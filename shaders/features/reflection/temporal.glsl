#ifndef FOXY_REFLECTION_TEMPORAL_GLSL
#define FOXY_REFLECTION_TEMPORAL_GLSL

struct ReflectionTemporalResult {
	vec3 color;
	float confidence;
	float historySupport;
	vec4 packedHistory;
};

struct ReflectionHistorySample {
	vec4 signal;
	vec4 meta;
};

struct ReflectionReprojection {
	vec2 previousRasterUv;
	float expectedDepth;
	float valid;
	float motionPixels;
};

ivec2 ReflectionSize() {
	return max(textureSize(colortex15, 0), ivec2(1));
}

ivec2 ReflectionPixel(const in vec2 uv) {
	ivec2 size = ReflectionSize();
	return clamp(ivec2(floor(clamp(uv, vec2(0.0), vec2(0.999999)) * vec2(size))), ivec2(0), size - ivec2(1));
}

vec2 ReflectionOctEncode(vec3 normal) {
	normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), 1.0e-6);
	if (normal.z < 0.0) {
		vec2 direction = vec2(normal.x >= 0.0 ? 1.0 : -1.0, normal.y >= 0.0 ? 1.0 : -1.0);
		normal.xy = (vec2(1.0) - abs(normal.yx)) * direction;
	}
	return normal.xy * 0.5 + 0.5;
}

vec3 ReflectionOctDecode(const in vec2 encoded) {
	vec2 value = encoded * 2.0 - 1.0;
	vec3 normal = vec3(value, 1.0 - abs(value.x) - abs(value.y));
	if (normal.z < 0.0) {
		vec2 direction = vec2(normal.x >= 0.0 ? 1.0 : -1.0, normal.y >= 0.0 ? 1.0 : -1.0);
		normal.xy = (vec2(1.0) - abs(normal.yx)) * direction;
	}
	return normalize(normal);
}

float ReflectionEncodeDepth(const in float linearDepth) {
	return clamp(log2(1.0 + max(linearDepth, 0.0)) * (1.0 / 16.0), 0.0, 1.0);
}

float ReflectionDecodeDepth(const in float encodedDepth) {
	return exp2(clamp(encodedDepth, 0.0, 1.0) * 16.0) - 1.0;
}

vec3 ReflectionTemporalEncodeColor(const in vec3 color) {
	return log2(vec3(1.0) + max(color, vec3(0.0)));
}

vec3 ReflectionTemporalDecodeColor(const in vec3 color) {
	return exp2(max(color, vec3(0.0))) - vec3(1.0);
}

// Pre-exposed companding preserves dark chroma in the packed 12-bit history.
const float FOXY_REFLECTION_HISTORY_COLOR_PREEXPOSURE = 64.0;
const float FOXY_REFLECTION_HISTORY_COLOR_LOG_RANGE = 24.0;

vec3 ReflectionHistoryEncodeColor(const in vec3 color) {
	return clamp(
		log2(vec3(1.0) + max(color, vec3(0.0)) * FOXY_REFLECTION_HISTORY_COLOR_PREEXPOSURE)
			/ FOXY_REFLECTION_HISTORY_COLOR_LOG_RANGE,
		vec3(0.0),
		vec3(1.0)
	);
}

vec3 ReflectionHistoryDecodeColor(const in vec3 color) {
	return (exp2(clamp(color, vec3(0.0), vec3(1.0))
		* FOXY_REFLECTION_HISTORY_COLOR_LOG_RANGE) - vec3(1.0))
		/ FOXY_REFLECTION_HISTORY_COLOR_PREEXPOSURE;
}

float ReflectionPackState(const in float reflectionType, const in float historyAge) {
	float typeCode = clamp(floor(reflectionType + 0.5), 1.0, 3.0);
	float ageCode = clamp(floor(historyAge + 0.5), 1.0, 31.0);
	return (typeCode + ageCode * 4.0) * (1.0 / 255.0);
}

void ReflectionDecodeState(const in float packedState, out float reflectionType, out float historyAge) {
	float code = floor(clamp(packedState, 0.0, 1.0) * 255.0 + 0.5);
	reflectionType = mod(code, 4.0);
	historyAge = floor(code * 0.25);
}

float ReflectionPackUnorm12Pair(const in vec2 value) {
	uvec2 encoded = uvec2(floor(clamp(value, vec2(0.0), vec2(1.0)) * 4095.0 + 0.5));
	return float(encoded.x | (encoded.y << 12));
}

vec2 ReflectionUnpackUnorm12Pair(const in float value) {
	uint encoded = uint(max(value, 0.0) + 0.5);
	return vec2(encoded & 4095u, (encoded >> 12) & 4095u) * (1.0 / 4095.0);
}

vec4 ReflectionPackHistory(const in vec4 signal, const in vec4 meta) {
	vec3 encodedColor = ReflectionHistoryEncodeColor(signal.rgb);
	return vec4(
		ReflectionPackUnorm12Pair(encodedColor.rg),
		ReflectionPackUnorm12Pair(vec2(encodedColor.b, signal.a)),
		ReflectionPackUnorm12Pair(meta.xy),
		ReflectionPackUnorm12Pair(meta.zw)
	);
}

ReflectionHistorySample ReflectionUnpackHistory(const in vec4 encoded) {
	ReflectionHistorySample decodedHistory;
	vec2 colorRg = ReflectionUnpackUnorm12Pair(encoded.x);
	vec2 colorBConfidence = ReflectionUnpackUnorm12Pair(encoded.y);
	decodedHistory.signal = vec4(
		ReflectionHistoryDecodeColor(vec3(colorRg, colorBConfidence.x)),
		colorBConfidence.y
	);
	decodedHistory.meta = vec4(
		ReflectionUnpackUnorm12Pair(encoded.z),
		ReflectionUnpackUnorm12Pair(encoded.w)
	);
	return decodedHistory;
}

ReflectionHistorySample ReflectionLoadPrevious(const in ivec2 pixel) {
	return ReflectionUnpackHistory(texelFetch(colortex15, pixel, 0));
}

ReflectionReprojection ReflectionBuildReprojection(const in vec3 currentViewPosition) {
	ReflectionReprojection reprojection;
	vec4 currentPlayer4 = gbufferModelViewInverse * vec4(currentViewPosition, 1.0);
	vec3 currentPlayerPosition = currentPlayer4.xyz / max(abs(currentPlayer4.w), 1.0e-6);
	vec3 previousPlayerPosition = currentPlayerPosition + cameraPosition - previousCameraPosition;
	vec4 previousView4 = gbufferPreviousModelView * vec4(previousPlayerPosition, 1.0);
	vec4 previousClip = gbufferPreviousProjection * previousView4;
	reprojection.valid = step(0.02, previousClip.w) * step(1.5, float(frameCounter));
	reprojection.valid *= step(previousView4.z, -0.02);
	reprojection.valid *= 1.0 - step(64.0, dot(cameraPosition - previousCameraPosition, cameraPosition - previousCameraPosition));
	vec2 previousViewUv = previousClip.xy / max(previousClip.w, 1.0e-6) * 0.5 + 0.5;
	vec2 unclampedPreviousRasterUv = previousViewUv;
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		unclampedPreviousRasterUv += previousTemporalJitter * 0.5;
	#endif
	reprojection.valid *= step(0.0, unclampedPreviousRasterUv.x) * step(unclampedPreviousRasterUv.x, 1.0);
	reprojection.valid *= step(0.0, unclampedPreviousRasterUv.y) * step(unclampedPreviousRasterUv.y, 1.0);
	reprojection.previousRasterUv = clamp(unclampedPreviousRasterUv, vec2(0.0), vec2(1.0));
	reprojection.expectedDepth = max(-previousView4.z, 0.0);
	reprojection.motionPixels = length((unclampedPreviousRasterUv - texcoord) * vec2(ReflectionSize()));
	return reprojection;
}

float ReflectionHistoryGeometryWeight(
	const in ReflectionHistorySample history,
	const in float reflectionType,
	const in vec3 worldNormal,
	const in float expectedDepth,
	out float historyAge
) {
	float historyType;
	ReflectionDecodeState(history.meta.w, historyType, historyAge);
	float typeWeight = 1.0 - step(0.25, abs(historyType - reflectionType));
	float historyDepth = ReflectionDecodeDepth(history.meta.z);
	float relativeDepthError = abs(historyDepth - expectedDepth) / max(expectedDepth, 0.25);
	float depthWeight = 1.0 - smoothstep(0.010, 0.045, relativeDepthError);
	vec3 historyNormal = ReflectionOctDecode(history.meta.xy);
	float normalDot = dot(historyNormal, worldNormal);
	float normalWeight = reflectionType < 1.5
		? smoothstep(0.70, 0.93, normalDot)
		: smoothstep(0.86, 0.975, normalDot);
	return typeWeight * depthWeight * normalWeight * step(0.5, historyAge);
}

float ReflectionTraceSelected(
	const in ReflectionReprojection reprojection,
	const in float reflectionType,
	const in vec3 worldNormal
) {
	#if FOXY_MATERIAL_REFLECTION_HIGH_QUALITY == 1
		return 1.0;
	#else
	ivec2 pixel = ReflectionPixel(texcoord);
	int pixelPhase = (pixel.x & 1) | ((pixel.y & 1) << 1);
	int framePhase = frameCounter & 3;
	bool scheduled = pixelPhase == framePhase;
	if (reprojection.motionPixels > 1.25) {
		scheduled = scheduled || pixelPhase == ((framePhase + 2) & 3);
	}
	if (scheduled || reprojection.valid < 0.5) return 1.0;

	ivec2 historyPixel = ReflectionPixel(reprojection.previousRasterUv);
	ReflectionHistorySample history = ReflectionLoadPrevious(historyPixel);
	float historyAge;
	float geometryWeight = ReflectionHistoryGeometryWeight(
		history,
		reflectionType,
		worldNormal,
		reprojection.expectedDepth,
		historyAge
	);
	return geometryWeight < 0.18 ? 1.0 : 0.0;
	#endif
}

void ReflectionAccumulateTap(
	const in ivec2 pixel,
	const in float spatialWeight,
	const in float reflectionType,
	const in vec3 worldNormal,
	const in float expectedDepth,
	inout vec4 signalSum,
	inout float ageSum,
	inout float weightSum
) {
	ivec2 size = ReflectionSize();
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, size))) return;
	ReflectionHistorySample history = ReflectionLoadPrevious(pixel);
	vec4 signal = history.signal;
	float historyAge;
	float valid = ReflectionHistoryGeometryWeight(history, reflectionType, worldNormal, expectedDepth, historyAge);
	float weight = spatialWeight * valid;
	signalSum += signal * weight;
	ageSum += historyAge * weight;
	weightSum += weight;
}

ReflectionTemporalResult ResolveReflectionTemporal(
	const in vec3 currentColor,
	const in float currentConfidence,
	const in float currentAvailable,
	const in float reflectionType,
	const in float perceptualRoughness,
	const in vec3 worldNormal,
	const in vec3 currentViewPosition,
	const in ReflectionReprojection reprojection,
	const in vec3 neighborhoodMinimum,
	const in vec3 neighborhoodMaximum
) {
	ReflectionTemporalResult result;
	result.color = max(currentColor, vec3(0.0));
	result.confidence = clamp(currentConfidence, 0.0, 1.0);
	result.historySupport = 0.0;
	result.packedHistory = vec4(0.0);

	ivec2 size = ReflectionSize();
	vec2 historyPosition = reprojection.previousRasterUv * vec2(size) - vec2(0.5);
	ivec2 historyBase = ivec2(floor(historyPosition));
	vec2 historyFraction = fract(historyPosition);
	vec4 historySignalSum = vec4(0.0);
	float historyAgeSum = 0.0;
	float historyWeightSum = 0.0;
	float expectedDepth = reprojection.expectedDepth;
	ReflectionAccumulateTap(historyBase + ivec2(0, 0), (1.0-historyFraction.x)*(1.0-historyFraction.y), reflectionType, worldNormal, expectedDepth, historySignalSum, historyAgeSum, historyWeightSum);
	ReflectionAccumulateTap(historyBase + ivec2(1, 0), historyFraction.x*(1.0-historyFraction.y), reflectionType, worldNormal, expectedDepth, historySignalSum, historyAgeSum, historyWeightSum);
	ReflectionAccumulateTap(historyBase + ivec2(0, 1), (1.0-historyFraction.x)*historyFraction.y, reflectionType, worldNormal, expectedDepth, historySignalSum, historyAgeSum, historyWeightSum);
	ReflectionAccumulateTap(historyBase + ivec2(1, 1), historyFraction.x*historyFraction.y, reflectionType, worldNormal, expectedDepth, historySignalSum, historyAgeSum, historyWeightSum);
	float reprojectionSupport = clamp(historyWeightSum, 0.0, 1.0) * reprojection.valid;

	float historyValid = step(0.05, historyWeightSum) * reprojection.valid;
	vec4 historySignal = historySignalSum / max(historyWeightSum, 1.0e-5);
	float historyAge = historyAgeSum / max(historyWeightSum, 1.0e-5);
	// Clamp history to the accepted local current distribution.
	if (historyValid > 0.5 && currentAvailable > 0.5) {
		vec3 encodedHistory = ReflectionTemporalEncodeColor(historySignal.rgb);
		historySignal.rgb = ReflectionTemporalDecodeColor(clamp(
			encodedHistory,
			neighborhoodMinimum,
			max(neighborhoodMaximum, neighborhoodMinimum + vec3(1.0e-4))
		));
	}
	if (currentAvailable < 0.5 && historyValid < 0.5) {
		return result;
	}

	float cameraMotion = smoothstep(0.002, 0.12, length(cameraPosition - previousCameraPosition));
	float screenMotion = smoothstep(0.65, 5.0, reprojection.motionPixels);
	float temporalMotion = max(cameraMotion, screenMotion);
	float progressiveWeight = clamp(historyAge / max(historyAge + 1.0, 1.0), 0.50, 0.96875);
	float historyWeight = mix(0.72, progressiveWeight, step(1.5, reflectionType));
	if (reflectionType >= 1.5) {
		historyWeight = mix(0.80, 0.96875, smoothstep(2.0, 24.0, historyAge));
	}
	// Rough-lobe history spans a complete four-orientation sampling period.
	float historyResponseCap = mix(
		0.88,
		0.94,
		smoothstep(0.18, 0.72, perceptualRoughness)
	);
	historyWeight = min(historyWeight, historyResponseCap);
	historyWeight *= mix(1.0, 0.72, temporalMotion) * historyValid;
	if (currentAvailable < 0.5) historyWeight = historyResponseCap * historyValid;
	if (reflectionType < 1.5 && currentConfidence < 0.02 && historySignal.a > 0.08) {
		historyWeight = max(historyWeight, mix(0.93, 0.68, temporalMotion) * historyValid);
	}

	result.color = max(mix(result.color, historySignal.rgb, historyWeight), vec3(0.0));
	result.confidence = mix(result.confidence, historySignal.a, historyWeight);
	result.historySupport = reprojectionSupport;
	float nextAge = currentAvailable > 0.5 ? min(historyAge + 1.0, 31.0) : max(historyAge, 1.0);
	if (historyValid < 0.5) nextAge = 1.0;
	vec4 currentMeta = vec4(
		ReflectionOctEncode(normalize(worldNormal)),
		ReflectionEncodeDepth(max(-currentViewPosition.z, 0.0)),
		ReflectionPackState(reflectionType, nextAge)
	);
	result.packedHistory = ReflectionPackHistory(
		vec4(result.color, result.confidence),
		currentMeta
	);
	return result;
}

#endif
