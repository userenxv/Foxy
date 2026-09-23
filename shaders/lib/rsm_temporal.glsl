#ifndef FOXY_RSM_TEMPORAL_GLSL
#define FOXY_RSM_TEMPORAL_GLSL

/*
	Independent copy of the reflection temporal resolve, kept separate so that
	changes to either path cannot affect the other.

	Host requirements:
	  - Must declare, before including this file, four rgba16f image2D (writable):
	      img_ptHistoryA / img_ptHistoryB          vec4(color.rgb, confidence)
	      img_ptHistoryMetaA / img_ptHistoryMetaB  vec4(octNormal.xy, viewDepth, state)
	    They use the ray resolution (0.5x). The pair is shared with SSPT because Iris
	    allows only 16 images per pack and every slot is already taken; on the RSM
	    path SSPT is off, so those four are idle.
	  - Parity: on even frames read B / write A, on odd frames read A / write B
	    (see RsmHistoryReadsA), which is the SSPT convention too.
	  - The camera uniforms and gbufferModelViewInverse / gbufferPreviousModelView /
	    gbufferPreviousProjection / gbufferProjection must be in scope
	    (see RsmBuildReprojection).
*/

// The bounce is diffuse: no material type exists, so the resolve runs as the roughest
// surface class. That is the branch leaning hardest on history, which is what a noisy
// one-bounce gather needs (RsmPackState clamps the stored code to 1..3).
#define FOXY_RSM_TEMPORAL_SURFACE_TYPE 3.0

struct RsmTemporalResult {
	vec3 color;
	float confidence;
	float historySupport;
	vec4 signal;
	vec4 meta;
};

struct RsmHistorySample {
	vec4 signal;
	vec4 meta;
};

struct RsmReprojection {
	vec2 previousRasterUv;
	float expectedDepth;
	float valid;
	float motionPixels;
};

bool RsmHistoryReadsA() {
	return (frameCounter % 2) != 0;
}

ivec2 RsmSize() {
	return max(imageSize(img_ptHistoryA), ivec2(1));
}

vec2 RsmOctEncode(vec3 normal) {
	normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), 1.0e-6);
	if (normal.z < 0.0) {
		vec2 direction = vec2(normal.x >= 0.0 ? 1.0 : -1.0, normal.y >= 0.0 ? 1.0 : -1.0);
		normal.xy = (vec2(1.0) - abs(normal.yx)) * direction;
	}
	return normal.xy * 0.5 + 0.5;
}

vec3 RsmOctDecode(const in vec2 encoded) {
	vec2 value = encoded * 2.0 - 1.0;
	vec3 normal = vec3(value, 1.0 - abs(value.x) - abs(value.y));
	if (normal.z < 0.0) {
		vec2 direction = vec2(normal.x >= 0.0 ? 1.0 : -1.0, normal.y >= 0.0 ? 1.0 : -1.0);
		normal.xy = (vec2(1.0) - abs(normal.yx)) * direction;
	}
	return normalize(normal);
}

vec3 RsmTemporalEncodeColor(const in vec3 color) {
	return log2(vec3(1.0) + max(color, vec3(0.0)));
}

vec3 RsmTemporalDecodeColor(const in vec3 color) {
	return exp2(max(color, vec3(0.0))) - vec3(1.0);
}

// The history images are rgba16f, so the sample is stored as plain values rather than
// packed integer codes: a half carries ~11 significant bits, which cannot hold two 12
// bit codes, but is far more than the values themselves need.
//
// The state stays a negative integer so that an untouched slot, which reads back as
// zero, decodes to age 0 and is rejected by the history weight.
float RsmPackState(const in float surfaceType, const in float historyAge) {
	float typeCode = clamp(floor(surfaceType + 0.5), 1.0, 3.0);
	float ageCode = clamp(floor(historyAge + 0.5), 1.0, 31.0);
	return -(typeCode + ageCode * 4.0);
}

void RsmDecodeState(const in float packedState, out float surfaceType, out float historyAge) {
	float code = max(-packedState, 0.0);
	surfaceType = mod(code, 4.0);
	historyAge = floor(code * 0.25);
}

RsmHistorySample RsmLoadPrevious(const in ivec2 pixel) {
	ivec2 clamped = clamp(pixel, ivec2(0), RsmSize() - ivec2(1));
	RsmHistorySample history;
	if (RsmHistoryReadsA()) {
		history.signal = imageLoad(img_ptHistoryA, clamped);
		history.meta = imageLoad(img_ptHistoryMetaA, clamped);
	} else {
		history.signal = imageLoad(img_ptHistoryB, clamped);
		history.meta = imageLoad(img_ptHistoryMetaB, clamped);
	}
	return history;
}

void RsmStoreHistory(const in ivec2 pixel, const in vec4 signal, const in vec4 meta) {
	if (RsmHistoryReadsA()) {
		imageStore(img_ptHistoryB, pixel, signal);
		imageStore(img_ptHistoryMetaB, pixel, meta);
	} else {
		imageStore(img_ptHistoryA, pixel, signal);
		imageStore(img_ptHistoryMetaA, pixel, meta);
	}
}

RsmReprojection RsmBuildReprojection(const in vec3 currentViewPosition, const in vec2 currentRasterUv) {
	RsmReprojection reprojection;
	vec4 currentPlayer4 = gbufferModelViewInverse * vec4(currentViewPosition, 1.0);
	vec3 currentPlayerPosition = currentPlayer4.xyz / max(abs(currentPlayer4.w), 1.0e-6);
	vec3 previousPlayerPosition = currentPlayerPosition + cameraPosition - previousCameraPosition;
	vec4 currentClip = gbufferProjection * vec4(currentViewPosition, 1.0);
	vec4 previousView4 = gbufferPreviousModelView * vec4(previousPlayerPosition, 1.0);
	vec4 previousClip = gbufferPreviousProjection * previousView4;
	reprojection.valid = step(0.02, currentClip.w) * step(0.02, previousClip.w) *
		step(1.5, float(frameCounter));
	reprojection.valid *= step(previousView4.z, -0.02);
	reprojection.valid *= 1.0 - step(64.0, dot(cameraPosition - previousCameraPosition, cameraPosition - previousCameraPosition));
	vec2 currentViewUv = currentClip.xy / max(currentClip.w, 1.0e-6) * 0.5 + 0.5;
	vec2 previousViewUv = previousClip.xy / max(previousClip.w, 1.0e-6) * 0.5 + 0.5;
	// History lives on the trace grid, but the shaded point is the primary pixel, which
	// sits off the grid centre. Quoting the absolute previous position would therefore
	// bake that offset into every read, and a recurrent resolve turns a constant read
	// offset into a directional smear. Only the displacement between the two frames is
	// meaningful here, so it is added to the grid centre instead.
	// Both view UVs are un-jittered, so no temporal jitter term belongs on either side.
	vec2 unclampedPreviousRasterUv = currentRasterUv + (previousViewUv - currentViewUv);
	reprojection.valid *= step(0.0, unclampedPreviousRasterUv.x) * step(unclampedPreviousRasterUv.x, 1.0);
	reprojection.valid *= step(0.0, unclampedPreviousRasterUv.y) * step(unclampedPreviousRasterUv.y, 1.0);
	reprojection.previousRasterUv = clamp(unclampedPreviousRasterUv, vec2(0.0), vec2(1.0));
	reprojection.expectedDepth = max(-previousView4.z, 0.0);
	reprojection.motionPixels = length((previousViewUv - currentViewUv) * vec2(RsmSize()));
	return reprojection;
}

float RsmHistoryGeometryWeight(
	const in RsmHistorySample history,
	const in float surfaceType,
	const in vec3 worldNormal,
	const in float expectedDepth,
	const in float motionStrictness,
	out float historyAge
) {
	float historyType;
	RsmDecodeState(history.meta.w, historyType, historyAge);
	float typeWeight = 1.0 - step(0.25, abs(historyType - surfaceType));
	float historyDepth = max(history.meta.z, 0.0);
	float relativeDepthError = abs(historyDepth - expectedDepth) / max(expectedDepth, 0.25);
	// Motion tightens the tests rather than scaling the history weight down. The history
	// is the sample budget: dropping it on movement leaves nothing behind, which is what
	// makes a low sample count look blotchy while walking. Judging it harder removes the
	// ghosting without spending the samples.
	float depthWeight = 1.0 - smoothstep(
		mix(0.010, 0.004, motionStrictness),
		mix(0.045, 0.014, motionStrictness),
		relativeDepthError
	);
	vec3 historyNormal = RsmOctDecode(history.meta.xy);
	float normalDot = dot(historyNormal, worldNormal);
	float normalWeight = surfaceType < 1.5
		? smoothstep(
			mix(0.700, 0.880, motionStrictness),
			mix(0.930, 0.975, motionStrictness),
			normalDot
		)
		: smoothstep(
			mix(0.860, 0.945, motionStrictness),
			mix(0.975, 0.995, motionStrictness),
			normalDot
		);
	return typeWeight * depthWeight * normalWeight * step(0.5, historyAge);
}

void RsmAccumulateTap(
	const in ivec2 pixel,
	const in float spatialWeight,
	const in float surfaceType,
	const in vec3 worldNormal,
	const in float expectedDepth,
	const in float motionStrictness,
	inout vec4 signalSum,
	inout float ageSum,
	inout float weightSum
) {
	ivec2 size = RsmSize();
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, size))) return;
	RsmHistorySample history = RsmLoadPrevious(pixel);
	vec4 signal = history.signal;
	float historyAge;
	float valid = RsmHistoryGeometryWeight(
		history,
		surfaceType,
		worldNormal,
		expectedDepth,
		motionStrictness,
		historyAge
	);
	float weight = spatialWeight * valid;
	signalSum += signal * weight;
	ageSum += historyAge * weight;
	weightSum += weight;
}

RsmTemporalResult RsmResolveTemporal(
	const in vec3 currentColor,
	const in float currentConfidence,
	const in float currentAvailable,
	const in float surfaceType,
	const in float perceptualRoughness,
	const in float surfaceReactive,
	const in vec3 worldNormal,
	const in vec3 currentViewPosition,
	const in RsmReprojection reprojection,
	const in vec3 neighborhoodMinimum,
	const in vec3 neighborhoodMaximum
) {
	RsmTemporalResult result;
	result.color = max(currentColor, vec3(0.0));
	result.confidence = clamp(currentConfidence, 0.0, 1.0);
	result.historySupport = 0.0;
	result.signal = vec4(0.0);
	result.meta = vec4(0.0);

	// Motion is measured before the taps because it decides how hard they judge the
	// history, not how much of it survives.
	float cameraMotion = smoothstep(0.002, 0.12, length(cameraPosition - previousCameraPosition));
	float screenMotion = smoothstep(0.65, 5.0, reprojection.motionPixels);
	float temporalMotion = max(cameraMotion, screenMotion);

	ivec2 size = RsmSize();
	vec2 historyPosition = reprojection.previousRasterUv * vec2(size) - vec2(0.5);
	ivec2 historyBase = ivec2(floor(historyPosition));
	vec2 historyFraction = fract(historyPosition);
	vec4 historySignalSum = vec4(0.0);
	float historyAgeSum = 0.0;
	float historyWeightSum = 0.0;
	float expectedDepth = reprojection.expectedDepth;
	RsmAccumulateTap(historyBase + ivec2(0, 0), (1.0-historyFraction.x)*(1.0-historyFraction.y), surfaceType, worldNormal, expectedDepth, temporalMotion, historySignalSum, historyAgeSum, historyWeightSum);
	RsmAccumulateTap(historyBase + ivec2(1, 0), historyFraction.x*(1.0-historyFraction.y), surfaceType, worldNormal, expectedDepth, temporalMotion, historySignalSum, historyAgeSum, historyWeightSum);
	RsmAccumulateTap(historyBase + ivec2(0, 1), (1.0-historyFraction.x)*historyFraction.y, surfaceType, worldNormal, expectedDepth, temporalMotion, historySignalSum, historyAgeSum, historyWeightSum);
	RsmAccumulateTap(historyBase + ivec2(1, 1), historyFraction.x*historyFraction.y, surfaceType, worldNormal, expectedDepth, temporalMotion, historySignalSum, historyAgeSum, historyWeightSum);
	float reprojectionSupport = clamp(historyWeightSum, 0.0, 1.0) * reprojection.valid;

	float historyValid = step(0.05, historyWeightSum) * reprojection.valid;
	vec4 historySignal = historySignalSum / max(historyWeightSum, 1.0e-5);
	float historyAge = historyAgeSum / max(historyWeightSum, 1.0e-5);

	if (historyValid > 0.5 && currentAvailable > 0.5) {
		// The clamp stops history from outliving a lighting change. It only needs to
		// tighten under motion: at rest the history already sits on the current value so
		// the clamp never bites, and widening it there was measurably a no-op. While
		// moving it has to stay tight, otherwise stale light rides along for the frames
		// it takes the geometry tests to reject it.
		vec3 clampHalf = (neighborhoodMaximum - neighborhoodMinimum) * 0.5;
		vec3 encodedCenter = RsmTemporalEncodeColor(currentColor);
		vec3 halfWidth = clampHalf * mix(1.0, 0.5, temporalMotion);
		historySignal.rgb = RsmTemporalDecodeColor(clamp(
			RsmTemporalEncodeColor(historySignal.rgb),
			max(encodedCenter - halfWidth, vec3(0.0)),
			encodedCenter + halfWidth
		));
	}
	if (currentAvailable < 0.5 && historyValid < 0.5) {
		return result;
	}

	float progressiveWeight = clamp(historyAge / max(historyAge + 1.0, 1.0), 0.58, 0.9765625);
	float historyWeight = mix(0.72, progressiveWeight, step(1.5, surfaceType));
	if (surfaceType >= 1.5) {
		historyWeight = mix(0.80, 0.96875, smoothstep(2.0, 24.0, historyAge));
	} else {
		historyWeight = mix(0.72, 0.90, smoothstep(2.0, 32.0, historyAge));
	}

	float historyResponseCap = mix(
		0.92,
		0.97,
		smoothstep(0.18, 0.72, perceptualRoughness)
	);
	historyWeight = min(historyWeight, historyResponseCap);
	// Motion still has a say in the blend, just a smaller one. The tightened tests above
	// decide which history is allowed, but they cannot make the survivors track any
	// faster: once the clamp stops biting, stale history climbs back at the base rate of
	// about 3% per frame, which is roughly a second of ghosting. So movement also raises
	// the current frame's share, far less aggressively than the 28% cut it used to take.
	historyWeight *= mix(1.0, 0.90, temporalMotion) * historyValid;
	if (currentAvailable < 0.5) historyWeight = historyResponseCap * historyValid;
	if (surfaceType < 1.5 && currentConfidence < 0.02 && historySignal.a > 0.08) {
		historyWeight = max(historyWeight, mix(0.93, 0.68, temporalMotion) * historyValid);
	}

	result.color = max(mix(result.color, historySignal.rgb, historyWeight), vec3(0.0));
	result.confidence = mix(result.confidence, historySignal.a, historyWeight);
	result.historySupport = reprojectionSupport;
	// A surface that is itself moving cannot afford a long memory: its history is
	// reprojected from where it used to be. Everything else stands still in world space,
	// so its history stays valid and is the cheapest sample source there is.
	float maximumAge = mix(31.0, 6.0, clamp(surfaceReactive, 0.0, 1.0));
	float nextAge = currentAvailable > 0.5
		? min(historyAge + 1.0, maximumAge)
		: max(min(historyAge, maximumAge), 1.0);
	if (historyValid < 0.5) nextAge = 1.0;
	result.signal = vec4(result.color, result.confidence);
	result.meta = vec4(
		RsmOctEncode(normalize(worldNormal)),
		max(-currentViewPosition.z, 0.0),
		RsmPackState(surfaceType, nextAge)
	);
	return result;
}

#endif
