#include "/lib/settings.glsl"
#include "/lib/math.glsl"

/* DRAWBUFFERS:3 */

uniform sampler2D texture;
uniform float rainStrength;

varying vec2 texcoord;
varying vec4 surfaceColor;

void main() {
	vec4 baseTexel = texture2D(texture, texcoord);
	vec4 texel = baseTexel * surfaceColor;
	if (texel.a < 0.10) discard;

	// Rain impacts are excluded; all other particles share one transparent layer.
	if (
		rainStrength > 0.01 &&
		baseTexel.r < 0.29 &&
		baseTexel.g < 0.45 &&
		baseTexel.b > 0.75
	) discard;

	// Store premultiplied source-over color in the scene encoding domain.
	vec3 encodedPremultiplied = EncodeSceneColor(SrgbToLinear(texel.rgb)) * texel.a;
	gl_FragData[0] = vec4(encodedPremultiplied, texel.a);
}
