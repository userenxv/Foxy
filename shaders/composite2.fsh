#version 430 compatibility
#define FOXY_FULLSCREEN_CELESTIAL_CACHE
#include "/lib/settings.glsl"

#if FOXY_MATERIAL_REFLECTIONS == 1
	/* RENDERTARGETS: 11,14 */
	const bool colortex11Clear = false;
#else
	/* RENDERTARGETS: 14 */
#endif
const bool colortex14Clear = false;

#include "/entry/composite/water_composite.fsh"
