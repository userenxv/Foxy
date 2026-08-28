#ifndef FOXY_LIGHTING_GLSL
#define FOXY_LIGHTING_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

#if !defined(FOXY_EXTERNAL_PIPELINE_BINDINGS)
uniform int moonPhase;
#endif

vec3 ColorTemperatureToRgb(const in float kelvin) {
	float t = clamp(kelvin, 1000.0, 40000.0) / 100.0;
	float r = t <= 66.0 ? 1.0 : Saturate(1.292936186062745 * pow(max(t - 60.0, 1.0), -0.1332047592));
	float g = t <= 66.0 ? Saturate(0.3900815787690196 * log(max(t, 1.0)) - 0.6318414437886275) : Saturate(1.129890860895294 * pow(max(t - 60.0, 1.0), -0.0755148492));
	float b = t >= 66.0 ? 1.0 : (t <= 19.0 ? 0.0 : Saturate(0.5432067891101961 * log(max(t - 10.0, 1.0)) - 1.19625408914));
	return vec3(r, g, b);
}

vec3 ColorTemperatureTint(const in float kelvin) {
	if (abs(kelvin - 6500.0) < 0.5) {
		return vec3(1.0);
	}
	vec3 neutral = max(ColorTemperatureToRgb(6500.0), vec3(0.04));
	vec3 tint = ColorTemperatureToRgb(kelvin) / neutral;
	return max(tint / max(Luma(tint), 0.04), vec3(0.0));
}

float TwilightFactor(const in float sunAltitude) {
	return smoothstep(-0.16, 0.07, sunAltitude) * (1.0 - smoothstep(0.14, 0.44, sunAltitude));
}

float SolarDiscVisibility(const in float sunAltitude) {
	// Solar radius and refraction keep the disc visible below geometric zero.
	return smoothstep(-0.0175, -0.0040, sunAltitude);
}

float CelestialRayHorizonVisibility(const in float rayAltitude) {
	// Disc visibility is separate from atmospheric scattering.
	return smoothstep(-0.0040, 0.0180, rayAltitude);
}

float DirectCelestialVisibility(const in float sourceAltitude) {
	// Shadow maps cannot represent direct light below the world horizon.
	return smoothstep(0.0, 0.0175, sourceAltitude);
}

float AtmosphereStyleWarp() {
#if FOXY_ATMOSPHERE_STYLE == 1
	return 0.0;
#elif FOXY_ATMOSPHERE_STYLE == 2
	return 0.50;
#else
	return 1.0;
#endif
}

float AtmosphereStyleSaturation() {
#if FOXY_ATMOSPHERE_STYLE == 1
	return 1.02;
#elif FOXY_ATMOSPHERE_STYLE == 2
	return 1.10;
#else
	return 1.20;
#endif
}

float AtmosphereStyleAerosol() {
#if FOXY_ATMOSPHERE_STYLE == 1
	return 0.78;
#elif FOXY_ATMOSPHERE_STYLE == 2
	return 1.0;
#else
	return 1.34;
#endif
}

float AtmosphereChapman(const in float x, const in float mu) {
	float c = sqrt(0.5 * PI * x);
	if (mu >= 0.0) {
		return c / max((c - 1.0) * mu + 1.0, 1.0e-4);
	}
	float sinTheta = sqrt(clamp(1.0 - mu * mu, 0.0, 1.0));
	float horizonTerm = 2.0 * c * exp(min(x - x * sinTheta, 40.0)) * sqrt(max(sinTheta, 0.0));
	return c / min((c - 1.0) * mu - 1.0, -1.0e-4) + horizonTerm;
}

vec3 AtmosphereMieExtinction() {
#if FOXY_ATMOSPHERE_STYLE == 1
	return vec3(4.00, 4.44, 5.00) * 0.000001;
#elif FOXY_ATMOSPHERE_STYLE == 2
	return vec3(3.70, 4.44, 5.80) * 0.000001;
#else
	return vec3(3.30, 4.44, 6.80) * 0.000001;
#endif
}

// Shared ground-level optical transmittance for distant celestial sources.
float SunsetWarmthControl() {
	return Saturate((FOXY_SKY_SUNSET_WARMTH - 1.0) * 0.50);
}

float SunsetAerosolScale(const in float sourceAltitude) {
	float lowSun = 1.0 - smoothstep(0.015, 0.82, clamp(sourceAltitude, -0.035, 1.0));
	// Low-altitude aerosol modifies the shared solar spectrum at its source.
	return 1.0 + SunsetWarmthControl() * lowSun * 2.50;
}

// Low-altitude aerosol transmittance shared by every SunColor consumer.
vec3 SunsetAerosolTransmittance(const in float sourceAltitude) {
	float lowSun = 1.0 - smoothstep(0.015, 0.82, clamp(sourceAltitude, -0.035, 1.0));
	float opticalPath = SunsetWarmthControl() * lowSun * 3.0;
	vec3 betaAerosol = vec3(0.12, 0.28, 0.62);
	return exp(-betaAerosol * opticalPath);
}

vec3 AtmosphereCelestialTransmittance(const in float sourceAltitude, const in float rainStrength) {
	const float planetRadius = 6371000.0;
	const float rayleighHeight = 8000.0;
	const float mieHeight = 1200.0;
	const vec3 betaRayleigh = vec3(5.802, 13.558, 33.100) * 0.000001;
	const vec3 betaOzone = vec3(0.650, 1.881, 0.085) * 0.000001;
	float mu = clamp(sourceAltitude, -0.035, 1.0);
	float rayleighMass = rayleighHeight * AtmosphereChapman(planetRadius / rayleighHeight, mu);
	float mieMass = mieHeight * AtmosphereChapman(planetRadius / mieHeight, mu);
	float lowSun = 1.0 - smoothstep(0.035, 0.22, mu);
	float aerosol = mix(1.0, AtmosphereStyleAerosol(), lowSun) * mix(1.0, 1.55, rainStrength);
	aerosol *= SunsetAerosolScale(sourceAltitude);
	float ozoneMass = rayleighMass * mix(0.18, 0.34, lowSun);
	vec3 extinction = betaRayleigh * rayleighMass + AtmosphereMieExtinction() * (mieMass * aerosol) + betaOzone * ozoneMass;
	return exp(-min(extinction, vec3(40.0))) * SunsetAerosolTransmittance(sourceAltitude);
}

// Separate low-altitude spectral response for distant emissive sources.
vec3 AtmosphereDistantCelestialTransmittance(const in float sourceAltitude, const in float rainStrength) {
	const float planetRadius = 6371000.0;
	const float rayleighHeight = 8000.0;
	const float mieHeight = 1200.0;
	const vec3 betaRayleigh = vec3(5.802, 13.558, 33.100) * 0.000001;
	const vec3 betaOzone = vec3(0.650, 1.881, 0.085) * 0.000001;
	float mu = clamp(sourceAltitude, -0.060, 1.0);
	float rayleighMass = rayleighHeight * AtmosphereChapman(planetRadius / rayleighHeight, mu);
	float mieMass = mieHeight * AtmosphereChapman(planetRadius / mieHeight, mu);
	float lowAltitude = 1.0 - smoothstep(0.10, 0.38, mu);
	float aerosol = mix(1.0, AtmosphereStyleAerosol() * 1.55, lowAltitude) * mix(1.0, 1.65, rainStrength);
	float ozoneMass = rayleighMass * mix(0.22, 0.58, lowAltitude);
	vec3 extinction = betaRayleigh * rayleighMass + AtmosphereMieExtinction() * (mieMass * aerosol) + betaOzone * ozoneMass;
	return exp(-min(extinction, vec3(40.0)));
}

vec3 AtmosphereSolarTransmittance(const in float sunAltitude, const in float rainStrength) {
	return AtmosphereCelestialTransmittance(sunAltitude, rainStrength);
}

float CloudWeatherMapDirectLightVisibility(const in float rainStrength) {
	// Rain removes directional light but preserves sky and fog illumination.
	float storm = smoothstep(0.0, 1.0, Saturate(rainStrength));
	return mix(1.0, 0.025, storm);
}

vec3 SunColor(const in float sunAltitude, const in float rainStrength) {
	float day = smoothstep(-0.08, 0.16, sunAltitude);
	vec3 transmittance = AtmosphereSolarTransmittance(sunAltitude, rainStrength);
	vec3 solar = vec3(1.051, 0.985, 0.940) * transmittance;
	float solarLuma = max(Luma(solar), 0.006);
	float solarEnergy = Saturate(solarLuma / (Luma(vec3(1.051, 0.985, 0.940)) * 0.89));
	vec3 chroma = solar / solarLuma;
#if FOXY_ATMOSPHERE_STYLE == 1
	chroma = pow(max(chroma, vec3(0.0)), vec3(0.62));
#elif FOXY_ATMOSPHERE_STYLE == 2
	chroma = pow(max(chroma, vec3(0.0)), vec3(0.76));
#else
	chroma = pow(max(chroma, vec3(0.0)), vec3(0.92));
#endif
	chroma /= max(Luma(chroma), 0.05);
	float energy = day * FOXY_SUN_INTENSITY * 2.18 * solarEnergy * PresentationSunScale(sunAltitude);
	return chroma * energy * CloudWeatherMapDirectLightVisibility(rainStrength);
}

float MoonPhaseIlluminance() {
	float phaseDistance = abs(float(moonPhase) - 4.0) * 0.25;
	return mix(0.10, 1.0, Saturate(phaseDistance));
}

float MoonVisibility(const in float moonAltitude) {
	return smoothstep(-0.012, 0.045, moonAltitude);
}

vec3 MoonSpectrum() {
	return vec3(0.75, 0.83, 1.00);
}

vec3 MoonColor(const in float moonAltitude, const in float rainStrength) {
	float visibility = MoonVisibility(moonAltitude);
	vec3 transmittance = AtmosphereDistantCelestialTransmittance(moonAltitude, rainStrength);
	vec3 transmittedMoon = MoonSpectrum() * transmittance;
	vec3 chroma = transmittedMoon / max(Luma(transmittedMoon), 0.025);
	chroma = pow(max(chroma, vec3(0.0)), vec3(0.78));
	chroma /= max(Luma(chroma), 0.05);
	float altitudeEnergy = mix(0.38, 1.0, smoothstep(0.012, 0.26, moonAltitude));
	float energy = visibility * altitudeEnergy * MoonPhaseIlluminance() * FOXY_MOON_INTENSITY * 1.45;
	return chroma * energy * CloudWeatherMapDirectLightVisibility(rainStrength);
}

vec3 MoonAmbientColor(const in float moonAltitude, const in float rainStrength) {
	return MoonColor(moonAltitude, rainStrength) * vec3(0.12, 0.15, 0.20) * FOXY_AMBIENT_INTENSITY;
}

vec3 MoonAmbientColorFromMoonColor(const in vec3 moonColor) {
	return moonColor * vec3(0.12, 0.15, 0.20) * FOXY_AMBIENT_INTENSITY;
}

// Water scattering uses continuous source irradiance, not shadow-map selection.
float WaterSolarIrradiance(const in vec3 solarColor, const in float sunAltitude) {
	float reference = max(FOXY_SUN_INTENSITY * 2.18, 1.0e-4);
	return DirectCelestialVisibility(sunAltitude) * Saturate(Luma(solarColor) / reference);
}

float WaterLunarIrradiance(const in vec3 lunarColor, const in float moonAltitude) {
	float reference = max(FOXY_SUN_INTENSITY * 2.18, 1.0e-4);
	return DirectCelestialVisibility(moonAltitude) * Saturate(Luma(lunarColor) / reference);
}

vec3 SkyAmbientColor(const in float sunAltitude, const in float rainStrength) {
	float day = smoothstep(-0.105, 0.035, sunAltitude);
	float twilight = TwilightFactor(sunAltitude);
	vec3 nightAmbient = vec3(0.014, 0.018, 0.030);
	vec3 dayAmbient = vec3(0.30, 0.39, 0.55);
	vec3 twilightAmbient = vec3(0.56, 0.42, 0.29);
	vec3 ambient = mix(nightAmbient, dayAmbient, day);
	ambient = mix(ambient, twilightAmbient, twilight * (1.0 - rainStrength * 0.45) * 0.34);
	// Diffuse skylight inherits a restrained low-sun spectral shift.
	vec3 solarTransmittance = AtmosphereSolarTransmittance(sunAltitude, rainStrength);
	float solarTransmittanceLuma = max(Luma(solarTransmittance), 1.0e-4);
	vec3 solarChroma = solarTransmittance / solarTransmittanceLuma;
	vec3 warmAmbient = ambient * solarChroma;
	warmAmbient *= Luma(ambient) / max(Luma(warmAmbient), 1.0e-4);
	float ambientSunsetWeight = twilight * (1.0 - smoothstep(0.035, 0.22, sunAltitude)) * 0.18;
	ambient = mix(ambient, warmAmbient, ambientSunsetWeight * (1.0 - rainStrength * 0.45));
	// Apply aerosol luminance loss after chroma preservation.
	ambient *= Luma(SunsetAerosolTransmittance(sunAltitude));
	float ambientLuma = Luma(ambient);
	float daylightNeutrality = day * (1.0 - twilight * 0.72) * FOXY_SKY_AMBIENT_NEUTRALITY;
	ambient = mix(ambient, vec3(ambientLuma), Saturate(daylightNeutrality));
	ambient *= mix(1.0, FOXY_SKY_AMBIENT_LIFT, day * (1.0 - twilight * 0.45));
	return ambient * FOXY_AMBIENT_INTENSITY * PresentationSkyScale(sunAltitude) *
		mix(1.0, 0.48, rainStrength);
}

float WaterSkyIrradiance(const in vec3 skyAmbient, const in float rainStrength) {
	float noonLuma = Luma(vec3(0.30, 0.39, 0.55))
		* FOXY_AMBIENT_INTENSITY
		* FOXY_SKY_AMBIENT_LIFT
		* PresentationSkyScale(0.60)
		* mix(1.0, 0.48, rainStrength);
	return Saturate(Luma(skyAmbient) / max(noonLuma, 1.0e-4));
}

float AmbientSkyVisibility(const in float sunAltitude, const in float skyLight) {
	float night = 1.0 - smoothstep(-0.105, 0.035, sunAltitude);
	float minimumVisibility = mix(0.12, 0.34, night);
	float skyAccess = smoothstep(0.02, 0.92, Saturate(skyLight));
	return mix(minimumVisibility, 1.0, skyAccess);
}

// Automatic key uses a 12.5% reflected-light calibration ceiling.
float ExposureKeyFromMeterEv(const in float meterEv) {
	float meteredLuminance = exp2(clamp(meterEv, -20.0, 20.0));
	float logAverage = log2(1.0 + meteredLuminance) * 0.30102999566;
	float automaticKey = 1.03 - 2.0 / (2.0 + logAverage);
	return clamp(automaticKey, 0.030, 0.125);
}

float AutoExposureFromMeterEv(const in float meterEv) {
	float targetGrey = ExposureKeyFromMeterEv(meterEv);
	float exposureEv = log2(targetGrey) - meterEv;
	float exposure = clamp(exp2(exposureEv), FOXY_PRESENTATION_EXPOSURE_MIN, FOXY_PRESENTATION_EXPOSURE_MAX);
	return mix(1.0, exposure, Saturate(FOXY_PRESENTATION_AUTO_WEIGHT));
}

vec3 ApplyPurkinjeVision(
	const in vec3 color,
	const in float sunAltitude,
	const in float blockLight,
	const in float skyLight,
	const in float eyeSkyLight
) {
	float night = 1.0 - smoothstep(-0.105, 0.015, sunAltitude);
	if (night <= 1.0e-6 || FOXY_PURKINJE_SHIFT <= 0.0) {
		return color;
	}

	float photopicLuminance = Luma(color);
	float scotopicLuminance = dot(color, vec3(0.062, 0.608, 0.330));
	float localDarkness = 1.0 - smoothstep(0.018, 0.180, photopicLuminance);
	float blockSuppression = 1.0 - smoothstep(0.08, 0.78, Saturate(blockLight));
	float skyAdaptation = max(Saturate(skyLight), Saturate(eyeSkyLight));
	float openSkyResponse = mix(0.28, 1.0, skyAdaptation * skyAdaptation);
	float amount = Saturate(FOXY_PURKINJE_SHIFT) * night * localDarkness * blockSuppression * openSkyResponse;
	if (amount <= 1.0e-6 || photopicLuminance <= 1.0e-7) {
		return color;
	}

	float targetLuminance = mix(photopicLuminance, scotopicLuminance, 0.42);
	vec3 reducedChroma = mix(vec3(photopicLuminance), color, 0.58);
	vec3 coolResponse = reducedChroma * vec3(0.82, 0.96, 1.10);
	coolResponse *= targetLuminance / max(Luma(coolResponse), 1.0e-6);
	return max(mix(color, coolResponse, amount), vec3(0.0));
}

vec3 TorchColor(const in float blockLight) {
	float b = blockLight * blockLight;
	return vec3(1.0, 0.52, 0.22) * b * 1.35;
}

vec3 FogColorFromClearSunColor(const in float sunAltitude, const in float rainStrength, const in vec3 clearSunColor) {
	float day = smoothstep(-0.105, 0.035, sunAltitude);
	float twilight = TwilightFactor(sunAltitude);
	vec3 nightFog = vec3(0.20, 0.25, 0.34);
	vec3 dayFog = vec3(0.34, 0.48, 0.72);
	vec3 twilightFog = clearSunColor / max(Luma(clearSunColor), 0.08);
	vec3 rainFog = vec3(0.38, 0.43, 0.48);
	vec3 fog = mix(nightFog, dayFog, day);
	float warmMix = twilight * (1.0 - rainStrength * 0.55) * mix(0.16, 0.28, AtmosphereStyleWarp());
	fog = mix(fog, twilightFog * max(Luma(fog), 0.06), warmMix);
	return mix(fog, rainFog, rainStrength * 0.65) * PresentationSkyScale(sunAltitude);
}

vec3 FogColor(const in float sunAltitude, const in float rainStrength) {
	return FogColorFromClearSunColor(sunAltitude, rainStrength, SunColor(sunAltitude, 0.0));
}

vec3 ApplyFogWithSurfaceTransmission(
	const in vec3 color,
	const in vec3 fogColor,
	const in vec3 boundarySkyColor,
	const in vec2 boundarySkyWeights,
	const in vec3 viewPos,
	const in vec3 worldPos,
	const in vec3 cameraWorldPos,
	const in vec3 upDir,
	out vec3 surfaceTransmission
) {
	float viewDistance = length(viewPos);
	vec3 viewDir = normalize(viewPos);
	float viewUp = dot(viewDir, upDir);
	float horizonFog = pow(1.0 - Saturate(viewUp * 0.5 + 0.5), 2.0);
	float fog = 0.0;
	#if FOXY_VOLUMETRIC_LIGHT == 0
		float clearRadius = mix(12.0, 145.0, FOXY_FOG_START);
		float farDistance = max(viewDistance - clearRadius, 0.0);
		float edgeFog = smoothstep(clearRadius, clearRadius + 180.0, viewDistance);
		edgeFog = edgeFog * edgeFog * (3.0 - 2.0 * edgeFog);
		float lowViewFog = smoothstep(-0.35, 0.16, -viewUp) * 0.32;
		float edgeDensity = max(FOXY_FOG_DENSITY, 0.0) * (0.00175 + horizonFog * 0.00345 + lowViewFog * 0.00175);
		fog = 1.0 - exp(-farDistance * edgeDensity);
		fog = Saturate(fog * (0.45 + 0.85 * edgeFog) + horizonFog * edgeFog * FOXY_FOG_DENSITY * 0.34);
	#endif

	float worldHeight = max(worldPos.y - FOXY_WORLD_FOG_HEIGHT, 0.0);
	float heightFalloff = exp(-worldHeight / max(FOXY_WORLD_FOG_FALLOFF, 1.0));
	float cameraHeight = max(cameraWorldPos.y - FOXY_WORLD_FOG_HEIGHT, 0.0);
	float cameraHeightFade = mix(1.0, 0.45, smoothstep(0.0, FOXY_WORLD_FOG_FALLOFF * 2.0, cameraHeight));
	float worldFogDensity = FOXY_WORLD_FOG_STRENGTH * heightFalloff * cameraHeightFade * (0.0025 + horizonFog * 0.0018);
	float worldFog = 1.0 - exp(-viewDistance * worldFogDensity);
	worldFog *= smoothstep(8.0, 96.0, viewDistance);
	fog = Saturate(fog + worldFog * (1.0 - fog) * 0.92);

	float skywardFactor = Saturate(viewUp * 0.5 + 0.5);
	float boundaryBlue = 1.0 - skywardFactor;
	float blueShift = max(FOXY_FOG_BLUE_SHIFT, 0.0);
	// Rayleigh airlight grows with optical path; sunset fog retains its source hue.
	float aerialPerspective = Saturate(fog * 1.18);
	float coolAir = smoothstep(0.015, 0.22, fogColor.b - fogColor.r);
	float warmAir = smoothstep(0.015, 0.22, fogColor.r - fogColor.b);
	float rayleighWeight = aerialPerspective * mix(0.30, 0.72, coolAir) * (1.0 - warmAir * 0.55);
	vec3 distanceFogColor = fogColor * mix(vec3(1.0), vec3(0.84, 0.94, 1.20), rayleighWeight);
	distanceFogColor *= Luma(fogColor) / max(Luma(distanceFogColor), 1.0e-5);
	vec3 baseBlueTint = mix(vec3(1.0), vec3(0.92, 0.96, 1.04), boundaryBlue * min(blueShift, 1.0));
	vec3 extraBlueTint = mix(vec3(1.0), vec3(0.78, 0.88, 1.22), boundaryBlue * Saturate((blueShift - 1.0) * 0.50));
	vec3 volumeTint = distanceFogColor * baseBlueTint * extraBlueTint;
	float baseTintLuma = max(Luma(distanceFogColor * baseBlueTint), 1.0e-5);
	float shiftedTintLuma = max(Luma(volumeTint), 1.0e-5);
	volumeTint *= mix(1.0, baseTintLuma / shiftedTintLuma, Saturate((blueShift - 1.0) * 0.65));
	float boundaryBlend = Saturate(boundarySkyWeights.x) * smoothstep(0.015, 0.22, fog);
	volumeTint = mix(volumeTint, max(boundarySkyColor, vec3(0.0)), boundaryBlend);
	float opticalDepth = -log(max(1.0 - fog, 1.0e-4));
	vec3 aerosolSpectrum = mix(vec3(0.94, 1.0, 1.08), vec3(0.82, 1.0, 1.28), AtmosphereStyleWarp());
	vec3 transmittance = exp(-opticalDepth * aerosolSpectrum);
	vec3 foggedColor = color * transmittance + volumeTint * (vec3(1.0) - transmittance);
	surfaceTransmission = transmittance * (1.0 - Saturate(boundarySkyWeights.y));
	return mix(foggedColor, max(boundarySkyColor, vec3(0.0)), Saturate(boundarySkyWeights.y));
}

vec3 ApplyFog(
	const in vec3 color,
	const in vec3 fogColor,
	const in vec3 boundarySkyColor,
	const in vec2 boundarySkyWeights,
	const in vec3 viewPos,
	const in vec3 worldPos,
	const in vec3 cameraWorldPos,
	const in vec3 upDir
) {
	vec3 surfaceTransmission;
	return ApplyFogWithSurfaceTransmission(
		color,
		fogColor,
		boundarySkyColor,
		boundarySkyWeights,
		viewPos,
		worldPos,
		cameraWorldPos,
		upDir,
		surfaceTransmission
	);
}

vec3 ApplyFog(
	const in vec3 color,
	const in vec3 fogColor,
	const in vec3 viewPos,
	const in vec3 worldPos,
	const in vec3 cameraWorldPos,
	const in vec3 upDir
) {
	return ApplyFog(color, fogColor, fogColor, vec2(0.0), viewPos, worldPos, cameraWorldPos, upDir);
}

vec3 ApplyFog(const in vec3 color, const in vec3 fogColor, const in vec3 viewPos, const in vec3 upDir) {
	return ApplyFog(color, fogColor, viewPos, vec3(0.0, FOXY_WORLD_FOG_HEIGHT + 100000.0, 0.0), vec3(0.0, FOXY_WORLD_FOG_HEIGHT + 100000.0, 0.0), upDir);
}

#endif
