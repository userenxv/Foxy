#ifndef FOXY_MATERIAL_PARALLAX_GLSL
#define FOXY_MATERIAL_PARALLAX_GLSL

#if FOXY_PBR_PARALLAX == 1 && FOXY_PBR_NORMAL_MAPS == 1 && defined(TERRAIN)
struct PbrParallaxHit {
	vec2 atlasUv;
	vec3 heightNormalTangent;
	float sideMask;
};

vec2 PbrParallaxAtlasUv(
	const in vec2 localUv,
	const in vec2 spriteOffset,
	const in vec2 spriteScale,
	const in vec2 spritePixels
) {
	vec2 edgeInset = min(vec2(0.5) / spritePixels, vec2(0.499));
	vec2 wrappedUv = clamp(fract(localUv), edgeInset, vec2(1.0) - edgeInset);
	return spriteOffset + wrappedUv * spriteScale;
}

vec2 PbrParallaxColumnUv(
	const in vec2 cell,
	const in vec2 spriteOffset,
	const in vec2 spriteScale,
	const in vec2 spritePixels
) {
	vec2 wrappedCell = mod(cell, spritePixels);
	vec2 localUv = (wrappedCell + 0.5) / spritePixels;
	return spriteOffset + localUv * spriteScale;
}

float PbrParallaxColumnHeight(
	const in vec2 cell,
	const in vec2 spriteOffset,
	const in vec2 spriteScale,
	const in vec2 spritePixels
) {
	vec2 atlasTexel = vec2(1.0) / max(vec2(atlasSize), vec2(1.0));
	return MATERIAL_TEXTURE_GRAD(
		normals,
		PbrParallaxColumnUv(cell, spriteOffset, spriteScale, spritePixels),
		vec2(atlasTexel.x, 0.0),
		vec2(0.0, atlasTexel.y)
	).a;
}

PbrParallaxHit PbrTraceParallax(const in vec2 baseUv, const in vec3 viewDirTangent) {
	PbrParallaxHit hit;
	hit.atlasUv = baseUv;
	hit.heightNormalTangent = vec3(0.0, 0.0, 1.0);
	hit.sideMask = 0.0;

	float distanceFade = 1.0 - smoothstep(
		FOXY_PBR_PARALLAX_DISTANCE * 0.70,
		FOXY_PBR_PARALLAX_DISTANCE,
		length(surfaceViewPosition)
	);
	if (distanceFade <= 0.001 || viewDirTangent.z <= 0.02) {
		return hit;
	}

	vec2 atlasPixels = max(vec2(atlasSize), vec2(1.0));
	vec2 spriteScale = spriteHalfSize * 2.0;
	vec2 spritePixels = floor(spriteScale * atlasPixels + 0.5);
	if (min(spritePixels.x, spritePixels.y) < 1.0) {
		return hit;
	}

	vec2 spriteOffset = baseUv - spriteUv * spriteScale;
	float depthScale = FOXY_PBR_PARALLAX_DEPTH * distanceFade;
	vec2 fullRayOffset = viewDirTangent.xy * (depthScale / max(viewDirTangent.z, 0.02));
	vec2 gridStart = spriteUv * spritePixels;
	vec2 gridDirection = -fullRayOffset * spritePixels;
	if (dot(gridDirection, gridDirection) < 1.0e-10) {
		return hit;
	}

	vec2 cell = floor(gridStart);
	float columnHeight = PbrParallaxColumnHeight(
		cell,
		spriteOffset,
		spriteScale,
		spritePixels
	);
	if (columnHeight >= 1.0 - 1.0e-5) {
		return hit;
	}

	vec2 cellStep = sign(gridDirection);
	vec2 inverseDirection = vec2(
		abs(gridDirection.x) > 1.0e-8 ? 1.0 / abs(gridDirection.x) : 1.0e20,
		abs(gridDirection.y) > 1.0e-8 ? 1.0 / abs(gridDirection.y) : 1.0e20
	);
	vec2 nextGridLine = cell + vec2(
		cellStep.x > 0.0 ? 1.0 : 0.0,
		cellStep.y > 0.0 ? 1.0 : 0.0
	);
	vec2 boundaryDepth = vec2(
		abs(gridDirection.x) > 1.0e-8
			? (nextGridLine.x - gridStart.x) / gridDirection.x
			: 1.0e20,
		abs(gridDirection.y) > 1.0e-8
			? (nextGridLine.y - gridStart.y) / gridDirection.y
			: 1.0e20
	);
	boundaryDepth = max(boundaryDepth, vec2(0.0));

	float currentDepth = 0.0;
	for (int i = 0; i < FOXY_PBR_PARALLAX_STEPS; ++i) {
		float nextBoundary = min(boundaryDepth.x, boundaryDepth.y);
		float columnTopDepth = 1.0 - columnHeight;
		if (
			columnTopDepth >= currentDepth - 1.0e-6 &&
			columnTopDepth <= min(nextBoundary, 1.0) + 1.0e-6
		) {
			hit.atlasUv = PbrParallaxAtlasUv(
				spriteUv - fullRayOffset * clamp(columnTopDepth, 0.0, 1.0),
				spriteOffset,
				spriteScale,
				spritePixels
			);
			return hit;
		}
		if (nextBoundary > 1.0) break;

		bool crossX = boundaryDepth.x <= boundaryDepth.y + 1.0e-7;
		bool crossY = boundaryDepth.y <= boundaryDepth.x + 1.0e-7;
		vec2 crossedCell = vec2(
			crossX ? cellStep.x : 0.0,
			crossY ? cellStep.y : 0.0
		);
		cell += crossedCell;
		if (crossX) boundaryDepth.x += inverseDirection.x;
		if (crossY) boundaryDepth.y += inverseDirection.y;
		currentDepth = nextBoundary;
		columnHeight = PbrParallaxColumnHeight(
			cell,
			spriteOffset,
			spriteScale,
			spritePixels
		);

		if (columnHeight + 1.0e-5 >= 1.0 - currentDepth) {
			vec2 sideLocalUv = spriteUv - fullRayOffset * currentDepth;
			vec2 unwrappedCellCenter = (cell + 0.5) / spritePixels;
			if (crossX) sideLocalUv.x = unwrappedCellCenter.x;
			if (crossY) sideLocalUv.y = unwrappedCellCenter.y;
			hit.atlasUv = PbrParallaxAtlasUv(
				sideLocalUv,
				spriteOffset,
				spriteScale,
				spritePixels
			);
			hit.heightNormalTangent = normalize(vec3(-crossedCell, 0.0));
			hit.sideMask = 1.0;
			return hit;
		}
	}

	hit.atlasUv = PbrParallaxAtlasUv(
		spriteUv - fullRayOffset * clamp(currentDepth, 0.0, 1.0),
		spriteOffset,
		spriteScale,
		spritePixels
	);
	return hit;
}
#endif

#endif
