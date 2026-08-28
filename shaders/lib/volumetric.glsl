#ifndef FOXY_VOLUMETRIC_GLSL
#define FOXY_VOLUMETRIC_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/lighting.glsl"
#include "/lib/sky.glsl"
#include "/lib/shadow.glsl"
#include "/lib/trace_common.glsl"
#include "/lib/celestial.glsl"
#include "/lib/clouds.glsl"
#include "/lib/water.glsl"

uniform sampler2D shadowtex1;

#if FOXY_VL_QUALITY <= 0
	#define FOXY_VL_MIN_STEPS 8
	#define FOXY_VL_MAX_STEPS 16
	#define FOXY_VL_EXTENDED_MAX_STEPS 32
	#define FOXY_UNDERWATER_VL_MIN_STEPS 10
	#define FOXY_UNDERWATER_VL_MAX_STEPS 24
	#define FOXY_UNDERWATER_VL_STEPS 30
#elif FOXY_VL_QUALITY == 1
	#define FOXY_VL_MIN_STEPS 10
	#define FOXY_VL_MAX_STEPS 22
	#define FOXY_VL_EXTENDED_MAX_STEPS 44
	#define FOXY_UNDERWATER_VL_MIN_STEPS 14
	#define FOXY_UNDERWATER_VL_MAX_STEPS 32
	#define FOXY_UNDERWATER_VL_STEPS 54
#else
	#define FOXY_VL_MIN_STEPS 12
	#define FOXY_VL_MAX_STEPS 28
	#define FOXY_VL_EXTENDED_MAX_STEPS 56
	#define FOXY_UNDERWATER_VL_MIN_STEPS 18
	#define FOXY_UNDERWATER_VL_MAX_STEPS 48
	#define FOXY_UNDERWATER_VL_STEPS 72
#endif

struct VolumeSample {
	vec3 scattering;
	float transmittance;
	float density;
	float shadow;
	float coverage;
	float tyndall;
	float clump;
	float phase;
	float terrainBlock;
	float shadowMask;
	float historyDistance;
};

VolumeSample VolumeEmptySample() {
	VolumeSample result;
	result.scattering = vec3(0.0);
	result.transmittance = 1.0;
	result.density = 0.0;
	result.shadow = 1.0;
	result.coverage = 0.0;
	result.tyndall = 0.0;
	result.clump = 0.0;
	result.phase = 0.0;
	result.terrainBlock = 0.0;
	result.shadowMask = 0.0;
	result.historyDistance = 1.0;
	return result;
}

float VolumeRayleighPhase(const in float mu) {
	return 0.0596831 * (1.0 + mu * mu);
}

float VolumeMiePhase(const in float mu, const in float g) {
	float gg = g * g;
	float denom = max(1.0 + gg - 2.0 * g * mu, 0.035);
	return (1.0 - gg) / (12.5663706 * pow(denom, 1.5));
}

float StandardMiePhase(const in float mu, const in float anisotropy) {
	float g = mix(0.42, 0.72, Saturate(anisotropy));
	float phase = 0.0;
	float weight = 1.0;
	for (int order = 0; order < 4; order++) {
		phase += VolumeMiePhase(mu, g) * weight;
		g *= 0.70;
		weight *= 0.50;
	}
	return phase;
}

vec2 StandardFogField(const in vec3 worldPos, const in float time) {
	#if FOXY_VL_CLUMPY_FOG == 1
		vec2 wind = vec2(0.000325, -0.000250) * time;
		vec3 fieldCoord = worldPos * 0.003125;
		fieldCoord.xz += wind;
		vec3 fieldNoise = texture3D(cloudDetail3D, fract(fieldCoord)).rgb;
		float broadField = fieldNoise.r - 0.18;
		float erosionField = dot(fieldNoise.gb, vec2(0.65, 0.35)) - 0.71;
		float fieldSample = Saturate(broadField + erosionField * 0.30);
		float bankShape = smoothstep(0.24, 0.80, fieldSample);
		float softCore = 1.0 - abs(fieldSample * 2.0 - 1.0);
		float clusteredDensity = mix(0.20, 2.12, bankShape) * mix(0.92, 1.08, softCore);
		float clumpiness = Saturate(FOXY_VL_CLUMPINESS);
		float densityScale = clamp(mix(1.0, clusteredDensity, clumpiness), 0.16, 2.65);
		float clump = bankShape * clumpiness;
		return vec2(densityScale, clump);
	#else
		return vec2(1.0, 0.0);
	#endif
}

float AirVerticalProfile(
	const in float worldY,
	const in float fadeStart,
	const in float fadeEnd
) {
	float fadeRange = max(fadeEnd - fadeStart, 1.0);
	float heightPhase = Saturate((worldY - fadeStart) / fadeRange);
	float exponentialFalloff = exp(-4.0 * heightPhase);
	float terminalFade = 1.0 - smoothstep(0.75, 1.0, heightPhase);
	return exponentialFalloff * terminalFade;
}

vec3 AirTimeWeights(const in float sunAltitude) {
	float noon = smoothstep(0.12, 0.52, sunAltitude);
	float night = 1.0 - smoothstep(-0.16, -0.04, sunAltitude);
	float twilight = max(1.0 - noon - night, 0.0);
	vec3 weights = vec3(noon, twilight, night);
	return weights / max(dot(weights, vec3(1.0)), 0.0001);
}

float AirConfiguredDensity() {
	float density = 0.0;
	#if FOXY_AIR_AEROSOL_ENABLED == 1
		density = max(density, FOXY_AIR_AEROSOL_DENSITY);
	#endif
	#if FOXY_AIR_MOLECULAR_ENABLED == 1
		density = max(density, FOXY_AIR_MOLECULAR_DENSITY);
	#endif
	return density;
}

vec2 StandardAirDensity(
	const in vec3 worldPos,
	const in float time,
	const in float rainStrength,
	const in float caveMask,
	out float clump
) {
	float indoor = mix(0.16, 1.0, Saturate(caveMask));
	float aerosol = 0.0;
	float molecular = 0.0;
	clump = 0.0;
	#if FOXY_AIR_AEROSOL_ENABLED == 1
		vec2 fogField = StandardFogField(worldPos, time);
		clump = fogField.y;
		aerosol = AirVerticalProfile(worldPos.y, FOXY_AIR_AEROSOL_FADE_START, FOXY_AIR_AEROSOL_FADE_END);
		aerosol *= fogField.x * mix(1.0, 10.0, rainStrength) * indoor;
	#endif
	#if FOXY_AIR_MOLECULAR_ENABLED == 1
		molecular = AirVerticalProfile(worldPos.y, FOXY_AIR_MOLECULAR_FADE_START, FOXY_AIR_MOLECULAR_FADE_END);
		molecular *= mix(0.42, 1.0, indoor);
	#endif
	return max(vec2(aerosol, molecular), vec2(0.0));
}

float StandardTerrainVisibility(
	const in vec4 shadowClip,
	const in float sampleDistance
) {
	vec3 shadowNdc = shadowClip.xyz / TraceSafeDivisor(shadowClip.w);
	vec2 shadowClipXY = shadowNdc.xy;
	vec2 warped = ShadowWarp(shadowClipXY);
	vec3 shadowCoord = vec3(warped, shadowNdc.z) * 0.5 + 0.5;
	if (shadowCoord.x <= 0.0 || shadowCoord.y <= 0.0 || shadowCoord.x >= 1.0 || shadowCoord.y >= 1.0 || shadowCoord.z <= 0.0 || shadowCoord.z >= 1.0) {
		return 1.0;
	}

	float distanceFade = ShadowDistanceFade(sampleDistance);
	if (distanceFade <= 0.0001) {
		return 1.0;
	}

	float bias = mix(0.00110, 0.00230, smoothstep(12.0, 220.0, sampleDistance));
	// Volumetric shadowing uses one shadow decision; main TAA resolves shimmer.
	vec2 shadowUv = clamp(ShadowSampleUv(shadowClipXY, vec2(0.0)), vec2(0.0), vec2(1.0));
	ivec2 shadowSize = max(textureSize(shadowtex1, 0), ivec2(1));
	ivec2 shadowTexel = clamp(
		ivec2(shadowUv * vec2(shadowSize)),
		ivec2(0),
		shadowSize - ivec2(1)
	);
	float shadowDepth = texelFetch(shadowtex1, shadowTexel, 0).r;
	float visibility = ShadowCompareDepth(shadowCoord.z, shadowDepth, bias);
	return mix(1.0, visibility, distanceFade);
}

int StandardAirStepCount(const in float rayLength, const in float extendedReach) {
	int steps = FOXY_VL_MIN_STEPS + int(rayLength * 0.050);
	int stepLimit = extendedReach > 0.5 ? FOXY_VL_EXTENDED_MAX_STEPS : FOXY_VL_MAX_STEPS;
	if (steps < FOXY_VL_MIN_STEPS) return FOXY_VL_MIN_STEPS;
	if (steps > stepLimit) return stepLimit;
	return steps;
}

int StandardWaterStepCount(const in float rayLength, const in float extendedReach) {
	int steps = FOXY_UNDERWATER_VL_MIN_STEPS + int(rayLength * 0.22);
	int stepLimit = extendedReach > 0.5 ? FOXY_UNDERWATER_VL_STEPS : FOXY_UNDERWATER_VL_MAX_STEPS;
	if (steps < FOXY_UNDERWATER_VL_MIN_STEPS) return FOXY_UNDERWATER_VL_MIN_STEPS;
	if (steps > stepLimit) return stepLimit;
	return steps;
}

VolumeSample IntegrateVolume(
	const in float fogDistance,
	const in float lightDistance,
	const in float extendedReach,
	const in vec3 sceneRayView,
	const in mat4 modelViewInverse,
	const in mat4 shadowModelView,
	const in mat4 shadowProjection,
	const in vec3 sunView,
	const in vec3 moonView,
	const in vec3 shadowLightView,
	const in vec3 upView,
	const in vec3 cachedSunLightColor,
	const in vec3 cachedMoonLightColor,
	const in vec3 cachedSkyAmbientColor,
	const in vec3 cachedSkyFluence,
	const in float cachedSunAltitude,
	const in float cachedMoonAltitude,
	const in vec3 cameraWorldPos,
	const in float time,
	const in float rainStrength,
	const in float dither,
	const in float shadowPhase,
	const in float caveMask
) {
	VolumeSample result = VolumeEmptySample();
	vec3 rayDirView = normalize(sceneRayView);
	vec3 rayDirWorld = normalize(mat3(modelViewInverse) * rayDirView);
	float fogLength = max(fogDistance, 0.0);
	vec3 airTimeWeights = AirTimeWeights(cachedSunAltitude);
	float airDensityMultiplier = dot(airTimeWeights, vec3(FOXY_AIR_DENSITY_NOON, FOXY_AIR_DENSITY_TWILIGHT, FOXY_AIR_DENSITY_NIGHT));
	if (fogLength <= 1.0 || AirConfiguredDensity() * airDensityMultiplier <= 0.0001 || FOXY_VL_STRENGTH <= 0.0001) {
		return result;
	}
	vec3 noonAirTint = ColorTemperatureTint(float(FOXY_AIR_TEMPERATURE_NOON));
	vec3 twilightAirTint = ColorTemperatureTint(float(FOXY_AIR_TEMPERATURE_TWILIGHT));
	vec3 airScatterTint = noonAirTint * airTimeWeights.x + twilightAirTint * airTimeWeights.y + vec3(airTimeWeights.z);

	vec3 sunDir = normalize(sunView);
	vec3 moonDir = normalize(moonView);
	vec3 shadowLightDir = normalize(shadowLightView);
	vec2 sourceWeights = CelestialShadowSourceWeights(shadowLightDir, sunDir, moonDir);
	float sourceConfidence = sourceWeights.x + sourceWeights.y;
	float useSun = step(sourceWeights.y, sourceWeights.x);
	vec3 lightDir = mix(moonDir, sunDir, useSun);
	vec3 lightColor = cachedSunLightColor * sourceWeights.x + cachedMoonLightColor * sourceWeights.y * 0.82;
	vec3 fallbackAmbient = cachedSkyAmbientColor + MoonAmbientColorFromMoonColor(cachedMoonLightColor);
	float skyFluenceValid = step(1.0e-6, Luma(cachedSkyFluence));
	vec3 ambientColor = mix(fallbackAmbient, max(cachedSkyFluence, vec3(0.0)) * FOXY_AMBIENT_INTENSITY, skyFluenceValid);
	float activeAltitude = mix(cachedMoonAltitude, cachedSunAltitude, useSun);
	float activeShadowMatch = sourceConfidence;
	float lightActive = DirectCelestialVisibility(activeAltitude) * sourceConfidence;
	vec3 lightDirWorld = TiltCelestialWorld(normalize(mat3(modelViewInverse) * lightDir));

	float mu = dot(rayDirView, lightDir);
	float rayleighPhase = VolumeRayleighPhase(mu);
	float miePhase = StandardMiePhase(mu, FOXY_VL_ANISOTROPY);
	float lowSunSide = smoothstep(-0.06, 0.14, activeAltitude) * (1.0 - smoothstep(0.30, 0.62, activeAltitude));
	result.phase = Saturate(miePhase * 2.2);

	vec3 rayleighBase = vec3(0.00089, 0.00207, 0.00506);
	vec3 mieScatterBase = vec3(0.0066, 0.0061, 0.0055);
	vec3 mieExtinctionBase = mieScatterBase * 1.12;
	float uniformPhase = 1.0 / (4.0 * PI);
	int targetStepCount = StandardAirStepCount(fogLength, extendedReach);
	float nearLength = min(fogLength, lightDistance);
	float tailLength = max(fogLength - nearLength, 0.0);
	int nearStepCount = StandardAirStepCount(nearLength, 0.0);
	int tailStepCount = tailLength > 1.0 ? max(targetStepCount - nearStepCount, 0) : 0;
	int stepCount = nearStepCount + tailStepCount;
	float nearStepLength = nearLength / float(nearStepCount);
	float tailStepLength = tailStepCount > 0 ? tailLength / float(tailStepCount) : 0.0;
	float rayJitter = mix(0.08, 0.92, Saturate(dither));
	float invFogLength = 1.0 / max(fogLength, 1.0);

	vec4 playerRayOrigin = modelViewInverse * vec4(0.0, 0.0, 0.0, 1.0);
	vec4 playerRayDirection = modelViewInverse * vec4(rayDirView, 0.0);
	vec4 shadowRayOrigin = shadowProjection * (shadowModelView * playerRayOrigin);
	vec4 shadowRayDirection = shadowProjection * (shadowModelView * playerRayDirection);

	vec3 transmittance = vec3(1.0);
	float densitySum = 0.0;
	float shadowSum = 0.0;
	float historyDistanceSum = 0.0;
	float occlusionSum = 0.0;
	#if FOXY_VL_CLUMPY_FOG == 1
		float clumpSum = 0.0;
		float aerosolWeightSum = 0.0;
	#endif
	for (int i = 0; i < FOXY_VL_EXTENDED_MAX_STEPS; i++) {
		if (i >= stepCount) {
			break;
		}

		float fi = float(i);
		float sampleDistance;
		float integrationStepLength;
		if (i < nearStepCount) {
			// Shared offset preserves depth-strata ordering.
			sampleDistance = nearStepLength * (fi + rayJitter);
			integrationStepLength = nearStepLength;
		} else {
			float tailIndex = float(i - nearStepCount);
			sampleDistance = nearLength + tailStepLength * (tailIndex + rayJitter);
			integrationStepLength = tailStepLength;
		}
		vec4 playerPos4 = playerRayOrigin + playerRayDirection * sampleDistance;
		vec3 playerPos = playerPos4.xyz / TraceSafeDivisor(playerPos4.w);
		vec3 worldPos = playerPos + cameraWorldPos;
		float clumpSample;
		vec2 densityParts = StandardAirDensity(worldPos, time, rainStrength, caveMask, clumpSample);
		float aerosolDensity = densityParts.x * FOXY_AIR_AEROSOL_DENSITY * airDensityMultiplier;
		float molecularDensity = densityParts.y * FOXY_AIR_MOLECULAR_DENSITY * airDensityMultiplier;
		float density = aerosolDensity + molecularDensity * 0.36;
		if (density <= 0.00001) {
			continue;
		}

		float progress = sampleDistance * invFogLength;
		float directRangeWeight = VolumeDirectRangeWeight(sampleDistance, lightDistance);
		float shadowGate = smoothstep(0.01, 0.10, density)
			* (1.0 - smoothstep(0.93, 1.0, progress))
			* directRangeWeight;
		float terrainVisibility = 1.0;
		if (lightActive * activeShadowMatch * FOXY_VL_SHADOWING * shadowGate > 0.001) {
			vec4 shadowClip = shadowRayOrigin + shadowRayDirection * sampleDistance;
			terrainVisibility = StandardTerrainVisibility(
				shadowClip,
				sampleDistance
			);
			terrainVisibility = mix(1.0, terrainVisibility, activeShadowMatch);
		}

		float cloudVisibility = 1.0;
		#if FOXY_CLOUDS == 1
			if (lightActive * FOXY_VL_SHADOWING * shadowGate > 0.001) {
				cloudVisibility = CloudShadowVisibilityCached(
					colortex7,
					worldPos,
					cameraWorldPos,
					lightDirWorld,
					time,
					rainStrength
				);
			}
		#endif
		float visibility = min(terrainVisibility, cloudVisibility);
		visibility = mix(1.0, visibility, Saturate(FOXY_VL_SHADOWING));
		float rangedVisibility = mix(1.0, visibility, directRangeWeight);
		float shaftVisibility = pow(
			Saturate(rangedVisibility),
			max(FOXY_VL_SHADOW_DARKEN, 0.01)
		);

		vec3 sigmaS = (rayleighBase * molecularDensity + mieScatterBase * aerosolDensity) * airScatterTint;
		vec3 sigmaT = rayleighBase * molecularDensity + mieExtinctionBase * aerosolDensity;
		vec3 stepTransmittance = exp(-sigmaT * integrationStepLength);
		// Shaft presentation lift must not cancel low-sun attenuation.
		float directArtBoost = mix(1.12, 1.22, lowSunSide);
		vec3 directSource = lightColor * lightActive * shaftVisibility * directArtBoost * airScatterTint * (
			rayleighBase * molecularDensity * rayleighPhase +
			mieScatterBase * aerosolDensity * miePhase
		);
		vec3 ambientSource = ambientColor * uniformPhase * sigmaS;
		vec3 source = directSource + ambientSource;
		vec3 stepIntegral = (vec3(1.0) - stepTransmittance) / max(sigmaT, vec3(1.0e-5));
		result.scattering += transmittance * source * stepIntegral;
		transmittance *= stepTransmittance;

		float densityWeight = density * integrationStepLength;
		densitySum += densityWeight;
		shadowSum += rangedVisibility * densityWeight;
		occlusionSum += (1.0 - terrainVisibility) * directRangeWeight * densityWeight;
		#if FOXY_VL_CLUMPY_FOG == 1
			float aerosolWeight = aerosolDensity * integrationStepLength;
			clumpSum += clumpSample * aerosolWeight;
			aerosolWeightSum += aerosolWeight;
		#endif
		historyDistanceSum += sampleDistance * densityWeight;
		if (Luma(transmittance) < 0.008) {
			break;
		}
	}

	result.scattering *= FOXY_VL_STRENGTH;
	result.transmittance = Saturate(Luma(transmittance));
	result.coverage = 1.0 - result.transmittance;
	result.density = Saturate(densitySum * 0.035);
	result.shadow = densitySum > 0.0001 ? Saturate(shadowSum / densitySum) : 1.0;
	result.terrainBlock = densitySum > 0.0001 ? Saturate(occlusionSum / densitySum) : 0.0;
	result.shadowMask = result.terrainBlock;
	result.tyndall = Saturate(result.coverage * (1.0 - result.shadow) * 1.8);
	#if FOXY_VL_CLUMPY_FOG == 1
		result.clump = aerosolWeightSum > 0.0001 ? Saturate(clumpSum / aerosolWeightSum) : 0.0;
	#else
		result.clump = 0.0;
	#endif
	result.historyDistance = densitySum > 0.0001
		? clamp(historyDistanceSum / densitySum, 1.0, fogLength)
		: max(fogLength * 0.55, 1.0);
	return result;
}

VolumeSample IntegrateUnderwaterVolume(
	const in float fogDistance,
	const in float lightDistance,
	const in float extendedReach,
	const in vec3 sceneRayView,
	const in mat4 modelViewInverse,
	const in mat4 shadowModelView,
	const in mat4 shadowProjection,
	const in vec3 sunView,
	const in vec3 moonView,
	const in vec3 shadowLightView,
	const in vec3 upView,
	const in vec3 cachedSunLightColor,
	const in vec3 cachedMoonLightColor,
	const in vec3 cachedSkyAmbientColor,
	const in float cachedSunAltitude,
	const in float cachedMoonAltitude,
	const in vec3 cameraWorldPos,
	const in float time,
	const in float rainStrength,
	const in float dither,
	const in float shadowPhase,
	const in float skyEye,
	const in float waterSurfaceAltitude
) {
	VolumeSample result = VolumeEmptySample();
	vec3 rayDirView = normalize(sceneRayView);
	vec3 rayDirWorld = normalize(mat3(modelViewInverse) * rayDirView);
	float fogLength = max(fogDistance, 0.0);
	if (fogLength <= 0.8 || FOXY_VL_STRENGTH <= 0.0001 || FOXY_WATER_UNDERWATER <= 0.0001) {
		return result;
	}

	vec3 sunDir = normalize(sunView);
	vec3 moonDir = normalize(moonView);
	vec3 shadowLightDir = normalize(shadowLightView);
	float day = smoothstep(-0.08, 0.18, cachedSunAltitude);
	vec2 sourceWeights = CelestialShadowSourceWeights(shadowLightDir, sunDir, moonDir);
	float sourceConfidence = sourceWeights.x + sourceWeights.y;
	float useSunDirection = step(sourceWeights.y, sourceWeights.x);
	vec3 mainLightDir = mix(moonDir, sunDir, useSunDirection);
	float activeShadowMatch = sourceConfidence;
	float activeLightAltitude = mix(cachedMoonAltitude, cachedSunAltitude, useSunDirection);
	vec3 sunWorld = TiltCelestialWorld(normalize(mat3(modelViewInverse) * sunDir));
	vec3 lightColor = cachedSunLightColor * sourceWeights.x + cachedMoonLightColor * sourceWeights.y * 0.78;
	lightColor *= DirectCelestialVisibility(activeLightAltitude);
	vec3 ambientColor = (cachedSkyAmbientColor + MoonAmbientColorFromMoonColor(cachedMoonLightColor)) * (0.10 + skyEye * 0.56);
	vec3 extinction = WaterExtinction(Saturate(FOXY_WATER_FOG));
	vec3 scatteringCoeff = vec3(0.010) * FOXY_WATER_DENSITY * mix(0.90, 1.22, Saturate(FOXY_WATER_FOG));
	float mu = dot(rayDirView, mainLightDir);
	float forwardAmount = Saturate(mu * 0.5 + 0.5);
	float phase = VolumeMiePhase(mu, 0.42) * 0.58 + (1.0 / (4.0 * PI)) * 0.42;
	float sunCoreCompression = mix(1.0, 0.46, pow(forwardAmount, 8.0) * day);
	phase *= sunCoreCompression;
	float shaft = pow(forwardAmount, 5.0) * (1.0 - rainStrength * 0.62) * day * sunCoreCompression;
	float sideShaft = pow(Saturate(1.0 - abs(mu)), 1.30) * smoothstep(0.015, 0.26, sunWorld.y) * day;
	result.phase = Saturate(phase * 3.0);
	int stepCount = StandardWaterStepCount(fogLength, extendedReach);
	float stepLength = fogLength / float(stepCount);
	float rayJitter = mix(0.18, 0.92, Saturate(dither));
	float invFogLength = 1.0 / max(fogLength, 1.0);
	vec4 playerRayOrigin = modelViewInverse * vec4(0.0, 0.0, 0.0, 1.0);
	vec4 playerRayDirection = modelViewInverse * vec4(rayDirView, 0.0);
	vec4 shadowRayOrigin = shadowProjection * (shadowModelView * playerRayOrigin);
	vec4 shadowRayDirection = shadowProjection * (shadowModelView * playerRayDirection);
	float densitySum = 0.0;
	float shadowSum = 0.0;
	float tyndallSum = 0.0;
	for (int i = 0; i < FOXY_UNDERWATER_VL_STEPS; i++) {
		if (i >= stepCount) {
			break;
		}
		float fi = float(i);
		float t = stepLength * (fi + rayJitter);
		float sampleDistance = max(t, 0.2);
		vec4 playerPos4 = playerRayOrigin + playerRayDirection * sampleDistance;
		vec3 playerPos = playerPos4.xyz / TraceSafeDivisor(playerPos4.w);
		vec3 worldPos = playerPos + cameraWorldPos;
		float progress = t * invFogLength;
		float directRangeWeight = VolumeDirectRangeWeight(t, lightDistance);
		float density = (0.58 + Saturate(FOXY_WATER_FOG) * 0.62) * FOXY_WATER_DENSITY;
		density *= 1.0 - smoothstep(0.92, 1.0, progress);
		float terrainVisibility = 1.0;
		if (directRangeWeight * activeLightAltitude * activeShadowMatch > 0.001) {
			vec4 shadowClip = shadowRayOrigin + shadowRayDirection * sampleDistance;
			terrainVisibility = StandardTerrainVisibility(
				shadowClip,
				sampleDistance
			);
			terrainVisibility = mix(1.0, terrainVisibility, activeShadowMatch);
		}

		float waterDepth = max(waterSurfaceAltitude - worldPos.y, 0.0);
		float lightPathDepth = max(waterDepth / max(sunWorld.y, 0.10), 0.0);
		float stepPhase = fract(rayJitter + fi * 0.61803398875);
		vec3 causticPos = worldPos + rayDirWorld * ((stepPhase - 0.5) * stepLength * 0.72);
		float causticSample = 1.0;
		if (directRangeWeight > 0.001) {
			causticSample = WaterCaustics(causticPos, sunWorld, time, waterDepth + t * 0.08, lightPathDepth);
		}
		float directCausticVisibility = smoothstep(0.10, 0.82, terrainVisibility);
		float caustic = mix(1.0, causticSample, directCausticVisibility);
		float causticVolume = 1.0 + max(caustic - 1.0, 0.0) * 0.42 * FOXY_WATER_CAUSTICS_BRIGHTNESS;
		float causticBeam = 1.0 + max(causticVolume - 1.0, 0.0) * smoothstep(0.03, 0.34, sunWorld.y) * day * directCausticVisibility;
		float waveBeam = pow(Saturate(abs(causticVolume - 1.0) * 0.56), 0.86) * smoothstep(0.02, 0.30, sunWorld.y) * day;
		float causticShaft = pow(Saturate(abs(causticVolume - 1.0) * 1.35), 0.72) * smoothstep(0.02, 0.32, sunWorld.y) * day;
		float rangedTerrainVisibility = mix(1.0, terrainVisibility, directRangeWeight);
		float directVisibility = mix(0.42, rangedTerrainVisibility, 0.58);
		vec3 lightTransmittance = exp(-extinction * lightPathDepth * density * 0.62);
		float directStructure = causticBeam * (0.88 + shaft * 0.24 + sideShaft * 0.62 + waveBeam * 0.92 + causticShaft * 1.55);
		directStructure = mix(1.0, directStructure, directRangeWeight);
		vec3 directLight = lightColor * lightTransmittance * phase * directVisibility * directStructure;
		vec3 ambientLight = ambientColor * (1.0 / (4.0 * PI)) * (0.42 + skyEye * 0.48);
		vec3 stepTransmittance = exp(-extinction * stepLength * density);
		float scalarTransmittance = max(max(stepTransmittance.r, stepTransmittance.g), stepTransmittance.b);
		vec3 scatterWeight = (vec3(1.0) - stepTransmittance) * result.transmittance;
		result.scattering += (directLight + ambientLight) * scatterWeight * scatteringCoeff / max(extinction, vec3(1.0e-4));
		result.transmittance *= scalarTransmittance;
		float densityWeight = density * stepLength;
		densitySum += densityWeight;
		shadowSum += rangedTerrainVisibility * densityWeight;
		tyndallSum += (shaft * 0.58 + sideShaft * 0.42) * terrainVisibility * directRangeWeight * densityWeight;
		if (result.transmittance < 0.055) {
			result.transmittance = 0.055;
			break;
		}
	}

	result.scattering *= FOXY_VL_STRENGTH * FOXY_WATER_UNDERWATER * FOXY_UNDERWATER_VL_STRENGTH * mix(1.65, 2.45, Saturate(FOXY_WATER_FOG));
	result.coverage = Saturate(1.0 - result.transmittance);
	result.density = Saturate(densitySum * 0.030);
	result.shadow = densitySum > 0.0001 ? Saturate(shadowSum / max(densitySum, 1.0e-4)) : 1.0;
	result.tyndall = Saturate(tyndallSum * 0.060);
	result.shadowMask = 1.0 - result.shadow;
	result.historyDistance = max(fogLength * 0.62, 1.0);
	return result;
}

#endif
