#include "/lib/settings.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
const vec2 workGroupsRender = vec2(
	FOXY_RAY_RESOLUTION,
	FOXY_RAY_RESOLUTION
);

layout(rgba16f) readonly uniform image2D img_ptTrace;
layout(rgba16f) uniform image2D img_ptHistoryA;
layout(rgba16f) uniform image2D img_ptHistoryB;
layout(rgba16f) uniform image2D img_ptHistoryMetaA;
layout(rgba16f) uniform image2D img_ptHistoryMetaB;
layout(rg16f) uniform image2D img_ptMomentsA;
layout(rg16f) uniform image2D img_ptMomentsB;
// Spatial bootstrap is display-only; history stores only cell-owned observations.
layout(rgba16f) writeonly uniform image2D img_ptFilteredA;

uniform sampler2D colortex2;
uniform sampler2D depthtex0;
#if FOXY_VOXEL_GI_ACTIVE == 1
	uniform sampler2D colortex7;
#endif
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTime;
uniform vec2 temporalJitter;
uniform vec2 previousTemporalJitter;
uniform int frameCounter;

#include "/lib/math.glsl"
#include "/lib/sr.glsl"
#include "/lib/rt_denoiser.glsl"
#include "/lib/first_person_depth.glsl"
#if FOXY_VOXEL_GI_ACTIVE == 1
	#include "/lib/contracts/sky_lut.glsl"
	#include "/lib/dimension_sky.glsl"
	#include "/lib/voxel/vrtgi_fallback.glsl"
#endif
#define PT_GBUFFER_READ
#include "/lib/pt_gbuffer.glsl"
#undef PT_GBUFFER_READ
#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
	#include "/lib/voxel/voxel_grid.glsl"
	#include "/lib/voxel/irradiance_cache.glsl"
#endif

#define SSPT_TEMPORAL_GROUP_SIZE 8
#define SSPT_TEMPORAL_PREFILTER_RADIUS 1
#define SSPT_TEMPORAL_TILE_SIDE (SSPT_TEMPORAL_GROUP_SIZE + SSPT_TEMPORAL_PREFILTER_RADIUS * 2)
#define SSPT_TEMPORAL_TILE_AREA (SSPT_TEMPORAL_TILE_SIDE * SSPT_TEMPORAL_TILE_SIDE)

shared vec4 ssptCurrentSignal[SSPT_TEMPORAL_TILE_AREA];
shared vec4 ssptCurrentGuide[SSPT_TEMPORAL_TILE_AREA];
shared vec4 ssptCurrentMaterialAux[SSPT_TEMPORAL_TILE_AREA];
#if FOXY_VOXEL_GI_ACTIVE == 1
	shared vec2 ssptCurrentLightmap[SSPT_TEMPORAL_TILE_AREA];
#endif

// Per-invocation private cache shared by history and fallback taps.
ivec2 ssptTemporalRenderSize;
vec2 ssptTemporalTraceToRenderScale;
vec2 ssptTemporalHistoryToRenderScale;
vec2 ssptTemporalPreviousViewPixelScale;
vec2 ssptTemporalPreviousViewBias;
float ssptTemporalGrazingRelax;
float ssptTemporalCurrentFoliage;
float ssptTemporalCurrentVegetation;
float ssptTemporalCurrentClassLocked;
float ssptTemporalCurrentFirstPerson;

bool SsptTemporalWritesA() {
	return (frameCounter % 2) == 0;
}

vec4 SsptTemporalLoadSignal(const in ivec2 pixel) {
	if (SsptTemporalWritesA()) return imageLoad(img_ptHistoryB, pixel);
	return imageLoad(img_ptHistoryA, pixel);
}

vec4 SsptTemporalLoadMeta(const in ivec2 pixel) {
	if (SsptTemporalWritesA()) return imageLoad(img_ptHistoryMetaB, pixel);
	return imageLoad(img_ptHistoryMetaA, pixel);
}

vec4 SsptTemporalLoadMoments(const in ivec2 pixel) {
	if (SsptTemporalWritesA()) return imageLoad(img_ptMomentsB, pixel);
	return imageLoad(img_ptMomentsA, pixel);
}

void SsptTemporalStore(
	const in ivec2 pixel,
	const in vec4 signal,
	const in vec4 meta,
	const in vec4 moments
) {
	if (SsptTemporalWritesA()) {
		imageStore(img_ptHistoryA, pixel, signal);
		imageStore(img_ptHistoryMetaA, pixel, meta);
		imageStore(img_ptMomentsA, pixel, moments);
	} else {
		imageStore(img_ptHistoryB, pixel, signal);
		imageStore(img_ptHistoryMetaB, pixel, meta);
		imageStore(img_ptMomentsB, pixel, moments);
	}
}

float SsptTemporalSafeDivisor(const in float value) {
	if (abs(value) < 1.0e-6) return value < 0.0 ? -1.0e-6 : 1.0e-6;
	return value;
}

float SsptTemporalSampleScale() {
	float referenceFrameFraction = max(frameTime, 1.0e-4) * 60.0;
	return clamp(1.0 / referenceFrameFraction, 1.0, 4.3333333333);
}

vec2 SsptTemporalViewUvFromRenderPixel(const in ivec2 pixel) {
	vec2 renderSize = max(SrRenderSize(), vec2(1.0));
	vec2 rasterUv = (vec2(pixel) + vec2(0.5)) / renderSize;
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return rasterUv - temporalJitter * 0.5;
	#else
		return rasterUv;
	#endif
}

vec3 SsptTemporalViewPos(const in vec2 viewUv, const in float depthRaw) {
	vec4 clip = vec4(viewUv * 2.0 - 1.0, depthRaw * 2.0 - 1.0, 1.0);
	vec4 view = gbufferProjectionInverse * clip;
	return view.xyz / SsptTemporalSafeDivisor(view.w);
}

float SsptTemporalLinearDepth(const in float depthRaw) {
	float clipZ = depthRaw * 2.0 - 1.0;
	float viewZ = gbufferProjectionInverse[2][2] * clipZ + gbufferProjectionInverse[3][2];
	float viewW = gbufferProjectionInverse[2][3] * clipZ + gbufferProjectionInverse[3][3];
	return max(-viewZ / SsptTemporalSafeDivisor(viewW), 1.0e-3);
}

int SsptTemporalSharedIndex(const in ivec2 localPixel) {
	return localPixel.y * SSPT_TEMPORAL_TILE_SIDE + localPixel.x;
}

vec2 SsptTemporalRasterUvFromRenderPixel(const in ivec2 pixel, const in ivec2 renderSize) {
	return (vec2(pixel) + vec2(0.5)) / vec2(renderSize);
}

bool SsptTemporalTracePixelSampled(const in ivec2 tracePixel) {
	#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 0 && FOXY_VRTGI_TEMPORAL_INTERLEAVE == 1
		return (tracePixel.x & 1) == (frameCounter & 1);
	#else
		return true;
	#endif
}

ivec2 SsptTemporalClosestPrimaryPixel(
	const in ivec2 tracePixel,
	const in ivec2 traceSize,
	const in ivec2 renderSize,
	out float bestDepth,
	out int bestCornerIndex
) {
	ivec2 minimumPixel;
	ivec2 maximumPixel;
	SrRayCellPixelBounds(
		tracePixel,
		traceSize,
		renderSize,
		minimumPixel,
		maximumPixel
	);
	ivec2 bestPixel = minimumPixel;
	bestDepth = texelFetch(depthtex0, bestPixel, 0).r;
	bestCornerIndex = 0;
	for (int cornerIndex = 1; cornerIndex < 4; cornerIndex++) {
		bool usesMaximumX = (cornerIndex & 1) != 0;
		bool usesMaximumY = (cornerIndex & 2) != 0;
		if (usesMaximumX && maximumPixel.x == minimumPixel.x) continue;
		if (usesMaximumY && maximumPixel.y == minimumPixel.y) continue;
		ivec2 candidatePixel = ivec2(
			usesMaximumX ? maximumPixel.x : minimumPixel.x,
			usesMaximumY ? maximumPixel.y : minimumPixel.y
		);
		float candidateDepth = texelFetch(depthtex0, candidatePixel, 0).r;
		if (candidateDepth < bestDepth) {
			bestDepth = candidateDepth;
			bestPixel = candidatePixel;
			bestCornerIndex = cornerIndex;
		}
	}
	return bestPixel;
}

void SsptTemporalPreload(const in ivec2 traceSize) {
	ivec2 groupBase = ivec2(gl_WorkGroupID.xy) * SSPT_TEMPORAL_GROUP_SIZE - ivec2(SSPT_TEMPORAL_PREFILTER_RADIUS);
	int localIndex = int(gl_LocalInvocationIndex);
	for (int tileIndex = localIndex; tileIndex < SSPT_TEMPORAL_TILE_AREA; tileIndex += SSPT_TEMPORAL_GROUP_SIZE * SSPT_TEMPORAL_GROUP_SIZE) {
		ivec2 tilePixel = ivec2(tileIndex % SSPT_TEMPORAL_TILE_SIDE, tileIndex / SSPT_TEMPORAL_TILE_SIDE);
		ivec2 sampleTracePixel = groupBase + tilePixel;
		vec4 signal = vec4(0.0);
		vec4 guide = vec4(0.5, 0.5, 1.0, 0.0);
		vec4 materialAux = vec4(0.0, 0.0, 0.0, 0.0);
		#if FOXY_VOXEL_GI_ACTIVE == 1
			vec2 sampleLightmap = vec2(0.0);
		#endif
		bool traceInside = all(greaterThanEqual(sampleTracePixel, ivec2(0))) && all(lessThan(sampleTracePixel, traceSize));
		if (traceInside) {
			vec4 traceData = imageLoad(img_ptTrace, sampleTracePixel);
			bool sampleTraced = SsptTemporalTracePixelSampled(sampleTracePixel);
			int primaryOffsetIndex;
			float sampleDepthRaw;
			ivec2 samplePrimaryPixel;
			if (sampleTraced) {
				primaryOffsetIndex = int(floor(
					RtDenoiserTracePrimaryOffsetIndex(traceData.a) + 0.5
				));
				samplePrimaryPixel = SrRayPrimaryPixelScaled(
					sampleTracePixel,
					ssptTemporalTraceToRenderScale,
					ssptTemporalRenderSize,
					primaryOffsetIndex
				);
				sampleDepthRaw = texelFetch(depthtex0, samplePrimaryPixel, 0).r;
			} else {
				samplePrimaryPixel = SsptTemporalClosestPrimaryPixel(
					sampleTracePixel,
					traceSize,
					ssptTemporalRenderSize,
					sampleDepthRaw,
					primaryOffsetIndex
				);
			}
			PtGbufferSample sampleGbuffer = PtDecodeGbuffer(
				texelFetch(colortex2, samplePrimaryPixel, 0),
				sampleDepthRaw
			);
			// Negative ownership invalidates history across the VRTGI boundary.
			float traceOwnership = sampleTraced
				? step(-0.99, RtDenoiserTraceState(traceData.a))
				: 1.0;
			float sampleDynamic = 1.0 - step(
				0.5,
				abs(sampleGbuffer.surfaceClass - PT_SURFACE_DYNAMIC)
			);
			float sampleFirstPerson = FirstPersonDepthMask(sampleDepthRaw) * sampleDynamic;
			float sampleProjectionDepth = FirstPersonProjectionDepth(
				sampleDepthRaw,
				sampleFirstPerson
			);
			vec3 sampleRadiance = sampleTraced ? max(traceData.rgb, vec3(0.0)) : vec3(0.0);
			if (!RtDenoiserFinite3(sampleRadiance)) sampleRadiance = vec3(0.0);
			sampleRadiance = min(sampleRadiance, vec3(64.0));
			float sampleLuma = min(RtDenoiserLuma(sampleRadiance), 64.0);
			signal = vec4(sampleRadiance, sampleLuma);
			guide = vec4(
				PtEncodeOctNormal(sampleGbuffer.worldGeometricNormal),
				SsptTemporalLinearDepth(sampleProjectionDepth),
				sampleGbuffer.reactive
			);
			materialAux = vec4(
				sampleGbuffer.surfaceClass,
				sampleDepthRaw,
				float(primaryOffsetIndex),
				sampleGbuffer.valid * traceOwnership
			);
			#if FOXY_VOXEL_GI_ACTIVE == 1
				sampleLightmap = sampleGbuffer.lightmap;
			#endif
		}
		ssptCurrentSignal[tileIndex] = signal;
		ssptCurrentGuide[tileIndex] = guide;
		ssptCurrentMaterialAux[tileIndex] = materialAux;
		#if FOXY_VOXEL_GI_ACTIVE == 1
			ssptCurrentLightmap[tileIndex] = sampleLightmap;
		#endif
	}
	memoryBarrierShared();
	barrier();
}

float SsptTemporalPreviousUv(
	const in vec3 viewPos,
	const in vec2 fallbackUv,
	const in float firstPerson,
	out vec2 previousUv,
	out float expectedPreviousDepth,
	out vec3 expectedPreviousViewPosition
) {
	previousUv = fallbackUv;
	expectedPreviousDepth = 0.0;
	expectedPreviousViewPosition = vec3(0.0);
	vec3 cameraDelta = cameraPosition - previousCameraPosition;
	if (dot(cameraDelta, cameraDelta) > 64.0) return 0.0;

	vec4 player = gbufferModelViewInverse * vec4(viewPos, 1.0);
	player.xyz /= SsptTemporalSafeDivisor(player.w);
	player.xyz += cameraDelta * (1.0 - firstPerson);
	vec4 previousView = gbufferPreviousModelView * vec4(player.xyz, 1.0);
	if (previousView.z >= -0.02) return 0.0;

	vec4 previousClip = gbufferPreviousProjection * previousView;
	if (previousClip.w <= 0.02) return 0.0;
	previousUv = previousClip.xy / SsptTemporalSafeDivisor(previousClip.w) * 0.5 + 0.5;
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		previousUv += previousTemporalJitter * 0.5;
	#endif
	expectedPreviousDepth = -previousView.z;
	expectedPreviousViewPosition = previousView.xyz;
	return float(previousUv.x >= 0.0 && previousUv.x <= 1.0 && previousUv.y >= 0.0 && previousUv.y <= 1.0);
}

vec3 SsptTemporalHistoryViewPosition(
	const in ivec2 historyPixel,
	const in vec4 historyMeta
) {
	int primaryOffsetIndex = int(floor(
		RtDenoiserMetaPrimaryOffsetIndex(historyMeta) + 0.5
	));
	vec2 fullPixel = vec2(SrRayPrimaryPixelScaled(
		historyPixel,
		ssptTemporalHistoryToRenderScale,
		ssptTemporalRenderSize,
		primaryOffsetIndex
	));
	float viewDepth = max(historyMeta.z, 1.0e-3);
	vec2 viewRay = (fullPixel + vec2(0.5)) *
		ssptTemporalPreviousViewPixelScale +
		ssptTemporalPreviousViewBias;
	return vec3(viewRay * viewDepth, -viewDepth);
}

float SsptTemporalThinSurface(const in float surfaceClass) {
	float plant = 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_PLANT));
	float strand = 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_STRAND));
	return max(plant, strand);
}

float SsptTemporalFoliageSurface(const in float surfaceClass) {
	return 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_FOLIAGE));
}

float SsptTemporalVegetationSurface(const in float surfaceClass) {
	float plant = 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_PLANT));
	return max(SsptTemporalFoliageSurface(surfaceClass), plant);
}

vec3 SsptTemporalFallbackViewNormal(
	const in vec3 worldNormal,
	const in vec3 previousViewPosition,
	const in float surfaceClass
) {
	vec3 physicalViewNormal = normalize(mat3(gbufferPreviousModelView) * worldNormal);
	float thinSurface = SsptTemporalThinSurface(surfaceClass);
	float foliageSurface = SsptTemporalFoliageSurface(surfaceClass);
	if (max(thinSurface, foliageSurface) < 0.5) return physicalViewNormal;
	float viewLengthSquared = dot(previousViewPosition, previousViewPosition);
	if (viewLengthSquared <= 1.0e-6) return physicalViewNormal;
	vec3 viewToCamera = -previousViewPosition * inversesqrt(viewLengthSquared);
	if (foliageSurface > 0.5) return viewToCamera;
	vec3 strandTangent = normalize(mat3(gbufferPreviousModelView) * vec3(0.0, 1.0, 0.0));
	vec3 projectedNormal = viewToCamera - strandTangent * dot(viewToCamera, strandTangent);
	float projectedLengthSquared = dot(projectedNormal, projectedNormal);
	if (projectedLengthSquared <= 1.0e-6) return physicalViewNormal;
	return projectedNormal * inversesqrt(projectedLengthSquared);
}

float SsptTemporalFoliageNeighbor(
	const in ivec2 tracePixel
) {
	float presence = 0.0;
	for (int tapIndex = 0; tapIndex < 4; tapIndex++) {
		ivec2 pixel = SrRayPrimaryPixelScaled(
			tracePixel,
			ssptTemporalTraceToRenderScale,
			ssptTemporalRenderSize,
			tapIndex
		);
		float depthRaw = texelFetch(depthtex0, pixel, 0).r;
		PtGbufferSample sampleGbuffer = PtDecodeGbuffer(texelFetch(colortex2, pixel, 0), depthRaw);
		float foliage = 1.0 - step(0.5, abs(sampleGbuffer.surfaceClass - PT_SURFACE_FOLIAGE));
		float plant = 1.0 - step(0.5, abs(sampleGbuffer.surfaceClass - PT_SURFACE_PLANT));
		presence = max(presence, sampleGbuffer.valid * sampleGbuffer.reactive * max(foliage, plant));
	}
	return presence;
}

void SsptTemporalBootstrapTap(
	const in ivec2 centerTracePixel,
	const in ivec2 centerLocalPixel,
	const in ivec2 unitOffset,
	const in vec3 centerNormal,
	const in float centerDepth,
	const in float centerSurfaceClass,
	const in float referenceLuminance,
	const in float referenceStandardDeviation,
	const in float kernelWeight,
	inout vec3 radianceSum,
	inout vec2 momentSum,
	inout float weightSum
) {
	ivec2 sampleTracePixel = centerTracePixel + unitOffset;
	ivec2 sampleLocalPixel = centerLocalPixel + unitOffset;
	int sampleIndex = SsptTemporalSharedIndex(sampleLocalPixel);
	vec4 sampleGuide = ssptCurrentGuide[sampleIndex];
	vec4 sampleMaterialAux = ssptCurrentMaterialAux[sampleIndex];
	if (sampleMaterialAux.w < 0.5) return;
	vec4 sampleHistory = SsptTemporalLoadSignal(sampleTracePixel);
	vec4 sampleHistoryMeta = SsptTemporalLoadMeta(sampleTracePixel);
	if (!RtDenoiserFinite4(sampleHistory) || !RtDenoiserFinite4(sampleHistoryMeta)) return;
	float sampleHistoryValid = RtDenoiserMetaValid(sampleHistoryMeta)
		* step(0.5, sampleHistory.a)
		* (1.0 - step(257.5, sampleHistory.a));
	if (sampleHistoryValid < 0.5) return;

	vec3 sampleNormal = PtDecodeOctNormal(sampleGuide.xy);
	float sampleDepth = sampleGuide.z;
	float sampleSurfaceClass = floor(sampleMaterialAux.x + 0.5);
	float sampleHistoryClassWeight = RtDenoiserSurfaceClassWeight(
		sampleSurfaceClass,
		RtDenoiserMetaSurfaceClass(sampleHistoryMeta)
	);
	float sampleHistoryDepthWeight = RtDenoiserRelativeDepthWeight(
		sampleDepth,
		sampleHistoryMeta.z,
		0.008,
		0.080
	);
	float sampleHistoryNormalWeight = RtDenoiserNormalWeight(
		sampleNormal,
		PtDecodeOctNormal(sampleHistoryMeta.xy)
	);
	if (sampleHistoryClassWeight * sampleHistoryDepthWeight * sampleHistoryNormalWeight <= 1.0e-4) return;
	float sameSurfaceClass = 1.0 - step(0.5, abs(centerSurfaceClass - sampleSurfaceClass));
	float normalGuideWeight = RtDenoiserNormalWeight(centerNormal, sampleNormal);
	normalGuideWeight = max(
		normalGuideWeight,
		RtDenoiserGrazingSurfaceFloor(
			sameSurfaceClass,
			ssptTemporalGrazingRelax
		) * (1.0 - ssptTemporalCurrentVegetation)
	);
	normalGuideWeight = mix(
		normalGuideWeight,
		max(normalGuideWeight, sameSurfaceClass * 0.25),
		ssptTemporalCurrentVegetation
	);
	float weight = kernelWeight;
	if (ssptTemporalCurrentVegetation > 0.5) {
		weight *= RtDenoiserRelativeDepthWeight(centerDepth, sampleDepth, 0.010, 0.10);
	} else {
		weight *= RtDenoiserRelativeDepthWeight(centerDepth, sampleDepth, 0.004, 0.032);
	}
	weight *= normalGuideWeight;
	vec3 sampleRadiance = max(sampleHistory.rgb, vec3(0.0));
	float sampleLuminance = RtDenoiserLuma(sampleRadiance);
	float luminancePhi = max(
		0.012 + 0.10 * max(referenceLuminance, sampleLuminance),
		referenceStandardDeviation * 1.25
	);
	weight *= sampleHistoryClassWeight * sampleHistoryDepthWeight * sampleHistoryNormalWeight;
	weight *= exp2(-abs(sampleLuminance - referenceLuminance) / max(luminancePhi, 1.0e-4));
	if (weight <= 1.0e-5) return;
	radianceSum += sampleRadiance * weight;
	momentSum += vec2(sampleLuminance, sampleLuminance * sampleLuminance) * weight;
	weightSum += weight;
}

void SsptTemporalHistoryTap(
	const in ivec2 pixel,
	const in ivec2 historySize,
	const in float bilinearWeight,
	const in vec3 currentNormal,
	const in float currentSurfaceClass,
	const in vec3 currentPreviousViewNormal,
	const in vec3 expectedPreviousViewPosition,
	const in float expectedDepth,
	inout vec4 historySignalSum,
	inout vec2 historyMomentSum,
	inout float weightSum
) {
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, historySize))) return;

	vec4 historyMeta = SsptTemporalLoadMeta(pixel);
	if (!RtDenoiserFinite4(historyMeta)) return;

	float markerValid = RtDenoiserMetaValid(historyMeta);
	if (markerValid < 0.5) return;
	vec3 historyNormal = PtDecodeOctNormal(historyMeta.xy);
	vec3 historyPreviousViewNormal = normalize(mat3(gbufferPreviousModelView) * historyNormal);
	vec3 historyPreviousViewPosition = SsptTemporalHistoryViewPosition(
		pixel,
		historyMeta
	);
	vec3 positionDelta = historyPreviousViewPosition - expectedPreviousViewPosition;
	float planeDistance = max(
		abs(dot(positionDelta, currentPreviousViewNormal)),
		abs(dot(positionDelta, historyPreviousViewNormal))
	);
	float planeTolerance = (0.016 + max(expectedDepth, historyMeta.z) * 0.00055) * ssptTemporalGrazingRelax;
	planeTolerance *= mix(1.0, 3.0, ssptTemporalCurrentFirstPerson);
	float planeWeight = exp2(-planeDistance / max(planeTolerance, 1.0e-4));
	float planeLimitWeight = mix(
		step(planeDistance, planeTolerance * 5.0),
		1.0 - smoothstep(planeTolerance * 3.0, planeTolerance * 8.0, planeDistance),
		ssptTemporalCurrentFirstPerson
	);
	planeWeight *= planeLimitWeight;
	planeWeight *= RtDenoiserRelativeDepthWeight(
		expectedDepth,
		historyMeta.z,
		mix(0.08, 0.12, ssptTemporalCurrentFirstPerson),
		mix(0.45, 0.72, ssptTemporalCurrentFirstPerson)
	);
	float guideWeight = bilinearWeight * markerValid;
	float historyClassWeight = RtDenoiserSurfaceClassWeight(
		currentSurfaceClass,
		RtDenoiserMetaSurfaceClass(historyMeta)
	);
	if (ssptTemporalCurrentClassLocked > 0.5 && historyClassWeight < 0.5) return;
	vec3 currentNormalGuide = normalize(mix(
		currentNormal,
		currentPreviousViewNormal,
		ssptTemporalCurrentFirstPerson
	));
	vec3 historyNormalGuide = normalize(mix(
		historyNormal,
		historyPreviousViewNormal,
		ssptTemporalCurrentFirstPerson
	));
	float normalWeight = RtDenoiserNormalWeight(currentNormalGuide, historyNormalGuide);
	normalWeight = max(
		normalWeight,
		RtDenoiserGrazingSurfaceFloor(
			historyClassWeight,
			ssptTemporalGrazingRelax
		) * (1.0 - ssptTemporalCurrentVegetation)
	);
	// First-person geometry lacks model motion vectors; retain only low-confidence history.
	normalWeight = max(
		normalWeight,
		historyClassWeight * ssptTemporalCurrentFirstPerson * 0.24
	);
	normalWeight = mix(normalWeight, max(normalWeight, historyClassWeight * 0.30), ssptTemporalCurrentVegetation);
	guideWeight *= normalWeight;
	guideWeight *= planeWeight;
	if (guideWeight <= 1.0e-5) return;

	vec4 historySignal = SsptTemporalLoadSignal(pixel);
	if (!RtDenoiserFinite4(historySignal)) return;
	float ageValid = step(0.5, historySignal.a) * (1.0 - step(257.5, historySignal.a));
	float weight = guideWeight * ageValid;
	if (weight <= 1.0e-5) return;
	vec4 historyMoments = SsptTemporalLoadMoments(pixel);
	if (!RtDenoiserFinite4(historyMoments)) return;

	historySignalSum += vec4(max(historySignal.rgb, vec3(0.0)), historySignal.a) * weight;
	historyMomentSum += max(historyMoments.xy, vec2(0.0)) * weight;
	weightSum += weight;
}

void SsptTemporalFallbackTap(
	const in ivec2 pixel,
	const in ivec2 historySize,
	const in ivec2 searchOffset,
	const in vec3 currentPreviousViewNormal,
	const in vec3 currentFallbackViewNormal,
	const in float currentSurfaceClass,
	const in vec3 expectedPreviousViewPosition,
	const in float expectedDepth,
	inout float bestScore,
	inout float bestConfidence,
	inout ivec2 bestPixel
) {
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, historySize))) return;
	vec4 historyMeta = SsptTemporalLoadMeta(pixel);
	if (!RtDenoiserFinite4(historyMeta)) return;
	float markerValid = RtDenoiserMetaValid(historyMeta) * step(0.5, RtDenoiserMetaAge(historyMeta));
	if (markerValid < 0.5) return;

	float historySurfaceClass = RtDenoiserMetaSurfaceClass(historyMeta);
	if (ssptTemporalCurrentClassLocked > 0.5 && RtDenoiserSurfaceClassWeight(currentSurfaceClass, historySurfaceClass) < 0.5) return;
	vec3 historyNormal = PtDecodeOctNormal(historyMeta.xy);
	vec3 historyPreviousViewNormal = normalize(mat3(gbufferPreviousModelView) * historyNormal);
	vec3 historyPreviousViewPosition = SsptTemporalHistoryViewPosition(
		pixel,
		historyMeta
	);
	vec3 historyFallbackViewNormal = SsptTemporalFallbackViewNormal(
		historyNormal,
		historyPreviousViewPosition,
		historySurfaceClass
	);
	float normalAlignment = dot(currentFallbackViewNormal, historyFallbackViewNormal);
	float fallbackAlignmentFloor = mix(
		0.72,
		0.62,
		smoothstep(1.02, 2.35, ssptTemporalGrazingRelax) *
		(1.0 - ssptTemporalCurrentVegetation)
	);
	fallbackAlignmentFloor = mix(
		fallbackAlignmentFloor,
		0.30,
		ssptTemporalCurrentFirstPerson
	);
	if (normalAlignment <= fallbackAlignmentFloor) return;
	float normalWeight = RtDenoiserNormalWeight(currentFallbackViewNormal, historyFallbackViewNormal);
	normalWeight = max(
		normalWeight,
		RtDenoiserGrazingSurfaceFloor(
			RtDenoiserSurfaceClassWeight(currentSurfaceClass, historySurfaceClass),
			ssptTemporalGrazingRelax
		) * (1.0 - ssptTemporalCurrentVegetation)
	);
	normalWeight = max(
		normalWeight,
		RtDenoiserSurfaceClassWeight(currentSurfaceClass, historySurfaceClass) *
			ssptTemporalCurrentFirstPerson * 0.24
	);

	float geometryConfidence;
	float geometryScore;
	if (ssptTemporalCurrentVegetation > 0.5) {
		float relativeDepthError = abs(historyMeta.z - expectedDepth) / max(expectedDepth, 0.25);
		float depthFar = mix(0.10, 0.14, ssptTemporalCurrentFoliage);
		geometryConfidence = 1.0 - smoothstep(depthFar * 0.15, depthFar, relativeDepthError);
		geometryScore = relativeDepthError / depthFar;
	} else {
		vec3 positionDelta = historyPreviousViewPosition - expectedPreviousViewPosition;
		float planeDistance = max(
			abs(dot(positionDelta, currentPreviousViewNormal)),
			abs(dot(positionDelta, historyPreviousViewNormal))
		);
		float planeTolerance = (0.016 + max(expectedDepth, historyMeta.z) * 0.00055) * ssptTemporalGrazingRelax;
		planeTolerance *= mix(1.0, 3.0, ssptTemporalCurrentFirstPerson);
		geometryConfidence = exp2(-planeDistance / max(planeTolerance, 1.0e-4));
		geometryConfidence *= mix(
			step(planeDistance, planeTolerance * 5.0),
			1.0 - smoothstep(planeTolerance * 3.0, planeTolerance * 8.0, planeDistance),
			ssptTemporalCurrentFirstPerson
		);
		geometryConfidence *= RtDenoiserRelativeDepthWeight(
			expectedDepth,
			historyMeta.z,
			mix(0.08, 0.12, ssptTemporalCurrentFirstPerson),
			mix(0.45, 0.72, ssptTemporalCurrentFirstPerson)
		);
		geometryScore = planeDistance / max(planeTolerance, 1.0e-4);
	}
	float confidence = markerValid * normalWeight * geometryConfidence;
	float confidenceFloor = mix(0.10, 0.018, ssptTemporalCurrentFirstPerson);
	if (confidence < confidenceFloor) return;

	float screenDistanceSquared = float(searchOffset.x * searchOffset.x + searchOffset.y * searchOffset.y);
	float score = geometryScore
		+ max(1.0 - normalAlignment, 0.0) * 8.0
		+ screenDistanceSquared * 0.05;
	if (score >= bestScore) return;

	bestScore = score;
	bestConfidence = confidence;
	bestPixel = pixel;
}

void main() {
	ivec2 tracePixel = ivec2(gl_GlobalInvocationID.xy);
	ivec2 historySize = SrActiveRaySceneSize(imageSize(img_ptHistoryA));
	ivec2 traceSize = SrActiveRaySceneSize(imageSize(img_ptTrace));
	ivec2 renderSize = max(ivec2(SrRenderSize()), ivec2(1));
	ssptTemporalRenderSize = renderSize;
	ssptTemporalTraceToRenderScale = vec2(renderSize) /
		vec2(max(traceSize, ivec2(1)));
	ssptTemporalHistoryToRenderScale = vec2(renderSize) /
		vec2(max(historySize, ivec2(1)));
	vec2 previousProjectionScale = vec2(
		abs(gbufferPreviousProjection[0][0]) > 1.0e-6 ? gbufferPreviousProjection[0][0] : 1.0,
		abs(gbufferPreviousProjection[1][1]) > 1.0e-6 ? gbufferPreviousProjection[1][1] : 1.0
	);
	ssptTemporalPreviousViewPixelScale = vec2(2.0) /
		(vec2(renderSize) * previousProjectionScale);
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		ssptTemporalPreviousViewBias = (-vec2(1.0) - previousTemporalJitter) /
			previousProjectionScale;
	#else
		ssptTemporalPreviousViewBias = -vec2(1.0) /
			previousProjectionScale;
	#endif
	SsptTemporalPreload(traceSize);
	if (any(greaterThanEqual(tracePixel, historySize))) return;

	ivec2 centerLocalPixel = ivec2(gl_LocalInvocationID.xy) + ivec2(SSPT_TEMPORAL_PREFILTER_RADIUS);
	int centerIndex = SsptTemporalSharedIndex(centerLocalPixel);
	vec4 currentSignal = ssptCurrentSignal[centerIndex];
	vec4 currentGuide = ssptCurrentGuide[centerIndex];
	vec4 currentMaterialAux = ssptCurrentMaterialAux[centerIndex];
	#if FOXY_VOXEL_GI_ACTIVE == 1
		vec2 currentLightmap = ssptCurrentLightmap[centerIndex];
	#endif
	if (currentMaterialAux.w < 0.5) {
		SsptTemporalStore(tracePixel, vec4(0.0), vec4(0.0), vec4(0.0));
		imageStore(img_ptFilteredA, tracePixel, vec4(0.0));
		return;
	}

	int primaryOffsetIndex = int(floor(currentMaterialAux.z + 0.5));
	ivec2 primaryPixel = SrRayPrimaryPixelScaled(
		tracePixel,
		ssptTemporalTraceToRenderScale,
		ssptTemporalRenderSize,
		primaryOffsetIndex
	);
	float primaryDepthRaw = currentMaterialAux.y;
	vec3 currentNormal = PtDecodeOctNormal(currentGuide.xy);
	float currentReactive = currentGuide.w;
	float currentSurfaceClass = floor(currentMaterialAux.x + 0.5);
	float currentSampled = SsptTemporalTracePixelSampled(tracePixel) ? 1.0 : 0.0;
	vec3 currentRaw = currentSignal.rgb;
	float currentRawLuma = currentSignal.a;
	vec2 currentRawMoments = vec2(currentRawLuma, currentRawLuma * currentRawLuma);

	vec2 currentRasterUv = SsptTemporalRasterUvFromRenderPixel(primaryPixel, renderSize);
	vec2 currentViewUv = currentRasterUv;
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		currentViewUv -= temporalJitter * 0.5;
	#endif
	float currentDynamicSurface = 1.0 - step(
		0.5,
		abs(currentSurfaceClass - PT_SURFACE_DYNAMIC)
	);
	float currentFirstPerson = FirstPersonDepthMask(primaryDepthRaw) * currentDynamicSurface;
	ssptTemporalCurrentFirstPerson = currentFirstPerson;
	float currentProjectionDepthRaw = FirstPersonProjectionDepth(
		primaryDepthRaw,
		currentFirstPerson
	);
	vec3 currentViewPos = SsptTemporalViewPos(currentViewUv, currentProjectionDepthRaw);
	float currentDepth = currentGuide.z;
	float temporalSampleScale = SsptTemporalSampleScale();
	float maximumHistory = min(float(FOXY_SSPT_HISTORY_FRAMES) * temporalSampleScale, 256.0);

	vec2 previousSurfaceUv;
	float expectedPreviousDepth;
	vec3 expectedPreviousViewPosition;
	float reprojectionValid = SsptTemporalPreviousUv(
		currentViewPos,
		currentRasterUv,
		currentFirstPerson,
		previousSurfaceUv,
		expectedPreviousDepth,
		expectedPreviousViewPosition
	);
	vec3 currentWorldPreviousViewNormal = normalize(mat3(gbufferPreviousModelView) * currentNormal);
	vec3 currentViewNormal = normalize(transpose(mat3(gbufferModelViewInverse)) * currentNormal);
	vec3 currentPreviousViewNormal = normalize(mix(
		currentWorldPreviousViewNormal,
		currentViewNormal,
		currentFirstPerson
	));
	float currentThinSurface = SsptTemporalThinSurface(currentSurfaceClass);
	float currentVegetationSurface = SsptTemporalVegetationSurface(currentSurfaceClass);
	ssptTemporalCurrentFoliage = SsptTemporalFoliageSurface(currentSurfaceClass);
	ssptTemporalCurrentVegetation = currentVegetationSurface;
	ssptTemporalCurrentClassLocked = max(
		currentDynamicSurface,
		max(currentThinSurface, ssptTemporalCurrentFoliage)
	);
	ssptTemporalGrazingRelax = mix(
		2.35,
		1.0,
		sqrt(Saturate(abs(currentPreviousViewNormal.z)))
	);
	float foliageGapNeighbor = currentSurfaceClass < 0.5
		? SsptTemporalFoliageNeighbor(tracePixel)
		: 0.0;
	vec3 currentFallbackViewNormal = SsptTemporalFallbackViewNormal(
		currentNormal,
		expectedPreviousViewPosition,
		currentSurfaceClass
	);
	vec2 traceCenterUv = (vec2(tracePixel) + vec2(0.5)) / vec2(historySize);
	vec2 previousUv = traceCenterUv + (previousSurfaceUv - currentRasterUv);
	reprojectionValid *= float(previousUv.x >= 0.0 && previousUv.x <= 1.0 && previousUv.y >= 0.0 && previousUv.y <= 1.0);
	reprojectionValid *= 1.0 - smoothstep(0.080, 0.220, max(frameTime, 0.0));
	reprojectionValid *= step(1.5, float(frameCounter));

	vec4 historySignalSum = vec4(0.0);
	vec2 historyMomentSum = vec2(0.0);
	float historyWeight = 0.0;
	if (reprojectionValid > 0.5) {
		vec2 historyPosition = previousUv * vec2(historySize) - vec2(0.5);
		ivec2 historyBase = ivec2(floor(historyPosition));
		vec2 fractionValue = fract(historyPosition);
		for (int tapIndex = 0; tapIndex < 4; tapIndex++) {
			ivec2 offset = ivec2(tapIndex % 2, tapIndex / 2);
			vec2 axisWeight = mix(vec2(1.0) - fractionValue, fractionValue, vec2(offset));
			SsptTemporalHistoryTap(
				historyBase + offset,
				historySize,
				axisWeight.x * axisWeight.y,
				currentNormal,
				currentSurfaceClass,
				currentPreviousViewNormal,
				expectedPreviousViewPosition,
				expectedPreviousDepth,
				historySignalSum,
				historyMomentSum,
				historyWeight
			);
		}
		if (historyWeight < 0.20) {
			ivec2 fallbackCenter = ivec2(floor(historyPosition + vec2(0.5)));
			float bestScore = 1.0e20;
			float bestConfidence = 0.0;
			ivec2 bestPixel = fallbackCenter;
			int fallbackRadius = max(
				ssptTemporalCurrentVegetation,
				ssptTemporalCurrentFirstPerson
			) > 0.5 ? 2 : 1;
			for (int offsetY = -2; offsetY <= 2; offsetY++) {
				for (int offsetX = -2; offsetX <= 2; offsetX++) {
					if (abs(offsetX) > fallbackRadius || abs(offsetY) > fallbackRadius) continue;
					ivec2 searchOffset = ivec2(offsetX, offsetY);
					SsptTemporalFallbackTap(
						fallbackCenter + searchOffset,
						historySize,
						searchOffset,
						currentPreviousViewNormal,
						currentFallbackViewNormal,
						currentSurfaceClass,
						expectedPreviousViewPosition,
						expectedPreviousDepth,
						bestScore,
						bestConfidence,
						bestPixel
					);
				}
			}
			float fallbackConfidenceFloor = mix(
				0.10,
				0.018,
				ssptTemporalCurrentFirstPerson
			);
			if (bestConfidence >= fallbackConfidenceFloor) {
				vec4 bestSignal = SsptTemporalLoadSignal(bestPixel);
				vec4 bestMomentData = SsptTemporalLoadMoments(bestPixel);
				float bestAgeValid = RtDenoiserFinite4(bestSignal)
					? step(0.5, bestSignal.a) * (1.0 - step(257.5, bestSignal.a))
					: 0.0;
				if (bestAgeValid > 0.5 && RtDenoiserFinite4(bestMomentData)) {
					float shortRecovery = max(currentThinSurface, SsptTemporalFoliageSurface(currentSurfaceClass));
					bestSignal = vec4(
						max(bestSignal.rgb, vec3(0.0)),
						mix(bestSignal.a, min(bestSignal.a, 4.0), shortRecovery)
					);
					historySignalSum = bestSignal * bestConfidence;
					historyMomentSum = max(bestMomentData.xy, vec2(0.0)) * bestConfidence;
					historyWeight = bestConfidence;
				}
			}
		}
	}

	float historySupport = mix(
		RtDenoiserHistorySupport(historyWeight),
		smoothstep(0.0, 0.26, historyWeight),
		currentFirstPerson
	);
	float continuitySurface = max(currentVegetationSurface, foliageGapNeighbor);
	float historyAcceptanceThreshold = mix(0.10, 0.02, continuitySurface);
	historyAcceptanceThreshold = mix(
		historyAcceptanceThreshold,
		0.012,
		currentFirstPerson
	);
	float historyAccepted = step(historyAcceptanceThreshold, historyWeight) * step(0.001, historySupport);
	vec4 previousHistory = vec4(0.0);
	vec2 previousMoments = vec2(0.0);
	if (historyAccepted > 0.5) {
		previousHistory = historySignalSum / max(historyWeight, 1.0e-5);
		previousMoments = historyMomentSum / max(historyWeight, 1.0e-5);
	}

	float referenceLuminance = currentRawLuma;
	float referenceStandardDeviation = 0.0;
	if (historyAccepted > 0.5) {
		referenceLuminance = max(previousMoments.x, 0.0);
		referenceStandardDeviation = sqrt(max(
			previousMoments.y - previousMoments.x * previousMoments.x,
			0.0
		));
	}
	#if FOXY_VOXEL_GI_ACTIVE == 0 || FOXY_IRC_MODE == 0
		if (currentSampled < 0.5 && historyAccepted < 0.5) {
			SsptTemporalStore(tracePixel, vec4(0.0), vec4(0.0), vec4(0.0));
			imageStore(img_ptFilteredA, tracePixel, vec4(0.0));
			return;
		}
	#endif

	#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 1
		// IRC shares VRTGI's outer-surface cache handoff without tracing.
		vec3 ircOnlyRadiance = vec3(0.0);
		#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
			vec3 ircOnlyPlayerPosition = (
				gbufferModelViewInverse * vec4(currentViewPos, 1.0)
			).xyz;
			vec3 ircOnlyGridPosition = VoxelGridSceneToGrid(
				ircOnlyPlayerPosition,
				cameraPosition
			) + currentNormal * 0.08;
			float ircOnlyDomainWeight;
			float ircOnlyConfidence;
			vec3 ircOnlyEstimate = IrcSampleOuterSurfaceMode(
				ircOnlyGridPosition,
				currentNormal,
				cameraPosition,
				frameCounter,
				false,
				ircOnlyDomainWeight,
				ircOnlyConfidence
			) * (FOXY_IRRADIANCE_CACHE_STRENGTH / 8.0);
			float ircOnlyValid = clamp(
				ircOnlyDomainWeight * step(0.02, ircOnlyConfidence),
				0.0,
				1.0
			);
			// Alpha carries cache handoff weight; RGB remains unattenuated.
			ircOnlyRadiance = ircOnlyEstimate;
		#endif
		imageStore(img_ptFilteredA, tracePixel, vec4(
			min(max(ircOnlyRadiance, vec3(0.0)), vec3(64.0)),
			ircOnlyValid
		));
		return;
	#endif

	// Sampled VRTGI cells own one fresh observation; others forward validated data.
	vec3 resolvedRadiance = currentRaw;
	vec2 resolvedMoments = currentRawMoments;
	float historyAge = max(currentSampled, 1.0);
	if (historyAccepted > 0.5 && continuitySurface > 0.5) {
		float estimateLuma = RtDenoiserLuma(resolvedRadiance);
		float historyLumaCap = max(estimateLuma * 3.0 + 0.050, 0.120);
		float historyLuma = RtDenoiserLuma(previousHistory.rgb);
		if (historyLuma > historyLumaCap) {
			float historyScale = historyLumaCap / max(historyLuma, 1.0e-5);
			previousHistory.rgb *= historyScale;
			previousMoments.x = min(previousMoments.x, historyLumaCap);
			previousMoments.y = min(previousMoments.y, historyLumaCap * historyLumaCap);
		}
	}

	if (historyAccepted > 0.5) {
		float reactiveHistory = min(maximumHistory, 6.0 * temporalSampleScale);
		float maxHistory = mix(
			maximumHistory,
			reactiveHistory,
			currentReactive * currentDynamicSurface
		);
		float firstPersonHistory = min(
			maximumHistory,
			max(float(FOXY_SSPT_HISTORY_FRAMES) * 0.5, 16.0) *
				clamp(temporalSampleScale, 1.0, 3.0)
		);
		maxHistory = mix(maxHistory, firstPersonHistory, currentFirstPerson);
		float retainedSamples = previousHistory.a * historySupport;
		float targetAge = min(retainedSamples + currentSampled, maxHistory);
		historyAge = max(targetAge, 1.0);
		float temporalAlpha = currentSampled > 0.5
			? currentSampled / historyAge
			: 0.0;
		resolvedRadiance = mix(previousHistory.rgb, currentRaw, temporalAlpha);
		resolvedMoments = mix(previousMoments, currentRawMoments, temporalAlpha);
	} else {
		historyAge = max(currentSampled, 1.0);
	}
	// Bound isolated vegetation observations to prevent one-frame flashes.
	if (historyAccepted > 0.5 && continuitySurface > 0.5) {
		float previousLuma = RtDenoiserLuma(previousHistory.rgb);
		float resolvedLuma = RtDenoiserLuma(resolvedRadiance);
		float maximumStep = min(0.060, 0.012 + previousLuma * 0.030);
		float continuityScale = min(1.0, maximumStep / max(abs(resolvedLuma - previousLuma), 1.0e-5));
		resolvedRadiance = previousHistory.rgb + (resolvedRadiance - previousHistory.rgb) * continuityScale;
	}

	resolvedRadiance = min(max(resolvedRadiance, vec3(0.0)), vec3(64.0));
	resolvedMoments.x = min(max(resolvedMoments.x, 0.0), 64.0);
	resolvedMoments.y = min(max(resolvedMoments.y, resolvedMoments.x * resolvedMoments.x), 4096.0);
	float packedMetaState = RtDenoiserPackMetaState(
		float(primaryOffsetIndex),
		historyAge,
		currentSurfaceClass,
		currentReactive,
		historyAccepted
	);
	vec4 currentMeta = vec4(PtEncodeOctNormal(currentNormal), currentDepth, packedMetaState);
	SsptTemporalStore(
		tracePixel,
		vec4(resolvedRadiance, historyAge),
		currentMeta,
		vec4(resolvedMoments, 0.0, 0.0)
	);

	// Validated neighbour history stabilizes display only and never re-enters history.
	float spatialBootstrapWeight = 1.0 - smoothstep(12.0, 32.0, historyAge);
	vec3 bootstrapSpatialRadiance = resolvedRadiance;
	vec2 bootstrapSpatialMoments = resolvedMoments;
	if (spatialBootstrapWeight > 0.0) {
		vec3 bootstrapRadianceSum = resolvedRadiance;
		float resolvedLuminance = RtDenoiserLuma(resolvedRadiance);
		vec2 bootstrapMomentSum = vec2(
			resolvedLuminance,
			resolvedLuminance * resolvedLuminance
		);
		float bootstrapWeightSum = 1.0;
		SsptTemporalBootstrapTap(tracePixel, centerLocalPixel, ivec2(-1,  0), currentNormal, currentDepth, currentSurfaceClass, referenceLuminance, referenceStandardDeviation, 0.55, bootstrapRadianceSum, bootstrapMomentSum, bootstrapWeightSum);
		SsptTemporalBootstrapTap(tracePixel, centerLocalPixel, ivec2( 1,  0), currentNormal, currentDepth, currentSurfaceClass, referenceLuminance, referenceStandardDeviation, 0.55, bootstrapRadianceSum, bootstrapMomentSum, bootstrapWeightSum);
		SsptTemporalBootstrapTap(tracePixel, centerLocalPixel, ivec2( 0, -1), currentNormal, currentDepth, currentSurfaceClass, referenceLuminance, referenceStandardDeviation, 0.55, bootstrapRadianceSum, bootstrapMomentSum, bootstrapWeightSum);
		SsptTemporalBootstrapTap(tracePixel, centerLocalPixel, ivec2( 0,  1), currentNormal, currentDepth, currentSurfaceClass, referenceLuminance, referenceStandardDeviation, 0.55, bootstrapRadianceSum, bootstrapMomentSum, bootstrapWeightSum);
		SsptTemporalBootstrapTap(tracePixel, centerLocalPixel, ivec2(-1, -1), currentNormal, currentDepth, currentSurfaceClass, referenceLuminance, referenceStandardDeviation, 0.34, bootstrapRadianceSum, bootstrapMomentSum, bootstrapWeightSum);
		SsptTemporalBootstrapTap(tracePixel, centerLocalPixel, ivec2( 1, -1), currentNormal, currentDepth, currentSurfaceClass, referenceLuminance, referenceStandardDeviation, 0.34, bootstrapRadianceSum, bootstrapMomentSum, bootstrapWeightSum);
		SsptTemporalBootstrapTap(tracePixel, centerLocalPixel, ivec2(-1,  1), currentNormal, currentDepth, currentSurfaceClass, referenceLuminance, referenceStandardDeviation, 0.34, bootstrapRadianceSum, bootstrapMomentSum, bootstrapWeightSum);
		SsptTemporalBootstrapTap(tracePixel, centerLocalPixel, ivec2( 1,  1), currentNormal, currentDepth, currentSurfaceClass, referenceLuminance, referenceStandardDeviation, 0.34, bootstrapRadianceSum, bootstrapMomentSum, bootstrapWeightSum);
		bootstrapSpatialRadiance = bootstrapRadianceSum / max(bootstrapWeightSum, 1.0e-5);
		bootstrapSpatialMoments = bootstrapMomentSum / max(bootstrapWeightSum, 1.0e-5);
	}
	vec3 bootstrapRadiance = mix(
		resolvedRadiance,
		bootstrapSpatialRadiance,
		spatialBootstrapWeight
	);
	vec2 bootstrapMoments = mix(
		resolvedMoments,
		bootstrapSpatialMoments,
		spatialBootstrapWeight
	);
	float bootstrapAge = historyAge;
	// Deterministic receiver light supplies the bounded cold estimator.
	float coldStartVisibility = smoothstep(1.0, 12.0, historyAge);
	#if FOXY_VOXEL_GI_ACTIVE == 1
		if (coldStartVisibility < 0.99999) {
			vec3 fallbackSkyFluence = vec3(0.0);
			#if !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
				fallbackSkyFluence = DecodeBufferColor(texelFetch(
					colortex7,
					SkyUpperHemisphereFluenceTexel(),
					0
				).rgb);
			#endif
			vec3 coldStartFallback = VrtgiReceiverFallbackRadiance(
				currentLightmap,
				currentNormal,
				fallbackSkyFluence
			);
			vec3 coldStartPlayerPosition = (
				gbufferModelViewInverse * vec4(currentViewPos, 1.0)
			).xyz;
			float coldStartOriginBias = max(
				0.025,
				max(-currentViewPos.z, 1.0e-3) * 0.00065
			);
			float coldStartDomainWeight = VrtgiReceiverDomainWeight(
				coldStartPlayerPosition + currentNormal * coldStartOriginBias,
				cameraPosition
			);
			coldStartFallback *= 1.0 - coldStartDomainWeight;
			float fallbackLuma = RtDenoiserLuma(coldStartFallback);
			float inverseColdVisibility = 1.0 - coldStartVisibility;
			vec2 sourceBootstrapMoments = bootstrapMoments;
			bootstrapRadiance = mix(
				coldStartFallback,
				bootstrapRadiance,
				coldStartVisibility
			);
			bootstrapMoments = vec2(
				inverseColdVisibility * fallbackLuma +
					coldStartVisibility * sourceBootstrapMoments.x,
				inverseColdVisibility * inverseColdVisibility *
					fallbackLuma * fallbackLuma +
				2.0 * inverseColdVisibility * coldStartVisibility *
					fallbackLuma * sourceBootstrapMoments.x +
				coldStartVisibility * coldStartVisibility *
					sourceBootstrapMoments.y
			);
		}
	#else
		bootstrapRadiance *= coldStartVisibility;
		bootstrapMoments *= vec2(
			coldStartVisibility,
			coldStartVisibility * coldStartVisibility
		);
	#endif
	#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
		float cacheHandoffAge = max(
			float(FOXY_SSPT_HISTORY_FRAMES),
			2.0
		);
		float cacheBootstrap = 1.0 - smoothstep(
			2.0,
			max(cacheHandoffAge, 2.0),
			historyAge
		);
		if (cacheBootstrap > 1.0e-4) {
			vec3 currentPlayerPosition = (
				gbufferModelViewInverse * vec4(currentViewPos, 1.0)
			).xyz;
			vec3 cacheGridPosition = VoxelGridSceneToGrid(
				currentPlayerPosition,
				cameraPosition
			) + currentNormal * 0.08;
			float cacheDomainWeight;
			float cacheConfidence;
			vec3 cacheEstimate = IrcSampleOuterSurfaceMode(
				cacheGridPosition,
				currentNormal,
				cameraPosition,
				frameCounter,
				false,
				cacheDomainWeight,
				cacheConfidence
			) * (FOXY_IRRADIANCE_CACHE_STRENGTH / 8.0);
			cacheBootstrap *= cacheDomainWeight * step(0.02, cacheConfidence);
			bootstrapRadiance = mix(bootstrapRadiance, cacheEstimate, cacheBootstrap);
			float cacheLuma = RtDenoiserLuma(cacheEstimate);
			bootstrapMoments = mix(
				bootstrapMoments,
				vec2(cacheLuma, cacheLuma * cacheLuma),
				cacheBootstrap
			);
		}
	#endif
	float bootstrapVariance = max(
		bootstrapMoments.y - bootstrapMoments.x * bootstrapMoments.x,
		0.0
	) / max(bootstrapAge, 1.0);
	imageStore(img_ptFilteredA, tracePixel, vec4(
		min(max(bootstrapRadiance, vec3(0.0)), vec3(64.0)),
		clamp(bootstrapVariance, 0.0, 4096.0)
	));
}

#undef SSPT_TEMPORAL_GROUP_SIZE
#undef SSPT_TEMPORAL_PREFILTER_RADIUS
#undef SSPT_TEMPORAL_TILE_SIDE
#undef SSPT_TEMPORAL_TILE_AREA
