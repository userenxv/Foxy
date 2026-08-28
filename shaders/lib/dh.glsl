#ifndef FOXY_DH_COMPATIBILITY_FACADE_GLSL
#define FOXY_DH_COMPATIBILITY_FACADE_GLSL

// Compatibility names for third-party includes.  All ownership and depth
// behavior lives in the backend/endpoint contracts; this facade contains no
// distance, radius, or material-marker heuristic.
#include "/lib/contracts/endpoint.glsl"

float DhDepth0(const in vec2 uv) {
	return BackendLodFrontRaw(uv);
}

float DhDepth1(const in vec2 uv) {
	return BackendLodSolidRaw(uv);
}

vec3 DhViewPosition(const in vec2 uv, const in float rawDepth) {
	return BackendLodViewPosition(uv, rawDepth);
}

bool DhFrontSurface(
	const in vec2 uv,
	const in float mainDepth,
	const in mat4 mainProjectionInverse
) {
	Endpoint endpoint = ResolveOpaqueEndpoint(
		uv,
		uv,
		mainDepth,
		mainProjectionInverse
	);
	return abs(endpoint.owner - FOXY_ENDPOINT_OWNER_LOD) < 0.5;
}

float DhSurfaceMask(
	const in vec2 uv,
	const in float mainDepth,
	const in mat4 mainProjectionInverse
) {
	return DhFrontSurface(uv, mainDepth, mainProjectionInverse) ? 1.0 : 0.0;
}

float DhFarDistance(const in float mainFar) {
	return SceneReach(mainFar);
}

#endif
