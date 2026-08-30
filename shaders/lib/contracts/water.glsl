#ifndef FOXY_CONTRACT_WATER_GLSL
#define FOXY_CONTRACT_WATER_GLSL

#include "/lib/contracts/endpoint.glsl"
#include "/lib/contracts/images.glsl"
#include "/lib/contracts/water_surface.glsl"

struct WaterProducerPacket {
	float frontRayDistance;
	vec3 baseNormalView;
	float backRayDistance;
	float owner;
};

vec2 WaterProducerEncodeNormalOct(const in vec3 inputNormal) {
	vec3 normal = normalize(inputNormal);
	normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), 1.0e-6);
	vec2 encoded = normal.xy;
	if (normal.z < 0.0) {
		vec2 direction = step(vec2(0.0), encoded) * 2.0 - 1.0;
		encoded = (vec2(1.0) - abs(encoded.yx)) * direction;
	}
	return encoded * 0.5 + 0.5;
}

vec3 WaterProducerDecodeNormalOct(const in vec2 encodedNormal) {
	vec2 encoded = encodedNormal * 2.0 - 1.0;
	vec3 normal = vec3(encoded, 1.0 - abs(encoded.x) - abs(encoded.y));
	if (normal.z < 0.0) {
		vec2 direction = step(vec2(0.0), normal.xy) * 2.0 - 1.0;
		normal.xy = (vec2(1.0) - abs(normal.yx)) * direction;
	}
	return normalize(normal);
}

float WaterProducerPackBaseNormal(const in vec3 baseNormalView) {

vec2 encoded = floor(WaterProducerEncodeNormalOct(baseNormalView) * 4095.0 + 0.5);
	return encoded.x * 4096.0 + encoded.y;
}

vec3 WaterProducerUnpackBaseNormal(const in float packedNormal) {
	float packedValue = clamp(floor(packedNormal + 0.5), 0.0, 16777215.0);
	float encodedX = floor(packedValue * (1.0 / 4096.0));
	float encodedY = packedValue - encodedX * 4096.0;
	return WaterProducerDecodeNormalOct(vec2(encodedX, encodedY) * (1.0 / 4095.0));
}

WaterProducerPacket WaterProducerInvalid() {
	WaterProducerPacket packet;
	packet.frontRayDistance = FOXY_ENDPOINT_INFINITY;
	packet.baseNormalView = vec3(0.0, 1.0, 0.0);
	packet.backRayDistance = FOXY_ENDPOINT_INFINITY;
	packet.owner = FOXY_ENDPOINT_OWNER_NONE;
	return packet;
}

WaterProducerPacket WaterProducerUnpack(const in vec4 encoded) {
	WaterProducerPacket packet;
	packet.frontRayDistance = encoded.x;
	packet.baseNormalView = WaterProducerUnpackBaseNormal(encoded.y);
	packet.backRayDistance = encoded.z;
	packet.owner = encoded.w;
	return packet;
}

vec4 WaterProducerPack(
	const in float frontRayDistance,
	const in vec3 baseNormalView,
	const in float backRayDistance,
	const in float owner
) {
	return vec4(
		max(frontRayDistance, 0.0),
		WaterProducerPackBaseNormal(baseNormalView),
		max(backRayDistance, 0.0),
		owner
	);
}

#if defined(FOXY_IMAGE_MAIN_WATER_PRODUCER_CURRENT)
WaterProducerPacket ResolveWaterProducer(const in vec2 sampleUv) {
	WaterProducerPacket mainPacket = WaterProducerUnpack(LoadMainWaterProducer(sampleUv));
	float mainValid = step(0.5, mainPacket.owner);
	if (mainValid > 0.5) {
		return mainPacket;
	}
#if defined(VOXY)
	float voxyFrontRaw = BackendLodFrontRaw(sampleUv);
	if (BackendHasLodSurface(voxyFrontRaw)) {

vec2 voxyViewUv = BackendVoxyDepthViewUv(sampleUv);
		vec3 voxyFrontView = BackendLodViewPosition(voxyViewUv, voxyFrontRaw);
		WaterProducerPacket voxyPacket;
		voxyPacket.frontRayDistance = length(voxyFrontView);

voxyPacket.baseNormalView = vec3(0.0, 1.0, 0.0);
		voxyPacket.backRayDistance = voxyPacket.frontRayDistance;
		voxyPacket.owner = FOXY_ENDPOINT_OWNER_VOXY_WATER;
		float voxyBackRaw = BackendLodSolidRaw(sampleUv);
		if (BackendHasLodSurface(voxyBackRaw)) {
			voxyPacket.backRayDistance = length(BackendLodViewPosition(voxyViewUv, voxyBackRaw));
		}
		return voxyPacket;
	}
#elif defined(FOXY_IMAGE_LOD_WATER_PRODUCER_CURRENT)
	WaterProducerPacket lodPacket = WaterProducerUnpack(LoadLodWaterProducer(sampleUv));
	float lodValid = step(0.5, lodPacket.owner);
	if (lodValid > 0.5) {
		return lodPacket;
	}
#endif
	return WaterProducerInvalid();
}
#endif

float WaterProducerIsValid(const in WaterProducerPacket packet) {
	return step(0.5, packet.owner);
}

float WaterProducerVisibleBeforeOpaque(
	const in WaterProducerPacket packet,
	const in Endpoint opaqueEndpoint
) {
	float valid = WaterProducerIsValid(packet);
	float inFront = 1.0 - step(opaqueEndpoint.rayDistance, packet.frontRayDistance);
	return valid * inFront;
}

vec3 WaterProducerViewPosition(
	const in vec2 viewUv,
	const in vec2 sampleUv,
	const in WaterProducerPacket packet,
	const in mat4 mainProjectionInverse,
	const in mat4 mainModelView
) {
	if (WaterProducerIsValid(packet) < 0.5) {
		return vec3(0.0);
	}
	vec3 viewRay;
	#if defined(VOXY)
	if (abs(packet.owner - FOXY_ENDPOINT_OWNER_VOXY_WATER) < 0.5) {

vec2 voxyViewUv = BackendVoxyDepthViewUv(sampleUv);
		vec3 voxyViewPosition = BackendLodViewRay(voxyViewUv) * max(packet.frontRayDistance, 0.0);
		return BackendLodViewToMainView(voxyViewPosition, mainModelView);
	} else
	#endif
	if (abs(packet.owner - FOXY_ENDPOINT_OWNER_LOD_WATER) < 0.5) {
		viewRay = BackendLodViewRay(viewUv);
	} else {
		viewRay = normalize(EndpointMainViewPosition(viewUv, 1.0, mainProjectionInverse));
	}
	return viewRay * max(packet.frontRayDistance, 0.0);
}

vec2 ProducerScreenUv(const in vec2 viewportSize) {
	return clamp(gl_FragCoord.xy / max(viewportSize, vec2(1.0)), vec2(0.0), vec2(0.999999));
}

#endif
