#ifndef FOXY_FOLIAGE_GLSL
#define FOXY_FOLIAGE_GLSL

float FoliageMaterialMatch(const in float materialId, const in float expectedId) {
	return 1.0 - step(0.5, abs(materialId - expectedId));
}

bool FoliageIsLeaf(const in float materialId) {
	return abs(materialId - 10100.0) < 0.5 || abs(materialId - 12000.0) < 0.5;
}

#if FOXY_PBR_SSS_ALPHA_NEIGHBORS == 1
vec2 FoliageSpriteSampleUv(const in vec2 uv, const in vec2 atlasTexel) {
	vec2 spriteHalf = max(spriteHalfSize, atlasTexel);
	vec2 spriteCenter = texcoord - (spriteUv - vec2(0.5)) * (2.0 * spriteHalfSize);
	vec2 lower = spriteCenter - spriteHalf + atlasTexel * 0.5;
	vec2 upper = spriteCenter + spriteHalf - atlasTexel * 0.5;
	return clamp(uv, min(lower, upper), max(lower, upper));
}
#endif

float FoliageLeafBoundaryMask(const in float centerAlpha) {
	#if FOXY_PBR_SSS_ALPHA_NEIGHBORS == 0
		float centerCoverage = smoothstep(0.10, 0.30, centerAlpha);
		vec2 centeredSpriteUv = abs(spriteUv * 2.0 - 1.0);
		float perimeter = max(centeredSpriteUv.x, centeredSpriteUv.y);
		float perimeterWeight = smoothstep(0.10, 0.72, perimeter);
		return Saturate(centerCoverage * mix(0.42, 0.72, perimeterWeight));
	#else
	vec2 atlasTexel = 1.0 / max(vec2(atlasSize), vec2(1.0));
	vec2 footprint = abs(dFdx(texcoord)) + abs(dFdy(texcoord));
	vec2 sampleOffset = min(max(atlasTexel * 1.85, footprint * 0.78), atlasTexel * 2.85);

	float minimumAlpha = 1.0;
	minimumAlpha = min(minimumAlpha, texture2D(texture, FoliageSpriteSampleUv(texcoord + vec2( sampleOffset.x, 0.0), atlasTexel)).a * surfaceColor.a);
	minimumAlpha = min(minimumAlpha, texture2D(texture, FoliageSpriteSampleUv(texcoord + vec2(-sampleOffset.x, 0.0), atlasTexel)).a * surfaceColor.a);
	minimumAlpha = min(minimumAlpha, texture2D(texture, FoliageSpriteSampleUv(texcoord + vec2(0.0,  sampleOffset.y), atlasTexel)).a * surfaceColor.a);
	minimumAlpha = min(minimumAlpha, texture2D(texture, FoliageSpriteSampleUv(texcoord + vec2(0.0, -sampleOffset.y), atlasTexel)).a * surfaceColor.a);

	float centerCoverage = smoothstep(0.10, 0.30, centerAlpha);
	float alphaDrop = max(centerAlpha - minimumAlpha, 0.0);
	float boundaryContrast = smoothstep(0.08, 0.55, alphaDrop);
	float transparentNeighbor = 1.0 - smoothstep(0.18, 0.62, minimumAlpha);
	vec2 centeredSpriteUv = abs(spriteUv * 2.0 - 1.0);
	float perimeter = max(centeredSpriteUv.x, centeredSpriteUv.y);
	float perimeterWeight = smoothstep(0.10, 0.72, perimeter);
	float sheetBase = centerCoverage * mix(0.42, 0.72, perimeterWeight);
	float edgeDetail = centerCoverage * boundaryContrast * transparentNeighbor * mix(0.45, 1.0, perimeterWeight) * 0.98;
	return Saturate(max(sheetBase, edgeDetail));
	#endif
}

float FoliageTransmissionMask(const in float centerAlpha) {
	float leaves = max(
		FoliageMaterialMatch(vertexMaterialId, 10100.0),
		FoliageMaterialMatch(vertexMaterialId, 12000.0)
	);
	if (leaves > 0.5) {
		return smoothstep(0.10, 0.30, centerAlpha);
	}

	float shortPlant = FoliageMaterialMatch(vertexMaterialId, 10101.0);
	float tallPlantLower = FoliageMaterialMatch(vertexMaterialId, 10102.0);
	float tallPlantUpper = FoliageMaterialMatch(vertexMaterialId, 10103.0);
	float localHeight = 1.0 - Saturate(spriteUv.y);
	float centerCoverage = smoothstep(0.10, 0.30, centerAlpha);
	float plantHeight = localHeight;
	if (tallPlantLower > 0.5) {
		plantHeight = 0.5 * localHeight;
	} else if (tallPlantUpper > 0.5) {
		plantHeight = 0.5 + 0.5 * localHeight;
	} else if (shortPlant <= 0.5) {
		return 0.0;
	}
	return smoothstep(0.12, 0.72, plantHeight) * centerCoverage;
}

float FoliageSoftSunMask(
	const in float centerAlpha,
	const in vec3 geometricNormalView,
	const in vec3 sunDirectionView
) {
	float coverage = smoothstep(0.10, 0.30, centerAlpha);
	float facing = dot(normalize(geometricNormalView), normalize(sunDirectionView));
	float wrapped = Saturate((facing + FOXY_LEAF_SOFT_LIGHT_WRAP_ACTIVE) /
		(1.0 + FOXY_LEAF_SOFT_LIGHT_WRAP_ACTIVE));
	float faceResponse = mix(0.58, 1.0, smoothstep(0.02, 0.62, wrapped));
	return coverage * faceResponse;
}

#endif
