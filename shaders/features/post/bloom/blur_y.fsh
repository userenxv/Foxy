#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform sampler2D colortex4;
uniform float viewWidth;
uniform float viewHeight;
layout(rg16f) uniform writeonly image2D colorimg9;

varying vec2 texcoord;
varying float finalVertexExposure;

#include "/lib/sr.glsl"

vec3 BloomBlurSource(const in vec2 uv) {
	#if FOXY_TAAU_ACTIVE == 1
		return max(texture2D(colortex4, clamp(uv, vec2(0.0), vec2(1.0))).rgb, vec3(0.0));
	#else
		return max(texture2D(colortex4, SrPresentationUv(uv)).rgb, vec3(0.0));
	#endif
}

void main() {
	vec2 px = vec2(0.0, SrFullPixelSize().y * 4.0);
	vec3 bloom = BloomBlurSource(texcoord) * 0.20;
	bloom += BloomBlurSource(texcoord + px * 1.5) * 0.18;
	bloom += BloomBlurSource(texcoord - px * 1.5) * 0.18;
	bloom += BloomBlurSource(texcoord + px * 3.5) * 0.12;
	bloom += BloomBlurSource(texcoord - px * 3.5) * 0.12;
	bloom += BloomBlurSource(texcoord + px * 6.5) * 0.07;
	bloom += BloomBlurSource(texcoord - px * 6.5) * 0.07;
	bloom += BloomBlurSource(texcoord + px * 10.0) * 0.03;
	bloom += BloomBlurSource(texcoord - px * 10.0) * 0.03;
	gl_FragData[0] = vec4(max(bloom, vec3(0.0)), 1.0);
	if (all(equal(ivec2(gl_FragCoord.xy), ivec2(0)))) {
		imageStore(colorimg9, ivec2(0), vec4(finalVertexExposure, -0.875, 0.0, 0.0));
	}
}
