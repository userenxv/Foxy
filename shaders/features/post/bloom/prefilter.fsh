#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform sampler2D colortex11;
uniform float viewWidth;
uniform float viewHeight;

varying vec2 texcoord;

#include "/lib/sr.glsl"

vec3 BloomSourceSample(const in vec2 uv) {

return DecodeSceneColor(texture2D(colortex11, SrPresentationUv(uv)).rgb);
}

vec3 BloomSafeSample(const in vec2 uv) {
	vec3 color = max(BloomSourceSample(uv), vec3(0.0));
	float luma = Luma(color);

return color * min(1.0, 64.0 / max(luma, 1.0e-4));
}

vec3 BloomPrefilter13(const in vec2 uv, const in vec2 px) {
	// Technique: Sledgehammer Games, "Next Generation Post Processing in Call of Duty: Advanced Warfare," SIGGRAPH 2014.

	vec3 bloom = BloomSafeSample(uv) * 0.125;
	bloom += BloomSafeSample(uv + vec2( 1.0,  1.0) * px) * 0.125;
	bloom += BloomSafeSample(uv + vec2(-1.0,  1.0) * px) * 0.125;
	bloom += BloomSafeSample(uv + vec2( 1.0, -1.0) * px) * 0.125;
	bloom += BloomSafeSample(uv + vec2(-1.0, -1.0) * px) * 0.125;
	bloom += BloomSafeSample(uv + vec2( 2.0,  0.0) * px) * 0.0625;
	bloom += BloomSafeSample(uv + vec2(-2.0,  0.0) * px) * 0.0625;
	bloom += BloomSafeSample(uv + vec2( 0.0,  2.0) * px) * 0.0625;
	bloom += BloomSafeSample(uv + vec2( 0.0, -2.0) * px) * 0.0625;
	bloom += BloomSafeSample(uv + vec2( 2.0,  2.0) * px) * 0.03125;
	bloom += BloomSafeSample(uv + vec2(-2.0,  2.0) * px) * 0.03125;
	bloom += BloomSafeSample(uv + vec2( 2.0, -2.0) * px) * 0.03125;
	bloom += BloomSafeSample(uv + vec2(-2.0, -2.0) * px) * 0.03125;
	return bloom;
}

void main() {
	vec2 px = SrFullPixelSize();
	vec3 bloom = BloomPrefilter13(texcoord, px);
	gl_FragData[0] = vec4(max(bloom, vec3(0.0)), 1.0);
}
