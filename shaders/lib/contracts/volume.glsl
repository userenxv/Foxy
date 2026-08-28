#ifndef FOXY_VOLUME_CONTRACT_GLSL
#define FOXY_VOLUME_CONTRACT_GLSL

#include "/lib/settings.glsl"
#include "/lib/contracts/endpoint.glsl"

struct VolumeRay {
	vec3 viewDirection;
	float fogDistance;
	float lightDistance;
	float extendedReach;
	float endpointValid;
};

float VolumeFogReach(const in float mainFar) {
	return max(SceneReach(mainFar), 1.0);
}

float VolumeFogDistanceFromEndpoint(
	const in Endpoint endpoint,
	const in float mainFar
) {
	float fogReach = VolumeFogReach(mainFar);
	if (EndpointValid(endpoint) > 0.5) {
		return min(max(endpoint.rayDistance, 0.0), fogReach);
	}
	return fogReach;
}

float VolumeLightDistance() {
	return max(FOXY_VL_DISTANCE, 1.0);
}

float VolumeDirectRangeWeight(
	const in float distanceAlongRay,
	const in float lightDistance
) {
	float normalizedDistance = max(distanceAlongRay, 0.0) / max(lightDistance, 1.0);
	return 1.0 - smoothstep(0.72, 1.0, normalizedDistance);
}

VolumeRay VolumeRayFromEndpoint(
	const in Endpoint endpoint,
	const in vec2 viewUv,
	const in mat4 mainProjectionInverse,
	const in float mainFar
) {
	VolumeRay ray;
	ray.viewDirection = normalize(EndpointViewRay(endpoint, viewUv, mainProjectionInverse));
	ray.endpointValid = EndpointValid(endpoint);
	ray.fogDistance = VolumeFogDistanceFromEndpoint(endpoint, mainFar);
	ray.lightDistance = VolumeLightDistance();
	ray.extendedReach = step(max(mainFar, 1.0) + 1.0, BackendRenderDistance());
	return ray;
}

#endif
