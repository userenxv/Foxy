#ifndef FOXY_TAA_RESOLVE_BYPASS_GLSL
#define FOXY_TAA_RESOLVE_BYPASS_GLSL

vec3 ResolveTemporalWorldEncoded(
	const in vec2 viewUv,
	const in vec3 currentWorldEncoded
) {
	return currentWorldEncoded;
}

#endif
