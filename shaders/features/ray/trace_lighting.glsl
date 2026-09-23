#ifndef FOXY_TRACE_LIGHTING_GLSL
#define FOXY_TRACE_LIGHTING_GLSL
// Shared trace and lighting helpers. Stage layouts/uniforms and main stay in the program.
#include "/lib/math.glsl"
#if FOXY_VOXEL_GI_ACTIVE == 1 && (FOXY_VOXEL_TRACING == 1 || defined(FOXY_SSPT_TRACE_LIBRARY_ONLY))

	#ifndef FOXY_SSPT_TRACE_LIBRARY_ONLY
		#include "/lib/celestial.glsl"
		#include "/lib/shadow.glsl"
	#endif

	vec3 ShadowTransmissionTint(const in vec4 sampleValue) {
		float coverage = clamp(sampleValue.a, 0.0, 1.0);
		vec3 transmission = clamp(
			sampleValue.rgb / max(coverage, 1.0e-4),
			vec3(0.02),
			vec3(1.0)
		);
		float marker = coverage * (1.0 - step(
			0.998,
			max(max(sampleValue.r, sampleValue.g), sampleValue.b)
		));
		return mix(vec3(1.0), transmission, step(0.002, marker));
	}
#endif
	#include "/lib/trace_common.glsl"
	#include "/lib/contracts/sky_lut.glsl"
	#include "/lib/dimension_sky.glsl"
#if FOXY_VOXEL_GI_ACTIVE == 1 && (FOXY_VOXEL_TRACING == 1 || defined(FOXY_SSPT_TRACE_LIBRARY_ONLY))
	#include "/lib/voxel/vrtgi_fallback.glsl"
#endif
#ifndef FOXY_SSPT_TRACE_LIBRARY_ONLY
	#include "/lib/sr.glsl"
	#include "/lib/rt_denoiser.glsl"
	#define PT_GBUFFER_READ
	#include "/lib/pt_gbuffer.glsl"
	#undef PT_GBUFFER_READ
	#include "/ray/query.glsl"
#endif
#if FOXY_SSPT == 1 && !defined(FOXY_SSPT_TRACE_LIBRARY_ONLY)
	#include "/ray/trace_screen.glsl"
#endif
#if FOXY_RAY_MODE == FOXY_RAY_RSM && !defined(FOXY_SSPT_TRACE_LIBRARY_ONLY)
	uniform mat4 shadowProjection;
	uniform mat4 shadowProjectionInverse;
	uniform mat4 shadowModelView;
	uniform mat4 shadowModelViewInverse;
	uniform sampler2D shadowtex1;
	uniform sampler2D shadowcolor1;
	#define FOXY_RSM_EXTERNAL_UNIFORMS
	#include "/lib/rsm.glsl"
	#undef FOXY_RSM_EXTERNAL_UNIFORMS
#endif
#if FOXY_VOXEL_GI_ACTIVE == 1
	#include "/lib/voxel/voxel_grid.glsl"
	#include "/lib/voxel/material_color.glsl"
	#include "/lib/voxel/voxel_shape.glsl"
	#if defined(FOXY_SSPT_TRACE_LIBRARY_ONLY) || FOXY_RAY_MODE == FOXY_RAY_IRC_SSPT
		#include "/lib/voxel/irradiance_cache.glsl"
	#endif
#endif

#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_RAY_MODE != FOXY_RAY_IRC_SSPT
	#define FOXY_ACTIVE_GI_SPP FOXY_VOXEL_GI_SPP
#else
	#define FOXY_ACTIVE_GI_SPP FOXY_SSPT_SPP
#endif

#if FOXY_VOXEL_GI_ACTIVE == 1 || FOXY_RAY_MODE == FOXY_RAY_RSM
#if !defined(FOXY_SSPT_TRACE_LIBRARY_ONLY) && FOXY_SSPT == 0
float SsptLinearDepth(const in float rawDepth) {
	return TraceLinearDepthFromRaw(rawDepth, near, far);
}

vec3 SsptViewPosFromDepth(
	const in vec2 viewUv,
	const in float rawDepth
) {
	return TraceViewPosFromDepth(
		viewUv,
		rawDepth,
		gbufferProjectionInverse
	);
}

vec2 SsptViewUvFromRenderPixel(const in ivec2 pixel) {
	vec2 renderSize = max(SrRenderSize(), vec2(1.0));
	vec2 rasterUv = (vec2(pixel) + vec2(0.5)) / renderSize;
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return rasterUv - temporalJitter * 0.5;
	#else
		return rasterUv;
	#endif
}
#endif
#endif

vec3 SsptCosineDirection(const in vec3 worldNormal, const in vec2 randomValue) {
	float radius = sqrt(Saturate(randomValue.x));
	float angle = 2.0 * PI * randomValue.y;
	vec3 localDirection = vec3(radius * cos(angle), radius * sin(angle), sqrt(max(1.0 - randomValue.x, 0.0)));
	vec3 helper = abs(worldNormal.z) < 0.999 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);
	vec3 tangent = normalize(cross(helper, worldNormal));
	vec3 bitangent = cross(worldNormal, tangent);
	return tangent * localDirection.x + bitangent * localDirection.y +
		worldNormal * localDirection.z;
}

vec2 SsptTemporalSample(const in ivec2 pixel) {
	const int spatialPeriod = 128;
	const int temporalPeriod = 64;
	int safeFrame = max(frameCounter, 0);
	ivec2 spatialPixel = ivec2(pixel.x % spatialPeriod, pixel.y % spatialPeriod);
	int temporalSlice = safeFrame % temporalPeriod;
	int temporalCycle = safeFrame / temporalPeriod;

	vec2 stbnSample = texelFetch(
		cloudStbnVec2,
		ivec3(spatialPixel, temporalSlice),
		0
	).rg;
	const vec2 temporalStep = vec2(0.7548776662466927, 0.5698402909980532);
	return fract(stbnSample + temporalStep * float(temporalCycle));
}

#if FOXY_VOXEL_TRACING == 1

vec2 SsptIndependentBounceSample(
	const in ivec2 pixel,
	const in int sampleIndex,
	const in int bounceIndex
) {
	uint state = uint(pixel.x) * 0x8da6b343u;
	state ^= uint(pixel.y) * 0xd8163841u;
	state ^= uint(max(frameCounter, 0)) * 0xcb1ab31fu;
	state ^= uint(sampleIndex + 1) * 0x165667b1u;
	state ^= uint(bounceIndex + 1) * 0x9e3779b9u;
	uint randomX = VoxelGridHashBits(state ^ 0xa511e9b3u);
	uint randomY = VoxelGridHashBits(state ^ 0x63d83595u);
	return vec2(
		float(randomX >> 8u),
		float(randomY >> 8u)
	) * (1.0 / 16777216.0);
}
#endif

vec2 SsptSkyLutUv(const in vec3 worldDirection) {
	vec3 direction = normalize(worldDirection);
	float azimuth = atan(direction.x, -direction.z);
	float altitude = asin(clamp(direction.y, -1.0, 1.0));
	float altitudeParameter = sign(altitude) * sqrt(abs(altitude) / (0.5 * PI));
	return SkyLutPhysicalUv(vec2(fract(azimuth / (2.0 * PI) + 0.5), altitudeParameter * 0.5 + 0.5));
}

float SsptSkyLeakVisibility(const in float rawSkyLight) {
	float skyLight = Saturate(rawSkyLight * 1.07);
	float curved = 1.0 - pow(max(1.0 - skyLight * 0.9, 0.0), 0.7);
	curved = Saturate(curved * curved * curved * 1.95);
	return Saturate(curved * 4.44);
}

vec3 SsptTerminalSkyRadiance(
	const in vec3 worldDirection,
	const in float receiverSkyVisibility,
	const in float radianceScale
) {
	float upperHemisphereEscape = Saturate(worldDirection.y * 25.0 + 0.5);
	float skyVisibility = Saturate(receiverSkyVisibility);
	#if defined(FOXY_DIM_NETHER)
		upperHemisphereEscape = 1.0;
		skyVisibility = 1.0;
	#elif defined(FOXY_DIM_END)
		skyVisibility = 1.0;
	#endif
	#if !defined(FOXY_DIM_NETHER)
		if (upperHemisphereEscape <= 0.0) return vec3(0.0);
	#endif
	vec3 environmentRadiance = DecodeBufferColor(texture2D(
		colortex7,
		SsptSkyLutUv(worldDirection)
	).rgb);
	return FoxyIndirectColorTemperature(
		environmentRadiance * upperHemisphereEscape *
			skyVisibility * radianceScale
	);
}
#if !defined(FOXY_SSPT_TRACE_LIBRARY_ONLY) && FOXY_SSPT == 1
vec3 SsptReconstructEmission(const in RayHit hit) {
	if (PtSurfaceIsEmissive(hit.surfaceClass) < 0.5) return vec3(0.0);

	float sourcePeak = max(max(hit.emission.r, hit.emission.g), hit.emission.b);
	if (sourcePeak <= 1.0e-5) return vec3(0.0);
	vec3 sourceSpectrum = hit.emission / sourcePeak;
	float sourceCoverage = smoothstep(0.002, 0.080, sourcePeak);
	float emitterEnergy = sourceCoverage * min(0.30 + sourcePeak * 0.88, 1.18) *
		FOXY_SSPT_EMISSIVE_BRIGHTNESS;
	return FoxyIndirectColorTemperature(max(sourceSpectrum * emitterEnergy, vec3(0.0)));
}

vec3 SsptScreenHitRadiance(const in ivec2 hitPixel) {

	return DecodeSceneColor(texelFetch(colortex0, hitPixel, 0).rgb);
}

#endif

float SsptSignalStorageScale() {
	#if FOXY_RAY_MODE == FOXY_RAY_IRC_SSPT

return clamp(FOXY_SSPT_BOUNCE_BRIGHTNESS, 0.0, 15.0) / 8.0;
	#elif FOXY_RAY_MODE == FOXY_RAY_SSPT_VRTGI

		return 1.0 / 8.0;
	#else
		return 1.0;
	#endif
}

#if FOXY_VOXEL_GI_ACTIVE == 1 && (FOXY_VOXEL_TRACING == 1 || defined(FOXY_SSPT_TRACE_LIBRARY_ONLY))

const float FOXY_VXGI_STORAGE_SCALE = 1.0 / 8.0;

const vec3 FOXY_VXGI_DYE_ALBEDO[16] = vec3[16](
	vec3(0.682, 0.720, 0.714),
	vec3(0.243, 0.243, 0.223),
	vec3(0.045, 0.056, 0.061),
	vec3(0.009, 0.009, 0.011),
	vec3(0.163, 0.064, 0.023),
	vec3(0.313, 0.020, 0.014),
	vec3(0.682, 0.155, 0.009),
	vec3(0.714, 0.494, 0.034),
	vec3(0.155, 0.411, 0.010),
	vec3(0.081, 0.145, 0.006),
	vec3(0.006, 0.239, 0.239),
	vec3(0.030, 0.325, 0.505),
	vec3(0.033, 0.042, 0.289),
	vec3(0.180, 0.023, 0.345),
	vec3(0.411, 0.055, 0.366),
	vec3(0.645, 0.186, 0.289)
);

const vec3 FOXY_VXGI_MINERAL_ALBEDO[12] = vec3[12](
	vec3(0.494, 0.494, 0.494),
	vec3(0.682, 0.494, 0.048),
	vec3(0.416, 0.128, 0.061),
	vec3(0.286, 0.161, 0.096),
	vec3(0.100, 0.253, 0.169),
	vec3(0.051, 0.150, 0.117),
	vec3(0.042, 0.030, 0.031),
	vec3(0.088, 0.610, 0.559),
	vec3(0.019, 0.440, 0.119),
	vec3(0.009, 0.040, 0.189),
	vec3(0.233, 0.077, 0.407),
	vec3(0.575, 0.548, 0.505)
);

vec3 VoxelGiAlbedo(const in uint payload) {
	uint materialId = VoxelGridMaterial(payload);
	if (materialId >= 10200u && materialId <= 10215u) {
		return FOXY_VXGI_DYE_ALBEDO[int(materialId - 10200u)];
	}
	if (materialId >= 11200u && materialId <= 11215u) {
		return FOXY_VXGI_DYE_ALBEDO[int(materialId - 11200u)];
	}
	if (materialId >= 10220u && materialId <= 10231u) {
		return FOXY_VXGI_MINERAL_ALBEDO[int(materialId - 10220u)];
	}
	if (materialId == 10100u) return vec3(0.16, 0.34, 0.10);
	if (materialId == 12000u) return vec3(0.44000, 0.24000, 0.33000);
	if (materialId >= 10101u && materialId <= 10103u) {
		return vec3(0.18, 0.38, 0.09);
	}
	if (materialId >= 10110u && materialId <= 10119u) {
		return vec3(0.34, 0.21, 0.09);
	}
	if (materialId >= 10120u && materialId <= 10129u) {
		return vec3(0.38, 0.39, 0.41);
	}
	if (materialId == 10131u) return vec3(0.28, 0.54, 0.17);
	if (materialId >= 10130u && materialId <= 10139u) {
		return vec3(0.33, 0.22, 0.11);
	}
	if (materialId >= 10140u && materialId <= 10149u) {
		return vec3(0.48, 0.49, 0.50);
	}
	if (materialId >= 10150u && materialId <= 10159u) {
		return vec3(0.36, 0.46, 0.56);
	}
	if (materialId >= 10160u && materialId <= 10169u) {
		return vec3(0.47, 0.46, 0.45);
	}
	if (materialId == 10170u) return vec3(0.40, 0.22, 0.08);
	if (materialId == 10171u) return vec3(0.12, 0.28, 0.36);
	if (materialId == 10172u) return vec3(0.55, 0.34, 0.14);
	if (materialId == 10173u) return vec3(0.42, 0.56, 0.66);
	if (materialId == 10174u) return vec3(0.46, 0.10, 0.045);
	if (materialId == 10175u) return vec3(0.30, 0.12, 0.065);
	if (materialId == 10177u) return vec3(0.31, 0.24, 0.18);
	if (materialId == 10178u) return vec3(0.50, 0.58, 0.62);
	if (materialId == 10179u) return vec3(0.34, 0.075, 0.035);
	if (materialId == 10180u) return vec3(0.32, 0.46, 0.18);
	if (materialId == 10181u) return vec3(0.57, 0.30, 0.62);
	if (materialId == 10182u) return vec3(0.25, 0.58, 0.36);
	if (EmissionLavaMaterial(float(materialId))) {

		return vec3(0.0);
	}
	if (materialId == 10184u || materialId == 10185u) return vec3(0.42, 0.18, 0.055);
	if (materialId == 10186u) return vec3(0.30, 0.58, 0.12);
	if (materialId == 10187u) return vec3(0.38, 0.24, 0.58);
	if (materialId == 10188u) return vec3(0.14, 0.42, 0.50);
	if (materialId == 10189u) return vec3(0.38, 0.12, 0.52);
	if (materialId == 10190u) return vec3(0.26, 0.34, 0.42);
	if (materialId == 10191u) return vec3(0.22, 0.08, 0.30);
	if (materialId == 10192u) return vec3(0.32, 0.035, 0.52);
	if (materialId == 10193u) return vec3(0.46, 0.16, 0.035);
	if (materialId == 10194u) return vec3(0.035, 0.30, 0.48);
	if (materialId == 10195u || materialId == 10196u) return vec3(0.10, 0.44, 0.14);
	return vec3(0.43);
}

bool VoxelGiStoredFaceNormalMaterial(const in uint materialId) {

	return materialId == 10100u || materialId == 12000u ||
		(materialId >= 10101u && materialId <= 10103u) ||
		materialId == 10176u;
}

vec3 VoxelGiEmission(const in uint payload) {
	uint materialId = VoxelGridMaterial(payload);
	float encodedSourceLevel = Saturate(VoxelEmissionLevel(payload));
	if (encodedSourceLevel <= 0.0) return vec3(0.0);
	float sourceLevel = pow(encodedSourceLevel, 2.2);

	float materialKey = float(materialId);
	if (EmissionLavaMaterial(materialKey)) {
		return FOXY_EMISSION_LAVA * (15.0 * sourceLevel) *
			FOXY_VOXEL_GI_EMITTER_BRIGHTNESS;
	}
	vec3 sourceSpectrum = EmissionSpectrum(materialKey);
	float sourceRadiance = EmissionRadiance(materialKey);

	return sourceSpectrum * (sourceRadiance * sourceLevel) *
		FOXY_VOXEL_GI_EMITTER_BRIGHTNESS *
		FOXY_VXGI_EMITTER_CALIBRATION;
}

#if !defined(FOXY_SSPT_TRACE_LIBRARY_ONLY) || defined(FOXY_MATERIAL_REFLECTION_GLOBAL_DIRECT_LIGHT)
float VoxelGiDirectVisibility(
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
	if (
		any(lessThanEqual(shadowCoord, vec3(0.0))) ||
		any(greaterThanEqual(shadowCoord, vec3(1.0)))
	) {
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

float VoxelGiSkyVisibility(const in float rawSkyLight) {
	return SsptSkyLeakVisibility(rawSkyLight);
}

vec3 VoxelGiSkyIncomingRadiance(
	const in float rawSkyLight,
	const in vec3 surfaceNormal,
	const in vec3 neutralSkyMeanRadiance
) {

	float skyFacing = Saturate(surfaceNormal.y * 0.5 + 0.5);
	float skyVisibility = VoxelGiSkyVisibility(rawSkyLight);
	#if defined(FOXY_DIM_NETHER)

		skyFacing = 1.0;
		skyVisibility = 1.0;
	#elif defined(FOXY_DIM_END)

		skyVisibility = 1.0;
	#endif
	return FoxyIndirectColorTemperature(
		neutralSkyMeanRadiance * skyVisibility * skyFacing *
			FOXY_VOXEL_GI_SKY_BRIGHTNESS
	);
}

vec3 VoxelGiNeutralSkyMeanRadiance() {
	vec3 skyUpperHemisphereFluence = DecodeBufferColor(texelFetch(
		colortex7,
		SkyUpperHemisphereFluenceTexel(),
		0
	).rgb);
	vec3 skyMeanRadiance = max(skyUpperHemisphereFluence, vec3(0.0)) /
		(2.0 * PI);
	float skyMeanLuma = dot(
		max(skyMeanRadiance, vec3(0.0)),
		vec3(0.2126, 0.7152, 0.0722)
	);
	vec3 neutralSkyMeanRadiance = mix(
		skyMeanRadiance,
		vec3(skyMeanLuma),
		Saturate(FOXY_SKY_AMBIENT_NEUTRALITY)
	) * FOXY_SKY_AMBIENT_LIFT;
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
	#endif
	return neutralSkyMeanRadiance;
}

vec3 VoxelGiBlockLightRadiance(
	const in uint payload,
	const in vec3 albedo,
	const in vec3 hitNormal
) {
	float blockLevel = Saturate(VoxelBlockLight(payload));
	blockLevel *= blockLevel;
	if (blockLevel <= 0.0) return vec3(0.0);
	vec3 litFaceNormal = VoxelAxisNormal(payload);
	float faceCosine = max(dot(hitNormal, litFaceNormal), 0.0);
	vec3 blockIrradiance = vec3(blockLevel * 0.18) *
		FOXY_VOXEL_GI_EMITTER_BRIGHTNESS *
		FOXY_VXGI_EMITTER_CALIBRATION;
	vec3 radiance = albedo * blockIrradiance * (faceCosine / PI);
	#if FOXY_RAY_MODE == FOXY_RAY_IRC
		return radiance;
	#else
		return FoxyIndirectColorTemperature(radiance);
	#endif
}

vec3 VoxelGiDirectHitRadiance(
	const in uint payload,
	const in vec3 albedo,
	const in vec3 hitNormal,
	const in float skyLight,
	const in vec3 sunRadiance,
	const in float sunCosine,
	const in float sunVisibility,
	const in float localLightScale
) {
	vec3 radiance = VoxelGiBlockLightRadiance(
		payload,
		albedo,
		hitNormal
	) * localLightScale;
	if (sunVisibility > 0.0) {
		float sunDomainGate = step(0.5 / 15.0, skyLight);
		#if defined(FOXY_DIM_END)
			sunDomainGate = 1.0;
		#endif
		radiance += albedo * sunRadiance *
			(sunCosine * sunVisibility * sunDomainGate / PI) *
			FOXY_VOXEL_GI_SUN_DIFFUSE_BRIGHTNESS *
			FOXY_VXGI_SUN_CALIBRATION;
	}
	return max(radiance, vec3(0.0));
}

vec3 VoxelGiReflectionRadiance(
	const in uint payload,
	const in vec3 albedo,
	const in vec3 hitNormal,
	const in float skyLight,
	const in vec3 neutralSkyMeanRadiance,
	const in vec3 sunRadiance,
	const in float sunCosine,
	const in float sunVisibility,
	const in float localLightScale,
	const in float skyLightScale
) {
	vec3 emission = VoxelGiEmission(payload);
	if (Luma(emission) > 1.0e-5) {
		return max(
			FoxyIndirectColorTemperature(emission) * localLightScale,
			vec3(0.0)
		);
	}
	vec3 radiance = VoxelGiDirectHitRadiance(
		payload,
		albedo,
		hitNormal,
		skyLight,
		sunRadiance,
		sunCosine,
		sunVisibility,
		localLightScale
	);
	float skyVisibility = VoxelGiSkyVisibility(skyLight);
	float skyFacing = 0.5 + 0.5 * clamp(hitNormal.y, -1.0, 1.0);
	vec3 baseSky = neutralSkyMeanRadiance *
		max(skyVisibility, 0.12) *
		mix(0.45, 1.0, skyFacing) *
		FOXY_VOXEL_GI_SKY_BRIGHTNESS * skyLightScale;
	return max(radiance + albedo * baseSky / PI, vec3(0.0));
}

vec3 VoxelGiHitRadianceMode(
	const in uint payload,
	const in vec3 albedo,
	const in vec3 hitNormal,
	const in float skyLight,
	const in vec3 neutralSkyMeanRadiance,
	const in vec3 sunRadiance,
	const in float sunCosine,
	const in float sunVisibility,
	const in bool useTerminalSkyFallback,
	const in float localLightScale,
	const in float skyLightScale,
	const in bool tintEmissionWithAlbedo
) {
	vec3 radiance = vec3(0.0);
	#if FOXY_VXGI_BLOCKLIGHT_EMITTER == 1
		radiance += VoxelGiBlockLightRadiance(
			payload,
			albedo,
			hitNormal
		) * localLightScale;
	#endif
	if (sunVisibility > 0.0) {
		float sunDomainGate = step(0.5 / 15.0, skyLight);
		#if defined(FOXY_DIM_END)
			sunDomainGate = 1.0;
		#endif
		radiance += albedo * sunRadiance *
			(sunCosine * sunVisibility * sunDomainGate / PI) *
			FOXY_VOXEL_GI_SUN_DIFFUSE_BRIGHTNESS *
			FOXY_VXGI_SUN_CALIBRATION;
	}
	vec3 emission = VoxelGiEmission(payload);
	if (tintEmissionWithAlbedo && Luma(emission) > 0.0) {
		emission = mix(emission, max(albedo, vec3(0.0)), 0.65);
	}
	#if FOXY_RAY_MODE == FOXY_RAY_IRC
		radiance += emission * localLightScale;
	#else
		radiance += FoxyIndirectColorTemperature(emission) * localLightScale;
	#endif
	return max(radiance, vec3(0.0));
}

vec3 VoxelGiHitRadiance(
	const in uint payload,
	const in vec3 albedo,
	const in vec3 hitNormal,
	const in float skyLight,
	const in vec3 neutralSkyMeanRadiance,
	const in vec3 sunRadiance,
	const in float sunCosine,
	const in float sunVisibility,
	const in bool useTerminalSkyFallback,
	const in float localLightScale,
	const in float skyLightScale
) {
	return VoxelGiHitRadianceMode(
		payload,
		albedo,
		hitNormal,
		skyLight,
		neutralSkyMeanRadiance,
		sunRadiance,
		sunCosine,
		sunVisibility,
		useTerminalSkyFallback,
		localLightScale,
		skyLightScale,
		false
	);
}

#include "/lib/voxel/vrtgi_trace.glsl"
#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1 && defined(FOXY_SSPT_TRACE_LIBRARY_ONLY)
void VoxelGiEmitterPrimitiveCandidate(
	const in vec3 receiverPosition,
	const in vec3 receiverNormal,
	const in uint faceCount,
	inout uint randomState,
	out ivec3 emitterCell,
	out bool emitterSphere,
	out vec3 samplePosition,
	out vec3 unshadowedIncoming,
	out float importance
) {
	randomState = VoxelGridHashBits(randomState + 0x9e3779b9u);
	uint faceIndex = min(
		uint(VoxelGridHashUnitFloat(randomState) * float(faceCount)),
		faceCount - 1u
	);
	uint faceKey = VoxelEmitterFaceLoad(faceIndex);
	uint normalCode = faceKey & 7u;
	emitterCell = VoxelGridCellFromIndex(faceKey >> 3u);
	vec3 faceNormal = IrcNormalFromCode(normalCode);
	uint emitterPayload = VoxelGridLoadUnchecked(emitterCell);
	uint emitterMaterial = VoxelGridMaterial(emitterPayload);
	emitterSphere = normalCode == 0u &&
		VoxelSphereEmitterMaterial(emitterMaterial);
	bool emitterFace = normalCode != 0u &&
		!VoxelSphereEmitterMaterial(emitterMaterial) &&
		dot(faceNormal, faceNormal) > 0.5;
	if (!VoxelGridOccupied(emitterPayload) ||
		VoxelEmissionLevel(emitterPayload) <= 0.0 ||
		!(emitterSphere || emitterFace)) {
		emitterSphere = false;
		samplePosition = vec3(emitterCell) + vec3(0.5);
		unshadowedIncoming = vec3(0.0);
		importance = 0.0;
		return;
	}

	randomState = VoxelGridHashBits(randomState + 0x85ebca6bu);
	float sampleU = VoxelGridHashUnitFloat(randomState);
	randomState = VoxelGridHashBits(randomState + 0xc2b2ae35u);
	float sampleV = VoxelGridHashUnitFloat(randomState);
	samplePosition = vec3(emitterCell) + vec3(0.5);
	float primitiveArea = 1.0;
	if (emitterSphere) {

		vec3 toCenter = samplePosition - receiverPosition;
		float centerDistanceSquared = dot(toCenter, toCenter);
		if (centerDistanceSquared <= 1.0e-5 ||
			centerDistanceSquared > FOXY_VOXEL_GI_MAX_DISTANCE *
				FOXY_VOXEL_GI_MAX_DISTANCE) {
			unshadowedIncoming = vec3(0.0);
			importance = 0.0;
			return;
		}
		float centerDistance = sqrt(centerDistanceSquared);
		vec3 centerDirection = toCenter / centerDistance;
		samplePosition -= centerDirection * FOXY_VOXEL_GI_SPHERE_RADIUS;
		float receiverCosine = max(dot(receiverNormal, centerDirection), 0.0);
		float projectedSolidAngle =
			FOXY_VOXEL_GI_SPHERE_RADIUS * FOXY_VOXEL_GI_SPHERE_RADIUS /
			max(centerDistanceSquared, 1.0e-5);
		unshadowedIncoming = VoxelGiEmission(emitterPayload) *
			(receiverCosine * projectedSolidAngle);
		importance = max(Luma(unshadowedIncoming), 0.0);
		return;
	}
	float emitterHeight = emitterMaterial == FOXY_VOXEL_LAVA_SURFACE_MATERIAL
		? FOXY_VOXEL_LAVA_SURFACE_HEIGHT
		: 1.0;
	if (abs(faceNormal.x) > 0.5) {
		samplePosition.x = float(emitterCell.x) + (faceNormal.x > 0.0 ? 1.0 : 0.0);
		samplePosition.y = float(emitterCell.y) + sampleU * emitterHeight;
		samplePosition.z = float(emitterCell.z) + sampleV;
		primitiveArea = emitterHeight;
	} else if (abs(faceNormal.y) > 0.5) {
		samplePosition.x = float(emitterCell.x) + sampleU;
		samplePosition.y = float(emitterCell.y) +
			(faceNormal.y > 0.0 ? emitterHeight : 0.0);
		samplePosition.z = float(emitterCell.z) + sampleV;
	} else {
		samplePosition.x = float(emitterCell.x) + sampleU;
		samplePosition.y = float(emitterCell.y) + sampleV * emitterHeight;
		samplePosition.z = float(emitterCell.z) + (faceNormal.z > 0.0 ? 1.0 : 0.0);
		primitiveArea = emitterHeight;
	}

	vec3 toLight = samplePosition - receiverPosition;
	float distanceSquared = dot(toLight, toLight);
	if (distanceSquared <= 1.0e-5 ||
		distanceSquared > FOXY_VOXEL_GI_MAX_DISTANCE * FOXY_VOXEL_GI_MAX_DISTANCE) {
		unshadowedIncoming = vec3(0.0);
		importance = 0.0;
		return;
	}
	vec3 lightDirection = toLight * inversesqrt(distanceSquared);
	float receiverCosine = max(dot(receiverNormal, lightDirection), 0.0);
	float emitterCosine = max(dot(faceNormal, -lightDirection), 0.0);
	float geometry = receiverCosine * emitterCosine /
		(max(distanceSquared, 1.0e-5) * PI);
	unshadowedIncoming = VoxelGiEmission(emitterPayload) *
		(geometry * primitiveArea);
	importance = max(Luma(unshadowedIncoming), 0.0);
}

vec3 VoxelGiSampleEmitterDirect(
	const in vec3 receiverPosition,
	const in vec3 receiverNormal,
	const in uint inputSeed
) {
	uint faceCount = VoxelEmitterFaceCount();
	if (faceCount == 0u) return vec3(0.0);

	uint randomState = inputSeed;
	ivec3 firstCell;
	bool firstSphere;
	vec3 firstPosition;
	vec3 firstIncoming;
	float firstImportance;
	VoxelGiEmitterPrimitiveCandidate(
		receiverPosition,
		receiverNormal,
		faceCount,
		randomState,
		firstCell,
		firstSphere,
		firstPosition,
		firstIncoming,
		firstImportance
	);
	ivec3 secondCell;
	bool secondSphere;
	vec3 secondPosition;
	vec3 secondIncoming;
	float secondImportance;
	VoxelGiEmitterPrimitiveCandidate(
		receiverPosition,
		receiverNormal,
		faceCount,
		randomState,
		secondCell,
		secondSphere,
		secondPosition,
		secondIncoming,
		secondImportance
	);

	float importanceSum = firstImportance + secondImportance;
	if (importanceSum <= 1.0e-12) return vec3(0.0);
	randomState = VoxelGridHashBits(randomState + 0x27d4eb2du);
	bool chooseSecond = VoxelGridHashUnitFloat(randomState) *
		importanceSum >= firstImportance;
	ivec3 selectedCell = chooseSecond ? secondCell : firstCell;
	bool selectedSphere = chooseSecond ? secondSphere : firstSphere;
	vec3 selectedPosition = chooseSecond ? secondPosition : firstPosition;
	vec3 selectedIncoming = chooseSecond ? secondIncoming : firstIncoming;
	float selectedImportance = chooseSecond ? secondImportance : firstImportance;
	if (selectedImportance <= 1.0e-12) return vec3(0.0);
	vec3 biasedOrigin = receiverPosition + receiverNormal * 0.010;
	vec3 toLight = selectedPosition - biasedOrigin;
	float lightDistance = length(toLight);
	if (lightDistance <= 1.0e-4 || lightDistance > FOXY_VOXEL_GI_MAX_DISTANCE) {
		return vec3(0.0);
	}
	vec3 lightDirection = toLight / lightDistance;
	uint hitPayload;
	float hitDistance;
	ivec3 hitCell;
	vec3 hitNormal;
	vec3 unusedSphereRadiance;
	vec3 transmittance;
	int visibilityResult = VoxelGiTrace(
		biasedOrigin,
		lightDirection,
		selectedSphere
			? max(lightDistance - 0.003, 0.001)
			: min(lightDistance + 0.025, FOXY_VOXEL_GI_MAX_DISTANCE),
		min(FOXY_VOXEL_GI_TRACE_ITERATIONS, int(ceil(lightDistance * 1.75)) + 3),
		true,
		hitPayload,
		hitDistance,
		hitCell,
		hitNormal,
		unusedSphereRadiance,
		transmittance
	);
	bool selectedEmitterVisible = selectedSphere
		? visibilityResult == FOXY_VOXEL_GI_TRACE_DISTANCE_LIMIT
		: (visibilityResult == FOXY_VOXEL_GI_TRACE_SURFACE_HIT &&
			all(equal(hitCell, selectedCell)));
	if (!selectedEmitterVisible) return vec3(0.0);

float reservoirWeight = float(faceCount) * importanceSum /
		(2.0 * selectedImportance);
	return max(selectedIncoming * transmittance * reservoirWeight, vec3(0.0));
}
#endif
#endif


#endif
