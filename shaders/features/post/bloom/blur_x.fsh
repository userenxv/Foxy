#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform sampler2D colortex1;
uniform float viewWidth;
uniform float viewHeight;

varying vec2 texcoord;

#include "/lib/sr.glsl"

#include "/features/post/bloom/gaussian.glsl"

void main() {
	vec2 bloomSize = vec2(max(textureSize(colortex1, 0), ivec2(1)));
	vec2 axis = vec2(1.0 / bloomSize.x, 0.0);
	vec3 mediumBloom = BloomGaussian65(colortex1, texcoord, axis);
	vec3 wideBloom = BloomGaussian193(colortex1, texcoord, axis);
	gl_FragData[0] = vec4(max(mediumBloom, vec3(0.0)), 1.0);
	gl_FragData[1] = vec4(max(wideBloom, vec3(0.0)), 1.0);
}
