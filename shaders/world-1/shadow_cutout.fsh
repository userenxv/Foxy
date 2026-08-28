#version 430 compatibility
/* DRAWBUFFERS:0 */

uniform sampler2D texture;

varying vec2 texcoord;
varying vec4 surfaceColor;

void main() {
	if ((texture2D(texture, texcoord) * surfaceColor).a < 0.10) {
		discard;
	}
	gl_FragColor = vec4(1.0);
}
