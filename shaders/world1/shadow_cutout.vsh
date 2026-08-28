#version 430 compatibility
#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/shadow.glsl"
#include "/lib/wind.glsl"

attribute vec4 mc_Entity;
attribute vec2 mc_midTexCoord;

uniform mat4 shadowModelViewInverse;
uniform mat4 shadowModelView;
uniform vec3 cameraPosition;
uniform float frameTimeCounter;
uniform float rainStrength;

#if FOXY_VOXEL_ACTIVE == 1
#define FOXY_VOXEL_BUFFER_WRITE
#include "/lib/voxel/voxel_grid.glsl"

attribute vec4 at_midBlock;
#endif

varying vec2 texcoord;
varying vec4 surfaceColor;

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	surfaceColor = gl_Color;
	vec4 baseShadowViewPos = gl_ModelViewMatrix * gl_Vertex;
	vec3 playerPos = (shadowModelViewInverse * baseShadowViewPos).xyz;
	vec2 spriteCenterUv = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).xy;
	float topVertex = 1.0 - step(spriteCenterUv.y, texcoord.y);
	vec2 lightmapUv = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	playerPos += WindDisplacement(
		playerPos + cameraPosition,
		mc_Entity.x,
		topVertex,
		lightmapUv.y,
		frameTimeCounter,
		rainStrength
	);
	vec4 shadowViewPos = shadowModelView * vec4(playerPos, 1.0);
	vec4 clip = gl_ProjectionMatrix * shadowViewPos;
	clip.xy = ShadowWarp(clip.xy / clip.w) * clip.w;
	gl_Position = clip;

#if FOXY_VOXEL_ACTIVE == 1
	vec3 modelPos = gl_Vertex.xyz + at_midBlock.xyz / 64.0;
	vec3 voxelShadowViewPos = (gl_ModelViewMatrix * vec4(modelPos, 1.0)).xyz;
	vec3 scenePos = (shadowModelViewInverse * vec4(voxelShadowViewPos, 1.0)).xyz;
	vec3 sceneNormal = normalize(
		mat3(shadowModelViewInverse) * gl_NormalMatrix * gl_Normal
	);
	uint materialId = uint(max(mc_Entity.x, 0.0) + 0.5);
	VoxelGridStoreScene(
		scenePos,
		cameraPosition,
		materialId,
		sceneNormal,
		at_midBlock.w,
		lightmapUv
	);
#endif
}
