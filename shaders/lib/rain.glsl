#ifndef FOXY_RAIN_GLSL
#define FOXY_RAIN_GLSL

#include "/lib/math.glsl"

float RainHash12(const in vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

vec2 RainRingSlopeSingle(
	const in vec2 worldXZ,
	const in float time,
	const in float cellSize,
	const in float phaseOffset
) {
	vec2 grid = worldXZ / cellSize + vec2(phaseOffset, phaseOffset * 0.37);
	vec2 cell = floor(grid);
	vec2 local = fract(grid);
	float seed = RainHash12(cell + phaseOffset * 19.0);
	vec2 center = vec2(
		RainHash12(cell + vec2(7.1, 2.3)),
		RainHash12(cell + vec2(3.7, 9.2))
	) * 0.66 + 0.17;
	vec2 delta = local - center;
	float radius = length(delta);
	float age = fract(time * (0.70 + seed * 0.38) + seed + phaseOffset);
	float ringRadius = age * 0.82;
	float ringDistance = radius - ringRadius;
	float envelope = exp(-abs(ringDistance) * 30.0);
	float wave = cos(ringDistance * 54.0) * envelope;
	float life = (1.0 - age) * (1.0 - age) * smoothstep(0.0, 0.08, age);
	return delta / max(radius, 0.035) * wave * life;
}

vec2 RainRippleSlope(const in vec2 worldXZ, const in float time) {
	vec2 closeRings = RainRingSlopeSingle(worldXZ, time, 1.20, 0.0);
	vec2 broadRings = RainRingSlopeSingle(worldXZ, time * 0.83, 1.72, 0.41);
	return closeRings + broadRings * 0.62;
}

vec3 RainPerturbWorldNormal(
	const in vec3 worldNormal,
	const in vec2 worldXZ,
	const in float time,
	const in float amount
) {
	vec2 slope = RainRippleSlope(worldXZ, time);
	vec3 perturbed = worldNormal + vec3(-slope.x, 0.0, -slope.y) * (0.15 * amount);
	return normalize(perturbed);
}

float RainPuddleMask(
	const in vec3 worldPos,
	const in vec3 geometricWorldNormal,
	const in float skyLight,
	const in float rain,
	const in float materialId,
	const in float broadNoise
) {
	float foliage = step(10099.5, materialId) * step(materialId, 10103.5);
	float upward = smoothstep(0.80, 0.985, geometricWorldNormal.y);
	float outdoors = smoothstep(0.86, 0.985, Saturate(skyLight));
	float pockets = smoothstep(0.40, 0.69, broadNoise);
	float rainfall = smoothstep(0.015, 0.70, Saturate(rain));
	return pockets * upward * outdoors * rainfall * (1.0 - foliage);
}

#endif
