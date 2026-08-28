#ifndef FOXY_VRTGI_FALLBACK_GLSL
#define FOXY_VRTGI_FALLBACK_GLSL

float VrtgiReceiverDomainWeight(
	const in vec3 originPlayerPosition,
	const in vec3 cameraWorldPosition
) {
	vec3 gridPosition = originPlayerPosition + fract(cameraWorldPosition) +
		vec3(FOXY_VOXEL_GRID_HALF_SIZE);
	if (
		any(lessThan(gridPosition, vec3(0.0))) ||
		any(greaterThanEqual(gridPosition, vec3(float(FOXY_VOXEL_GRID_SIZE))))
	) {
		return 0.0;
	}
	vec3 voxelEdge = min(
		gridPosition,
		vec3(float(FOXY_VOXEL_GRID_SIZE)) - gridPosition
	);
	float voxelBoxFade = smoothstep(
		2.0,
		10.0,
		min(voxelEdge.x, min(voxelEdge.y, voxelEdge.z))
	);
	float traceRange = max(FOXY_VOXEL_GI_MAX_DISTANCE, 1.0);
	float rangeFadeWidth = clamp(traceRange * 0.125, 2.0, 6.0);
	float voxelRangeFade = 1.0 - smoothstep(
		max(traceRange - rangeFadeWidth, 0.0),
		traceRange,
		length(originPlayerPosition)
	);
	return voxelBoxFade * voxelRangeFade;
}

// Deterministic, direction-independent fallback in VXGI's 1/8 storage scale.
vec3 VrtgiReceiverFallbackRadiance(
	const in vec2 lightmap,
	const in vec3 worldNormal,
	const in vec3 skyFluence
) {
	float blockLevel = Saturate(lightmap.x);
	// Missing-cache lightmap fallback is spectrally neutral.
	vec3 radiance = vec3(blockLevel * blockLevel * 0.18) *
		FOXY_VOXEL_GI_EMITTER_BRIGHTNESS * FOXY_VXGI_EMITTER_CALIBRATION;

	vec3 skyMeanRadiance = max(skyFluence, vec3(0.0)) / (2.0 * PI);
	float skyMeanLuma = dot(max(skyMeanRadiance, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
	vec3 neutralSkyMeanRadiance = mix(
		skyMeanRadiance,
		vec3(skyMeanLuma),
		Saturate(FOXY_SKY_AMBIENT_NEUTRALITY)
	) * FOXY_SKY_AMBIENT_LIFT;
	float skyVisibility = Saturate(
		(1.0 - pow(max(1.0 - Saturate(lightmap.y * 1.07) * 0.9, 0.0), 0.7))
	);
	skyVisibility = Saturate(skyVisibility * skyVisibility * skyVisibility * 1.95 * 4.44);
	float skyFacing = Saturate(worldNormal.y * 0.5 + 0.5);

	#if defined(FOXY_DIM_NETHER)
		neutralSkyMeanRadiance = max(
			neutralSkyMeanRadiance,
			NetherEnvironmentFluence() * 4.0
		);
		skyVisibility = 1.0;
		skyFacing = 1.0;
	#elif defined(FOXY_DIM_END)
		neutralSkyMeanRadiance = max(
			neutralSkyMeanRadiance,
			EndEnvironmentFluence() * 0.75
		);
		skyVisibility = 1.0;
	#endif

	radiance += neutralSkyMeanRadiance * skyVisibility * skyFacing *
		FOXY_VOXEL_GI_SKY_BRIGHTNESS;
	return radiance * (1.0 / 8.0);
}

#endif
