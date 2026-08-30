#include "/lib/settings.glsl"
#include "/lib/math.glsl"

#if FOXY_BLOOM_STRENGTH > 0
uniform sampler2D colortex4;
uniform sampler2D colortex10;
uniform float viewWidth;
uniform float viewHeight;
#endif
layout(rg16f) uniform writeonly image2D colorimg9;

varying vec2 texcoord;
varying float finalVertexExposure;

#if FOXY_BLOOM_STRENGTH > 0
	#include "/lib/sr.glsl"

#include "/features/post/bloom/gaussian.glsl"
#endif

void main() {
	#if FOXY_BLOOM_STRENGTH > 0
		vec2 bloomSize = vec2(max(textureSize(colortex4, 0), ivec2(1)));
		vec2 axis = vec2(0.0, 1.0 / bloomSize.y);
		vec3 mediumBloom = BloomGaussian65(colortex4, texcoord, axis);
		vec3 wideBloom = BloomGaussian193(colortex10, texcoord, axis);
		vec3 bloom = mediumBloom * 0.28 + wideBloom * 0.72;
		gl_FragData[0] = vec4(max(bloom, vec3(0.0)), 1.0);
	#else

		if (any(notEqual(ivec2(gl_FragCoord.xy), ivec2(0)))) discard;
		gl_FragData[0] = vec4(0.0);
	#endif
	if (all(equal(ivec2(gl_FragCoord.xy), ivec2(0)))) {
		imageStore(colorimg9, ivec2(0), vec4(finalVertexExposure, -0.875, 0.0, 0.0));
	}
}
