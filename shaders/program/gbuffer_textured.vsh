#include "/lib/settings.glsl"

uniform float viewWidth;
uniform float viewHeight;
uniform vec2 srJitter;

#include "/lib/sr.glsl"

varying vec2 texcoord;
varying vec4 surfaceColor;
// Distance from the eye to this vertex, in blocks.  The particle layer needs it to
// fade the nearest precipitation, which otherwise saturates the shared layer.
varying float weatherViewDistance;

void main() {
	vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
	gl_Position = gl_ProjectionMatrix * viewPos;
	SrScaleClipPositionJittered(gl_Position, srJitter);
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	surfaceColor = gl_Color;
	weatherViewDistance = length(viewPos.xyz);
}
