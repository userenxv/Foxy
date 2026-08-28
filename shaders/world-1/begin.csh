#version 430
#include "/lib/settings.glsl"

#if FOXY_VOXEL_ACTIVE == 1
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(128, 1, 1);

#define FOXY_VOXEL_BUFFER_WRITE
#include "/lib/voxel/voxel_grid.glsl"
#define FOXY_VOXEL_SHAPE_BUFFER_WRITE
#include "/lib/voxel/voxel_shape_buffer.glsl"
#include "/lib/voxel/voxel_shape_table.glsl"

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
layout(std430, binding = 3) coherent buffer IrradianceFeedback {
	uint ircActiveCount;
	uint ircActiveCells[];
};
#endif

void main() {
	uint shapeIndex = gl_GlobalInvocationID.x;
	if (shapeIndex < FOXY_VOXEL_SHAPE_META_COUNT) {
		voxelShapeMeta[shapeIndex] = FOXY_VOXEL_SHAPE_META[shapeIndex];
	}
	if (shapeIndex < FOXY_VOXEL_SHAPE_BOX_COUNT) {
		voxelShapeBoxes[shapeIndex] = FOXY_VOXEL_SHAPE_BOXES[shapeIndex];
	}
	#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
		if (gl_GlobalInvocationID.x == 0u) ircActiveCount = 0u;
	#endif
	uint stride = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
	for (
		uint index = gl_GlobalInvocationID.x;
		index < VOXEL_GRID_COUNT;
		index += stride
	) {
		VoxelGridClear(index);
		VoxelHierarchyClear(index);
		#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
			VoxelEmitterFacesClear(index);
		#endif
	}
	memoryBarrierBuffer();
}
#else
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
}
#endif
