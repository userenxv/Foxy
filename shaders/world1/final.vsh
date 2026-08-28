#version 120
#include "/lib/settings.glsl"
#define FOXY_FULLSCREEN_VERTEX_EXPOSURE
#define FOXY_FULLSCREEN_EXPOSURE_STATE_READ
#if FOXY_POST_RESOLVE_ACTIVE == 0
	#define FOXY_FULLSCREEN_EXPOSURE_CURRENT_STAGING
#endif
#define FOXY_FULLSCREEN_CELESTIAL_CACHE
#include "/entry/final/fullscreen.vsh"
