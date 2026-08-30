#ifndef FOXY_WIND_GLSL
#define FOXY_WIND_GLSL

#include "/lib/math.glsl"

float WindIdInRange(const in float id, const in float firstId, const in float lastId) {
	return step(firstId - 0.5, id) * step(id, lastId + 0.5);
}

vec3 WindDisplacement(
	const in vec3 worldPos,
	const in float materialId,
	const in float topVertex,
	const in float skyLight,
	const in float time,
	const in float rain
) {
	float leaves = WindIdInRange(materialId, 10100.0, 10100.0);
	float shortPlant = WindIdInRange(materialId, 10101.0, 10102.0);
	float tallTop = WindIdInRange(materialId, 10103.0, 10103.0);
	if (max(leaves, max(shortPlant, tallTop)) < 0.5) {
		return vec3(0.0);
	}

	float weather = Saturate(rain);
	float exposure = Saturate(skyLight);
	exposure *= exposure;

float calmTime = time * 1.40;
	float stormTime = time * 4.20;
	vec2 windDir = normalize(vec2(0.86, 0.51));
	float broad = sin(dot(worldPos.xz, vec2(0.075, 0.052)) + calmTime);
	broad += sin(dot(worldPos.xz, vec2(-0.031, 0.091)) + calmTime * 0.63 + 1.8) * 0.48;
	float stormGust = sin(dot(worldPos.xz, vec2(0.121, -0.064)) + stormTime + 0.7);
	stormGust += sin(dot(worldPos.xz, vec2(-0.057, 0.138)) - stormTime * 0.72) * 0.40;
	broad += stormGust * weather * 0.44;
	float fine = sin(worldPos.x * 2.7 + worldPos.y * 1.9 + calmTime * 2.15);
	fine += sin(worldPos.z * 3.4 - worldPos.y * 1.3 - calmTime * 1.72) * 0.42;
	fine += sin(worldPos.x * 4.1 - worldPos.z * 3.3 + stormTime * 1.54) * weather * 0.32;

	float weatherAmplitude = mix(0.56, 1.45, weather);
	float plantAnchor = topVertex;
	float upperAnchor = mix(0.64, 1.12, topVertex);
	float vertexWeight = leaves + shortPlant * plantAnchor + tallTop * upperAnchor;
	float amplitude = exposure * weatherAmplitude * (
		leaves * 0.032 + shortPlant * 0.075 + tallTop * 0.084
	);
	vec2 horizontal = windDir * (broad * 0.72 + fine * 0.16);
	horizontal += vec2(-windDir.y, windDir.x) * fine * 0.10;
	float lift = (broad * 0.10 + fine * 0.045) * (leaves + max(shortPlant, tallTop) * topVertex);
	return vec3(horizontal.x, lift, horizontal.y) * amplitude * vertexWeight;
}

#endif
