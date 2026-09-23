#ifndef FOXY_NATIVE_TEMPORAL_GLSL
#define FOXY_NATIVE_TEMPORAL_GLSL

#include "/lib/contracts/material.glsl"
#if FOXY_MATERIAL_REFLECTIONS == 1
	#define PT_GBUFFER_READ
	#include "/lib/pt_gbuffer.glsl"
	#undef PT_GBUFFER_READ
	#include "/features/material/reflection_policy.glsl"
#endif

#if FOXY_VOLUMETRIC_LIGHT == 1 && !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
	#define FOXY_TAA_CURRENT_SCENE colortex0
#else
	#define FOXY_TAA_CURRENT_SCENE colortex14
#endif

vec4 FormalHistoryOutput = vec4(0.0);

float NativeTemporalReflectionReactive(
	const in vec4 surfaceData,
	const in float depthRaw,
	const in TaaSlotReprojection reprojection
) {
	float reflectionSurface = MaterialIsGlass(surfaceData);
	#if FOXY_MATERIAL_REFLECTIONS == 1
		PtGbufferSample material = PtDecodeGbuffer(surfaceData, depthRaw);
		float perceptualRoughness = sqrt(Saturate(material.roughness));
		float smoothReflection = 1.0 - step(
			1.5,
			MaterialReflectionType(perceptualRoughness)
		);
		float reflectionEnabled = MaterialReflectionSurfaceEnabled(
			material.valid,
			material.surfaceClass,
			perceptualRoughness,
			material.metalness
		);
		reflectionSurface = max(
			reflectionSurface,
			smoothReflection * reflectionEnabled
		);
	#endif
	float motionPixels = length(
		reprojection.motionUv * vec2(textureSize(colortex12, 0))
	);
	float cameraMotion = length(cameraPosition - previousCameraPosition);
	float temporalMotion = max(
		smoothstep(0.15, 1.25, motionPixels),
		smoothstep(0.002, 0.035, cameraMotion)
	);
	return Saturate(reflectionSurface * temporalMotion);
}

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

// Streaming reduction keeps each neighbor alive only until it contributes.
// The visit order matches the reference's left-associated luma sum.
struct NativeNeighborhood {
	vec3 colorMinimum;
	vec3 colorMaximum;
	float lumaMinimum;
	float lumaMaximum;
	float lumaSum;
};

void NativeAccumulateNeighbor(
	const in ivec2 texel, const in ivec2 size, inout NativeNeighborhood bounds
) {
	vec3 linearColor = NativeCurrentLinear(texel, size);
	float luma = Luma(linearColor);
	vec3 compressed = linearColor / (1.0 + luma);
	bounds.colorMinimum = min(bounds.colorMinimum, compressed);
	bounds.colorMaximum = max(bounds.colorMaximum, compressed);
	bounds.lumaMinimum = min(bounds.lumaMinimum, luma);
	bounds.lumaMaximum = max(bounds.lumaMaximum, luma);
	bounds.lumaSum += luma;
}

NativeNeighborhood NativeGatherNeighborhood(
	const in ivec2 center, const in ivec2 size, const in vec3 centerLinear
) {
	float luma = Luma(centerLinear);
	vec3 compressed = centerLinear / (1.0 + luma);
	NativeNeighborhood bounds;
	bounds.colorMinimum = compressed;
	bounds.colorMaximum = compressed;
	bounds.lumaMinimum = luma;
	bounds.lumaMaximum = luma;
	bounds.lumaSum = luma;
	NativeAccumulateNeighbor(center + ivec2(-1, -1), size, bounds);
	NativeAccumulateNeighbor(center + ivec2( 0, -1), size, bounds);
	NativeAccumulateNeighbor(center + ivec2( 1, -1), size, bounds);
	NativeAccumulateNeighbor(center + ivec2(-1,  0), size, bounds);
	NativeAccumulateNeighbor(center + ivec2( 1,  0), size, bounds);
	NativeAccumulateNeighbor(center + ivec2(-1,  1), size, bounds);
	NativeAccumulateNeighbor(center + ivec2( 0,  1), size, bounds);
	NativeAccumulateNeighbor(center + ivec2( 1,  1), size, bounds);
	return bounds;
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
	ivec2 centerTexel = clamp(
		ivec2(currentRasterUv * vec2(sceneSize)),
		ivec2(0),
		sceneSize - ivec2(1)
	);
	#if FOXY_TAA_STREAM_NEIGHBORHOOD == 1 && FOXY_TAAU_ACTIVE == 0
		vec3 currentLinear = NativeCurrentLinear(centerTexel, sceneSize);
		vec3 currentCompressed = NativeCompress(currentLinear);
		NativeNeighborhood bounds = NativeGatherNeighborhood(centerTexel, sceneSize, currentLinear);
		float meanLinear = bounds.lumaSum / 9.0;
		float neighborhoodMinimum = bounds.lumaMinimum / (1.0 + bounds.lumaMinimum);
		float neighborhoodMaximum = bounds.lumaMaximum / (1.0 + bounds.lumaMaximum);
		float neighborhoodMean = meanLinear / (1.0 + meanLinear);
		vec3 neighborhoodColorMinimum = bounds.colorMinimum;
		vec3 neighborhoodColorMaximum = bounds.colorMaximum;
	#else
	vec3 linear0 = NativeCurrentLinear(centerTexel, sceneSize);
	vec3 linear1 = NativeCurrentLinear(centerTexel + ivec2(-1, -1), sceneSize);
	vec3 linear2 = NativeCurrentLinear(centerTexel + ivec2( 0, -1), sceneSize);
	vec3 linear3 = NativeCurrentLinear(centerTexel + ivec2( 1, -1), sceneSize);
	vec3 linear4 = NativeCurrentLinear(centerTexel + ivec2(-1,  0), sceneSize);
	vec3 linear5 = NativeCurrentLinear(centerTexel + ivec2( 1,  0), sceneSize);
	vec3 linear6 = NativeCurrentLinear(centerTexel + ivec2(-1,  1), sceneSize);
	vec3 linear7 = NativeCurrentLinear(centerTexel + ivec2( 0,  1), sceneSize);
	vec3 linear8 = NativeCurrentLinear(centerTexel + ivec2( 1,  1), sceneSize);
	vec3 reconstructedCurrent = linear0;
	#if FOXY_TAAU_ACTIVE == 1
		// Reuse the centered neighborhood for bilinear reconstruction in any quadrant.
		vec2 sourceOffset = currentRasterUv * vec2(sceneSize) -
			(vec2(centerTexel) + vec2(0.5));
		vec2 sourceFraction = abs(sourceOffset);
		vec3 horizontal = sourceOffset.x < 0.0 ? linear4 : linear5;
		vec3 vertical = sourceOffset.y < 0.0 ? linear2 : linear7;
		vec3 diagonal = sourceOffset.y < 0.0
			? (sourceOffset.x < 0.0 ? linear1 : linear3)
			: (sourceOffset.x < 0.0 ? linear6 : linear8);
		reconstructedCurrent = mix(
			mix(linear0, horizontal, sourceFraction.x),
			mix(vertical, diagonal, sourceFraction.x),
			sourceFraction.y
		);
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

	vec3 compressed0 = linear0 / (1.0 + luma0);
	vec3 compressed1 = linear1 / (1.0 + luma1);
	vec3 compressed2 = linear2 / (1.0 + luma2);
	vec3 compressed3 = linear3 / (1.0 + luma3);
	vec3 compressed4 = linear4 / (1.0 + luma4);
	vec3 compressed5 = linear5 / (1.0 + luma5);
	vec3 compressed6 = linear6 / (1.0 + luma6);
	vec3 compressed7 = linear7 / (1.0 + luma7);
	vec3 compressed8 = linear8 / (1.0 + luma8);
	vec3 neighborhoodColorMinimum = min(
		min(min(compressed0, compressed1), min(compressed2, compressed3)),
		min(min(compressed4, compressed5), min(compressed6, min(compressed7, compressed8)))
	);
	vec3 neighborhoodColorMaximum = max(
		max(max(compressed0, compressed1), max(compressed2, compressed3)),
		max(max(compressed4, compressed5), max(compressed6, max(compressed7, compressed8)))
	);

	#endif

	TaaSlotReprojection reprojection = TaaSlotBuildReprojection(currentRasterUv, viewUv);
	vec3 historyCompressed = max(
		NativeHistoryCubic(reprojection.previousUv),
		vec3(0.0)
	);
	vec3 boundedHistory = clamp(
		historyCompressed,
		neighborhoodColorMinimum,
		neighborhoodColorMaximum
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
	vec2 currentRenderUv = SrSceneSampleUv(currentRasterUv);
	vec4 currentSurfaceData = texture2D(colortex2, currentRenderUv);
	float glassDepth = MaterialIsGlass(currentSurfaceData);
	float currentDepth = glassDepth > 0.5
		? texture2D(depthtex0, currentRenderUv).r
		: texture2D(depthtex1, currentRenderUv).r;
	float reflectionReactive = NativeTemporalReflectionReactive(
		currentSurfaceData,
		currentDepth,
		reprojection
	);
	historyWeight *= 1.0 - reflectionReactive;
	vec3 resolvedCompressed = mix(
		currentCompressed,
		boundedHistory,
		historyWeight
	);

	float resolvedLuma = Luma(resolvedCompressed);
	float positiveDetail = max(resolvedLuma - neighborhoodMean, 0.0);
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
