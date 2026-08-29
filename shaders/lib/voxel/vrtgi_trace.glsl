const float FOXY_VOXEL_GI_SPHERE_RADIUS = 0.34;

const int FOXY_VOXEL_GI_TRACE_SURFACE_HIT = 0;
const int FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT = 1;
const int FOXY_VOXEL_GI_TRACE_DISTANCE_LIMIT = 2;
const int FOXY_VOXEL_GI_TRACE_STEP_LIMIT = 3;
const int FOXY_VOXEL_GI_TRACE_INVALID = 4;

float VoxelGiSphereChordWeight(
	const in vec3 rayOrigin,
	const in vec3 rayDirection,
	const in vec3 sphereCenter,
	const in float segmentStart,
	const in float segmentEnd
) {
	vec3 originFromCenter = rayOrigin - sphereCenter;
	float projectedOrigin = dot(originFromCenter, rayDirection);
	float discriminant = projectedOrigin * projectedOrigin -
		(dot(originFromCenter, originFromCenter) -
		FOXY_VOXEL_GI_SPHERE_RADIUS * FOXY_VOXEL_GI_SPHERE_RADIUS);
	if (discriminant <= 0.0) return 0.0;

	float root = sqrt(discriminant);
	float sphereEntry = -projectedOrigin - root;
	float sphereExit = -projectedOrigin + root;
	float chord = max(
		min(sphereExit, segmentEnd) - max(sphereEntry, segmentStart),
		0.0
	);
	return Saturate(chord / (2.0 * FOXY_VOXEL_GI_SPHERE_RADIUS));
}

int VoxelGiTrace(
	const in vec3 rayOrigin,
	const in vec3 inputDirection,
	const in float maximumDistance,
	const in int maximumIterations,
	const in bool skipOriginCell,
	out uint hitPayload,
	out float hitDistance,
	out ivec3 hitCell,
	out vec3 hitNormal,
	out vec3 sphereRadiance,
	out vec3 rayTransmittance
) {
	hitPayload = 0u;
	hitDistance = 0.0;
	hitCell = ivec3(-1);
	hitNormal = vec3(0.0);
	sphereRadiance = vec3(0.0);
	rayTransmittance = vec3(1.0);

	// Callers provide unit directions.
	if (dot(inputDirection, inputDirection) < 1.0e-14) {
		return FOXY_VOXEL_GI_TRACE_INVALID;
	}
	vec3 rayDirection = inputDirection;

	float entryDistance;
	float exitDistance;
	if (!VoxelGridRayBox(
		rayOrigin,
		rayDirection,
		entryDistance,
		exitDistance
	)) {
		return FOXY_VOXEL_GI_TRACE_INVALID;
	}

	float traceStart = max(entryDistance, 0.0);
	float traceEnd = min(exitDistance, maximumDistance);
	if (traceEnd < traceStart) return FOXY_VOXEL_GI_TRACE_INVALID;
	bool domainExitBeforeDistance = exitDistance <= maximumDistance + 1.0e-4;

	vec3 startPosition = rayOrigin +
		rayDirection * (traceStart + 1.0e-4);
	startPosition = clamp(
		startPosition,
		vec3(0.0),
		vec3(float(VOXEL_GRID_SIZE)) - vec3(1.0e-4)
	);
	ivec3 cell = ivec3(floor(startPosition));
	ivec3 cellStep = ivec3(sign(rayDirection));
	bvec3 parallelDirection = lessThan(abs(rayDirection), vec3(1.0e-7));
	vec3 inverseDirection = vec3(0.0);
	vec3 stepDistance = vec3(1.0e30);
	vec3 nextDistance = vec3(1.0e30);
	for (int axis = 0; axis < 3; ++axis) {
		if (parallelDirection[axis]) continue;
		inverseDirection[axis] = 1.0 / rayDirection[axis];
		stepDistance[axis] = abs(inverseDirection[axis]);
		float nextBoundary = cellStep[axis] > 0
			? float(cell[axis] + 1)
			: float(cell[axis]);
		nextDistance[axis] =
			(nextBoundary - rayOrigin[axis]) * inverseDirection[axis];
	}

	float traveled = traceStart;
	bool firstCell = true;
	bool suppressFirstCell = skipOriginCell && traceStart <= 1.0e-4;
	vec3 cellEntryNormal = -rayDirection;
	const bool hierarchyEnabled = VoxelHierarchyEnabled();
	for (int iteration = 0; iteration < maximumIterations; ++iteration) {
		float nextTravel = min(
			nextDistance.x,
			min(nextDistance.y, nextDistance.z)
		);
		if (hierarchyEnabled) {
			int skipSize = VoxelHierarchyEmptySize(cell);
			if (skipSize > 0) {
				ivec3 blockBase = (cell / skipSize) * skipSize;
				ivec3 boundaryCount = ivec3(0);
				if (cellStep.x > 0) {
					boundaryCount.x = blockBase.x + skipSize - cell.x;
				} else if (cellStep.x < 0) {
					boundaryCount.x = cell.x - blockBase.x + 1;
				}
				if (cellStep.y > 0) {
					boundaryCount.y = blockBase.y + skipSize - cell.y;
				} else if (cellStep.y < 0) {
					boundaryCount.y = cell.y - blockBase.y + 1;
				}
				if (cellStep.z > 0) {
					boundaryCount.z = blockBase.z + skipSize - cell.z;
				} else if (cellStep.z < 0) {
					boundaryCount.z = cell.z - blockBase.z + 1;
				}
				vec3 hierarchyExit = vec3(1.0e30);
				if (boundaryCount.x > 0) {
					hierarchyExit.x = nextDistance.x +
						float(boundaryCount.x - 1) * stepDistance.x;
				}
				if (boundaryCount.y > 0) {
					hierarchyExit.y = nextDistance.y +
						float(boundaryCount.y - 1) * stepDistance.y;
				}
				if (boundaryCount.z > 0) {
					hierarchyExit.z = nextDistance.z +
						float(boundaryCount.z - 1) * stepDistance.z;
				}
				float hierarchyTravel = min(
					hierarchyExit.x,
					min(hierarchyExit.y, hierarchyExit.z)
				);
				bvec3 hierarchyAdvance = lessThanEqual(
					hierarchyExit,
					vec3(hierarchyTravel + 1.0e-5)
				);
				int tiedAxes = int(hierarchyAdvance.x) +
					int(hierarchyAdvance.y) + int(hierarchyAdvance.z);
				if (tiedAxes == 1 && hierarchyTravel > traveled + 1.0e-6) {
					if (hierarchyTravel > traceEnd) {
						if (domainExitBeforeDistance) {
							hitDistance = exitDistance;
							return FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT;
						}
						return FOXY_VOXEL_GI_TRACE_DISTANCE_LIMIT;
					}
					if (
						domainExitBeforeDistance &&
						hierarchyTravel >= exitDistance - 1.0e-5
					) {
						hitDistance = exitDistance;
						return FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT;
					}
					for (int jump = 0; jump < 8; ++jump) {
						if (
							cellStep.x == 0 ||
							nextDistance.x > hierarchyTravel + 1.0e-6
						) break;
						cell.x += cellStep.x;
						nextDistance.x += stepDistance.x;
					}
					for (int jump = 0; jump < 8; ++jump) {
						if (
							cellStep.y == 0 ||
							nextDistance.y > hierarchyTravel + 1.0e-6
						) break;
						cell.y += cellStep.y;
						nextDistance.y += stepDistance.y;
					}
					for (int jump = 0; jump < 8; ++jump) {
						if (
							cellStep.z == 0 ||
							nextDistance.z > hierarchyTravel + 1.0e-6
						) break;
						cell.z += cellStep.z;
						nextDistance.z += stepDistance.z;
					}
					vec3 crossingNormal = vec3(
						hierarchyAdvance.x ? -float(cellStep.x) : 0.0,
						hierarchyAdvance.y ? -float(cellStep.y) : 0.0,
						hierarchyAdvance.z ? -float(cellStep.z) : 0.0
					);
					cellEntryNormal = crossingNormal;
					traveled = hierarchyTravel;
					firstCell = false;
					continue;
				}
			}
		}
		float cellSegmentEnd = min(nextTravel, traceEnd);
		uint payload = VoxelGridLoadUnchecked(cell);
		if (VoxelGridOccupied(payload)) {
			uint materialId = VoxelGridMaterial(payload);
			if (VoxelSphereEmitterMaterial(materialId)) {
				// Small emitters are participating spheres, not cell occluders.
				float chordWeight = VoxelGiSphereChordWeight(
					rayOrigin,
					rayDirection,
					vec3(cell) + vec3(0.5),
					traveled,
					cellSegmentEnd
				);
				if (chordWeight > 0.0) {
					sphereRadiance += rayTransmittance *
						VoxelGiEmission(payload) * chordWeight;
				}
			} else {
				int shapeDescriptor = VoxelShapeDescriptorForPayload(
					materialId,
					payload
				);
				bool analyticShape = shapeDescriptor >= 0;
				bool paneShape = TransmissionIsPaneUint(materialId);
				float cellSegmentStart = traveled;
				float shapeHitDistance = cellSegmentStart;
				vec3 shapeHitNormal = cellEntryNormal;
				bool shapeHit = true;
				if (paneShape) {
					shapeHit = VoxelShapeAnyHit(
						shapeDescriptor,
						rayOrigin,
						inverseDirection,
						parallelDirection,
						cell,
						cellSegmentStart,
						cellSegmentEnd
					);
				} else if (analyticShape) {
					shapeHit = VoxelShapeTrace(
						shapeDescriptor,
						rayOrigin,
						rayDirection,
						inverseDirection,
						parallelDirection,
						cell,
						cellSegmentStart,
						cellSegmentEnd,
						shapeHitDistance,
						shapeHitNormal
					);
				}
				// Transmission follows material class, not shape descriptor ordering.
				bool glassHit = shapeHit && (
					paneShape ||
					(materialId >= 10300u && materialId <= 10316u)
				);
				if (glassHit) {
					// Accumulate pane transmission in traversal order.
					rayTransmittance *= TransmissionColor(float(materialId));
				} else if (
					shapeHit &&
					// Analytic shapes remain valid in the origin cell after coarse self-hit suppression.
					!(suppressFirstCell && firstCell && !analyticShape)
				) {
					hitPayload = payload;
					hitDistance = shapeHitDistance;
					hitCell = cell;
					vec3 storedFaceNormal = VoxelAxisNormal(payload);
					hitNormal = VoxelGiStoredFaceNormalMaterial(materialId) &&
						dot(storedFaceNormal, storedFaceNormal) > 0.5
						? storedFaceNormal
						: (analyticShape ? shapeHitNormal : cellEntryNormal);
					return FOXY_VOXEL_GI_TRACE_SURFACE_HIT;
				}
			}
		}
		firstCell = false;

		if (nextTravel > traceEnd) {
			if (domainExitBeforeDistance) {
				hitDistance = exitDistance;
				return FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT;
			}
			return FOXY_VOXEL_GI_TRACE_DISTANCE_LIMIT;
		}
		// Ray-box clipping guarantees the start cell; terminate at the exact exit plane.
		if (
			domainExitBeforeDistance &&
			nextTravel >= exitDistance - 1.0e-5
		) {
			hitDistance = exitDistance;
			return FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT;
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
		// Preserve multi-axis steps only for exact edge and corner crossings.
		float crossingLengthSquared = dot(crossingNormal, crossingNormal);
		cellEntryNormal = crossingLengthSquared > 1.0001
			? crossingNormal * inversesqrt(crossingLengthSquared)
			: crossingNormal;
		traveled = nextTravel;
	}
	return FOXY_VOXEL_GI_TRACE_STEP_LIMIT;
}

