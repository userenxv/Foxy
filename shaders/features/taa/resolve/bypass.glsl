#ifndef FOXY_TAA_RESOLVE_BYPASS_GLSL
#define FOXY_TAA_RESOLVE_BYPASS_GLSL

// Stable replaceable core interface. A temporal implementation may replace
// this function, but the surrounding complete-current framegraph contract must
// not change with the algorithm.
vec3 ResolveTemporalWorldEncoded(
	const in vec2 viewUv,
	const in vec3 currentWorldEncoded
) {
	return currentWorldEncoded;
}

#endif
