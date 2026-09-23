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
	uint voxelShapeExtent[685];
};

uint VoxelShapeMetaLoad(const in int index) {
	return voxelShapeMeta[index];
}

uint VoxelShapeBoxLoad(const in uint index) {
	return voxelShapeBoxes[index];
}

uint VoxelShapeExtentLoad(const in int descriptor) {
	return voxelShapeExtent[descriptor];
}

int VoxelShapeExtentField(const in uint extent, const in int shift) {
	return int((extent >> uint(shift)) & 31u);
}

float VoxelShapeSurfaceOffset(const in int descriptor, const in ivec3 normalStep) {
	if (normalStep.x != 0) {
		if (descriptor < 0) return normalStep.x > 0 ? 1.0 : 0.0;
		uint extent = VoxelShapeExtentLoad(descriptor);
		return float(normalStep.x > 0
			? VoxelShapeExtentField(extent, 5)
			: VoxelShapeExtentField(extent, 0)) * (1.0 / 16.0);
	}
	if (normalStep.y != 0) {
		if (descriptor < 0) return normalStep.y > 0 ? 1.0 : 0.0;
		uint extent = VoxelShapeExtentLoad(descriptor);
		return float(normalStep.y > 0
			? VoxelShapeExtentField(extent, 15)
			: VoxelShapeExtentField(extent, 10)) * (1.0 / 16.0);
	}
	if (descriptor < 0) return normalStep.z > 0 ? 1.0 : 0.0;
	uint extent = VoxelShapeExtentLoad(descriptor);
	return float(normalStep.z > 0
		? VoxelShapeExtentField(extent, 25)
		: VoxelShapeExtentField(extent, 20)) * (1.0 / 16.0);
}

vec3 VoxelShapeCentre(const in int descriptor) {
	uint extent = VoxelShapeExtentLoad(descriptor);
	return vec3(
		float(VoxelShapeExtentField(extent, 0) + VoxelShapeExtentField(extent, 5)),
		float(VoxelShapeExtentField(extent, 10) + VoxelShapeExtentField(extent, 15)),
		float(VoxelShapeExtentField(extent, 20) + VoxelShapeExtentField(extent, 25))
	) * (1.0 / 32.0);
}

#endif
