#version 430 compatibility
#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/shadow.glsl"

#if FOXY_VOXEL_ACTIVE == 1
#define FOXY_VOXEL_BUFFER_WRITE
#include "/lib/voxel/voxel_grid.glsl"

attribute vec4 at_midBlock;
attribute vec4 mc_Entity;

uniform mat4 shadowModelViewInverse;
uniform vec3 cameraPosition;
#endif

void main() {
	vec4 clip = ftransform();
	clip.xy = ShadowWarp(clip.xy / clip.w) * clip.w;
	gl_Position = clip;

#if FOXY_VOXEL_ACTIVE == 1
	vec3 modelPos = gl_Vertex.xyz + at_midBlock.xyz / 64.0;
	vec3 shadowViewPos = (gl_ModelViewMatrix * vec4(modelPos, 1.0)).xyz;
	vec3 scenePos = (shadowModelViewInverse * vec4(shadowViewPos, 1.0)).xyz;
	vec3 sceneNormal = normalize(
		mat3(shadowModelViewInverse) * gl_NormalMatrix * gl_Normal
	);
	uint materialId = uint(max(mc_Entity.x, 0.0) + 0.5);
	vec2 lightmapUv = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
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
