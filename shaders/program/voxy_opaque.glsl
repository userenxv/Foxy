#ifndef texture2D
#define texture2D texture
#endif

#define FOXY_EXTERNAL_PIPELINE_BINDINGS

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/lighting.glsl"
#include "/lib/contracts/voxy.glsl"
#define PT_GBUFFER_WRITE
#include "/lib/pt_gbuffer.glsl"
#undef PT_GBUFFER_WRITE

layout(location = 0) out vec4 voxySceneColor;
layout(location = 1) out vec4 voxyGbuffer;

void voxy_emitFragment(VoxyFragmentParameters parameters) {
	vec2 screenUv = VoxyViewUv(gl_FragCoord.xy, view_pixel_size);
	vec3 normalWorld = normalize(VoxyFaceNormal(parameters.face));
	vec3 viewPos = VoxyViewPosition(screenUv, gl_FragCoord.z, vxProjInv);
	vec3 playerPos = VoxyPlayerPosition(viewPos);
	vec3 worldPos = playerPos + cameraPosition;
	vec3 baseSrgb = max(parameters.sampledColour.rgb * parameters.tinting.rgb, vec3(0.0));
	vec3 albedo = SrgbToLinear(baseSrgb);
	vec3 sunWorld = vec3(0.0, 1.0, 0.0);
	vec3 moonWorld = vec3(0.0, -1.0, 0.0);
#if !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
	sunWorld = normalize(sun_dir);
	moonWorld = normalize(moon_dir);
#endif
	vec3 ambient;
	vec3 directSun;
	vec3 directMoon;
	vec3 fogColor;
	VoxyLighting(parameters.lightMap, normalWorld, sunWorld, moonWorld, rainStrength, ambient, directSun, directMoon, fogColor);
	vec3 direct = directSun + directMoon;
	vec3 lit = albedo * max(ambient + direct, vec3(0.00015));

#if FOXY_VOLUMETRIC_LIGHT == 0
	lit = VoxyApplyFog(
		lit,
		fogColor,
		viewPos,
		worldPos,
		cameraPosition,
		vec3(0.0, 1.0, 0.0),
		normalize(sunWorld).y,
		far
	);
#endif
	voxySceneColor = vec4(EncodeSceneColor(max(lit, vec3(0.0))), 1.0);

	float materialId = VoxyMaterialId(parameters.customId);
	float surfaceClass = PT_SURFACE_OPAQUE;
	if (abs(materialId - 10100.0) < 0.5) {
		surfaceClass = PT_SURFACE_FOLIAGE;
	} else if (materialId >= 10101.0 && materialId <= 10103.0) {
		surfaceClass = PT_SURFACE_PLANT;
	} else if (
		(materialId >= 10170.0 && materialId <= 10197.0) ||
		abs(materialId - 10232.0) < 0.5
	) {
		surfaceClass = PT_SURFACE_EMISSIVE;
	}
	voxyGbuffer = PtEncodeGbuffer(
		albedo,
		normalWorld,
		normalWorld,
		parameters.lightMap,
		surfaceClass,
		0.82,
		0.0
	);
}
