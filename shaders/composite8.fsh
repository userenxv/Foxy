#version 430 compatibility
/* RENDERTARGETS: 6,0 */
const bool colortex6Clear = false;
const bool colortex0Clear = false;
#include "/lib/settings.glsl"
#if FOXY_VOLUME_RESOLVE_TILED == 1 && FOXY_VOLUMETRIC_LIGHT == 1
// Compute writes current images directly. The matching flip=false directives
// keep these images current. Retain the raster stage as an Iris pass anchor;
// no fullscreen copy, no framebuffer writes, and no read/write feedback.
void main() { discard; }

#else
	#include "/entry/composite/volumetric_resolve.fsh"
#endif
