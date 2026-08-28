#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform sampler2D colortex1;
uniform float viewWidth;
uniform float viewHeight;

varying vec2 texcoord;

#include "/lib/sr.glsl"

vec3 BloomBlurSource(const in vec2 uv) {
	#if FOXY_TAAU_ACTIVE == 1
		return max(texture2D(colortex1, clamp(uv, vec2(0.0), vec2(1.0))).rgb, vec3(0.0));
	#else
		return max(texture2D(colortex1, SrPresentationUv(uv)).rgb, vec3(0.0));
	#endif
}

void main() {
	vec2 px = vec2(SrFullPixelSize().x * 4.0, 0.0);
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
}
