#ifndef FOXY_SKY_LUT_CONTRACT_GLSL
#define FOXY_SKY_LUT_CONTRACT_GLSL

float SkyLutActiveWidth() {
	return max(FOXY_SKY_LUT_WIDTH - 1.0, 2.0);
}

vec2 SkyLutPhysicalUv(const in vec2 logicalUv) {
	float activeWidth = SkyLutActiveWidth();
	float physicalX = (0.5 + clamp(logicalUv.x, 0.0, 1.0) * (activeWidth - 1.0)) / FOXY_SKY_LUT_WIDTH;
	return vec2(physicalX, clamp(logicalUv.y, 0.0015, 0.9985));
}

vec2 SkyLutLogicalUv(const in vec2 physicalUv) {
	float activeWidth = SkyLutActiveWidth();
	float logicalX = (physicalUv.x * FOXY_SKY_LUT_WIDTH - 0.5) / max(activeWidth - 1.0, 1.0);
	return vec2(clamp(logicalX, 0.0, 1.0), clamp(physicalUv.y, 0.0015, 0.9985));
}

vec2 SkyLightingCacheUv(const in float row) {
	return vec2(
		(FOXY_SKY_LUT_WIDTH - 0.5) / FOXY_SKY_LUT_WIDTH,
		(clamp(row, 0.0, FOXY_SKY_LUT_HEIGHT - 1.0) + 0.5) / FOXY_SKY_LUT_HEIGHT
	);
}

vec2 SkyUpperHemisphereFluenceUv() {
	return SkyLightingCacheUv(0.0);
}

vec2 SkyDirectSunColorUv() {
	return SkyLightingCacheUv(1.0);
}

ivec2 SkyUpperHemisphereFluenceTexel() {
	return ivec2(int(FOXY_SKY_LUT_WIDTH) - 1, 0);
}

ivec2 SkyDirectSunColorTexel() {
	return ivec2(int(FOXY_SKY_LUT_WIDTH) - 1, 1);
}

float SkyLutCacheColumn(const in vec2 fragmentCoord) {
	return step(SkyLutActiveWidth(), floor(fragmentCoord.x));
}

#endif
