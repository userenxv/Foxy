#version 430 compatibility
#define FOXY_FULLSCREEN_CELESTIAL_CACHE
#define PT_GBUFFER_READ
#include "/lib/settings.glsl"
#if FOXY_DOF == 1
	#if FOXY_POST_RESOLVE_ACTIVE == 0
		const bool colortex11MipmapEnabled = true;
	#else
		const bool colortex0MipmapEnabled = true;
	#endif
#endif
/*
const int colortex0Format = RGBA16F;
const int colortex1Format = RGBA16F;
const int colortex2Format = RGBA16;
const int colortex3Format = RGBA16F;
const int colortex5Format = RGBA16F;
const int colortex6Format = RGBA16F;
const int colortex7Format = RGBA16F;
const int colortex8Format = RGBA16F;
const int colortex9Format = RG16F;
const int colortex10Format = RGBA16F;
const int colortex11Format = RGBA16F;
const int colortex12Format = RGBA16F;
const int colortex13Format = RGBA16F;
const int colortex14Format = RGBA16F;
const int colortex15Format = RGBA32F;
*/
#include "/entry/final/present.fsh"
