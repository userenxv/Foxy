#ifndef FOXY_CONTRACT_MATERIAL_GLSL
#define FOXY_CONTRACT_MATERIAL_GLSL

// colortex2 is the PT material packet while the ray pipeline is active.  The
// high byte of its packed blue/class word is reserved for this explicit water
// packet; ordinary PT surface classes are 0..7 and cannot collide with it.
const float FOXY_MATERIAL_WATER_SENTINEL = 1.0;
const float FOXY_MATERIAL_WATER_GLINT_MAX = 192.0;
const float FOXY_MATERIAL_WATER_GLINT_LOG_RANGE = 7.59245703727; // log2(1 + 192)
const float FOXY_MATERIAL_GLASS_SENTINEL = 0.996;

vec2 MaterialEncodeWaterNormal(const in vec3 inputNormal) {
	vec3 normal = normalize(inputNormal);
	normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), 1.0e-6);
	vec2 encoded = normal.xy;
	if (normal.z < 0.0) {
		vec2 direction = step(vec2(0.0), encoded) * 2.0 - 1.0;
		encoded = (vec2(1.0) - abs(encoded.yx)) * direction;
	}
	return encoded * 0.5 + 0.5;
}

vec3 MaterialDecodeWaterNormal(const in vec2 encodedNormal) {
	vec2 encoded = encodedNormal * 2.0 - 1.0;
	vec3 normal = vec3(encoded, 1.0 - abs(encoded.x) - abs(encoded.y));
	if (normal.z < 0.0) {
		vec2 direction = step(vec2(0.0), normal.xy) * 2.0 - 1.0;
		normal.xy = (vec2(1.0) - abs(normal.yx)) * direction;
	}
	return normalize(normal);
}

float MaterialIsWater(const in vec4 packet) {
	return step(0.999, packet.y);
}

float MaterialIsGlass(const in vec4 packet) {
	return step(0.993, packet.y) * (1.0 - step(0.999, packet.y));
}

float MaterialPackGlassTransmission(const in vec3 transmission) {
	// colortex2 is RGBA16, so one normalized channel can carry RGB555 without
	// losing the flat glass normal that the lightweight optical resolve needs.
	vec3 encoded = floor(clamp(transmission, vec3(0.0), vec3(1.0)) * 31.0 + 0.5);
	return (encoded.r * 1024.0 + encoded.g * 32.0 + encoded.b) * (1.0 / 32767.0);
}

vec3 MaterialUnpackGlassTransmission(const in float packedTransmission) {
	float packedValue = floor(clamp(packedTransmission, 0.0, 1.0) * 32767.0 + 0.5);
	float red = floor(packedValue * (1.0 / 1024.0));
	packedValue -= red * 1024.0;
	float green = floor(packedValue * (1.0 / 32.0));
	float blue = packedValue - green * 32.0;
	return vec3(red, green, blue) * (1.0 / 31.0);
}

vec4 MaterialGlassPacket(const in vec3 transmission, const in vec3 normalView) {
	vec2 encodedNormal = MaterialEncodeWaterNormal(normalView);
	return vec4(
		encodedNormal.x,
		FOXY_MATERIAL_GLASS_SENTINEL,
		encodedNormal.y,
		MaterialPackGlassTransmission(transmission)
	);
}

vec3 MaterialGlassTransmission(const in vec4 packet) {
	return MaterialUnpackGlassTransmission(packet.w);
}

vec3 MaterialGlassNormal(const in vec4 packet) {
	return MaterialDecodeWaterNormal(packet.xz);
}

vec4 MaterialWaterPacket(
	const in vec3 normalView,
	const in float normalAaReduction,
	const in float sunGlintSignal
) {
	vec2 encodedNormal = MaterialEncodeWaterNormal(normalView);
	// colortex2 can be normalized on some backends.  Keep the water payload
	// portable by fitting normal AA and HDR solar surface energy into one byte.
	float aaBucket = floor(clamp(normalAaReduction, 0.0, 1.0) * 3.0 + 0.5);
	float glintEncoded = log2(1.0 + clamp(sunGlintSignal, 0.0, FOXY_MATERIAL_WATER_GLINT_MAX)) / FOXY_MATERIAL_WATER_GLINT_LOG_RANGE;
	float glintBucket = floor(clamp(glintEncoded, 0.0, 1.0) * 63.0 + 0.5);
	float packedAux = (glintBucket * 4.0 + aaBucket) / 255.0;
	return vec4(
		encodedNormal.x,
		FOXY_MATERIAL_WATER_SENTINEL,
		encodedNormal.y,
		packedAux
	);
}

vec3 MaterialWaterNormal(const in vec4 packet) {
	return MaterialDecodeWaterNormal(packet.xz);
}

float MaterialWaterNormalAa(const in vec4 packet) {
	float packedAux = floor(clamp(packet.w, 0.0, 1.0) * 255.0 + 0.5);
	return mod(packedAux, 4.0) / 3.0;
}

float MaterialWaterSunGlintSignal(const in vec4 packet, const in float signalCap) {
	float packedAux = floor(clamp(packet.w, 0.0, 1.0) * 255.0 + 0.5);
	float glintEncoded = floor(packedAux / 4.0) / 63.0;
	return min(exp2(glintEncoded * FOXY_MATERIAL_WATER_GLINT_LOG_RANGE) - 1.0, max(signalCap, 0.0));
}

#endif
