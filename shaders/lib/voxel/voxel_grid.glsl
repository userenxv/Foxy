#ifndef VOXEL_GRID_GLSL
#define VOXEL_GRID_GLSL

#include "/lib/emissive.glsl"
#include "/lib/transmission.glsl"

// One uint per one-block cell. The selected VRTGI range controls the cubic
// domain while preserving one Minecraft block per voxel.
// 31      occupied
// 27..30  atomic selection level (block light, or source level for emitters)
// 24..26  dominant lit-face axis normal
// 20..23  sky light
// 16..19  source emission level
//  0..15  Iris material ID
const int VOXEL_GRID_SIZE = FOXY_VOXEL_GRID_SIZE;
const uint VOXEL_GRID_COUNT = FOXY_VOXEL_GRID_COUNT;
const uint VOXEL_OCCUPIED_BIT = 0x80000000u;
const uint FOXY_VOXEL_PRIORITY_MASK = 0x78000000u;
const uint FOXY_VOXEL_NORMAL_MASK = 0x07000000u;
const uint FOXY_VOXEL_SKY_LIGHT_MASK = 0x00f00000u;
const uint FOXY_VOXEL_EMISSION_MASK = 0x000f0000u;
const uint VOXEL_MATERIAL_MASK = 0x0000ffffu;
const uint FOXY_VOXEL_PRIORITY_SHIFT = 27u;
const uint FOXY_VOXEL_NORMAL_SHIFT = 24u;
const uint FOXY_VOXEL_SKY_LIGHT_SHIFT = 20u;
const uint FOXY_VOXEL_EMISSION_SHIFT = 16u;

// Internal payload ID for a rendered lava surface below the block boundary.
// It is generated from geometry at voxel-write time; the raster material map
// remains unchanged.
const uint FOXY_VOXEL_LAVA_MATERIAL = 10183u;
const uint FOXY_VOXEL_LAVA_SURFACE_MATERIAL = 10198u;

// Three compact occupancy bitsets cover aligned 2^3, 4^3 and 8^3 regions.
// Word zero stores the number of occupied 8^3 regions for the dense-scene
// fallback. Each level is sized from the active cubic voxel domain.
const uint FOXY_VOXEL_HIERARCHY_LEVEL2_SIDE =
	uint(VOXEL_GRID_SIZE >> 1);
const uint FOXY_VOXEL_HIERARCHY_LEVEL4_SIDE =
	uint(VOXEL_GRID_SIZE >> 2);
const uint FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE =
	uint(VOXEL_GRID_SIZE >> 3);
const uint FOXY_VOXEL_HIERARCHY_LEVEL2_WORD_COUNT =
	(FOXY_VOXEL_HIERARCHY_LEVEL2_SIDE *
	FOXY_VOXEL_HIERARCHY_LEVEL2_SIDE *
	FOXY_VOXEL_HIERARCHY_LEVEL2_SIDE + 31u) >> 5u;
const uint FOXY_VOXEL_HIERARCHY_LEVEL4_WORD_COUNT =
	(FOXY_VOXEL_HIERARCHY_LEVEL4_SIDE *
	FOXY_VOXEL_HIERARCHY_LEVEL4_SIDE *
	FOXY_VOXEL_HIERARCHY_LEVEL4_SIDE + 31u) >> 5u;
const uint FOXY_VOXEL_HIERARCHY_LEVEL8_WORD_COUNT =
	(FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE *
	FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE *
	FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE + 31u) >> 5u;
const uint FOXY_VOXEL_HIERARCHY_LEVEL2_OFFSET = 1u;
const uint FOXY_VOXEL_HIERARCHY_LEVEL4_OFFSET =
	FOXY_VOXEL_HIERARCHY_LEVEL2_OFFSET +
	FOXY_VOXEL_HIERARCHY_LEVEL2_WORD_COUNT;
const uint FOXY_VOXEL_HIERARCHY_LEVEL8_OFFSET =
	FOXY_VOXEL_HIERARCHY_LEVEL4_OFFSET +
	FOXY_VOXEL_HIERARCHY_LEVEL4_WORD_COUNT;
const uint FOXY_VOXEL_HIERARCHY_WORD_COUNT =
	FOXY_VOXEL_HIERARCHY_LEVEL8_OFFSET +
	FOXY_VOXEL_HIERARCHY_LEVEL8_WORD_COUNT;
const uint FOXY_VOXEL_HIERARCHY_DENSE_LIMIT =
	(FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE *
	FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE *
	FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE * 3u) >> 2u;

#ifdef FOXY_VOXEL_BUFFER_WRITE
layout(std430, binding = 0) coherent buffer VoxelGridBuffer {
	uint voxelGridData[];
};
#else
layout(std430, binding = 0) readonly buffer VoxelGridBuffer {
	uint voxelGridData[];
};
#endif

#ifdef FOXY_VOXEL_BUFFER_WRITE
layout(std430, binding = 5) coherent buffer VoxelHierarchyBuffer {
	uint voxelHierarchyData[];
};
#else
layout(std430, binding = 5) readonly buffer VoxelHierarchyBuffer {
	uint voxelHierarchyData[];
};
#endif

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
// The cache remains a 128^3 camera-centered window inside the larger tracing
// domain. Emitter faces outside that window cannot affect its direct-light
// estimator and are intentionally not stored.
const int FOXY_VOXEL_IRC_WINDOW_SIZE = 128;
const ivec3 FOXY_VOXEL_IRC_WINDOW_OFFSET = ivec3(
	(VOXEL_GRID_SIZE - FOXY_VOXEL_IRC_WINDOW_SIZE) / 2
);
const uint FOXY_VOXEL_EMITTER_FACE_KEY_WORDS = 524288u;
const uint FOXY_VOXEL_EMITTER_FACE_LIST_OFFSET =
	2u + FOXY_VOXEL_EMITTER_FACE_KEY_WORDS;
const uint FOXY_VOXEL_EMITTER_FACE_CAPACITY = 524286u;

	#ifdef FOXY_VOXEL_BUFFER_WRITE
layout(std430, binding = 4) coherent buffer VoxelEmitterFaces {
	uint voxelEmitterFaces[];
};
	#else
layout(std430, binding = 4) readonly buffer VoxelEmitterFaces {
	uint voxelEmitterFaces[];
};
	#endif
#endif

vec3 VoxelGridSceneToGrid(
	const in vec3 scenePosition,
	const in vec3 cameraPosition
) {
	return scenePosition + fract(cameraPosition) +
		vec3(FOXY_VOXEL_GRID_HALF_SIZE);
}

bool VoxelGridInside(const in ivec3 cell) {
	return all(greaterThanEqual(cell, ivec3(0))) &&
		all(lessThan(cell, ivec3(VOXEL_GRID_SIZE)));
}

bool VoxelGridInside(const in vec3 position) {
	return all(greaterThanEqual(position, vec3(0.0))) &&
		all(lessThan(position, vec3(float(VOXEL_GRID_SIZE))));
}

uint VoxelGridIndex(const in ivec3 cell) {
	return uint(
		cell.x +
		VOXEL_GRID_SIZE * (cell.y + VOXEL_GRID_SIZE * cell.z)
	);
}

bool VoxelGridOccupied(const in uint payload) {
	return (payload & VOXEL_OCCUPIED_BIT) != 0u;
}

// Cache interpolation needs the air volume immediately in front of a receiver,
// not a ray-traversal obstacle. Glass remains occupied for VRTGI traversal but
// is transparent to the IRC surface-topology classifier.
bool VoxelGridTopologyOccupied(const in uint payload) {
	return VoxelGridOccupied(payload) &&
		!TransmissionIsGlassUint(payload & VOXEL_MATERIAL_MASK);
}

bool VoxelThinPlantMaterial(const in uint materialId) {
	// Crossed-quad plants have negligible geometric volume and must not become
	// solid full-cell occluders in the voxel RT representation.
	return materialId >= 10101u && materialId <= 10103u;
}

bool VoxelExcludedMaterial(const in uint materialId) {
	// Crossed-quad plants are omitted because their raster alpha geometry has no
	// block volume. Small light sources use the analytic sphere path below.
	return VoxelThinPlantMaterial(materialId);
}

uint VoxelMaterialForGeometry(
	const in uint materialId,
	const in vec3 scenePosition,
	const in vec3 cameraPosition,
	const in vec3 sceneNormal
) {
	if (materialId != FOXY_VOXEL_LAVA_MATERIAL || sceneNormal.y <= 0.5) {
		return materialId;
	}
	vec3 gridPosition = VoxelGridSceneToGrid(
		scenePosition,
		cameraPosition
	);
	float localY = fract(gridPosition.y);
	float boundaryDistance = min(localY, 1.0 - localY);
	return boundaryDistance > (1.0 / 32.0)
		? FOXY_VOXEL_LAVA_SURFACE_MATERIAL
		: materialId;
}

uint VoxelGridMaterial(const in uint payload) {
	return payload & VOXEL_MATERIAL_MASK;
}

bool VoxelSphereEmitterMaterial(const in uint materialId) {
	return EmissionPrimitive(float(materialId)) == FOXY_EMISSIVE_SPHERE;
}

bool VoxelFullEmitterMaterial(const in uint materialId) {
	return EmissionPrimitive(float(materialId)) == FOXY_EMISSIVE_SURFACE;
}

bool VoxelEmitterMaterial(const in uint materialId) {
	return EmissionPrimitive(float(materialId)) > FOXY_EMISSIVE_NONE;
}

uint VoxelFallbackEmissionLevel(const in uint materialId) {
	return uint(clamp(floor(EmissionFallbackLevel(float(materialId)) + 0.5), 0.0, 15.0));
}

float VoxelPriorityLevel(const in uint payload) {
	return float(
		(payload & FOXY_VOXEL_PRIORITY_MASK) >> FOXY_VOXEL_PRIORITY_SHIFT
	) * (1.0 / 15.0);
}

float VoxelEmissionLevel(const in uint payload) {
	if (!VoxelEmitterMaterial(VoxelGridMaterial(payload))) return 0.0;
	return float(
		(payload & FOXY_VOXEL_EMISSION_MASK) >> FOXY_VOXEL_EMISSION_SHIFT
	) * (1.0 / 15.0);
}

float VoxelBlockLight(const in uint payload) {
	if (VoxelEmitterMaterial(VoxelGridMaterial(payload))) return 0.0;
	return float(
		(payload & FOXY_VOXEL_EMISSION_MASK) >> FOXY_VOXEL_EMISSION_SHIFT
	) * (1.0 / 15.0);
}

float VoxelSkyLight(const in uint payload) {
	return float(
		(payload & FOXY_VOXEL_SKY_LIGHT_MASK) >>
		FOXY_VOXEL_SKY_LIGHT_SHIFT
	) * (1.0 / 15.0);
}

uint VoxelAxisNormalCode(const in uint payload) {
	return (payload & FOXY_VOXEL_NORMAL_MASK) >> FOXY_VOXEL_NORMAL_SHIFT;
}

uint VoxelEncodeAxisNormal(const in vec3 inputNormal) {
	vec3 axisWeight = abs(inputNormal);
	if (max(axisWeight.x, max(axisWeight.y, axisWeight.z)) < 1.0e-5) {
		return 0u;
	}
	// Larger codes win atomicMax ties. +Y is deliberately last so equally lit
	// sky-exposed cube faces retain their upward face deterministically.
	if (axisWeight.y >= axisWeight.x && axisWeight.y >= axisWeight.z) {
		return inputNormal.y >= 0.0 ? 6u : 1u;
	}
	if (axisWeight.x >= axisWeight.z) {
		return inputNormal.x >= 0.0 ? 5u : 4u;
	}
	return inputNormal.z >= 0.0 ? 3u : 2u;
}

vec3 VoxelAxisNormal(const in uint payload) {
	uint code = VoxelAxisNormalCode(payload);
	if (code == 1u) return vec3(0.0, -1.0, 0.0);
	if (code == 2u) return vec3(0.0, 0.0, -1.0);
	if (code == 3u) return vec3(0.0, 0.0, 1.0);
	if (code == 4u) return vec3(-1.0, 0.0, 0.0);
	if (code == 5u) return vec3(1.0, 0.0, 0.0);
	if (code == 6u) return vec3(0.0, 1.0, 0.0);
	return vec3(0.0);
}

uint VoxelGridLoad(const in ivec3 cell) {
	if (!VoxelGridInside(cell)) {
		return 0u;
	}
	return voxelGridData[VoxelGridIndex(cell)];
}

// Use only after VoxelGridInside has validated the cell.
uint VoxelGridLoadUnchecked(const in ivec3 cell) {
	return voxelGridData[VoxelGridIndex(cell)];
}

uint VoxelHierarchyCellIndex(
	const in ivec3 cell,
	const in int levelShift,
	const in uint levelSide
) {
	uvec3 levelCell = uvec3(cell) >> uvec3(uint(levelShift));
	return levelCell.x + levelSide * (
		levelCell.y + levelSide * levelCell.z
	);
}

bool VoxelHierarchyLevelOccupied(
	const in ivec3 cell,
	const in int levelShift,
	const in uint levelSide,
	const in uint wordOffset
) {
	uint levelIndex = VoxelHierarchyCellIndex(
		cell,
		levelShift,
		levelSide
	);
	uint bitMask = 1u << (levelIndex & 31u);
	return (
		voxelHierarchyData[wordOffset + (levelIndex >> 5u)] & bitMask
	) != 0u;
}

bool VoxelHierarchyEnabled() {
	return voxelHierarchyData[0] < FOXY_VOXEL_HIERARCHY_DENSE_LIMIT;
}

int VoxelHierarchyEmptySize(const in ivec3 cell) {
	if (!VoxelHierarchyLevelOccupied(
		cell,
		3,
		FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE,
		FOXY_VOXEL_HIERARCHY_LEVEL8_OFFSET
	)) return 8;
	if (!VoxelHierarchyLevelOccupied(
		cell,
		2,
		FOXY_VOXEL_HIERARCHY_LEVEL4_SIDE,
		FOXY_VOXEL_HIERARCHY_LEVEL4_OFFSET
	)) return 4;
	if (!VoxelHierarchyLevelOccupied(
		cell,
		1,
		FOXY_VOXEL_HIERARCHY_LEVEL2_SIDE,
		FOXY_VOXEL_HIERARCHY_LEVEL2_OFFSET
	)) return 2;
	return 0;
}

#ifdef FOXY_VOXEL_BUFFER_WRITE
void VoxelGridClear(const in uint index) {
	voxelGridData[index] = 0u;
}

void VoxelHierarchyClear(const in uint index) {
	if (index < FOXY_VOXEL_HIERARCHY_WORD_COUNT) {
		voxelHierarchyData[index] = 0u;
	}
}

uint VoxelHierarchyMarkLevel(
	const in ivec3 cell,
	const in int levelShift,
	const in uint levelSide,
	const in uint wordOffset
) {
	uint levelIndex = VoxelHierarchyCellIndex(
		cell,
		levelShift,
		levelSide
	);
	uint bitMask = 1u << (levelIndex & 31u);
	return atomicOr(
		voxelHierarchyData[wordOffset + (levelIndex >> 5u)],
		bitMask
	) & bitMask;
}

void VoxelHierarchyMark(const in ivec3 cell) {
	VoxelHierarchyMarkLevel(
		cell,
		1,
		FOXY_VOXEL_HIERARCHY_LEVEL2_SIDE,
		FOXY_VOXEL_HIERARCHY_LEVEL2_OFFSET
	);
	VoxelHierarchyMarkLevel(
		cell,
		2,
		FOXY_VOXEL_HIERARCHY_LEVEL4_SIDE,
		FOXY_VOXEL_HIERARCHY_LEVEL4_OFFSET
	);
	uint previous = VoxelHierarchyMarkLevel(
		cell,
		3,
		FOXY_VOXEL_HIERARCHY_LEVEL8_SIDE,
		FOXY_VOXEL_HIERARCHY_LEVEL8_OFFSET
	);
	if (previous == 0u) {
		atomicAdd(voxelHierarchyData[0], 1u);
	}
}

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
void VoxelEmitterFacesClear(const in uint index) {
	if (index == 0u) {
		voxelEmitterFaces[0] = 0u;
		voxelEmitterFaces[1] = 0u;
	}
	if (index < FOXY_VOXEL_EMITTER_FACE_KEY_WORDS) {
		voxelEmitterFaces[2u + index] = 0u;
	}
}

void VoxelEmitterFaceAppend(
	const in ivec3 voxelCell,
	const in uint normalCode
) {
	ivec3 localCell = voxelCell - FOXY_VOXEL_IRC_WINDOW_OFFSET;
	if (
		any(lessThan(localCell, ivec3(0))) ||
		any(greaterThanEqual(localCell, ivec3(FOXY_VOXEL_IRC_WINDOW_SIZE)))
	) return;
	uint localVoxelIndex = uint(
		localCell.x + FOXY_VOXEL_IRC_WINDOW_SIZE *
		(localCell.y + FOXY_VOXEL_IRC_WINDOW_SIZE * localCell.z)
	);
	uint faceKey = localVoxelIndex * 8u + (normalCode & 7u);
	uint keyWord = faceKey >> 5u;
	uint keyMask = 1u << (faceKey & 31u);
	uint previous = atomicOr(voxelEmitterFaces[2u + keyWord], keyMask);
	if ((previous & keyMask) != 0u) return;
	uint listIndex = atomicAdd(voxelEmitterFaces[0], 1u);
	if (listIndex < FOXY_VOXEL_EMITTER_FACE_CAPACITY) {
		voxelEmitterFaces[
			FOXY_VOXEL_EMITTER_FACE_LIST_OFFSET + listIndex
		] = faceKey;
	} else {
		atomicOr(voxelEmitterFaces[1], 1u);
	}
}
#endif

void VoxelGridSynchronizeAnchor() {
	atomicOr(voxelGridData[0], 0u);
}

void VoxelGridStoreScene(
	const in vec3 scenePosition,
	const in vec3 cameraPosition,
	const in uint materialId,
	const in vec3 sceneNormal,
	const in float emissionLevel,
	const in vec2 lightmapUv
) {
	uint storedMaterialId = VoxelMaterialForGeometry(
		materialId,
		scenePosition,
		cameraPosition,
		sceneNormal
	);
	// Raster rendering is unaffected; omit only thin alpha geometry from the RT
	// occupancy map. Analytic light spheres still receive a voxel entry without
	// becoming hard cell occluders during traversal.
	if (VoxelExcludedMaterial(storedMaterialId)) return;

	ivec3 cell = ivec3(floor(VoxelGridSceneToGrid(
		scenePosition,
		cameraPosition
	)));
	if (!VoxelGridInside(cell)) {
		return;
	}

	uvec2 lightLevels = uvec2(clamp(
		floor(clamp(lightmapUv, vec2(0.0), vec2(1.0)) * 16.0),
		vec2(0.0),
		vec2(15.0)
	));
	uint encodedEmission = uint(clamp(
		floor(max(emissionLevel, 0.0) + 0.5),
		0.0,
		15.0
	));
	encodedEmission = max(
		encodedEmission,
		VoxelFallbackEmissionLevel(storedMaterialId)
	);
	uint storedLightLevel = encodedEmission > 0u
		? encodedEmission
		: lightLevels.x;
	uint selectionLevel = encodedEmission > 0u
		? encodedEmission
		: max(lightLevels.x, lightLevels.y);
	uint normalCode = VoxelEncodeAxisNormal(sceneNormal);
	uint payload = VOXEL_OCCUPIED_BIT |
		(storedMaterialId & VOXEL_MATERIAL_MASK) |
		(selectionLevel << FOXY_VOXEL_PRIORITY_SHIFT) |
		(normalCode << FOXY_VOXEL_NORMAL_SHIFT) |
		(lightLevels.y << FOXY_VOXEL_SKY_LIGHT_SHIFT) |
		(storedLightLevel << FOXY_VOXEL_EMISSION_SHIFT);
	// A deterministic maximum avoids draw-order-dependent data when multiple
	// terrain classes share a one-block cell. The selection level retains the
	// strongest incident-light face, or the strongest source for emitter cells.
	uint voxelIndex = VoxelGridIndex(cell);
	uint previousPayload = atomicMax(voxelGridData[voxelIndex], payload);
	// A hierarchy cell only needs one mark. The successful empty-to-occupied
	// transition is unique even when several terrain vertices share this voxel,
	// so this avoids multiplying hierarchy atomics by vertex density.
	if (!VoxelGridOccupied(previousPayload)) {
		VoxelHierarchyMark(cell);
	}
	#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
		// Normal code zero is the one-entry analytic-sphere primitive. Solid and
		// modded emitters retain one entry per rendered face.
		if (encodedEmission > 0u) {
			uint emitterPrimitiveCode = VoxelSphereEmitterMaterial(storedMaterialId)
				? 0u
				: normalCode;
			VoxelEmitterFaceAppend(cell, emitterPrimitiveCode);
		}
	#endif
}
#endif

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
uint VoxelEmitterFaceCount() {
	return min(voxelEmitterFaces[0], FOXY_VOXEL_EMITTER_FACE_CAPACITY);
}

uint VoxelEmitterFaceLoad(const in uint index) {
	return voxelEmitterFaces[FOXY_VOXEL_EMITTER_FACE_LIST_OFFSET + index];
}

ivec3 VoxelGridCellFromIndex(const in uint index) {
	uint side = uint(FOXY_VOXEL_IRC_WINDOW_SIZE);
	uint plane = side * side;
	uint z = index / plane;
	uint remainder = index - z * plane;
	uint y = remainder / side;
	uint x = remainder - y * side;
	return ivec3(int(x), int(y), int(z)) + FOXY_VOXEL_IRC_WINDOW_OFFSET;
}

float VoxelGridHashUnitFloat(const in uint value) {
	// The high 24 bits are exactly representable and therefore strictly [0,1).
	// Converting all 32 bits can round 0xffffffff to 1.0 on float hardware.
	return float(value >> 8u) * (1.0 / 16777216.0);
}
#endif

uint VoxelGridHashBits(uint value) {
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	value ^= value >> 16u;
	return value;
}

vec3 VoxelGridMaterialColor(const in uint payload) {
	uint materialId = VoxelGridMaterial(payload);
	uvec3 bits = uvec3(
		VoxelGridHashBits(materialId + 0x68bc21ebu),
		VoxelGridHashBits(materialId + 0x02e5be93u),
		VoxelGridHashBits(materialId + 0x967a889bu)
	);
	vec3 color = vec3(bits & uvec3(1023u)) / 1023.0;
	return 0.18 + color * 0.82;
}

bool VoxelGridFindNearby(
	const in ivec3 center,
	out uint payload,
	out int cellDistance
) {
	payload = 0u;
	cellDistance = 100;
	for (int z = -1; z <= 1; ++z) {
		for (int y = -1; y <= 1; ++y) {
			for (int x = -1; x <= 1; ++x) {
				ivec3 offset = ivec3(x, y, z);
				ivec3 candidate = center + offset;
				if (!VoxelGridInside(candidate)) {
					continue;
				}
				uint candidatePayload = VoxelGridLoad(candidate);
				int candidateDistance = abs(x) + abs(y) + abs(z);
				if (
					VoxelGridOccupied(candidatePayload) &&
					candidateDistance < cellDistance
				) {
					payload = candidatePayload;
					cellDistance = candidateDistance;
				}
			}
		}
	}
	return VoxelGridOccupied(payload);
}

bool VoxelGridRayBox(
	const in vec3 rayOrigin,
	const in vec3 rayDirection,
	out float entryDistance,
	out float exitDistance
) {
	entryDistance = 0.0;
	exitDistance = 1.0e30;
	for (int axis = 0; axis < 3; ++axis) {
		float originAxis = rayOrigin[axis];
		float directionAxis = rayDirection[axis];
		if (abs(directionAxis) < 1.0e-7) {
			if (
				originAxis < 0.0 ||
				originAxis >= float(VOXEL_GRID_SIZE)
			) {
				return false;
			}
			continue;
		}

		float firstDistance = (0.0 - originAxis) / directionAxis;
		float secondDistance =
			(float(VOXEL_GRID_SIZE) - originAxis) / directionAxis;
		if (firstDistance > secondDistance) {
			float temporaryDistance = firstDistance;
			firstDistance = secondDistance;
			secondDistance = temporaryDistance;
		}
		entryDistance = max(entryDistance, firstDistance);
		exitDistance = min(exitDistance, secondDistance);
		if (exitDistance < entryDistance) {
			return false;
		}
	}
	return exitDistance >= max(entryDistance, 0.0);
}

bool VoxelGridTraceAdvanced(
	const in vec3 rayOrigin,
	const in vec3 inputDirection,
	const in float maximumDistance,
	const in int maximumIterations,
	const in bool skipOriginCell,
	out uint hitPayload,
	out float hitDistance,
	out ivec3 hitCell,
	out vec3 hitNormal
) {
	hitPayload = 0u;
	hitDistance = 0.0;
	hitCell = ivec3(-1);
	hitNormal = vec3(0.0);

	float directionLength = length(inputDirection);
	if (directionLength < 1.0e-7) {
		return false;
	}
	vec3 rayDirection = inputDirection / directionLength;

	float entryDistance;
	float exitDistance;
	if (!VoxelGridRayBox(
		rayOrigin,
		rayDirection,
		entryDistance,
		exitDistance
	)) {
		return false;
	}

	float traceStart = max(entryDistance, 0.0);
	float traceEnd = min(exitDistance, maximumDistance);
	if (traceEnd < traceStart) {
		return false;
	}

	vec3 startPosition = rayOrigin +
		rayDirection * (traceStart + 1.0e-4);
	startPosition = clamp(
		startPosition,
		vec3(0.0),
		vec3(float(VOXEL_GRID_SIZE)) - vec3(1.0e-4)
	);
	ivec3 cell = ivec3(floor(startPosition));
	ivec3 cellStep = ivec3(sign(rayDirection));
	vec3 stepDistance = vec3(1.0e30);
	vec3 nextDistance = vec3(1.0e30);
	for (int axis = 0; axis < 3; ++axis) {
		if (abs(rayDirection[axis]) < 1.0e-7) {
			continue;
		}
		stepDistance[axis] = abs(1.0 / rayDirection[axis]);
		float nextBoundary = cellStep[axis] > 0
			? float(cell[axis] + 1)
			: float(cell[axis]);
		nextDistance[axis] =
			(nextBoundary - rayOrigin[axis]) / rayDirection[axis];
	}

	float traveled = traceStart;
	bool firstCell = true;
	bool suppressFirstCell = skipOriginCell && traceStart <= 1.0e-4;
	vec3 cellEntryNormal = normalize(-rayDirection);
	for (int iteration = 0;
		iteration < FOXY_VOXEL_GI_TRACE_ITERATIONS;
		++iteration) {
		if (
			iteration >= maximumIterations ||
			!VoxelGridInside(cell) ||
			traveled > traceEnd
		) {
			break;
		}
		uint payload = VoxelGridLoad(cell);
		if (
			VoxelGridOccupied(payload) &&
			!(suppressFirstCell && firstCell)
		) {
			hitPayload = payload;
			hitDistance = traveled;
			hitCell = cell;
			hitNormal = cellEntryNormal;
			return true;
		}
		firstCell = false;

		float nextTravel = min(
			nextDistance.x,
			min(nextDistance.y, nextDistance.z)
		);
		if (nextTravel > traceEnd) {
			break;
		}
		bvec3 advance = lessThanEqual(
			nextDistance,
			vec3(nextTravel + 1.0e-6)
		);
		vec3 crossingNormal = vec3(0.0);
		if (advance.x) {
			cell.x += cellStep.x;
			nextDistance.x += stepDistance.x;
			crossingNormal.x = -float(cellStep.x);
		}
		if (advance.y) {
			cell.y += cellStep.y;
			nextDistance.y += stepDistance.y;
			crossingNormal.y = -float(cellStep.y);
		}
		if (advance.z) {
			cell.z += cellStep.z;
			nextDistance.z += stepDistance.z;
			crossingNormal.z = -float(cellStep.z);
		}
		cellEntryNormal = normalize(crossingNormal);
		traveled = nextTravel;
	}
	return false;
}

bool VoxelGridTrace(
	const in vec3 rayOrigin,
	const in vec3 inputDirection,
	const in float maximumDistance,
	out uint hitPayload,
	out float hitDistance,
	out ivec3 hitCell
) {
	vec3 unusedHitNormal;
	return VoxelGridTraceAdvanced(
		rayOrigin,
		inputDirection,
		maximumDistance,
		224,
		false,
		hitPayload,
		hitDistance,
		hitCell,
		unusedHitNormal
	);
}

#endif
