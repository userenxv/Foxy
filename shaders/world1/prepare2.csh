#version 430

#define FOXY_DIM_END
#define FOXY_SSPT_TRACE_LIBRARY_ONLY
#include "/program/sspt_trace.csh"

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1

#include "/lib/celestial.glsl"
#include "/lib/shadow.glsl"

layout(std430, binding = 3) coherent buffer IrradianceFeedback {
	uint ircActiveCount;
	uint ircActiveCells[];
};

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(8192, 1, 1);
const float FOXY_IRC_TRACE_DISTANCE = FOXY_VOXEL_GI_MAX_DISTANCE;
const int FOXY_IRC_TRACE_STEPS = FOXY_VOXEL_GI_TRACE_ITERATIONS;
const int FOXY_IRC_INITIAL_SAMPLES_PER_PROBE = 8;
const int FOXY_IRC_REFRESH_SAMPLES_PER_PROBE = 2;
const float FOXY_IRC_CONVERGED_SAMPLE_COUNT = 512.0;
const ivec3 FOXY_IRC_SUPPORT_TILE_SIZE = ivec3(10, 6, 6);
const uint FOXY_IRC_SUPPORT_TILE_COUNT = 360u;
const uint FOXY_IRC_SUPPORT_ROW_COUNT = 36u;
shared uint ircSupportTile[360];
shared uint ircOccupancyRows[36];
shared uint ircDilatedYRows[36];
shared uint ircSupportRows[36];

uint IrcSupportTileIndex(const in ivec3 cell) {
	return uint(cell.x + FOXY_IRC_SUPPORT_TILE_SIZE.x *
		(cell.y + FOXY_IRC_SUPPORT_TILE_SIZE.y * cell.z));
}

uint IrcSupportTileLoad(const in ivec3 cell) {
	return ircSupportTile[IrcSupportTileIndex(cell)];
}

void IrcLoadSupportTile() {
	ivec3 workGroupBase = ivec3(gl_WorkGroupID) * ivec3(8, 4, 4) +
		FOXY_IRC_GRID_OFFSET - ivec3(1);
	for (
		uint tileIndex = gl_LocalInvocationIndex;
		tileIndex < FOXY_IRC_SUPPORT_TILE_COUNT;
		tileIndex += 128u
	) {
		int x = int(tileIndex % uint(FOXY_IRC_SUPPORT_TILE_SIZE.x));
		uint yz = tileIndex / uint(FOXY_IRC_SUPPORT_TILE_SIZE.x);
		int y = int(yz % uint(FOXY_IRC_SUPPORT_TILE_SIZE.y));
		int z = int(yz / uint(FOXY_IRC_SUPPORT_TILE_SIZE.y));
		ivec3 sourceCell = workGroupBase + ivec3(x, y, z);
		uint payload = VoxelGridInside(sourceCell)
			? VoxelGridLoadUnchecked(sourceCell)
			: 0u;
		ircSupportTile[tileIndex] = payload;
	}
	memoryBarrierShared();
	barrier();
	if (gl_LocalInvocationIndex < FOXY_IRC_SUPPORT_ROW_COUNT) {
		uint rowIndex = gl_LocalInvocationIndex;
		uint row = 0u;
		uint tileBase = rowIndex * 10u;
		for (uint x = 0u; x < 10u; ++x) {
			if (VoxelGridTopologyOccupied(ircSupportTile[tileBase + x])) {
				row |= 1u << x;
			}
		}
		ircOccupancyRows[rowIndex] = row;
	}
	memoryBarrierShared();
	barrier();
	if (gl_LocalInvocationIndex < FOXY_IRC_SUPPORT_ROW_COUNT) {
		uint rowIndex = gl_LocalInvocationIndex;
		int y = int(rowIndex % 6u);
		uint row = ircOccupancyRows[rowIndex];
		if (y > 0) row |= ircOccupancyRows[rowIndex - 1u];
		if (y < 5) row |= ircOccupancyRows[rowIndex + 1u];
		ircDilatedYRows[rowIndex] = row | (row << 1u) | (row >> 1u);
	}
	memoryBarrierShared();
	barrier();
	if (gl_LocalInvocationIndex < FOXY_IRC_SUPPORT_ROW_COUNT) {
		uint rowIndex = gl_LocalInvocationIndex;
		int z = int(rowIndex / 6u);
		uint row = ircDilatedYRows[rowIndex];
		if (z > 0) row |= ircDilatedYRows[rowIndex - 6u];
		if (z < 5) row |= ircDilatedYRows[rowIndex + 6u];
		ircSupportRows[rowIndex] = row;
	}
	memoryBarrierShared();
	barrier();
}

bool IrcSharedProbeInsideOpaque(const in ivec3 tileCell) {
	uint payload = IrcSupportTileLoad(tileCell);
	return VoxelGridTopologyOccupied(payload);
}

bool IrcSharedProbeHasSurfaceSupport(const in ivec3 tileCell) {
	uint rowIndex = uint(tileCell.y + 6 * tileCell.z);
	return (ircSupportRows[rowIndex] & (1u << uint(tileCell.x))) != 0u;
}

uint IrcHash(uint value) {
	value ^= value >> 16u;
	value *= 0x7feb352du;
	value ^= value >> 15u;
	value *= 0x846ca68bu;
	value ^= value >> 16u;
	return value;
}

float IrcHashFloat(const in uint value) {
	return float(IrcHash(value) >> 8u) * (1.0 / 16777216.0);
}

uint IrcWorldHash(const in ivec3 worldCell) {
	uint hashValue = uint(worldCell.x) * 73856093u;
	hashValue ^= uint(worldCell.y) * 19349663u;
	hashValue ^= uint(worldCell.z) * 83492791u;
	return IrcHash(hashValue);
}

vec3 IrcUniformSphereDirection(
	const in vec2 sequence
) {
	float z = 1.0 - 2.0 * sequence.x;
	float phi = 2.0 * PI * sequence.y;
	float radius = sqrt(max(1.0 - z * z, 0.0));
	return vec3(radius * cos(phi), z, radius * sin(phi));
}

bool IrcProbeSurfaceNormal(
	const in ivec3 cell,
	out vec3 surfaceNormal
) {
	const ivec3 offsets[6] = ivec3[6](
		ivec3(-1, 0, 0), ivec3(1, 0, 0),
		ivec3(0, -1, 0), ivec3(0, 1, 0),
		ivec3(0, 0, -1), ivec3(0, 0, 1)
	);
	vec3 occupiedGradient = vec3(0.0);
	for (int index = 0; index < 6; ++index) {
		ivec3 neighbor = cell + offsets[index];
		if (!VoxelGridInside(neighbor)) continue;
		if (VoxelGridTopologyOccupied(VoxelGridLoadUnchecked(neighbor))) {
			occupiedGradient += vec3(offsets[index]);
		}
	}
	float gradientLength = length(occupiedGradient);
	surfaceNormal = gradientLength > 1.0e-5
		? -occupiedGradient / gradientLength
		: vec3(0.0, 1.0, 0.0);
	return gradientLength > 1.0e-5;
}

vec3 IrcCosineHemisphereDirection(
	const in vec2 sequence,
	const in vec3 surfaceNormal
) {
	float radius = sqrt(sequence.x);
	float phi = 2.0 * PI * sequence.y;
	vec3 localDirection = vec3(
		radius * cos(phi),
		radius * sin(phi),
		sqrt(max(1.0 - sequence.x, 0.0))
	);
	vec3 helper = abs(surfaceNormal.y) < 0.9
		? vec3(0.0, 1.0, 0.0)
		: vec3(1.0, 0.0, 0.0);
	vec3 tangent = normalize(cross(helper, surfaceNormal));
	vec3 bitangent = cross(surfaceNormal, tangent);
	return normalize(
		tangent * localDirection.x +
		bitangent * localDirection.y +
		surfaceNormal * localDirection.z
	);
}

bool IrcProbeInsideOpaque(const in ivec3 cell) {
	uint payload = VoxelGridLoadUnchecked(cell);
	return VoxelGridTopologyOccupied(payload);
}

bool IrcProbeHasSurfaceSupport(const in ivec3 cell) {
	for (int z = -1; z <= 1; ++z) {
		for (int y = -1; y <= 1; ++y) {
			for (int x = -1; x <= 1; ++x) {
				ivec3 neighbor = cell + ivec3(x, y, z);
				if (!VoxelGridInside(neighbor)) continue;
				if (VoxelGridTopologyOccupied(VoxelGridLoadUnchecked(neighbor))) {
					return true;
				}
			}
		}
	}
	return false;
}

float IrcProbeSkyVisibility(const in ivec3 cell) {
	#if defined(FOXY_DIM_END)
		return 1.0;
	#endif
	const ivec3 offsets[7] = ivec3[7](
		ivec3(0, 0, 0),
		ivec3(-1, 0, 0), ivec3(1, 0, 0),
		ivec3(0, -1, 0), ivec3(0, 1, 0),
		ivec3(0, 0, -1), ivec3(0, 0, 1)
	);
	float skyLight = 0.0;
	for (int index = 0; index < 7; ++index) {
		ivec3 candidate = cell + offsets[index];
		if (!VoxelGridInside(candidate)) continue;
		uint payload = VoxelGridLoadUnchecked(candidate);
		if (!VoxelGridTopologyOccupied(payload)) continue;
		skyLight = max(skyLight, VoxelSkyLight(payload));
	}
	return VoxelGiSkyVisibility(skyLight);
}

IrcEntry IrcPreviousWorldEntry(const in ivec3 worldCell) {
	ivec3 previousCell = worldCell -
		IrcPreviousWorldBase(previousCameraPosition);
	return IrcLoadPrevious(
		previousCell + FOXY_IRC_GRID_OFFSET,
		frameCounter
	);
}

IrcEntry IrcPreviousWorldDirectEntry(const in ivec3 worldCell) {
	ivec3 previousCell = worldCell -
		IrcPreviousWorldBase(previousCameraPosition);
	return IrcLoadPreviousDirect(
		previousCell + FOXY_IRC_GRID_OFFSET,
		frameCounter
	);
}

vec3 IrcSamplePreviousWorld(
	const in vec3 currentGridPosition,
	const in vec3 surfaceNormal,
	out float confidence
) {
	vec3 worldPosition = currentGridPosition - vec3(FOXY_IRC_GRID_OFFSET) +
		vec3(IrcCurrentWorldBase(cameraPosition));
	vec3 previousGridPosition = worldPosition -
		vec3(IrcPreviousWorldBase(previousCameraPosition)) +
		vec3(FOXY_IRC_GRID_OFFSET);
	return IrcSampleGridDirect(
		previousGridPosition,
		surfaceNormal,
		previousCameraPosition,
		frameCounter - 1,
		confidence
	);
}

float IrcDirectVisibility(
	const in vec3 gridPosition,
	const in vec3 hitNormal,
	const in float lightNoL
) {
	float projectionScale = max(abs(shadowProjection[0][0]), 1.0e-6);
	float worldTexel = 2.0 /
		(float(FOXY_SHADOW_RESOLUTION) * projectionScale);
	float grazing = 1.0 - smoothstep(0.035, 0.32, lightNoL);
	float normalOffset = clamp(
		worldTexel * (0.24 + grazing * 0.62),
		0.018,
		0.180
	);
	vec3 scenePosition = gridPosition - fract(cameraPosition) -
		vec3(FOXY_VOXEL_GRID_HALF_SIZE);
	vec4 shadowClip = shadowProjection * shadowModelView *
		vec4(scenePosition + hitNormal * normalOffset, 1.0);
	if (abs(shadowClip.w) < 1.0e-7) return 0.0;
	vec3 shadowNdc = shadowClip.xyz / shadowClip.w;
	vec3 shadowCoord = vec3(ShadowWarp(shadowNdc.xy), shadowNdc.z) *
		0.5 + vec3(0.5);
	if (any(lessThanEqual(shadowCoord, vec3(0.0))) ||
		any(greaterThanEqual(shadowCoord, vec3(1.0)))) {
		return 0.0;
	}
	float receiverBias = mix(0.00034, 0.000055, Saturate(lightNoL));
	float shadowVisibility = textureLod(
		shadowtex1,
		vec3(shadowCoord.xy, shadowCoord.z - receiverBias),
		0.0
	);
	return Saturate(shadowVisibility);
}

vec3 IrcNeutralSkyMeanRadiance() {
	vec3 skyUpperHemisphereFluence = DecodeBufferColor(texelFetch(
		colortex7,
		SkyUpperHemisphereFluenceTexel(),
		0
	).rgb);
	vec3 skyMeanRadiance = max(skyUpperHemisphereFluence, vec3(0.0)) /
		(2.0 * PI);
	float skyMeanLuminance = dot(skyMeanRadiance, vec3(0.2126, 0.7152, 0.0722));
	vec3 neutralRadiance = mix(
		skyMeanRadiance,
		vec3(skyMeanLuminance),
		Saturate(FOXY_SKY_AMBIENT_NEUTRALITY)
	) * FOXY_SKY_AMBIENT_LIFT;
	#if defined(FOXY_DIM_END)
		neutralRadiance = max(
			neutralRadiance,
			EndEnvironmentFluence() * 0.5
		);
	#endif
	return neutralRadiance;
}

vec3 IrcTraceSample(
	const in vec3 probePosition,
	const in vec3 rayDirection,
	const in float probeSkyVisibility,
	const in vec3 neutralSkyMeanRadiance,
	out float rayDistance,
	out vec3 directRadiance
) {
	uint hitPayload;
	float hitDistance;
	ivec3 hitCell;
	vec3 hitNormal;
	vec3 sphereRadiance;
	vec3 rayTransmittance;
	int traceResult = VoxelGiTrace(
		probePosition,
		rayDirection,
		FOXY_IRC_TRACE_DISTANCE,
		FOXY_IRC_TRACE_STEPS,
		false,
		hitPayload,
		hitDistance,
		hitCell,
		hitNormal,
		sphereRadiance,
		rayTransmittance
	);
	vec3 sampleRadiance = sphereRadiance *
		FOXY_IRRADIANCE_CACHE_BLOCK_BRIGHTNESS;
	bool environmentTerminal =
		traceResult == FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT ||
		traceResult == FOXY_VOXEL_GI_TRACE_DISTANCE_LIMIT;
	if (environmentTerminal) {
		rayDistance = traceResult == FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT
			? hitDistance
			: FOXY_IRC_TRACE_DISTANCE;
		float skyWeight = Saturate(rayDirection.y * 25.0 + 0.5) *
			probeSkyVisibility;
		directRadiance = sampleRadiance;
		if (skyWeight > 0.0) {
			vec3 skyRadiance = DecodeBufferColor(texture2D(
				colortex7,
				SsptSkyLutUv(rayDirection)
			).rgb) * FOXY_VOXEL_GI_SKY_BRIGHTNESS *
				FOXY_IRRADIANCE_CACHE_SKY_BRIGHTNESS;
			directRadiance += rayTransmittance *
				max(skyRadiance, vec3(0.0)) * skyWeight;
		}
		return directRadiance;
	}
	if (traceResult != FOXY_VOXEL_GI_TRACE_SURFACE_HIT) {
		rayDistance = FOXY_IRC_TRACE_DISTANCE;
		// Trace-budget exhaustion is not an environment escape.
		directRadiance = sampleRadiance;
		return directRadiance;
	}

	rayDistance = hitDistance;
	vec3 hitPosition = probePosition + rayDirection * hitDistance;
	vec3 surfaceAlbedo = VoxelGiAlbedo(hitPayload);
	float skyLight = VoxelSkyLight(hitPayload);

	vec3 unitUpView = normalize(upPosition);
	vec3 directLightView = normalize(shadowLightPosition);
	vec3 directLightWorldDirection = normalize(
		mat3(gbufferModelViewInverse) * directLightView
	);
	float directLightAltitude = dot(directLightView, unitUpView);
	#if defined(FOXY_DIM_END)
		directLightWorldDirection = EndSunWorldDirection();
		directLightAltitude = 0.86602540;
	#endif
	float directLightCosine = max(
		dot(hitNormal, directLightWorldDirection),
		0.0
	);
	#if defined(FOXY_DIM_END)
		float directLightVisibility = directLightCosine > 0.001 ? 1.0 : 0.0;
		vec3 directLightRadiance = vec3(0.62, 0.72, 1.00);
	#else
		bool directLightCandidate = directLightAltitude > 0.001 &&
			directLightCosine > 0.001 && skyLight >= (0.5 / 15.0);
		float directLightVisibility = directLightCandidate
			? IrcDirectVisibility(hitPosition, hitNormal, directLightCosine)
			: 0.0;
		vec3 directLightRadiance = vec3(0.0);
		if (directLightVisibility > 0.0) {
			directLightRadiance = DecodeBufferColor(texelFetch(
				colortex7,
				SkyDirectSunColorTexel(),
				0
			).rgb);
		}
	#endif
	vec3 hitRadiance = VoxelGiHitRadiance(
		hitPayload,
		surfaceAlbedo,
		hitNormal,
		skyLight,
		neutralSkyMeanRadiance,
		directLightRadiance,
		directLightCosine,
		directLightVisibility,
		true,
		FOXY_IRRADIANCE_CACHE_BLOCK_BRIGHTNESS,
		FOXY_IRRADIANCE_CACHE_SKY_BRIGHTNESS
	);
	directRadiance = sampleRadiance + rayTransmittance *
		max(hitRadiance, vec3(0.0));
	#if FOXY_VXGI_TRUE_SECONDARY_BOUNCE == 1
	ivec3 hitAirCell = ivec3(floor(hitPosition + hitNormal * 0.08));
	ivec3 hitWorldCell = IrcCurrentWorldBase(cameraPosition) +
		hitAirCell - FOXY_IRC_GRID_OFFSET;
	IrcEntry recurrentEntry = frameCounter > 0
		? IrcPreviousWorldEntry(hitWorldCell)
		: IrcEmptyEntry();
	vec3 recurrentIrradiance = IrcEvaluateDirect(recurrentEntry, hitNormal);
	vec3 secondBounce = rayTransmittance * surfaceAlbedo * recurrentIrradiance;
	return directRadiance + secondBounce;
	#else
	return directRadiance;
	#endif
}

void main() {
	uint activeIndex = gl_GlobalInvocationID.x;
	if (activeIndex >= ircActiveCount) return;
	uint linearCell = ircActiveCells[activeIndex];
	ivec3 cacheCell = ivec3(
		int(linearCell & 127u),
		int((linearCell >> 7u) & 127u),
		int(linearCell >> 14u)
	) + FOXY_IRC_GRID_OFFSET;
	ivec3 worldCell = IrcCurrentWorldBase(cameraPosition) +
		cacheCell - FOXY_IRC_GRID_OFFSET;

	IrcEntry previousEntry = frameCounter > 0
		? IrcPreviousWorldEntry(worldCell)
		: IrcEmptyEntry();
	float previousCount = previousEntry.sampleCount;
	vec3 neutralSkyMeanRadiance = IrcNeutralSkyMeanRadiance();
	float currentSkySignature = dot(
		neutralSkyMeanRadiance,
		vec3(0.2126, 0.7152, 0.0722)
	);
	int samplesPerProbe = previousCount < FOXY_IRC_CONVERGED_SAMPLE_COUNT
		? FOXY_IRC_INITIAL_SAMPLES_PER_PROBE
		: FOXY_IRC_REFRESH_SAMPLES_PER_PROBE;
	uint randomSeed = IrcWorldHash(worldCell);
	float probeSkyVisibility = IrcProbeSkyVisibility(cacheCell);
	vec3 probePosition = IrcProbePosition(cacheCell);
	vec3 probeSurfaceNormal;
	bool hasProbeSurfaceNormal = IrcProbeSurfaceNormal(
		cacheCell,
		probeSurfaceNormal
	);
	float surfaceSamplingWeight = hasProbeSurfaceNormal ? 0.75 : 0.0;
	vec3 sampleRadiance = vec3(0.0);
	vec3 sampleMoment = vec3(0.0);
	vec3 positiveWeight = vec3(0.0);
	vec3 positiveDistance = vec3(0.0);
	vec3 positiveDistanceSecond = vec3(0.0);
	vec3 negativeWeight = vec3(0.0);
	vec3 negativeDistance = vec3(0.0);
	vec3 negativeDistanceSecond = vec3(0.0);
	vec3 samplePositiveIrradianceX = vec3(0.0);
	vec3 samplePositiveIrradianceY = vec3(0.0);
	vec3 samplePositiveIrradianceZ = vec3(0.0);
	vec3 sampleNegativeIrradianceX = vec3(0.0);
	vec3 sampleNegativeIrradianceY = vec3(0.0);
	vec3 sampleNegativeIrradianceZ = vec3(0.0);
	vec3 samplePositiveDirectIrradianceX = vec3(0.0);
	vec3 samplePositiveDirectIrradianceY = vec3(0.0);
	vec3 samplePositiveDirectIrradianceZ = vec3(0.0);
	vec3 sampleNegativeDirectIrradianceX = vec3(0.0);
	vec3 sampleNegativeDirectIrradianceY = vec3(0.0);
	vec3 sampleNegativeDirectIrradianceZ = vec3(0.0);
	for (int sampleIndex = 0; sampleIndex < samplesPerProbe; ++sampleIndex) {
		uint sequenceBase = previousCount < FOXY_IRC_CONVERGED_SAMPLE_COUNT
			? uint(previousCount)
			: uint(max(frameCounter, 0)) *
				uint(FOXY_IRC_REFRESH_SAMPLES_PER_PROBE);
		uint sampleOrdinal = sequenceBase + uint(sampleIndex);
		vec4 sequenceRotation = vec4(
			IrcHashFloat(randomSeed + 0x9e3779b9u),
			IrcHashFloat(randomSeed + 0x85ebca6bu),
			IrcHashFloat(randomSeed + 0xc2b2ae35u),
			IrcHashFloat(randomSeed + 0x27d4eb2fu)
		);
		vec4 sampleSequence = fract(
			vec4(0.5) + sequenceRotation + float(sampleOrdinal) * vec4(
				0.8566748838545030,
				0.7338918566271260,
				0.6287067210378090,
				0.5385972572236100
			)
		);
		vec3 rayDirection = sampleSequence.z < surfaceSamplingWeight
			? IrcCosineHemisphereDirection(
				sampleSequence.xy,
				probeSurfaceNormal
			)
			: IrcUniformSphereDirection(sampleSequence.xy);
		float uniformPdf = 1.0 / (4.0 * PI);
		float cosinePdf = max(dot(probeSurfaceNormal, rayDirection), 0.0) /
			PI;
		float samplePdf = mix(
			uniformPdf,
			cosinePdf,
			surfaceSamplingWeight
		);
		float sphereEstimatorWeight = 1.0 /
			max(4.0 * PI * samplePdf, 1.0e-6);
		float irradianceEstimatorWeight = 1.0 /
			max(PI * samplePdf, 1.0e-6);
		float rayDistance;
		vec3 rayDirectRadiance;
		vec3 rayRadiance = clamp(
			IrcTraceSample(
				probePosition,
				rayDirection,
				probeSkyVisibility,
				neutralSkyMeanRadiance,
				rayDistance,
				rayDirectRadiance
			),
			vec3(0.0),
			vec3(FOXY_IRC_MAX_RADIANCE)
		);
		float rayLuminance = dot(rayRadiance, vec3(0.2126, 0.7152, 0.0722));
		sampleRadiance += rayRadiance * sphereEstimatorWeight;
		sampleMoment += rayDirection * rayLuminance * sphereEstimatorWeight;
		vec3 positiveLobe = max(rayDirection, vec3(0.0));
		vec3 negativeLobe = max(-rayDirection, vec3(0.0));
		positiveLobe *= positiveLobe;
		positiveLobe *= positiveLobe;
		negativeLobe *= negativeLobe;
		negativeLobe *= negativeLobe;
		positiveLobe *= sphereEstimatorWeight;
		negativeLobe *= sphereEstimatorWeight;
		positiveWeight += positiveLobe;
		positiveDistance += positiveLobe * rayDistance;
		positiveDistanceSecond += positiveLobe * rayDistance * rayDistance;
		negativeWeight += negativeLobe;
		negativeDistance += negativeLobe * rayDistance;
		negativeDistanceSecond += negativeLobe * rayDistance * rayDistance;
		vec3 positiveCosine = max(rayDirection, vec3(0.0));
		vec3 negativeCosine = max(-rayDirection, vec3(0.0));
		positiveCosine *= irradianceEstimatorWeight;
		negativeCosine *= irradianceEstimatorWeight;
		samplePositiveIrradianceX += rayRadiance * positiveCosine.x;
		samplePositiveIrradianceY += rayRadiance * positiveCosine.y;
		samplePositiveIrradianceZ += rayRadiance * positiveCosine.z;
		sampleNegativeIrradianceX += rayRadiance * negativeCosine.x;
		sampleNegativeIrradianceY += rayRadiance * negativeCosine.y;
		sampleNegativeIrradianceZ += rayRadiance * negativeCosine.z;
		rayDirectRadiance = clamp(
			rayDirectRadiance,
			vec3(0.0),
			vec3(FOXY_IRC_MAX_RADIANCE)
		);
		samplePositiveDirectIrradianceX += rayDirectRadiance * positiveCosine.x;
		samplePositiveDirectIrradianceY += rayDirectRadiance * positiveCosine.y;
		samplePositiveDirectIrradianceZ += rayDirectRadiance * positiveCosine.z;
		sampleNegativeDirectIrradianceX += rayDirectRadiance * negativeCosine.x;
		sampleNegativeDirectIrradianceY += rayDirectRadiance * negativeCosine.y;
		sampleNegativeDirectIrradianceZ += rayDirectRadiance * negativeCosine.z;
	}
	float inverseSampleCount = 1.0 / float(samplesPerProbe);
	sampleRadiance *= inverseSampleCount;
	sampleMoment *= inverseSampleCount;
	float irradianceNormalization = inverseSampleCount;
	samplePositiveIrradianceX *= irradianceNormalization;
	samplePositiveIrradianceY *= irradianceNormalization;
	samplePositiveIrradianceZ *= irradianceNormalization;
	sampleNegativeIrradianceX *= irradianceNormalization;
	sampleNegativeIrradianceY *= irradianceNormalization;
	sampleNegativeIrradianceZ *= irradianceNormalization;
	samplePositiveDirectIrradianceX *= irradianceNormalization;
	samplePositiveDirectIrradianceY *= irradianceNormalization;
	samplePositiveDirectIrradianceZ *= irradianceNormalization;
	sampleNegativeDirectIrradianceX *= irradianceNormalization;
	sampleNegativeDirectIrradianceY *= irradianceNormalization;
	sampleNegativeDirectIrradianceZ *= irradianceNormalization;
	vec3 positiveValid = step(vec3(1.0e-5), positiveWeight);
	vec3 negativeValid = step(vec3(1.0e-5), negativeWeight);
	vec3 batchPositiveMean = mix(
		previousEntry.positiveVisibilityMean,
		positiveDistance / max(positiveWeight, vec3(1.0e-5)),
		positiveValid
	);
	vec3 batchPositiveSecond = mix(
		previousEntry.positiveVisibilitySecond,
		positiveDistanceSecond / max(positiveWeight, vec3(1.0e-5)),
		positiveValid
	);
	vec3 batchNegativeMean = mix(
		previousEntry.negativeVisibilityMean,
		negativeDistance / max(negativeWeight, vec3(1.0e-5)),
		negativeValid
	);
	vec3 batchNegativeSecond = mix(
		previousEntry.negativeVisibilitySecond,
		negativeDistanceSecond / max(negativeWeight, vec3(1.0e-5)),
		negativeValid
	);
	float batchSampleCount = float(samplesPerProbe);
	float accumulatedFrames = previousCount < FOXY_IRC_CONVERGED_SAMPLE_COUNT
		? previousCount / float(FOXY_IRC_INITIAL_SAMPLES_PER_PROBE)
		: float(FOXY_IRRADIANCE_CACHE_HISTORY_FRAMES);
	float previousSkySignature = max(previousEntry.skyLuminance, 0.0);
	float relativeSkyChange = abs(
		currentSkySignature - previousSkySignature
	) / max(max(currentSkySignature, previousSkySignature), 1.0e-4);
	float skyResponse = smoothstep(0.05, 0.25, relativeSkyChange);
	float responsiveHistoryFrames = mix(
		float(FOXY_IRRADIANCE_CACHE_HISTORY_FRAMES),
		16.0,
		skyResponse
	);
	float historyAge = min(
		accumulatedFrames + 1.0,
		responsiveHistoryFrames
	);
	float blendCurrent = 1.0 / max(historyAge, 1.0);
	IrcEntry currentEntry;
	currentEntry.radiance = mix(
		previousEntry.radiance,
		sampleRadiance,
		blendCurrent
	);
	currentEntry.directionMoment = mix(
		previousEntry.directionMoment,
		sampleMoment,
		blendCurrent
	);
	currentEntry.sampleCount = min(
		previousCount + batchSampleCount,
		FOXY_IRC_CONVERGED_SAMPLE_COUNT
	);
	currentEntry.skyLuminance = mix(
		previousSkySignature,
		currentSkySignature,
		blendCurrent
	);
	currentEntry.positiveVisibilityMean = mix(
		previousEntry.positiveVisibilityMean,
		batchPositiveMean,
		blendCurrent
	);
	currentEntry.positiveVisibilitySecond = mix(
		previousEntry.positiveVisibilitySecond,
		batchPositiveSecond,
		blendCurrent
	);
	currentEntry.negativeVisibilityMean = mix(
		previousEntry.negativeVisibilityMean,
		batchNegativeMean,
		blendCurrent
	);
	currentEntry.negativeVisibilitySecond = mix(
		previousEntry.negativeVisibilitySecond,
		batchNegativeSecond,
		blendCurrent
	);
	currentEntry.positiveIrradianceX = mix(
		previousEntry.positiveIrradianceX,
		samplePositiveIrradianceX,
		blendCurrent
	);
	currentEntry.positiveIrradianceY = mix(
		previousEntry.positiveIrradianceY,
		samplePositiveIrradianceY,
		blendCurrent
	);
	currentEntry.positiveIrradianceZ = mix(
		previousEntry.positiveIrradianceZ,
		samplePositiveIrradianceZ,
		blendCurrent
	);
	currentEntry.negativeIrradianceX = mix(
		previousEntry.negativeIrradianceX,
		sampleNegativeIrradianceX,
		blendCurrent
	);
	currentEntry.negativeIrradianceY = mix(
		previousEntry.negativeIrradianceY,
		sampleNegativeIrradianceY,
		blendCurrent
	);
	currentEntry.negativeIrradianceZ = mix(
		previousEntry.negativeIrradianceZ,
		sampleNegativeIrradianceZ,
		blendCurrent
	);
	currentEntry.positiveDirectIrradianceX = mix(
		previousEntry.positiveDirectIrradianceX,
		samplePositiveDirectIrradianceX,
		blendCurrent
	);
	currentEntry.positiveDirectIrradianceY = mix(
		previousEntry.positiveDirectIrradianceY,
		samplePositiveDirectIrradianceY,
		blendCurrent
	);
	currentEntry.positiveDirectIrradianceZ = mix(
		previousEntry.positiveDirectIrradianceZ,
		samplePositiveDirectIrradianceZ,
		blendCurrent
	);
	currentEntry.negativeDirectIrradianceX = mix(
		previousEntry.negativeDirectIrradianceX,
		sampleNegativeDirectIrradianceX,
		blendCurrent
	);
	currentEntry.negativeDirectIrradianceY = mix(
		previousEntry.negativeDirectIrradianceY,
		sampleNegativeDirectIrradianceY,
		blendCurrent
	);
	currentEntry.negativeDirectIrradianceZ = mix(
		previousEntry.negativeDirectIrradianceZ,
		sampleNegativeDirectIrradianceZ,
		blendCurrent
	);
	IrcStoreCurrent(cacheCell, currentEntry, frameCounter);
}

#else

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);
void main() {}

#endif
