#ifndef FOXY_VOXEL_SHAPE_GLSL
#define FOXY_VOXEL_SHAPE_GLSL

#include "/lib/transmission.glsl"
#include "/lib/voxel/voxel_shape_buffer.glsl"

int VoxelShapeDescriptorIndex(const in uint materialId) {

if (materialId < 10400u) return -1;

	if (materialId >= 10400u && materialId <= 10439u) {
		return int(materialId - 10400u);
	}
	if (materialId >= 10440u && materialId <= 10441u) {
		return 40 + int(materialId - 10440u);
	}
	if (materialId >= 10450u && materialId <= 10465u) {
		return 42 + int(materialId - 10450u);
	}
	if (materialId >= 10480u && materialId <= 10495u) {
		return 78 + int(materialId - 10480u);
	}
	if (materialId >= 10500u && materialId <= 10515u) {
		return 94 + int(materialId - 10500u);
	}

if (materialId >= 10600u && materialId <= 10871u) {
		return 110 + int(TransmissionPaneConnections(materialId));
	}
	if (materialId >= 10900u && materialId <= 10915u) {
		return 58 + int(materialId - 10900u);
	}
	if (materialId >= 10920u && materialId <= 10923u) {
		return 74 + int(materialId - 10920u);
	}

if (materialId >= 11000u && materialId <= 11015u) {
		return 365 + int(materialId - 11000u);
	}
	if (materialId >= 11020u && materialId <= 11026u) {
		return 126 + int(materialId - 11020u);
	}
	if (materialId >= 11030u && materialId <= 11034u) {
		return 133 + int(materialId - 11030u);
	}
	if (materialId >= 11040u && materialId <= 11043u) {
		return 138 + int((materialId - 11040u) & 1u);
	}
	if (materialId >= 11050u && materialId <= 11055u) {
		return 140 + int(materialId - 11050u);
	}
	if (materialId >= 11060u && materialId <= 11063u) {
		return 146 + int(materialId - 11060u);
	}
	if (materialId == 11070u) return 150;
	if (materialId >= 11080u && materialId <= 11086u) {
		return 151 + int(materialId - 11080u);
	}
	if (materialId >= 11100u && materialId <= 11106u) {
		return 158 + int(materialId - 11100u);
	}
	if (materialId >= 11200u && materialId <= 11215u) return 165;
	if (materialId >= 11300u && materialId <= 11461u) return 166 + int(materialId - 11300u);
	if (materialId >= 11500u && materialId <= 11511u) return 328 + int(materialId - 11500u);
	if (materialId >= 11512u && materialId <= 11517u) return 340 + int(materialId - 11512u);
	if (materialId >= 11518u && materialId <= 11521u) return 346 + int(materialId - 11518u);
	if (materialId >= 11522u && materialId <= 11536u) return 350 + int(materialId - 11522u);
	if (materialId >= 11600u && materialId <= 11743u) return 381 + int(materialId - 11600u);
	if (materialId >= 11800u && materialId <= 11959u) return 525 + int(materialId - 11800u);
	return -1;
}

const int FOXY_VOXEL_LAVA_SURFACE_DESCRIPTOR = 164;
const float FOXY_VOXEL_LAVA_SURFACE_HEIGHT = 14.0 / 16.0;

int VoxelShapeDescriptorForPayload(
	const in uint materialId,
	const in uint payload
) {
	int descriptor = VoxelShapeDescriptorIndex(materialId);
	if (materialId == FOXY_VOXEL_LAVA_SURFACE_MATERIAL) {
		descriptor = FOXY_VOXEL_LAVA_SURFACE_DESCRIPTOR;
	}
	return descriptor;
}

float VoxelShapePackedCoordinate(
	const in uint packedBox,
	const in uint shift
) {
	return float((packedBox >> shift) & 31u) * (1.0 / 16.0);
}

void VoxelShapeDecodeBox(
	const in uint packedBox,
	out vec3 boxMinimum,
	out vec3 boxMaximum
) {
	boxMinimum = vec3(
		VoxelShapePackedCoordinate(packedBox, 0u),
		VoxelShapePackedCoordinate(packedBox, 5u),
		VoxelShapePackedCoordinate(packedBox, 10u)
	);
	boxMaximum = vec3(
		VoxelShapePackedCoordinate(packedBox, 15u),
		VoxelShapePackedCoordinate(packedBox, 20u),
		VoxelShapePackedCoordinate(packedBox, 25u)
	);
}

bool VoxelShapeRayBoxClosest(
	const in vec3 localRayOrigin,
	const in vec3 rayDirection,
	const in vec3 rayInverseDirection,
	const in bvec3 parallelDirection,
	const in vec3 boxMinimum,
	const in vec3 boxMaximum,
	const in float segmentStart,
	const in float segmentEnd,
	out float hitDistance,
	out vec3 hitNormal
) {
	float nearDistance = segmentStart - 1.0e-5;
	float farDistance = segmentEnd;
	vec3 nearNormal = vec3(0.0);
	for (int axis = 0; axis < 3; ++axis) {
		if (parallelDirection[axis]) {
			if (
				localRayOrigin[axis] < boxMinimum[axis] ||
				localRayOrigin[axis] > boxMaximum[axis]
			) {
				return false;
			}
			continue;
		}
		float first = (boxMinimum[axis] - localRayOrigin[axis]) *
			rayInverseDirection[axis];
		float second = (boxMaximum[axis] - localRayOrigin[axis]) *
			rayInverseDirection[axis];
		float axisNear = min(first, second);
		float axisFar = max(first, second);
		if (axisNear > nearDistance) {
			nearDistance = axisNear;
			nearNormal = vec3(0.0);
			nearNormal[axis] = first < second ? -1.0 : 1.0;
		}
		farDistance = min(farDistance, axisFar);
		if (farDistance < nearDistance) return false;
	}
	hitDistance = max(nearDistance, segmentStart);
	hitNormal = dot(nearNormal, nearNormal) > 0.5
		? nearNormal
		: -rayDirection;
	return hitDistance <= segmentEnd + 1.0e-5;
}

bool VoxelShapeRayBoxAnyHit(
	const in vec3 localRayOrigin,
	const in vec3 rayInverseDirection,
	const in bvec3 parallelDirection,
	const in vec3 boxMinimum,
	const in vec3 boxMaximum,
	const in float segmentStart,
	const in float segmentEnd
) {
	float nearDistance = segmentStart - 1.0e-5;
	float farDistance = segmentEnd;
	for (int axis = 0; axis < 3; ++axis) {
		if (parallelDirection[axis]) {
			if (
				localRayOrigin[axis] < boxMinimum[axis] ||
				localRayOrigin[axis] > boxMaximum[axis]
			) {
				return false;
			}
			continue;
		}
		float first = (boxMinimum[axis] - localRayOrigin[axis]) *
			rayInverseDirection[axis];
		float second = (boxMaximum[axis] - localRayOrigin[axis]) *
			rayInverseDirection[axis];
		nearDistance = max(nearDistance, min(first, second));
		farDistance = min(farDistance, max(first, second));
		if (farDistance < nearDistance) return false;
	}
	return nearDistance <= segmentEnd + 1.0e-5;
}

bool VoxelShapeTrace(
	const in int descriptorIndex,
	const in vec3 rayOrigin,
	const in vec3 rayDirection,
	const in vec3 rayInverseDirection,
	const in bvec3 parallelDirection,
	const in ivec3 cell,
	const in float segmentStart,
	const in float segmentEnd,
	out float hitDistance,
	out vec3 hitNormal
) {
	uint meta = VoxelShapeMetaLoad(descriptorIndex);
	uint offset = meta & 0xffffu;
	uint count = meta >> 16u;
	vec3 localRayOrigin = rayOrigin - vec3(cell);
	bool found = false;
	hitDistance = segmentEnd;
	hitNormal = -rayDirection;

	for (uint item = 0u; item < count; ++item) {
		vec3 boxMinimum;
		vec3 boxMaximum;
		VoxelShapeDecodeBox(
			VoxelShapeBoxLoad(offset + item),
			boxMinimum,
			boxMaximum
		);
		float candidateDistance;
		vec3 candidateNormal;
		bool candidateHit = VoxelShapeRayBoxClosest(
			localRayOrigin,
			rayDirection,
			rayInverseDirection,
			parallelDirection,
			boxMinimum,
			boxMaximum,
			segmentStart,
			segmentEnd,
			candidateDistance,
			candidateNormal
		);
		if (candidateHit && (!found || candidateDistance < hitDistance)) {
			found = true;
			hitDistance = candidateDistance;
			hitNormal = candidateNormal;

			if (hitDistance <= segmentStart + 1.0e-5) return true;
		}
	}
	return found;
}

bool VoxelShapeAnyHit(
	const in int descriptorIndex,
	const in vec3 rayOrigin,
	const in vec3 rayInverseDirection,
	const in bvec3 parallelDirection,
	const in ivec3 cell,
	const in float segmentStart,
	const in float segmentEnd
) {
	uint meta = VoxelShapeMetaLoad(descriptorIndex);
	uint offset = meta & 0xffffu;
	uint count = meta >> 16u;
	vec3 localRayOrigin = rayOrigin - vec3(cell);
	for (uint item = 0u; item < count; ++item) {
		vec3 boxMinimum;
		vec3 boxMaximum;
		VoxelShapeDecodeBox(
			VoxelShapeBoxLoad(offset + item),
			boxMinimum,
			boxMaximum
		);
		if (VoxelShapeRayBoxAnyHit(
			localRayOrigin,
			rayInverseDirection,
			parallelDirection,
			boxMinimum,
			boxMaximum,
			segmentStart,
			segmentEnd
		)) {
			return true;
		}
	}
	return false;
}

#endif

