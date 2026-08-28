#ifndef FOXY_SHADOW_GLSL
#define FOXY_SHADOW_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

const float SHADOW_AFFINE_FILTER_MIN_FACTOR = 0.41;
const float SHADOW_RECEIVER_PLANE_BIAS_SCALE = 1.12;
const float SHADOW_RECEIVER_PLANE_BIAS_MAX = 0.0035;
// Hardware comparison already covers a 2x2 map footprint. Keep a small,
// stable PCF footprint even when blocker search finds no blocker so the
// raster silhouette is resolved continuously instead of snapping at a texel.
const float SHADOW_MIN_FILTER_TEXELS = 0.42;

float ShadowWarpFactor(const in vec2 clipXY) {
	float warp = Saturate(FOXY_SHADOW_WARP);
	float warp2 = warp * warp;
	return 1.0 - warp2 + 1.16 * warp2 * length(clipXY);
}

vec2 ShadowWarp(const in vec2 clipXY) {
	return clipXY / max(ShadowWarpFactor(clipXY), 0.18);
}

vec4 ShadowWarpClip(const in vec4 clipPosition) {
	vec4 warpedPosition = clipPosition;
	warpedPosition.xy = ShadowWarp(clipPosition.xy / clipPosition.w) * clipPosition.w;
	return warpedPosition;
}

void ShadowWarpJacobianData(
	const in vec2 clipXY,
	out mat2 jacobian,
	out float effectiveFactor
) {
	float warp = Saturate(FOXY_SHADOW_WARP);
	float warp2 = warp * warp;
	float base = 1.0 - warp2;
	float slope = 1.16 * warp2;
	float radius = length(clipXY);
	float rawFactor = base + slope * radius;
	float factor = max(rawFactor, 0.18);
	effectiveFactor = factor;

	float radialScale = rawFactor <= 0.18 ? 1.0 / factor : base / (factor * factor);
	float tangentScale = 1.0 / factor;
	if (radius <= 1.0e-5) {
		jacobian = mat2(tangentScale, 0.0, 0.0, tangentScale);
		return;
	}

	vec2 radial = clipXY / radius;
	vec2 tangent = vec2(-radial.y, radial.x);
	float diagonalX = radialScale * radial.x * radial.x + tangentScale * tangent.x * tangent.x;
	float diagonalY = radialScale * radial.y * radial.y + tangentScale * tangent.y * tangent.y;
	float cross = radialScale * radial.x * radial.y + tangentScale * tangent.x * tangent.y;
	jacobian = mat2(diagonalX, cross, cross, diagonalY);
}

mat2 ShadowWarpJacobian(const in vec2 clipXY) {
	mat2 jacobian;
	float effectiveFactor;
	ShadowWarpJacobianData(clipXY, jacobian, effectiveFactor);
	return jacobian;
}

vec2 ShadowTexelOffsetToClip(const in vec2 offsetTexels) {
	return offsetTexels * (2.0 / float(FOXY_SHADOW_RESOLUTION));
}

float ShadowReceiverPlaneBias(const in vec2 clipXY, const in vec2 depthSlope) {
	// Hardware depth comparison filters neighboring map texels, not neighboring
	// coordinates in the unwarped shadow domain. Convert true map-texel steps
	// back through the warp before using the receiver-plane depth slope.
	mat2 warpJacobian = ShadowWarpJacobian(clipXY);
	float determinant = warpJacobian[0].x * warpJacobian[1].y -
		warpJacobian[1].x * warpJacobian[0].y;
	vec2 mapTexel = ShadowTexelOffsetToClip(vec2(1.0));
	vec2 clipTexelX;
	vec2 clipTexelY;
	if (abs(determinant) < 1.0e-6) {
		clipTexelX = vec2(mapTexel.x, 0.0);
		clipTexelY = vec2(0.0, mapTexel.y);
	} else {
		mat2 inverseWarpJacobian = mat2(
			 warpJacobian[1].y,
			-warpJacobian[0].y,
			-warpJacobian[1].x,
			 warpJacobian[0].x
		) / determinant;
		clipTexelX = inverseWarpJacobian * vec2(mapTexel.x, 0.0);
		clipTexelY = inverseWarpJacobian * vec2(0.0, mapTexel.y);
	}
	// A bilinear comparison can select either side of the receiver within half
	// a texel along both axes. This is the conservative planar depth span.
	return 0.5 * (
		abs(dot(depthSlope, clipTexelX)) +
		abs(dot(depthSlope, clipTexelY))
	);
}

vec2 ShadowSampleUv(const in vec2 clipXY, const in vec2 offsetTexels) {
	vec2 sampleClip = clipXY + ShadowTexelOffsetToClip(offsetTexels);
	return ShadowWarp(sampleClip) * 0.5 + 0.5;
}

struct ShadowFilterWarp {
	mat2 uvPerTexel;
	float affine;
};

ShadowFilterWarp ShadowBuildFilterWarp(const in vec2 clipXY) {
	ShadowFilterWarp filterWarp;
	mat2 warpJacobian;
	float effectiveWarpFactor;
	ShadowWarpJacobianData(clipXY, warpJacobian, effectiveWarpFactor);
	filterWarp.uvPerTexel = warpJacobian * (1.0 / float(FOXY_SHADOW_RESOLUTION));
	filterWarp.affine = step(SHADOW_AFFINE_FILTER_MIN_FACTOR, effectiveWarpFactor);
	return filterWarp;
}

vec2 ShadowFilterSampleUv(
	const in vec2 clipXY,
	const in vec2 centerUv,
	const in ShadowFilterWarp filterWarp,
	const in vec2 offsetTexels
) {
	if (filterWarp.affine > 0.5) {
		return clamp(centerUv + filterWarp.uvPerTexel * offsetTexels, vec2(0.001), vec2(0.999));
	}
	return clamp(ShadowSampleUv(clipXY, offsetTexels), vec2(0.001), vec2(0.999));
}

float ShadowTemporalPhase(const in vec2 fragCoord, const in int frameIndex) {
	vec2 pixel = floor(fragCoord);
	float phase = fract(52.9829189 * fract(0.06711056 * pixel.x + 0.00583715 * pixel.y));
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		phase = fract(phase + float(frameIndex) * 0.61803398875);
	#endif
	return phase;
}

vec2 ShadowDirection(const in float phase) {
	float angle = phase * 6.28318530718;
	return vec2(cos(angle), sin(angle));
}

vec2 ShadowGoldenRotate(const in vec2 direction) {
	return vec2(
		-0.73736887808 * direction.x - 0.67549029426 * direction.y,
		 0.67549029426 * direction.x - 0.73736887808 * direction.y
	);
}

float ShadowDiskRadius(
	const in float sampleIndex,
	const in float sampleCount,
	const in float radialJitter
) {
	return sqrt((sampleIndex + clamp(radialJitter, 0.08, 0.92)) / max(sampleCount, 1.0));
}

float ShadowCompareDepth(const in float receiverDepth, const in float sampleDepth, const in float bias) {
	return receiverDepth - bias <= sampleDepth ? 1.0 : 0.0;
}

float ShadowDistanceFade(const in float receiverDistance) {
	return 1.0 - smoothstep(max(FOXY_SHADOW_DISTANCE - 24.0, 0.0), FOXY_SHADOW_DISTANCE, receiverDistance);
}

float ShadowSurfaceCoverageFade(const in vec2 shadowUv, const in float receiverDistance) {
	float edgeDistance = min(min(shadowUv.x, 1.0 - shadowUv.x), min(shadowUv.y, 1.0 - shadowUv.y));
	return smoothstep(0.008, 0.050, edgeDistance) * ShadowDistanceFade(receiverDistance);
}

float ShadowFilterMix(const in float baseMix, const in float centerVisibility, const in float contactGap, const in float softness) {
	float contact = (1.0 - centerVisibility) * (1.0 - smoothstep(0.00035, 0.0045 + softness * 0.0040, contactGap));
	return Saturate(baseMix * mix(1.0, 0.58, contact));
}

#endif
