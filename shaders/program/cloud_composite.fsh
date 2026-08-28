#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/first_person_depth.glsl"
#include "/lib/contracts/material.glsl"
#include "/lib/lighting.glsl"
#include "/lib/sky.glsl"
#include "/lib/celestial.glsl"
#include "/lib/dimension_sky.glsl"
#include "/lib/nasa_galaxy.glsl"
#include "/lib/vanilla_moon.glsl"
#include "/lib/cbr.glsl"
#include "/lib/cloud_coverage.glsl"

uniform sampler2D colortex0;
uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex10;
uniform sampler2D colortex7;
uniform sampler2D colortex8;
uniform sampler2D colortex9;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTime;
uniform float frameTimeCounter;
uniform float rainStrength;
uniform int frameCounter;
uniform vec2 temporalJitter;

const float CLOUD_COMPOSITE_TRACE_LIMIT = 60000.0;
const float CLOUD_COMPOSITE_PLANET_RADIUS = 6371000.0;
const float CLOUD_COMPOSITE_BASE_VARIATION = 120.0;
const float CLOUD_CBR_HISTORY_FRAMES = 16.0;
const float CLOUD_CBR_ACTIVE_HISTORY_WEIGHT = 0.75;

#include "/lib/sr.glsl"
#include "/lib/contracts/endpoint.glsl"
#define FOXY_IMAGE_OPAQUE_ENDPOINT_CURRENT
#define FOXY_IMAGE_LAYER_ENDPOINT_PING_PONG
#define FOXY_IMAGE_CLOUD_LAYER_CURRENT
#include "/lib/contracts/images.glsl"

varying vec2 texcoord;
varying vec3 cloudVertexSunView;
varying vec3 cloudVertexMoonView;
varying vec3 cloudVertexUpView;
varying vec3 cloudVertexLightDirView;
varying vec3 cloudVertexCompositeSunLightColor;
varying vec3 cloudVertexCompositeMoonLightColor;
varying float cloudVertexViewSunAltitude;
varying float cloudVertexViewMoonAltitude;
varying float cloudVertexSunsetRed;

float CloudSafeDivisor(const in float x) {
	if (abs(x) < 1.0e-5) {
		return x < 0.0 ? -1.0e-5 : 1.0e-5;
	}
	return x;
}

vec3 CloudUnpremultiply(const in vec4 cloud) {
	return cloud.rgb / CloudSafeDivisor(cloud.a);
}

vec4 CloudCompositeClamp(const in vec4 cloud) {
	float alpha = Saturate(cloud.a);
	vec3 color = min(max(cloud.rgb, vec3(0.0)), vec3(alpha * 5.60 + 0.18));
	return vec4(color, alpha);
}

vec3 CloudCompositeAerialPerspective(
	const in vec3 cloudPremul,
	const in float cloudAlpha,
	const in float cloudDistance,
	const in vec3 viewDir
) {
	if (cloudAlpha <= 0.00004 || cloudDistance <= 1.0) {
		return cloudPremul;
	}

	vec3 rayDir = normalize(viewDir);
	vec3 upView = cloudVertexUpView;
	vec3 sunView = cloudVertexSunView;
	vec3 moonView = cloudVertexMoonView;
	float sunAltitude = cloudVertexViewSunAltitude;
	float moonAltitude = cloudVertexViewMoonAltitude;
	float rain = Saturate(rainStrength);
	float solarDiscVisibility = SolarDiscVisibility(sunAltitude);
	vec3 lightDir = cloudVertexLightDirView;
	float lowSun = cloudVertexSunsetRed;
	vec3 sunLight = cloudVertexCompositeSunLightColor;
	vec3 lightColor = sunLight * solarDiscVisibility;
	lightColor += cloudVertexCompositeMoonLightColor * (1.0 - solarDiscVisibility);
	vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * rayDir);
	vec3 skyLutColor = DecodeSkyLutColor(texture2D(colortex7, SkyViewLutUv(worldDir)).rgb);
	vec3 horizonDir = normalize(mix(worldDir, normalize(vec3(worldDir.x, 0.035, worldDir.z)), 0.65));
	vec3 horizonSkyColor = DecodeSkyLutColor(texture2D(colortex7, SkyViewLutUv(horizonDir)).rgb);

	const vec3 betaRayleigh = vec3(5.802, 13.558, 33.100) * 0.000001;
	const vec3 betaMieScatter = vec3(4.800) * 0.000001;
	const vec3 betaMieExtinct = vec3(5.400) * 0.000001;
	const float rayleighHeight = 8000.0;
	const float mieHeight = 1200.0;

	float distance = min(cloudDistance, CLOUD_COMPOSITE_TRACE_LIMIT);
	float viewUp = dot(rayDir, upView);
	float viewFlatness = 1.0 - abs(viewUp);
	float horizonBoost = 0.45 + viewFlatness * viewFlatness * 1.35;
	float height = max(cameraPosition.y - FOXY_WORLD_FOG_HEIGHT, 0.0);
	float densityRayleigh = exp(-height / rayleighHeight);
	float densityMie = exp(-height / mieHeight) * mix(1.0, 1.85, rain);
	float opticalScale = (0.36 + max(FOXY_FOG_DENSITY, 0.0) * 0.42 + max(FOXY_WORLD_FOG_STRENGTH, 0.0) * 0.28) * horizonBoost;
	vec3 opticalDepth = (betaRayleigh * densityRayleigh + betaMieExtinct * densityMie) * distance * opticalScale;
	vec3 airTransmittance = exp(-opticalDepth);

	float mu = dot(rayDir, normalize(lightDir));
	float rayleighPhase = RayleighPhase(mu);
	float miePhase = MiePhase(mu, mix(0.56, 0.68, Saturate(FOXY_FOG_DENSITY)));
	vec3 phaseScatter = lightColor * (betaRayleigh * rayleighPhase + betaMieScatter * miePhase) / max(betaRayleigh + betaMieExtinct, vec3(1.0e-6));
	vec3 clearAirColor = mix(skyLutColor, horizonSkyColor, viewFlatness * 0.62);
	clearAirColor = mix(clearAirColor, phaseScatter, (0.06 + 0.08 * viewFlatness) * (1.0 - lowSun * 0.55));
	vec3 airScatter = max((1.0 - airTransmittance) * clearAirColor, vec3(0.0));

	return cloudPremul * airTransmittance + airScatter * cloudAlpha;
}

vec4 CloudEncodeHistoryBuffer(const in vec4 cloud) {
	return vec4(EncodeSceneColor(max(cloud.rgb, vec3(0.0))), Saturate(cloud.a));
}

vec4 CloudDecodeHistoryBuffer(const in vec4 cloud) {
	return CloudCompositeClamp(vec4(DecodeSceneColor(cloud.rgb), Saturate(cloud.a)));
}

ivec2 CloudRenderSize() {
	return max(ivec2(floor(vec2(viewWidth, viewHeight) * SrActiveRenderScale())), ivec2(1));
}

ivec2 CloudFullPixel(const in vec2 uv) {
	ivec2 renderSize = CloudRenderSize();
	return clamp(ivec2(floor(clamp(uv, vec2(0.0), vec2(0.999999)) * vec2(renderSize))), ivec2(0), renderSize - ivec2(1));
}

ivec2 CloudActiveSourceSize() {
	ivec2 requiredSize = (CloudRenderSize() + ivec2(CBR_BLOCK_SIZE - 1)) / CBR_BLOCK_SIZE;
	return max(min(requiredSize, textureSize(colortex1, 0)), ivec2(1));
}

ivec2 CloudClampSourcePixel(const in ivec2 pixel) {
	ivec2 sourceSize = CloudActiveSourceSize();
	return clamp(pixel, ivec2(0), sourceSize - ivec2(1));
}

vec4 CloudReadSourceCompact(const in ivec2 compactPixel) {
	return CloudDecodeHistoryBuffer(texelFetch(colortex1, CloudClampSourcePixel(compactPixel), 0));
}

vec4 CloudReadDistanceCompact(const in ivec2 compactPixel) {
	ivec2 sourceSize = max(min(CloudActiveSourceSize(), textureSize(colortex10, 0)), ivec2(1));
	return texelFetch(colortex10, clamp(compactPixel, ivec2(0), sourceSize - ivec2(1)), 0);
}

void CloudCurrentLattice(const in vec2 uv, out ivec2 basePixel, out vec2 fraction) {
	vec2 fullPosition = clamp(uv, vec2(0.0), vec2(1.0)) * vec2(CloudRenderSize()) - vec2(0.5);
	vec2 latticePosition = (fullPosition - vec2(CbrPhaseOffset(frameCounter))) / float(CBR_BLOCK_SIZE);
	basePixel = ivec2(floor(latticePosition));
	fraction = clamp(fract(latticePosition), vec2(0.0), vec2(1.0));
}

vec4 CloudReadCurrentSpatial(const in vec2 uv) {
	ivec2 basePixel;
	vec2 fraction;
	CloudCurrentLattice(uv, basePixel, fraction);
	vec4 s00 = CloudReadSourceCompact(basePixel);
	vec4 s10 = CloudReadSourceCompact(basePixel + ivec2(1, 0));
	vec4 s01 = CloudReadSourceCompact(basePixel + ivec2(0, 1));
	vec4 s11 = CloudReadSourceCompact(basePixel + ivec2(1, 1));
	return CloudCompositeClamp(mix(mix(s00, s10, fraction.x), mix(s01, s11, fraction.x), fraction.y));
}

vec4 CloudReadCurrentPoint(const in vec2 uv) {
	return CloudReadSourceCompact(CbrCompactPixel(CloudFullPixel(uv)));
}

vec4 CloudReadCurrentDistance(const in vec2 uv) {
	ivec2 basePixel;
	vec2 fraction;
	CloudCurrentLattice(uv, basePixel, fraction);
	vec4 d00 = CloudReadDistanceCompact(basePixel);
	vec4 d10 = CloudReadDistanceCompact(basePixel + ivec2(1, 0));
	vec4 d01 = CloudReadDistanceCompact(basePixel + ivec2(0, 1));
	vec4 d11 = CloudReadDistanceCompact(basePixel + ivec2(1, 1));
	return mix(mix(d00, d10, fraction.x), mix(d01, d11, fraction.x), fraction.y);
}

vec4 CloudReadHistory(const in vec2 uv) {
	return CloudDecodeHistoryBuffer(texture2D(
		colortex8,
		SrLocalResourceUv(uv, textureSize(colortex8, 0))
	));
}

vec4 CloudReadHistoryMeta(const in vec2 uv) {
	ivec2 renderSize = CloudRenderSize();
	ivec2 historyPixel = clamp(
		ivec2(floor(clamp(uv, vec2(0.0), vec2(0.999999)) * vec2(renderSize))),
		ivec2(0),
		renderSize - ivec2(1)
	);
	if (all(equal(historyPixel, ivec2(0)))) {
		historyPixel.x = min(1, renderSize.x - 1);
	}
	return texelFetch(colortex9, historyPixel, 0);
}

void CloudWriteComposite(const in vec4 sceneOut, const in vec4 historyOut, const in vec4 metaOut) {
	vec4 storedMeta = metaOut;
	if (all(equal(ivec2(gl_FragCoord.xy), ivec2(0)))) {
		storedMeta = vec4(texelFetch(colortex9, ivec2(0), 0).rg, 0.0, 0.0);
	}
	gl_FragData[0] = sceneOut;
	gl_FragData[1] = CloudEncodeHistoryBuffer(historyOut);
	gl_FragData[2] = storedMeta;
}

vec3 CloudScreenViewRay(const in vec2 uv) {
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 view = gbufferProjectionInverse * vec4(ndc, 1.0, 1.0);
	return normalize(view.xyz / CloudSafeDivisor(view.w));
}

vec3 CloudCameraWorldPos() {
	return cameraPosition + gbufferModelViewInverse[3].xyz;
}

vec3 CloudPreviousViewOffset() {
	vec3 previousViewTranslation = gbufferPreviousModelView[3].xyz;
	return -vec3(
		dot(gbufferPreviousModelView[0].xyz, previousViewTranslation),
		dot(gbufferPreviousModelView[1].xyz, previousViewTranslation),
		dot(gbufferPreviousModelView[2].xyz, previousViewTranslation)
	);
}

vec3 CloudCompositeWindDir() {
	return normalize(vec3(0.78, 0.0, 0.62));
}

vec2 CloudCompositeSphereIntersection(
	const in vec3 rayOrigin,
	const in vec3 rayDir,
	const in float radius
) {
	vec3 localOrigin = vec3(0.0, CLOUD_COMPOSITE_PLANET_RADIUS + rayOrigin.y, 0.0);
	float b = dot(localOrigin, rayDir);
	float c = dot(localOrigin, localOrigin) - radius * radius;
	float h = b * b - c;
	if (h < 0.0) {
		return vec2(1.0e8, -1.0e8);
	}
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}

void CloudCompositeLayerInterval(
	const in vec3 rayOrigin,
	const in vec3 rayDir,
	const in float bottom,
	const in float top,
	out float tNear,
	out float tFar
) {
	float altitude = rayOrigin.y;
	if (altitude < bottom && rayDir.y <= 0.0) {
		tNear = 1.0e8;
		tFar = -1.0e8;
		return;
	}
	if (altitude > top && rayDir.y >= 0.0) {
		tNear = 1.0e8;
		tFar = -1.0e8;
		return;
	}

	vec2 outer = CloudCompositeSphereIntersection(rayOrigin, rayDir, CLOUD_COMPOSITE_PLANET_RADIUS + top);
	vec2 inner = CloudCompositeSphereIntersection(rayOrigin, rayDir, CLOUD_COMPOSITE_PLANET_RADIUS + bottom);
	tNear = 1.0e8;
	tFar = -1.0e8;

	if (outer.y <= 0.0) {
		return;
	}
	if (altitude < bottom) {
		tNear = max(inner.y, 0.0);
		tFar = outer.y;
	} else if (altitude > top) {
		tNear = max(outer.x, 0.0);
		tFar = inner.x > tNear ? inner.x : outer.y;
	} else {
		tNear = 0.0;
		tFar = rayDir.y < 0.0 && inner.x > 0.0 ? inner.x : outer.y;
	}

	tNear = max(tNear, 0.0);
	tFar = min(tFar, CLOUD_COMPOSITE_TRACE_LIMIT);
	if (tFar <= tNear) {
		tNear = 1.0e8;
		tFar = -1.0e8;
	}
}

float CloudStableLayerDistance(const in vec3 cameraWorldPos, const in vec3 worldDir) {
	vec3 referenceCameraWorldPos = CloudWorldToReference(cameraWorldPos);
	float bottom = FOXY_CLOUD_HEIGHT - CLOUD_COMPOSITE_BASE_VARIATION;
	float top = FOXY_CLOUD_HEIGHT + FOXY_CLOUD_THICKNESS;
	float tNear;
	float tFar;
	CloudCompositeLayerInterval(referenceCameraWorldPos, worldDir, bottom, top, tNear, tFar);
	if (tFar <= tNear) {
		return CloudReferenceDistanceToWorld(CLOUD_COMPOSITE_TRACE_LIMIT);
	}
	float traceLength = tFar - tNear;
	float viewFlatness = 1.0 - abs(worldDir.y);
	float layerWeight = mix(0.43, 0.52, smoothstep(0.55, 0.98, viewFlatness));
	float referenceDistance = clamp(tNear + traceLength * layerWeight, 0.0, CLOUD_COMPOSITE_TRACE_LIMIT);
	return CloudReferenceDistanceToWorld(referenceDistance);
}

vec2 CloudPreviousUv(
	const in vec3 cameraWorldPos,
	const in vec3 worldDir,
	const in float cloudDistance,
	const in float timeDelta,
	out float valid
) {
	valid = 0.0;
	float reprojectionDistance = min(cloudDistance, CLOUD_COMPOSITE_TRACE_LIMIT * 0.982);
	vec3 cloudWorldPos = cameraWorldPos + worldDir * reprojectionDistance;
	cloudWorldPos -= CloudCompositeWindDir() * (FOXY_CLOUD_SPEED * 22.0 * CloudWorldScale() * timeDelta);
	vec3 previousScenePos = cloudWorldPos - cameraPosition;
	previousScenePos += cameraPosition - previousCameraPosition;
	previousScenePos += CloudPreviousViewOffset() - gbufferModelViewInverse[3].xyz;
	vec4 previousView = gbufferPreviousModelView * vec4(previousScenePos, 1.0);
	if (previousView.z > -0.02) {
		return texcoord;
	}
	vec4 previousClip = gbufferPreviousProjection * previousView;
	vec2 previousUv = previousClip.xy / CloudSafeDivisor(previousClip.w) * 0.5 + 0.5;
	if (previousUv.x > 0.001 && previousUv.x < 0.999 && previousUv.y > 0.001 && previousUv.y < 0.999) {
		valid = 1.0;
	}
	return previousUv;
}

vec4 CloudResolveCbr(
	const in vec2 uv,
	out vec4 metaOut
) {
	ivec2 renderSize = CloudRenderSize();
	ivec2 fullPixel = CloudFullPixel(uv);
	float phaseActive = CbrPixelActive(fullPixel, renderSize, frameCounter);
	vec4 currentPoint = CloudReadCurrentPoint(uv);

	vec3 viewDir = CloudScreenViewRay(uv);
	vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
	vec3 cloudCameraWorldPos = CloudCameraWorldPos();
	vec4 currentDistanceData = CloudReadCurrentDistance(uv);
	float currentDistanceSupport = smoothstep(0.00004, 0.025, currentPoint.a);
	float sourceDistance = Saturate(currentDistanceData.r) * CLOUD_COMPOSITE_TRACE_LIMIT;
	float currentDistance = sourceDistance;
	if (currentDistanceSupport < 1.0) {
		float stableDistance = CloudStableLayerDistance(cloudCameraWorldPos, worldDir);
		currentDistance = mix(stableDistance, sourceDistance, currentDistanceSupport);
	}

	float uvHistoryValid;
	vec2 previousUv = CloudPreviousUv(cloudCameraWorldPos, worldDir, currentDistance, max(frameTime, 0.0), uvHistoryValid);
	vec4 historyMeta = CloudReadHistoryMeta(previousUv);
	float historyFrames = Saturate(historyMeta.r) * CLOUD_CBR_HISTORY_FRAMES;
	float finiteHistory = any(isnan(historyMeta)) || any(isinf(historyMeta)) ? 0.0 : 1.0;
	float frameValid = 1.0 - smoothstep(0.080, 0.220, max(frameTime, 0.0));
	float startupValid = step(1.5, float(frameCounter));
	float hardHistoryValid = uvHistoryValid * step(0.5, historyFrames) * finiteHistory * frameValid * startupValid;

	float historyDistance = Saturate(historyMeta.g) * CLOUD_COMPOSITE_TRACE_LIMIT;
	vec4 resolved = currentPoint;
	float resolvedDistance = currentDistance;
	if (hardHistoryValid > 0.5) {
		vec4 history = CloudReadHistory(previousUv);
		if (any(isnan(history)) || any(isinf(history))) {
			hardHistoryValid = 0.0;
			if (phaseActive < 0.5) {
				resolved = CloudReadCurrentSpatial(uv);
			}
		} else {
			if (phaseActive > 0.5) {
				resolved = CloudCompositeClamp(mix(currentPoint, history, CLOUD_CBR_ACTIVE_HISTORY_WEIGHT));
				resolvedDistance = mix(currentDistance, historyDistance, CLOUD_CBR_ACTIVE_HISTORY_WEIGHT);
			} else {
				resolved = history;
				resolvedDistance = historyDistance;
			}
		}
	} else if (phaseActive < 0.5) {
		resolved = CloudReadCurrentSpatial(uv);
	}

	resolved = CloudCompositeClamp(resolved);
	float newFrames = hardHistoryValid > 0.5 ? min(historyFrames + 1.0, CLOUD_CBR_HISTORY_FRAMES) : 1.0;
	metaOut = vec4(
		newFrames / CLOUD_CBR_HISTORY_FRAMES,
		Saturate(resolvedDistance / CLOUD_COMPOSITE_TRACE_LIMIT),
		0.0,
		0.0
	);

	return resolved;
}

// Reconstruct sky only on the depth-clear background.
vec3 CloudCompositeSky(const in vec2 uv, out vec3 celestialOut) {
	vec3 viewDir = CloudScreenViewRay(uv);
	vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
	vec3 sunView = normalize(cloudVertexSunView);
	vec3 moonView = normalize(cloudVertexMoonView);
	vec3 upView = normalize(cloudVertexUpView);
	float sunAltitude = cloudVertexViewSunAltitude;
	float moonAltitude = cloudVertexViewMoonAltitude;

	#if defined(FOXY_DIM_NETHER)
		return NetherEnvironment(worldDir);
	#elif defined(FOXY_DIM_END)
		return EndEnvironment(worldDir, frameTimeCounter);
	#else
		vec3 sky = DecodeSkyLutColor(texture2D(colortex7, SkyViewLutUv(worldDir)).rgb);
		#if FOXY_NASA_GALAXY == 1
			sky += NasaGalaxyRadiance(worldDir, sunAltitude, rainStrength, worldTime);
		#endif
		celestialOut = SunMoonDisks(viewDir, sunView, moonView, upView, sunAltitude, moonAltitude, rainStrength);
		sky += celestialOut;
		#if FOXY_SKY_VANILLA_CELESTIALS == 0 && FOXY_SKY_VANILLA_MOON == 1
			sky += VanillaMoonDisk(viewDir, moonView, upView, moonAltitude, rainStrength);
		#endif
		return sky;
	#endif
}

void main() {
	vec2 renderTexcoord = SrSceneSampleUv(texcoord);
	vec4 scene = texture2D(colortex0, renderTexcoord);
	scene.rgb = DecodeSceneColor(scene.rgb);
	// Endpoint ownership uses jittered raster UV; cloud history uses stable view UV.
	vec2 opaqueRasterUv = texcoord;
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		opaqueRasterUv += temporalJitter * 0.5;
	#endif
	vec2 opaqueRenderUv = SrSceneSampleUv(opaqueRasterUv);
	float currentDepth = texture2D(depthtex0, opaqueRenderUv).r;
	float firstPerson = FirstPersonDepthMask(currentDepth);
	vec4 currentTransmissiveMaterial = texture2D(colortex2, opaqueRenderUv);
	float currentWaterOrGlass = max(
		MaterialIsWater(currentTransmissiveMaterial),
		MaterialIsGlass(currentTransmissiveMaterial)
	);
	float opaqueDepth = texture2D(depthtex1, opaqueRenderUv).r;
	float depth = mix(
		currentDepth,
		opaqueDepth,
		currentWaterOrGlass * (1.0 - firstPerson)
	);
	depth = FirstPersonProjectionDepth(depth, firstPerson);
	Endpoint opaqueEndpoint = ResolveOpaqueEndpoint(
		texcoord,
		opaqueRenderUv,
		depth,
		gbufferProjectionInverse
	);
	// Resolve Voxy endpoint ownership before testing the vanilla depth-clear sky.
	vec3 skyCelestial = vec3(0.0);
	if (EndpointValid(opaqueEndpoint) < 0.5) {
		scene.rgb = CloudCompositeSky(texcoord, skyCelestial);
		scene.a = 1.0;
	}
	Endpoint layerEndpoint = opaqueEndpoint;
	vec4 cloudHistory = vec4(0.0);
	vec4 cloudMeta = vec4(0.0);
	vec4 cloudLayer = vec4(0.0);

	#if FOXY_CLOUDS == 1 && !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
		cloudHistory = CloudResolveCbr(texcoord, cloudMeta);
		float cloudDistance = cloudMeta.g * CLOUD_COMPOSITE_TRACE_LIMIT;
		Endpoint cloudEndpoint = ResolveCloudEndpoint(
			opaqueEndpoint,
			cloudDistance,
			cloudHistory.a
		);
		float cloudVisible = 1.0 - step(
			0.5,
			abs(cloudEndpoint.owner - FOXY_ENDPOINT_OWNER_CLOUD)
		);
		vec4 visibleCloud = cloudHistory * cloudVisible;
		vec3 viewDir = normalize(CloudScreenViewRay(texcoord));
		float referenceCloudDistance = CloudWorldDistanceToReference(cloudDistance);
		vec3 displayCloud = CloudCompositeAerialPerspective(
			visibleCloud.rgb,
			visibleCloud.a,
			referenceCloudDistance,
			viewDir
		);
		cloudLayer = vec4(displayCloud, visibleCloud.a);
		if (cloudVisible > 0.5) {
			layerEndpoint = cloudEndpoint;
			// Solar transmittance uses a longer optical path than camera-ray coverage.
			if (EndpointValid(opaqueEndpoint) < 0.5) {
				float celestialTransmittance = pow(max(1.0 - visibleCloud.a, 0.0), 4.0);
				scene.rgb -= skyCelestial *
					(1.0 - celestialTransmittance);
			}
		}
	#endif

	// Current endpoints use the packed resource domain; composite5 republishes them.
	StoreOpaqueEndpoint(renderTexcoord, EndpointPack(opaqueEndpoint));
	StoreCloudEndpoint(renderTexcoord, EndpointPack(layerEndpoint));
	StoreCloudLayer(renderTexcoord, cloudLayer);
	CloudWriteComposite(
		vec4(EncodeSceneColor(max(scene.rgb, vec3(0.0))), scene.a),
		cloudHistory,
		cloudMeta
	);
}
