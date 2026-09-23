#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/lighting.glsl"
#include "/lib/weather_particles.glsl"

/* DRAWBUFFERS:3 */

uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;

varying vec2 texcoord;
varying vec4 surfaceColor;
// Reported by the shared textured vertex stage, in blocks.
varying float weatherViewDistance;

// Both vanilla precipitation particles end up in this layer: the falling streaks
// and the splash they raise on impact.  They share colortex3 with gbuffers_weather,
// so both have to be tinted with the same weather colour; tinting only the streaks
// leaves the splashes painted in the pack's own blue.
void main() {
	vec4 baseTexel = texture2D(texture, texcoord);
	vec4 texel = baseTexel * surfaceColor;
	if (texel.a < 0.10) discard;

	// Above the cloud layer the camera is out of the weather: the particles fade out
	// and the tint slides back to its clear-weather value with them.
	float altitudeFade = WeatherAltitudeFade(cameraPosition.y);
	float effectiveRain = rainStrength * altitudeFade;

	float precipitationFade = 1.0;
	vec3 encodedColor = EncodeSceneColor(SrgbToLinear(clamp(texel.rgb, 0.0, 1.0)));

	if (effectiveRain > 0.01) {
		bool isRain = WeatherParticleIsRain(baseTexel);
		if (isRain) {
			vec3 sunView = normalize(sunPosition);
			vec3 moonView = normalize(moonPosition);
			vec3 upView = normalize(upPosition);
			float sunAltitude = dot(sunView, upView);
			float moonAltitude = dot(moonView, upView);
			vec3 tint = WeatherParticleTint(
				SunColor(sunAltitude, effectiveRain),
				MoonColor(moonAltitude, effectiveRain),
				sunAltitude,
				moonAltitude,
				effectiveRain,
				true
			);
			// The near fade belongs to the falling streaks, which saturate the layer
			// when they are stretched across it.  A splash sits on the ground at the
			// eye's own distance, so the fade is replaced by a flat weight: vanilla's
			// splash texture is fully opaque where the streak is not, and at full
			// weight the impact reads as a solid speck of paint.
			precipitationFade = WeatherParticleIsSplash(baseTexel)
				? FOXY_WEATHER_SPLASH_OPACITY
				: WeatherParticleNearFade(weatherViewDistance);
			encodedColor = EncodeSceneColor(tint);
		}
	}

	precipitationFade *= altitudeFade;
	gl_FragData[0] = vec4(encodedColor * texel.a * precipitationFade, texel.a * precipitationFade);
}
