#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/sky.glsl"
#include "/lib/shadow.glsl"
#include "/lib/celestial.glsl"
#include "/lib/water.glsl"
#include "/lib/dimension_sky.glsl"
#include "/lib/nasa_galaxy.glsl"
#include "/lib/vanilla_moon.glsl"
uniform int frameCounter;
#define FOXY_IMAGE_OPAQUE_ENDPOINT_CURRENT
#define FOXY_IMAGE_LAYER_ENDPOINT_PING_PONG
#define FOXY_IMAGE_WATER_SEGMENT_CURRENT
#define FOXY_IMAGE_MAIN_WATER_PRODUCER_CURRENT
#if (defined(DISTANT_HORIZONS) || defined(LOD_MOD_ACTIVE)) && !defined(VOXY)
	#define FOXY_IMAGE_LOD_WATER_PRODUCER_CURRENT
#endif
#define FOXY_IMAGE_CLOUD_LAYER_CURRENT
#include "/lib/contracts/water.glsl"

uniform sampler2D colortex0;
uniform sampler2D colortex2;
uniform sampler2D colortex13;
uniform sampler2D colortex7;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler2D shadowtex0;
#if FOXY_MATERIAL_REFLECTIONS == 1 && FOXY_MATERIAL_REFLECTION_GLOBAL == 1 && FOXY_VOXEL_GI_ACTIVE == 1
uniform sampler2DShadow shadowtex1;
#endif
#if FOXY_MATERIAL_REFLECTIONS == 1
uniform sampler3D cloudStbnVec2;
#endif
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousProjection;
uniform mat4 gbufferPreviousModelView;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform float rainStrength;
uniform float near;
uniform float far;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTimeCounter;
uniform int isEyeInWater;
uniform vec2 temporalJitter;
uniform vec2 previousTemporalJitter;

varying vec2 texcoord;
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying vec3 vertexSunView;
varying vec3 vertexMoonView;
varying vec3 vertexUpView;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;

#include "/lib/sr.glsl"

#include "/lib/contracts/images.glsl"
#include "/lib/contracts/material.glsl"
#if FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
	#include "/lib/contracts/direct_shadow.glsl"
#endif
#if FOXY_PT_GBUFFER_ACTIVE == 1 || defined(VOXY)
	#define PT_GBUFFER_READ
	#include "/lib/pt_gbuffer.glsl"
	#undef PT_GBUFFER_READ
#endif
#if defined(VOXY)
	#include "/lib/contracts/voxy.glsl"
#endif

// Import VRTGI geometry without its compute entry point or image uniforms.
#if FOXY_VOXEL_GI_ACTIVE == 1 && (FOXY_VOXEL_TRACING == 1 || (FOXY_MATERIAL_REFLECTIONS == 1 && FOXY_MATERIAL_REFLECTION_GLOBAL == 1))
	#if FOXY_MATERIAL_REFLECTIONS == 1 && FOXY_MATERIAL_REFLECTION_GLOBAL == 1
		#define FOXY_MATERIAL_REFLECTION_GLOBAL_DIRECT_LIGHT
	#endif
	#define FOXY_SSPT_TRACE_EXTERNAL_UNIFORMS
	#define FOXY_SSPT_TRACE_LIBRARY_ONLY
	#include "/program/sspt_trace.csh"
	#undef FOXY_SSPT_TRACE_LIBRARY_ONLY
	#undef FOXY_SSPT_TRACE_EXTERNAL_UNIFORMS
	#if FOXY_MATERIAL_REFLECTIONS == 1 && FOXY_MATERIAL_REFLECTION_GLOBAL == 1
		#undef FOXY_MATERIAL_REFLECTION_GLOBAL_DIRECT_LIGHT
	#endif
#endif

float SafeDivisor(const in float x) {
	if (abs(x) < 1.0e-6) {
		return x < 0.0 ? -1.0e-6 : 1.0e-6;
	}
	return x;
}

vec3 ViewPosFromDepth(const in vec2 uv, const in float depth) {
	vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 view = gbufferProjectionInverse * clip;
	return view.xyz / SafeDivisor(view.w);
}

vec2 SceneRenderUv(const in vec2 uv) {
	return SrSceneSampleUv(uv);
}

vec2 RenderPixelCenter(const in vec2 uv) {
	return SrSceneResourcePixelCenter(uv);
}

vec3 DimensionBackground(const in vec2 viewUv) {
	vec2 ndc = viewUv * 2.0 - 1.0;
	vec4 view = gbufferProjectionInverse * vec4(ndc, 1.0, 1.0);
	vec3 viewDirection = normalize(view.xyz / SafeDivisor(view.w));
	vec3 worldDirection = normalize(mat3(gbufferModelViewInverse) * viewDirection);
	#if defined(FOXY_DIM_NETHER)
		return NetherEnvironment(worldDirection);
	#elif defined(FOXY_DIM_END)
		return EndEnvironment(worldDirection, frameTimeCounter);
	#else
		return vec3(0.0);
	#endif
}

vec2 WaterCurrentViewUv(const in vec2 rasterUv) {
#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
	return rasterUv - temporalJitter * 0.5;
#else
	return rasterUv;
#endif
}

vec2 WaterCurrentRasterUv(const in vec2 viewUv) {
#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
	return viewUv + temporalJitter * 0.5;
#else
	return viewUv;
#endif
}

vec2 WaterCurrentRenderUv(const in vec2 viewUv) {
	return SceneRenderUv(WaterCurrentRasterUv(viewUv));
}

vec3 PlayerPosFromViewPos(const in vec3 viewPos) {
	vec4 playerPos = gbufferModelViewInverse * vec4(viewPos, 1.0);
	return playerPos.xyz / SafeDivisor(playerPos.w);
}

#if FOXY_PT_GBUFFER_ACTIVE == 0
vec3 WorldNormalFromDepth1(const in vec2 uv, const in float centerDepth) {
	vec2 pixel = SrActivePixelSize();
	vec2 uvL = clamp(uv - vec2(pixel.x, 0.0), vec2(0.001), vec2(0.999));
	vec2 uvR = clamp(uv + vec2(pixel.x, 0.0), vec2(0.001), vec2(0.999));
	vec2 uvD = clamp(uv - vec2(0.0, pixel.y), vec2(0.001), vec2(0.999));
	vec2 uvU = clamp(uv + vec2(0.0, pixel.y), vec2(0.001), vec2(0.999));

	float depthL = texture2D(depthtex1, WaterCurrentRenderUv(uvL)).r;
	float depthR = texture2D(depthtex1, WaterCurrentRenderUv(uvR)).r;
	float depthD = texture2D(depthtex1, WaterCurrentRenderUv(uvD)).r;
	float depthU = texture2D(depthtex1, WaterCurrentRenderUv(uvU)).r;
	vec3 center = ViewPosFromDepth(uv, centerDepth);
	vec3 posL = ViewPosFromDepth(uvL, depthL);
	vec3 posR = ViewPosFromDepth(uvR, depthR);
	vec3 posD = ViewPosFromDepth(uvD, depthD);
	vec3 posU = ViewPosFromDepth(uvU, depthU);

	// Compare in reconstructed camera space; Iris `far` may use a shorter domain.
	float dl = abs(posL.z - center.z);
	float dr = abs(posR.z - center.z);
	float dd = abs(posD.z - center.z);
	float du = abs(posU.z - center.z);
	vec3 dx = dr < dl ? posR - center : center - posL;
	vec3 dy = du < dd ? posU - center : center - posD;
	vec3 normalView = normalize(cross(dx, dy));
	if (dot(normalView, -center) < 0.0) {
		normalView = -normalView;
	}
	return normalize(mat3(gbufferModelViewInverse) * normalView);
}
#endif

vec3 MainWaterGeometricNormalView(const in vec2 uv, const in float centerDepth) {
	vec2 pixel = SrActivePixelSize();
	vec2 uvL = clamp(uv - vec2(pixel.x, 0.0), vec2(0.001), vec2(0.999));
	vec2 uvR = clamp(uv + vec2(pixel.x, 0.0), vec2(0.001), vec2(0.999));
	vec2 uvD = clamp(uv - vec2(0.0, pixel.y), vec2(0.001), vec2(0.999));
	vec2 uvU = clamp(uv + vec2(0.0, pixel.y), vec2(0.001), vec2(0.999));

	float depthL = texture2D(depthtex0, WaterCurrentRenderUv(uvL)).r;
	float depthR = texture2D(depthtex0, WaterCurrentRenderUv(uvR)).r;
	float depthD = texture2D(depthtex0, WaterCurrentRenderUv(uvD)).r;
	float depthU = texture2D(depthtex0, WaterCurrentRenderUv(uvU)).r;
	vec3 center = ViewPosFromDepth(uv, centerDepth);
	vec3 posL = ViewPosFromDepth(uvL, depthL);
	vec3 posR = ViewPosFromDepth(uvR, depthR);
	vec3 posD = ViewPosFromDepth(uvD, depthD);
	vec3 posU = ViewPosFromDepth(uvU, depthU);

	float dl = abs(posL.z - center.z);
	float dr = abs(posR.z - center.z);
	float dd = abs(posD.z - center.z);
	float du = abs(posU.z - center.z);
	vec3 dx = dr < dl ? posR - center : center - posL;
	vec3 dy = du < dd ? posU - center : center - posD;
	vec3 normalView = cross(dx, dy);
	normalView *= inversesqrt(max(dot(normalView, normalView), 1.0e-12));
	if (dot(normalView, -center) < 0.0) {
		normalView = -normalView;
	}
	return normalView;
}

float ScreenEdgeFade(const in vec2 uv) {
	vec2 edge = min(uv, vec2(1.0) - uv);
	return smoothstep(0.0, 0.012, edge.x) * smoothstep(0.0, 0.012, edge.y);
}

float WaterR11DitherNoise() {
	vec2 phase = gl_FragCoord.xy + vec2(float(frameCounter) * 0.75487765, float(frameCounter) * 0.56984026);
	return fract(52.9829189 * fract(0.06711056 * phase.x + 0.00583715 * phase.y)) - 0.5;
}

vec3 WaterR11Dither(const in vec3 color) {
	return color;
}

vec4 WaterStoreBufferColor(const in vec3 color, const in float alpha) {
	return vec4(WaterR11Dither(color), alpha);
}

vec3 CloudLayerOverScene(
	const in vec3 background,
	const in vec2 viewUv,
	const in float minimumRayDistance,
	const in Endpoint endpoint
) {
	if (
		EndpointOwnerIs(endpoint, FOXY_ENDPOINT_OWNER_CLOUD) &&
		endpoint.rayDistance > minimumRayDistance
	) {
		vec4 cloud = LoadCloudLayer(SceneRenderUv(viewUv));
		float alpha = Saturate(cloud.a);
		return background * (1.0 - alpha) + max(cloud.rgb, vec3(0.0));
	}
	return background;
}

vec3 CloudLayerOverScene(
	const in vec3 background,
	const in vec2 viewUv,
	const in float minimumRayDistance
) {
	Endpoint endpoint = EndpointUnpack(LoadCloudEndpoint(SceneRenderUv(viewUv)));
	return CloudLayerOverScene(background, viewUv, minimumRayDistance, endpoint);
}

vec3 OrderedSceneSampleBehind(
	const in vec2 viewUv,
	const in float minimumRayDistance
) {
	vec3 background = DecodeSceneColor(
		texture2D(colortex0, WaterCurrentRenderUv(viewUv)).rgb
	);
	return CloudLayerOverScene(background, viewUv, minimumRayDistance);
}

vec3 ReflectionSample(const in vec2 uv) {
	return OrderedSceneSampleBehind(uv, 0.0);
}

float WaterSceneLinearDepth(
	const in vec2 viewUv,
	const in vec2 renderUv,
	out float surfaceValid
) {
	#if defined(VOXY)
		// Endpoint Y stores projection-neutral linear view depth for water SSR.
		Endpoint sceneEndpoint = EndpointUnpack(
			LoadOpaqueEndpoint(SceneRenderUv(viewUv))
		);
		float linearDepth = sceneEndpoint.viewDistance;
		surfaceValid = 1.0 - step(FOXY_ENDPOINT_INFINITY * 0.5, linearDepth);
		return max(linearDepth, 0.0);
	#else
	float mainDepthRaw = texture2D(depthtex1, renderUv).r;
	vec3 viewPos = ResolveOpaqueViewPosition(
		viewUv,
		renderUv,
		mainDepthRaw,
		gbufferProjectionInverse,
		surfaceValid
	);
	return max(-viewPos.z, 0.0);
	#endif
}

vec3 WaterSolidViewPosition(
	const in vec2 viewUv,
	const in vec2 renderUv,
	const in float mainDepthRaw,
	out float surfaceValid
) {
	vec3 viewPos = ResolveOpaqueViewPosition(
		viewUv,
		renderUv,
		mainDepthRaw,
		gbufferProjectionInverse,
		surfaceValid
	);
	return viewPos;
}

float WaterProducerValidAtViewUv(const in vec2 viewUv) {
	vec2 rasterUv = WaterCurrentRasterUv(viewUv);
	WaterProducerPacket packet = ResolveWaterProducer(SceneRenderUv(rasterUv));
	Endpoint opaqueEndpoint = EndpointUnpack(
		LoadOpaqueEndpoint(SceneRenderUv(viewUv))
	);
	return WaterProducerVisibleBeforeOpaque(packet, opaqueEndpoint);
}

#include "/features/water/reflection/trace_screen.glsl"
#include "/features/water/reflection/resolve.glsl"
#include "/features/water/reflection/fallback.glsl"
#include "/features/water/transmission/surface.glsl"
#include "/features/material/reflection.glsl"

vec4 TraceGlassReflection(const in vec3 viewPos, const in vec3 reflectedDir) {
	vec3 startView = viewPos + reflectedDir * 0.065;
	float rayLength = clamp(max(-viewPos.z * 1.25, 12.0), 12.0, 64.0);
	if (reflectedDir.z > 0.0001) {
		float nearLimit = (-near - startView.z) / reflectedDir.z;
		if (nearLimit <= 0.01) return vec4(texcoord, 0.0, 0.0);
		rayLength = min(rayLength, nearLimit * 0.98);
	}
	vec3 endView = startView + reflectedDir * rayLength;
	vec4 startProjected = ProjectViewPos(startView);
	vec4 endProjected = ProjectViewPos(endView);
	if (startProjected.w <= 0.0 || endProjected.w <= 0.0) {
		return vec4(texcoord, 0.0, 0.0);
	}

	vec2 screenDelta = endProjected.xy - startProjected.xy;
	float startK = 1.0 / SafeDivisor(startProjected.w);
	float endK = 1.0 / SafeDivisor(endProjected.w);
	vec2 startQzAndK = vec2(startView.z * startK, startK);
	vec2 endQzAndK = vec2(endView.z * endK, endK);
	float jitter = 0.30 + Hash12(floor(gl_FragCoord.xy)) * 0.55;
	float previousT = 0.0;
	const int glassReflectionSteps = 6;

	for (int i = 0; i < glassReflectionSteps; i++) {
		float rayT = (float(i) + jitter) / float(glassReflectionSteps);
		vec2 sampleViewUv = startProjected.xy + screenDelta * rayT;
		if (sampleViewUv.x <= 0.001 || sampleViewUv.x >= 0.999 ||
			sampleViewUv.y <= 0.001 || sampleViewUv.y >= 0.999) break;
		vec2 sampleRenderUv = WaterCurrentRenderUv(sampleViewUv);
		float sampleValid;
		float sceneDepth = WaterSceneLinearDepth(sampleViewUv, sampleRenderUv, sampleValid);
		if (sampleValid > 0.5) {
			float rayDepth = TraceViewDepth(rayT, startQzAndK, endQzAndK);
			float previousRayDepth = TraceViewDepth(previousT, startQzAndK, endQzAndK);
			float thickness = clamp(sceneDepth * 0.010 + abs(rayDepth - previousRayDepth) * 1.35, 0.10, 1.65);
			float depthDelta = rayDepth - sceneDepth;
			if (depthDelta >= -thickness * 0.22 && depthDelta <= thickness) {
				return vec4(sampleViewUv, ScreenEdgeFade(sampleViewUv), 1.0);
			}
		}
		previousT = rayT;
	}
	return vec4(texcoord, 0.0, 0.0);
}

vec3 ApplyLightweightGlass(
	const in vec3 sceneColor,
	const in vec2 viewUv,
	const in vec2 renderUv,
	const in vec4 glassPacket,
	const in float glassDepth,
	const in Endpoint layerEndpoint
) {
	vec3 glassViewPos = ViewPosFromDepth(viewUv, glassDepth);
	float glassViewDistance = max(length(glassViewPos), 1.0e-5);
	vec3 unrefractedScene = CloudLayerOverScene(
		sceneColor,
		viewUv,
		glassViewDistance,
		layerEndpoint
	);
	vec3 incidentView = glassViewPos / glassViewDistance;
	vec3 normalView = MaterialGlassNormal(glassPacket);
	if (dot(normalView, -incidentView) < 0.0) normalView = -normalView;
	float normalViewDot = max(dot(normalView, -incidentView), 0.0);

	float opaqueDepth = texture2D(depthtex1, renderUv).r;
	float opaqueValid = 1.0 - step(0.99999, opaqueDepth);
	vec3 opaqueViewPos = ViewPosFromDepth(viewUv, opaqueDepth);
	float glassPath = max(length(opaqueViewPos) - glassViewDistance, 0.0) * opaqueValid;
	vec3 refractedDir = refract(incidentView, normalView, 0.66);
	float refractedNormalDot = max(dot(refractedDir, -normalView), 0.12);
	float refractionOffset = Saturate(glassPath * 2.0) * 0.045;
	vec3 refractedViewPos = glassViewPos + refractedDir * (refractionOffset / refractedNormalDot);
	vec4 refractedProjected = ProjectViewPos(refractedViewPos);
	vec2 refractedUv = refractedProjected.xy;
	vec2 refractedRenderUv = WaterCurrentRenderUv(refractedUv);
	float refractedDepth = texture2D(depthtex1, refractedRenderUv).r;
	float refractionValid = step(1.0e-6, refractedProjected.w);
	refractionValid *= step(0.001, refractedUv.x) * step(refractedUv.x, 0.999);
	refractionValid *= step(0.001, refractedUv.y) * step(refractedUv.y, 0.999);
	refractionValid *= step(glassDepth + 1.0e-5, refractedDepth);
	refractionValid *= ScreenEdgeFade(refractedUv) * opaqueValid;
	vec3 refractedScene = OrderedSceneSampleBehind(refractedUv, glassViewDistance);

	vec3 transmission = MaterialGlassTransmission(glassPacket);
	float transmissionMax = max(max(transmission.r, transmission.g), transmission.b);
	float transmissionMin = min(min(transmission.r, transmission.g), transmission.b);
	float transmissionChroma = transmissionMax - transmissionMin;
	// Glass uses exponential absorption rather than painted alpha.
	float tintSignal = max(transmissionChroma, 1.0 - transmissionMax);
	float opticalDensity = mix(0.55, 2.20, Saturate(tintSignal * 1.35));
	vec3 absorption = exp2((transmission - vec3(1.0)) * opticalDensity);
	vec3 transmittedColor = mix(unrefractedScene, refractedScene, refractionValid) * absorption;

	vec3 reflectedViewDir = normalize(reflect(incidentView, normalView));
	vec3 reflectedWorldDir = normalize(mat3(gbufferModelViewInverse) * reflectedViewDir);
	vec3 skyReflection = DecodeSkyLutColor(
		texture2D(colortex7, SkyViewLutUv(reflectedWorldDir)).rgb
	);
	float skyVisibility = smoothstep(0.04, 0.26, reflectedWorldDir.y);
	vec3 reflectionColor = mix(unrefractedScene * 0.08 + vertexSkyAmbientColor * 0.12, skyReflection, skyVisibility);
	float grazing = 1.0 - normalViewDot;
	float fresnel = 0.04 + 0.96 * grazing * grazing * grazing * grazing * grazing;
	if (fresnel > 0.065) {
		vec4 localTrace = TraceGlassReflection(glassViewPos, reflectedViewDir);
		if (localTrace.w > 0.5) {
			vec3 localReflection = ReflectionSample(localTrace.xy);
			reflectionColor = mix(reflectionColor, localReflection, localTrace.z);
		}
	}
	vec3 glassColor = mix(transmittedColor, reflectionColor, Saturate(fresnel * 0.82));

	float sunLobe = pow(max(dot(reflectedViewDir, vertexSunView), 0.0), 512.0);
	float moonLobe = pow(max(dot(reflectedViewDir, vertexMoonView), 0.0), 384.0);
	vec2 directSourceWeights = CelestialShadowSourceWeights(normalize(shadowLightPosition), vertexSunView, vertexMoonView);
	sunLobe *= directSourceWeights.x * DirectCelestialVisibility(vertexSunAltitude);
	moonLobe *= directSourceWeights.y * DirectCelestialVisibility(vertexMoonAltitude);
	glassColor += vertexSunLightColor * sunLobe * (0.45 + fresnel * 1.10);
	glassColor += vertexMoonLightColor * moonLobe * (0.28 + fresnel * 0.72);
	return max(glassColor, vec3(0.0));
}

#if FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
bool ShadowSceneDepthHit(
	const in vec3 traceViewPosition,
	const in float thickness,
	out bool traceValid
) {
	traceValid = true;
	vec4 projected = gbufferProjection * vec4(traceViewPosition, 1.0);
	if (projected.w <= 1.0e-5) {
		traceValid = false;
		return false;
	}
	vec2 viewUv = projected.xy / projected.w * 0.5 + 0.5;
	if (viewUv.x <= 0.001 || viewUv.x >= 0.999 ||
		viewUv.y <= 0.001 || viewUv.y >= 0.999) {
		traceValid = false;
		return false;
	}

	Endpoint surfaceEndpoint = EndpointUnpack(
		LoadOpaqueEndpoint(SceneRenderUv(viewUv))
	);
	if (EndpointValid(surfaceEndpoint) < 0.5) return false;
	float depthDelta = length(traceViewPosition) - surfaceEndpoint.rayDistance;
	return depthDelta > 0.20 && depthDelta < thickness;
}

float UnifiedScreenShadowTrace(
	const in vec3 receiverViewPosition,
	const in vec3 receiverViewNormal,
	const in vec3 lightViewDirection,
	const in float traceReach,
	const in int traceSamples
) {
	float stepLength = max(traceReach / max(float(traceSamples), 1.0), 0.35);
	float phase = Hash12(
		floor(gl_FragCoord.xy) +
		vec2(float(frameCounter) * 0.75487765, float(frameCounter) * 0.56984026)
	);
	vec3 tracePosition = receiverViewPosition +
		receiverViewNormal * 1.25 +
		lightViewDirection * (stepLength * (0.45 + phase * 0.70));

	for (int stepIndex = 0; stepIndex < 16; stepIndex++) {
		if (stepIndex >= traceSamples) break;
		bool traceValid;
		if (ShadowSceneDepthHit(
			tracePosition,
			max(3.0, stepLength * 1.35),
			traceValid
		)) return 0.0;
		if (!traceValid) break;
		tracePosition += lightViewDirection * stepLength;
	}
	return 1.0;
}

float ShadowCasterBoundaryTravel(
	const in vec3 receiverPlayerPosition,
	const in vec3 lightWorldDirection
) {
	float ownedRadius = max(FOXY_SHADOW_DISTANCE - 24.0, 1.0);
	float receiverRadius2 = dot(receiverPlayerPosition, receiverPlayerPosition);
	if (receiverRadius2 >= ownedRadius * ownedRadius) return 0.0;
	float projected = dot(receiverPlayerPosition, lightWorldDirection);
	float discriminant = max(
		projected * projected + ownedRadius * ownedRadius - receiverRadius2,
		0.0
	);
	return max(-projected + sqrt(discriminant), 0.0);
}

#if FOXY_VOXEL_TRACING == 1
float VoxelCasterVisibility(
	const in vec3 receiverPlayerPosition,
	const in vec3 receiverWorldNormal,
	const in vec3 lightWorldDirection
) {
	vec3 traceOrigin = VoxelGridSceneToGrid(
		receiverPlayerPosition,
		cameraPosition
	);

	// One stochastic DDA sample matches the native PCF footprint through TAA.
	float phase = ShadowTemporalPhase(gl_FragCoord.xy, frameCounter);
	float diskRadius = sqrt(fract(phase * 1.32471795724 + 0.37));
	vec2 diskSample = ShadowDirection(phase) * diskRadius;
	vec3 basisSeed = abs(lightWorldDirection.y) < 0.999
		? vec3(0.0, 1.0, 0.0)
		: vec3(1.0, 0.0, 0.0);
	vec3 filterTangent = normalize(cross(basisSeed, lightWorldDirection));
	vec3 filterBitangent = cross(lightWorldDirection, filterTangent);
	vec3 filterDirection = filterTangent * diskSample.x +
		filterBitangent * diskSample.y;

	vec4 shadowClip = shadowProjection * shadowModelView *
		vec4(receiverPlayerPosition, 1.0);
	vec2 shadowClipXY = shadowClip.xy / SafeDivisor(shadowClip.w);
	float projectionScale = max(abs(shadowProjection[0][0]), 1.0e-6);
	float shadowWorldTexel = 2.0 * max(ShadowWarpFactor(shadowClipXY), 0.18) /
		(float(FOXY_SHADOW_RESOLUTION) * projectionScale);
	float minimumFilterRadius = shadowWorldTexel *
		(0.5 + SHADOW_MIN_FILTER_TEXELS);
	float maximumPenumbra = shadowWorldTexel *
		(0.12 + FOXY_SHADOW_SOFTNESS * 1.00);

	vec3 receiverFilterOffset = filterDirection * minimumFilterRadius;
	receiverFilterOffset -= receiverWorldNormal *
		dot(receiverFilterOffset, receiverWorldNormal);
	vec3 filteredLightDirection = normalize(
		lightWorldDirection + filterDirection * (maximumPenumbra * 0.5)
	);
	traceOrigin += receiverFilterOffset + receiverWorldNormal * 0.035 +
		filteredLightDirection * 0.035;
	if (!VoxelGridInside(traceOrigin)) return 1.0;

	uint hitPayload;
	float hitDistance;
	ivec3 hitCell;
	vec3 hitNormal;
	vec3 sphereRadiance;
	vec3 rayTransmittance;
	int traceResult = VoxelGiTrace(
		traceOrigin,
		filteredLightDirection,
		0.5,
		7,
		false,
		hitPayload,
		hitDistance,
		hitCell,
		hitNormal,
		sphereRadiance,
		rayTransmittance
	);
	return traceResult == FOXY_VOXEL_GI_TRACE_SURFACE_HIT ? 0.0 : 1.0;
}
#endif

vec3 ApplyMainOpaqueShadowContract(
	const in vec3 sceneColor,
	const in vec2 viewUv,
	const in vec2 renderUv,
	const in vec4 directShadowPacket,
	const in vec4 surfaceData,
	const in Endpoint opaqueEndpoint
) {
	if (!EndpointOwnerIs(opaqueEndpoint, FOXY_ENDPOINT_OWNER_MAIN)) {
		return sceneColor;
	}

	vec3 removableDirect = DirectShadowContribution(directShadowPacket);
	float nativeVisibility = DirectShadowNativeVisibility(directShadowPacket);
	if (Luma(removableDirect) <= 1.0e-6 || nativeVisibility <= 1.0e-5) {
		return sceneColor;
	}

	vec3 mainViewPosition = EndpointViewRay(
		opaqueEndpoint,
		viewUv,
		gbufferProjectionInverse
	) * opaqueEndpoint.rayDistance;
	vec3 mainPlayerPosition = PlayerPosFromViewPos(mainViewPosition);
	vec3 activeLightWorld = normalize(
		mat3(gbufferModelViewInverse) * normalize(shadowLightPosition)
	);

	#if FOXY_VOXEL_TRACING == 0
		float boundaryTravel = ShadowCasterBoundaryTravel(
			mainPlayerPosition,
			activeLightWorld
		);
		const float maximumTraceReach = 128.0;
		if (boundaryTravel >= maximumTraceReach) return sceneColor;
	#endif

	#if FOXY_PT_GBUFFER_ACTIVE == 1
		PtGbufferSample mainSurfaceData = PtDecodeGbuffer(surfaceData, 0.5);
		if (mainSurfaceData.valid < 0.5) return sceneColor;
		vec3 receiverWorldNormal = mainSurfaceData.worldGeometricNormal;
	#else
		float mainDepth = texture2D(depthtex1, renderUv).r;
		if (mainDepth >= 0.99999) return sceneColor;
		vec3 receiverWorldNormal = WorldNormalFromDepth1(viewUv, mainDepth);
	#endif
	#if FOXY_VOXEL_TRACING == 1
		float supplementalVisibility = VoxelCasterVisibility(
			mainPlayerPosition,
			receiverWorldNormal,
			activeLightWorld
		);
	#else
		vec3 receiverViewNormal = normalize(mat3(gbufferModelView) * receiverWorldNormal);
		vec3 lightViewDirection = normalize(mat3(gbufferModelView) * activeLightWorld);
		float traceStepLength = clamp(length(mainViewPosition) * 0.0025, 2.5, 10.0);
		float supplementalVisibility = UnifiedScreenShadowTrace(
			mainViewPosition,
			receiverViewNormal,
			lightViewDirection,
			traceStepLength * 16.0,
			16
		);
	#endif
	if (supplementalVisibility > 0.999) return sceneColor;

	float finalVisibility = min(nativeVisibility, supplementalVisibility);
	float retainedDirect = finalVisibility / max(nativeVisibility, 1.0e-5);
	return max(
		sceneColor - removableDirect * (1.0 - Saturate(retainedDirect)),
		vec3(0.0)
	);
}

#if defined(VOXY)
vec3 ApplyVoxyOpaqueShadow(
	const in vec3 sceneColor,
	const in vec2 viewUv,
	const in vec2 renderUv,
	const in vec4 surfaceData,
	const in Endpoint opaqueEndpoint
) {
	bool voxyEndpoint = EndpointOwnerIs(opaqueEndpoint, FOXY_ENDPOINT_OWNER_VOXY);
	if (!voxyEndpoint) return sceneColor;

	float voxyDepth = BackendLodSolidRaw(renderUv);
	if (!BackendHasLodSurface(voxyDepth)) return sceneColor;
	PtGbufferSample voxySurfaceData = PtDecodeGbuffer(surfaceData, 0.5);
	if (voxySurfaceData.valid < 0.5 || PtSurfaceIsEmissive(voxySurfaceData.surfaceClass) > 0.5) {
		return sceneColor;
	}
	vec2 voxyRasterUv = BackendVoxyDepthViewUv(renderUv);
	vec3 voxyViewPosition = BackendLodViewPosition(voxyRasterUv, voxyDepth);
	vec3 sunWorld = normalize(mat3(gbufferModelViewInverse) * vertexSunView);
	vec3 moonWorld = normalize(mat3(gbufferModelViewInverse) * vertexMoonView);

	vec3 ambient;
	vec3 directSun;
	vec3 directMoon;
	vec3 fogColor;
	VoxyLighting(
		voxySurfaceData.lightmap,
		voxySurfaceData.worldGeometricNormal,
		sunWorld,
		moonWorld,
		rainStrength,
		ambient,
		directSun,
		directMoon,
		fogColor
	);
	vec3 direct = directSun + directMoon;
	if (Luma(direct) <= 1.0e-5) return sceneColor;

	vec3 activeLightWorld = Luma(directSun) >= Luma(directMoon)
		? sunWorld
		: moonWorld;
	vec3 receiverMainViewPosition = BackendLodViewToMainView(
		voxyViewPosition,
		gbufferModelView
	);
	vec3 receiverMainViewNormal = normalize(
		mat3(gbufferModelView) * voxySurfaceData.worldGeometricNormal
	);
	vec3 lightViewDirection = normalize(mat3(gbufferModelView) * activeLightWorld);
	float voxyStepLength = clamp(length(receiverMainViewPosition) * 0.0025, 2.5, 10.0);
	float visibility = UnifiedScreenShadowTrace(
		receiverMainViewPosition,
		receiverMainViewNormal,
		lightViewDirection,
		voxyStepLength * 16.0,
		16
	);
	if (visibility > 0.999) return sceneColor;
	// Match binary Voxy blockers to average filtered near-field visibility.
	visibility = mix(1.0, visibility, 0.88);

	vec3 unshadowed = voxySurfaceData.albedo * max(ambient + direct, vec3(0.00015));
	vec3 shadowed = voxySurfaceData.albedo * max(ambient + direct * visibility, vec3(0.00015));
	#if FOXY_VOLUMETRIC_LIGHT == 0
		vec3 playerPosition = (vxModelViewInv * vec4(voxyViewPosition, 1.0)).xyz;
		vec3 worldPosition = playerPosition + cameraPosition;
		unshadowed = VoxyApplyFog(
			unshadowed,
			fogColor,
			voxyViewPosition,
			worldPosition,
			cameraPosition,
			vec3(0.0, 1.0, 0.0),
			sunWorld.y,
			far
		);
		shadowed = VoxyApplyFog(
			shadowed,
			fogColor,
			voxyViewPosition,
			worldPosition,
			cameraPosition,
			vec3(0.0, 1.0, 0.0),
			sunWorld.y,
			far
		);
	#endif

	return max(sceneColor - max(unshadowed - shadowed, vec3(0.0)), vec3(0.0));
}
#endif
#endif

void main() {
	// composite2 consumes raster UV; viewTexcoord identifies the stable camera ray.
	vec2 rasterTexcoord = texcoord;
	vec2 viewTexcoord = WaterCurrentViewUv(rasterTexcoord);
	vec2 renderTexcoord = SceneRenderUv(rasterTexcoord);
	Endpoint layerEndpoint = EndpointUnpack(
		LoadCloudEndpoint(SceneRenderUv(viewTexcoord))
	);
	vec4 scene = texture2D(colortex0, renderTexcoord);
	#if FOXY_MATERIAL_REFLECTIONS == 1
		vec4 materialReflectionSignal = vec4(0.0);
	#endif
	vec2 waterProducerUv = renderTexcoord;
	vec2 waterPayloadUv = RenderPixelCenter(rasterTexcoord);
	vec4 waterMaterialPacket = texture2D(colortex2, waterPayloadUv);
	vec4 waterSurfacePacket = texture2D(colortex13, waterPayloadUv);
	WaterProducerPacket waterPacket = ResolveWaterProducer(waterProducerUv);
	if (
		abs(waterPacket.owner - FOXY_ENDPOINT_OWNER_MAIN_WATER) < 0.5
		&& MaterialIsWater(waterMaterialPacket) > 0.5
	) {
		// Rebuild unordered water image writes from the depth-tested nearest surface.
		float mainWaterDepthRaw = texture2D(depthtex0, renderTexcoord).r;
		if (mainWaterDepthRaw < 0.99999) {
			vec3 mainWaterViewPos = ViewPosFromDepth(viewTexcoord, mainWaterDepthRaw);
			waterPacket.frontRayDistance = length(mainWaterViewPos);
			waterPacket.baseNormalView = MainWaterGeometricNormalView(viewTexcoord, mainWaterDepthRaw);

			float mainOpaqueDepthRaw = texture2D(depthtex1, renderTexcoord).r;
			waterPacket.backRayDistance = waterPacket.frontRayDistance;
			if (mainOpaqueDepthRaw < 0.99999) {
				vec3 mainOpaqueViewPos = ViewPosFromDepth(viewTexcoord, mainOpaqueDepthRaw);
				waterPacket.backRayDistance = max(length(mainOpaqueViewPos), waterPacket.frontRayDistance);
			}
		}
	}
	Endpoint opaqueEndpoint = EndpointUnpack(
		LoadOpaqueEndpoint(SceneRenderUv(viewTexcoord))
	);
	#if defined(FOXY_DIM_NETHER) || defined(FOXY_DIM_END)
		// Voxy leaves vanilla depth empty; the resolved endpoint owns the sky test.
		if (EndpointValid(opaqueEndpoint) < 0.5) {
			scene.rgb = EncodeSceneColor(DimensionBackground(viewTexcoord));
		}
	#endif
	float waterPresent = WaterProducerVisibleBeforeOpaque(waterPacket, opaqueEndpoint)
		* MaterialIsWater(waterMaterialPacket);
	#if FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
		if (waterPresent <= 0.0001) {
			vec3 shadowedScene = ApplyMainOpaqueShadowContract(
				max(DecodeSceneColor(scene.rgb), vec3(0.0)),
				viewTexcoord,
				renderTexcoord,
				waterSurfacePacket,
				waterMaterialPacket,
				opaqueEndpoint
			);
			#if defined(VOXY)
				shadowedScene = ApplyVoxyOpaqueShadow(
					shadowedScene,
					viewTexcoord,
					renderTexcoord,
					waterMaterialPacket,
					opaqueEndpoint
				);
			#endif
			scene.rgb = EncodeSceneColor(shadowedScene);
		}
	#endif

	if (waterPresent <= 0.0001) {
		float glassPresent = MaterialIsGlass(waterMaterialPacket);
		float glassDepth = 1.0;
		if (glassPresent > 0.5) {
			glassDepth = texture2D(depthtex0, renderTexcoord).r;
			glassPresent *= 1.0 - step(0.99999, glassDepth);
		}
		if (glassPresent > 0.5) {
			vec3 glassViewPos = ViewPosFromDepth(viewTexcoord, glassDepth);
			WaterSegment glassSegment;
			glassSegment.frontRayDistance = length(glassViewPos);
			glassSegment.frontViewDistance = max(-glassViewPos.z, 0.0);
			glassSegment.owner = FOXY_ENDPOINT_OWNER_MAIN_GLASS;
			glassSegment.valid = 1.0;
			StoreWaterSegment(renderTexcoord, WaterSegmentPack(glassSegment));
			vec3 glassScene = ApplyLightweightGlass(
				max(DecodeSceneColor(scene.rgb), vec3(0.0)),
				viewTexcoord,
				renderTexcoord,
				waterMaterialPacket,
				glassDepth,
				layerEndpoint
			);
			scene.rgb = EncodeSceneColor(glassScene);
		} else {
			StoreWaterSegment(renderTexcoord, WaterSegmentPack(WaterSegmentInvalid()));
		}
		#if FOXY_MATERIAL_REFLECTIONS == 1
			materialReflectionSignal = TraceMaterialReflectionSignal(
				max(DecodeSceneColor(scene.rgb), vec3(0.0)),
				viewTexcoord,
				renderTexcoord,
				waterMaterialPacket
			);
		#endif
		#if FOXY_VOLUMETRIC_LIGHT == 0
			// Without volume resolve, colortex14 is the complete TAA source.
			vec3 completeCurrent = max(DecodeSceneColor(scene.rgb), vec3(0.0));
			if (glassPresent <= 0.5) {
				completeCurrent = CloudLayerOverScene(
					completeCurrent,
					viewTexcoord,
					0.0,
					layerEndpoint
				);
			}
			scene.rgb = EncodeSceneColor(max(completeCurrent, vec3(0.0)));
		#endif
		gl_FragData[0] = WaterStoreBufferColor(scene.rgb, scene.a);
		#if FOXY_MATERIAL_REFLECTIONS == 1
			gl_FragData[1] = materialReflectionSignal;
		#endif
		return;
	}
	float waterSunGlintSignal = MaterialWaterSunGlintSignal(
		waterMaterialPacket,
		192.0 * min(FOXY_WATER_SUN_GLINT, 1.0)
	);
	scene.rgb = mix(
		scene.rgb,
		WaterSurfaceEncodedColor(waterSurfacePacket),
		WaterSurfaceAlpha(waterSurfacePacket)
	);
	scene.rgb = DecodeSceneColor(scene.rgb);
	float mask = waterPresent;
	vec2 waterViewUv = viewTexcoord;
	vec3 waterViewPos = WaterProducerViewPosition(
		waterViewUv,
		waterProducerUv,
	waterPacket,
		gbufferProjectionInverse,
		gbufferModelView
	);
	float waterOwner = waterPacket.owner;
	float waterDepth = max(-waterViewPos.z, 0.0);
	float waterPathDistance = max(
		waterPacket.backRayDistance - waterPacket.frontRayDistance,
		0.0
	) * waterPresent;
	vec3 waterPlayerPos = PlayerPosFromViewPos(waterViewPos);
	vec3 waterWorldPos = waterPlayerPos + cameraPosition;

	float waterViewDistance = max(length(waterViewPos), 0.0);
	scene.rgb = CloudLayerOverScene(
		scene.rgb,
		viewTexcoord,
		waterViewDistance,
		layerEndpoint
	);
	vec3 incidentView = waterViewPos / max(waterViewDistance, 1.0e-6);
	vec3 upView = vertexUpView;
	vec3 normalView = upView;
	float waterNormalAaReduction = MaterialWaterNormalAa(waterMaterialPacket);
	vec3 baseNormalView = normalize(waterPacket.baseNormalView);
	vec3 wavedNormalView = MaterialWaterNormal(waterMaterialPacket);
	#if defined(VOXY)
		if (abs(waterOwner - FOXY_ENDPOINT_OWNER_VOXY_WATER) < 0.5) {
			// Voxy water normals already use main optical space.
			baseNormalView = wavedNormalView;
			#if FOXY_WATER_SPECTRUM_WAVES == 1
				vec3 baseNormalPlayer = normalize(mat3(gbufferModelViewInverse) * baseNormalView);
				vec2 waterSurfaceCoord = WaterSurfaceCoordPlayer(baseNormalPlayer, waterWorldPos);
				float waterFootprint = max(length(dFdx(waterSurfaceCoord)), length(dFdy(waterSurfaceCoord)));
				wavedNormalView = WaterDetailNormalViewShared(
					gbufferModelView,
					baseNormalView,
					waterWorldPos,
					cameraPosition,
					frameTimeCounter,
					waterFootprint,
					waterNormalAaReduction
				);
			#endif
		}
	#endif
	float underwaterMix = isEyeInWater == 1 ? 1.0 : 0.0;
	normalView = wavedNormalView;
	if (dot(normalView, -incidentView) < 0.0) {
		normalView = -normalView;
	}
	float NoV = max(dot(normalView, -incidentView), 0.0);
	float waterFresnel = 0.020 + 0.980 * pow(1.0 - NoV, 5.0);
	float internalReflectance = WaterInternalReflectance(NoV);
	float snellWindow = 1.0;
	float snellUvValid = 0.0;
	vec2 snellTransmissionUv = viewTexcoord;
	if (isEyeInWater == 1) {
		snellWindow = WaterSnellWindowTransmission(NoV);
		snellTransmissionUv = WaterSnellTransmissionUv(viewTexcoord, incidentView, normalView, snellUvValid);
	}
	float underwaterTransmission = underwaterMix * snellWindow * snellUvValid;
	float totalInternalReflection = underwaterMix * (1.0 - underwaterTransmission);
	float reflectionReflectance = mix(waterFresnel, internalReflectance, underwaterMix);
	float reflectionUserScale = mix(0.30, 1.35, Saturate(FOXY_WATER_REFLECTION));
	mask *= Saturate(reflectionReflectance * reflectionUserScale);
	// Total internal reflection must not expose the unrefracted shoreline.
	mask = mix(mask, waterPresent, totalInternalReflection);
	vec3 reflectionUpView = dot(upView, -incidentView) < 0.0 ? -upView : upView;
	float flatReflectionNoV = abs(dot(reflectionUpView, -incidentView));
	float reflectionGrazing = 1.0 - smoothstep(0.035, 0.18, flatReflectionNoV);
	#if FOXY_WATER_SSR_NORMAL_STABILIZATION == 1
	float reflectionNormalStabilize = Saturate(waterNormalAaReduction * (0.38 + reflectionGrazing * 0.44));
	#else
	float reflectionNormalStabilize = 0.0;
	#endif
	vec3 reflectionNormalView = normalize(mix(normalView, reflectionUpView, reflectionNormalStabilize));
	vec3 sunView = vertexSunView;
	vec3 moonView = vertexMoonView;
	float sunAltitude = vertexSunAltitude;
	float moonAltitude = vertexMoonAltitude;
	float waveStability = mix(1.0, 0.78 + 0.22 * max(dot(normalView, upView), 0.0), Saturate(FOXY_WATER_WAVE_STRENGTH));
	vec3 reflectedDir = normalize(reflect(incidentView, reflectionNormalView));
	vec3 reflectedWorldDir = normalize(mat3(gbufferModelViewInverse) * reflectedDir);
	vec4 trace = vec4(viewTexcoord, 0.0, 0.0);
	if (mask > 0.003) {
		trace = TraceWaterReflection(
			waterViewPos,
			reflectedDir
		);
	}
	float skyOpenness = WaterReflectionSkyOpenness(reflectedWorldDir, waterDepth);
	if (isEyeInWater == 1) {
		skyOpenness = 0.0;
	}
	// Screen-space misses use low-frequency local and directional environment light.
	vec4 fallback = vec4(max(scene.rgb, vec3(0.0)) * 0.58, 0.78);
	if (skyOpenness > 0.035) {
		vec4 directionalFallback = SkyCloudReflectionFallback(
			reflectedDir,
			reflectedWorldDir,
			waterWorldPos
		);
		float directionalWeight = directionalFallback.a * mix(0.04, 1.0, skyOpenness);
		fallback.rgb = mix(fallback.rgb, directionalFallback.rgb * 0.52, directionalWeight);
		fallback.a = mix(fallback.a, 0.92, directionalWeight);
	}
	if (isEyeInWater == 1) {
		vec4 underwaterFallback = UnderwaterInternalReflectionFallback(reflectionReflectance, reflectedWorldDir);
		fallback = vec4(mix(fallback.rgb, underwaterFallback.rgb, underwaterFallback.a), max(fallback.a, underwaterFallback.a));
		fallback.a = max(fallback.a, totalInternalReflection);
	}
	float waterRoughness = Saturate(0.27 + FOXY_WATER_WAVE_STRENGTH * 0.36 + (1.0 - waveStability) * 0.30);
	WaterReflectionSignal reflectionSignal;
	float microfacetVisibility = mix(0.74, 1.0, pow(1.0 - NoV, 2.15));
	float resolvedWaveStability = mix(waveStability, 1.0, totalInternalReflection);
	float resolvedMicrofacetVisibility = mix(microfacetVisibility, 1.0, totalInternalReflection);
	reflectionSignal = ResolveWaterReflectionSignal(trace, fallback, waterRoughness, mask, resolvedWaveStability, resolvedMicrofacetVisibility);
	float reflectionAmount = reflectionSignal.amount;


	float grazingWater = pow(1.0 - NoV, 2.15);
	float waterFogOcclusion = 0.0;
	float refractionWeight = 0.0;
	float refractionSurface = waterPresent * (0.84 + FOXY_WATER_WAVE_STRENGTH * 0.32);
	vec2 refractedUv = WaterRefractionUv(
		viewTexcoord,
		baseNormalView,
		normalView,
		waterDepth,
		refractionSurface
	);
	float currentDepthRaw = texture2D(depthtex1, renderTexcoord).r;
	float currentNotSky;
	vec3 currentViewPos = WaterSolidViewPosition(viewTexcoord, renderTexcoord, currentDepthRaw, currentNotSky);
	float currentLinearDepth = max(-currentViewPos.z, 0.0);
	float currentRayDistance = max(length(currentViewPos) - waterViewDistance, 0.0);
	float currentDepthSpan = currentLinearDepth - waterDepth;
	float currentBelowSurface = smoothstep(-0.03, 0.18, currentDepthSpan) * smoothstep(0.03, 0.70, currentRayDistance);
	float currentUnderwaterTarget = currentNotSky * currentBelowSurface * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	vec2 refractedRenderUv = WaterCurrentRenderUv(refractedUv);
	float refractedDepthRaw = texture2D(depthtex1, refractedRenderUv).r;
	float refractedNotSky;
	vec3 refractedViewPos = WaterSolidViewPosition(refractedUv, refractedRenderUv, refractedDepthRaw, refractedNotSky);
	float refractedLinearDepth = max(-refractedViewPos.z, 0.0);
	float refractedRayDistance = max(length(refractedViewPos) - waterViewDistance, 0.0);
	float refractedDepthSpan = refractedLinearDepth - waterDepth;
	float refractedBelowSurface = smoothstep(-0.03, 0.18, refractedDepthSpan) * smoothstep(0.03, 0.70, refractedRayDistance);
	float refractionDepthJump = abs(refractedLinearDepth - currentLinearDepth);
	float refractionEdgeReject = smoothstep(0.42 + waterDepth * 0.010, 2.65 + waterDepth * 0.035, refractionDepthJump);
	float stableRefraction = (1.0 - refractionEdgeReject) * refractedNotSky * refractedBelowSurface * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	stableRefraction *= ScreenEdgeFade(refractedUv);
	vec2 transmittedUv = mix(viewTexcoord, refractedUv, stableRefraction);
	transmittedUv = mix(transmittedUv, snellTransmissionUv, underwaterTransmission);
	vec2 transmittedRenderUv = WaterCurrentRenderUv(transmittedUv);
	float transmittedDepthRaw = texture2D(depthtex1, transmittedRenderUv).r;
	vec3 transmitted = OrderedSceneSampleBehind(
		transmittedUv,
		waterViewDistance
	);
	float transmittedNotSky;
	vec3 transmittedViewPos = WaterSolidViewPosition(transmittedUv, transmittedRenderUv, transmittedDepthRaw, transmittedNotSky);
	float transmittedLinearDepth = max(-transmittedViewPos.z, 0.0);
	float transmittedRayDistance = max(length(transmittedViewPos) - waterViewDistance, 0.0);
	float transmittedDepthSpan = transmittedLinearDepth - waterDepth;
	float belowSurface = smoothstep(-0.03, 0.18, transmittedDepthSpan) * smoothstep(0.03, 0.70, transmittedRayDistance);
	float noBottomWater = (1.0 - transmittedNotSky) * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	float packetUnderwaterTarget = smoothstep(0.03, 0.70, waterPathDistance) * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	float underwaterTarget = max(max(transmittedNotSky * belowSurface, packetUnderwaterTarget), noBottomWater) * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	if (underwaterTarget > 0.001) {
		float noBottomRayDistance = max(far * 0.35, 96.0);
		float depthStableRayDistance = max(transmittedRayDistance, currentRayDistance * currentUnderwaterTarget);
		float packetFallbackWeight = (1.0 - transmittedNotSky * belowSurface) * smoothstep(0.18, 1.20, waterPathDistance);
		float conservativeRayDistance = max(depthStableRayDistance, mix(depthStableRayDistance, waterPathDistance, 0.18));
		float effectiveWaterRayDistance = noBottomWater > 0.5 ? noBottomRayDistance : mix(conservativeRayDistance, waterPathDistance, packetFallbackWeight);
		float waterFog = Saturate(FOXY_WATER_FOG);
		float waterRayDistance = effectiveWaterRayDistance;
		vec3 waterTransmittance = WaterTransmittance(waterRayDistance * mix(1.15, 2.10, waterFog), waterFog);
		// Water direct transport follows atmospheric, not disc, horizon visibility.
		float solarLightingVisibility = DirectCelestialVisibility(sunAltitude);
		float moonLightingVisibility = DirectCelestialVisibility(vertexMoonAltitude);
		float solarIrradiance = WaterSolarIrradiance(vertexSunLightColor, sunAltitude);
		float lunarIrradiance = WaterLunarIrradiance(vertexMoonLightColor, vertexMoonAltitude);
		float sourceIrradiance = solarIrradiance + lunarIrradiance;
		float sunTopLight = max(dot(upView, sunView), 0.0);
		float moonTopLight = max(dot(upView, moonView), 0.0);
		float topLight = (sunTopLight * solarIrradiance + moonTopLight * lunarIrradiance)
			/ max(sourceIrradiance, 1.0e-4);
		vec3 moonLightColor = vertexMoonLightColor;
		vec3 activeDirectColor = vertexSunLightColor * solarLightingVisibility
			+ moonLightColor * moonLightingVisibility;
		float activeDirectAmount = Saturate(topLight * sourceIrradiance);
		vec3 waterAmbient = vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor);
		float skyIrradiance = WaterSkyIrradiance(waterAmbient, rainStrength);
		float stableWaterSkyLight = Saturate((0.26 + smoothstep(-0.08, 0.34, sunAltitude) * 0.42
			+ (1.0 - rainStrength) * 0.10) * mix(0.30, 1.0, skyIrradiance));
		vec3 waterScatter = WaterScatterColor(waterAmbient, activeDirectColor, activeDirectAmount, stableWaterSkyLight, rainStrength);
		vec3 waterInput = mix(waterScatter, transmitted, transmittedNotSky);
		vec3 transmittedWater = waterInput * waterTransmittance + waterScatter * (vec3(1.0) - waterTransmittance);
		if (transmittedNotSky * belowSurface > 0.001) {
			vec3 transmittedPlayerPos = PlayerPosFromViewPos(transmittedViewPos);
			vec3 transmittedWorldPos = transmittedPlayerPos + cameraPosition;
			vec3 sunWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, sunView));
			float verticalWaterDepth = max(waterWorldPos.y - transmittedWorldPos.y, 0.0);
			float caustics = WaterCaustics(
				transmittedWorldPos,
				sunWorld,
				frameTimeCounter,
				verticalWaterDepth,
				verticalWaterDepth
			);
			float causticVisibility = transmittedNotSky * belowSurface;
			causticVisibility *= smoothstep(0.02, 0.30, sunWorld.y);
			causticVisibility *= 1.0 - rainStrength * 0.78;
			causticVisibility *= 1.0 - smoothstep(54.0, 138.0, verticalWaterDepth);
			float causticFocus = max(caustics - 1.0, 0.0)
				* FOXY_WATER_CAUSTICS_BRIGHTNESS * causticVisibility;
			vec3 sunTint = max(vertexSunLightColor, vec3(0.0));
			sunTint /= max(Luma(sunTint), 0.16);
			vec3 causticTint = mix(vec3(1.0), sunTint, 0.18);
			transmittedWater *= vec3(1.0) + causticTint * causticFocus * 0.78;
		}
		float waterOcclusion = Saturate(1.0 - max(max(waterTransmittance.r, waterTransmittance.g), waterTransmittance.b));
		waterFogOcclusion = waterOcclusion * underwaterTarget;
		float waterFogReplace = mix(0.30, 1.0, smoothstep(0.05, 0.72, waterOcclusion));
		transmitted = mix(transmitted, transmittedWater, underwaterTarget * waterFogReplace);
	}
	float refractionCoverage = smoothstep(0.015, 0.18, NoV);
	float refractionReplace = mix(0.97, 1.0, Saturate(FOXY_WATER_FOG));
	float fogReplace = smoothstep(0.08, 0.92, waterFogOcclusion);
	refractionWeight = max(underwaterTarget * refractionCoverage * refractionReplace, fogReplace * waterPresent);
	refractionWeight = max(refractionWeight, underwaterTransmission);
	vec3 baseScene = mix(scene.rgb, transmitted, Saturate(refractionWeight));
	float finalReflectionAmount = 0.0;
	vec3 color = CompositeWaterReflection(baseScene, reflectionSignal, reflectionAmount, waterFogOcclusion, grazingWater, finalReflectionAmount);
	// Add solar glint after refraction selects the water volume.
	if (isEyeInWater == 0 && waterSunGlintSignal > 0.0001) {
		color += max(vertexSunLightColor, vec3(0.0)) * waterSunGlintSignal;
	}
	if (isEyeInWater == 0) {
		vec3 fogColor = FogColor(sunAltitude, rainStrength);
		float waterBoundaryFar = SceneReach(far);
		vec2 boundaryFogWeights = SkyBoundaryFogWeights(waterPlayerPos, sunAltitude, waterBoundaryFar);
		vec3 boundaryFogColor = fogColor;
		if (max(boundaryFogWeights.x, boundaryFogWeights.y) > 0.001) {
			boundaryFogColor = SkyBoundaryFogColor(colortex7, waterViewPos, gbufferModelViewInverse);
		}
		#if FOXY_VOLUMETRIC_LIGHT == 0
			color = ApplyFog(color, fogColor, boundaryFogColor, boundaryFogWeights, waterViewPos, waterWorldPos, cameraPosition, upView);
		#endif
	}
	WaterSegment waterSegment;
	waterSegment.frontRayDistance = max(waterViewDistance, 0.0);
	waterSegment.frontViewDistance = waterDepth;
	waterSegment.owner = waterOwner;
	waterSegment.valid = waterPresent;
	layerEndpoint = ResolveWaterEndpoint(
		layerEndpoint,
		waterSegment.frontRayDistance,
		waterSegment.frontViewDistance,
		waterSegment.valid,
		waterOwner,
		FOXY_ENDPOINT_MEDIUM_WATER
	);
	#if FOXY_VOLUMETRIC_LIGHT == 0
		// Without volume resolve, add only clouds in front of the water endpoint.
		color = CloudLayerOverScene(
			color,
			viewTexcoord,
			0.0,
			layerEndpoint
		);
	#endif
	// composite8 completes cloud and volume when volumetrics are enabled.
	StoreWaterSegment(renderTexcoord, WaterSegmentPack(waterSegment));
	gl_FragData[0] = WaterStoreBufferColor(EncodeSceneColor(max(color, vec3(0.0))), scene.a);
	#if FOXY_MATERIAL_REFLECTIONS == 1
		gl_FragData[1] = vec4(0.0);
	#endif
}
