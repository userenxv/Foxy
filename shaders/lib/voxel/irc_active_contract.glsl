#ifndef FOXY_IRC_ACTIVE_CONTRACT_GLSL
#define FOXY_IRC_ACTIVE_CONTRACT_GLSL

#include "/lib/settings.glsl"

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1

#include "/lib/transmission.glsl"

const int FOXY_IRC_SIZE = 128;
const uint FOXY_IRC_COUNT = 2097152u;
const ivec3 FOXY_IRC_GRID_OFFSET = ivec3(
	(FOXY_VOXEL_GRID_SIZE - FOXY_IRC_SIZE) / 2
);

layout(std430, binding = 0) readonly buffer VoxelGridBuffer {
	uint voxelGridData[];
};

uint VoxelGridIndex(const in ivec3 cell) {
	return uint(
		cell.x +
		FOXY_VOXEL_GRID_SIZE * (cell.y + FOXY_VOXEL_GRID_SIZE * cell.z)
	);
}

bool VoxelGridInside(const in ivec3 cell) {
	return all(greaterThanEqual(cell, ivec3(0))) &&
		all(lessThan(cell, ivec3(FOXY_VOXEL_GRID_SIZE)));
}

uint VoxelGridLoadUnchecked(const in ivec3 cell) {
	return voxelGridData[VoxelGridIndex(cell)];
}

bool VoxelGridTopologyOccupied(const in uint payload) {
	return (payload & 0x80000000u) != 0u &&
		!TransmissionIsGlassUint(payload & 0x0000ffffu);
}

uint IrcIndex(const in ivec3 cell) {
	ivec3 localCell = cell - FOXY_IRC_GRID_OFFSET;
	return uint(localCell.x + FOXY_IRC_SIZE *
		(localCell.y + FOXY_IRC_SIZE * localCell.z));
}

bool IrcInside(const in ivec3 cell) {
	ivec3 localCell = cell - FOXY_IRC_GRID_OFFSET;
	return all(greaterThanEqual(localCell, ivec3(0))) &&
		all(lessThan(localCell, ivec3(FOXY_IRC_SIZE)));
}

#endif

#endif
