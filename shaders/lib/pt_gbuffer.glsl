#ifndef PT_GBUFFER_GLSL
#define PT_GBUFFER_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/contracts/material.glsl"

vec2 PtSignNotZero(const in vec2 value) {
	return mix(vec2(-1.0), vec2(1.0), step(vec2(0.0), value));
}

vec2 PtEncodeOctNormal(const in vec3 direction) {
	vec3 normal = normalize(direction);
	normal /= max(abs(normal.x) + abs(normal.y) + abs(normal.z), 1.0e-6);
	vec2 encoded = normal.xy;
	if (normal.z < 0.0) {
		encoded = (vec2(1.0) - abs(encoded.yx)) * PtSignNotZero(encoded);
	}
	return encoded * 0.5 + 0.5;
}

vec3 PtDecodeOctNormal(const in vec2 encoded) {
	vec2 folded = encoded * 2.0 - 1.0;
	vec3 normal = vec3(folded, 1.0 - abs(folded.x) - abs(folded.y));
	if (normal.z < 0.0) {
		normal.xy = (vec2(1.0) - abs(normal.yx)) * PtSignNotZero(normal.xy);
	}
	return normalize(normal);
}

float PtPackUnorm2x8(const in vec2 value) {
	vec2 bytes = floor(clamp(value, vec2(0.0), vec2(1.0)) * 255.0 + 0.5);
	return (bytes.x * 256.0 + bytes.y) * (1.0 / 65535.0);
}

vec2 PtUnpackUnorm2x8(const in float encodedValue) {
	float bits = floor(Saturate(encodedValue) * 65535.0 + 0.5);
	float highByte = floor(bits * (1.0 / 256.0));
	float lowByte = bits - highByte * 256.0;
	return vec2(highByte, lowByte) * (1.0 / 255.0);
}

#if FOXY_PT_GBUFFER_ACTIVE == 1 || defined(VOXY)

#define PT_SURFACE_OPAQUE 0.0
#define PT_SURFACE_FOLIAGE 1.0
#define PT_SURFACE_PLANT 2.0
#define PT_SURFACE_ALPHA_TEST 3.0
#define PT_SURFACE_DYNAMIC 4.0
#define PT_SURFACE_EMISSIVE 5.0

#define PT_SURFACE_STRAND PT_SURFACE_PLANT

float PtSurfaceIsEmissive(const in float surfaceClass) {
	return 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_EMISSIVE));
}

float PtPackLightmapGeometry(
	const in vec2 lightmap,
	const in vec3 geometricWorldNormal
) {

	vec2 levels = floor(clamp(lightmap, vec2(0.0), vec2(1.0)) * 15.0 + 0.5);
	vec2 signedOct = PtEncodeOctNormal(geometricWorldNormal) * 2.0 - 1.0;
	vec2 geometryCodes = floor(clamp(signedOct, vec2(-1.0), vec2(1.0)) * 7.0 + 0.5) + 7.0;
	float metadataBits = levels.x + levels.y * 16.0 +
		geometryCodes.x * 256.0 + geometryCodes.y * 4096.0;
	return metadataBits * (1.0 / 65535.0);
}

void PtUnpackLightmapGeometry(
	const in float encodedValue,
	out vec2 lightmap,
	out vec3 geometricWorldNormal
) {
	float metadataBits = floor(Saturate(encodedValue) * 65535.0 + 0.5);
	float geometryY = floor(metadataBits * (1.0 / 4096.0));
	metadataBits -= geometryY * 4096.0;
	float geometryX = floor(metadataBits * (1.0 / 256.0));
	metadataBits -= geometryX * 256.0;
	float skyLevel = floor(metadataBits * (1.0 / 16.0));
	float blockLevel = metadataBits - skyLevel * 16.0;
	lightmap = vec2(blockLevel, skyLevel) * (1.0 / 15.0);
	vec2 signedOct = (vec2(geometryX, geometryY) - 7.0) * (1.0 / 7.0);
	geometricWorldNormal = PtDecodeOctNormal(signedOct * 0.5 + 0.5);
}

#if defined(PT_GBUFFER_WRITE)
vec4 PtEncodeGbuffer(
	const in vec3 albedo,
	const in vec3 worldNormal,
	const in vec3 geometricWorldNormal,
	const in vec2 lightmap,
	const in float surfaceClass,
	const in float roughness,
	const in float metalness
) {
	vec3 albedoSrgb = LinearToSrgb(Saturate3(albedo));

	float surfaceBits = clamp(floor(surfaceClass + 0.5), 0.0, 7.0);
	float perceptualRoughness = sqrt(Saturate(roughness));
	float roughnessBits = floor(perceptualRoughness * 15.0 + 0.5);
	float metalBit = step(0.5, metalness);
	float encodedSurfaceClass = (surfaceBits + roughnessBits * 8.0 + metalBit * 128.0) * (1.0 / 255.0);
	return vec4(
		PtPackUnorm2x8(albedoSrgb.rg),

		PtPackUnorm2x8(vec2(min(albedoSrgb.b, 253.0 / 255.0), encodedSurfaceClass)),
		PtPackUnorm2x8(PtEncodeOctNormal(worldNormal)),
		PtPackLightmapGeometry(lightmap, geometricWorldNormal)
	);
}

#endif

#if defined(PT_GBUFFER_READ)
struct PtGbufferSample {
	vec3 albedo;
	vec3 emission;
	vec3 worldNormal;
	vec3 worldGeometricNormal;
	vec2 lightmap;
	float reactive;
	float surfaceClass;
	float roughness;
	float metalness;
	float valid;
};

vec3 PtDecodeGbufferAlbedo(const in vec4 surfaceData) {
	vec2 albedoRg = PtUnpackUnorm2x8(surfaceData.x);
	vec2 albedoBFlags = PtUnpackUnorm2x8(surfaceData.y);
	return SrgbToLinear(vec3(albedoRg, albedoBFlags.x));
}

PtGbufferSample PtDecodeGbuffer(const in vec4 surfaceData, const in float depthRaw) {
	PtGbufferSample gbufferData;
	float water = MaterialIsWater(surfaceData);
	float glass = MaterialIsGlass(surfaceData);
	float transparentSurface = max(water, glass);
	vec2 albedoRg = PtUnpackUnorm2x8(surfaceData.x);
	vec2 albedoBFlags = PtUnpackUnorm2x8(surfaceData.y);
	vec3 colorPayload = SrgbToLinear(vec3(albedoRg, albedoBFlags.x));
	float materialBits = floor(albedoBFlags.y * 255.0 + 0.5);
	gbufferData.metalness = step(128.0, materialBits) * (1.0 - transparentSurface);
	materialBits -= gbufferData.metalness * 128.0;
	float roughnessBits = floor(materialBits * (1.0 / 8.0));
	gbufferData.surfaceClass = (materialBits - roughnessBits * 8.0) * (1.0 - transparentSurface);
	float emissiveSurface = PtSurfaceIsEmissive(gbufferData.surfaceClass);

	gbufferData.albedo = colorPayload * (1.0 - emissiveSurface);
	gbufferData.emission = colorPayload * emissiveSurface;
	float perceptualRoughness = roughnessBits * (1.0 / 15.0);
	gbufferData.roughness = perceptualRoughness * perceptualRoughness;
	gbufferData.worldNormal = PtDecodeOctNormal(PtUnpackUnorm2x8(surfaceData.z));
	PtUnpackLightmapGeometry(
		surfaceData.a,
		gbufferData.lightmap,
		gbufferData.worldGeometricNormal
	);

	float foliageReactive = 1.0 - step(0.5, abs(gbufferData.surfaceClass - PT_SURFACE_FOLIAGE));
	float plantReactive = 1.0 - step(0.5, abs(gbufferData.surfaceClass - PT_SURFACE_PLANT));
	float dynamicReactive = 1.0 - step(0.5, abs(gbufferData.surfaceClass - PT_SURFACE_DYNAMIC));

	gbufferData.reactive = max(emissiveSurface, max(foliageReactive, max(plantReactive, dynamicReactive))) *
		(1.0 - transparentSurface);
	gbufferData.valid = (1.0 - step(0.99999, depthRaw)) * (1.0 - transparentSurface);
	return gbufferData;
}

#endif

#endif

#endif
