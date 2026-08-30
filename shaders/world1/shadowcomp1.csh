#version 430

#define FOXY_DIM_END
#include "/lib/settings.glsl"
#include "/lib/voxel/irc_dispatch.glsl"

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1 && FOXY_IRC_SSPT_MODE == 1
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
	uint boundedCount = min(ircActiveCount, 2097152u);
	ircDispatchGroupsX = max((boundedCount + 63u) / 64u, 1u);
	ircDispatchGroupsY = 1u;
	ircDispatchGroupsZ = 1u;
	memoryBarrierBuffer();
}
#else
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);
void main() {}
#endif
