#include "/lib/settings.glsl"

#ifndef FOXY_SSPT_TRACE_LIBRARY_ONLY
#if FOXY_VOXEL_GI_ACTIVE == 1
	#if defined MC_GL_VENDOR_AMD

		layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
	#else
		layout(local_size_x = 8, local_size_y = 4, local_size_z = 1) in;
	#endif
#else
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#endif
#if FOXY_VOXEL_TRACING == 1 && FOXY_VRTGI_TEMPORAL_INTERLEAVE == 1
const vec2 workGroupsRender = vec2(
	FOXY_RAY_RESOLUTION * 0.5,
	FOXY_RAY_RESOLUTION
);
#else
const vec2 workGroupsRender = vec2(
	FOXY_RAY_RESOLUTION,
	FOXY_RAY_RESOLUTION
);
#endif
#endif

#ifndef FOXY_SSPT_TRACE_LIBRARY_ONLY
layout(rgba16f) writeonly uniform image2D img_ptTrace;
#if FOXY_SSPT == 1
layout(rgba16f) uniform image2D img_ptHistoryA;
layout(rgba16f) uniform image2D img_ptHistoryB;
layout(rgba16f) uniform image2D img_ptHistoryMetaA;
layout(rgba16f) uniform image2D img_ptHistoryMetaB;
#endif
#endif

#ifndef FOXY_SSPT_TRACE_EXTERNAL_UNIFORMS
uniform sampler2D colortex0;
uniform sampler2D colortex2;
uniform sampler2D colortex7;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform sampler3D cloudStbnVec2;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform float near;
uniform float far;
uniform float viewWidth;
uniform float viewHeight;
uniform vec2 temporalJitter;
uniform vec2 previousTemporalJitter;
uniform int frameCounter;
	#if FOXY_VOXEL_TRACING == 1 || defined(FOXY_SSPT_TRACE_LIBRARY_ONLY)
		uniform vec3 sunPosition;
		uniform vec3 moonPosition;
		uniform vec3 upPosition;
		uniform vec3 shadowLightPosition;
		uniform mat4 shadowModelView;
		uniform mat4 shadowProjection;
		uniform sampler2DShadow shadowtex1;
		uniform sampler2D shadowcolor0;
#endif
#endif

#include "/features/ray/trace_lighting.glsl"

#ifndef FOXY_SSPT_TRACE_LIBRARY_ONLY
ivec2 SsptClosestPrimaryPixel(
	const in ivec2 tracePixel,
	const in ivec2 traceSize,
	const in ivec2 renderSize,
	out float bestDepth,
	out int bestCornerIndex
) {
	ivec2 minimumPixel;
	ivec2 maximumPixel;
	SrRayCellPixelBounds(
		tracePixel,
		traceSize,
		renderSize,
		minimumPixel,
		maximumPixel
	);
	ivec2 bestPixel = minimumPixel;
	bestDepth = texelFetch(depthtex0, bestPixel, 0).r;
	bestCornerIndex = 0;
	for (int cornerIndex = 1; cornerIndex < 4; cornerIndex++) {
		bool usesMaximumX = (cornerIndex & 1) != 0;
		bool usesMaximumY = (cornerIndex & 2) != 0;
		if (usesMaximumX && maximumPixel.x == minimumPixel.x) continue;
		if (usesMaximumY && maximumPixel.y == minimumPixel.y) continue;
		ivec2 candidatePixel = ivec2(
			usesMaximumX ? maximumPixel.x : minimumPixel.x,
			usesMaximumY ? maximumPixel.y : minimumPixel.y
		);
		float candidateDepth = texelFetch(depthtex0, candidatePixel, 0).r;
		if (candidateDepth < bestDepth) {
			bestDepth = candidateDepth;
			bestPixel = candidatePixel;
			bestCornerIndex = cornerIndex;
		}
	}
	return bestPixel;
}

#if FOXY_SSPT == 1
vec4 SsptPreviousSignal(const in ivec2 pixel) {
	if ((frameCounter % 2) == 0) return imageLoad(img_ptHistoryB, pixel);
	return imageLoad(img_ptHistoryA, pixel);
}

vec4 SsptPreviousMeta(const in ivec2 pixel) {
	if ((frameCounter % 2) == 0) return imageLoad(img_ptHistoryMetaB, pixel);
	return imageLoad(img_ptHistoryMetaA, pixel);
}

void SsptFeedbackTap(
	const in ivec2 pixel,
	const in ivec2 historySize,
	const in float bilinearWeight,
	const in vec3 hitNormal,
	const in float expectedDepth,
	inout vec3 radianceSum,
	inout float weightSum
) {
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, historySize))) return;
	vec4 historyMeta = SsptPreviousMeta(pixel);
	float markerValid = RtDenoiserMetaValid(historyMeta);
	vec3 historyNormal = PtDecodeOctNormal(historyMeta.xy);
	float normalWeight = smoothstep(0.82, 0.975, dot(hitNormal, historyNormal));
	float relativeDepthError = abs(historyMeta.z - expectedDepth) / max(expectedDepth, 0.25);
	float depthWeight = 1.0 - smoothstep(0.004, 0.030, relativeDepthError);
	float guideWeight = bilinearWeight * markerValid * normalWeight * depthWeight;
	if (guideWeight <= 1.0e-5) return;
	vec4 historySignal = SsptPreviousSignal(pixel);
	float ageValid = step(0.5, historySignal.a) * (1.0 - step(257.5, historySignal.a));
	float weight = guideWeight * ageValid;
	if (weight <= 1.0e-5) return;
	radianceSum += max(historySignal.rgb, vec3(0.0)) * weight;
	weightSum += weight;
}

vec3 SsptPreviousIndirect(
	const in vec3 hitWorldPosition,
	const in vec3 hitNormal
) {
	vec3 cameraDelta = cameraPosition - previousCameraPosition;
	if (frameCounter < 2 || dot(cameraDelta, cameraDelta) > 64.0) return vec3(0.0);
	vec3 previousPlayerPosition = hitWorldPosition - previousCameraPosition;
	vec4 previousView = gbufferPreviousModelView * vec4(previousPlayerPosition, 1.0);
	if (previousView.z >= -0.02) return vec3(0.0);
	vec4 previousClip = gbufferPreviousProjection * previousView;
	if (previousClip.w <= 0.02) return vec3(0.0);
	vec2 previousUv = previousClip.xy / previousClip.w * 0.5 + 0.5;
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		previousUv += previousTemporalJitter * 0.5;
	#endif
	if (any(lessThanEqual(previousUv, vec2(0.001))) || any(greaterThanEqual(previousUv, vec2(0.999)))) return vec3(0.0);

	ivec2 historySize = SrActiveRaySceneSize(imageSize(img_ptHistoryA));
	vec2 historyPosition = previousUv * vec2(historySize) - vec2(0.5);
	ivec2 historyBase = ivec2(floor(historyPosition));
	vec2 fractionValue = fract(historyPosition);
	vec3 radianceSum = vec3(0.0);
	float weightSum = 0.0;
	for (int tapIndex = 0; tapIndex < 4; tapIndex++) {
		ivec2 offset = ivec2(tapIndex % 2, tapIndex / 2);
		vec2 axisWeight = mix(vec2(1.0) - fractionValue, fractionValue, vec2(offset));
		SsptFeedbackTap(
			historyBase + offset,
			historySize,
			axisWeight.x * axisWeight.y,
			hitNormal,
			-previousView.z,
			radianceSum,
			weightSum
		);
	}
	float support = smoothstep(0.12, 0.52, weightSum);
	return weightSum > 1.0e-5 ? radianceSum / weightSum * support : vec3(0.0);
}
#endif

void main() {
	ivec2 traceSize = SrActiveRaySceneSize(imageSize(img_ptTrace));
	#if FOXY_IRC_MODE == 1
		ivec2 ircPixel = ivec2(gl_GlobalInvocationID.xy);
		if (any(greaterThanEqual(ircPixel, traceSize))) return;

		imageStore(img_ptTrace, ircPixel, vec4(0.0));
		return;
	#endif
	ivec2 tracePixel;
	#if FOXY_VOXEL_TRACING == 1 && FOXY_VRTGI_TEMPORAL_INTERLEAVE == 1
		ivec2 compactPixel = ivec2(gl_GlobalInvocationID.xy);
		ivec2 compactSize = ivec2((traceSize.x + 1) / 2, traceSize.y);
		if (any(greaterThanEqual(compactPixel, compactSize))) return;
		tracePixel = ivec2(compactPixel.x * 2 + (frameCounter & 1), compactPixel.y);
	#else
		tracePixel = ivec2(gl_GlobalInvocationID.xy);
	#endif
	if (any(greaterThanEqual(tracePixel, traceSize))) return;

	ivec2 renderSize = max(ivec2(SrRenderSize()), ivec2(1));
	float primaryDepthRaw;
	int primaryCornerIndex;
	ivec2 primaryPixel = SsptClosestPrimaryPixel(
		tracePixel,
		traceSize,
		renderSize,
		primaryDepthRaw,
		primaryCornerIndex
	);
	vec4 primarySurface = texelFetch(colortex2, primaryPixel, 0);
	PtGbufferSample primaryGbuffer = PtDecodeGbuffer(primarySurface, primaryDepthRaw);
	if (primaryGbuffer.valid < 0.5) {
		imageStore(img_ptTrace, tracePixel, vec4(0.0, 0.0, 0.0, -1.0));
		return;
	}

	vec2 primaryViewUv = SsptViewUvFromRenderPixel(primaryPixel);
	vec3 primaryViewPos = SsptViewPosFromDepth(primaryViewUv, primaryDepthRaw);
	vec3 viewNormal = normalize(mat3(gbufferModelView) * primaryGbuffer.worldGeometricNormal);
	float originBias = max(0.025, SsptLinearDepth(primaryDepthRaw) * 0.00065);
	vec3 originViewPos = primaryViewPos + viewNormal * originBias;
	vec3 originPlayerPos = (gbufferModelViewInverse * vec4(originViewPos, 1.0)).xyz;

	#if FOXY_RAY_MODE == FOXY_RAY_RSM
		// Raw single-bounce estimate only. History belongs to the shared temporal pass,
		// so this branch must not touch img_ptHistory*.
		vec3 rsmSignal = RsmGather(
			originPlayerPos,
			primaryGbuffer.worldGeometricNormal
		) * FOXY_RSM_INTENSITY;
		// Same packing as the traced path: the temporal preload recovers the owning
		// primary corner through RtDenoiserTracePrimaryOffsetIndex, and the payload has
		// to stay >= -0.99 so both the temporal ownership test and the composite read
		// treat the cell as valid.
		float rsmPackedState = 1.0 + float(primaryCornerIndex) * 4.0;
		imageStore(img_ptTrace, tracePixel, vec4(rsmSignal, rsmPackedState));
		return;
	#else

#if FOXY_VOXEL_TRACING == 1
	vec3 voxelRayOrigin = VoxelGridSceneToGrid(
		originPlayerPos,
		cameraPosition
	);
	float voxelTraceWeight = VrtgiReceiverDomainWeight(
		originPlayerPos,
		cameraPosition
	);

#if FOXY_SSPT == 0
	if (voxelTraceWeight <= 1.0e-5) {
		imageStore(
			img_ptTrace,
			tracePixel,
			vec4(0.0, 0.0, 0.0, -1.0 + float(primaryCornerIndex) * 4.0)
		);
		return;
	}
#endif
#endif

	vec3 radianceSum = vec3(0.0);
	float hitDistanceSum = 0.0;
	float hitCount = 0.0;
	float missCount = 0.0;
	float maximumRejection = 0.0;
	float ircFallbackCount = 0.0;
	vec3 ircEnvironmentFallbackSum = vec3(0.0);
	#if FOXY_VOXEL_TRACING == 1
		#if defined(FOXY_DIM_NETHER) || defined(FOXY_DIM_END)
		vec3 skyUpperHemisphereFluence = DecodeBufferColor(texelFetch(
			colortex7,
			SkyUpperHemisphereFluenceTexel(),
			0
		).rgb);
		vec3 skyMeanRadiance = max(skyUpperHemisphereFluence, vec3(0.0)) /
			(2.0 * PI);
		float skyMeanLuma = RtDenoiserLuma(skyMeanRadiance);
		vec3 neutralSkyMeanRadiance = mix(
			skyMeanRadiance,
			vec3(skyMeanLuma),
			Saturate(FOXY_SKY_AMBIENT_NEUTRALITY)
		) * FOXY_SKY_AMBIENT_LIFT;
	#endif
	#if defined(FOXY_DIM_NETHER)
		neutralSkyMeanRadiance = max(
			neutralSkyMeanRadiance,
			NetherEnvironmentFluence() * 4.0
		);
	#elif defined(FOXY_DIM_END)
		neutralSkyMeanRadiance = max(
			neutralSkyMeanRadiance,
			EndEnvironmentFluence() * 0.75
		);
	#else
		vec3 neutralSkyMeanRadiance = vec3(0.0);
	#endif
	float primarySkyVisibility = VoxelGiSkyVisibility(
		primaryGbuffer.lightmap.y
	);
	vec3 unitUpView = normalize(upPosition);
	vec3 voxelDirectLightView = normalize(shadowLightPosition);
	vec3 voxelDirectLightWorldDirection = normalize(
		mat3(gbufferModelViewInverse) * voxelDirectLightView
	);
	float voxelDirectLightAltitude = dot(
		voxelDirectLightView,
		unitUpView
	);
	bool voxelDirectLightCanContribute = voxelDirectLightAltitude > 0.001;
	vec3 voxelDirectLightRadiance = DecodeBufferColor(texelFetch(
		colortex7,
		SkyDirectSunColorTexel(),
		0
	).rgb);
	#if defined(FOXY_DIM_END)

		voxelDirectLightWorldDirection = EndSunWorldDirection();
		voxelDirectLightAltitude = 0.86602540;
		voxelDirectLightCanContribute = true;
		voxelDirectLightRadiance = EndLightAligned(vec3(0.62, 0.72, 1.00));
	#endif
#endif

	vec2 stbnValue = SsptTemporalSample(primaryPixel);

	for (int sampleIndex = 0; sampleIndex < FOXY_ACTIVE_GI_SPP; sampleIndex++) {
		float sampleValue = float(sampleIndex);

		vec2 sampleRotation = vec2(
			sampleValue / float(FOXY_ACTIVE_GI_SPP),
			0.61803398875 * sampleValue
		);
		vec2 randomValue = fract(stbnValue + sampleRotation);

		RayQuery query;
		query.worldOrigin = cameraPosition + originPlayerPos;
		query.worldDirection = SsptCosineDirection(primaryGbuffer.worldNormal, randomValue);

if (dot(query.worldDirection, primaryGbuffer.worldGeometricNormal) <= 0.0) {
			#if FOXY_RAY_MODE == FOXY_RAY_IRC_SSPT
				ircFallbackCount += 1.0;
			#else
			missCount += 1.0;
			#endif
			continue;
		}
		#if FOXY_VOXEL_TRACING == 1
			query.maxDistance = FOXY_VOXEL_GI_MAX_DISTANCE;
		#else
			query.maxDistance = FOXY_SSPT_MAX_DISTANCE;
		#endif
		query.coneWidth = 0.0;
		query.roughness = 1.0;
		query.lobe = RAY_LOBE_DIFFUSE;
		bool screenResolved = false;
		vec3 fallbackTransmittance = vec3(1.0);
		#if FOXY_SSPT == 1
			RayQuery screenQuery = query;

screenQuery.maxDistance = max(FOXY_SSPT_MAX_DISTANCE, far);
			ScreenTraceResult screenResult = TraceScreen(
				screenQuery,
				primaryPixel,
				sampleIndex
			);
			if (screenResult.hit.validity >= 0.5) {
				ivec2 hitPixel = SsptRenderPixelFromViewUv(screenResult.screenUv);
				vec3 hitRadiance = SsptScreenHitRadiance(hitPixel);
				#if FOXY_SSPT_EMISSIVE_FEEDBACK == 1
					screenResult.hit.emission = SsptReconstructEmission(screenResult.hit);
					float reconstructedPeak = max(
						max(screenResult.hit.emission.r, screenResult.hit.emission.g),
						screenResult.hit.emission.b
					);
					float reconstructedLuma = max(RtDenoiserLuma(screenResult.hit.emission), 0.0);
					float sceneLuma = max(RtDenoiserLuma(hitRadiance), 1.0e-5);
					vec3 boundedSurfaceLight = hitRadiance * min(
						1.0,
						reconstructedLuma * 0.12 / sceneLuma
					);
					float emitterDominance = smoothstep(0.002, 0.040, reconstructedPeak);
					hitRadiance = mix(
						hitRadiance,
						screenResult.hit.emission + boundedSurfaceLight,
						emitterDominance
					);
				#endif
				vec3 previousIncoming = SsptPreviousIndirect(
					screenResult.hit.worldPosition,
					screenResult.hit.worldNormal
				);
				hitRadiance += previousIncoming * screenResult.hit.albedo;
					radianceSum += min(
						max(hitRadiance, vec3(0.0)) * screenResult.transmittance *
							SsptSignalStorageScale(),
						vec3(64.0)
					);
				hitDistanceSum += max(screenResult.normalizedDistance, 1.0 / 65535.0);
				hitCount += 1.0;
				screenResolved = true;
			} else {
				maximumRejection = max(maximumRejection, screenResult.rejection);
				fallbackTransmittance = screenResult.transmittance;
				#if FOXY_RAY_MODE == FOXY_RAY_SSPT_VRTGI

if (screenResult.terminal > 0.5) {
						float screenSkyVisibility = SsptSkyLeakVisibility(
							primaryGbuffer.lightmap.y
						);
						radianceSum += SsptTerminalSkyRadiance(
							query.worldDirection,
							screenSkyVisibility,
							1.0
						) * screenResult.transmittance * SsptSignalStorageScale();
						missCount += 1.0;
						screenResolved = true;
					} else if (voxelTraceWeight <= 1.0e-5) {
						missCount += 1.0;
						screenResolved = true;
					}
				#elif FOXY_RAY_MODE == FOXY_RAY_IRC_SSPT

if (screenResult.terminal > 0.5) {
						float screenSkyVisibility = SsptSkyLeakVisibility(
							primaryGbuffer.lightmap.y
						);
						radianceSum += SsptTerminalSkyRadiance(
							query.worldDirection,
							screenSkyVisibility,
							1.0
						) * screenResult.transmittance * SsptSignalStorageScale();
						missCount += 1.0;
						screenResolved = true;
					} else {
						ircFallbackCount += 1.0;
					if (screenResult.viewportExit > 0.5) {
						float screenSkyVisibility = SsptSkyLeakVisibility(
							primaryGbuffer.lightmap.y
						);
						ircEnvironmentFallbackSum += SsptTerminalSkyRadiance(
							query.worldDirection,
							screenSkyVisibility,
							1.0
						) * screenResult.transmittance * SsptSignalStorageScale();
					}
					}
				#else
					float environmentEscape = max(
						screenResult.terminal,
						screenResult.viewportExit
					);
					missCount += environmentEscape;
					if (environmentEscape > 0.5) {
						float screenSkyVisibility = SsptSkyLeakVisibility(
							primaryGbuffer.lightmap.y
						);
						radianceSum += SsptTerminalSkyRadiance(
							query.worldDirection,
							screenSkyVisibility,
							1.0
						) * screenResult.transmittance;
					}
					screenResolved = true;
				#endif
			}
		#endif

		#if FOXY_VOXEL_TRACING == 1
		if (!screenResolved) {

			int distanceBoundedTraceSteps = min(
				FOXY_VOXEL_GI_TRACE_ITERATIONS,
				int(ceil(query.maxDistance * 1.75)) + 3
			);
			vec3 pathOrigin = voxelRayOrigin;
			vec3 pathDirection = query.worldDirection;
			vec3 pathThroughput = fallbackTransmittance;
			vec3 pathRadiance = vec3(0.0);
			float pathSkyVisibility = primarySkyVisibility;
			bool firstVoxelHit = false;
			float firstVoxelHitDistance = 0.0;

			for (
				int bounceIndex = 0;
				bounceIndex < 1 + FOXY_VXGI_TRUE_SECONDARY_BOUNCE;
				++bounceIndex
			) {
				uint voxelPayload;
				float voxelHitDistance;
				ivec3 voxelHitCell;
				vec3 voxelHitNormal;
				vec3 voxelSphereRadiance;
				vec3 voxelRayTransmittance;
				int voxelTraceResult = VoxelGiTrace(
					pathOrigin,
					pathDirection,
					query.maxDistance,
					distanceBoundedTraceSteps,
					true,
					voxelPayload,
					voxelHitDistance,
					voxelHitCell,
					voxelHitNormal,
					voxelSphereRadiance,
					voxelRayTransmittance
				);
				bool voxelHit = voxelTraceResult ==
					FOXY_VOXEL_GI_TRACE_SURFACE_HIT;
				pathRadiance += pathThroughput * voxelSphereRadiance;
				pathThroughput *= voxelRayTransmittance;

				if (!voxelHit) {

					#if defined(FOXY_DIM_NETHER)
						pathRadiance += pathThroughput * neutralSkyMeanRadiance *
							FOXY_VOXEL_GI_SKY_BRIGHTNESS;
					#elif defined(FOXY_DIM_END)
						pathRadiance += pathThroughput * neutralSkyMeanRadiance *
							Saturate(pathDirection.y * 25.0 + 0.5) *
							FOXY_VOXEL_GI_SKY_BRIGHTNESS;
					#else
						bool environmentTerminal =
							voxelTraceResult == FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT ||
							voxelTraceResult == FOXY_VOXEL_GI_TRACE_DISTANCE_LIMIT;
						if (environmentTerminal) {
							vec3 skyEscapeRadiance = pathThroughput *
								SsptTerminalSkyRadiance(
									pathDirection,
									pathSkyVisibility,
									FOXY_VOXEL_GI_SKY_BRIGHTNESS
								);
							pathRadiance += skyEscapeRadiance;
						}
					#endif
					break;
				}

				if (bounceIndex == 0) {
					firstVoxelHit = true;
					firstVoxelHitDistance = voxelHitDistance;
				}
				vec3 surfaceAlbedo = VoxelGiAlbedo(voxelPayload);
				vec3 continuedThroughput = vec3(0.0);
				bool continuePath = false;
				if (bounceIndex < FOXY_VXGI_TRUE_SECONDARY_BOUNCE) {
					continuedThroughput = pathThroughput * surfaceAlbedo;
					float continuedEnergy = max(
						continuedThroughput.x,
						max(continuedThroughput.y, continuedThroughput.z)
					);
					continuePath = continuedEnergy > 0.015;
				}
				float voxelSkyLight = VoxelSkyLight(voxelPayload);
				float directLightCosine = max(dot(
					voxelHitNormal,
					voxelDirectLightWorldDirection
				), 0.0);
				#if defined(FOXY_DIM_END)
					bool directLightTraceCandidate =
						directLightCosine > 0.001 &&
						voxelDirectLightCanContribute;
				#else
					bool directLightTraceCandidate = voxelSkyLight > 0.0001 &&
						directLightCosine > 0.001 &&
						voxelDirectLightCanContribute;
				#endif
				vec3 hitPosition = vec3(0.0);
				if (
					directLightTraceCandidate || continuePath
					#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1 && FOXY_VXGI_TRUE_SECONDARY_BOUNCE == 0
						|| true
					#endif
				) {
					hitPosition = pathOrigin + pathDirection * voxelHitDistance;
				}
				vec3 directLightTransmission = vec3(1.0);
				float directLightVisibility = directLightTraceCandidate
					? VoxelGiDirectVisibility(
						hitPosition,
						voxelHitNormal,
						directLightCosine,
						directLightTransmission
					)
					: 0.0;
				vec3 hitRadiance = VoxelGiHitRadiance(
					voxelPayload,
					surfaceAlbedo,
					voxelHitNormal,
					voxelSkyLight,
					neutralSkyMeanRadiance,
					voxelDirectLightRadiance * directLightTransmission,
					directLightCosine,
					directLightVisibility,
					true,
					1.0,
					1.0
				);
				pathRadiance += pathThroughput * hitRadiance;
				if (!continuePath) break;

				pathOrigin = hitPosition + voxelHitNormal * 0.002;
				vec2 bounceRandom = SsptIndependentBounceSample(
					primaryPixel,
					sampleIndex,
					bounceIndex
				);
				pathDirection = SsptCosineDirection(
					voxelHitNormal,
					bounceRandom
				);
				pathThroughput = continuedThroughput;
				pathSkyVisibility = VoxelGiSkyVisibility(voxelSkyLight);
			}

			vec3 blendedPathRadiance = pathRadiance;
			radianceSum += min(
				max(blendedPathRadiance, vec3(0.0)) *
					FOXY_VXGI_STORAGE_SCALE,
				vec3(64.0)
			);
			if (firstVoxelHit) {
				hitDistanceSum += max(
					firstVoxelHitDistance / max(query.maxDistance, 1.0e-3),
					1.0 / 65535.0
				);
				hitCount += 1.0;
			} else {
				missCount += 1.0;
			}
		}
		#endif
	}

	#if FOXY_RAY_MODE == FOXY_RAY_IRC_SSPT
	if (ircFallbackCount > 0.0) {
		#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
		vec3 ircGridPosition = VoxelGridSceneToGrid(
			originPlayerPos,
			cameraPosition
		) + primaryGbuffer.worldGeometricNormal * 0.08;
		float ircDomainWeight;
		float ircConfidence;
		vec3 ircEstimate = IrcSampleOuterSurfaceMode(
			ircGridPosition,
			primaryGbuffer.worldGeometricNormal,
			cameraPosition,
			frameCounter,
			false,
			ircDomainWeight,
			ircConfidence
		) * FOXY_IRRADIANCE_CACHE_STRENGTH * SsptSignalStorageScale();
		float ircValid = ircDomainWeight * step(0.02, ircConfidence);
		radianceSum += ircEstimate * ircValid * ircFallbackCount;
		radianceSum += ircEnvironmentFallbackSum * (1.0 - ircValid);
		hitCount += ircFallbackCount * ircValid;
		missCount += ircFallbackCount * (1.0 - ircValid);
		#else
		radianceSum += ircEnvironmentFallbackSum;
		missCount += ircFallbackCount;
		#endif
	}
	#endif

	vec3 indirectSignal = radianceSum / float(FOXY_ACTIVE_GI_SPP);
	float traceState;
	if (hitCount > 0.5) {
		traceState = hitDistanceSum / hitCount;
	} else if (missCount > 0.5) {
		traceState = 0.0;
	} else {
		traceState = maximumRejection > 1.5 ? -0.75 : -0.50;
	}
	float packedTraceState = traceState + float(primaryCornerIndex) * 4.0;
	imageStore(img_ptTrace, tracePixel, vec4(indirectSignal, packedTraceState));
	#endif
}
#endif
