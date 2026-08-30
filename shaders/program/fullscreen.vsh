#include "/lib/settings.glsl"

uniform float viewWidth;
uniform float viewHeight;
#ifdef FOXY_FULLSCREEN_VERTEX_TEMPORAL_REPROJECTION
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
#endif
#ifdef FOXY_FULLSCREEN_VERTEX_EXPOSURE
	#ifdef FOXY_FULLSCREEN_EXPOSURE_CURRENT_STAGING
uniform sampler2D colortex11;
	#else
uniform sampler2D colortex0;
	#endif
uniform ivec2 eyeBrightnessSmooth;
uniform float rainStrength;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
#if defined(FOXY_FULLSCREEN_EXPOSURE_STATE_READ) || defined(FOXY_FULLSCREEN_EXPOSURE_STATE_UPDATE)
uniform sampler2D colortex9;
#endif
#ifdef FOXY_FULLSCREEN_EXPOSURE_STATE_UPDATE
uniform float frameTime;
uniform int frameCounter;
#endif
#endif
#include "/lib/sr.glsl"
#ifdef FOXY_FULLSCREEN_CELESTIAL_CACHE
	#include "/lib/math.glsl"
	#include "/lib/celestial.glsl"
	#include "/lib/lighting.glsl"
#ifndef FOXY_FULLSCREEN_VERTEX_EXPOSURE
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform float rainStrength;
#endif
#endif
#ifdef FOXY_FULLSCREEN_CLOUD_CACHE
	#include "/lib/math.glsl"
	#include "/lib/celestial.glsl"
	#include "/lib/lighting.glsl"
	#include "/lib/sky.glsl"
uniform mat4 gbufferModelViewInverse;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform float rainStrength;
#endif
#ifdef FOXY_FULLSCREEN_VERTEX_EXPOSURE
	#include "/lib/math.glsl"
	#include "/lib/celestial.glsl"
#endif
#ifdef FOXY_FULLSCREEN_VERTEX_EXPOSURE
	#include "/lib/lighting.glsl"
#endif

varying vec2 texcoord;
#ifdef FOXY_FULLSCREEN_CELESTIAL_CACHE
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying vec3 vertexSunView;
varying vec3 vertexMoonView;
varying vec3 vertexUpView;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;
#endif
#ifdef FOXY_FULLSCREEN_CLOUD_CACHE
varying vec3 cloudVertexSunWorld;
varying vec3 cloudVertexMoonWorld;
varying vec3 cloudVertexWorldSunLightColor;
varying vec3 cloudVertexWorldMoonLightColor;
varying vec3 cloudVertexWorldSkyAmbientColor;
varying vec3 cloudVertexSunView;
varying vec3 cloudVertexMoonView;
varying vec3 cloudVertexUpView;
varying vec3 cloudVertexLightDirView;
varying vec3 cloudVertexCompositeSunLightColor;
varying vec3 cloudVertexCompositeMoonLightColor;
varying float cloudVertexWorldSunAltitude;
varying float cloudVertexWorldMoonAltitude;
varying float cloudVertexViewSunAltitude;
varying float cloudVertexViewMoonAltitude;
varying float cloudVertexSunsetRed;
#endif
#ifdef FOXY_FULLSCREEN_VERTEX_TEMPORAL_REPROJECTION
flat out mat4 temporalViewToPreviousClip;
flat out vec4 temporalCameraPreviousClipOffset;
#endif
#ifdef FOXY_FULLSCREEN_VERTEX_EXPOSURE
varying float finalVertexExposure;
varying float presentationSunAltitude;

#ifdef FOXY_FULLSCREEN_EXPOSURE_STATE_UPDATE
vec2 FullscreenExposureSceneUv(const in vec2 uv) {
	return clamp(uv, vec2(0.0), vec2(1.0));
}

float FullscreenExposureLuma(const in vec2 uv) {
	#ifdef FOXY_FULLSCREEN_EXPOSURE_CURRENT_STAGING
	vec3 color = DecodeSceneColor(texture2D(colortex11, FullscreenExposureSceneUv(uv)).rgb);
	#else
	vec3 color = DecodeSceneColor(texture2D(colortex0, FullscreenExposureSceneUv(uv)).rgb);
	#endif
	return Luma(color);
}

float FullscreenExposureEv(const in vec2 uv) {
	return log2(max(FullscreenExposureLuma(uv), 1.0e-6));
}

const vec2 EXPOSURE_SAMPLE_UV[32] = vec2[32](
	vec2(0.1250, 0.1250), vec2(0.3750, 0.1250), vec2(0.6250, 0.1250), vec2(0.8750, 0.1250),
	vec2(0.1250, 0.3750), vec2(0.3750, 0.3750), vec2(0.6250, 0.3750), vec2(0.8750, 0.3750),
	vec2(0.1250, 0.6250), vec2(0.3750, 0.6250), vec2(0.6250, 0.6250), vec2(0.8750, 0.6250),
	vec2(0.1250, 0.8750), vec2(0.3750, 0.8750), vec2(0.6250, 0.8750), vec2(0.8750, 0.8750),
	vec2(0.3125, 0.3125), vec2(0.4375, 0.3125), vec2(0.5625, 0.3125), vec2(0.6875, 0.3125),
	vec2(0.3125, 0.4375), vec2(0.4375, 0.4375), vec2(0.5625, 0.4375), vec2(0.6875, 0.4375),
	vec2(0.3125, 0.5625), vec2(0.4375, 0.5625), vec2(0.5625, 0.5625), vec2(0.6875, 0.5625),
	vec2(0.3125, 0.6875), vec2(0.4375, 0.6875), vec2(0.5625, 0.6875), vec2(0.6875, 0.6875)
);

float FullscreenPercentileMeterEv() {
	float sampleEv[32];
	for (int i = 0; i < 32; ++i) {
		sampleEv[i] = FullscreenExposureEv(EXPOSURE_SAMPLE_UV[i]);
	}

for (int sequence = 2; sequence <= 32; sequence *= 2) {
		for (int stride = sequence / 2; stride > 0; stride /= 2) {
			for (int i = 0; i < 32; ++i) {
				int partner = i ^ stride;
				if (partner > i) {
					float a = sampleEv[i];
					float b = sampleEv[partner];
					bool ascending = (i & sequence) == 0;
					sampleEv[i] = ascending ? min(a, b) : max(a, b);
					sampleEv[partner] = ascending ? max(a, b) : min(a, b);
				}
			}
		}
	}

	float meterEv = 0.0;
	for (int i = 13; i < 29; ++i) {
		meterEv += sampleEv[i];
	}
	return meterEv * (1.0 / 16.0);
}

float FullscreenAutoExposure() {
	return AutoExposureFromMeterEv(FullscreenPercentileMeterEv());
}
#endif
vec2 FullscreenExposureStateSample() {
	vec2 stateUv = vec2(0.5 / max(viewWidth, 1.0), 0.5 / max(viewHeight, 1.0));
	return texture2D(colortex9, stateUv).rg;
}

bool FullscreenExposureStateValid(const in vec2 state) {
	return state.x == state.x && state.y < -0.5 && state.x >= FOXY_PRESENTATION_EXPOSURE_STATE_MIN && state.x <= FOXY_PRESENTATION_EXPOSURE_STATE_MAX;
}

#ifdef FOXY_FULLSCREEN_EXPOSURE_STATE_READ
float FullscreenReadExposureState() {
	vec2 state = FullscreenExposureStateSample();
	return FullscreenExposureStateValid(state) ? state.x : 1.0;
}
#endif

#ifdef FOXY_FULLSCREEN_EXPOSURE_STATE_UPDATE
float FullscreenAdaptExposure(const in float targetExposure) {
	if (FOXY_PRESENTATION_AUTO_WEIGHT <= 0.0001) {
		return 1.0;
	}
	vec2 state = FullscreenExposureStateSample();
	if (!FullscreenExposureStateValid(state) || frameCounter < 2) {
		return targetExposure;
	}
	float previousEv = log2(max(state.x, 1.0e-4));
	float targetEv = log2(max(targetExposure, 1.0e-4));
	float evDelta = targetEv - previousEv;
	float distanceEv = abs(evDelta);
	float speedStops = evDelta < 0.0 ? 3.0 : 1.0;
	float deltaTime = clamp(frameTime, 0.0, 0.10);
	float transitionEv = 1.5;
	float stepEv;
	if (distanceEv > transitionEv) {
		stepEv = min(distanceEv, speedStops * deltaTime);
	} else {
		float response = 1.0 - exp(-(speedStops / transitionEv) * deltaTime);
		stepEv = distanceEv * response;
	}
	float adaptedEv = previousEv + sign(evDelta) * stepEv;
	return clamp(exp2(adaptedEv), FOXY_PRESENTATION_EXPOSURE_MIN, FOXY_PRESENTATION_EXPOSURE_MAX);
}
#endif
#endif
void main() {
	gl_Position = ftransform();
	#ifdef FOXY_SR_RENDER_DOMAIN_PASS
		SrScaleClipPosition(gl_Position);
	#endif
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	#ifdef FOXY_FULLSCREEN_CELESTIAL_CACHE
		vec3 celestialUp = normalize(upPosition);
		vec3 celestialSun;
		vec3 celestialMoon;
		StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, celestialUp, celestialSun, celestialMoon);
		vertexSunAltitude = dot(celestialSun, celestialUp);
		vertexMoonAltitude = dot(celestialMoon, celestialUp);
		vertexSunView = celestialSun;
		vertexMoonView = celestialMoon;
		vertexUpView = celestialUp;
		vertexSunLightColor = SunColor(vertexSunAltitude, rainStrength);
		vertexMoonLightColor = MoonColor(vertexMoonAltitude, rainStrength);
		vertexSkyAmbientColor = SkyAmbientColor(vertexSunAltitude, rainStrength);
	#endif
	#ifdef FOXY_FULLSCREEN_CLOUD_CACHE
		vec3 cloudUpView = normalize(upPosition);
		vec3 cloudSunView;
		vec3 cloudMoonView;
		StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, cloudUpView, cloudSunView, cloudMoonView);
		vec3 cloudSunWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, cloudSunView));
		vec3 cloudMoonWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, cloudMoonView));
		float cloudWorldSunAltitude = cloudSunWorld.y;
		float cloudWorldMoonAltitude = cloudMoonWorld.y;
		float cloudViewSunAltitude = dot(cloudSunView, cloudUpView);
		float cloudViewMoonAltitude = dot(cloudMoonView, cloudUpView);
		float cloudRain = Saturate(rainStrength);
		float cloudSolarVisibility = SolarDiscVisibility(cloudViewSunAltitude);
		cloudVertexSunWorld = cloudSunWorld;
		cloudVertexMoonWorld = cloudMoonWorld;
		cloudVertexWorldSunAltitude = cloudWorldSunAltitude;
		cloudVertexWorldMoonAltitude = cloudWorldMoonAltitude;
		cloudVertexWorldSunLightColor = SunColor(cloudWorldSunAltitude, rainStrength);
		cloudVertexWorldMoonLightColor = MoonColor(cloudWorldMoonAltitude, rainStrength);
		cloudVertexWorldSkyAmbientColor = SkyAmbientColor(cloudWorldSunAltitude, rainStrength);
		cloudVertexSunView = cloudSunView;
		cloudVertexMoonView = cloudMoonView;
		cloudVertexUpView = cloudUpView;
		cloudVertexLightDirView = normalize(mix(cloudMoonView, cloudSunView, step(0.01, cloudSolarVisibility)));
		cloudVertexViewSunAltitude = cloudViewSunAltitude;
		cloudVertexViewMoonAltitude = cloudViewMoonAltitude;
		cloudVertexCompositeSunLightColor = SunColor(max(clamp(cloudViewSunAltitude, -1.0, 1.0), -0.045), cloudRain);
		cloudVertexCompositeMoonLightColor = MoonColor(cloudViewMoonAltitude, cloudRain);
		cloudVertexSunsetRed = SkySunsetRedAmount(clamp(cloudViewSunAltitude, -1.0, 1.0));
	#endif
	#ifdef FOXY_FULLSCREEN_VERTEX_TEMPORAL_REPROJECTION
		mat4 previousViewProjection = gbufferPreviousProjection * gbufferPreviousModelView;
		temporalViewToPreviousClip = previousViewProjection * gbufferModelViewInverse;
		temporalCameraPreviousClipOffset = previousViewProjection * vec4(cameraPosition - previousCameraPosition, 0.0);
	#endif
	#ifdef FOXY_FULLSCREEN_VERTEX_EXPOSURE
		#ifdef FOXY_FULLSCREEN_EXPOSURE_STATE_READ
			finalVertexExposure = FullscreenReadExposureState();
			#ifdef FOXY_FULLSCREEN_CELESTIAL_CACHE
				presentationSunAltitude = vertexSunAltitude;
			#else
				vec3 exposureUp = normalize(upPosition);
				vec3 exposureSun;
				vec3 exposureMoon;
				StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, exposureUp, exposureSun, exposureMoon);
				presentationSunAltitude = dot(exposureSun, exposureUp);
			#endif
		#elif defined(FOXY_FULLSCREEN_EXPOSURE_STATE_UPDATE)
			finalVertexExposure = FullscreenAdaptExposure(FullscreenAutoExposure());
			presentationSunAltitude = 0.0;
		#else
			finalVertexExposure = 1.0;
			presentationSunAltitude = 0.0;
		#endif
	#endif
}
