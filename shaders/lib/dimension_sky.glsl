#ifndef FOXY_DIMENSION_SKY_GLSL
#define FOXY_DIMENSION_SKY_GLSL

#include "/lib/math.glsl"

float DimensionHash13(const in vec3 p) {
	vec3 q = fract(p * 0.1031);
	q += dot(q, q.yzx + 33.33);
	return fract((q.x + q.y) * q.z);
}

vec3 NetherEnvironment(const in vec3 worldDir) {
	float horizon = pow(max(1.0 - abs(worldDir.y), 0.0), 3.0);
	float emberBand = 0.5 + 0.5 * sin(worldDir.x * 9.0 + worldDir.z * 7.0);
	return vec3(0.0060, 0.0010, 0.00045) +
		vec3(0.0140, 0.0022, 0.00065) * horizon * (0.62 + emberBand * 0.38);
}

vec3 EndSunWorldDirection() {

	return vec3(0.35355339, 0.86602540, 0.35355339);
}

vec3 EndEnvironment(const in vec3 direction, const in float time) {
	vec3 worldDir = normalize(direction);
	float upper = smoothstep(-0.35, 0.85, worldDir.y);
	vec3 sky = mix(vec3(0.010, 0.006, 0.024), vec3(0.014, 0.033, 0.073), upper);
	float horizon = pow(max(1.0 - abs(worldDir.y), 0.0), 4.0);
	sky += vec3(0.022, 0.055, 0.090) * horizon;
	float sunAlignment = dot(worldDir, EndSunWorldDirection());
	float zenithHalo = smoothstep(0.975, 0.9996, sunAlignment);
	float zenithDisc = smoothstep(0.99915, 0.99972, sunAlignment);
	sky += vec3(0.060, 0.090, 0.150) * zenithHalo * 0.34;
	sky += vec3(0.62, 0.72, 1.00) * zenithDisc;

	vec3 starCell = floor(worldDir * 430.0);
	float starSeed = DimensionHash13(starCell);
	float star = smoothstep(0.9965, 1.0, starSeed);
	float twinkle = 0.72 + 0.28 * sin(time * (0.7 + starSeed) + starSeed * 47.0);
	vec3 starTint = mix(vec3(0.34, 0.58, 1.0), vec3(1.0, 0.45, 0.78), DimensionHash13(starCell + 11.0));
	sky += starTint * star * twinkle * 0.55;

	return max(sky, vec3(0.0));
}

vec3 NetherEnvironmentFluence() {
	return vec3(0.0120, 0.0018, 0.00065);
}

vec3 EndEnvironmentFluence() {
	return vec3(0.024, 0.020, 0.050);
}

vec3 NetherDirectEnvironment() {
	return vec3(0.0260, 0.0040, 0.0012);
}

vec3 EndDirectEnvironment() {
	return vec3(0.042, 0.026, 0.068);
}

#endif
