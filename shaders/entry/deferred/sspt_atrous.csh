#ifndef ENTRY_DEFERRED_SSPT_ATROUS_CSH
#define ENTRY_DEFERRED_SSPT_ATROUS_CSH

#include "/pipeline/framegraph.glsl"
#if FOXY_SSPT_ATROUS_PASS == 0
	#define FOXY_ACTIVE_STAGE FOXY_STAGE_SSPT_DENOISE_NEAR
#else
	#define FOXY_ACTIVE_STAGE FOXY_STAGE_SSPT_DENOISE_WIDE
#endif

#include "/program/sspt_atrous.csh"

#endif
