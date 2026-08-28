#ifndef FOXY_DH_SHADOW_RECEIVER_GLSL
#define FOXY_DH_SHADOW_RECEIVER_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/shadow.glsl"

uniform sampler2D shadowtex0;
uniform sampler2DShadow shadowtex1;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 shadowLightPosition;
uniform int frameCounter;

float DhShadowSafeDivisor(const in float value) {
	if (abs(value) < 1.0e-6) {
		return value < 0.0 ? -1.0e-6 : 1.0e-6;
	}
	return value;
}

struct DhShadowReceiver {
	vec3 coord;
	vec2 clipXY;
	vec2 depthSlope;
	float bias;
	float coverage;
};

DhShadowReceiver DhBuildShadowReceiver(
	const in vec3 playerPos,
	const in vec3 viewPos,
	const in vec3 normalView,
	const in mat4 viewToPlayer,
	const in vec3 cameraPosition,
	const in float NoL
) {
	DhShadowReceiver receiver;
	receiver.coord = vec3(0.5);
	receiver.clipXY = vec2(0.0);
	receiver.depthSlope = vec2(0.0);
	receiver.bias = 0.0;
	receiver.coverage = 0.0;

	float surfaceNoL = Saturate(NoL);
	float grazing = 1.0 - smoothstep(0.035, 0.32, surfaceNoL);
	float viewDistance = length(viewPos);
	float distanceRatio = Saturate(viewDistance / max(FOXY_SHADOW_DISTANCE, 1.0));
	float projectionScale = max(abs(shadowProjection[0][0]), 1.0e-6);
	float worldTexel = 2.0 / (float(FOXY_SHADOW_RESOLUTION) * projectionScale);
	float normalOffset = worldTexel * (0.18 + distanceRatio * 0.18 + grazing * (0.38 + distanceRatio * 0.42));
	normalOffset = clamp(normalOffset, 0.018, 0.220);

	vec3 normalPlayer = normalize(mat3(viewToPlayer) * normalView);
	vec4 shadowClip = shadowProjection * shadowModelView * vec4(playerPos + normalPlayer * normalOffset, 1.0);
	vec3 shadowNdc = shadowClip.xyz / DhShadowSafeDivisor(shadowClip.w);
	receiver.clipXY = shadowNdc.xy;
	receiver.coord = vec3(ShadowWarp(receiver.clipXY), shadowNdc.z) * 0.5 + 0.5;
	if (receiver.coord.x <= 0.0 || receiver.coord.y <= 0.0 || receiver.coord.x >= 1.0 || receiver.coord.y >= 1.0 || receiver.coord.z <= 0.0 || receiver.coord.z >= 1.0) {
		return receiver;
	}

	receiver.coverage = ShadowSurfaceCoverageFade(receiver.coord.xy, viewDistance);
	vec3 normalShadow = normalize(mat3(shadowModelView) * normalPlayer);
	float normalShadowZ = normalShadow.z;
	if (abs(normalShadowZ) < 0.08) {
		normalShadowZ = normalShadowZ < 0.0 ? -0.08 : 0.08;
	}
	float projectionX = DhShadowSafeDivisor(shadowProjection[0][0]);
	float projectionY = DhShadowSafeDivisor(shadowProjection[1][1]);
	receiver.depthSlope = -0.5 * shadowProjection[2][2] * vec2(
		normalShadow.x / projectionX,
		normalShadow.y / projectionY
	) / normalShadowZ;
	receiver.depthSlope = clamp(receiver.depthSlope, vec2(-8.0), vec2(8.0));

	float baseBias = mix(0.00034, 0.000045, surfaceNoL);
	float distanceBias = distanceRatio * distanceRatio * 0.00010;
	float slopeBias = grazing * grazing * mix(0.00008, 0.00030, distanceRatio);
	float receiverPlaneBias = min(
		ShadowReceiverPlaneBias(receiver.clipXY, receiver.depthSlope) *
			SHADOW_RECEIVER_PLANE_BIAS_SCALE,
		SHADOW_RECEIVER_PLANE_BIAS_MAX
	);
	receiver.bias = baseBias + distanceBias + slopeBias + receiverPlaneBias;
	return receiver;
}

vec2 DhShadowReceiverUv(const in DhShadowReceiver receiver, const in vec2 offsetTexels) {
	return clamp(ShadowSampleUv(receiver.clipXY, offsetTexels), vec2(0.001), vec2(0.999));
}

float DhShadowReceiverDepth(const in DhShadowReceiver receiver, const in vec2 offsetTexels) {
	vec2 clipOffset = ShadowTexelOffsetToClip(offsetTexels);
	return receiver.coord.z + dot(receiver.depthSlope, clipOffset) - receiver.bias;
}

float DhShadowCompare(const in DhShadowReceiver receiver, const in vec2 offsetTexels) {
	vec2 uv = DhShadowReceiverUv(receiver, offsetTexels);
	return shadow2D(shadowtex1, vec3(uv, DhShadowReceiverDepth(receiver, offsetTexels))).x;
}

float DhShadowCompareFiltered(
	const in DhShadowReceiver receiver,
	const in ShadowFilterWarp filterWarp,
	const in vec2 offsetTexels
) {
	vec2 uv = ShadowFilterSampleUv(receiver.clipXY, receiver.coord.xy, filterWarp, offsetTexels);
	return shadow2D(shadowtex1, vec3(uv, DhShadowReceiverDepth(receiver, offsetTexels))).x;
}

vec2 DhShadowBlockerSearch(
	const in DhShadowReceiver receiver,
	const in float centerDepth,
	const in float centerVisibility,
	const in float searchRadius,
	const in float phase
) {
	float sampleCount = float(FOXY_SHADOW_BLOCKER_SAMPLES);
	float radialJitter = fract(phase * 1.32471795724 + 0.37);
	float blockerGapSum = 0.0;
	float blockerWeight = 0.0;
	float threshold = max(receiver.bias * 0.12, 0.000015);

	float centerGap = max(DhShadowReceiverDepth(receiver, vec2(0.0)) - centerDepth, 0.0);
	float centerWeight = smoothstep(threshold, threshold * 3.0, centerGap);
	blockerGapSum += centerGap * centerWeight;
	blockerWeight += centerWeight;

	vec2 direction = ShadowDirection(fract(phase + 0.38196601125));
	for (int i = 1; i < FOXY_SHADOW_BLOCKER_SAMPLES; i++) {
		if (
			i == FOXY_SHADOW_BLOCKER_BASE_SAMPLES &&
			centerVisibility >= 0.999 &&
			blockerWeight <= 0.0001
		) {
			return vec2(0.0);
		}
		direction = ShadowGoldenRotate(direction);
		float radius = ShadowDiskRadius(float(i), sampleCount, radialJitter);
		vec2 offsetTexels = direction * (searchRadius * radius);
		float sampleDepth = texture2D(shadowtex0, DhShadowReceiverUv(receiver, offsetTexels)).r;
		float gap = max(DhShadowReceiverDepth(receiver, offsetTexels) - sampleDepth, 0.0);
		float weight = smoothstep(threshold, threshold * 3.0, gap);
		blockerGapSum += gap * weight;
		blockerWeight += weight;
	}

	if (blockerWeight <= 0.0001) {
		return vec2(0.0);
	}
	return vec2(blockerGapSum / blockerWeight, blockerWeight / sampleCount);
}

float DhShadowVisibility(const in DhShadowReceiver receiver, const in float lightAltitude) {
	if (receiver.coverage <= 0.0001) {
		return 1.0;
	}

	float centerDepth = texture2D(shadowtex0, receiver.coord.xy).r;
	float center = DhShadowCompare(receiver, vec2(0.0));
	#if FOXY_SHADOW_FILTERING == 0
		float hardFloorVisibility = 1.0 - FOXY_SHADOW_STRENGTH;
		float hardVisibility = mix(hardFloorVisibility, 1.0, center);
		return mix(1.0, hardVisibility, receiver.coverage);
	#endif
	float phase = ShadowTemporalPhase(gl_FragCoord.xy, frameCounter);
	float altitudeStability = smoothstep(0.025, 0.20, max(lightAltitude, 0.0));
	float searchRadius = (4.00 + FOXY_SHADOW_SOFTNESS * 5.00) * mix(0.75, 1.0, altitudeStability);
	vec2 blockerInfo = DhShadowBlockerSearch(receiver, centerDepth, center, searchRadius, phase);
	if (blockerInfo.y <= 0.001 && center >= 0.999) {
		return 1.0;
	}

	float gapLimit = 0.0065 + FOXY_SHADOW_SOFTNESS * 0.0050;
	float gapResponse = sqrt(smoothstep(0.00018, gapLimit, blockerInfo.x));
	float coverageResponse = smoothstep(0.02, 0.22, blockerInfo.y);
	float minimumRadius = (0.12 + FOXY_SHADOW_SOFTNESS * 0.28) * mix(1.06, 1.0, altitudeStability);
	float maximumPenumbra = (0.12 + FOXY_SHADOW_SOFTNESS * 1.00) * mix(0.80, 1.0, altitudeStability);
	float filterRadius = minimumRadius + maximumPenumbra * gapResponse * coverageResponse;
	float centerGap = max(DhShadowReceiverDepth(receiver, vec2(0.0)) - centerDepth, 0.0);
	float contactScale = mix(0.62, 1.0, smoothstep(0.00018, 0.0028 + FOXY_SHADOW_SOFTNESS * 0.0022, centerGap));
	filterRadius *= mix(1.0, contactScale, 1.0 - Saturate(center));
	filterRadius = clamp(filterRadius, 0.10, 2.50);
	ShadowFilterWarp filterWarp = ShadowBuildFilterWarp(receiver.clipXY);

	#if FOXY_SHADOW_FILTER_SAMPLES > 12
		const int maxDhShadowSamples = 12;
	#else
		const int maxDhShadowSamples = FOXY_SHADOW_FILTER_SAMPLES;
	#endif
	int activeDhShadowSamples = maxDhShadowSamples;
	#if FOXY_SHADOW_FILTER_SAMPLES > 8
		if (filterRadius < 1.65) {
			activeDhShadowSamples = 8;
		}
	#endif

	float radialJitter = fract(phase * 1.61803398875 + 0.21);
	vec2 direction = ShadowDirection(fract(phase + 0.17320508076));
	float filtered = 0.0;
	for (int i = 0; i < maxDhShadowSamples; i++) {
		if (i >= activeDhShadowSamples) break;
		direction = ShadowGoldenRotate(direction);
		float radius = ShadowDiskRadius(float(i), float(activeDhShadowSamples), radialJitter);
		filtered += DhShadowCompareFiltered(receiver, filterWarp, direction * (filterRadius * radius));
	}
	filtered /= float(activeDhShadowSamples);

	float floorVisibility = 1.0 - FOXY_SHADOW_STRENGTH;
	float visibility = mix(floorVisibility, 1.0, Saturate(filtered));
	return mix(1.0, visibility, receiver.coverage);
}

#endif
