#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/shadow.glsl"
#include "/lib/transmission.glsl"
#include "/lib/wind.glsl"

#if FOXY_VOXEL_ACTIVE == 1
	#define FOXY_VOXEL_BUFFER_WRITE
	#include "/lib/voxel/voxel_grid.glsl"
	attribute vec4 at_midBlock;
	#ifdef COLORWHEEL
		#define VOXEL_GEOMETRY_ELIGIBLE(materialId) false
	#else
		#define VOXEL_GEOMETRY_ELIGIBLE(materialId) TransmissionIsGlass(materialId)
	#endif
#endif

varying vec2 texcoord;
varying vec4 surfaceColor;
varying vec3 surfaceWorldPosition;
varying float isWater;
varying float vertexMaterialId;

attribute vec4 mc_Entity;
attribute vec2 mc_midTexCoord;

uniform mat4 shadowModelViewInverse;
uniform mat4 shadowModelView;
uniform vec3 cameraPosition;
uniform float frameTimeCounter;
uniform float rainStrength;

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	surfaceColor = gl_Color;
	float entityId = mc_Entity.x;
	vertexMaterialId = entityId;
	float mappedWater = step(10007.5, entityId) * step(entityId, 10008.5);
	float legacyWater = step(7.5, entityId) * step(entityId, 9.5);
	isWater = max(mappedWater, legacyWater);
	vec4 baseShadowViewPos = gl_ModelViewMatrix * gl_Vertex;
	vec3 playerPos = (shadowModelViewInverse * baseShadowViewPos).xyz;
	vec2 spriteCenterUv = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).xy;
	float topVertex = 1.0 - step(spriteCenterUv.y, texcoord.y);
	vec2 lightmapUv = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	#ifndef COLORWHEEL
		playerPos += WindDisplacement(
			playerPos + cameraPosition,
			entityId,
			topVertex,
			lightmapUv.y,
			frameTimeCounter,
			rainStrength
		);
	#endif
	vec4 shadowViewPos = shadowModelView * vec4(playerPos, 1.0);
	gl_Position = ShadowWarpClip(gl_ProjectionMatrix * shadowViewPos);
	surfaceWorldPosition = playerPos + cameraPosition;

	#if FOXY_VOXEL_ACTIVE == 1

if (VOXEL_GEOMETRY_ELIGIBLE(entityId)) {
			vec3 modelPos = gl_Vertex.xyz + at_midBlock.xyz / 64.0;
			vec3 centeredShadowView = (gl_ModelViewMatrix * vec4(modelPos, 1.0)).xyz;
			vec3 centeredScenePos = (shadowModelViewInverse * vec4(centeredShadowView, 1.0)).xyz;
			vec3 sceneNormal = normalize(
				mat3(shadowModelViewInverse) * gl_NormalMatrix * gl_Normal
			);
			VoxelGridStoreScene(
				centeredScenePos,
				cameraPosition,
				uint(max(entityId, 0.0) + 0.5),
				sceneNormal,
				at_midBlock.w,
				lightmapUv
			);
		}
	#endif
}
