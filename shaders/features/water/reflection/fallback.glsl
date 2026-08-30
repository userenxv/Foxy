#ifndef WATER_REFLECTION_FALLBACK_GLSL
#define WATER_REFLECTION_FALLBACK_GLSL

#include "/lib/cloud_coverage.glsl"

uniform sampler2D cloudWeatherMap;

float WaterReflectionSkyOpenness(const in vec3 worldDir, const in float waterDepth) {
	float horizonOpen = smoothstep(-0.055, -0.004, worldDir.y);
	return Saturate(horizonOpen);
}

vec3 WaterReflectionSkyDirection(const in vec3 worldDir) {
	vec3 direction = normalize(worldDir);
	if (direction.y >= 0.0035) {
		return direction;
	}
	float horizontalLength = length(direction.xz);
	if (horizontalLength <= 1.0e-5) {
		return vec3(0.0, 1.0, 0.0);
	}
	const float horizonLift = 0.0035;
	vec2 horizontal = direction.xz / horizontalLength * sqrt(1.0 - horizonLift * horizonLift);
	return vec3(horizontal.x, horizonLift, horizontal.y);
}

float WaterProjectedCloudLayer(
	const in vec3 reflectedDir,
	out vec4 cloudLayer
) {
	cloudLayer = vec4(0.0);
	if (reflectedDir.z >= -0.015) {
		return 0.0;
	}

	vec4 clip = gbufferProjection * vec4(reflectedDir, 0.0);
	if (clip.w <= 1.0e-5) {
		return 0.0;
	}
	vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
	if (any(lessThanEqual(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) {
		return 0.0;
	}
	vec2 edge = min(uv, vec2(1.0) - uv);
	float interiorWeight = smoothstep(0.045, 0.160, edge.x) * smoothstep(0.045, 0.160, edge.y);
	if (interiorWeight <= 0.0001) {
		return 0.0;
	}
	cloudLayer = LoadCloudLayer(uv);
	cloudLayer = vec4(max(cloudLayer.rgb, vec3(0.0)), Saturate(cloudLayer.a));
	return interiorWeight;
}

vec4 DirectionalSkyCloudReflection(
	const in vec3 reflectedDir,
	const in vec3 worldDir,
	const in vec3 waterWorldPos
) {
	vec3 upView = normalize(upPosition);
	vec3 sunView;
	vec3 moonView;
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, upView, sunView, moonView);
	float sunAltitude = vertexSunAltitude;
	float moonAltitude = vertexMoonAltitude;
	vec3 skyDirection = WaterReflectionSkyDirection(worldDir);
	vec3 skyColor = DecodeSkyLutColor(texture2D(colortex7, SkyViewLutUv(skyDirection)).rgb);
	#if FOXY_NASA_GALAXY == 1 && !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
		skyColor += NasaGalaxyRadiance(skyDirection, sunAltitude, rainStrength, worldTime);
	#endif
	skyColor += SunMoonDisks(reflectedDir, sunView, moonView, upView, sunAltitude, moonAltitude, rainStrength) * 0.20;
	#if FOXY_SKY_VANILLA_CELESTIALS == 0 && FOXY_SKY_VANILLA_MOON == 1 && !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
		skyColor += VanillaMoonDisk(reflectedDir, moonView, upView, moonAltitude, rainStrength) * 0.20;
	#endif
	float skyWeight = smoothstep(-0.055, -0.004, worldDir.y);
	vec3 background = skyColor;
	float backgroundWeight = skyWeight;

	#if FOXY_CLOUDS == 1
		vec4 projectedCloud;
		float projectedWeight = WaterProjectedCloudLayer(
			reflectedDir,
			projectedCloud
		);
		vec3 directionalBackground = skyColor;

		if (projectedWeight < 0.999 && skyDirection.y > 0.003) {
			float cloudPlane = FOXY_CLOUD_HEIGHT + FOXY_CLOUD_THICKNESS * 0.34;
			vec3 referenceWaterPos = CloudWorldToReference(waterWorldPos);
			float t = (cloudPlane - referenceWaterPos.y) / max(skyDirection.y, 0.008);
			if (t > 0.0) {
				vec3 cloudPos = referenceWaterPos + skyDirection * t;
				vec3 densityPos = CloudCoverageUnscaleWorld(cloudPos);
				vec2 wind = CloudCoverageWindDir().xz;
				densityPos.xz += wind * (frameTimeCounter * FOXY_CLOUD_SPEED * 22.0);
				vec4 weather = texture2D(cloudWeatherMap, CloudCoverageWeatherUv(densityPos.xz, frameTimeCounter));
				float coverageControl = Saturate(FOXY_CLOUD_COVERAGE + rainStrength * 0.20 + FOXY_CLOUD_HORIZONTAL_COVERAGE_BIAS);
				float coverageLift = coverageControl - 0.50 + max(FOXY_CLOUD_HORIZONTAL_COVERAGE_BIAS, 0.0) * 1.80;
				float liftedCoverage = Saturate(weather.r + coverageLift);
				float broadCell = smoothstep(0.18, 0.78, weather.g);
				float sheetBreak = smoothstep(0.28, 0.68, liftedCoverage * 0.70 + weather.g * 0.44);
				float sparseFloor = liftedCoverage * smoothstep(0.0, 0.42, coverageLift);
				float groupedCoverage = mix(sparseFloor, liftedCoverage, broadCell);
				groupedCoverage = mix(groupedCoverage, max(groupedCoverage, liftedCoverage * mix(0.62, 1.0, broadCell)), smoothstep(-0.04, 0.06, coverageLift) * 0.78);
				float cloudAlpha = smoothstep(0.16, 0.62, Saturate(groupedCoverage * sheetBreak));
				cloudAlpha *= Saturate(FOXY_CLOUD_DENSITY * 0.74);
				float cloudVisibilityRange = CloudCoverageVisibilityRange();
				cloudAlpha *= 1.0 - smoothstep(cloudVisibilityRange * 0.72, cloudVisibilityRange, t);
				cloudAlpha *= smoothstep(0.003, 0.10, skyDirection.y);

float solarLightingVisibility = DirectCelestialVisibility(sunAltitude);
				vec3 activeLightView = normalize(mix(moonView, sunView, step(0.01, solarLightingVisibility)));
				vec3 activeLightWorld = normalize(mat3(gbufferModelViewInverse) * activeLightView);
				float lightFace = pow(Saturate(dot(skyDirection, activeLightWorld) * 0.5 + 0.5), 3.0);
				float twilight = TwilightFactor(sunAltitude);
				vec3 ambient = mix(vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(vertexMoonLightColor), skyColor, 0.38);
				vec3 activeLightColor = vertexSunLightColor * solarLightingVisibility;
				activeLightColor += vertexMoonLightColor * (1.0 - solarLightingVisibility);
				vec3 direct = activeLightColor * (0.10 + lightFace * (0.26 + twilight * 0.22));
				vec3 cloudColor = ambient * 1.22 + direct;
				cloudColor = mix(cloudColor, skyColor, rainStrength * 0.34);
				cloudColor = mix(skyColor, cloudColor, 0.82);

				directionalBackground = mix(directionalBackground, cloudColor, cloudAlpha);
			}
		}

		vec3 projectedBackground = skyColor * (1.0 - projectedCloud.a) + projectedCloud.rgb;
		background = mix(directionalBackground, projectedBackground, projectedWeight);
	#endif

	return vec4(max(background, vec3(0.0)), Saturate(backgroundWeight));
}

vec4 SkyCloudReflectionFallback(
	const in vec3 reflectedDir,
	const in vec3 worldDir,
	const in vec3 waterWorldPos
) {
	return DirectionalSkyCloudReflection(
		reflectedDir,
		worldDir,
		waterWorldPos
	);
}

float WaterInternalReflectance(const in float NoV) {
	const float etaI = WATER_IOR;
	const float etaT = 1.0;
	float cosI = Saturate(NoV);
	float sinT2 = (etaI / etaT) * (etaI / etaT) * max(1.0 - cosI * cosI, 0.0);
	if (sinT2 >= 1.0) {
		return 1.0;
	}
	float cosT = sqrt(max(1.0 - sinT2, 0.0));
	float rs = (etaI * cosI - etaT * cosT) / max(etaI * cosI + etaT * cosT, 1.0e-4);
	float rp = (etaI * cosT - etaT * cosI) / max(etaI * cosT + etaT * cosI, 1.0e-4);
	return Saturate(0.5 * (rs * rs + rp * rp));
}

vec4 UnderwaterInternalReflectionFallback(const in float internalReflectance, const in vec3 reflectedWorldDir) {
	vec3 upView = normalize(upPosition);
	vec3 sunView;
	vec3 moonView;
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, upView, sunView, moonView);
	float sunAltitude = vertexSunAltitude;
	float moonAltitude = vertexMoonAltitude;
	float solarLightingVisibility = DirectCelestialVisibility(sunAltitude);
	float moonLightingVisibility = DirectCelestialVisibility(moonAltitude);
	float solarIrradiance = WaterSolarIrradiance(vertexSunLightColor, sunAltitude);
	float lunarIrradiance = WaterLunarIrradiance(vertexMoonLightColor, moonAltitude);
	float sourceIrradiance = solarIrradiance + lunarIrradiance;
	float sunTopLight = max(dot(upView, sunView), 0.0);
	float moonTopLight = max(dot(upView, moonView), 0.0);
	float topLight = (sunTopLight * solarIrradiance + moonTopLight * lunarIrradiance)
		/ max(sourceIrradiance, 1.0e-4);
	vec3 activeDirectColor = vertexSunLightColor * solarLightingVisibility
		+ vertexMoonLightColor * moonLightingVisibility;
	float activeDirectAmount = Saturate(topLight * sourceIrradiance);
	vec3 waterAmbient = vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(vertexMoonLightColor);
	float skyIrradiance = WaterSkyIrradiance(waterAmbient, rainStrength);
	float stableWaterSkyLight = Saturate((0.24 + smoothstep(-0.08, 0.34, sunAltitude) * 0.42
		+ (1.0 - rainStrength) * 0.10) * mix(0.30, 1.0, skyIrradiance));
	vec3 waterScatter = WaterScatterColor(waterAmbient, activeDirectColor, activeDirectAmount, stableWaterSkyLight, rainStrength);
	float surfaceLight = 0.74 + 0.26 * smoothstep(-0.18, 0.36, sunAltitude);
	float directionalSoftening = mix(0.82, 1.0, smoothstep(-0.75, 0.15, reflectedWorldDir.y));
	float alpha = Saturate(mix(0.18, 1.0, internalReflectance) * smoothstep(0.08, 0.72, internalReflectance));
	return vec4(waterScatter * surfaceLight * directionalSoftening, alpha);
}

#endif
