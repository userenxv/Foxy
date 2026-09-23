#include "/lib/shadow.glsl"

uniform mat4 shadowModelViewInverse;

flat out float dhShadowOpaqueCaster;
out vec3 dhShadowPlayerPos;

void main() {
	vec4 shadowViewPosition = gl_ModelViewMatrix * gl_Vertex;
	vec3 playerPos = (shadowModelViewInverse * shadowViewPosition).xyz;
	vec3 aimedPlayerPos = FoEndShadowAim(shadowModelViewInverse) * playerPos;
	gl_Position = ShadowWarpClip(
		FoEndShadowProjection(gl_ProjectionMatrix) *
			(gl_ModelViewMatrix * vec4(aimedPlayerPos, 1.0))
	);
	dhShadowPlayerPos = playerPos;
	float opaqueMaterial = dhMaterialId == DH_BLOCK_WATER ? 0.0 : 1.0;
	dhShadowOpaqueCaster = opaqueMaterial * step(0.999, gl_Color.a);
}
