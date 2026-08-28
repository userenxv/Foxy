#version 430 compatibility
#include "/lib/settings.glsl"
#if FOXY_TAA_ENABLED == 1
	/* RENDERTARGETS: 11,12 */
#else
	/* RENDERTARGETS: 11 */
#endif
const bool colortex11Clear = false;
#if FOXY_TAA_ENABLED == 1
const bool colortex12Clear = false;
#endif
#include "/entry/composite/temporal_boundary.fsh"
