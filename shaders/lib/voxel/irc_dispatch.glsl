#ifndef FOXY_IRC_DISPATCH_GLSL
#define FOXY_IRC_DISPATCH_GLSL

#include "/lib/settings.glsl"

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
layout(std430, binding = 3) coherent buffer IrradianceFeedback {
	#if FOXY_IRC_SSPT_MODE == 1
		uint ircDispatchGroupsX;
		uint ircDispatchGroupsY;
		uint ircDispatchGroupsZ;
	#endif
	uint ircActiveCount;
	uint ircActiveCells[];
};
#endif

#endif
