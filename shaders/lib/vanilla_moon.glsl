#ifndef FOXY_VANILLA_MOON_GLSL
#define FOXY_VANILLA_MOON_GLSL

#if FOXY_SKY_VANILLA_MOON == 1 && !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)

// Eight 8x8 source moon phases, copied verbatim from Minecraft's celestial
// textures. Each phase occupies one row in this 8 by 64 RGBA8 texture.
uniform sampler2D vanillaMoonCore;

vec3 VanillaMoonDisk(
	const in vec3 rayDir,
	const in vec3 moonDir,
	const in vec3 upDir,
	const in float moonAltitude,
	const in float rainStrength
) {
	vec3 moon = normalize(moonDir);
	vec3 up = normalize(upDir);
	vec3 tangent = cross(up, moon);
	if (dot(tangent, tangent) < 1.0e-6) {
		tangent = cross(vec3(1.0, 0.0, 0.0), moon);
	}
	tangent = normalize(tangent);
	vec3 bitangent = normalize(cross(moon, tangent));
	float forward = dot(rayDir, moon);
	if (forward <= 1.0e-5) {
		return vec3(0.0);
	}

const float halfExtent = 0.038;
	vec2 localUv = vec2(dot(rayDir, tangent), dot(rayDir, bitangent)) / forward;
	localUv = localUv / (2.0 * halfExtent) + 0.5;
	if (any(lessThan(localUv, vec2(0.0))) || any(greaterThanEqual(localUv, vec2(1.0)))) {
		return vec3(0.0);
	}

	vec2 pixel = floor(localUv * 8.0);
	float phase = clamp(float(moonPhase), 0.0, 7.0);
	vec2 textureUv = vec2((pixel.x + 0.5) / 8.0, (phase * 8.0 + pixel.y + 0.5) / 64.0);
	vec3 moonTexel = SrgbToLinear(texture2D(vanillaMoonCore, textureUv).rgb);
	float horizonVisibility = CelestialRayHorizonVisibility(dot(rayDir, up));
	return moonTexel * MoonColor(moonAltitude, rainStrength) * horizonVisibility * 8.0;
}

#endif

#endif
