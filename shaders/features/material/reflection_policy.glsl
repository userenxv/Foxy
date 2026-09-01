#ifndef FOXY_MATERIAL_REFLECTION_POLICY_GLSL
#define FOXY_MATERIAL_REFLECTION_POLICY_GLSL

#include "/lib/surface_pbr.glsl"

#define FOXY_REFLECTION_TYPE_SMOOTH 1.0
#define FOXY_REFLECTION_TYPE_ROUGH 2.0

float MaterialReflectionSmoothness(const in float perceptualRoughness) {
	return 1.0 - smoothstep(
		FOXY_MATERIAL_REFLECTION_ROUGHNESS_CUTOFF * 0.72,
		FOXY_MATERIAL_REFLECTION_ROUGHNESS_CUTOFF,
		perceptualRoughness
	);
}

float MaterialReflectionType(
	const in float perceptualRoughness
) {
	return mix(
		FOXY_REFLECTION_TYPE_SMOOTH,
		FOXY_REFLECTION_TYPE_ROUGH,
		step(FOXY_MATERIAL_REFLECTION_SMOOTH_ROUGHNESS, perceptualRoughness)
	);
}

vec3 MaterialReflectionAboveSurface(
	const in vec3 direction,
	const in vec3 geometricNormal
) {
	vec3 surfaceNormal = normalize(geometricNormal);
	float geometricSide = dot(direction, surfaceNormal);
	return normalize(direction - 2.0 * min(geometricSide, 0.0) * surfaceNormal);
}

float MaterialReflectionSurfaceEnabled(
	const in float valid,
	const in float surfaceClass,
	const in float perceptualRoughness,
	const in float metalness
) {
	float smoothness = MaterialReflectionSmoothness(perceptualRoughness);
	float vegetation = step(0.5, surfaceClass) * (1.0 - step(3.5, surfaceClass));

	float emissive = step(4.5, surfaceClass);
	float roughness = perceptualRoughness * perceptualRoughness;
	float dielectricF0 = max(FOXY_PBR_FALLBACK_F0, 0.02);
	float dielectricEnergy = dielectricF0 * max(
		1.0 - roughness * FOXY_MATERIAL_REFLECTION_ENERGY_ROUGHNESS_ATTENUATION,
		0.0
	);
	float dielectricEligible = step(FOXY_MATERIAL_REFLECTION_ENERGY_THRESHOLD, dielectricEnergy);
	float reflectiveMaterial = max(
		Saturate(metalness),
		dielectricEligible * step(FOXY_MATERIAL_REFLECTION_MIN_SMOOTHNESS, smoothness)
	);
	return valid * (1.0 - vegetation) * (1.0 - emissive) * step(0.002, smoothness) * reflectiveMaterial;
}

float MaterialReflectionGlobalEnabled(
	const in float smoothness,
	const in float f0Energy,
	const in float NoV
) {
	float grazingFresnel = pow(1.0 - Saturate(NoV), 5.0);
	float visibleEnergy = smoothness * max(f0Energy, grazingFresnel);
	return step(FOXY_MATERIAL_REFLECTION_GLOBAL_MIN_ENERGY, visibleEnergy);
}

#endif
