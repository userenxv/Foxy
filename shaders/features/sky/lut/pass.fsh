#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/sky.glsl"
#include "/lib/celestial.glsl"
#include "/lib/clouds.glsl"
#include "/lib/dimension_sky.glsl"

uniform mat4 gbufferModelViewInverse;
uniform sampler2D colortex7;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform float rainStrength;
uniform float frameTimeCounter;
uniform int frameCounter;

varying vec2 texcoord;

void main() {
	#if defined(FOXY_DIM_NETHER) || defined(FOXY_DIM_END)
		vec2 dimensionUv = clamp(texcoord, vec2(0.0), vec2(1.0));
		vec3 dimensionSky;
		if (SkyLutCacheColumn(gl_FragCoord.xy) > 0.5) {
			float cacheRow = floor(gl_FragCoord.y);
			#if defined(FOXY_DIM_NETHER)
				dimensionSky = cacheRow < 1.0
					? NetherEnvironmentFluence()
					: NetherDirectEnvironment();
			#else
				dimensionSky = cacheRow < 1.0
					? EndEnvironmentFluence()
					: EndDirectEnvironment();
			#endif
		} else {
			vec3 dimensionWorldDir = SkyViewLutDirection(dimensionUv);
			#if defined(FOXY_DIM_NETHER)
				dimensionSky = NetherEnvironment(dimensionWorldDir);
			#else
				dimensionSky = EndEnvironment(dimensionWorldDir, frameTimeCounter);
			#endif
		}
		gl_FragData[0] = vec4(EncodeSkyLutColor(dimensionSky), 1.0);
		return;
	#else
	vec2 uv = clamp(texcoord, vec2(0.0), vec2(1.0));
	vec3 sky = vec3(0.0);
	if (SkyLutCacheColumn(gl_FragCoord.xy) > 0.5) {
		float cacheRow = floor(gl_FragCoord.y);
		if (cacheRow < 1.0) {
			sky = SkyLutUpperHemisphereFluence(colortex7);
		} else if (cacheRow < 2.0) {

vec3 stableSun;
			vec3 stableMoon;
			StableSunMoonViewDirs(
				sunPosition,
				moonPosition,
				upPosition,
				stableSun,
				stableMoon
			);
			float sunAltitude = dot(stableSun, normalize(upPosition));
			float moonAltitude = dot(stableMoon, normalize(upPosition));
			vec3 shadowView = normalize(shadowLightPosition);
			float shadowMatchesSun = smoothstep(
				0.05,
				0.45,
				dot(shadowView, stableSun)
			);
			float shadowMatchesMoon = smoothstep(
				0.05,
				0.45,
				dot(shadowView, stableMoon)
			);
			float useSunShadow = step(shadowMatchesMoon, shadowMatchesSun);
			sky = mix(
				MoonColor(moonAltitude, rainStrength),
				SunColor(sunAltitude, rainStrength),
				useSunShadow
			);
		}
	} else {
		vec3 previousSky = DecodeSkyLutColor(texture2D(colortex7, uv).rgb);
		float phase = mod(float(frameCounter), 16.0);
		vec2 phase2 = vec2(mod(phase, 4.0), floor(phase * 0.25));
		vec2 texelPhase = mod(floor(gl_FragCoord.xy), vec2(4.0));
		vec2 phaseDelta = abs(texelPhase - phase2);
		float checkerUpdate = (1.0 - step(0.5, phaseDelta.x)) * (1.0 - step(0.5, phaseDelta.y));
		float initialUpdate = 1.0 - step(0.00001, Luma(previousSky));
		sky = previousSky;
		if (checkerUpdate > 0.5 || initialUpdate > 0.5) {
			vec3 worldDir = SkyViewLutDirection(uv);
			vec3 stableSun;
			vec3 stableMoon;
			StableSunMoonViewDirs(sunPosition, moonPosition, upPosition, stableSun, stableMoon);
			vec3 sunWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, stableSun));
			vec3 moonWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, stableMoon));
			sky = AtmosphereScattering(worldDir, sunWorld, moonWorld, vec3(0.0, 1.0, 0.0), sunWorld.y, rainStrength);
		}
	}
	vec3 shadowView = normalize(shadowLightPosition);
	vec3 shadowWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, shadowView));
	vec2 cacheCenter = CloudShadowCacheCenter(cameraPosition, shadowWorld);
	vec2 planePosition = cacheCenter + (uv - vec2(0.5)) * CLOUD_SHADOW_CACHE_EXTENT;
	float cloudShadow = CloudShadowVisibilityAtPlane(planePosition, shadowWorld.y, frameTimeCounter, rainStrength);
	gl_FragData[0] = vec4(EncodeSkyLutColor(sky), cloudShadow);
	#endif
}
