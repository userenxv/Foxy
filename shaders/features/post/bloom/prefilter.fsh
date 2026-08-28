#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform sampler2D colortex11;
#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
uniform vec2 temporalJitter;
#endif
uniform float viewWidth;
uniform float viewHeight;

varying vec2 texcoord;

#include "/lib/sr.glsl"

vec3 BloomSourceSample(const in vec2 uv) {
#if FOXY_TAAU_ACTIVE == 1
	// colortex11 is the stable full-resolution TAAU output.
	return DecodeSceneColor(texture2D(colortex11, clamp(uv, vec2(0.0), vec2(1.0))).rgb);
#elif FOXY_TEMPORAL_JITTER_ACTIVE == 1
	vec2 currentUv = uv + temporalJitter * 0.5;
	return DecodeSceneColor(texture2D(colortex11, SrPresentationUv(currentUv)).rgb);
#else
	return DecodeSceneColor(texture2D(colortex11, SrPresentationUv(uv)).rgb);
#endif
}

vec3 BloomPrefilterSample(const in vec2 uv) {
	vec3 c = BloomSourceSample(uv);
	float luma = Luma(c);
	float threshold = max(FOXY_BLOOM_THRESHOLD, 0.01);
	float knee = max(threshold * 1.15, 1.0e-4);
	float soft = Saturate((luma - threshold + knee) / (2.0 * knee));
	float contribution = max(luma - threshold, 0.0) + soft * soft * knee;
	float broadGlow = smoothstep(threshold * 0.20, threshold * 1.55, luma) * 0.28;
	float weight = Saturate(contribution / max(luma + threshold * 0.55, 1.0e-4) + broadGlow);
	vec3 chroma = c / max(luma, 1.0e-4);
	chroma = mix(vec3(1.0), chroma, 0.32);
	chroma = mix(chroma, chroma * vec3(1.055, 1.015, 0.94), smoothstep(threshold * 0.80, threshold * 4.0, luma));
	float energy = min(luma * weight, 5.0);
	return chroma * energy;
}

vec3 BloomGatherLowFreq(const in vec2 uv, const in vec2 px) {
	float r0 = 2.0 + FOXY_BLOOM_RADIUS * 2.0;
	float r1 = 5.5 + FOXY_BLOOM_RADIUS * 4.5;
	float r2 = 11.0 + FOXY_BLOOM_RADIUS * 7.0;
	vec3 bloom = BloomPrefilterSample(uv) * 0.105;
	bloom += BloomPrefilterSample(uv + vec2( r0, 0.0) * px) * 0.082;
	bloom += BloomPrefilterSample(uv + vec2(-r0, 0.0) * px) * 0.082;
	bloom += BloomPrefilterSample(uv + vec2(0.0,  r0) * px) * 0.082;
	bloom += BloomPrefilterSample(uv + vec2(0.0, -r0) * px) * 0.082;
	bloom += BloomPrefilterSample(uv + vec2( r1,  r1) * px) * 0.062;
	bloom += BloomPrefilterSample(uv + vec2(-r1,  r1) * px) * 0.062;
	bloom += BloomPrefilterSample(uv + vec2( r1, -r1) * px) * 0.062;
	bloom += BloomPrefilterSample(uv + vec2(-r1, -r1) * px) * 0.062;
	bloom += BloomPrefilterSample(uv + vec2( r2, 0.0) * px) * 0.042;
	bloom += BloomPrefilterSample(uv + vec2(-r2, 0.0) * px) * 0.042;
	bloom += BloomPrefilterSample(uv + vec2(0.0,  r2) * px) * 0.042;
	bloom += BloomPrefilterSample(uv + vec2(0.0, -r2) * px) * 0.042;
	return bloom;
}

void main() {
	vec2 px = SrFullPixelSize();
	vec3 bloom = BloomGatherLowFreq(texcoord, px);
	float bloomLuma = Luma(bloom);
	bloom *= min(1.0, 2.6 / max(bloomLuma, 1.0e-4));
	gl_FragData[0] = vec4(max(bloom, vec3(0.0)), 1.0);
}
