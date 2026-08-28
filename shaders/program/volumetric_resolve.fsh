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

varying vec2 texcoord;

#include "/lib/sr.glsl"
#include "/lib/contracts/endpoint.glsl"
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
	vec2 sourceUv = clamp((sourceTexel + vec2(0.5)) * context.sourcePixel, 0.5 * context.sourcePixel, vec2(1.0) - 0.5 * context.sourcePixel);
	Endpoint sampleEndpoint = ResolveCurrentEndpoint(sourceUv);
	float sameEndpointClass = ResolveSameEndpointClass(referenceEndpoint, sampleEndpoint);
	float sampleDistance = ResolveSceneDistance(sampleEndpoint, context);
	float depthDelta = abs(sampleDistance - referenceDistance);
	float referenceSky = ResolveSurfaceSky(referenceEndpoint);
	float surfaceThreshold = max(0.65, referenceDistance * 0.012);
	float skyThreshold = max(4.0, referenceDistance * 0.080);
	float depthThreshold = mix(surfaceThreshold, skyThreshold, referenceSky);
	float depthRatio = depthDelta / depthThreshold;
	float depthWeight = exp2(-depthRatio * depthRatio * 2.5);
	vec4 sampleVolume = ResolveDecode(texture2D(
		colortex5,
		SrLocalResourceUv(sourceUv, textureSize(colortex5, 0))
	));

	// Underwater samples may shorten to the endpoint; air may not cross silhouettes.
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

vec4 ResolveSpatialVolume(const in vec2 uv) {
	ResolveContext context = MakeResolveContext();
	vec2 sourcePos = clamp(uv, vec2(0.0), vec2(0.999999)) * context.sourceSize - vec2(0.5);
	vec2 centerTexel = floor(sourcePos + vec2(0.5));
	Endpoint referenceEndpoint = ResolveCurrentEndpoint(uv);
	float referenceDistance = ResolveSceneDistance(referenceEndpoint, context);
	vec4 sum = vec4(0.0);
	float weightSum = 0.0;
	vec4 bestVolume = vec4(0.0, 0.0, 0.0, 1.0);
	float bestScore = -1.0;

	// Current reconstruction favors nearest source texels at shadow boundaries.
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

	// Split the endpoint volume integral at cloud depth to preserve medium ordering.
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
		// Sky fades retain the same air path as the background.
		vec3 skyThroughAir = max(skyAirlight, vec3(0.0)) * Saturate(volume.a) + max(volume.rgb, vec3(0.0));
		return mix(scene, skyThroughAir, fade);
	#else
		return scene;
	#endif
}

void main() {
	#if FOXY_VOLUMETRIC_LIGHT == 0
		gl_FragData[0] = EncodeVolumeBuffer(vec4(0.0, 0.0, 0.0, 1.0));
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
		gl_FragData[1] = vec4(EncodeSceneColor(max(noVolumeWorld, vec3(0.0))), 1.0);
		return;
	#endif

	vec4 volume = ResolveSpatialVolume(texcoord);
	gl_FragData[0] = EncodeVolumeBuffer(volume);

	// Main TAA exclusively owns volume history; colortex0 is the HDR staging target.
	vec2 sceneUv = SrSceneSampleUv(texcoord);
	vec3 world = max(DecodeSceneColor(texture2D(colortex14, sceneUv).rgb), vec3(0.0));
	Endpoint foregroundEndpoint = ResolveCurrentEndpoint(texcoord);
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
	gl_FragData[1] = vec4(EncodeSceneColor(max(temporalCurrent, vec3(0.0))), 1.0);
}
