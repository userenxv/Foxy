#ifndef FOXY_WEATHER_PARTICLES_GLSL
#define FOXY_WEATHER_PARTICLES_GLSL

// Rain and snow particles: wind lean, screen-coverage normalization, near fade
// and tint with a scattering floor.

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/weather_altitude.glsl"

uniform sampler2D texture;
uniform float rainStrength;

// Vanilla paints rain as a saturated blue and snow as plain grey, so the blue bias
// is what tells them apart.  Snow's channels are equal, which is why this compares
// against blue rather than against luminance.
bool WeatherParticleIsRain(const in vec4 texel) {
	return (texel.b - texel.r) > 0.10;
}

// The splash vanilla raises where rain lands is a far more saturated blue than the
// falling streak, and it sits on the ground rather than in the air, so it is the
// one precipitation particle that must not take the near fade.
bool WeatherParticleIsSplash(const in vec4 texel) {
	return (texel.b - texel.r) > 0.40 && texel.b > 0.55;
}

// texcoordSlope is the texture-coordinate rate per pixel, i.e. how far the particle
// is stretched across the screen.  A streak seen edge-on already covers a lot of
// area and must not also be opaque; a compressed one needs full weight to stay
// visible.  The two smoothsteps overlap so the response has no corner.
float WeatherParticleCoverage(const in vec2 texcoordSlope) {
	float footprint = dot(texcoordSlope, vec2(0.05, 1.25));
	float compressed = smoothstep(0.030, 0.120, footprint);
	float stretched = smoothstep(0.450, 1.600, footprint);
	return mix(mix(1.0, 0.34, stretched), 1.06, compressed);
}

// A particle a metre from the eye covers most of the screen, and a column of them
// fills it completely.
float WeatherParticleNearFade(const in float viewDistance) {
	float fade = Saturate(viewDistance / max(FOXY_WEATHER_NEAR_FADE, 1.0e-3));
	return fade * fade * (3.0 - 2.0 * fade);
}

// Applied in world space in the vertex stage, so the lean belongs to the particle
// and not to the camera.
vec3 WeatherParticleSlant(
	const in vec3 worldPos,
	const in float time,
	const in float rainStrength
) {
	#if FOXY_WEATHER_SLANT > 0.0
		float amount = FOXY_WEATHER_SLANT * (0.55 + 0.45 * Saturate(rainStrength));
		float phase = dot(worldPos.xz, vec2(0.061, 0.047)) + time * 0.36;
		vec2 lean = vec2(cos(phase), sin(phase * 0.83));
		float wave = mix(1.0, 0.35 + 0.65 * sin(dot(worldPos, vec3(0.021)) + time * 0.21), FOXY_WEATHER_SLANT_WAVE);
		worldPos.xz += lean * (amount * wave) * worldPos.y;
	#endif
	return worldPos;
}

// Particle lighting.  Deriving this from the pack's own celestial colours means
// precipitation inherits the weather's desaturation and dusk shift instead of
// being a hand-picked constant.  The luminance floor is the physical half: drops
// scatter the light that reaches them forward, which is why a streak stays
// visible against an overcast sky that is darker than itself.
vec3 WeatherParticleTint(
	const in vec3 sunLightColor,
	const in vec3 moonLightColor,
	const in float sunAltitude,
	const in float moonAltitude,
	const in float rainStrength,
	const in bool isRain
) {
	float day = smoothstep(-0.10, 0.42, sunAltitude);
	float night = smoothstep(-0.02, 0.22, moonAltitude) * (1.0 - day);
	vec3 celestial = sunLightColor * (day + 0.18) + moonLightColor * night;
	float chroma = Luma(celestial);
	// Guard the fully dark case, where there is no celestial light to tint with.
	vec3 tint = mix(vec3(0.42, 0.52, 0.70), celestial / max(chroma, 1.0e-4), smoothstep(0.002, 0.05, chroma));
	tint *= isRain ? vec3(0.78, 0.90, 1.16) : vec3(0.96, 1.00, 1.10);
	tint *= mix(1.10, 0.72, Saturate(rainStrength));
	float targetLuma = FOXY_WEATHER_SCATTER_FLOOR * (1.0 + 0.70 * Luma(sunLightColor));
	float tintLuma = max(Luma(tint), 1.0e-4);
	return tint * mix(1.0, max(targetLuma, tintLuma) / tintLuma, smoothstep(0.0, 0.55, tintLuma));
}

// Opacity of one particle fragment, as a premultiplied result.
float WeatherParticleAlpha(
	const in float baseAlpha,
	const in float surfaceAlpha,
	const in vec2 texcoordSlope,
	const in float viewDistance
) {
	return baseAlpha * surfaceAlpha * FOXY_WEATHER_OPACITY
		* WeatherParticleCoverage(texcoordSlope)
		* WeatherParticleNearFade(viewDistance);
}

#endif
