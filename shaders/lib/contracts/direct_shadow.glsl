#ifndef FOXY_CONTRACT_DIRECT_SHADOW_GLSL
#define FOXY_CONTRACT_DIRECT_SHADOW_GLSL

// Opaque direct-light payload carried to the completed-depth stage. RGB is the
// exact final-space contribution that may still be removed by a farther
// blocker; alpha is the visibility already applied by the native shadow map.
vec4 DirectShadowPack(
	const in vec3 removableDirect,
	const in float nativeVisibility
) {
	return vec4(
		max(removableDirect, vec3(0.0)),
		clamp(nativeVisibility, 0.0, 1.0)
	);
}

vec3 DirectShadowContribution(const in vec4 packet) {
	return max(packet.rgb, vec3(0.0));
}

float DirectShadowNativeVisibility(const in vec4 packet) {
	return clamp(packet.a, 0.0, 1.0);
}

#endif
