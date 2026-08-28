#include "/lib/settings.glsl"

#ifndef FOXY_SSPT_TRACE_LIBRARY_ONLY
layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 0 && FOXY_VRTGI_TEMPORAL_INTERLEAVE == 1
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
layout(rgba16f) readonly uniform image2D img_ptHistoryA;
layout(rgba16f) readonly uniform image2D img_ptHistoryB;
layout(rgba16f) readonly uniform image2D img_ptHistoryMetaA;
layout(rgba16f) readonly uniform image2D img_ptHistoryMetaB;
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
#if FOXY_VOXEL_GI_ACTIVE == 1
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform vec3 shadowLightPosition;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform sampler2DShadow shadowtex1;
#endif
#endif

#include "/lib/math.glsl"
#if FOXY_VOXEL_GI_ACTIVE == 1
	#ifndef FOXY_SSPT_TRACE_LIBRARY_ONLY
		#include "/lib/celestial.glsl"
		#include "/lib/shadow.glsl"
	#endif
#endif
	#include "/lib/trace_common.glsl"
	#include "/lib/contracts/sky_lut.glsl"
	#include "/lib/dimension_sky.glsl"
#if FOXY_VOXEL_GI_ACTIVE == 1
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
#if FOXY_VOXEL_GI_ACTIVE == 1
	#include "/lib/voxel/voxel_grid.glsl"
	#include "/lib/voxel/voxel_shape.glsl"
	#include "/lib/voxel/irradiance_cache.glsl"
#endif

#if FOXY_VOXEL_GI_ACTIVE == 1
	#define FOXY_ACTIVE_GI_SPP FOXY_VOXEL_GI_SPP
#else
	#define FOXY_ACTIVE_GI_SPP FOXY_SSPT_SPP
#endif

#if FOXY_VOXEL_GI_ACTIVE == 1
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
	// STBN must advance in Z; a fixed slice destroys its temporal spectrum.
	vec2 stbnSample = texelFetch(
		cloudStbnVec2,
		ivec3(spatialPixel, temporalSlice),
		0
	).rg;
	const vec2 temporalStep = vec2(0.7548776662466927, 0.5698402909980532);
	return fract(stbnSample + temporalStep * float(temporalCycle));
}

#if FOXY_VOXEL_GI_ACTIVE == 1
// Continuation bounces require an independent random stream.
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

// The lightmap gates escaped sky rays; it is not an irradiance source.
float SsptSkyLeakVisibility(const in float rawSkyLight) {
	float skyLight = Saturate(rawSkyLight * 1.07);
	float curved = 1.0 - pow(max(1.0 - skyLight * 0.9, 0.0), 0.7);
	curved = Saturate(curved * curved * curved * 1.95);
	return Saturate(curved * 4.44);
}

#ifndef FOXY_SSPT_TRACE_LIBRARY_ONLY
// Sky LUT radiance is valid only for upper-hemisphere terminal escapes.
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
	vec3 environmentRadiance = DecodeBufferColor(texture2D(
		colortex7,
		SsptSkyLutUv(worldDirection)
	).rgb);
	return environmentRadiance * upperHemisphereEscape *
		skyVisibility * radianceScale;
}
#endif

#if !defined(FOXY_SSPT_TRACE_LIBRARY_ONLY) && FOXY_SSPT == 1
vec3 SsptReconstructEmission(const in RayHit hit) {
	if (PtSurfaceIsEmissive(hit.surfaceClass) < 0.5) return vec3(0.0);

	float sourcePeak = max(max(hit.emission.r, hit.emission.g), hit.emission.b);
	if (sourcePeak <= 1.0e-5) return vec3(0.0);
	vec3 sourceSpectrum = hit.emission / sourcePeak;
	float sourceCoverage = smoothstep(0.002, 0.080, sourcePeak);
	float emitterEnergy = sourceCoverage * min(0.30 + sourcePeak * 0.88, 1.18) *
		FOXY_SSPT_EMISSIVE_BRIGHTNESS;
	return max(sourceSpectrum * emitterEnergy, vec3(0.0));
}

vec3 SsptScreenHitRadiance(const in ivec2 hitPixel) {
	// The raster pass exclusively owns direct lighting in SSGI.
	return DecodeSceneColor(texelFetch(colortex0, hitPixel, 0).rgb);
}

#endif

float SsptSignalStorageScale() {
	#if FOXY_RAY_MODE == FOXY_RAY_SSPT_VRTGI
		// Hybrid history shares VRTGI/IRC's FP16 storage scale.
		return 1.0 / 8.0;
	#else
		return 1.0;
	#endif
}

#if FOXY_VOXEL_GI_ACTIVE == 1
// VXGI history uses 1/8 scene-radiance scale for FP16 headroom.
const float FOXY_VXGI_STORAGE_SCALE = 1.0 / 8.0;

const vec3 FOXY_VXGI_DYE_ALBEDO[16] = vec3[16](
	vec3(0.682, 0.720, 0.714), // white
	vec3(0.243, 0.243, 0.223), // light gray
	vec3(0.045, 0.056, 0.061), // gray
	vec3(0.009, 0.009, 0.011), // black
	vec3(0.163, 0.064, 0.023), // brown
	vec3(0.313, 0.020, 0.014), // red
	vec3(0.682, 0.155, 0.009), // orange
	vec3(0.714, 0.494, 0.034), // yellow
	vec3(0.155, 0.411, 0.010), // lime
	vec3(0.081, 0.145, 0.006), // green
	vec3(0.006, 0.239, 0.239), // cyan
	vec3(0.030, 0.325, 0.505), // light blue
	vec3(0.033, 0.042, 0.289), // blue
	vec3(0.180, 0.023, 0.345), // purple
	vec3(0.411, 0.055, 0.366), // magenta
	vec3(0.645, 0.186, 0.289)  // pink
);

const vec3 FOXY_VXGI_MINERAL_ALBEDO[12] = vec3[12](
	vec3(0.494, 0.494, 0.494), // iron
	vec3(0.682, 0.494, 0.048), // gold
	vec3(0.416, 0.128, 0.061), // copper
	vec3(0.286, 0.161, 0.096), // exposed copper
	vec3(0.100, 0.253, 0.169), // weathered copper
	vec3(0.051, 0.150, 0.117), // oxidized copper
	vec3(0.042, 0.030, 0.031), // netherite
	vec3(0.088, 0.610, 0.559), // diamond
	vec3(0.019, 0.440, 0.119), // emerald
	vec3(0.009, 0.040, 0.189), // lapis
	vec3(0.233, 0.077, 0.407), // amethyst
	vec3(0.575, 0.548, 0.505)  // quartz
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
	if (materialId >= 10101u && materialId <= 10103u) {
		return vec3(0.18, 0.38, 0.09);
	}
	if (materialId >= 10110u && materialId <= 10119u) {
		return vec3(0.34, 0.21, 0.09);
	}
	if (materialId >= 10120u && materialId <= 10129u) {
		return vec3(0.38, 0.39, 0.41);
	}
	if (materialId == 10131u) return vec3(0.20, 0.34, 0.10);
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
		// Lava is emissive-only and terminates the path.
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
	// Thin and cutout geometry uses its stored face normal instead of the cell boundary.
	return materialId == 10100u ||
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
	// Vanilla light levels are perceptual; source radiance is scene-linear.
	return sourceSpectrum * (sourceRadiance * sourceLevel) *
		FOXY_VOXEL_GI_EMITTER_BRIGHTNESS *
		FOXY_VXGI_EMITTER_CALIBRATION;
}

#if !defined(FOXY_SSPT_TRACE_LIBRARY_ONLY) || defined(FOXY_MATERIAL_REFLECTION_GLOBAL_DIRECT_LIGHT)
float VoxelGiDirectVisibility(
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
	// Face-centre projection prevents DDA edge hits from crossing shadow texels.
	vec3 faceCenter = floor(gridPosition - hitNormal * 1.0e-4) +
		vec3(0.5) + hitNormal * 0.5;
	vec3 scenePosition = faceCenter - fract(cameraPosition) -
		vec3(FOXY_VOXEL_GRID_HALF_SIZE);
	vec4 shadowClip = shadowProjection * shadowModelView *
		vec4(scenePosition + hitNormal * normalOffset, 1.0);
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
	// Compute shadow comparisons require explicit LOD; this is a strict visibility gate.
	float shadowVisibility = textureLod(
		shadowtex1,
		vec3(shadowCoord.xy, shadowCoord.z - receiverBias),
		0.0
	);
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
	// Exact cosine-integral fraction for a constant upper-hemisphere field.
	float skyFacing = Saturate(surfaceNormal.y * 0.5 + 0.5);
	float skyVisibility = VoxelGiSkyVisibility(rawSkyLight);
	#if defined(FOXY_DIM_NETHER)
		// Nether environment radiance is omnidirectional.
		skyFacing = 1.0;
		skyVisibility = 1.0;
	#elif defined(FOXY_DIM_END)
		// The End has directional sky but no vanilla skylight channel.
		skyVisibility = 1.0;
	#endif
	return neutralSkyMeanRadiance * skyVisibility * skyFacing *
		FOXY_VOXEL_GI_SKY_BRIGHTNESS;
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
	return albedo * blockIrradiance * (faceCosine / PI);
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
	vec3 radiance = vec3(0.0);
	radiance += VoxelGiBlockLightRadiance(
		payload,
		albedo,
		hitNormal
	) * localLightScale;

	// Zero skylight vetoes stale or out-of-domain direct-sun samples.
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

	// Sky is an environment terminal, never voxel emission.
	radiance += VoxelGiEmission(payload) * localLightScale;
	return max(radiance, vec3(0.0));
}

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
				bool paneShape = TransmissionIsPane(materialId);
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

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
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
		// Integrate small Lambertian emitters as projected discs.
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

	// Resample two emitter proposals; only the selected one launches visibility.
	float reservoirWeight = float(faceCount) * importanceSum /
		(2.0 * selectedImportance);
	return max(selectedIncoming * transmittance * reservoirWeight, vec3(0.0));
}
#endif
#endif

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
		// IRC uses a valid zero-radiance trace placeholder to preserve ownership.
		imageStore(img_ptTrace, ircPixel, vec4(0.0));
		return;
	#endif
	ivec2 tracePixel;
	#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_VRTGI_TEMPORAL_INTERLEAVE == 1
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

#if FOXY_VOXEL_GI_ACTIVE == 1
	vec3 voxelRayOrigin = VoxelGridSceneToGrid(
		originPlayerPos,
		cameraPosition
	);
	float voxelTraceWeight = VrtgiReceiverDomainWeight(
		originPlayerPos,
		cameraPosition
	);
	// Pure VRTGI owns only its voxel domain. Hybrid mode still gives screen
	// space a chance outside that domain and falls back only when needed.
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
#if FOXY_VOXEL_GI_ACTIVE == 1
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
		// End daylight uses a fixed 60-degree source.
		voxelDirectLightWorldDirection = EndSunWorldDirection();
		voxelDirectLightAltitude = 0.86602540;
		voxelDirectLightCanContribute = true;
		voxelDirectLightRadiance = vec3(0.62, 0.72, 1.00);
	#endif
#endif

	vec2 stbnValue = SsptTemporalSample(primaryPixel);

	for (int sampleIndex = 0; sampleIndex < FOXY_ACTIVE_GI_SPP; sampleIndex++) {
		float sampleValue = float(sampleIndex);
		// Stratify cosine radius and azimuth; STBN supplies pixel decorrelation.
		vec2 sampleRotation = vec2(
			sampleValue / float(FOXY_ACTIVE_GI_SPP),
			0.61803398875 * sampleValue
		);
		vec2 randomValue = fract(stbnValue + sampleRotation);

		RayQuery query;
		query.worldOrigin = cameraPosition + originPlayerPos;
		query.worldDirection = SsptCosineDirection(primaryGbuffer.worldNormal, randomValue);
		// Shading normals may tilt a sample below the actual surface. Keep the
		// cosine sampler, but reject those rays against the geometric hemisphere.
		if (dot(query.worldDirection, primaryGbuffer.worldGeometricNormal) <= 0.0) {
			missCount += 1.0;
			continue;
		}
		#if FOXY_VOXEL_GI_ACTIVE == 1
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
			// Screen-space tracing is bounded by the projected view, not the
			// voxel-domain radius. Keep the configured distance as a near-range
			// floor, while allowing rays to reach the far clip plane outside voxels.
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
					// A rejected screen ray is unknown, so hybrid mode sends it to
					// the voxel backend. A clean screen escape remains a sky sample.
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
				#else
					missCount += screenResult.terminal;
					if (screenResult.terminal > 0.5) {
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
			// Bound iterations by the maximum voxel-plane crossings of the segment.
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
					// Only domain and distance exits reach the environment.
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
				#if defined(FOXY_DIM_END)
					float directLightVisibility = directLightTraceCandidate
						? 1.0
						: 0.0;
				#else
					float directLightVisibility = directLightTraceCandidate
						? VoxelGiDirectVisibility(
							hitPosition,
							voxelHitNormal,
							directLightCosine
						)
						: 0.0;
				#endif
				vec3 hitRadiance = VoxelGiHitRadiance(
					voxelPayload,
					surfaceAlbedo,
					voxelHitNormal,
					voxelSkyLight,
					neutralSkyMeanRadiance,
					voxelDirectLightRadiance,
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
}
#endif

