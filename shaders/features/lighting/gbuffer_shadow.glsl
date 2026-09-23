#ifndef FOXY_GBUFFER_SHADOW_GLSL
#define FOXY_GBUFFER_SHADOW_GLSL

// Geometry shadow receiver/filter. Uses the owning gbuffer program uniforms
// and surface inputs; no attachment writes or stage entry point.
struct ShadowReceiver {
	vec3 coord;
	vec2 clipXY;
	vec2 depthSlope;
	float bias;
	float edgeFade;
};

vec3 ShadowNdcFromPlayerPos(const in vec3 playerPos) {
	vec3 aimedPlayerPos = FoEndShadowAim(shadowModelViewInverse) * playerPos;
	vec4 shadowClip = FoEndShadowProjection(shadowProjection) * shadowModelView * vec4(aimedPlayerPos, 1.0);
	return shadowClip.xyz / ShadowSafeDivisor(shadowClip.w);
}

ShadowReceiver ShadowBuildReceiver(
	const in float NoL,
	const in float biasLift,
	const in vec3 normalView,
	const in float skyLight
) {
	ShadowReceiver receiver;
	receiver.coord = vec3(0.5);
	receiver.clipXY = vec2(0.0);
	receiver.depthSlope = vec2(0.0);
	receiver.bias = 0.0;
	receiver.edgeFade = 0.0;

	float surfaceNoL = Saturate(NoL);
	float grazing = 1.0 - smoothstep(0.035, 0.32, surfaceNoL);
	float viewDistance = length(surfaceViewPosition);
	float distanceRatio = Saturate(viewDistance / max(FOXY_SHADOW_DISTANCE, 1.0));
	float projectionScale = max(abs(shadowProjection[0][0]), 1.0e-6);
	float worldTexel = 2.0 / (float(FOXY_SHADOW_RESOLUTION) * projectionScale);
	float normalOffset = worldTexel * (0.18 + distanceRatio * 0.18 + grazing * (0.38 + distanceRatio * 0.42));
	normalOffset = clamp(normalOffset, 0.018, 0.220);
	vec3 normalPlayer = normalize(mat3(gbufferModelViewInverse) * normalView);
	vec3 receiverPlayerPos = surfaceWorldPosition + normalPlayer * normalOffset;

	float interiorReceiver = 1.0 - smoothstep(0.045, 0.115, skyLight);
	#if defined(FOXY_DIM_END)
		interiorReceiver = 0.0;
	#endif
	if (interiorReceiver > 0.001) {
		vec3 receiverWorldPos = receiverPlayerPos + cameraPosition;
		vec3 blockCenter = floor(receiverWorldPos) + vec3(0.5);
		vec3 contractedWorldPos = blockCenter +
			(receiverWorldPos - blockCenter) * 0.54;
		receiverPlayerPos = mix(
			receiverPlayerPos,
			contractedWorldPos - cameraPosition,
			interiorReceiver
		);
	}
	vec3 shadowNdc = ShadowNdcFromPlayerPos(receiverPlayerPos);

	receiver.clipXY = shadowNdc.xy;
	receiver.coord = vec3(ShadowWarp(receiver.clipXY), shadowNdc.z) * 0.5 + 0.5;
	if (receiver.coord.x <= 0.0 || receiver.coord.y <= 0.0 || receiver.coord.x >= 1.0 || receiver.coord.y >= 1.0 || receiver.coord.z <= 0.0 || receiver.coord.z >= 1.0) {
		return receiver;
	}

	receiver.edgeFade = ShadowSurfaceCoverageFade(receiver.coord.xy, viewDistance);

	vec3 normalShadow = normalize(mat3(shadowModelView) * normalPlayer);
	float normalShadowZ = normalShadow.z;
	if (abs(normalShadowZ) < 0.08) {
		normalShadowZ = normalShadowZ < 0.0 ? -0.08 : 0.08;
	}
	mat4 foShadowProjection = FoEndShadowProjection(shadowProjection);
	float projectionX = ShadowSafeDivisor(foShadowProjection[0][0]);
	float projectionY = ShadowSafeDivisor(foShadowProjection[1][1]);
	receiver.depthSlope = -0.5 * foShadowProjection[2][2] * vec2(
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
	receiver.bias = baseBias + distanceBias + slopeBias + receiverPlaneBias + biasLift * 0.30;
	return receiver;
}

vec2 ShadowReceiverUv(const in ShadowReceiver receiver, const in vec2 offsetTexels) {
	return clamp(ShadowSampleUv(receiver.clipXY, offsetTexels), vec2(0.001), vec2(0.999));
}

float ShadowReceiverDepth(const in ShadowReceiver receiver, const in vec2 offsetTexels) {
	vec2 clipOffset = ShadowTexelOffsetToClip(offsetTexels);
	return receiver.coord.z + dot(receiver.depthSlope, clipOffset) - receiver.bias;
}

float ShadowHardwareCompare(const in ShadowReceiver receiver, const in vec2 offsetTexels) {
	vec2 uv = ShadowReceiverUv(receiver, offsetTexels);
	return shadow2D(shadowtex1, vec3(uv, ShadowReceiverDepth(receiver, offsetTexels))).x;
}

float ShadowHardwareCompareFiltered(
	const in ShadowReceiver receiver,
	const in ShadowFilterWarp filterWarp,
	const in vec2 offsetTexels
) {
	vec2 uv = ShadowFilterSampleUv(receiver.clipXY, receiver.coord.xy, filterWarp, offsetTexels);
	return shadow2D(shadowtex1, vec3(uv, ShadowReceiverDepth(receiver, offsetTexels))).x;
}

float ShadowTransmissionMarker(const in vec4 transmissionSample) {
	float transmissionCoverage = Saturate(transmissionSample.a);
	vec3 transmission = clamp(
		transmissionSample.rgb / max(transmissionCoverage, 1.0e-4),
		vec3(0.02),
		vec3(1.0)
	);
	return transmissionCoverage *
		(1.0 - step(0.998, max(max(transmission.r, transmission.g), transmission.b)));
}

bool ShadowHasTransmission(
	const in ShadowReceiver receiver,
	const in ShadowFilterWarp filterWarp,
	const in float filterRadius,
	const in float phase
) {
	vec2 centerUv = ShadowFilterSampleUv(
		receiver.clipXY,
		receiver.coord.xy,
		filterWarp,
		vec2(0.0)
	);
	float marker = ShadowTransmissionMarker(texture2D(shadowcolor0, centerUv));
	vec2 direction = ShadowDirection(fract(phase + 0.61803398875));
	float probeRadius = max(filterRadius * 0.82, 0.18);
	for (int i = 0; i < 4; i++) {
		vec2 uv = ShadowFilterSampleUv(
			receiver.clipXY,
			receiver.coord.xy,
			filterWarp,
			direction * probeRadius
		);
		marker = max(marker, ShadowTransmissionMarker(texture2D(shadowcolor0, uv)));
		direction = vec2(-direction.y, direction.x);
	}
	return marker > 0.002;
}

vec2 ShadowBlockerSearch(
	const in ShadowReceiver receiver,
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

	float centerGap = max(ShadowReceiverDepth(receiver, vec2(0.0)) - centerDepth, 0.0);
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
		vec2 uv = ShadowReceiverUv(receiver, offsetTexels);
		float sampleDepth = texture2D(shadowtex0, uv).r;
		float gap = max(ShadowReceiverDepth(receiver, offsetTexels) - sampleDepth, 0.0);
		float weight = smoothstep(threshold, threshold * 3.0, gap);
		blockerGapSum += gap * weight;
		blockerWeight += weight;
	}

	if (blockerWeight <= 0.0001) {
		return vec2(0.0);
	}
	return vec2(blockerGapSum / blockerWeight, blockerWeight / sampleCount);
}

float ShadowFilterPcf(
	const in ShadowReceiver receiver,
	const in ShadowFilterWarp filterWarp,
	const in float filterRadius,
	const in float phase,
	const in bool sampleTransmission,
	out vec3 transmissionFactor
) {
	#if FOXY_SHADOW_FILTER_SAMPLES > 12
		const int maxFilterSamples = 12;
	#else
		const int maxFilterSamples = FOXY_SHADOW_FILTER_SAMPLES;
	#endif
	int activeSamples = maxFilterSamples;
	#if FOXY_SHADOW_FILTER_SAMPLES > 8
		if (filterRadius < 1.65) {
			activeSamples = 8;
		}
	#endif
	#if FOXY_SHADOW_FILTER_SAMPLES > 12
		if (filterRadius >= 1.65 && filterRadius < 3.10) {
			activeSamples = 12;
		}
	#endif

	float sampleCount = float(activeSamples);
	float radialJitter = fract(phase * 1.61803398875 + 0.21);
	vec2 direction = ShadowDirection(fract(phase + 0.17320508076));
	#if FOXY_SHADOW_PCF_SPECIALIZE == 1
		// The caller discards transmission when this flag is false. Keep the
		// exact PCF sequence, but do not carry color-energy state in that loop.
		if (!sampleTransmission) {
			float visibility = 0.0;
			for (int i = 0; i < maxFilterSamples; i++) {
				if (i >= activeSamples) break;
				direction = ShadowGoldenRotate(direction);
				float radius = ShadowDiskRadius(float(i), sampleCount, radialJitter);
				vec2 offsetTexels = direction * (filterRadius * radius);
				visibility += ShadowHardwareCompareFiltered(receiver, filterWarp, offsetTexels);
			}
			transmissionFactor = vec3(1.0);
			return visibility / max(sampleCount, 1.0);
		}
	#endif
	float visibility = 0.0;
	vec3 transmissionEnergy = vec3(0.0);
	for (int i = 0; i < maxFilterSamples; i++) {
		if (i >= activeSamples) break;
		direction = ShadowGoldenRotate(direction);
		float radius = ShadowDiskRadius(float(i), sampleCount, radialJitter);
		vec2 offsetTexels = direction * (filterRadius * radius);
		float opaqueVisibility = ShadowHardwareCompareFiltered(
			receiver,
			filterWarp,
			offsetTexels
		);
		visibility += opaqueVisibility;
		vec3 sampleEnergy = vec3(opaqueVisibility);

		if (sampleTransmission) {
			vec2 uv = ShadowFilterSampleUv(
				receiver.clipXY,
				receiver.coord.xy,
				filterWarp,
				offsetTexels
			);
			vec4 transmissionSample = texture2D(shadowcolor0, uv);
			float transmissionCoverage = Saturate(transmissionSample.a);
			vec3 transmission = clamp(
				transmissionSample.rgb / max(transmissionCoverage, 1.0e-4),
				vec3(0.02),
				vec3(1.0)
			);
			float transmissionMarker = transmissionCoverage *
				(1.0 - step(
					0.998,
					max(max(transmission.r, transmission.g), transmission.b)
				));
			if (transmissionMarker > 0.0) {
				float allGeometryDepth = texture2D(shadowtex0, uv).r;
				float allGeometryVisibility = ShadowCompareDepth(
					ShadowReceiverDepth(receiver, offsetTexels),
					allGeometryDepth,
					0.0
				);
				float glassVisibility = max(
					opaqueVisibility - allGeometryVisibility,
					0.0
				) * transmissionMarker;
				sampleEnergy += glassVisibility *
					(transmission - vec3(1.0));
			}
		}
		transmissionEnergy += sampleEnergy;
	}
	float filteredVisibility = visibility / max(sampleCount, 1.0);
	vec3 filteredEnergy = transmissionEnergy / max(sampleCount, 1.0);
	transmissionFactor = filteredVisibility > 0.001
		? clamp(
			filteredEnergy / filteredVisibility,
			vec3(0.02),
			vec3(1.0)
		)
		: vec3(1.0);
	return filteredVisibility;
}

vec4 ShadowEvaluate(
	const in ShadowReceiver receiver,
	const in float lightAltitude,
	const in bool sampleTransmission,
	out float visibility
) {
	visibility = 1.0;
	if (receiver.edgeFade <= 0.0001) {
		return vec4(1.0, 1.0, 1.0, 0.0);
	}

	float centerDepth = texture2D(shadowtex0, receiver.coord.xy).r;
	float center = ShadowHardwareCompare(receiver, vec2(0.0));
	#if FOXY_SHADOW_FILTERING == 0
		float hardFloorVisibility = 1.0 - FOXY_SHADOW_STRENGTH;
		float hardShadowVisibility = mix(hardFloorVisibility, 1.0, center);
		visibility = mix(1.0, hardShadowVisibility, receiver.edgeFade);
		return vec4(1.0, 1.0, 1.0, 0.0);
	#endif
	float phase = ShadowTemporalPhase(gl_FragCoord.xy, frameCounter);
	float altitudeStability = smoothstep(0.025, 0.20, max(lightAltitude, 0.0));
	float searchRadius = (4.00 + FOXY_SHADOW_SOFTNESS * 5.00) * mix(0.75, 1.0, altitudeStability);
	vec2 blockerInfo = ShadowBlockerSearch(receiver, centerDepth, center, searchRadius, phase);

	float gapLimit = 0.0065 + FOXY_SHADOW_SOFTNESS * 0.0050;
	float gapResponse = sqrt(smoothstep(0.00018, gapLimit, blockerInfo.x));
	float coverageResponse = smoothstep(0.02, 0.22, blockerInfo.y);
	float minimumRadius = SHADOW_MIN_FILTER_TEXELS *
		mix(1.06, 1.0, altitudeStability);
	float maximumPenumbra = (0.12 + FOXY_SHADOW_SOFTNESS * 1.00) * mix(0.80, 1.0, altitudeStability);
	float filterRadius = minimumRadius + maximumPenumbra * gapResponse * coverageResponse;
	float centerGap = max(ShadowReceiverDepth(receiver, vec2(0.0)) - centerDepth, 0.0);
	float contactScale = mix(0.62, 1.0, smoothstep(0.00018, 0.0028 + FOXY_SHADOW_SOFTNESS * 0.0022, centerGap));
	filterRadius *= mix(1.0, contactScale, 1.0 - Saturate(center));
	filterRadius = clamp(filterRadius, 0.10, 2.50);
	ShadowFilterWarp filterWarp = ShadowBuildFilterWarp(receiver.clipXY);
	bool hasTransmission = sampleTransmission && ShadowHasTransmission(
		receiver,
		filterWarp,
		filterRadius,
		phase
	);
	vec3 filteredTransmission = vec3(1.0);
	float filtered = ShadowFilterPcf(
		receiver,
		filterWarp,
		filterRadius,
		phase,
		hasTransmission,
		filteredTransmission
	);

	float floorVisibility = 1.0 - FOXY_SHADOW_STRENGTH;
	float shadowVisibility = mix(floorVisibility, 1.0, Saturate(filtered));
	visibility = mix(1.0, shadowVisibility, receiver.edgeFade);
	if (!hasTransmission || visibility <= 0.0) {
		return vec4(1.0, 1.0, 1.0, 0.0);
	}
	vec3 transmissionColor = mix(
		vec3(1.0),
		filteredTransmission,
		receiver.edgeFade
	);
	float transmissionAmount = max(
		max(1.0 - filteredTransmission.r, 1.0 - filteredTransmission.g),
		1.0 - filteredTransmission.b
	);
	return vec4(
		transmissionColor,
		Saturate(transmissionAmount) * receiver.edgeFade
	);
}


#endif
