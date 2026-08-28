#include "/lib/settings.glsl"

#ifndef FOXY_SSPT_ATROUS_GROUP_SIZE
	#define FOXY_SSPT_ATROUS_GROUP_SIZE 16
#endif

layout(
	local_size_x = FOXY_SSPT_ATROUS_GROUP_SIZE,
	local_size_y = FOXY_SSPT_ATROUS_GROUP_SIZE,
	local_size_z = 1
) in;
const vec2 workGroupsRender = vec2(
	FOXY_RAY_RESOLUTION,
	FOXY_RAY_RESOLUTION
);

layout(rgba16f) readonly uniform image2D img_ptHistoryMetaA;
layout(rgba16f) readonly uniform image2D img_ptHistoryMetaB;
#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
	layout(rgba16f) readonly uniform image2D img_ptHistoryA;
	layout(rgba16f) readonly uniform image2D img_ptHistoryB;
	layout(rg16f) readonly uniform image2D img_ptMomentsA;
	layout(rg16f) readonly uniform image2D img_ptMomentsB;
#endif

#ifdef FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT
	#if FOXY_SSPT_ATROUS_PASS == 0 || FOXY_SSPT_ATROUS_PASS == 2 || FOXY_SSPT_ATROUS_PASS == 4 || FOXY_SSPT_ATROUS_PASS == 6
		layout(rgba16f) readonly uniform image2D img_ptFilteredA;
		layout(rgba16f) writeonly uniform image2D img_ptFiltered;
	#else
		layout(rgba16f) readonly uniform image2D img_ptFiltered;
		layout(rgba16f) writeonly uniform image2D img_ptFilteredA;
	#endif
#else
	#if FOXY_SSPT_ATROUS_PASS == 0
		layout(rgba16f) writeonly uniform image2D img_ptFilteredA;
	#elif FOXY_SSPT_ATROUS_PASS == 1 || FOXY_SSPT_ATROUS_PASS == 3 || FOXY_SSPT_ATROUS_PASS == 5
		layout(rgba16f) readonly uniform image2D img_ptFilteredA;
		layout(rgba16f) writeonly uniform image2D img_ptFiltered;
	#else
		layout(rgba16f) readonly uniform image2D img_ptFiltered;
		layout(rgba16f) writeonly uniform image2D img_ptFilteredA;
	#endif
#endif

uniform mat4 gbufferModelView;
uniform mat4 gbufferProjection;
uniform sampler2D depthtex0;
uniform float viewWidth;
uniform float viewHeight;
uniform vec2 temporalJitter;
uniform int frameCounter;

#include "/lib/math.glsl"
#include "/lib/sr.glsl"
#include "/lib/rt_denoiser.glsl"
#include "/lib/first_person_depth.glsl"
#define PT_GBUFFER_READ
#include "/lib/pt_gbuffer.glsl"
#undef PT_GBUFFER_READ

#define SSPT_FILTER_GROUP_SIZE FOXY_SSPT_ATROUS_GROUP_SIZE
#define SSPT_FILTER_JITTER_RADIUS 0
#define SSPT_FILTER_RADIUS (FOXY_SSPT_ATROUS_STEP + SSPT_FILTER_JITTER_RADIUS)
#define SSPT_FILTER_TILE_SIDE (SSPT_FILTER_GROUP_SIZE + SSPT_FILTER_RADIUS * 2)
#define SSPT_FILTER_TILE_AREA (SSPT_FILTER_TILE_SIDE * SSPT_FILTER_TILE_SIDE)

// Sparse stages alternate axial support; the widest stage closes angular support.
#ifdef FOXY_SSPT_ATROUS_FULL_KERNEL

	#define SSPT_CENTER_WEIGHT 0.2500
	#define SSPT_AXIS_WEIGHT 0.1250
	#define SSPT_DIAGONAL_WEIGHT 0.0625
	#define SSPT_NEIGHBOR_KERNEL_MASS 0.7500
#elif defined(FOXY_SSPT_ATROUS_CROSS_KERNEL)
	#define SSPT_CENTER_WEIGHT 0.5000
	#define SSPT_AXIS_WEIGHT 0.1250
	#define SSPT_NEIGHBOR_KERNEL_MASS 0.5000
#else
	#define SSPT_CENTER_WEIGHT 0.5000
	#define SSPT_DIRECTION_WEIGHT 0.2500
	#define SSPT_NEIGHBOR_KERNEL_MASS 0.5000
#endif

#if FOXY_SSPT_ATROUS_SHARED == 1
shared vec4 ssptSharedSignal[SSPT_FILTER_TILE_AREA];
// Shared guides keep decoded normals and scalar positions.
shared vec4 ssptSharedViewGuide[SSPT_FILTER_TILE_AREA];
shared float ssptSharedViewPositionX[SSPT_FILTER_TILE_AREA];
shared float ssptSharedViewPositionY[SSPT_FILTER_TILE_AREA];
shared float ssptSharedViewPositionZ[SSPT_FILTER_TILE_AREA];
// Valid ages are [1,15]; age zero is the shared-path invalid marker.
shared float ssptSharedMetaAge[SSPT_FILTER_TILE_AREA];
shared float ssptSharedMetaSurfaceClass[SSPT_FILTER_TILE_AREA];
shared float ssptSharedFirstPerson[SSPT_FILTER_TILE_AREA];
	#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
shared vec4 ssptSharedMoments[SSPT_FILTER_TILE_AREA];
	#endif
#endif

// Per-invocation reconstruction constants shared by all taps.
ivec2 ssptAtrousFilterSize;
ivec2 ssptAtrousRenderSize;
vec2 ssptAtrousRayToRenderScale;
vec2 ssptAtrousViewPixelScale;
vec2 ssptAtrousViewBias;
float ssptAtrousCenterGrazingRelax;

vec3 SsptAtrousViewPosition(
	const in ivec2 tracePixel,
	const in float viewDepth,
	const in float primaryOffsetIndex
);

float SsptAtrousFirstPerson(
	const in ivec2 tracePixel,
	const in vec4 meta
);

float SsptAtrousTemporalSampleCount(const in float historyAge) {
	return max(historyAge, 1.0);
}

bool SsptAtrousReadsA() {
	return (frameCounter % 2) == 0;
}

#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
	vec4 SsptAtrousHistorySignal(const in ivec2 pixel) {
		if (SsptAtrousReadsA()) return imageLoad(img_ptHistoryA, pixel);
		return imageLoad(img_ptHistoryB, pixel);
	}
#endif

vec4 SsptAtrousMeta(const in ivec2 pixel) {
	if (SsptAtrousReadsA()) return imageLoad(img_ptHistoryMetaA, pixel);
	return imageLoad(img_ptHistoryMetaB, pixel);
}

#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
	vec4 SsptAtrousMoments(const in ivec2 pixel) {
		if (SsptAtrousReadsA()) return imageLoad(img_ptMomentsA, pixel);
		return imageLoad(img_ptMomentsB, pixel);
	}
#endif

vec4 SsptAtrousSource(const in ivec2 pixel) {
	#ifdef FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT
		#if FOXY_SSPT_ATROUS_PASS == 0 || FOXY_SSPT_ATROUS_PASS == 2 || FOXY_SSPT_ATROUS_PASS == 4 || FOXY_SSPT_ATROUS_PASS == 6
			return imageLoad(img_ptFilteredA, pixel);
		#else
			return imageLoad(img_ptFiltered, pixel);
		#endif
	#else
		#if FOXY_SSPT_ATROUS_PASS == 0
			return SsptAtrousHistorySignal(pixel);
		#elif FOXY_SSPT_ATROUS_PASS == 1 || FOXY_SSPT_ATROUS_PASS == 3 || FOXY_SSPT_ATROUS_PASS == 5
			return imageLoad(img_ptFilteredA, pixel);
		#else
			return imageLoad(img_ptFiltered, pixel);
		#endif
	#endif
}

ivec2 SsptAtrousOutputSize() {
	#ifdef FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT
		#if FOXY_SSPT_ATROUS_PASS == 0 || FOXY_SSPT_ATROUS_PASS == 2 || FOXY_SSPT_ATROUS_PASS == 4 || FOXY_SSPT_ATROUS_PASS == 6
			return SrActiveRaySceneSize(imageSize(img_ptFiltered));
		#else
			return SrActiveRaySceneSize(imageSize(img_ptFilteredA));
		#endif
	#else
		#if FOXY_SSPT_ATROUS_PASS == 1 || FOXY_SSPT_ATROUS_PASS == 3 || FOXY_SSPT_ATROUS_PASS == 5
			return SrActiveRaySceneSize(imageSize(img_ptFiltered));
		#else
			return SrActiveRaySceneSize(imageSize(img_ptFilteredA));
		#endif
	#endif
}

void SsptAtrousStore(const in ivec2 pixel, const in vec4 value) {
	#ifdef FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT
		#if FOXY_SSPT_ATROUS_PASS == 0 || FOXY_SSPT_ATROUS_PASS == 2 || FOXY_SSPT_ATROUS_PASS == 4 || FOXY_SSPT_ATROUS_PASS == 6
			imageStore(img_ptFiltered, pixel, value);
		#else
			imageStore(img_ptFilteredA, pixel, value);
		#endif
	#else
		#if FOXY_SSPT_ATROUS_PASS == 1 || FOXY_SSPT_ATROUS_PASS == 3 || FOXY_SSPT_ATROUS_PASS == 5
			imageStore(img_ptFiltered, pixel, value);
		#else
			imageStore(img_ptFilteredA, pixel, value);
		#endif
	#endif
}

#if FOXY_SSPT_ATROUS_SHARED == 1
int SsptAtrousSharedIndex(const in ivec2 localPixel) {
	return localPixel.y * SSPT_FILTER_TILE_SIDE + localPixel.x;
}

void SsptAtrousPreload(const in ivec2 filterSize) {
	ivec2 groupBase = ivec2(gl_WorkGroupID.xy) * SSPT_FILTER_GROUP_SIZE - ivec2(SSPT_FILTER_RADIUS);
	int localIndex = int(gl_LocalInvocationIndex);
	for (int tileIndex = localIndex; tileIndex < SSPT_FILTER_TILE_AREA; tileIndex += SSPT_FILTER_GROUP_SIZE * SSPT_FILTER_GROUP_SIZE) {
		ivec2 tilePixel = ivec2(tileIndex % SSPT_FILTER_TILE_SIDE, tileIndex / SSPT_FILTER_TILE_SIDE);
		ivec2 sourcePixel = clamp(groupBase + tilePixel, ivec2(0), filterSize - ivec2(1));
		ssptSharedSignal[tileIndex] = SsptAtrousSource(sourcePixel);
		vec4 sourceMeta = SsptAtrousMeta(sourcePixel);
		bool sourceMetaFinite = RtDenoiserFinite4(sourceMeta);
		float sourceMetaValid = sourceMetaFinite
			? RtDenoiserMetaValid(sourceMeta)
			: 0.0;
		ssptSharedMetaAge[tileIndex] = sourceMetaValid > 0.5
			? RtDenoiserMetaAge(sourceMeta)
			: 0.0;
		ssptSharedMetaSurfaceClass[tileIndex] = sourceMetaFinite
			? RtDenoiserMetaSurfaceClass(sourceMeta)
			: 0.0;
		vec3 sourceViewNormal = vec3(0.0, 0.0, 1.0);
		float sourceDepth = sourceMetaFinite ? max(sourceMeta.z, 1.0e-3) : 1.0;
		float sourceOffsetIndex = sourceMetaFinite
			? RtDenoiserMetaPrimaryOffsetIndex(sourceMeta)
			: 0.0;
		ssptSharedFirstPerson[tileIndex] = sourceMetaValid > 0.5
			? SsptAtrousFirstPerson(sourcePixel, sourceMeta)
			: 0.0;
		if (sourceMetaValid > 0.5) {
			sourceViewNormal = normalize(mat3(gbufferModelView) * PtDecodeOctNormal(sourceMeta.xy));
		}
		ssptSharedViewGuide[tileIndex] = vec4(sourceViewNormal, sourceDepth);
		vec3 sourceViewPosition = SsptAtrousViewPosition(
			sourcePixel,
			sourceDepth,
			sourceOffsetIndex
		);
		ssptSharedViewPositionX[tileIndex] = sourceViewPosition.x;
		ssptSharedViewPositionY[tileIndex] = sourceViewPosition.y;
		ssptSharedViewPositionZ[tileIndex] = sourceViewPosition.z;
		#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
			ssptSharedMoments[tileIndex] = SsptAtrousMoments(sourcePixel);
		#endif
	}
	memoryBarrierShared();
	barrier();
}
#endif

vec3 SsptAtrousViewPosition(
	const in ivec2 tracePixel,
	const in float viewDepth,
	const in float primaryOffsetIndex
) {
	vec2 primaryPixel = vec2(SrRayPrimaryPixelScaled(
		tracePixel,
		ssptAtrousRayToRenderScale,
		ssptAtrousRenderSize,
		int(floor(primaryOffsetIndex + 0.5))
	));
	vec2 viewRay = (primaryPixel + vec2(0.5)) *
		ssptAtrousViewPixelScale + ssptAtrousViewBias;
	return vec3(viewRay * viewDepth, -viewDepth);
}

float SsptAtrousFirstPerson(
	const in ivec2 tracePixel,
	const in vec4 meta
) {
	ivec2 primaryPixel = SrRayPrimaryPixelScaled(
		tracePixel,
		ssptAtrousRayToRenderScale,
		ssptAtrousRenderSize,
		int(floor(RtDenoiserMetaPrimaryOffsetIndex(meta) + 0.5))
	);
	float rawDepth = texelFetch(depthtex0, primaryPixel, 0).r;
	float dynamicSurface = 1.0 - step(
		0.5,
		abs(RtDenoiserMetaSurfaceClass(meta) - PT_SURFACE_DYNAMIC)
	);
	return FirstPersonDepthMask(rawDepth) * dynamicSurface;
}

float SsptAtrousThinSurface(const in float surfaceClass) {
	float plant = 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_PLANT));
	float strand = 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_STRAND));
	return max(plant, strand);
}

vec3 SsptAtrousThinViewNormal(const in vec3 viewPosition) {
	float viewLengthSquared = dot(viewPosition, viewPosition);
	if (viewLengthSquared <= 1.0e-6) return vec3(0.0, 0.0, 1.0);
	vec3 viewToCamera = -viewPosition * inversesqrt(viewLengthSquared);
	vec3 strandTangent = normalize(mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0));
	vec3 projectedNormal = viewToCamera - strandTangent * dot(viewToCamera, strandTangent);
	float projectedLengthSquared = dot(projectedNormal, projectedNormal);
	return projectedLengthSquared > 1.0e-6
		? projectedNormal * inversesqrt(projectedLengthSquared)
		: viewToCamera;
}

void SsptAtrousTap(
	const in ivec2 centerPixel,
	const in ivec2 centerLocalPixel,
	const in ivec2 unitOffset,
	const in float kernelWeight,
	const in vec3 centerViewNormal,
	const in vec3 centerViewPosition,
	const in float centerDepth,
	const in float centerSurfaceClass,
	const in float centerLuminance,
	const in float centerVariance,
	const in float centerFirstPerson,
	const in float filterAmount,
	inout vec3 radianceSum,
	inout float varianceNumerator,
	inout float weightSum,
	inout float geometrySupportSum
) {
	ivec2 tapOffset = unitOffset * FOXY_SSPT_ATROUS_STEP;
	ivec2 samplePixel = centerPixel + tapOffset;
	if (any(lessThan(samplePixel, ivec2(0))) || any(greaterThanEqual(samplePixel, ssptAtrousFilterSize))) return;
	vec4 sampleSignal;
	vec4 sampleViewGuide;
	vec3 sampleViewPosition;
	float sampleAge;
	float sampleSurfaceClass;
	float markerValid;
	#if FOXY_SSPT_ATROUS_SHARED == 0
		vec4 sampleMeta;
	#endif
	#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
		vec4 sampleMoments;
	#endif
	#if FOXY_SSPT_ATROUS_SHARED == 1
		ivec2 sampleLocalPixel = centerLocalPixel + tapOffset;
		int sampleIndex = SsptAtrousSharedIndex(sampleLocalPixel);
		sampleSignal = ssptSharedSignal[sampleIndex];
		sampleViewGuide = ssptSharedViewGuide[sampleIndex];
		sampleViewPosition = vec3(
			ssptSharedViewPositionX[sampleIndex],
			ssptSharedViewPositionY[sampleIndex],
			ssptSharedViewPositionZ[sampleIndex]
		);
		#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
			sampleMoments = ssptSharedMoments[sampleIndex];
			sampleAge = sampleSignal.a;
		#else
			sampleAge = ssptSharedMetaAge[sampleIndex];
		#endif
		sampleSurfaceClass = ssptSharedMetaSurfaceClass[sampleIndex];
		markerValid = step(0.5, ssptSharedMetaAge[sampleIndex]);
	#else
		sampleSignal = SsptAtrousSource(samplePixel);
		sampleMeta = SsptAtrousMeta(samplePixel);
		#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
			sampleMoments = SsptAtrousMoments(samplePixel);
			sampleAge = sampleSignal.a;
		#else
			sampleAge = RtDenoiserMetaAge(sampleMeta);
		#endif
		sampleSurfaceClass = RtDenoiserMetaSurfaceClass(sampleMeta);
		markerValid = RtDenoiserMetaValid(sampleMeta);
	#endif
	// Only pass zero consumes unvalidated temporal payloads.
	#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
		#if FOXY_SSPT_ATROUS_SHARED == 1
			bool sampleFinite = RtDenoiserFinite4(sampleSignal)
				&& RtDenoiserFinite4(sampleMoments);
		#else
			bool sampleFinite = RtDenoiserFinite4(sampleSignal)
				&& RtDenoiserFinite4(sampleMeta)
				&& RtDenoiserFinite4(sampleMoments);
		#endif
	#else
		#if FOXY_SSPT_ATROUS_SHARED == 1
			bool sampleFinite = true;
		#else
			bool sampleFinite = RtDenoiserFinite4(sampleMeta);
		#endif
	#endif
	if (sampleAge < 0.5 || !sampleFinite) return;
	if (markerValid < 0.5) return;
	#if FOXY_SSPT_ATROUS_SHARED == 1
		vec3 sampleViewNormal = sampleViewGuide.xyz;
		float sampleDepth = sampleViewGuide.w;
	#else
		vec3 sampleViewNormal = normalize(mat3(gbufferModelView) * PtDecodeOctNormal(sampleMeta.xy));
		float sampleDepth = max(sampleMeta.z, 1.0e-3);
	#endif
	#if FOXY_SSPT_ATROUS_SHARED == 0
		sampleViewPosition = SsptAtrousViewPosition(
			samplePixel,
			sampleDepth,
			RtDenoiserMetaPrimaryOffsetIndex(sampleMeta)
		);
	#endif
	vec3 positionDelta = sampleViewPosition - centerViewPosition;
	float planeDistance = max(abs(dot(positionDelta, centerViewNormal)), abs(dot(positionDelta, sampleViewNormal)));
	float radius = sqrt(float(FOXY_SSPT_ATROUS_STEP));
	float planeTolerance = (0.018 + max(centerDepth, sampleDepth) * 0.00055 * (1.0 + radius * 0.45)) * ssptAtrousCenterGrazingRelax;
	float sameSurfaceClass = RtDenoiserSurfaceClassWeight(
		centerSurfaceClass,
		sampleSurfaceClass
	);
	float centerDynamic = 1.0 - step(0.5, abs(centerSurfaceClass - PT_SURFACE_DYNAMIC));
	float sampleDynamic = 1.0 - step(0.5, abs(sampleSurfaceClass - PT_SURFACE_DYNAMIC));
	float classBoundaryWeight = mix(
		1.0,
		sameSurfaceClass,
		max(centerDynamic, sampleDynamic)
	);
	float thinSurface = SsptAtrousThinSurface(centerSurfaceClass) * sameSurfaceClass;
	float physicalNormalAlignment = dot(centerViewNormal, sampleViewNormal);
	float planeExponent = -planeDistance / max(planeTolerance, 1.0e-4);
	float normalAlignment = physicalNormalAlignment;
	if (thinSurface > 0.5) {
		float thinDepthWeight = RtDenoiserRelativeDepthWeight(
			centerDepth,
			sampleDepth,
			0.010,
			0.10
		);
		planeExponent = log2(max(thinDepthWeight, 1.0e-6));
		float envelopeNormalAlignment = dot(
			SsptAtrousThinViewNormal(centerViewPosition),
			SsptAtrousThinViewNormal(sampleViewPosition)
		);
		normalAlignment = max(physicalNormalAlignment, envelopeNormalAlignment);
	} else if (centerDynamic > 0.5) {
		float dynamicDepthWeight = RtDenoiserRelativeDepthWeight(
			centerDepth,
			sampleDepth,
			0.025,
			0.18
		);
		planeExponent = log2(max(dynamicDepthWeight, 1.0e-6));
	}
	float staticNormalWeight = smoothstep(0.84, 0.975, normalAlignment);
	staticNormalWeight *= staticNormalWeight;
	float dynamicNormalWeight = smoothstep(-0.15, 0.80, normalAlignment);
	float normalWeight = mix(staticNormalWeight, dynamicNormalWeight, centerDynamic);
	normalWeight = max(
		normalWeight,
		RtDenoiserGrazingSurfaceFloor(
			sameSurfaceClass,
			ssptAtrousCenterGrazingRelax
		)
	);
	float sampleLuminance = RtDenoiserLuma(sampleSignal.rgb);
	#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
		float sampleVariance = max(
			sampleMoments.y - sampleMoments.x * sampleMoments.x,
			0.0
		) / SsptAtrousTemporalSampleCount(sampleAge);
	#else
		float sampleVariance = abs(sampleSignal.a);
	#endif
	float standardDeviation = sqrt(max(centerVariance + sampleVariance, 1.0e-6));
	float luminancePhi = max(
		0.045 + 0.130 * max(centerLuminance, sampleLuminance),
		standardDeviation * 2.25
	);
	float relativeLuminanceExponent = 0.0;
	float luminanceRejection = mix(1.0, 0.35, centerDynamic) *
		(1.0 - centerFirstPerson);
	#if FOXY_SSPT_ATROUS_STEP >= 8
		float relativeLuminanceScale = max(max(centerLuminance, sampleLuminance), 0.002);
		float relativeLuminanceContrast = abs(sampleLuminance - centerLuminance) /
			relativeLuminanceScale;
		float relativeNoise = standardDeviation / relativeLuminanceScale;
		float relativePhi = mix(0.22, 0.85, Saturate(relativeNoise * 0.5));
		relativeLuminanceExponent = -relativeLuminanceContrast / relativePhi *
			luminanceRejection;
	#endif
	float guideWeight = exp2(
		planeExponent - abs(sampleLuminance - centerLuminance) * luminanceRejection /
		max(luminancePhi, 1.0e-4) + relativeLuminanceExponent
	);
	// Pass zero owns the persistent planar-support marker.
	#if FOXY_SSPT_ATROUS_PASS == 0
		geometrySupportSum += kernelWeight * markerValid * guideWeight * normalWeight * classBoundaryWeight;
	#endif

	float weight = kernelWeight * filterAmount * markerValid * guideWeight * normalWeight * classBoundaryWeight;
	if (weight <= 1.0e-6) return;
	radianceSum += max(sampleSignal.rgb, vec3(0.0)) * weight;
	varianceNumerator += sampleVariance * weight * weight;
	weightSum += weight;
}

void main() {
	ivec2 filterSize = SsptAtrousOutputSize();
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, filterSize))) return;

	#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 1
		// IRC bypasses spatial filtering and preserves its payload.
		SsptAtrousStore(pixel, SsptAtrousSource(pixel));
		return;
	#endif

	ssptAtrousFilterSize = filterSize;
	ssptAtrousRenderSize = max(ivec2(SrRenderSize()), ivec2(1));
	ssptAtrousRayToRenderScale = vec2(ssptAtrousRenderSize) /
		vec2(max(filterSize, ivec2(1)));
	vec2 projectionScale = vec2(
		abs(gbufferProjection[0][0]) > 1.0e-6 ? gbufferProjection[0][0] : 1.0,
		abs(gbufferProjection[1][1]) > 1.0e-6 ? gbufferProjection[1][1] : 1.0
	);
	ssptAtrousViewPixelScale = vec2(2.0) /
		(vec2(ssptAtrousRenderSize) * projectionScale);
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		ssptAtrousViewBias = (-vec2(1.0) - temporalJitter) /
			projectionScale;
	#else
		ssptAtrousViewBias = -vec2(1.0) / projectionScale;
	#endif
	#if FOXY_SSPT_ATROUS_SHARED == 1
		SsptAtrousPreload(filterSize);
	#endif

	vec4 centerSignal;
	vec4 centerViewGuide;
	vec3 centerViewPosition;
	float centerAge;
	float centerSurfaceClass;
	float centerValid;
	float centerFirstPerson = 0.0;
	#if FOXY_SSPT_ATROUS_SHARED == 0
		vec4 centerMeta;
	#endif
	#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
		vec4 centerMoments;
	#endif
	ivec2 centerLocalPixel = ivec2(gl_LocalInvocationID.xy) + ivec2(SSPT_FILTER_RADIUS);
	#if FOXY_SSPT_ATROUS_SHARED == 1
		int centerIndex = SsptAtrousSharedIndex(centerLocalPixel);
		centerSignal = ssptSharedSignal[centerIndex];
		centerViewGuide = ssptSharedViewGuide[centerIndex];
		centerViewPosition = vec3(
			ssptSharedViewPositionX[centerIndex],
			ssptSharedViewPositionY[centerIndex],
			ssptSharedViewPositionZ[centerIndex]
		);
		#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
			centerMoments = ssptSharedMoments[centerIndex];
			centerAge = centerSignal.a;
		#else
			centerAge = ssptSharedMetaAge[centerIndex];
		#endif
		centerSurfaceClass = ssptSharedMetaSurfaceClass[centerIndex];
		centerValid = step(0.5, ssptSharedMetaAge[centerIndex]);
		centerFirstPerson = ssptSharedFirstPerson[centerIndex];
	#else
		centerSignal = SsptAtrousSource(pixel);
		centerMeta = SsptAtrousMeta(pixel);
		#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
			centerMoments = SsptAtrousMoments(pixel);
			centerAge = centerSignal.a;
		#else
			centerAge = RtDenoiserMetaAge(centerMeta);
		#endif
		centerSurfaceClass = RtDenoiserMetaSurfaceClass(centerMeta);
		centerValid = RtDenoiserMetaValid(centerMeta);
	#endif

	centerValid *= step(0.5, centerAge);
	#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
		#if FOXY_SSPT_ATROUS_SHARED == 1
			bool centerFinite = RtDenoiserFinite4(centerSignal)
				&& RtDenoiserFinite4(centerMoments);
		#else
			bool centerFinite = RtDenoiserFinite4(centerSignal)
				&& RtDenoiserFinite4(centerMeta)
				&& RtDenoiserFinite4(centerMoments);
		#endif
	#else
		#if FOXY_SSPT_ATROUS_SHARED == 1
			bool centerFinite = true;
		#else
			bool centerFinite = RtDenoiserFinite4(centerMeta);
		#endif
	#endif
	if (centerValid < 0.5 || !centerFinite) {
		SsptAtrousStore(pixel, vec4(0.0));
		return;
	}
	#if FOXY_SSPT_ATROUS_SHARED == 0
		centerFirstPerson = SsptAtrousFirstPerson(pixel, centerMeta);
	#endif

	#if FOXY_SSPT_ATROUS_SHARED == 1
		vec3 centerViewNormal = centerViewGuide.xyz;
		float centerDepth = centerViewGuide.w;
	#else
		vec3 centerViewNormal = normalize(mat3(gbufferModelView) * PtDecodeOctNormal(centerMeta.xy));
		float centerDepth = max(centerMeta.z, 1.0e-3);
	#endif
	#if FOXY_SSPT_ATROUS_SHARED == 0
		centerViewPosition = SsptAtrousViewPosition(
			pixel,
			centerDepth,
			RtDenoiserMetaPrimaryOffsetIndex(centerMeta)
		);
	#endif
	ssptAtrousCenterGrazingRelax = mix(
		2.20,
		1.0,
		sqrt(Saturate(abs(centerViewNormal.z)))
	);
	float centerLuminance = RtDenoiserLuma(centerSignal.rgb);
	#if FOXY_SSPT_ATROUS_PASS == 0 && !defined(FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT)
		float centerVariance = max(
			centerMoments.y - centerMoments.x * centerMoments.x,
			0.0
		) / SsptAtrousTemporalSampleCount(centerAge);
	#else
		float centerVariance = abs(centerSignal.a);
	#endif
	float relativeDeviation = sqrt(centerVariance) / max(centerLuminance + 0.04, 0.04);
	float startupUncertainty = 1.0 - Saturate(centerAge * 0.20);
	float uncertainty = Saturate(relativeDeviation * 0.90 + startupUncertainty * 0.72);
	#if FOXY_SSPT_ATROUS_PASS == 0
		float passAmount = mix(0.65, 1.20, uncertainty);
	#elif FOXY_SSPT_ATROUS_PASS == 1
		float passAmount = mix(0.50, 1.05, uncertainty);
	#else
		float passAmount = mix(0.75, 1.00, uncertainty);
	#endif
	float filterAmount = min(clamp(FOXY_SSPT_DENOISE_STRENGTH, 0.0, 2.0) * passAmount, 1.6);

	const float centerKernelWeight = SSPT_CENTER_WEIGHT;
	vec3 radianceSum = max(centerSignal.rgb, vec3(0.0)) * centerKernelWeight;
	float varianceNumerator = centerVariance * centerKernelWeight * centerKernelWeight;
	float weightSum = centerKernelWeight;
	float geometrySupportSum = 0.0;
	#ifdef FOXY_SSPT_ATROUS_FULL_KERNEL
		SsptAtrousTap(pixel, centerLocalPixel, ivec2(-1,  0), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		SsptAtrousTap(pixel, centerLocalPixel, ivec2( 1,  0), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		SsptAtrousTap(pixel, centerLocalPixel, ivec2( 0, -1), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		SsptAtrousTap(pixel, centerLocalPixel, ivec2( 0,  1), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		SsptAtrousTap(pixel, centerLocalPixel, ivec2(-1, -1), SSPT_DIAGONAL_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		SsptAtrousTap(pixel, centerLocalPixel, ivec2( 1, -1), SSPT_DIAGONAL_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		SsptAtrousTap(pixel, centerLocalPixel, ivec2(-1,  1), SSPT_DIAGONAL_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		SsptAtrousTap(pixel, centerLocalPixel, ivec2( 1,  1), SSPT_DIAGONAL_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
	#elif defined(FOXY_SSPT_ATROUS_CROSS_KERNEL)
		#ifdef FOXY_SSPT_ATROUS_DIAGONAL_CROSS_KERNEL
			SsptAtrousTap(pixel, centerLocalPixel, ivec2(-1, -1), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
			SsptAtrousTap(pixel, centerLocalPixel, ivec2( 1, -1), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
			SsptAtrousTap(pixel, centerLocalPixel, ivec2(-1,  1), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
			SsptAtrousTap(pixel, centerLocalPixel, ivec2( 1,  1), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		#else
			SsptAtrousTap(pixel, centerLocalPixel, ivec2(-1,  0), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
			SsptAtrousTap(pixel, centerLocalPixel, ivec2( 1,  0), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
			SsptAtrousTap(pixel, centerLocalPixel, ivec2( 0, -1), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
			SsptAtrousTap(pixel, centerLocalPixel, ivec2( 0,  1), SSPT_AXIS_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		#endif
	#else
		const ivec2 direction = ivec2(FOXY_SSPT_ATROUS_AXIS_X, FOXY_SSPT_ATROUS_AXIS_Y);
		SsptAtrousTap(pixel, centerLocalPixel, -direction, SSPT_DIRECTION_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
		SsptAtrousTap(pixel, centerLocalPixel,  direction, SSPT_DIRECTION_WEIGHT, centerViewNormal, centerViewPosition, centerDepth, centerSurfaceClass, centerLuminance, centerVariance, centerFirstPerson, filterAmount, radianceSum, varianceNumerator, weightSum, geometrySupportSum);
	#endif

	vec3 filteredRadiance = radianceSum / max(weightSum, 1.0e-5);
	float filteredVariance = varianceNumerator / max(weightSum * weightSum, 1.0e-5);
	float stablePlanarMarker;
	#if FOXY_SSPT_ATROUS_PASS == 0
		stablePlanarMarker = centerSurfaceClass < 0.5 && geometrySupportSum / SSPT_NEIGHBOR_KERNEL_MASS >= 0.92 ? 1.0 : 0.0;
	#else
		stablePlanarMarker = centerSignal.a >= 0.0 ? 1.0 : 0.0;
	#endif
	float packedVariance = stablePlanarMarker > 0.5 ? filteredVariance : -filteredVariance - 1.0e-6;
	SsptAtrousStore(
		pixel,
		vec4(
			min(max(filteredRadiance, vec3(0.0)), vec3(64.0)),
			clamp(packedVariance, -4096.0, 4096.0)
		)
	);
}

#undef SSPT_FILTER_GROUP_SIZE
#undef SSPT_FILTER_JITTER_RADIUS
#undef SSPT_FILTER_RADIUS
#undef SSPT_FILTER_TILE_SIDE
#undef SSPT_FILTER_TILE_AREA
#undef SSPT_CENTER_WEIGHT
#undef SSPT_NEIGHBOR_KERNEL_MASS
#undef SSPT_AXIS_WEIGHT
#undef SSPT_DIAGONAL_WEIGHT
#undef SSPT_DIRECTION_WEIGHT
