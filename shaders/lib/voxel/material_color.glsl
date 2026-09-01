#ifndef FOXY_VOXEL_MATERIAL_COLOR_GLSL
#define FOXY_VOXEL_MATERIAL_COLOR_GLSL

// Per-cell atlas metadata for offscreen reflections; independently designed.
#if FOXY_MATERIAL_REFLECTIONS == 1 && FOXY_MATERIAL_REFLECTION_GLOBAL == 1 && FOXY_MATERIAL_REFLECTION_OFFSCREEN == 1 && FOXY_VOXEL_GI_ACTIVE == 1

#define FOXY_VOXEL_MATERIAL_COLOR_FACE_COUNT 6u
#define FOXY_VOXEL_MATERIAL_COLOR_WORDS 2u

uniform sampler2D atlas2D;
uniform ivec2 atlasSize;

#ifdef FOXY_VOXEL_MATERIAL_COLOR_WRITE
layout(std430, binding = 7) coherent buffer VoxelMaterialColorBuffer {
	uint voxelMaterialColorData[];
};
#else
layout(std430, binding = 7) readonly buffer VoxelMaterialColorBuffer {
	uint voxelMaterialColorData[];
};
#endif

uint VoxelMaterialColorBase(const in ivec3 cell, const in uint faceCode) {
	if (faceCode < 1u || faceCode > FOXY_VOXEL_MATERIAL_COLOR_FACE_COUNT) return 0u;
	return uint(cell.x + VOXEL_GRID_SIZE * (cell.y + VOXEL_GRID_SIZE * cell.z)) *
		FOXY_VOXEL_MATERIAL_COLOR_FACE_COUNT * FOXY_VOXEL_MATERIAL_COLOR_WORDS +
		(faceCode - 1u) * FOXY_VOXEL_MATERIAL_COLOR_WORDS;
}

void VoxelMaterialColorStore(
	const in ivec3 cell,
	const in uint materialId,
	const in uint faceCode,
	const in vec2 atlasCenterUv,
	const in vec2 atlasVertexUv
) {
	if (!VoxelGridInside(cell) || faceCode < 1u || faceCode > FOXY_VOXEL_MATERIAL_COLOR_FACE_COUNT) return;
	vec2 atlasResolution = vec2(atlasSize);
	vec2 footprint = max(abs(atlasVertexUv - atlasCenterUv) * 2.0 * atlasResolution, vec2(1.0));
	float textureResolution = exp2(round(log2(max(footprint.x, footprint.y))));
	textureResolution = clamp(textureResolution, 1.0, 256.0);
	vec2 atlasTiles = atlasResolution / textureResolution;
	vec2 tileCenter = (floor(atlasCenterUv * atlasTiles) + vec2(0.5)) / atlasTiles;
	uvec2 encodedCenter = uvec2(clamp(floor(tileCenter * 4095.0 + 0.5), vec2(0.0), vec2(4095.0)));
	uint resolutionCode = uint(clamp(round(log2(textureResolution)), 0.0, 8.0));
	uint packedCenter = 0x80000000u | (encodedCenter.x << 19u) | (encodedCenter.y << 7u) | resolutionCode;
	uint baseIndex = VoxelMaterialColorBase(cell, faceCode);
	atomicExchange(voxelMaterialColorData[baseIndex], packedCenter);
	atomicExchange(
		voxelMaterialColorData[baseIndex + 1u],
		0x80000000u | (materialId & 0xffffu)
	);
}

vec2 VoxelMaterialColorFaceUv(const in vec3 gridPosition, const in vec3 faceNormal) {
	vec3 localPosition = fract(gridPosition);
	vec3 axis = abs(faceNormal);
	if (axis.y >= axis.x && axis.y >= axis.z) return localPosition.xz;
	if (axis.x >= axis.z) return localPosition.zy;
	return localPosition.xy;
}

vec3 VoxelMaterialColorLoad(
	const in ivec3 cell,
	const in uint materialId,
	const in uint faceCode,
	const in vec3 gridPosition,
	const in vec3 faceNormal
) {
	if (!VoxelGridInside(cell) || faceCode < 1u || faceCode > FOXY_VOXEL_MATERIAL_COLOR_FACE_COUNT) return vec3(0.0);
	uint baseIndex = VoxelMaterialColorBase(cell, faceCode);
	uint packedCenter = voxelMaterialColorData[baseIndex];
	uint packedMaterial = voxelMaterialColorData[baseIndex + 1u];
	if ((packedCenter & 0x80000000u) == 0u) return vec3(0.0);
	if ((packedMaterial & 0x80000000u) == 0u ||
		(packedMaterial & 0xffffu) != (materialId & 0xffffu)) return vec3(0.0);
	vec2 atlasCenterUv = vec2(
		float((packedCenter >> 19u) & 0xfffu),
		float((packedCenter >> 7u) & 0xfffu)
	) * (1.0 / 4095.0);
	float textureResolution = exp2(float(packedCenter & 0x1fu));
	vec2 atlasExtent = 0.5 * textureResolution / vec2(atlasSize);
	vec2 atlasUv = atlasCenterUv + (VoxelMaterialColorFaceUv(gridPosition, faceNormal) * 2.0 - 1.0) * atlasExtent;
	atlasUv = clamp(atlasUv, atlasCenterUv - atlasExtent * 0.96, atlasCenterUv + atlasExtent * 0.96);
	return max(texture2D(atlas2D, atlasUv).rgb, vec3(0.0));
}

#endif
#endif
