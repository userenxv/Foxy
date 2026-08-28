#ifndef FOXY_SKY_GLSL
#define FOXY_SKY_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/contracts/sky_lut.glsl"
#include "/lib/lighting.glsl"

uniform int worldTime;
uniform sampler2D atmosphereMultiLut;

const float SKY_BASE_SUNSET_HORIZON_TICK = 12700.0;
const float SKY_BASE_SUNRISE_HORIZON_TICK = 23000.0;

vec3 EncodeSkyLutColor(const in vec3 c) {
	return EncodeBufferColor(c);
}

vec3 DecodeSkyLutColor(const in vec3 c) {
	return DecodeBufferColor(c);
}

float RayleighPhase(const in float mu) {
	return 3.0 / (16.0 * PI) * (1.0 + mu * mu);
}

float MiePhase(const in float mu, const in float g) {
	float gg = g * g;
	float denom = max(1.0 + gg - 2.0 * g * mu, 0.035);
	return (1.0 - gg) / (4.0 * PI * pow(denom, 1.5));
}

// Finite solar source profile with a soft limb and monotonic aureole.
float SunAngularSourceProfile(const in float nu, const in float radius) {
	float radiusSafe = max(radius, 1.0e-4);
	float viewCosine = clamp(nu, -1.0, 1.0);
	float discCosine = cos(radiusSafe);
	float cosineGap = max(discCosine - viewCosine, 0.0);
	float cosineSpan = max(1.0 - discCosine, 1.0e-5);
	float normalizedGap = cosineGap / cosineSpan;
	const float limbWidth = 0.08;
	const float tailSharpness = 512.0;
	float limb = 1.0 - smoothstep(0.0, limbWidth, normalizedGap);
	float tail = 1.0 / (1.0 + tailSharpness * normalizedGap * normalizedGap);
	return max(limb, tail);
}

vec2 SkyRaySphere(const in vec3 rayOrigin, const in vec3 rayDir, const in float radius) {
	float b = dot(rayOrigin, rayDir);
	float c = dot(rayOrigin, rayOrigin) - radius * radius;
	float h = b * b - c;
	if (h < 0.0) {
		return vec2(-1.0);
	}
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}

float SkySlantDepth(const in float height, const in float mu, const in float scaleHeight) {
	float muSafe = max(mu, 0.010);
	float chapmanApprox = 1.0 / (muSafe + sqrt(muSafe * muSafe + 0.0065));
	return exp(-height / scaleHeight) * scaleHeight * chapmanApprox;
}

float SkyOzoneDensity(const in float height) {
	float lowerLayer = clamp(height / 25000.0, 0.0, 1.0);
	float upperLayer = clamp((40000.0 - height) / 15000.0, 0.0, 1.0);
	return min(lowerLayer, upperLayer);
}

float SkyOzoneSlantDepth(const in float height, const in float mu) {
	return SkyOzoneDensity(height) * SkySlantDepth(height, mu, 15000.0);
}

float SkySinDegrees(const in float degreesValue) {
	return sin(degreesValue * (PI / 180.0));
}

float SkyTwilightScale() {
	return max(FOXY_SKY_TWILIGHT_SCALE, 0.05);
}

float SkyDaylightAltitude() {
	return SkySinDegrees(2.0);
}

float SkyCivilTwilightAltitude() {
	return SkySinDegrees(-6.0 * SkyTwilightScale());
}

float SkyNauticalTwilightAltitude() {
	return SkySinDegrees(-12.0 * SkyTwilightScale());
}

float SkyAstronomicalTwilightAltitude() {
	return SkySinDegrees(-18.0 * SkyTwilightScale());
}

float SkyTimeAfter(const in float t, const in float anchor) {
	return mod(t - anchor + 24000.0, 24000.0);
}

float SkyTimeSunAltitudeAnchored(const in float sunriseTickSetting, const in float sunsetTickSetting) {
	float t = mod(float(worldTime), 24000.0);
	float sunriseTick = mod(sunriseTickSetting, 24000.0);
	float sunsetTick = mod(sunsetTickSetting, 24000.0);
	float dayLength = clamp(SkyTimeAfter(sunsetTick, sunriseTick), 1000.0, 23000.0);
	float nightLength = max(24000.0 - dayLength, 1000.0);
	float sinceSunrise = SkyTimeAfter(t, sunriseTick);
	if (sinceSunrise <= dayLength) {
		float dayPhase = clamp(sinceSunrise / dayLength, 0.0, 1.0);
		return sin(dayPhase * PI);
	}
	float sinceSunset = SkyTimeAfter(t, sunsetTick);
	float nightPhase = clamp(sinceSunset / nightLength, 0.0, 1.0);
	return -sin(nightPhase * PI);
}

float SkyTimeSunAltitude() {
	return SkyTimeSunAltitudeAnchored(SKY_BASE_SUNRISE_HORIZON_TICK + FOXY_SKY_SUNRISE_HORIZON_OFFSET, SKY_BASE_SUNSET_HORIZON_TICK + FOXY_SKY_SUNSET_HORIZON_OFFSET);
}

float SkySolarTimeSunAltitude() {
	return SkyTimeSunAltitudeAnchored(SKY_BASE_SUNRISE_HORIZON_TICK + FOXY_SKY_SOLAR_SUNRISE_HORIZON_OFFSET, SKY_BASE_SUNSET_HORIZON_TICK + FOXY_SKY_SOLAR_SUNSET_HORIZON_OFFSET);
}

float SkyTimeDayFloor() {
	return smoothstep(SkyCivilTwilightAltitude(), SkyDaylightAltitude(), SkyTimeSunAltitude());
}

float SkyTimeTwilightCarry() {
	float timeAltitude = SkyTimeSunAltitude();
	return smoothstep(SkyAstronomicalTwilightAltitude(), SkyCivilTwilightAltitude(), timeAltitude);
}

float SkyTimeSunAltitudeFloor() {
	return SkyTimeSunAltitude();
}

float SkySunsetRedAmount(const in float sunAltitude) {
	// Solar chroma follows geometric altitude, not clock time.
	return Saturate(1.0 - smoothstep(-0.010, 0.070, sunAltitude));
}

vec3 SkySunDirectionWithAltitude(const in vec3 sunDir, const in vec3 upDir, const in float targetAltitude) {
	float altitude = clamp(targetAltitude, -0.999, 0.999);
	float currentAltitude = dot(sunDir, upDir);
	vec3 horizonDir = sunDir - upDir * currentAltitude;
	float horizonLen = length(horizonDir);
	if (horizonLen < 0.0001) {
		vec3 axis = abs(upDir.y) < 0.98 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		horizonDir = normalize(cross(upDir, axis));
	} else {
		horizonDir /= horizonLen;
	}
	return normalize(horizonDir * sqrt(max(1.0 - altitude * altitude, 0.0)) + upDir * altitude);
}

vec3 SkySolarTransmittance(const in float sunAltitude, const in float rainStrength) {
	return AtmosphereSolarTransmittance(sunAltitude, rainStrength);
}

vec3 SkyMultiScattering(const in float height, const in float sunMu) {
	float h = sqrt(clamp(height / 100000.0, 0.0, 1.0));
	float m = sign(sunMu) * pow(abs(clamp(sunMu, -1.0, 1.0)), 1.0 / 3.0);
	vec2 unitUv = vec2(m * 0.5 + 0.5, h);
	vec2 uv = (unitUv * vec2(31.0, 17.0) + vec2(0.5)) / vec2(32.0, 18.0);
	return max(texture2D(atmosphereMultiLut, clamp(uv, vec2(0.5 / 32.0, 0.5 / 18.0), vec2(31.5 / 32.0, 17.5 / 18.0))).rgb, vec3(0.0));
}

vec3 SkyWarpViewRay(const in vec3 viewRay, const in vec3 up) {
	float viewUp = dot(viewRay, up);
	if (viewUp <= 0.0 || AtmosphereStyleWarp() <= 0.0) {
		return viewRay;
	}
	vec3 horizonDir = normalize(viewRay - up * viewUp);
	float warpedUp = viewUp * sqrt(sqrt(max(viewUp, 0.0)));
	vec3 warped = normalize(horizonDir * sqrt(max(1.0 - warpedUp * warpedUp, 0.0)) + up * warpedUp);
	return normalize(mix(viewRay, warped, AtmosphereStyleWarp()));
}

// Lower sky uses the same-azimuth tangent atmosphere as one fog field.
vec3 SkyHorizonFogRay(const in vec3 viewRay, const in vec3 up) {
	float viewUp = dot(viewRay, up);
	if (viewUp >= 0.0) {
		return normalize(viewRay);
	}
	vec3 horizonDir = viewRay - up * viewUp;
	return length(horizonDir) > 0.0001
		? normalize(horizonDir)
		: vec3(1.0, 0.0, 0.0);
}

vec3 SkyTransmittanceToSun(const in vec3 samplePos, const in vec3 sunDir, const in float rainStrength) {
	const float planetRadius = 6371000.0;
	const float atmosphereRadius = 6471000.0;
	const vec3 betaRayleigh = vec3(5.802, 13.558, 33.100) * 0.000001;
	const vec3 betaOzone = vec3(0.650, 1.881, 0.085) * 0.000001;
	vec2 groundHit = SkyRaySphere(samplePos, sunDir, planetRadius);
	if (groundHit.x > 1.0) {
		return vec3(0.0);
	}
	vec2 topHit = SkyRaySphere(samplePos, sunDir, atmosphereRadius);
	float distance = max(topHit.y, 0.0);
	float depthRayleigh = 0.0;
	float depthMie = 0.0;
	float depthOzone = 0.0;
	for (int i = 0; i < 8; i++) {
		float u0 = float(i) / 8.0;
		float u1 = float(i + 1) / 8.0;
		float t0 = distance * u0 * u0;
		float t1 = distance * u1 * u1;
		float dt = t1 - t0;
		vec3 p = samplePos + sunDir * ((t0 + t1) * 0.5);
		float height = max(length(p) - planetRadius, 0.0);
		depthRayleigh += exp(-height / 8000.0) * dt;
		depthMie += exp(-height / 1200.0) * dt;
		depthOzone += SkyOzoneDensity(height) * dt;
	}
	float sunsetAerosolScale = SunsetAerosolScale(dot(normalize(sunDir), normalize(samplePos)));
	vec3 extinction = betaRayleigh * depthRayleigh + AtmosphereMieExtinction() * (depthMie * mix(1.0, 1.55, rainStrength) * sunsetAerosolScale) + betaOzone * depthOzone;
	return exp(-min(extinction, vec3(40.0))) * SunsetAerosolTransmittance(dot(normalize(sunDir), normalize(samplePos)));
}

float SkyViewAltitudeToLutY(const in float y) {
	float altitude = asin(clamp(y, -1.0, 1.0));
	float normalized = sign(altitude) * sqrt(abs(altitude) / (0.5 * PI));
	return normalized * 0.5 + 0.5;
}

vec2 SkyViewLutUv(const in vec3 worldDir) {
	vec3 dir = normalize(worldDir);
	float azimuth = atan(dir.x, -dir.z);
	float u = fract(azimuth / (2.0 * PI) + 0.5);
	float v = SkyViewAltitudeToLutY(dir.y);
	return SkyLutPhysicalUv(vec2(u, v));
}

vec3 SkyViewLutDirection(const in vec2 uv) {
	vec2 logicalUv = SkyLutLogicalUv(uv);
	float azimuth = (logicalUv.x - 0.5) * (2.0 * PI);
	float yParam = clamp(logicalUv.y * 2.0 - 1.0, -1.0, 1.0);
	float altitude = sign(yParam) * yParam * yParam * (0.5 * PI);
	float altitudeCos = cos(altitude);
	return normalize(vec3(altitudeCos * sin(azimuth), sin(altitude), -altitudeCos * cos(azimuth)));
}

vec3 SkyLutRadiance(sampler2D skyLut, const in vec3 worldDir) {
	return DecodeSkyLutColor(texture2D(skyLut, SkyViewLutUv(worldDir)).rgb);
}

vec3 SkyLutUpperHemisphereFluence(sampler2D skyLut) {
	const int sampleCount = 128;
	const float goldenAngle = 2.39996322972865332;
	vec3 fluence = vec3(0.0);
	for (int i = 0; i < sampleCount; i++) {
		float sampleIndex = float(i);
		float y = (sampleIndex + 0.5) / float(sampleCount);
		float azimuth = sampleIndex * goldenAngle;
		float horizontal = sqrt(max(1.0 - y * y, 0.0));
		vec3 worldDir = vec3(horizontal * cos(azimuth), y, horizontal * sin(azimuth));
		fluence += SkyLutRadiance(skyLut, worldDir);
	}
	return max(fluence * (2.0 * PI / float(sampleCount)), vec3(0.0));
}

vec3 SkyCachedUpperHemisphereFluence(sampler2D skyLut) {
	return max(DecodeSkyLutColor(texture2D(skyLut, SkyUpperHemisphereFluenceUv()).rgb), vec3(0.0));
}

vec2 SkyBoundaryFogWeights(
	const in vec3 scenePos,
	const in float sunAltitude,
	const in float farPlane
) {
	float twilightFactor = TwilightFactor(sunAltitude);
	if (twilightFactor <= 0.04) {
		return vec2(0.0);
	}
	vec2 horizontal = abs(scenePos.xz);
	vec2 horizontal2 = horizontal * horizontal;
	float horizontalDistance = sqrt(sqrt(dot(horizontal2, horizontal2)));
	if (horizontalDistance <= 1.0) {
		return vec2(0.0);
	}
	float borderDistance = horizontalDistance / max(farPlane, 1.0);
	float colorDistance = smoothstep(0.22, 0.55, borderDistance);
	float borderCurve = pow(Saturate(borderDistance), 6.0);
	float farBoundary = 1.0 - exp2(-7.0 * borderCurve);
	float twilight = smoothstep(0.04, 0.40, twilightFactor);
	return vec2(colorDistance * twilight, farBoundary * twilight * 0.98);
}

vec3 SkyBoundaryFogColor(
	sampler2D skyLut,
	const in vec3 viewPos,
	const in mat4 modelViewInverse
) {
	vec3 viewDir = normalize(viewPos);
	vec3 worldDir = normalize(mat3(modelViewInverse) * viewDir);
	return DecodeSkyLutColor(texture2D(skyLut, SkyViewLutUv(worldDir)).rgb);
}

vec3 SkyPreserveLuminance(const in vec3 source, const in vec3 styled) {
	float sourceLuma = Luma(max(source, vec3(0.0)));
	float styledLuma = Luma(max(styled, vec3(0.0)));
	return max(styled, vec3(0.0)) * (sourceLuma / max(styledLuma, 1.0e-6));
}

vec3 SkyApplyAppearance(
	const in vec3 source,
	const in vec3 viewDir,
	const in vec3 sunDir,
	const in vec3 upDir,
	const in float sunAltitude,
	const in float rainStrength
) {
	vec3 sky = max(source, vec3(0.0));
	float viewUp = clamp(dot(viewDir, upDir), -1.0, 1.0);
	float daylight = smoothstep(SkyAstronomicalTwilightAltitude(), SkyDaylightAltitude(), sunAltitude);
	float clearWeather = 1.0 - Saturate(rainStrength) * 0.45;

	float horizonRange = mix(0.035, 0.30, Saturate(FOXY_SKY_HORIZON_WHITE_RANGE / 1.50));
	float horizonMask = 1.0 - smoothstep(0.0, horizonRange, abs(viewUp));
	float horizonWhite = Saturate(FOXY_SKY_HORIZON_WHITE) * horizonMask * daylight * clearWeather;
	sky = mix(sky, vec3(Luma(sky)), horizonWhite * 0.58);

	float blueDelta = FOXY_SKY_BLUE_DEPTH - 1.0;
	float blueAmount = Saturate(abs(blueDelta)) * smoothstep(0.08, 0.76, viewUp) * smoothstep(-0.08, 0.16, sunAltitude) * clearWeather;
	vec3 blueTint = blueDelta >= 0.0
		? sky * vec3(0.90, 0.98, 1.16)
		: sky * vec3(1.08, 1.02, 0.88);
	sky = mix(sky, SkyPreserveLuminance(sky, blueTint), blueAmount);

	// Atmospheric transmittance exclusively owns sunset tint.
	return max(sky, vec3(0.0));
}

vec3 AtmosphereScatteringV3(
	const in vec3 rayDir,
	const in vec3 sunDir,
	const in vec3 moonDir,
	const in vec3 upDir,
	const in float sunAltitude,
	const in float rainStrength
) {
	const float planetRadius = 6371000.0;
	const float atmosphereRadius = 6471000.0;
	const float cameraAltitude = 80.0;
	const vec3 betaRayleigh = vec3(5.802, 13.558, 33.100) * 0.000001;
	const vec3 betaMieScatter = vec3(3.996) * 0.000001;
	const vec3 betaOzone = vec3(0.650, 1.881, 0.085) * 0.000001;

	vec3 geometricView = normalize(rayDir);
	vec3 up = normalize(upDir);
	vec3 sunRay = normalize(sunDir);
	vec3 moonRay = normalize(moonDir);
	float effectiveSunAltitude = clamp(dot(sunRay, up), -1.0, 1.0);
	float moonAltitude = clamp(dot(moonRay, up), -1.0, 1.0);
	float geometricViewUp = dot(geometricView, up);
	vec3 atmosphereView = SkyHorizonFogRay(geometricView, up);
	atmosphereView = SkyWarpViewRay(atmosphereView, up);
	vec3 viewRay = atmosphereView;
	float viewUp = dot(viewRay, up);
	// Lower-sky phase uses the real view direction, not the flattened fog ray.
	vec3 phaseView = geometricView;
	float phaseMu = clamp(dot(phaseView, sunRay), -1.0, 1.0);
	float moonPhaseMu = clamp(dot(phaseView, moonRay), -1.0, 1.0);
	float day = smoothstep(-0.105, 0.035, effectiveSunAltitude);
	float twilightCarry = smoothstep(SkyAstronomicalTwilightAltitude(), SkyCivilTwilightAltitude(), effectiveSunAltitude);
	float moonVisibility = MoonVisibility(moonAltitude) * (1.0 - SolarDiscVisibility(effectiveSunAltitude));

	vec3 origin = up * (planetRadius + cameraAltitude);
	vec2 topHit = SkyRaySphere(origin, viewRay, atmosphereRadius);
	float tEnd = max(topHit.y, 0.0);
	tEnd = clamp(tEnd, 10.0, 260000.0);

	float rayleighPhase = RayleighPhase(phaseMu);
	float moonRayleighPhase = RayleighPhase(moonPhaseMu);
#if FOXY_ATMOSPHERE_STYLE == 1
	float mieG = 0.76;
	float atmosphereScale = 5.6;
#elif FOXY_ATMOSPHERE_STYLE == 2
	float mieG = 0.80;
	float atmosphereScale = 6.5;
#else
	float mieG = 0.84;
	float atmosphereScale = 7.4;
#endif
	float miePhase = MiePhase(phaseMu, mieG);
	float moonMiePhase = MiePhase(moonPhaseMu, mieG);
	vec3 solarRadiance = vec3(1.051, 0.985, 0.940);
	vec3 lunarRadiance = MoonSpectrum() * (MoonPhaseIlluminance() * FOXY_MOON_INTENSITY * 1.45 * moonVisibility * mix(1.0, 0.52, rainStrength));
	vec3 opticalDepth = vec3(0.0);
	vec3 directScattering = vec3(0.0);
	vec3 multipleScattering = vec3(0.0);
	vec3 moonDirectScattering = vec3(0.0);
	vec3 moonMultipleScattering = vec3(0.0);
	float solarScatterActive = step(1.0e-6, max(day, twilightCarry));
	float lunarScatterActive = step(1.0e-6, moonVisibility);
	float stepLength = tEnd / 24.0;
	for (int i = 0; i < 24; i++) {
		float t = (float(i) + 0.5) * stepLength;
		vec3 samplePos = origin + viewRay * t;
		float radius = length(samplePos);
		float height = max(radius - planetRadius, 0.0);
		vec3 sampleUp = samplePos / max(radius, 1.0);
		float densityRayleigh = exp(-height / 8000.0);
		float densityMie = exp(-height / 1200.0);
		float densityOzone = SkyOzoneDensity(height);
		vec3 scatterRayleigh = betaRayleigh * densityRayleigh;
		vec3 scatterMie = betaMieScatter * densityMie;
		vec3 extinction = scatterRayleigh + AtmosphereMieExtinction() * densityMie + betaOzone * densityOzone;
		vec3 stepExtinction = extinction * stepLength;
		vec3 transmittanceView = exp(-min(opticalDepth + stepExtinction * 0.5, vec3(40.0)));
		if (solarScatterActive > 0.5) {
			float localSunMu = dot(sampleUp, sunRay);
			vec3 transmittanceSun = SkyTransmittanceToSun(samplePos, sunRay, rainStrength);
			vec3 directSource = solarRadiance * transmittanceSun * (scatterRayleigh * rayleighPhase + scatterMie * miePhase);
			vec3 multiIncident = SkyMultiScattering(height, localSunMu);
			vec3 multiSource = (scatterRayleigh + scatterMie) * multiIncident;
			directScattering += transmittanceView * directSource * stepLength;
			multipleScattering += transmittanceView * multiSource * stepLength;
		}
		if (lunarScatterActive > 0.5) {
			float localMoonMu = dot(sampleUp, moonRay);
			vec3 transmittanceMoon = SkyTransmittanceToSun(samplePos, moonRay, rainStrength);
			vec3 moonDirectSource = lunarRadiance * transmittanceMoon * (scatterRayleigh * moonRayleighPhase + scatterMie * moonMiePhase);
			vec3 moonMultiIncident = SkyMultiScattering(height, localMoonMu) * lunarRadiance;
			vec3 moonMultiSource = (scatterRayleigh + scatterMie) * moonMultiIncident;
			moonDirectScattering += transmittanceView * moonDirectSource * stepLength;
			moonMultipleScattering += transmittanceView * moonMultiSource * stepLength;
		}
		opticalDepth += stepExtinction;
	}

	float exposureScale = atmosphereScale * (FOXY_SKY_SCATTER_EXPOSURE / 0.15);
	vec3 solarSky = (directScattering + multipleScattering) * exposureScale;
	vec3 lunarSky = (moonDirectScattering + moonMultipleScattering) * exposureScale;
	vec3 sky = solarSky + lunarSky;
	float skyLuma = Luma(sky);
	sky = mix(vec3(skyLuma), sky, AtmosphereStyleSaturation() * (1.0 - rainStrength * 0.30));
	float visibility = max(day, twilightCarry * 0.82);
	vec3 nightSky = vec3(0.0025, 0.0045, 0.0110) + vec3(0.0040, 0.0050, 0.0110) * exp(-abs(viewUp) * 7.0);
	sky = mix(nightSky + lunarSky, max(sky, vec3(0.0)), visibility);
	vec3 appearanceView = geometricViewUp < 0.0 ? viewRay : geometricView;
	sky = SkyApplyAppearance(sky, appearanceView, sunRay, up, effectiveSunAltitude, rainStrength);

	return max(sky, vec3(0.0)) * PresentationSkyScale(effectiveSunAltitude);
}

vec3 AtmosphereScattering(
	const in vec3 rayDir,
	const in vec3 sunDir,
	const in vec3 moonDir,
	const in vec3 upDir,
	const in float sunAltitude,
	const in float rainStrength
) {
	return AtmosphereScatteringV3(rayDir, sunDir, moonDir, upDir, sunAltitude, rainStrength);
}

vec3 SkyRefractedSunDirection(
	const in vec3 sunDir,
	const in vec3 upDir,
	const in float sunAltitude
) {
	float altitudeDegrees = degrees(asin(clamp(sunAltitude, -1.0, 1.0)));
	if (altitudeDegrees > 85.0) {
		return sunDir;
	}
	// Clamp Bennett refraction below its -1 degree validity limit.
	float refractionAltitude = max(altitudeDegrees, -1.0);
	float denominator = tan(radians(refractionAltitude + 10.3 / (refractionAltitude + 5.11)));
	float refractionDegrees = max(1.02 / max(denominator, 0.05) / 60.0, 0.0);
	refractionDegrees *= 1.0 - smoothstep(-1.75, -1.0, altitudeDegrees);
	float apparentSunAltitude = sin(radians(altitudeDegrees + refractionDegrees));
	return SkySunDirectionWithAltitude(sunDir, upDir, apparentSunAltitude);
}

vec3 SunMoonDisks(
	const in vec3 rayDir,
	const in vec3 sunDir,
	const in vec3 moonDir,
	const in vec3 upDir,
	const in float sunAltitude,
	const in float moonAltitude,
	const in float rainStrength
) {
	#if FOXY_SKY_VANILLA_CELESTIALS == 1
		return vec3(0.0);
	#endif
	vec3 up = normalize(upDir);
	float rayAltitude = dot(rayDir, up);
	float sunHorizonClip = CelestialRayHorizonVisibility(rayAltitude);
	float moonHorizonClip = CelestialRayHorizonVisibility(rayAltitude);
	vec3 geometricSunDir = normalize(sunDir);
	float geometricSunAltitude = clamp(dot(geometricSunDir, up), -1.0, 1.0);
	vec3 apparentSunDir = SkyRefractedSunDirection(geometricSunDir, up, geometricSunAltitude);
	float apparentSunAltitude = clamp(dot(apparentSunDir, up), -1.0, 1.0);
	float sunDot = dot(rayDir, apparentSunDir);
	// Solar disc, atmospheric aureole, and post bloom have separate ownership.
	const float sunAngularRadius = FOXY_SUN_ANGULAR_RADIUS;
	float sunProfile = SunAngularSourceProfile(sunDot, sunAngularRadius) * sunHorizonClip;
	// Disc and aureole profiles remain monotonic and use fixed angular radii.
	const float aureoleAngularRadius = FOXY_SUN_ANGULAR_RADIUS * 1.35;
	float sunCosine = cos(sunAngularRadius);
	float aureoleCosine = cos(aureoleAngularRadius);
	float aureoleSpan = max(sunCosine - aureoleCosine, 1.0e-5);
	float aureoleGap = max(sunCosine - sunDot, 0.0) / aureoleSpan;
	float aureoleTail = 1.0 / (1.0 + 32.0 * aureoleGap * aureoleGap);
	float aureoleMask = 1.0 - smoothstep(sunCosine - aureoleSpan * 0.18, sunCosine, sunDot);
	float aureoleProfile = aureoleTail * aureoleMask;
	float lowSunAureole = 1.0 - smoothstep(-0.010, 0.110, geometricSunAltitude);
	float aureoleEnergy = mix(1.0, 0.35, lowSunAureole);
	vec3 sunTransmittance = SkySolarTransmittance(rayAltitude, rainStrength);
	float moonDisk = smoothstep(0.99925, 0.99986, dot(rayDir, moonDir)) * moonHorizonClip;
	const vec3 solarSpectrum = vec3(1.051, 0.985, 0.940);
	const float clearZenithTransmittance = 0.89;
	vec3 solarRadiance = solarSpectrum * sunTransmittance / clearZenithTransmittance;
	float visiblePhotosphere = smoothstep(-sunAngularRadius, sunAngularRadius, apparentSunAltitude);
	vec3 disk = solarRadiance * sunProfile * visiblePhotosphere * FOXY_SUN_DISK_BRIGHTNESS * PresentationSunScale(geometricSunAltitude);
	const float aureoleRadianceScale = 0.002;
	vec3 aureole = solarRadiance * aureoleProfile * aureoleEnergy * FOXY_SUN_DISK_BRIGHTNESS * 0.0006 * sunHorizonClip * visiblePhotosphere;
	vec3 sun = disk + aureole;
	vec3 moon = MoonColor(moonAltitude, rainStrength) * moonDisk * 8.0;
	#if FOXY_SKY_VANILLA_MOON == 1
		moon = vec3(0.0);
	#endif
	return sun + moon;
}

#endif
