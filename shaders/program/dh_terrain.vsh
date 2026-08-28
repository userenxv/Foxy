#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform mat4 dhProjection;
uniform mat4 gbufferModelViewInverse;
uniform float viewWidth;
uniform float viewHeight;
uniform vec2 srJitter;

#include "/lib/sr.glsl"

out vec4 dhColor;
out vec2 dhLightmap;
out vec3 dhNormalView;
out vec3 dhViewPos;
out vec3 dhPlayerPos;

void main() {
	vec4 viewPosition = gl_ModelViewMatrix * gl_Vertex;
	gl_Position = dhProjection * viewPosition;
	SrScaleClipPositionJittered(gl_Position, srJitter);

	dhColor = gl_Color;
	vec2 rawLightmap = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	dhLightmap = clamp((rawLightmap - vec2(0.03125)) * 1.0666667, vec2(0.0), vec2(1.0));
	dhNormalView = normalize(gl_NormalMatrix * gl_Normal);
	dhViewPos = viewPosition.xyz;
	vec4 playerPosition = gbufferModelViewInverse * viewPosition;
	dhPlayerPos = playerPosition.xyz / max(abs(playerPosition.w), 1.0e-6);
}
