#define FOXY_FRAME_WEATHER_READER
#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/trace_common.glsl"
#include "/lib/celestial.glsl"
uniform sampler2D colortex7;
uniform int frameCounter;
#define FOXY_READ_ONLY_OPAQUE_ENDPOINT_CURRENT
#define FOXY_READ_ONLY_WATER_SEGMENT_CURRENT
#define FOXY_IMAGE_OPAQUE_ENDPOINT_CURRENT
#define FOXY_IMAGE_WATER_SEGMENT_CURRENT
#include "/lib/contracts/images.glsl"
#include "/lib/contracts/volume.glsl"
#include "/lib/volumetric.glsl"

uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform float viewWidth;
uniform float viewHeight;
uniform float far;
uniform float rainStrength;
uniform float waterEnteredAltitude;
uniform ivec2 eyeBrightnessSmooth;
uniform int isEyeInWater;
uniform vec2 temporalJitter;

varying vec2 texcoord;
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying vec3 vertexSunView;
varying vec3 vertexMoonView;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;

#include "/lib/sr.glsl"

vec2 VolumeCurrentRasterUv(const in vec2 viewUv) {
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return viewUv + temporalJitter * 0.5;
	#else
		return viewUv;
	#endif
}

Endpoint VolumeCurrentEndpoint(const in vec2 viewUv) {
	Endpoint endpoint = EndpointUnpack(
		LoadOpaqueEndpoint(SrSceneSampleUv(viewUv))
	);
	WaterSegment water = WaterSegmentUnpack(
		LoadWaterSegment(SrSceneSampleUv(VolumeCurrentRasterUv(viewUv)))
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

float VolumeTemporalDither(const in vec2 fragCoord) {

	vec2 texel = mod(floor(fragCoord), vec2(128.0));
	vec3 stbnUv = (vec3(texel, 0.0) + vec3(0.5)) / vec3(128.0, 128.0, 64.0);
	float spatialSeed = texture3D(cloudStbnVec2, stbnUv).r;
	float temporalPhase = mod(float(frameCounter), 8.0) * 0.125;
	return fract(spatialSeed + temporalPhase);
}

vec2 VolumeCompactSelectedPhase() {
	float phase = mod(float(frameCounter), 4.0);
	if (phase < 0.5) return vec2(0.0, 0.0);
	if (phase < 1.5) return vec2(1.0, 1.0);
	if (phase < 2.5) return vec2(1.0, 0.0);
	return vec2(0.0, 1.0);
}

vec2 VolumeSourceFullPixel() {
#if FOXY_VOLUME_COMPACT_CBR == 1
	return floor(gl_FragCoord.xy) * 2.0 + VolumeCompactSelectedPhase();
#else
	return floor(gl_FragCoord.xy);
#endif
}

vec2 VolumeSourceDisplayUv(const in vec2 sourcePixel, const in float volumeScale) {
	vec2 logicalSize = max(vec2(viewWidth, viewHeight) * volumeScale * SrActiveRenderScale(), vec2(1.0));
	return clamp((sourcePixel + vec2(0.5)) / logicalSize, vec2(0.0), vec2(1.0));
}

void main() {
	#if FOXY_VOLUMETRIC_LIGHT == 0
		gl_FragData[0] = vec4(0.0, 0.0, 0.0, 1.0);
		return;
	#endif

	float volumeScale = clamp(FOXY_VL_RESOLUTION, 0.10, 1.0);
	vec2 sourcePixel = VolumeSourceFullPixel();
	vec2 sourceDisplayUv = VolumeSourceDisplayUv(sourcePixel, volumeScale);
	Endpoint sceneEndpoint = VolumeCurrentEndpoint(sourceDisplayUv);
	VolumeRay sceneRay = VolumeRayFromEndpoint(
		sceneEndpoint,
		sourceDisplayUv,
		gbufferProjectionInverse,
		far
	);
	vec3 sunView = vertexSunView;
	vec3 moonView = vertexMoonView;
	vec3 shadowLightView = normalize(shadowLightPosition);
	float dither = VolumeTemporalDither(sourcePixel);
	float skyEye = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
	float blockEye = Saturate(float(eyeBrightnessSmooth.x) / 240.0);
	float caveMask = max(skyEye, blockEye * 0.38);
	vec3 skyFluence = SkyCachedUpperHemisphereFluence(colortex7);
	VolumeSample volume;
	if (isEyeInWater == 1) {
		volume = IntegrateUnderwaterVolume(
			sceneRay.fogDistance,
			sceneRay.lightDistance,
			sceneRay.extendedReach,
			sceneRay.viewDirection,
			gbufferModelViewInverse,
			shadowModelView,
			shadowProjection,
			sunView,
			moonView,
			shadowLightView,
			vertexSunLightColor,
			vertexMoonLightColor,
			vertexSkyAmbientColor,
			vertexSunAltitude,
			vertexMoonAltitude,
			cameraPosition,
			frameTimeCounter,
			rainStrength,
			dither,
			skyEye,
			waterEnteredAltitude + 1.35
		);
	} else {
		volume = IntegrateVolume(
			sceneRay.fogDistance,
			sceneRay.lightDistance,
			sceneRay.extendedReach,
			sceneRay.viewDirection,
			gbufferModelViewInverse,
			shadowModelView,
			shadowProjection,
			sunView,
			moonView,
			shadowLightView,
			vertexSunLightColor,
			vertexMoonLightColor,
			vertexSkyAmbientColor,
			skyFluence,
			vertexSunAltitude,
			vertexMoonAltitude,
			cameraPosition,
			frameTimeCounter,
			rainStrength,
			dither,
			caveMask
		);
	}

	gl_FragData[0] = EncodeVolumeBuffer(vec4(max(volume.scattering, vec3(0.0)), volume.transmittance));
}
