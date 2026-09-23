#ifndef FOXY_FRAME_CELESTIAL_GLSL
#define FOXY_FRAME_CELESTIAL_GLSL
// 10 vec4 slots = 160 bytes, FP32 throughout. Sole writer: prepare compute.
// Bindings 0..7 belong to voxel/GI resources; binding 8 is frame state.
#ifdef FOXY_FRAME_CELESTIAL_WRITE
layout(std430, binding = 8) writeonly buffer FoxyFrameCelestial {
#else
layout(std430, binding = 8) readonly buffer FoxyFrameCelestial {
#endif
	vec4 frameSunLight;
	vec4 frameMoonLight;
	vec4 frameSkyAmbient;
	vec4 frameSunView;
	vec4 frameMoonView;
	vec4 frameUpView;
	vec4 frameShadowSelection;
	vec4 frameWeatherDayA; // cloud factor/offset, aerosol day/twilight
	vec4 frameWeatherDayB; // noon decay, wind, fog wind, sun scale
	vec4 frameWeatherDrift; // integrated cloud/fog drift, reserved, reserved
};
#endif
