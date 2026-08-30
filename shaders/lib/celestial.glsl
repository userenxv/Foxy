#ifndef FOXY_CELESTIAL_GLSL
#define FOXY_CELESTIAL_GLSL

vec3 TiltCelestialWorld(const in vec3 worldDir) {
	return normalize(worldDir);
}

vec3 ViewToWorldDir(const in mat4 gbufferModelViewInverse, const in vec3 viewDir) {
	return normalize(mat3(gbufferModelViewInverse) * viewDir);
}

vec3 WorldToViewDir(const in mat4 gbufferModelView, const in vec3 worldDir) {
	return normalize(mat3(gbufferModelView) * worldDir);
}

void StableSunMoonViewDirsFromUnitUp(
	const in vec3 sunPosition,
	const in vec3 moonPosition,
	const in vec3 upDir,
	out vec3 stableSun,
	out vec3 stableMoon
) {

	stableSun = normalize(sunPosition);
	stableMoon = normalize(moonPosition);
}

void StableSunMoonViewDirs(
	const in vec3 sunPosition,
	const in vec3 moonPosition,
	const in vec3 upPosition,
	out vec3 stableSun,
	out vec3 stableMoon
) {
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, normalize(upPosition), stableSun, stableMoon);
}

vec3 StableSunViewDir(const in vec3 sunPosition, const in vec3 moonPosition, const in vec3 upPosition) {
	return normalize(sunPosition);
}

vec3 StableMoonViewDirFromStableSun(const in vec3 moonPosition, const in vec3 upPosition, const in vec3 stableSun) {
	return normalize(moonPosition);
}

vec3 StableMoonViewDir(const in vec3 sunPosition, const in vec3 moonPosition, const in vec3 upPosition) {
	return normalize(moonPosition);
}

vec2 CelestialShadowSourceWeights(
	const in vec3 shadowLightDir,
	const in vec3 sunDir,
	const in vec3 moonDir
) {
	float sunMatch = smoothstep(0.90, 0.995, dot(normalize(shadowLightDir), normalize(sunDir)));
	float moonMatch = smoothstep(0.90, 0.995, dot(normalize(shadowLightDir), normalize(moonDir)));
	float useSun = step(moonMatch, sunMatch);
	float confidence = max(sunMatch, moonMatch);
	return vec2(useSun, 1.0 - useSun) * confidence;
}

#endif
