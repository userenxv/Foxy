#ifndef FOXY_BLACKHOLE_SKY_GLSL
#define FOXY_BLACKHOLE_SKY_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/sky.glsl"
#include "/lib/lighting.glsl"


const float BH_SKY_BODY_COS = 0.669;   // cos(48 deg)

#if !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END) && (FOXY_BLACKHOLE_SUN == 1 || FOXY_BLACKHOLE_MOON == 1)

#include "/lib/blackhole.glsl"

BhBodyView BhSunBodyView() {
	return BhBodyView(FOXY_BLACKHOLE_SUN_DIST, FOXY_BLACKHOLE_SUN_PITCH,
		FOXY_BLACKHOLE_SUN_YAW, FOXY_BLACKHOLE_SUN_TILT,
		FOXY_BLACKHOLE_SUN_TEMP, FOXY_BLACKHOLE_SUN_BRIGHTNESS);
}

BhBodyView BhMoonBodyView() {
	return BhBodyView(FOXY_BLACKHOLE_MOON_DIST, FOXY_BLACKHOLE_MOON_PITCH,
		FOXY_BLACKHOLE_MOON_YAW, FOXY_BLACKHOLE_MOON_TILT,
		FOXY_BLACKHOLE_MOON_TEMP, FOXY_BLACKHOLE_MOON_BRIGHTNESS);
}

vec3 BhBodyApparentDirection(const in vec3 bodyViewVec) {
	vec3 bodyDirection = normalize(bodyViewVec);
	return SkyRefractedSunDirection(bodyDirection, vec3(0.0, 1.0, 0.0), bodyDirection.y);
}

float BhBodyUpFactor(const in vec3 bodyDirection) {
	return smoothstep(-0.03, 0.03, bodyDirection.y);
}

float BhRayHorizonFactor(const in vec3 worldDir) {
	return CelestialRayHorizonVisibility(clamp(worldDir.y, -1.0, 1.0));
}

vec3 BhRayAirTransmittance(const in vec3 worldDir) {
	return SkySolarTransmittance(clamp(worldDir.y, -1.0, 1.0), rainStrength);
}

vec3 BlackHoleReflectionOneBody(
	const in vec3 worldDir,
	const in vec3 bodyViewVec,
	const in BhBodyView view
) {
	if (length(bodyViewVec) <= 1.0e-5) return vec3(0.0);
	vec3 bodyDirection = BhBodyApparentDirection(bodyViewVec);
	if (dot(worldDir, bodyDirection) < BH_SKY_BODY_COS) return vec3(0.0);

	vec3 lensedDirection;
	vec4 hole = BlackHoleBodyOverlay(
		worldDir, frameTimeCounter, bodyDirection, view, lensedDirection
	);
	return BhRayAirTransmittance(worldDir) * max(hole.rgb, vec3(0.0))
		* FOXY_BLACKHOLE_REFLECTION_BRIGHTNESS
		* BhBodyUpFactor(bodyDirection) * BhRayHorizonFactor(worldDir);
}

vec3 BlackHoleReflectionRadiance(const in vec3 worldDir) {
	vec3 body = vec3(0.0);
	#if FOXY_BLACKHOLE_SUN == 1
		body += BlackHoleReflectionOneBody(
			worldDir, mat3(gbufferModelViewInverse) * sunPosition, BhSunBodyView()
		);
	#endif
	#if FOXY_BLACKHOLE_MOON == 1
		body += BlackHoleReflectionOneBody(
			worldDir, mat3(gbufferModelViewInverse) * moonPosition, BhMoonBodyView()
		);
	#endif
	return body;
}

#else

vec3 BlackHoleReflectionRadiance(const in vec3 worldDir) {
	return vec3(0.0);
}

#endif

#endif
