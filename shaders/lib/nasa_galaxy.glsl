#ifndef FOXY_NASA_GALAXY_GLSL
#define FOXY_NASA_GALAXY_GLSL

#if FOXY_NASA_GALAXY == 1 && !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)

// NASA Deep Star Map 2020 is stored as a linear RGBA16F equirectangular map.
// Keep this outside the sky LUT so its 4K detail is sampled per sky pixel.
uniform sampler2D nasaGalaxy;

vec2 NasaGalaxyUv(const in vec3 worldDir, const in int worldTick) {
	// Counter-rotate the texture with the sun, moon, and Minecraft sky dome.
	float rotation = -float(worldTick) * (2.0 * PI / 24000.0);
	float c = cos(rotation);
	float s = sin(rotation);
	vec3 celestialDir = vec3(
		worldDir.x * c - worldDir.z * s,
		worldDir.y,
		worldDir.x * s + worldDir.z * c
	);
	float u = fract(atan(celestialDir.x, -celestialDir.z) / (2.0 * PI) + 0.5);
	float v = acos(clamp(celestialDir.y, -1.0, 1.0)) / PI;
	return vec2(u, v);
}

vec3 NasaGalaxyRadiance(
	const in vec3 worldDir,
	const in float sunAltitude,
	const in float rainStrength,
	const in int worldTick
) {
	float nightVisibility = 1.0 - smoothstep(-0.18, 0.045, sunAltitude);
	// Let the physical RGB transmittance perform the low-horizon fade and
	// reddening. This gate only removes sources that are geometrically below it.
	float horizonVisibility = smoothstep(-0.015, 0.025, worldDir.y);
	float weatherVisibility = 1.0 - Saturate(rainStrength) * 0.95;
	float visibility = nightVisibility * horizonVisibility * weatherVisibility;
	vec3 galaxy = max(texture2D(nasaGalaxy, NasaGalaxyUv(normalize(worldDir), worldTick)).rgb, vec3(0.0));
	vec3 transmittance = AtmosphereDistantCelestialTransmittance(worldDir.y, rainStrength);
	return galaxy * transmittance * (FOXY_NASA_GALAXY_INTENSITY * visibility);
}

#endif

#endif
