#ifndef WATER_TRANSMISSION_SURFACE_GLSL
#define WATER_TRANSMISSION_SURFACE_GLSL

float WaterTransmissionShadow(const in vec3 playerPos, const in float NoL) {
	vec4 shadowClip = shadowProjection * shadowModelView * vec4(playerPos, 1.0);
	if (abs(shadowClip.w) < 1.0e-6) {
		return 1.0;
	}
	vec3 shadowNdc = shadowClip.xyz / SafeDivisor(shadowClip.w);
	vec2 shadowClipXY = shadowNdc.xy;
	shadowNdc.xy = ShadowWarp(shadowClipXY);
	vec3 shadowCoord = shadowNdc * 0.5 + 0.5;
	if (shadowCoord.x <= 0.0 || shadowCoord.y <= 0.0 || shadowCoord.x >= 1.0 || shadowCoord.y >= 1.0 || shadowCoord.z <= 0.0 || shadowCoord.z >= 1.0) {
		return 1.0;
	}
	float coverageFade = ShadowSurfaceCoverageFade(shadowCoord.xy, length(playerPos));
	if (coverageFade <= 0.0001) {
		return 1.0;
	}

	float bias = mix(0.0017, 0.00055, Saturate(NoL)) + 0.00085;
	float centerDepth = texture2D(shadowtex0, shadowCoord.xy).r;
	float center = ShadowCompareDepth(shadowCoord.z, centerDepth, bias);
	#if FOXY_SHADOW_FILTERING == 0
		float hardFloorVisibility = 1.0 - FOXY_SHADOW_STRENGTH;
		return mix(1.0, mix(hardFloorVisibility, 1.0, center), coverageFade);
	#endif
	float contactGap = max(shadowCoord.z - bias - centerDepth, 0.0);
	float contactScale = mix(0.66, 1.0, smoothstep(0.00055, 0.0060 + FOXY_SHADOW_SOFTNESS * 0.0035, contactGap));
	float filterRadius = (1.15 + FOXY_SHADOW_SOFTNESS * 2.15) * mix(1.0, contactScale, 1.0 - center);
	float phase = ShadowTemporalPhase(gl_FragCoord.xy, frameCounter);
	float radialJitter = fract(phase * 1.73205080757 + 0.29);
	vec2 direction = ShadowDirection(fract(phase + 0.14142135623));
	#if FOXY_SHADOW_QUALITY <= 0
		const int transmissionShadowSamples = 4;
	#else
		const int transmissionShadowSamples = 8;
	#endif
	float visibility = 0.0;
	for (int i = 0; i < transmissionShadowSamples; i++) {
		direction = ShadowGoldenRotate(direction);
		float radius = ShadowDiskRadius(float(i), float(transmissionShadowSamples), radialJitter);
		vec2 sampleUv = clamp(ShadowSampleUv(shadowClipXY, direction * (filterRadius * radius)), vec2(0.001), vec2(0.999));
		float sampleDepth = texture2D(shadowtex0, sampleUv).r;
		visibility += ShadowCompareDepth(shadowCoord.z, sampleDepth, bias);
	}
	visibility /= float(transmissionShadowSamples);
	float floorVisibility = 1.0 - FOXY_SHADOW_STRENGTH;
	return mix(1.0, mix(floorVisibility, 1.0, visibility), coverageFade);
}

vec2 WaterRefractionUv(
	const in vec2 uv,
	const in vec3 baseNormalView,
	const in vec3 normalView,
	const in float waterDepth,
	const in float refractionMask
) {
	vec3 geometricNormal = normalize(baseNormalView);
	vec3 wavedNormal = normalize(normalView);
	float sameHemisphere = mix(-1.0, 1.0, step(0.0, dot(geometricNormal, wavedNormal)));
	geometricNormal *= sameHemisphere;
	float waveUp = dot(wavedNormal, geometricNormal);
	vec3 waveTangentView = wavedNormal - geometricNormal * waveUp;
	// The material packet already contains the complete animated spectrum and
	// rain-ripple normal. Measure only its displacement from the geometric fluid
	// face: the face's own slope is geometry, not an animated refraction offset.
	vec2 waveSlopeUv = waveTangentView.xy / max(abs(waveUp), 0.35);
	float waveStrength = Saturate(FOXY_WATER_WAVE_STRENGTH);
	float depthFade = smoothstep(0.10, 3.2, waterDepth) * (1.0 - smoothstep(170.0, 340.0, waterDepth));
	float amount = mix(0.080, 0.150, waveStrength) * depthFade * Saturate(refractionMask);
	vec2 refractedUv = uv - waveSlopeUv * amount;
	vec2 edge = min(uv, vec2(1.0) - uv);
	float edgeFade = smoothstep(0.0, 0.025, min(edge.x, edge.y));
	return mix(uv, clamp(refractedUv, vec2(0.001), vec2(0.999)), edgeFade);
}

vec2 WaterSnellTransmissionUv(
	const in vec2 sourceUv,
	const in vec3 incidentView,
	const in vec3 normalView,
	out float valid
) {
	vec3 airDirection = refract(normalize(incidentView), normalize(normalView), WATER_IOR);
	float directionLengthSquared = dot(airDirection, airDirection);
	if (directionLengthSquared <= 1.0e-7) {
		valid = 0.0;
		return sourceUv;
	}
	airDirection *= inversesqrt(directionLengthSquared);
	vec4 clip = gbufferProjection * vec4(airDirection, 1.0);
	if (clip.w <= 1.0e-5) {
		valid = 0.0;
		return sourceUv;
	}
	vec2 projectedUv = clip.xy / clip.w * 0.5 + 0.5;
	vec2 edge = min(projectedUv, vec2(1.0) - projectedUv);
	valid = smoothstep(0.0, 0.018, min(edge.x, edge.y));
	valid *= step(0.001, projectedUv.x) * step(projectedUv.x, 0.999);
	valid *= step(0.001, projectedUv.y) * step(projectedUv.y, 0.999);
	return clamp(projectedUv, vec2(0.001), vec2(0.999));
}

#endif
