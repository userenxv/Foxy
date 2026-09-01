#version 430 compatibility
#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/shadow.glsl"

#if FOXY_VOXEL_ACTIVE == 1
#define FOXY_VOXEL_BUFFER_WRITE
#include "/lib/voxel/voxel_grid.glsl"
	#if FOXY_MATERIAL_REFLECTIONS == 1 && FOXY_MATERIAL_REFLECTION_GLOBAL == 1 && FOXY_MATERIAL_REFLECTION_OFFSCREEN == 1
		#define FOXY_VOXEL_MATERIAL_COLOR_WRITE
		#include "/lib/voxel/material_color.glsl"
		#undef FOXY_VOXEL_MATERIAL_COLOR_WRITE
	#endif

attribute vec4 at_midBlock;
attribute vec4 mc_Entity;
attribute vec2 mc_midTexCoord;

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
	uint storedMaterialId = VoxelMaterialForGeometry(materialId, scenePos, cameraPosition, sceneNormal);
	vec2 lightmapUv = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	#if FOXY_MATERIAL_REFLECTIONS == 1 && FOXY_MATERIAL_REFLECTION_GLOBAL == 1 && FOXY_MATERIAL_REFLECTION_OFFSCREEN == 1
		vec2 texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
		vec2 spriteCenterUv = (gl_TextureMatrix[0] * vec4(mc_midTexCoord, 0.0, 1.0)).xy;
		vec3 materialNormal = normalize(mat3(shadowModelViewInverse) * gl_NormalMatrix * gl_Normal);
	if (storedMaterialId >= FOXY_VOXEL_CUSTOM_MATERIAL_BASE) VoxelMaterialColorStore(ivec3(floor(VoxelGridSceneToGrid(scenePos, cameraPosition))), storedMaterialId, VoxelEncodeAxisNormal(materialNormal), spriteCenterUv, texcoord);
	#endif
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
