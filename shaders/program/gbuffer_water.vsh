#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/celestial.glsl"
#include "/lib/lighting.glsl"

uniform float viewWidth;
uniform float viewHeight;
uniform vec2 srJitter;

#include "/lib/sr.glsl"
#include "/lib/water.glsl"
#include "/lib/transmission.glsl"

varying vec2 texcoord;
varying vec2 vertexLmcoord;
varying vec4 surfaceColor;
varying vec3 surfaceNormalView;
varying vec3 surfaceViewPosition;
varying vec3 surfaceWorldPosition;
varying vec4 vertexShadowClip;
varying float waterWaveHeight;
varying float isWater;
varying float isIce;
varying float vertexMaterialId;
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;

attribute vec4 mc_Entity;

uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferModelView;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 cameraPosition;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform float frameTimeCounter;
uniform float rainStrength;

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	vertexLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	surfaceColor = gl_Color;
	float entityId = mc_Entity.x;
	vertexMaterialId = entityId;
	float mappedWater = step(10007.5, entityId) * step(entityId, 10008.5);
	float legacyWater = step(7.5, entityId) * step(entityId, 9.5);
	float mappedIce = step(10078.5, entityId) * step(entityId, 10082.5);
	float legacyIce = max(step(78.5, entityId) * step(entityId, 79.5), step(173.5, entityId) * step(entityId, 174.5));
	legacyIce = max(legacyIce, step(211.5, entityId) * step(entityId, 212.5));
	isWater = max(mappedWater, legacyWater);
	isIce = max(mappedIce, legacyIce);
	vec3 celestialUp = normalize(upPosition);
	vec3 celestialSun;
	vec3 celestialMoon;
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, celestialUp, celestialSun, celestialMoon);
	vertexSunAltitude = dot(celestialSun, celestialUp);
	vertexMoonAltitude = dot(celestialMoon, celestialUp);
	vertexSunLightColor = SunColor(vertexSunAltitude, rainStrength);
	vertexMoonLightColor = MoonColor(vertexMoonAltitude, rainStrength);
	vertexSkyAmbientColor = SkyAmbientColor(vertexSunAltitude, rainStrength);

	vec4 baseViewPos = gl_ModelViewMatrix * gl_Vertex;
	vec4 playerPos4 = gbufferModelViewInverse * baseViewPos;
	vec3 playerPos = playerPos4.xyz;
	vec3 worldPos = playerPos + cameraPosition;
	vec3 flatNormalView = normalize(gl_NormalMatrix * gl_Normal);
	vec3 flatNormalPlayer = normalize(mat3(gbufferModelViewInverse) * flatNormalView);

	float waveHeight = 0.0;
	if (isWater > 0.5) {
		waveHeight = WaterLargeHeight(worldPos.xz, frameTimeCounter);
	}
	float topFace = smoothstep(0.55, 0.92, max(flatNormalPlayer.y, 0.0));
	float waveDisplacementScale = mix(0.075, 0.125, Saturate(FOXY_WATER_WAVE_STRENGTH));
#if FOXY_WATER_SPECTRUM_WAVES == 1
	waveDisplacementScale *= 1.55;
#endif
	playerPos.y += waveHeight * topFace * waveDisplacementScale * isWater;
	worldPos.y += waveHeight * topFace * waveDisplacementScale * isWater;
	waterWaveHeight = waveHeight * topFace * isWater;

	vec4 viewPos = gbufferModelView * vec4(playerPos, 1.0);
	surfaceViewPosition = viewPos.xyz;
	surfaceWorldPosition = worldPos;
	surfaceNormalView = flatNormalView;
	vertexShadowClip = shadowProjection * shadowModelView * vec4(playerPos, 1.0);
	gl_Position = gl_ProjectionMatrix * viewPos;
	SrScaleClipPositionJittered(gl_Position, srJitter);
}
