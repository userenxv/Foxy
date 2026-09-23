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

#include "/features/clouds/temporal_resolve.glsl"

void CloudWriteComposite(const in vec4 sceneOut, const in vec4 historyOut, const in vec4 metaOut) {
	vec4 storedMeta = metaOut;
	if (all(equal(ivec2(gl_FragCoord.xy), ivec2(0)))) {
		storedMeta = vec4(texelFetch(colortex9, ivec2(0), 0).rg, 0.0, 0.0);
	}
	gl_FragData[0] = sceneOut;
	gl_FragData[1] = CloudEncodeHistoryBuffer(historyOut);
	gl_FragData[2] = storedMeta;
}

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
		#if FOXY_SKY_VANILLA_CELESTIALS == 0 && FOXY_SKY_VANILLA_MOON == 1 && FOXY_BLACKHOLE_MOON == 0
			sky += VanillaMoonDisk(viewDir, moonView, upView, moonAltitude, rainStrength);
		#endif
		return sky;
	#endif
}

void main() {
	vec2 renderTexcoord = SrSceneSampleUv(texcoord);
	vec4 scene = texture2D(colortex0, renderTexcoord);
	scene.rgb = DecodeSceneColor(scene.rgb);

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

			if (EndpointValid(opaqueEndpoint) < 0.5) {
				float celestialTransmittance = pow(max(1.0 - visibleCloud.a, 0.0), 4.0);
				scene.rgb -= skyCelestial *
					(1.0 - celestialTransmittance);
			}
		}
	#endif

StoreOpaqueEndpoint(renderTexcoord, EndpointPack(opaqueEndpoint));
	StoreCloudEndpoint(renderTexcoord, EndpointPack(layerEndpoint));
	StoreCloudLayer(renderTexcoord, cloudLayer);
	CloudWriteComposite(
		vec4(EncodeSceneColor(max(scene.rgb, vec3(0.0))), scene.a),
		cloudHistory,
		cloudMeta
	);
}
