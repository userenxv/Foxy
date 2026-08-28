#include "/lib/settings.glsl"

uniform float viewWidth;
uniform float viewHeight;
uniform vec2 srJitter;

#include "/lib/sr.glsl"

varying vec4 surfaceColor;
varying vec2 texcoord;

void main() {
	gl_Position = ftransform();
	SrScaleClipPositionJittered(gl_Position, srJitter);
	surfaceColor = gl_Color;
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
}
