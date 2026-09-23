// Shared dimension entry implementation. Keep dimension-specific transport branches.
#define FOXY_SSPT_TRACE_LIBRARY_ONLY
#include "/program/sspt_trace.csh"

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1

#include "/lib/celestial.glsl"
#include "/lib/shadow.glsl"

#include "/lib/voxel/irc_dispatch.glsl"

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(32768, 1, 1);
const float FOXY_IRC_TRACE_DISTANCE = FOXY_VOXEL_GI_MAX_DISTANCE;
const int FOXY_IRC_TRACE_STEPS = FOXY_VOXEL_GI_TRACE_ITERATIONS;
const int FOXY_IRC_INITIAL_SAMPLES_PER_PROBE = 8;
const int FOXY_IRC_REFRESH_SAMPLES_PER_PROBE = 2;
const float FOXY_IRC_CONVERGED_SAMPLE_COUNT = 512.0;
#include "/features/voxel/irc_probe_sampling.glsl"

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

	float previousCount = frameCounter > 0
		? IrcLoadPreviousSampleCount(worldCell, frameCounter)
		: 0.0;
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
	uint sequenceBase = previousCount < FOXY_IRC_CONVERGED_SAMPLE_COUNT
		? uint(previousCount)
		: uint(max(frameCounter, 0)) *
			uint(FOXY_IRC_REFRESH_SAMPLES_PER_PROBE);
	vec4 sequenceRotation = vec4(
		IrcHashFloat(randomSeed + 0x9e3779b9u),
		IrcHashFloat(randomSeed + 0x85ebca6bu),
		IrcHashFloat(randomSeed + 0xc2b2ae35u),
		IrcHashFloat(randomSeed + 0x27d4eb2fu)
	);
	for (int sampleIndex = 0; sampleIndex < samplesPerProbe; ++sampleIndex) {
		uint sampleOrdinal = sequenceBase + uint(sampleIndex);
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
	IrcEntry previousEntry = frameCounter > 0
		? IrcPreviousWorldEntry(worldCell)
		: IrcEmptyEntry();
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
