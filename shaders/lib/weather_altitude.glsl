#ifndef FOXY_WEATHER_ALTITUDE_GLSL
#define FOXY_WEATHER_ALTITUDE_GLSL

// Altitude response of the weather, kept apart from the particle model so that
// passes with no bound shader texture (the sky LUT bake) can use it too.
//
// Rain falls out of the cloud layer, so a camera that has climbed into it is above
// the weather.  This returns how much of the weather is still present: 1.0 at the
// cloud base, 0.0 once the camera is clear of the top.  Scaling the effective rain
// strength by it returns the grey sky and the visible rain to their clear-weather
// state together, instead of each effect needing its own altitude rule.
//
// The camera height is a parameter rather than a uniform read: every program
// declares its own uniforms, so a helper cannot rely on one being in scope.

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

float WeatherAltitudeFade(const in float cameraY) {
	float cloudBase = FOXY_CLOUD_HEIGHT;
	float fadeEnd = max(
		cloudBase + FOXY_CLOUD_THICKNESS * 0.5,
		cloudBase * max(FOXY_CLOUD_TOP_LIMIT, 1.0) + 64.0
	);
	return 1.0 - smoothstep(cloudBase, fadeEnd, cameraY);
}

#endif
