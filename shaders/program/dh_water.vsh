#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform mat4 dhProjection;
uniform mat4 gbufferModelViewInverse;
uniform float viewWidth;
uniform float viewHeight;
uniform vec2 srJitter;

#include "/lib/sr.glsl"

out vec4 dhWaterColor;
out vec2 dhWaterLightmap;
out vec3 dhWaterNormalView;
out vec3 dhWaterViewPos;
out vec3 dhWaterPlayerPos;
flat out float dhIsWater;

void main() {
	vec4 viewPosition = gl_ModelViewMatrix * gl_Vertex;
	gl_Position = dhProjection * viewPosition;
	SrScaleClipPositionJittered(gl_Position, srJitter);

	dhWaterColor = gl_Color;
	vec2 rawLightmap = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	dhWaterLightmap = clamp((rawLightmap - vec2(0.03125)) * 1.0666667, vec2(0.0), vec2(1.0));
	dhWaterNormalView = normalize(gl_NormalMatrix * gl_Normal);
	dhWaterViewPos = viewPosition.xyz;
	vec4 playerPosition = gbufferModelViewInverse * viewPosition;
	dhWaterPlayerPos = playerPosition.xyz / max(abs(playerPosition.w), 1.0e-6);
	dhIsWater = dhMaterialId == DH_BLOCK_WATER ? 1.0 : 0.0;
}
