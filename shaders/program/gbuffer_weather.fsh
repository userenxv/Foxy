// Included by gbuffers_weather.fsh, which owns the #version directive.

#define ALPHA_TEST
#define WEATHER

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/lighting.glsl"
#include "/lib/weather_particles.glsl"

uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;

varying vec2 texcoord;
varying vec4 surfaceColor;
varying float weatherViewDistance;

void main() {
	vec4 baseTexel = texture2D(texture, texcoord);
	#ifdef ALPHA_TEST
		if (baseTexel.a < 0.10) discard;
	#endif

	// Above the cloud layer the camera is out of the weather, so the streaks fade
	// out and the tint slides back to its clear-weather value with them.
	float altitudeFade = WeatherAltitudeFade(cameraPosition.y);
	float effectiveRain = rainStrength * altitudeFade;

	vec3 sunView = normalize(sunPosition);
	vec3 moonView = normalize(moonPosition);
	vec3 upView = normalize(upPosition);
	float sunAltitude = dot(sunView, upView);
	float moonAltitude = dot(moonView, upView);

	bool isRain = WeatherParticleIsRain(baseTexel);
	vec3 tint = WeatherParticleTint(
		SunColor(sunAltitude, effectiveRain),
		MoonColor(moonAltitude, effectiveRain),
		sunAltitude,
		moonAltitude,
		effectiveRain,
		isRain
	);

	float alpha = WeatherParticleAlpha(
		baseTexel.a,
		surfaceColor.a,
		fwidth(texcoord),
		weatherViewDistance
	) * altitudeFade;
	// Colortex3 is composited with premultiplied alpha further down the chain.
	gl_FragData[0] = vec4(EncodeSceneColor(tint) * alpha, alpha);
}
