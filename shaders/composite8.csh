#version 430 compatibility
#include "/lib/settings.glsl"
#if FOXY_VOLUME_RESOLVE_TILED == 1 && FOXY_VOLUMETRIC_LIGHT == 1
	#include "/program/volumetric_resolve.csh"
#else
	layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
	const ivec3 workGroups = ivec3(1, 1, 1);
	void main() {}
#endif
