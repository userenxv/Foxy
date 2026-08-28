#ifndef FOXY_NATIVE_TEMPORAL_GLSL
#define FOXY_NATIVE_TEMPORAL_GLSL

// Closest-depth reprojection with bounded rectification and geometry validation.

#if FOXY_VOLUMETRIC_LIGHT == 1 && !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
	#define FOXY_TAA_CURRENT_SCENE colortex0
#else
	#define FOXY_TAA_CURRENT_SCENE colortex14
#endif

vec4 FormalHistoryOutput = vec4(0.0);

vec3 NativeCompress(const in vec3 linearColor) {
	vec3 safeColor = max(linearColor, vec3(0.0));
	return safeColor / (1.0 + Luma(safeColor));
}

vec3 NativeExpand(const in vec3 compressedColor) {
	vec3 safeColor = max(compressedColor, vec3(0.0));
	return safeColor / max(1.0 - Luma(safeColor), 1.0e-4);
}

vec3 NativeCurrentLinear(const in ivec2 texel, const in ivec2 size) {
	ivec2 safeTexel = clamp(texel, ivec2(0), size - ivec2(1));
	return max(
		DecodeSceneColor(texelFetch(FOXY_TAA_CURRENT_SCENE, safeTexel, 0).rgb),
		vec3(0.0)
	);
}

vec3 NativeHistoryCubic(const in vec2 uv) {
	vec2 size = vec2(max(textureSize(colortex12, 0), ivec2(1)));
	vec2 pixel = 1.0 / size;
	vec2 center = floor(uv * size - 0.5) + 0.5;
	vec2 phase = uv * size - center;
	vec2 phase2 = phase * phase;
	vec2 phase3 = phase2 * phase;

	vec2 outerLow = -0.5 * phase + phase2 - 0.5 * phase3;
	vec2 innerLow = 1.0 - 2.5 * phase2 + 1.5 * phase3;
	vec2 innerHigh = 0.5 * phase + 2.0 * phase2 - 1.5 * phase3;
	vec2 outerHigh = -0.5 * phase2 + 0.5 * phase3;
	vec2 inner = innerLow + innerHigh;

	vec2 edge = pixel * 0.5;
	vec2 low = clamp((center - 1.0) * pixel, edge, vec2(1.0) - edge);
	vec2 high = clamp((center + 2.0) * pixel, edge, vec2(1.0) - edge);
	vec2 middle = clamp(
		(center + innerHigh / max(inner, vec2(1.0e-5))) * pixel,
		edge,
		vec2(1.0) - edge
	);

	float weight0 = inner.x * outerLow.y;
	float weight1 = outerLow.x * inner.y;
	float weight2 = inner.x * inner.y;
	float weight3 = outerHigh.x * inner.y;
	float weight4 = inner.x * outerHigh.y;
	float weightSum = weight0 + weight1 + weight2 + weight3 + weight4;
	vec3 middleSample = texture2D(colortex12, middle).rgb;
	vec3 reconstructed =
		texture2D(colortex12, vec2(middle.x, low.y)).rgb * weight0 +
		texture2D(colortex12, vec2(low.x, middle.y)).rgb * weight1 +
		middleSample * weight2 +
		texture2D(colortex12, vec2(high.x, middle.y)).rgb * weight3 +
		texture2D(colortex12, vec2(middle.x, high.y)).rgb * weight4;
	return reconstructed / max(weightSum, 1.0e-5);
}

float NativeHistoryGeometryConfidence(
	const in vec2 uv,
	const in float expectedPreviousMetric
) {
	// Validate history against all four depths in its filter footprint.
	vec4 packedDepth = textureGather(colortex12, uv, 3);
	vec4 payloadValid = step(
		vec4(-(FOXY_TAA_SLOT_HISTORY_DEPTH_BASE + FOXY_TAA_SLOT_HISTORY_DEPTH_SCALE) - 0.001),
		packedDepth
	) * step(
		packedDepth,
		vec4(-FOXY_TAA_SLOT_HISTORY_DEPTH_BASE + 0.001)
	);
	vec4 previousMetric = clamp(
		(-packedDepth - FOXY_TAA_SLOT_HISTORY_DEPTH_BASE) /
			FOXY_TAA_SLOT_HISTORY_DEPTH_SCALE,
		vec4(0.0),
		vec4(1.0)
	);
	float depthTolerance = min(0.00075 + fwidth(expectedPreviousMetric), 0.02);
	vec4 support = payloadValid * (vec4(1.0) - smoothstep(
		vec4(depthTolerance),
		vec4(depthTolerance * 4.0),
		abs(previousMetric - expectedPreviousMetric)
	));
	return max(max(support.x, support.y), max(support.z, support.w));
}

vec3 ResolveTemporalWorldEncoded(
	const in vec2 viewUv,
	const in vec3 currentWorldEncoded
) {
	ivec2 sceneTextureSize = max(textureSize(FOXY_TAA_CURRENT_SCENE, 0), ivec2(1));
	ivec2 sceneSize = min(max(ivec2(SrRenderSize()), ivec2(1)), sceneTextureSize);
	vec2 pixel = 1.0 / vec2(sceneSize);
	vec2 currentRasterUv = clamp(
		viewUv + temporalJitter * 0.5,
		pixel * 0.5,
		vec2(1.0) - pixel * 0.5
	);
	ivec2 centerTexel;
	vec3 linear0;
	vec3 linear1;
	vec3 linear2;
	vec3 linear3;
	vec3 linear4;
	vec3 linear5;
	vec3 linear6;
	vec3 linear7;
	vec3 linear8;
	vec3 reconstructedCurrent;

	#if FOXY_TAAU_ACTIVE == 1
		vec2 sourcePosition = currentRasterUv * vec2(sceneSize) - vec2(0.5);
		ivec2 sourceBase = ivec2(floor(sourcePosition));
		vec2 sourceFraction = fract(sourcePosition);
		centerTexel = sourceBase;
		linear0 = NativeCurrentLinear(sourceBase + ivec2( 0,  0), sceneSize);
		linear1 = NativeCurrentLinear(sourceBase + ivec2( 1,  0), sceneSize);
		linear2 = NativeCurrentLinear(sourceBase + ivec2( 0,  1), sceneSize);
		linear3 = NativeCurrentLinear(sourceBase + ivec2( 1,  1), sceneSize);
		linear4 = NativeCurrentLinear(sourceBase + ivec2(-1, -1), sceneSize);
		linear5 = NativeCurrentLinear(sourceBase + ivec2( 0, -1), sceneSize);
		linear6 = NativeCurrentLinear(sourceBase + ivec2( 1, -1), sceneSize);
		linear7 = NativeCurrentLinear(sourceBase + ivec2(-1,  0), sceneSize);
		linear8 = NativeCurrentLinear(sourceBase + ivec2(-1,  1), sceneSize);
		reconstructedCurrent = mix(
			mix(linear0, linear1, sourceFraction.x),
			mix(linear2, linear3, sourceFraction.x),
			sourceFraction.y
		);
	#else
		centerTexel = clamp(
			ivec2(currentRasterUv * vec2(sceneSize)),
			ivec2(0),
			sceneSize - ivec2(1)
		);
		linear0 = NativeCurrentLinear(centerTexel, sceneSize);
		linear1 = NativeCurrentLinear(centerTexel + ivec2(-1, -1), sceneSize);
		linear2 = NativeCurrentLinear(centerTexel + ivec2( 0, -1), sceneSize);
		linear3 = NativeCurrentLinear(centerTexel + ivec2( 1, -1), sceneSize);
		linear4 = NativeCurrentLinear(centerTexel + ivec2(-1,  0), sceneSize);
		linear5 = NativeCurrentLinear(centerTexel + ivec2( 1,  0), sceneSize);
		linear6 = NativeCurrentLinear(centerTexel + ivec2(-1,  1), sceneSize);
		linear7 = NativeCurrentLinear(centerTexel + ivec2( 0,  1), sceneSize);
		linear8 = NativeCurrentLinear(centerTexel + ivec2( 1,  1), sceneSize);
		reconstructedCurrent = linear0;
	#endif

	vec3 currentCompressed = NativeCompress(reconstructedCurrent);
	float luma0 = Luma(linear0);
	float luma1 = Luma(linear1);
	float luma2 = Luma(linear2);
	float luma3 = Luma(linear3);
	float luma4 = Luma(linear4);
	float luma5 = Luma(linear5);
	float luma6 = Luma(linear6);
	float luma7 = Luma(linear7);
	float luma8 = Luma(linear8);
	float neighborhoodMinimumLinear = min(
		min(min(luma0, luma1), min(luma2, luma3)),
		min(min(luma4, luma5), min(luma6, min(luma7, luma8)))
	);
	float neighborhoodMaximumLinear = max(
		max(max(luma0, luma1), max(luma2, luma3)),
		max(max(luma4, luma5), max(luma6, max(luma7, luma8)))
	);
	float neighborhoodMeanLinear = (
		luma0 + luma1 + luma2 + luma3 + luma4 +
		luma5 + luma6 + luma7 + luma8
	) / 9.0;
	float neighborhoodMinimum = neighborhoodMinimumLinear /
		(1.0 + neighborhoodMinimumLinear);
	float neighborhoodMaximum = neighborhoodMaximumLinear /
		(1.0 + neighborhoodMaximumLinear);
	float neighborhoodMean = neighborhoodMeanLinear /
		(1.0 + neighborhoodMeanLinear);

	TaaSlotReprojection reprojection = TaaSlotBuildReprojection(currentRasterUv);
	vec3 historyCompressed = max(
		NativeHistoryCubic(reprojection.previousUv),
		vec3(0.0)
	);
	float currentLuma = Luma(currentCompressed);
	float historyLuma = Luma(historyCompressed);
	float boundedHistoryLuma = clamp(
		historyLuma,
		neighborhoodMinimum,
		neighborhoodMaximum
	);
	vec3 currentChroma = currentCompressed - vec3(currentLuma);
	vec3 historyChroma = historyCompressed - vec3(historyLuma);
	vec3 chromaDifference = historyChroma - currentChroma;
	float chromaDistance = max(
		abs(chromaDifference.x),
		max(abs(chromaDifference.y), abs(chromaDifference.z))
	);
	chromaDifference *= min(
		1.0,
		FOXY_TAA_CHROMA_LIMIT / max(chromaDistance, 1.0e-5)
	);
	vec3 boundedHistory = max(
		vec3(boundedHistoryLuma) + currentChroma + chromaDifference,
		vec3(0.0)
	);

	float geometryConfidence = NativeHistoryGeometryConfidence(
		reprojection.previousUv,
		reprojection.expectedPreviousMetric
	);
	float historyAllowed = reprojection.valid * (1.0 - reprojection.firstPerson) *
		geometryConfidence;
	#if FOXY_TAAU_ACTIVE == 1
		float historyWeight = FOXY_TAAU_HISTORY_WEIGHT * historyAllowed;
	#else
		float historyWeight = FOXY_TAA_HISTORY_WEIGHT * historyAllowed;
	#endif
	vec3 resolvedCompressed = mix(
		currentCompressed,
		boundedHistory,
		historyWeight
	);

	// Positive-only presentation sharpening never feeds history.
	float resolvedLuma = Luma(resolvedCompressed);
	float positiveDetail = max(currentLuma - neighborhoodMean, 0.0);
	float displayLuma = clamp(
		resolvedLuma + positiveDetail * FOXY_TAA_SHARPEN,
		neighborhoodMinimum,
		neighborhoodMaximum
	);
	vec3 displayCompressed = max(
		resolvedCompressed + vec3(displayLuma - resolvedLuma),
		vec3(0.0)
	);
	vec3 displayLinear = NativeExpand(displayCompressed);

	FormalHistoryOutput = vec4(
		resolvedCompressed,
		TaaSlotPackHistoryMetric(reprojection.currentMetric)
	);
	return EncodeSceneColor(max(displayLinear, vec3(0.0)));
}

#undef FOXY_TAA_CURRENT_SCENE

#endif
