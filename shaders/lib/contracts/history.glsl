#ifndef FOXY_HISTORY_GLSL
#define FOXY_HISTORY_GLSL

#include "/lib/contracts/endpoint.glsl"
#include "/lib/contracts/images.glsl"

float HistoryEndpointCompatible(
	const in Endpoint currentEndpoint,
	const in Endpoint previousEndpoint
) {
	float currentValid = EndpointValid(currentEndpoint);
	float previousValid = EndpointValid(previousEndpoint);
	if (currentValid < 0.5 && previousValid < 0.5) {
		return 1.0;
	}
	if (currentValid < 0.5 || previousValid < 0.5) {
		return 0.0;
	}
	if (abs(currentEndpoint.owner - previousEndpoint.owner) >= 0.5) {
		return 0.0;
	}
	if (abs(currentEndpoint.medium - previousEndpoint.medium) >= 0.5) {
		return 0.0;
	}
	if (abs(EndpointBackendDomain(currentEndpoint.owner) - EndpointBackendDomain(previousEndpoint.owner)) >= 0.5) {
		return 0.0;
	}
	float distanceScale = max(max(currentEndpoint.rayDistance, previousEndpoint.rayDistance), 1.0);
	float distanceTolerance = max(0.25, distanceScale * 0.02);
	return 1.0 - step(distanceTolerance, abs(currentEndpoint.rayDistance - previousEndpoint.rayDistance));
}

#if defined(FOXY_IMAGE_LAYER_ENDPOINT_PREVIOUS) || defined(FOXY_IMAGE_LAYER_ENDPOINT_PING_PONG)
float HistoryValidateLayerAt(
	const in Endpoint currentEndpoint,
	const in vec2 previousUv
) {
	Endpoint previousEndpoint = EndpointUnpack(LoadLayerEndpointPrevious(previousUv));
	return HistoryEndpointCompatible(currentEndpoint, previousEndpoint);
}
#endif

#endif
