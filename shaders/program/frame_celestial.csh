#include "/lib/settings.glsl"
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);
#if FOXY_FRAME_CELESTIAL_CACHE == 1
#include "/lib/math.glsl"
#include "/lib/celestial.glsl"
#include "/lib/lighting.glsl"
#include "/lib/dimension_sky.glsl"
#define FOXY_FRAME_CELESTIAL_WRITE
#include "/lib/contracts/frame_celestial.glsl"
uniform mat4 gbufferModelView;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform vec3 shadowLightPosition;
uniform float rainStrength;
void main() {
	vec3 vertexSunLightColor;
	vec3 vertexMoonLightColor;
	vec3 vertexSkyAmbientColor;
	vec3 vertexSunView;
	vec3 vertexMoonView;
	vec3 vertexUpView;
	vec2 vertexShadowSelection;
	float vertexSunAltitude;
	float vertexMoonAltitude;
	vec3 celestialUp = normalize(upPosition);
	vec3 celestialSun;
	vec3 celestialMoon;
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, celestialUp, celestialSun, celestialMoon);
	vertexSunView = celestialSun;
	vertexMoonView = celestialMoon;
	vertexUpView = celestialUp;
	vec3 celestialShadow = normalize(shadowLightPosition);
	vec2 shadowSourceWeights = CelestialShadowSourceWeights(celestialShadow, celestialSun, celestialMoon);
	vertexShadowSelection = vec2(step(shadowSourceWeights.y, shadowSourceWeights.x), shadowSourceWeights.x + shadowSourceWeights.y);
	vertexSunAltitude = dot(celestialSun, celestialUp);
	vertexMoonAltitude = dot(celestialMoon, celestialUp);
	#if defined(FOXY_DIM_NETHER)
		vertexSunAltitude = -1.0;
		vertexMoonAltitude = -1.0;
		vertexSunLightColor = vec3(0.0);
		vertexMoonLightColor = vec3(0.0);
		#if FOXY_RAY_ACTIVE == 1
			vertexSkyAmbientColor = NetherEnvironmentFluence() * 4.0 * FOXY_AMBIENT_INTENSITY;
		#else
			vertexSkyAmbientColor = NetherAmbientColor();
		#endif
	#elif defined(FOXY_DIM_END)
		vertexSunView = normalize(mat3(gbufferModelView) * EndSunWorldDirection());
		vertexMoonView = -vertexSunView;
		vertexShadowSelection = vec2(1.0, 1.0);
		vertexSunAltitude = clamp(normalize(EndSunWorldDirection()).y, 0.05, 1.0);
		vertexMoonAltitude = -vertexSunAltitude;
		vertexSunLightColor = vec3(0.0);
		vertexMoonLightColor = vec3(0.0);
		#if FOXY_RAY_ACTIVE == 1
			vertexSkyAmbientColor = EndEnvironmentFluence() * 0.75 * FOXY_AMBIENT_INTENSITY;
		#else
			vertexSkyAmbientColor = EndAmbientColor();
		#endif
	#else
		vertexSunLightColor = SunColor(vertexSunAltitude, rainStrength);
		vertexMoonLightColor = MoonColor(vertexMoonAltitude, rainStrength);
		vertexSkyAmbientColor = SkyAmbientColor(vertexSunAltitude, rainStrength);
	#endif

	frameSunLight.rgb = vertexSunLightColor;
	frameMoonLight.rgb = vertexMoonLightColor;
	frameSkyAmbient.rgb = vertexSkyAmbientColor;
	frameSunView.xyz = vertexSunView;
	frameMoonView.xyz = vertexMoonView;
	frameUpView.xyz = vertexUpView;
	frameShadowSelection.xy = vertexShadowSelection;
	WeatherDay weather = WeatherCurrent();
	frameWeatherDayA = vec4(weather.cloudFactor, weather.cloudOffset, weather.fogDay, weather.fogTwilight);
	frameWeatherDayB = vec4(weather.noonDecay, weather.windSpeed, weather.fogSpeed, weather.sunScale);
	frameWeatherDrift = vec4(WeatherWindDrift(FOXY_WIND_CLOUDS), WeatherWindDrift(FOXY_WIND_FOG), 0.0, 0.0);
	frameSunView.w = vertexSunAltitude;
	frameMoonView.w = vertexMoonAltitude;
}
#else
void main() {}
#endif
