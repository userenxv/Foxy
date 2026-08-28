#include "/lib/shadow.glsl"

uniform mat4 shadowModelViewInverse;

flat out float dhShadowOpaqueCaster;
out vec3 dhShadowPlayerPos;

void main() {
	vec4 shadowViewPosition = gl_ModelViewMatrix * gl_Vertex;
	gl_Position = ShadowWarpClip(gl_ProjectionMatrix * shadowViewPosition);
	dhShadowPlayerPos = (shadowModelViewInverse * shadowViewPosition).xyz;
	float opaqueMaterial = dhMaterialId == DH_BLOCK_WATER ? 0.0 : 1.0;
	dhShadowOpaqueCaster = opaqueMaterial * step(0.999, gl_Color.a);
}
