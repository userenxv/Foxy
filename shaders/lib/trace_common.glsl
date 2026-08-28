#ifndef FOXY_TRACE_COMMON_GLSL
#define FOXY_TRACE_COMMON_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

float TraceSafeDivisor(const in float x) {
	if (abs(x) < 1.0e-6) {
		return x < 0.0 ? -1.0e-6 : 1.0e-6;
	}
	return x;
}

vec3 TraceViewPosFromDepth(
	const in vec2 uv,
	const in float depth,
	const in mat4 projectionInverse
) {
	vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 view = projectionInverse * clip;
	return view.xyz / TraceSafeDivisor(view.w);
}

vec3 TraceViewRay(
	const in vec2 uv,
	const in mat4 projectionInverse
) {
	return normalize(TraceViewPosFromDepth(uv, 1.0, projectionInverse));
}

vec3 TracePlayerPosFromViewPos(
	const in vec3 viewPos,
	const in mat4 modelViewInverse
) {
	vec4 player = modelViewInverse * vec4(viewPos, 1.0);
	return player.xyz / TraceSafeDivisor(player.w);
}

float TraceLinearDepthFromRaw(
	const in float rawDepth,
	const in float nearPlane,
	const in float farPlane
) {
	float ndcZ = rawDepth * 2.0 - 1.0;
	return (2.0 * nearPlane * farPlane) / max(farPlane + nearPlane - ndcZ * (farPlane - nearPlane), 1.0e-4);
}

float TraceRayLengthFromRawDepth(
	const in float rawDepth,
	const in vec3 rayDirView,
	const in float nearPlane,
	const in float farPlane,
	const in float maxDistance
) {
	if (rawDepth >= 0.99999) {
		return maxDistance;
	}
	float viewZDistance = TraceLinearDepthFromRaw(rawDepth, nearPlane, farPlane);
	return min(viewZDistance / max(-rayDirView.z, 0.055), maxDistance);
}

#endif
