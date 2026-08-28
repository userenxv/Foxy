#ifndef FOXY_EMISSIVE_GLSL
#define FOXY_EMISSIVE_GLSL

// Shared GI light-source contract. Keep this file valid for both the terrain
// terrain vertex/fragment programs and the 4.30 voxel compute programs.
// It intentionally does not define visible material emission: that is authored
// per texel by LabPBR and decoded in surface_pbr.glsl.
#define FOXY_EMISSIVE_NONE 0.0
#define FOXY_EMISSIVE_SPHERE 1.0
#define FOXY_EMISSIVE_SURFACE 2.0

const vec3 FOXY_EMISSION_TORCH = vec3(1.00, 0.30, 0.055);
const vec3 FOXY_EMISSION_SOUL = vec3(0.12, 0.55, 1.00);
const vec3 FOXY_EMISSION_GLOWSTONE = vec3(1.00, 0.52, 0.12);
const vec3 FOXY_EMISSION_SEA_LANTERN = vec3(0.38, 0.72, 1.00);
const vec3 FOXY_EMISSION_REDSTONE = vec3(1.00, 0.055, 0.018);
const vec3 FOXY_EMISSION_MAGMA = vec3(0.92, 0.25, 0.10);
const vec3 FOXY_EMISSION_END_ROD = vec3(0.55, 0.78, 1.00);
const vec3 FOXY_EMISSION_RED_TORCH = vec3(1.00, 0.035, 0.010);
const vec3 FOXY_EMISSION_GLOW_BERRY = vec3(0.72, 1.00, 0.30);
const vec3 FOXY_EMISSION_PEARLESCENT = vec3(0.92, 0.38, 1.00);
const vec3 FOXY_EMISSION_VERDANT = vec3(0.28, 1.00, 0.52);
const vec3 FOXY_EMISSION_AMETHYST = vec3(0.46, 0.22, 1.00);
const vec3 FOXY_EMISSION_EYEBLOSSOM = vec3(0.12, 0.72, 1.00);
const vec3 FOXY_EMISSION_RESPAWN = vec3(0.56, 0.10, 1.00);
const vec3 FOXY_EMISSION_TRIAL = vec3(0.18, 0.62, 1.00);
const vec3 FOXY_EMISSION_CRYING = vec3(0.58, 0.10, 1.00);
const vec3 FOXY_EMISSION_PORTAL = vec3(0.42, 0.035, 1.00);
const vec3 FOXY_EMISSION_CAMPFIRE = vec3(1.00, 0.14, 0.010);
const vec3 FOXY_EMISSION_SOUL_CAMPFIRE = vec3(0.020, 0.46, 1.00);
const vec3 FOXY_EMISSION_COPPER = vec3(0.025, 1.00, 0.10);
const vec3 FOXY_EMISSION_LAVA = vec3(1.00, 0.40, 0.05);

bool EmissionLavaMaterial(const in float materialId) {
	return materialId == 10183.0 || materialId == 10197.0 ||
		materialId == 10198.0;
}

float EmissionPrimitive(const in float materialId) {
	if (materialId < 10170.0 || materialId > 10232.0) return FOXY_EMISSIVE_NONE;
	if (materialId == 10170.0 || materialId == 10171.0 ||
		materialId == 10178.0 || materialId == 10179.0 ||
		materialId == 10180.0 ||
		(materialId >= 10184.0 && materialId <= 10188.0) ||
		(materialId >= 10192.0 && materialId <= 10195.0) ||
		materialId == 10197.0 || materialId == 10232.0) {
		return FOXY_EMISSIVE_SPHERE;
	}
	if (materialId == 10172.0 || materialId == 10173.0 ||
		materialId == 10174.0 || materialId == 10175.0 ||
		materialId == 10177.0 || materialId == 10181.0 ||
		materialId == 10182.0 || materialId == 10183.0 || materialId == 10198.0 ||
		(materialId >= 10189.0 && materialId <= 10191.0) ||
		materialId == 10196.0) {
		return FOXY_EMISSIVE_SURFACE;
	}
	return FOXY_EMISSIVE_NONE;
}

vec3 EmissionSpectrum(const in float materialId) {
	if (materialId == 10170.0) return FOXY_EMISSION_TORCH;
	if (materialId == 10171.0) return FOXY_EMISSION_SOUL;
	if (materialId == 10172.0) return FOXY_EMISSION_GLOWSTONE;
	if (materialId == 10173.0) return FOXY_EMISSION_SEA_LANTERN;
	if (materialId == 10174.0) return FOXY_EMISSION_REDSTONE;
	if (materialId == 10175.0) return FOXY_EMISSION_MAGMA;
	if (materialId == 10177.0) return vec3(1.00, 0.34, 0.065);
	if (materialId == 10178.0) return FOXY_EMISSION_END_ROD;
	if (materialId == 10179.0) return FOXY_EMISSION_RED_TORCH;
	if (materialId == 10180.0) return FOXY_EMISSION_GLOW_BERRY;
	if (materialId == 10181.0) return FOXY_EMISSION_PEARLESCENT;
	if (materialId == 10182.0) return FOXY_EMISSION_VERDANT;
	if (EmissionLavaMaterial(materialId)) return FOXY_EMISSION_LAVA;
	if (materialId == 10184.0 || materialId == 10185.0) return vec3(1.00, 0.20, 0.020);
	if (materialId == 10186.0) return vec3(0.32, 1.00, 0.10);
	if (materialId == 10187.0) return FOXY_EMISSION_AMETHYST;
	if (materialId == 10188.0) return FOXY_EMISSION_EYEBLOSSOM;
	if (materialId == 10189.0) return FOXY_EMISSION_RESPAWN;
	if (materialId == 10190.0) return vec3(0.18, 0.62, 1.00);
	if (materialId == 10191.0) return FOXY_EMISSION_CRYING;
	if (materialId == 10192.0) return FOXY_EMISSION_PORTAL;
	if (materialId == 10193.0) return FOXY_EMISSION_CAMPFIRE;
	if (materialId == 10194.0) return FOXY_EMISSION_SOUL_CAMPFIRE;
	if (materialId == 10195.0 || materialId == 10196.0 || materialId == 10232.0) return FOXY_EMISSION_COPPER;
	return vec3(0.82);
}

float EmissionRadiance(const in float materialId) {
	if (materialId == 10170.0) return 0.64;
	if (materialId == 10171.0) return 0.56;
	if (materialId == 10172.0) return 0.78;
	if (materialId == 10173.0) return 0.68;
	if (materialId == 10174.0) return 0.52;
	if (materialId == 10175.0) return 0.52;
	if (materialId == 10177.0) return 0.58;
	if (materialId == 10178.0) return 0.58;
	if (materialId == 10179.0) return 0.50;
	if (materialId == 10180.0) return 0.44;
	if (materialId == 10181.0 || materialId == 10182.0) return 0.72;
	if (materialId == 10183.0 || materialId == 10198.0) return 0.76;
	if (materialId == 10197.0) return 0.62;
	if (materialId == 10184.0 || materialId == 10185.0) return 0.38;
	if (materialId == 10186.0) return 0.40;
	if (materialId == 10187.0) return 0.24;
	if (materialId == 10188.0) return 0.30;
	if (materialId == 10189.0) return 0.48;
	if (materialId == 10190.0) return 0.34;
	if (materialId == 10191.0) return 0.30;
	if (materialId == 10192.0) return 0.52;
	if (materialId == 10193.0) return 0.62;
	if (materialId == 10194.0) return 0.56;
	if (materialId == 10195.0 || materialId == 10196.0 || materialId == 10232.0) return 0.56;
	return 0.0;
}

float EmissionFallbackLevel(const in float materialId) {
	if (materialId == 10170.0) return 14.0;
	if (materialId == 10171.0) return 10.0;
	if (materialId >= 10172.0 && materialId <= 10174.0) return 15.0;
	if (materialId == 10175.0) return 3.0;
	if (materialId == 10177.0) return 13.0;
	if (materialId == 10178.0) return 14.0;
	if (materialId == 10179.0 || materialId == 10180.0) return 7.0;
	if (materialId == 10181.0 || materialId == 10182.0) return 15.0;
	if (EmissionLavaMaterial(materialId)) return 15.0;
	if (materialId == 10184.0 || materialId == 10185.0) return 3.0;
	if (materialId == 10186.0) return 6.0;
	if (materialId == 10187.0) return 1.0;
	if (materialId == 10188.0 || materialId == 10189.0) return 3.0;
	if (materialId == 10190.0) return 6.0;
	if (materialId == 10191.0) return 10.0;
	if (materialId == 10192.0) return 11.0;
	if (materialId == 10193.0) return 15.0;
	if (materialId == 10194.0) return 10.0;
	if (materialId == 10195.0) return 12.0;
	if (materialId == 10196.0) return 4.0;
	if (materialId == 10232.0) return 14.0;
	return 0.0;
}

#endif
