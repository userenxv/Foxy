#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform sampler2D colortex5;
uniform sampler2D colortex7;
uniform sampler2D colortex14;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform float viewWidth;
uniform float viewHeight;
uniform float far;
uniform int frameCounter;
uniform int isEyeInWater;
uniform vec2 temporalJitter;



#include "/lib/sr.glsl"
#include "/lib/contracts/endpoint.glsl"
#define FOXY_READ_ONLY_OPAQUE_ENDPOINT_CURRENT
#define FOXY_READ_ONLY_WATER_SEGMENT_CURRENT
#define FOXY_READ_ONLY_LAYER_ENDPOINT_PING_PONG
#define FOXY_READ_ONLY_CLOUD_LAYER_CURRENT
#define FOXY_IMAGE_OPAQUE_ENDPOINT_CURRENT
#define FOXY_IMAGE_LAYER_ENDPOINT_PING_PONG
#define FOXY_IMAGE_WATER_SEGMENT_CURRENT
#define FOXY_IMAGE_CLOUD_LAYER_CURRENT
#include "/lib/contracts/images.glsl"
#include "/lib/contracts/volume.glsl"
#include "/lib/sky.glsl"

vec2 ResolveCurrentRasterUv(const in vec2 viewUv) {
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return viewUv + temporalJitter * 0.5;
	#else
		return viewUv;
	#endif
}

vec2 ResolveCurrentViewUv(const in vec2 rasterUv) {
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return rasterUv - temporalJitter * 0.5;
	#else
		return rasterUv;
	#endif
}

Endpoint ResolveCurrentEndpoint(const in vec2 viewUv) {
	Endpoint endpoint = EndpointUnpack(
		LoadOpaqueEndpoint(SrSceneSampleUv(viewUv))
	);
	WaterSegment water = WaterSegmentUnpack(
		LoadWaterSegment(SrSceneSampleUv(ResolveCurrentRasterUv(viewUv)))
	);
	return ResolveWaterEndpoint(
		endpoint,
		water.frontRayDistance,
		water.frontViewDistance,
		water.valid,
		water.owner,
		FOXY_ENDPOINT_MEDIUM_WATER
	);
}

struct ResolveCloudLayer {
	vec3 radiance;
	float alpha;
	float rayDistance;
	float valid;
};

ResolveCloudLayer ResolveVisibleCloudLayer(
	const in vec2 rasterUv,
	const in Endpoint foregroundEndpoint
) {
	ResolveCloudLayer layer;
	layer.radiance = vec3(0.0);
	layer.alpha = 0.0;
	layer.rayDistance = FOXY_ENDPOINT_INFINITY;
	layer.valid = 0.0;
	vec2 viewUv = ResolveCurrentViewUv(rasterUv);
	Endpoint cloudEndpoint = EndpointUnpack(
		LoadCloudEndpoint(SrSceneSampleUv(viewUv))
	);
	if (
		EndpointOwnerIs(cloudEndpoint, FOXY_ENDPOINT_OWNER_CLOUD) &&
		cloudEndpoint.rayDistance < foregroundEndpoint.rayDistance
	) {
		vec4 cloud = LoadCloudLayer(SrSceneSampleUv(viewUv));
		layer.radiance = max(cloud.rgb, vec3(0.0));
		layer.alpha = Saturate(cloud.a);
		layer.rayDistance = cloudEndpoint.rayDistance;
		layer.valid = 1.0;
	}
	return layer;
}

vec3 ResolveCloudOverCurrent(
	const in vec3 background,
	const in vec2 rasterUv,
	const in Endpoint foregroundEndpoint
) {
	ResolveCloudLayer cloud = ResolveVisibleCloudLayer(
		rasterUv,
		foregroundEndpoint
	);
	return cloud.valid > 0.5
		? background * (1.0 - cloud.alpha) + cloud.radiance
		: background;
}

struct ResolveContext {
	vec2 sourceSize;
	vec2 sourcePixel;
	float fogDistance;
};

ResolveContext MakeResolveContext() {
	ResolveContext context;
	float volumeScale = clamp(FOXY_VL_RESOLUTION, 0.10, 1.0);
	context.sourceSize = max(vec2(viewWidth, viewHeight) * volumeScale * SrActiveRenderScale(), vec2(1.0));
	context.sourcePixel = 1.0 / context.sourceSize;
	context.fogDistance = VolumeFogReach(far);
	return context;
}

vec4 ResolveDecode(const in vec4 storedVolume) {
	vec4 volume = DecodeVolumeBuffer(storedVolume);
	volume.rgb = min(max(volume.rgb, vec3(0.0)), vec3(16.0));
	volume.a = Saturate(volume.a);
	return volume;
}

float ResolveSurfaceSky(const in Endpoint endpoint) {
	return 1.0 - EndpointValid(endpoint);
}

float ResolveSceneDistance(const in Endpoint endpoint, const in ResolveContext context) {
	return min(VolumeFogDistanceFromEndpoint(endpoint, far), context.fogDistance);
}

float ResolveSameEndpointClass(
	const in Endpoint referenceEndpoint,
	const in Endpoint sampleEndpoint
) {
	float referenceSky = ResolveSurfaceSky(referenceEndpoint);
	float sampleSky = ResolveSurfaceSky(sampleEndpoint);
	float sameSkyClass = 1.0 - step(0.5, abs(referenceSky - sampleSky));
	float sameMedium = 1.0 - step(0.5, abs(referenceEndpoint.medium - sampleEndpoint.medium));
	return sameSkyClass * sameMedium;
}

struct ResolveSourceSample {
	vec4 volume;
	float distance;
	float sky;
	float medium;
};

ResolveSourceSample ResolveLoadSource(const in vec2 sourceTexel, const in ResolveContext context) {
	vec2 sourceUv = clamp((sourceTexel + vec2(0.5)) * context.sourcePixel, 0.5 * context.sourcePixel, vec2(1.0) - 0.5 * context.sourcePixel);
	Endpoint endpoint = ResolveCurrentEndpoint(sourceUv);
	ResolveSourceSample sampleData;
	sampleData.distance = ResolveSceneDistance(endpoint, context);
	sampleData.sky = ResolveSurfaceSky(endpoint);
	sampleData.medium = endpoint.medium;
	sampleData.volume = ResolveDecode(textureLod(
		colortex5, SrLocalResourceUv(sourceUv, textureSize(colortex5, 0)), 0.0
	));
	return sampleData;
}

#ifdef FOXY_VOLUME_RESOLVE_COMPUTE
// An 8x8 output group needs at most a 10x10 source tile, including its halo.
// All lanes load before the barrier, including lanes outside the active image.
shared vec4 resolveTileVolume[100];
shared vec4 resolveTileGuide[100];
ivec2 resolveTileOrigin;
ivec2 resolveTileSize;

void ResolvePrepareTile(const in ResolveContext context) {
	vec2 renderSize = SrRenderSize();
	ivec2 groupPixel = ivec2(gl_WorkGroupID.xy) * 8;
	vec2 firstUv = (vec2(groupPixel) + vec2(0.5)) / renderSize;
	vec2 lastUv = (vec2(groupPixel + ivec2(7)) + vec2(0.5)) / renderSize;
	// Match the reference's two operations, including rounding at cell boundaries.
	vec2 firstPos = clamp(firstUv, vec2(0.0), vec2(0.999999)) * context.sourceSize - vec2(0.5);
	vec2 lastPos = clamp(lastUv, vec2(0.0), vec2(0.999999)) * context.sourceSize - vec2(0.5);
	resolveTileOrigin = ivec2(floor(firstPos + vec2(0.5))) - ivec2(1);
	ivec2 lastCenter = ivec2(floor(lastPos + vec2(0.5)));
	resolveTileSize = lastCenter - resolveTileOrigin + ivec2(2);
	int count = resolveTileSize.x * resolveTileSize.y;
	for (int i = int(gl_LocalInvocationIndex); i < count; i += 64) {
		ivec2 local = ivec2(i % resolveTileSize.x, i / resolveTileSize.x);
		ResolveSourceSample sampleData = ResolveLoadSource(vec2(resolveTileOrigin + local), context);
		resolveTileVolume[i] = sampleData.volume;
		resolveTileGuide[i] = vec4(sampleData.distance, sampleData.sky, sampleData.medium, 0.0);
	}
	barrier();
}
#endif

ResolveSourceSample ResolveSource(const in vec2 sourceTexel, const in ResolveContext context) {
#ifdef FOXY_VOLUME_RESOLVE_COMPUTE
	ivec2 local = ivec2(sourceTexel) - resolveTileOrigin;
	int index = local.y * resolveTileSize.x + local.x;
	vec4 guide = resolveTileGuide[index];
	ResolveSourceSample sampleData;
	sampleData.volume = resolveTileVolume[index];
	sampleData.distance = guide.x;
	sampleData.sky = guide.y;
	sampleData.medium = guide.z;
	return sampleData;
#else
	return ResolveLoadSource(sourceTexel, context);
#endif
}

void ResolveAccumulate(
	const in vec2 sourceTexel,
	const in float spatialWeight,
	const in Endpoint referenceEndpoint,
	const in float referenceDistance,
	const in ResolveContext context,
	inout vec4 sum,
	inout float weightSum,
	inout vec4 bestVolume,
	inout float bestScore
) {
	ResolveSourceSample source = ResolveSource(sourceTexel, context);
	float referenceSky = ResolveSurfaceSky(referenceEndpoint);
	float sameSky = 1.0 - step(0.5, abs(referenceSky - source.sky));
	float sameMedium = 1.0 - step(0.5, abs(referenceEndpoint.medium - source.medium));
	float sameEndpointClass = sameSky * sameMedium;
	float sampleDistance = source.distance;
	float depthDelta = abs(sampleDistance - referenceDistance);
	float surfaceThreshold = max(0.65, referenceDistance * 0.012);
	float skyThreshold = max(4.0, referenceDistance * 0.080);
	float depthThreshold = mix(surfaceThreshold, skyThreshold, referenceSky);
	float depthRatio = depthDelta / depthThreshold;
	float depthWeight = exp2(-depthRatio * depthRatio * 2.5);
	vec4 sampleVolume = source.volume;

	float behindDistance = sampleDistance - referenceDistance;
	float truncateThreshold = max(0.75, referenceDistance * 0.015);
	if (isEyeInWater == 1 && sameEndpointClass > 0.5 && behindDistance > truncateThreshold) {
		float distanceRatio = clamp(referenceDistance / max(sampleDistance, 1.0), 0.0, 1.0);
		float sourceTransmittance = clamp(sampleVolume.a, 0.001, 1.0);
		float targetTransmittance = pow(sourceTransmittance, distanceRatio);
		float sourceCoverage = max(1.0 - sourceTransmittance, 0.001);
		float targetCoverage = max(1.0 - targetTransmittance, 0.0);
		sampleVolume.rgb *= clamp(targetCoverage / sourceCoverage, 0.0, 1.0);
		sampleVolume.a = targetTransmittance;
		depthWeight = 1.0;
	}

	float endpointWeight = sameEndpointClass * depthWeight;
	float weight = spatialWeight * endpointWeight;
	sum += sampleVolume * weight;
	weightSum += weight;
	float score = endpointWeight + spatialWeight * 0.01;
	if (sameEndpointClass > 0.5 && score > bestScore) {
		bestScore = score;
		bestVolume = sampleVolume;
	}
}

vec4 ResolveSpatialVolume(const in vec2 uv, const in Endpoint referenceEndpoint) {
	ResolveContext context = MakeResolveContext();
	vec2 sourcePos = clamp(uv, vec2(0.0), vec2(0.999999)) * context.sourceSize - vec2(0.5);
	vec2 centerTexel = floor(sourcePos + vec2(0.5));
	float referenceDistance = ResolveSceneDistance(referenceEndpoint, context);
	vec4 sum = vec4(0.0);
	float weightSum = 0.0;
	vec4 bestVolume = vec4(0.0, 0.0, 0.0, 1.0);
	float bestScore = -1.0;

	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 sourceTexel = centerTexel + vec2(float(x), float(y));
			vec2 delta = sourceTexel - sourcePos;
			float spatialWeight = exp2(-dot(delta, delta) * 1.65);
			ResolveAccumulate(
				sourceTexel,
				spatialWeight,
				referenceEndpoint,
				referenceDistance,
				context,
				sum,
				weightSum,
				bestVolume,
				bestScore
			);
		}
	}

	vec4 result = weightSum > 0.0001 ? sum / weightSum : bestVolume;
	result.rgb = min(max(result.rgb, vec3(0.0)), vec3(16.0));
	result.a = Saturate(result.a);
	return result;
}

vec3 ResolveVolumeAndCloud(
	const in vec3 background,
	const in vec4 volume,
	const in vec2 rasterUv,
	const in Endpoint foregroundEndpoint,
	out float cloudVisible
) {
	ResolveCloudLayer cloud = ResolveVisibleCloudLayer(
		rasterUv,
		foregroundEndpoint
	);
	cloudVisible = cloud.valid;
	if (cloud.valid < 0.5) {
		return background * volume.a + volume.rgb;
	}

	ResolveContext context = MakeResolveContext();
	float endpointDistance = max(
		ResolveSceneDistance(foregroundEndpoint, context),
		1.0e-4
	);
	float cloudDistance = min(cloud.rayDistance, endpointDistance);
	float frontFraction = clamp(cloudDistance / endpointDistance, 0.0, 1.0);
	float fullTransmittance = clamp(volume.a, 1.0e-4, 1.0);
	float frontTransmittance = pow(fullTransmittance, frontFraction);
	float fullCoverage = max(1.0 - fullTransmittance, 1.0e-4);
	float frontCoverage = max(1.0 - frontTransmittance, 0.0);
	vec3 frontScattering = volume.rgb * (frontCoverage / fullCoverage);
	float backTransmittance = fullTransmittance / max(frontTransmittance, 1.0e-4);
	vec3 backScattering = max(
		(volume.rgb - frontScattering) / max(frontTransmittance, 1.0e-4),
		vec3(0.0)
	);
	vec3 behindCloud = background * backTransmittance + backScattering;
	vec3 cloudComposite = behindCloud * (1.0 - cloud.alpha) + cloud.radiance;
	return frontScattering + cloudComposite * frontTransmittance;
}

float ResolveVanillaChunkBoundaryFade(
	const in Endpoint foregroundEndpoint,
	const in vec2 viewUv
) {
	#if FOXY_DH_ACTIVE == 0
		if (!EndpointOwnerIs(foregroundEndpoint, FOXY_ENDPOINT_OWNER_MAIN) &&
			!EndpointOwnerIs(foregroundEndpoint, FOXY_ENDPOINT_OWNER_MAIN_WATER) &&
			!EndpointOwnerIs(foregroundEndpoint, FOXY_ENDPOINT_OWNER_MAIN_GLASS)) {
			return 0.0;
		}
		vec3 viewRay = normalize(EndpointMainViewPosition(
			viewUv,
			1.0,
			gbufferProjectionInverse
		));
		vec3 worldRay = normalize(mat3(gbufferModelViewInverse) * viewRay);
		float horizontalDistance = foregroundEndpoint.rayDistance * length(worldRay.xz);
		float boundaryDistance = horizontalDistance / max(far, 32.0);
		return smoothstep(0.72, 0.985, boundaryDistance);
	#else
		return 0.0;
	#endif
}

vec3 ResolveApplyVanillaChunkBoundary(
	const in vec3 scene,
	const in vec4 volume,
	const in Endpoint foregroundEndpoint,
	const in vec2 viewUv,
	const in float cloudVisible
) {
	#if FOXY_DH_ACTIVE == 0
		float fade = ResolveVanillaChunkBoundaryFade(foregroundEndpoint, viewUv) * (1.0 - cloudVisible);
		if (fade <= 0.0001) return scene;
		vec3 viewRay = normalize(EndpointMainViewPosition(
			viewUv,
			1.0,
			gbufferProjectionInverse
		));
		vec3 worldRay = normalize(mat3(gbufferModelViewInverse) * viewRay);
		vec3 skyAirlight = DecodeSkyLutColor(texture2D(
			colortex7,
			SkyViewLutUv(worldRay)
		).rgb);

		vec3 skyThroughAir = max(skyAirlight, vec3(0.0)) * Saturate(volume.a) + max(volume.rgb, vec3(0.0));
		return mix(scene, skyThroughAir, fade);
	#else
		return scene;
	#endif
}

void ResolveVolumeAtUv(const in vec2 texcoord, out vec4 volumeOutput, out vec4 sceneOutput) {
	#if FOXY_VOLUMETRIC_LIGHT == 0
		volumeOutput = EncodeVolumeBuffer(vec4(0.0, 0.0, 0.0, 1.0));
		vec2 noVolumeSceneUv = SrSceneSampleUv(texcoord);
		vec3 noVolumeWorld = max(DecodeSceneColor(texture2D(colortex14, noVolumeSceneUv).rgb), vec3(0.0));
		Endpoint noVolumeEndpoint = ResolveCurrentEndpoint(texcoord);
		ResolveCloudLayer noVolumeCloud = ResolveVisibleCloudLayer(
			texcoord,
			noVolumeEndpoint
		);
		if (noVolumeCloud.valid > 0.5) {
			noVolumeWorld = noVolumeWorld * (1.0 - noVolumeCloud.alpha) + noVolumeCloud.radiance;
		}
		noVolumeWorld = ResolveApplyVanillaChunkBoundary(
			noVolumeWorld,
			vec4(0.0, 0.0, 0.0, 1.0),
			noVolumeEndpoint,
			texcoord,
			noVolumeCloud.valid
		);
		sceneOutput = vec4(EncodeSceneColor(max(noVolumeWorld, vec3(0.0))), 1.0);
		return;
	#endif

	Endpoint foregroundEndpoint = ResolveCurrentEndpoint(texcoord);
	vec4 volume = ResolveSpatialVolume(texcoord, foregroundEndpoint);
	volumeOutput = EncodeVolumeBuffer(volume);

	vec2 sceneUv = SrSceneSampleUv(texcoord);
	vec3 world = max(DecodeSceneColor(texture2D(colortex14, sceneUv).rgb), vec3(0.0));
	float cloudVisible;
	vec3 temporalCurrent = ResolveVolumeAndCloud(
		world,
		volume,
		texcoord,
		foregroundEndpoint,
		cloudVisible
	);
	temporalCurrent = ResolveApplyVanillaChunkBoundary(
		temporalCurrent,
		volume,
		foregroundEndpoint,
		texcoord,
		cloudVisible
	);
	sceneOutput = vec4(EncodeSceneColor(max(temporalCurrent, vec3(0.0))), 1.0);
}
