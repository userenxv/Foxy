// Probe sampling and dimension-specific lighting. Included after the trace
// library and update constants; owns no dispatch or output entry point.
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


#if defined(FOXY_DIM_NETHER)
float IrcProbeSkyVisibility(const in ivec3 cell) {
	#if defined(FOXY_DIM_NETHER)
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
#elif defined(FOXY_DIM_END)
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
#else
float IrcProbeSkyVisibility(const in ivec3 cell) {
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
#endif


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


#if defined(FOXY_DIM_NETHER)
float IrcDirectVisibility(
	const in vec3 gridPosition,
	const in vec3 hitNormal,
	const in float lightNoL,
	out vec3 transmission
) {
	transmission = vec3(1.0);
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
	transmission = ShadowTransmissionTint(texture2D(shadowcolor0, shadowCoord.xy));
	return Saturate(shadowVisibility);
}
#elif defined(FOXY_DIM_END)
float IrcDirectVisibility(
	const in vec3 gridPosition,
	const in vec3 hitNormal,
	const in float lightNoL,
	out vec3 transmission
) {
	transmission = vec3(1.0);
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
	vec3 receiverPosition = scenePosition + hitNormal * normalOffset;
	vec4 shadowClip = FoEndShadowProjection(shadowProjection) * shadowModelView *
		vec4(FoEndShadowAimFromView(shadowModelView) * receiverPosition, 1.0);
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
	transmission = ShadowTransmissionTint(texture2D(shadowcolor0, shadowCoord.xy));
	return Saturate(shadowVisibility);
}
#else
float IrcDirectVisibility(
	const in vec3 gridPosition,
	const in vec3 hitNormal,
	const in float lightNoL,
	out vec3 transmission
) {
	transmission = vec3(1.0);
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
	transmission = ShadowTransmissionTint(texture2D(shadowcolor0, shadowCoord.xy));
	return Saturate(shadowVisibility);
}
#endif



#if defined(FOXY_DIM_NETHER)
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
	#if defined(FOXY_DIM_NETHER)
		neutralRadiance = max(
			neutralRadiance,
			NetherEnvironmentFluence()
		);
	#endif
	return neutralRadiance;
}
#elif defined(FOXY_DIM_END)
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
	return FoxyIndirectColorTemperature(neutralRadiance);
}
#else
vec3 IrcNeutralSkyMeanRadiance() {
	vec3 skyUpperHemisphereFluence = DecodeBufferColor(texelFetch(
		colortex7,
		SkyUpperHemisphereFluenceTexel(),
		0
	).rgb);
	vec3 skyMeanRadiance = max(skyUpperHemisphereFluence, vec3(0.0)) /
		(2.0 * PI);
	float skyMeanLuminance = dot(skyMeanRadiance, vec3(0.2126, 0.7152, 0.0722));
	return mix(
		skyMeanRadiance,
		vec3(skyMeanLuminance),
		Saturate(FOXY_SKY_AMBIENT_NEUTRALITY)
	) * FOXY_SKY_AMBIENT_LIFT;
}
#endif



#if defined(FOXY_DIM_NETHER)
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
	if (traceResult == FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT) {
		rayDistance = hitDistance;
		#if defined(FOXY_DIM_NETHER)
			directRadiance = sampleRadiance + rayTransmittance *
				neutralSkyMeanRadiance * probeSkyVisibility *
				FOXY_VOXEL_GI_SKY_BRIGHTNESS *
				FOXY_IRRADIANCE_CACHE_SKY_BRIGHTNESS;
			return directRadiance;
		#endif
		float topExit = step(
			float(VOXEL_GRID_SIZE) - 1.0e-3,
			probePosition.y + rayDirection.y * hitDistance
		);
		if (topExit <= 0.0) {
			directRadiance = sampleRadiance;
			return directRadiance;
		}
		float skyWeight = probeSkyVisibility;
		vec3 skyRadiance = DecodeBufferColor(texture2D(
			colortex7,
			SsptSkyLutUv(rayDirection)
		).rgb) * FOXY_VOXEL_GI_SKY_BRIGHTNESS *
			FOXY_IRRADIANCE_CACHE_SKY_BRIGHTNESS;
		directRadiance = sampleRadiance + rayTransmittance *
			max(skyRadiance, vec3(0.0)) * skyWeight;
		return directRadiance;
	}
	if (traceResult != FOXY_VOXEL_GI_TRACE_SURFACE_HIT) {
		rayDistance = FOXY_IRC_TRACE_DISTANCE;
		float skyHemisphere = Saturate(rayDirection.y * 25.0 + 0.5);
		#if defined(FOXY_DIM_NETHER)
			skyHemisphere = 1.0;
		#endif
		directRadiance = sampleRadiance + rayTransmittance *
			neutralSkyMeanRadiance * skyHemisphere * probeSkyVisibility *
			FOXY_VOXEL_GI_SKY_BRIGHTNESS *
			FOXY_IRRADIANCE_CACHE_SKY_BRIGHTNESS;
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
	float directLightCosine = max(
		dot(hitNormal, directLightWorldDirection),
		0.0
	);
	vec3 directLightTransmission = vec3(1.0);
	float directLightVisibility = directLightAltitude > 0.001 &&
		directLightCosine > 0.001
		? IrcDirectVisibility(
			hitPosition,
			hitNormal,
			directLightCosine,
			directLightTransmission
		)
		: 0.0;
	vec3 directLightRadiance = DecodeBufferColor(texelFetch(
		colortex7,
		SkyDirectSunColorTexel(),
		0
	).rgb) * directLightTransmission;
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
	vec3 recurrentIrradiance = frameCounter > 0
		? IrcPreviousDirectWorld(hitWorldCell, hitNormal, frameCounter)
		: vec3(0.0);
	vec3 secondBounce = rayTransmittance * surfaceAlbedo * recurrentIrradiance;
	return directRadiance + secondBounce;
	#else
	return directRadiance;
	#endif
}
#elif defined(FOXY_DIM_END)
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
			#if defined(FOXY_DIM_END)
				vec3 skyRadiance = neutralSkyMeanRadiance *
					FOXY_VOXEL_GI_SKY_BRIGHTNESS *
					FOXY_IRRADIANCE_CACHE_SKY_BRIGHTNESS;
			#else
				vec3 skyRadiance = FoxyIndirectColorTemperature(
					DecodeBufferColor(texture2D(
						colortex7,
						SsptSkyLutUv(rayDirection)
					).rgb) * FOXY_VOXEL_GI_SKY_BRIGHTNESS *
						FOXY_IRRADIANCE_CACHE_SKY_BRIGHTNESS
				);
			#endif
			directRadiance += rayTransmittance *
				max(skyRadiance, vec3(0.0)) * skyWeight;
		}
		return directRadiance;
	}
	if (traceResult != FOXY_VOXEL_GI_TRACE_SURFACE_HIT) {
		rayDistance = FOXY_IRC_TRACE_DISTANCE;

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
		bool directLightCandidate = directLightCosine > 0.001;
		vec3 directLightTransmission = vec3(1.0);
		float directLightVisibility = directLightCandidate
			? IrcDirectVisibility(
				hitPosition,
				hitNormal,
				directLightCosine,
				directLightTransmission
			)
			: 0.0;
		vec3 directLightRadiance = directLightVisibility > 0.0
			? EndLightAligned(vec3(0.62, 0.72, 1.00)) * directLightTransmission
			: vec3(0.0);
	#else
		bool directLightCandidate = directLightAltitude > 0.001 &&
			directLightCosine > 0.001 && skyLight >= (0.5 / 15.0);
		vec3 directLightTransmission = vec3(1.0);
		float directLightVisibility = directLightCandidate
			? IrcDirectVisibility(
				hitPosition,
				hitNormal,
				directLightCosine,
				directLightTransmission
			)
			: 0.0;
		vec3 directLightRadiance = vec3(0.0);
		if (directLightVisibility > 0.0) {
			directLightRadiance = DecodeBufferColor(texelFetch(
				colortex7,
				SkyDirectSunColorTexel(),
				0
			).rgb) * directLightTransmission;
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
	vec3 recurrentIrradiance = frameCounter > 0
		? IrcPreviousDirectWorld(hitWorldCell, hitNormal, frameCounter)
		: vec3(0.0);
	vec3 secondBounce = rayTransmittance * surfaceAlbedo * recurrentIrradiance;
	return directRadiance + secondBounce;
	#else
	return directRadiance;
	#endif
}
#else
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
	float directLightCosine = max(
		dot(hitNormal, directLightWorldDirection),
		0.0
	);
	bool directLightCandidate = directLightAltitude > 0.001 &&
		directLightCosine > 0.001 && skyLight >= (0.5 / 15.0);
	vec3 directLightTransmission = vec3(1.0);
	float directLightVisibility = directLightCandidate
		? IrcDirectVisibility(
			hitPosition,
			hitNormal,
			directLightCosine,
			directLightTransmission
		)
		: 0.0;
	vec3 directLightRadiance = vec3(0.0);
	if (directLightVisibility > 0.0) {
		directLightRadiance = DecodeBufferColor(texelFetch(
			colortex7,
			SkyDirectSunColorTexel(),
			0
		).rgb) * directLightTransmission;
	}
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
	vec3 recurrentIrradiance = frameCounter > 0
		? IrcPreviousDirectWorld(hitWorldCell, hitNormal, frameCounter)
		: vec3(0.0);
	vec3 secondBounce = rayTransmittance * surfaceAlbedo * recurrentIrradiance;
	return directRadiance + secondBounce;
	#else
	return directRadiance;
	#endif
}
#endif


