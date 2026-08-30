#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/celestial.glsl"
#include "/lib/lighting.glsl"
#include "/lib/dimension_sky.glsl"
#include "/lib/wind.glsl"
#include "/lib/emissive.glsl"

uniform float viewWidth;
uniform float viewHeight;
uniform vec2 srJitter;

#include "/lib/sr.glsl"

varying vec2 texcoord;
varying vec2 spriteUv;
varying vec2 spriteHalfSize;
varying vec2 vertexLmcoord;
varying vec4 surfaceColor;
varying vec3 surfaceNormalView;
varying vec3 surfaceViewPosition;
varying vec3 surfaceWorldPosition;
varying float vertexMaterialId;
varying float vertexEmissionLevel;
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying vec3 vertexSunView;
varying vec3 vertexMoonView;
varying vec3 vertexUpView;
varying vec2 vertexShadowSelection;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;

#if FOXY_PBR_NORMAL_MAPS == 1 && defined(TERRAIN)
attribute vec4 at_tangent;
varying vec3 surfaceTangentView;
varying vec3 surfaceBitangentView;
#endif

attribute vec4 mc_Entity;
attribute vec2 mc_midTexCoord;
#ifdef TERRAIN
attribute vec4 at_midBlock;
#endif

uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferModelView;
uniform vec3 cameraPosition;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;
uniform float rainStrength;
uniform float frameTimeCounter;

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	vec2 atlasSpriteCenterUv = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).xy;
	vec2 spriteCenterDelta = texcoord - atlasSpriteCenterUv;

	spriteUv = sign(spriteCenterDelta) * 0.5 + 0.5;
	spriteHalfSize = abs(spriteCenterDelta);
	vertexLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	surfaceColor = gl_Color;
	surfaceNormalView = normalize(gl_NormalMatrix * gl_Normal);
	vertexMaterialId = mc_Entity.x;
	#ifdef TERRAIN

		vertexEmissionLevel = max(at_midBlock.w, 0.0);
	#else

		vertexEmissionLevel = EmissionFallbackLevel(vertexMaterialId);
	#endif
	vec4 baseViewPos = gl_ModelViewMatrix * gl_Vertex;
	vec3 playerPos = (gbufferModelViewInverse * baseViewPos).xyz;
	float topVertex = 1.0 - step(atlasSpriteCenterUv.y, texcoord.y);
	#ifndef COLORWHEEL
		vec3 windOffset = WindDisplacement(
			playerPos + cameraPosition,
			vertexMaterialId,
			topVertex,
			vertexLmcoord.y,
			frameTimeCounter,
			rainStrength
		);
		playerPos += windOffset;
	#endif
	vec4 viewPos = gbufferModelView * vec4(playerPos, 1.0);
	gl_Position = gl_ProjectionMatrix * viewPos;
	SrScaleClipPositionJittered(gl_Position, srJitter);
	surfaceViewPosition = viewPos.xyz;
	surfaceWorldPosition = playerPos;
	vec3 celestialUp = normalize(upPosition);
	vec3 celestialSun;
	vec3 celestialMoon;
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, celestialUp, celestialSun, celestialMoon);
	vertexSunView = celestialSun;
	vertexMoonView = celestialMoon;
	vertexUpView = celestialUp;
	vec3 celestialShadow = normalize(shadowLightPosition);
	vec2 shadowSourceWeights = CelestialShadowSourceWeights(celestialShadow, celestialSun, celestialMoon);
	vertexShadowSelection = vec2(step(shadowSourceWeights.y, shadowSourceWeights.x), shadowSourceWeights.x + shadowSourceWeights.y);
	vertexSunAltitude = dot(celestialSun, celestialUp);
	vertexMoonAltitude = dot(celestialMoon, celestialUp);
	#if defined(FOXY_DIM_NETHER)
		vertexSunAltitude = -1.0;
		vertexMoonAltitude = -1.0;
		vertexSunLightColor = vec3(0.0);
		vertexMoonLightColor = vec3(0.0);
		vertexSkyAmbientColor = NetherEnvironmentFluence() * 4.0 * FOXY_AMBIENT_INTENSITY;
	#elif defined(FOXY_DIM_END)
		vertexSunView = normalize(
			mat3(gbufferModelView) * EndSunWorldDirection()
		);
		vertexMoonView = -vertexSunView;
		vertexShadowSelection = vec2(1.0, 0.0);
		vertexSunAltitude = 0.86602540;
		vertexMoonAltitude = -0.86602540;
		vertexSunLightColor = vec3(0.0);
		vertexMoonLightColor = vec3(0.0);
		vertexSkyAmbientColor = EndEnvironmentFluence() * 0.75 * FOXY_AMBIENT_INTENSITY;
	#else
		vertexSunLightColor = SunColor(vertexSunAltitude, rainStrength);
		vertexMoonLightColor = MoonColor(vertexMoonAltitude, rainStrength);
		vertexSkyAmbientColor = SkyAmbientColor(vertexSunAltitude, rainStrength);
	#endif

	#if FOXY_PBR_NORMAL_MAPS == 1 && defined(TERRAIN)
		vec3 tangentView = normalize(gl_NormalMatrix * at_tangent.xyz);

		tangentView = normalize(tangentView - surfaceNormalView * dot(tangentView, surfaceNormalView));
		vec3 bitangentView = normalize(cross(tangentView, surfaceNormalView)) * at_tangent.w;
		surfaceTangentView = tangentView;
		surfaceBitangentView = bitangentView;
	#endif

}
