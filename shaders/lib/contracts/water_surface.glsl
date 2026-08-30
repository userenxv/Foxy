#ifndef FOXY_CONTRACT_WATER_SURFACE_GLSL
#define FOXY_CONTRACT_WATER_SURFACE_GLSL

vec4 WaterSurfacePack(
	const in vec3 encodedColor,
	const in float alpha
) {
	return vec4(max(encodedColor, vec3(0.0)), clamp(alpha, 0.0, 1.0));
}

vec3 WaterSurfaceEncodedColor(const in vec4 packet) {
	return max(packet.rgb, vec3(0.0));
}

float WaterSurfaceAlpha(const in vec4 packet) {
	return clamp(packet.a, 0.0, 1.0);
}

#endif
