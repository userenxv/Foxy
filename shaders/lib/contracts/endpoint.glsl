#ifndef FOXY_ENDPOINT_GLSL
#define FOXY_ENDPOINT_GLSL

#include "/lib/contracts/backend.glsl"

#define FOXY_ENDPOINT_OWNER_NONE 0.0
#define FOXY_ENDPOINT_OWNER_MAIN 1.0
#define FOXY_ENDPOINT_OWNER_LOD 2.0
#define FOXY_ENDPOINT_OWNER_CLOUD 3.0
#define FOXY_ENDPOINT_OWNER_MAIN_WATER 4.0
#define FOXY_ENDPOINT_OWNER_LOD_WATER 5.0
#define FOXY_ENDPOINT_OWNER_VOXY 6.0
#define FOXY_ENDPOINT_OWNER_VOXY_WATER 7.0
#define FOXY_ENDPOINT_OWNER_MAIN_GLASS 8.0

#define FOXY_ENDPOINT_MEDIUM_AIR 0.0
#define FOXY_ENDPOINT_MEDIUM_WATER 1.0
#define FOXY_ENDPOINT_MEDIUM_CLOUD 2.0

const float FOXY_ENDPOINT_INFINITY = 1.0e30;
const float FOXY_ENDPOINT_VALID_RAW = 0.99999;
const float FOXY_ENDPOINT_CLOUD_ALPHA_MIN = 1.0e-4;
const float FOXY_ENDPOINT_CLOUD_DISTANCE_LIMIT = 60000.0;

float SceneReach(const in float mainFar) {
	return max(mainFar, BackendRenderDistance());
}

struct Endpoint {
	float rayDistance;
	float viewDistance;
	float owner;
	float medium;
};

struct WaterSegment {
	float frontRayDistance;
	float frontViewDistance;
	float owner;
	float valid;
};

float EndpointValid(const in Endpoint endpoint) {
	return 1.0 - step(FOXY_ENDPOINT_INFINITY * 0.5, endpoint.rayDistance);
}

float EndpointBackendDomain(const in float owner) {
	if (abs(owner - FOXY_ENDPOINT_OWNER_LOD) < 0.5 ||
		abs(owner - FOXY_ENDPOINT_OWNER_LOD_WATER) < 0.5) {
		return BackendDomain();
	}
#if defined(VOXY)
	if (abs(owner - FOXY_ENDPOINT_OWNER_VOXY) < 0.5 ||
		abs(owner - FOXY_ENDPOINT_OWNER_VOXY_WATER) < 0.5) {
		return FOXY_BACKEND_DOMAIN_VOXY;
	}
#endif
	if (abs(owner - FOXY_ENDPOINT_OWNER_MAIN) < 0.5 ||
		abs(owner - FOXY_ENDPOINT_OWNER_MAIN_WATER) < 0.5 ||
		abs(owner - FOXY_ENDPOINT_OWNER_MAIN_GLASS) < 0.5) {
		return FOXY_BACKEND_DOMAIN_MAIN;
	}
	return 0.0;
}

Endpoint EndpointSky() {
	Endpoint endpoint;
	endpoint.rayDistance = FOXY_ENDPOINT_INFINITY;
	endpoint.viewDistance = FOXY_ENDPOINT_INFINITY;
	endpoint.owner = FOXY_ENDPOINT_OWNER_NONE;
	endpoint.medium = FOXY_ENDPOINT_MEDIUM_AIR;
	return endpoint;
}

WaterSegment WaterSegmentInvalid() {
	WaterSegment segment;
	segment.frontRayDistance = FOXY_ENDPOINT_INFINITY;
	segment.frontViewDistance = FOXY_ENDPOINT_INFINITY;
	segment.owner = FOXY_ENDPOINT_OWNER_NONE;
	segment.valid = 0.0;
	return segment;
}

vec3 EndpointMainViewPosition(
	const in vec2 viewUv,
	const in float rawDepth,
	const in mat4 mainProjectionInverse
) {
	vec4 clip = vec4(viewUv * 2.0 - 1.0, rawDepth * 2.0 - 1.0, 1.0);
	vec4 view = mainProjectionInverse * clip;
	float safeW = abs(view.w) < 1.0e-6
		? (view.w < 0.0 ? -1.0e-6 : 1.0e-6)
		: view.w;
	return view.xyz / safeW;
}

Endpoint ResolveOpaqueEndpoint(
	const in vec2 viewUv,
	const in vec2 sampleUv,
	const in float mainRawDepth,
	const in mat4 mainProjectionInverse
) {
	Endpoint endpoint = EndpointSky();
	BackendOpaqueSurface surface = BackendResolveOpaqueSurface(
		viewUv,
		sampleUv,
		mainRawDepth,
		mainProjectionInverse
	);
	if (surface.valid > 0.5) {
		endpoint.rayDistance = length(surface.viewPosition);
		endpoint.viewDistance = max(-surface.viewPosition.z, 0.0);
		endpoint.owner = FOXY_ENDPOINT_OWNER_MAIN;
#if defined(VOXY)
		if (abs(surface.domain - FOXY_BACKEND_DOMAIN_VOXY) < 0.5) {
			endpoint.owner = FOXY_ENDPOINT_OWNER_VOXY;
		}
#endif
		if (abs(surface.domain - FOXY_BACKEND_DOMAIN_DH) < 0.5) {
			endpoint.owner = FOXY_ENDPOINT_OWNER_LOD;
		}
		endpoint.medium = FOXY_ENDPOINT_MEDIUM_AIR;
	}
	return endpoint;
}

vec3 ResolveOpaqueViewPosition(
	const in vec2 viewUv,
	const in vec2 sampleUv,
	const in float mainRawDepth,
	const in mat4 mainProjectionInverse,
	out float valid
) {
	BackendOpaqueSurface surface = BackendResolveOpaqueSurface(
		viewUv,
		sampleUv,
		mainRawDepth,
		mainProjectionInverse
	);
	valid = surface.valid;
	return surface.viewPosition;
}

vec3 EndpointViewRay(
	const in Endpoint endpoint,
	const in vec2 viewUv,
	const in mat4 mainProjectionInverse
) {
	if (abs(endpoint.owner - FOXY_ENDPOINT_OWNER_LOD) < 0.5 ||
		abs(endpoint.owner - FOXY_ENDPOINT_OWNER_LOD_WATER) < 0.5) {
		return BackendLodViewRay(viewUv);
	}
	// Voxy depth has already been decoded into a scalar distance at the backend
	// boundary. All later endpoint consumers live on the shared view grid,
	// so their direction must be the shared camera ray rather than a second
	// application of Voxy's private raster projection.
	return normalize(EndpointMainViewPosition(viewUv, 1.0, mainProjectionInverse));
}

vec3 EndpointViewPosition(
	const in Endpoint endpoint,
	const in vec2 viewUv,
	const in float mainRawDepth,
	const in mat4 mainProjectionInverse
) {
	if (abs(endpoint.owner - FOXY_ENDPOINT_OWNER_MAIN) < 0.5 && mainRawDepth < FOXY_ENDPOINT_VALID_RAW) {
		return EndpointMainViewPosition(viewUv, mainRawDepth, mainProjectionInverse);
	}
	return EndpointViewRay(endpoint, viewUv, mainProjectionInverse) * max(endpoint.rayDistance, 0.0);
}

vec4 EndpointPreviousClip(
	const in Endpoint endpoint,
	const in vec4 previousViewPosition,
	const in mat4 mainPreviousProjection
) {
	if (abs(endpoint.owner - FOXY_ENDPOINT_OWNER_LOD) < 0.5 ||
		abs(endpoint.owner - FOXY_ENDPOINT_OWNER_LOD_WATER) < 0.5) {
		return BackendLodPreviousClip(previousViewPosition);
	}
	// History is a shared-screen resource. Voxy's previous projection is
	// only meaningful for a Voxy-owned target, not this presentation history.
	return mainPreviousProjection * previousViewPosition;
}

Endpoint ResolveCloudEndpoint(
	const in Endpoint opaque,
	const in float cloudDistance,
	const in float cloudAlpha
) {
	Endpoint endpoint = opaque;
	float cloudValid = step(FOXY_ENDPOINT_CLOUD_ALPHA_MIN, cloudAlpha);
	float finiteDistance = 1.0 - step(FOXY_ENDPOINT_INFINITY * 0.5, cloudDistance);
	if (cloudValid > 0.5 && finiteDistance > 0.5 && cloudDistance < opaque.rayDistance) {
		endpoint.rayDistance = max(cloudDistance, 0.0);
		endpoint.viewDistance = endpoint.rayDistance;
		endpoint.owner = FOXY_ENDPOINT_OWNER_CLOUD;
		endpoint.medium = FOXY_ENDPOINT_MEDIUM_CLOUD;
	}
	return endpoint;
}

Endpoint ResolveWaterEndpoint(
	const in Endpoint layer,
	const in float waterFrontRayDistance,
	const in float waterFrontViewDistance,
	const in float waterValid,
	const in float waterOwner,
	const in float waterMedium
) {
	Endpoint endpoint = layer;
	if (waterValid > 0.5 && waterFrontRayDistance < layer.rayDistance) {
		endpoint.rayDistance = max(waterFrontRayDistance, 0.0);
		endpoint.viewDistance = max(waterFrontViewDistance, 0.0);
		endpoint.owner = waterOwner;
		endpoint.medium = waterMedium;
	}
	return endpoint;
}

bool EndpointOwnerIs(
	const in Endpoint endpoint,
	const in float owner
) {
	return abs(endpoint.owner - owner) < 0.5;
}

vec4 EndpointPack(const in Endpoint endpoint) {
	return vec4(endpoint.rayDistance, endpoint.viewDistance, endpoint.owner, endpoint.medium);
}

Endpoint EndpointUnpack(const in vec4 encoded) {
	Endpoint endpoint;
	endpoint.rayDistance = encoded.x;
	endpoint.viewDistance = encoded.y;
	endpoint.owner = encoded.z;
	endpoint.medium = encoded.w;
	return endpoint;
}

vec4 WaterSegmentPack(const in WaterSegment segment) {
	return vec4(segment.frontRayDistance, segment.frontViewDistance, segment.owner, segment.valid);
}

WaterSegment WaterSegmentUnpack(const in vec4 encoded) {
	WaterSegment segment;
	segment.frontRayDistance = encoded.x;
	segment.frontViewDistance = encoded.y;
	segment.owner = encoded.z;
	segment.valid = encoded.w;
	return segment;
}

#endif
