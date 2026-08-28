#ifndef FOXY_CLOUD_COVERAGE_GLSL
#define FOXY_CLOUD_COVERAGE_GLSL

#include "/lib/settings.glsl"

#ifndef CLOUD_WEATHER_REGION_SCALE
#define CLOUD_WEATHER_REGION_SCALE 0.5
#endif

const vec3 CLOUD_WORLD_SCALE_ANCHOR = vec3(0.0, 70.0, 0.0);

uniform vec2 cloudDailyOffset;

float CloudWorldScale() {
	#if FOXY_CLOUD_BLOCK_SHAPE == 1
	return 1.0;
	#else
	return max(FOXY_CLOUD_WORLD_SCALE, 0.01);
	#endif
}

float CloudCoverageDetailRange() {
	return FOXY_CLOUD_RANGE * clamp(FOXY_CLOUD_RENDER_RANGE_SCALE, 1.0, 100.0);
}

float CloudCoverageVisibilityRange() {
	// Visibility follows the atmospheric horizon; the GUI range only controls
	// where full shape detail stops. 160 km in physical world space is beyond
	// the natural cloud-shell intersection for normal camera altitudes.
	return max(CloudCoverageDetailRange(), 160000.0 / CloudWorldScale());
}

vec3 CloudWorldToReference(const in vec3 worldPos) {
	return CLOUD_WORLD_SCALE_ANCHOR + (worldPos - CLOUD_WORLD_SCALE_ANCHOR) / CloudWorldScale();
}

float CloudReferenceDistanceToWorld(const in float referenceDistance) {
	return referenceDistance * CloudWorldScale();
}

float CloudWorldDistanceToReference(const in float worldDistance) {
	return worldDistance / CloudWorldScale();
}

vec3 CloudCoverageWindDir() {
	return normalize(vec3(0.78, 0.0, 0.62));
}

float CloudCoverageSizeScale() {
	return max(FOXY_CLOUD_CLOUD_SIZE, 0.01);
}

vec3 CloudCoverageUnscaleWorld(const in vec3 worldPos) {
	float size = CloudCoverageSizeScale();
	vec3 pivot = vec3(0.0, FOXY_CLOUD_HEIGHT + FOXY_CLOUD_THICKNESS * 0.5, 0.0);
	return pivot + (worldPos - pivot) / size;
}

float CloudCoverageHalfExtent() {
	float configuredRange = CloudCoverageDetailRange();
	float densityRange = configuredRange / CloudCoverageSizeScale();
	return min(densityRange * 1.08 + FOXY_CLOUD_THICKNESS * max(FOXY_CLOUD_VERTICAL_SHEAR, 0.0), 180000.0);
}

vec2 CloudCoverageCenter(const in vec3 densityCameraPos, const in float time) {
	vec2 wind = CloudCoverageWindDir().xz;
	return densityCameraPos.xz + wind * (time * FOXY_CLOUD_SPEED * 22.0);
}

vec2 CloudCoverageCacheUv(
	const in vec2 advectedPosition,
	const in vec3 densityCameraPos,
	const in float time
) {
	float halfExtent = max(CloudCoverageHalfExtent(), 1.0);
	return (advectedPosition - CloudCoverageCenter(densityCameraPos, time)) / (2.0 * halfExtent) + vec2(0.5);
}

vec2 CloudCoverageCachePosition(
	const in vec2 uv,
	const in vec3 densityCameraPos,
	const in float time
) {
	return CloudCoverageCenter(densityCameraPos, time) + (uv * 2.0 - 1.0) * CloudCoverageHalfExtent();
}

vec2 CloudCoverageWeatherUv(const in vec2 advectedPosition, const in float time) {
	vec2 wind = CloudCoverageWindDir().xz;
	vec2 dailyPosition = advectedPosition + cloudDailyOffset;
	return fract(dailyPosition * 0.000060 + vec2(0.5) + wind * time * FOXY_CLOUD_SPEED * 0.001);
}

vec2 CloudCoverageBroadUv(const in vec2 advectedPosition, const in float time) {
	vec2 wind = CloudCoverageWindDir().xz;
	vec2 dailyPosition = advectedPosition + cloudDailyOffset;
	float inverseScale = 1.0 / max(CLOUD_WEATHER_REGION_SCALE, 0.10);
	return fract((dailyPosition * 0.000010 + wind * time * FOXY_CLOUD_SPEED * 0.00019) * inverseScale + vec2(0.18, 0.71));
}

#endif
