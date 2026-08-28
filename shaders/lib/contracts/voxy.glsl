#ifndef FOXY_CONTRACT_VOXY_GLSL
#define FOXY_CONTRACT_VOXY_GLSL

#include "/lib/settings.glsl"
#include "/lib/contracts/backend.glsl"
#include "/lib/lighting.glsl"
#include "/lib/sky.glsl"

// Voxy's inverse projection is a pipeline-owned binding rather than an Iris
// custom uniform, so keep its declaration in this shared Voxy contract. The
// Iris custom uniforms are registered in shaders.properties and emitted from
// the voxy.json uniform list.

// Voxy rasterizes its program at the active Voxy viewport. vxProj/vxProjInv
// remain unjittered: Voxy applies the JSON taaOffset only after projection in
// its vertex shader. Convert the raster coordinate back to logical view UV
// before any inverse projection.
vec2 VoxyViewUv(
	const in vec2 fragCoord,
	const in vec2 viewPixelSize
) {
	float renderScale = 1.0;
#if FOXY_TAAU_ACTIVE == 1
	renderScale = max(FOXY_TAAU_RENDER_SCALE, 1.0e-6);
#endif
	vec2 rasterUv = fragCoord * viewPixelSize / renderScale;
	vec2 viewUv = BackendVoxyViewUvFromRasterUv(rasterUv);
	return clamp(viewUv, vec2(0.0), vec2(0.999999));
}

// Voxy passes Iris block.properties IDs through customId. The material
// table uses the same absolute IDs, so no 10000 offset is applied here.
float VoxyMaterialId(const in uint customId) {
	return customId >= 10000u ? float(customId) : 0.0;
}

bool VoxyMaterialInRange(
	const in float materialId,
	const in float firstId,
	const in float lastId
) {
	return materialId >= firstId && materialId <= lastId;
}

vec3 VoxyFaceNormal(const in uint face) {
	uint side = face >> 1u;
	float sign = (face & 1u) == 0u ? -1.0 : 1.0;
	return normalize(vec3(
		(side == 2u) ? 1.0 : 0.0,
		(side == 0u) ? 1.0 : 0.0,
		(side == 1u) ? 1.0 : 0.0
	) * sign);
}

vec3 VoxyViewPosition(
	const in vec2 uv,
	const in float depth,
	const in mat4 projectionInverse
) {
	vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 view = projectionInverse * clip;
	float safeW = abs(view.w) < 1.0e-6
		? (view.w < 0.0 ? -1.0e-6 : 1.0e-6)
		: view.w;
	return view.xyz / safeW;
}

// Voxy owns both sides of its view transform. A position reconstructed with
// vxProjInv must return through vxModelViewInv; Iris' regular GBuffer matrix is
// a different pipeline binding and cannot be mixed into this coordinate path.
vec3 VoxyPlayerPosition(const in vec3 viewPos) {
	return (vxModelViewInv * vec4(viewPos, 1.0)).xyz;
}

vec3 VoxyViewNormal(const in vec3 worldNormal) {
	return normalize(mat3(vxModelView) * worldNormal);
}

void VoxyLighting(
	const in vec2 lightMap,
	const in vec3 normalWorld,
	const in vec3 sunWorld,
	const in vec3 moonWorld,
	const in float rainStrength,
	out vec3 ambient,
	out vec3 directSun,
	out vec3 directMoon,
	out vec3 fogColor
) {
	float blockLight = clamp(lightMap.x, 0.0, 1.0);
	float skyLight = clamp(lightMap.y, 0.0, 1.0);
	float sunAltitude = sunWorld.y;
	float moonAltitude = moonWorld.y;

#if defined(FOXY_DIM_NETHER)
	ambient = vec3(0.070, 0.018, 0.010) * (0.32 + 0.68 * skyLight);
	directSun = vec3(0.0);
	directMoon = vec3(0.0);
	fogColor = vec3(0.115, 0.030, 0.018);
#elif defined(FOXY_DIM_END)
	ambient = vec3(0.026, 0.022, 0.050) * (0.42 + 0.58 * skyLight);
	directSun = vec3(0.0);
	directMoon = vec3(0.0);
	fogColor = vec3(0.050, 0.040, 0.090);
#else
	vec3 sunColor = SunColor(sunAltitude, rainStrength);
	vec3 moonColor = MoonColor(moonAltitude, rainStrength);
	float sunNoL = max(dot(normalWorld, sunWorld), 0.0);
	float moonNoL = max(dot(normalWorld, moonWorld), 0.0);
	// Voxy's light-map sky channel is an occlusion signal, not the sky's
	// time-of-day irradiance.  The native and DH paths keep a small physically
	// motivated open-sky floor at dawn/dusk; using the raw channel here made
	// distant Voxy terrain collapse to black while nearby terrain remained lit.
	float ambientVisibility = AmbientSkyVisibility(sunAltitude, skyLight);
	ambient = SkyAmbientColor(sunAltitude, rainStrength) * ambientVisibility;
	ambient += MoonAmbientColorFromMoonColor(moonColor) * ambientVisibility;
	directSun = sunColor * DirectCelestialVisibility(sunAltitude) * (sunNoL * 1.08 + pow(sunNoL, 8.0) * 0.24) * skyLight;
	directMoon = moonColor * (moonNoL * 1.03 + pow(moonNoL, 8.0) * 0.08) * skyLight;
	fogColor = FogColor(sunAltitude, rainStrength);
#endif
	ambient += TorchColor(blockLight) * 0.42;
}

// Voxy geometry is rendered outside the main far plane. Apply the same
// sky-boundary transition used by native and DH terrain so the LOD border
// fades into the current sky LUT instead of inheriting a gray far-fog color.
vec3 VoxyApplyFog(
	const in vec3 color,
	const in vec3 fogColor,
	const in vec3 viewPos,
	const in vec3 worldPos,
	const in vec3 cameraWorldPos,
	const in vec3 upDir,
	const in float sunAltitude,
	const in float mainFar
) {
	float boundaryFar = max(mainFar, BackendRenderDistance());
	vec2 boundaryWeights = SkyBoundaryFogWeights(worldPos, sunAltitude, boundaryFar);
	vec3 boundaryColor = fogColor;
	if (max(boundaryWeights.x, boundaryWeights.y) > 0.001) {
		boundaryColor = SkyBoundaryFogColor(colortex7, viewPos, vxModelViewInv);
	}
	return ApplyFog(
		color,
		fogColor,
		boundaryColor,
		boundaryWeights,
		viewPos,
		worldPos,
		cameraWorldPos,
		upDir
	);
}

#endif
