#ifndef FOXY_VOXEL_SHAPE_BUFFER_GLSL
#define FOXY_VOXEL_SHAPE_BUFFER_GLSL

const uint FOXY_VOXEL_SHAPE_META_COUNT = 685u;
const uint FOXY_VOXEL_SHAPE_BOX_COUNT = 2112u;

#ifdef FOXY_VOXEL_SHAPE_BUFFER_WRITE
layout(std430, binding = 6) coherent buffer VoxelShapeTableBuffer {
#else
layout(std430, binding = 6) readonly buffer VoxelShapeTableBuffer {
#endif
	uint voxelShapeMeta[685];
	uint voxelShapeBoxes[2112];
};

uint VoxelShapeMetaLoad(const in int index) {
	return voxelShapeMeta[index];
}

uint VoxelShapeBoxLoad(const in uint index) {
	return voxelShapeBoxes[index];
}

#endif
