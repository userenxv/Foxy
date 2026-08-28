#ifndef FOXY_MATH_GLSL
#define FOXY_MATH_GLSL

#include "/lib/settings.glsl"

const float PI = 3.14159265358979323846;


float Saturate(const in float x) {
	return clamp(x, 0.0, 1.0);
}

vec3 Saturate3(const in vec3 x) {
	return clamp(x, vec3(0.0), vec3(1.0));
}

vec3 SrgbToLinear(const in vec3 c) {
	vec3 x = max(c, vec3(0.0));
	vec3 lo = x / 12.92;
	vec3 hi = pow((x + vec3(0.055)) / 1.055, vec3(2.4));
	return mix(lo, hi, step(vec3(0.04045), x));
}

vec3 LinearToSrgb(const in vec3 c) {
	vec3 x = max(c, vec3(0.0));
	vec3 lo = x * 12.92;
	vec3 hi = 1.055 * pow(x, vec3(1.0 / 2.4)) - vec3(0.055);
	return mix(lo, hi, step(vec3(0.0031308), x));
}

vec3 EncodeBufferColor(const in vec3 c) {
	return sqrt(max(c, vec3(0.0)));
}

vec3 DecodeBufferColor(const in vec3 c) {
	vec3 x = max(c, vec3(0.0));
	return x * x;
}

vec4 EncodeColorAlphaBuffer(const in vec4 c) {
	return vec4(EncodeBufferColor(c.rgb), Saturate(c.a));
}

vec4 DecodeColorAlphaBuffer(const in vec4 c) {
	return vec4(DecodeBufferColor(c.rgb), Saturate(c.a));
}

vec4 EncodeVolumeBuffer(const in vec4 volume) {
	return vec4(EncodeBufferColor(volume.rgb), Saturate(volume.a));
}

vec4 DecodeVolumeBuffer(const in vec4 volume) {
	return vec4(DecodeBufferColor(volume.rgb), Saturate(volume.a));
}

vec3 EncodeSceneColor(const in vec3 c) {
	return EncodeBufferColor(c);
}

vec3 DecodeSceneColor(const in vec3 c) {
	return DecodeBufferColor(c);
}

float Luma(const in vec3 c) {
	return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

float Bayer2(const in vec2 p) {
	vec2 q = floor(p);
	return fract(dot(q, vec2(0.5, q.y * 0.75)));
}

float Bayer4(const in vec2 p) {
	return 0.25 * Bayer2(p * 0.5) + Bayer2(p);
}

float Bayer8(const in vec2 p) {
	return 0.25 * Bayer4(p * 0.5) + Bayer2(p);
}

float Bayer16(const in vec2 p) {
	return 0.25 * Bayer8(p * 0.5) + Bayer2(p);
}

float Dither8Bit(const in float x, const in float pattern) {
	return Saturate(x + (pattern - 0.5) / 255.0);
}

vec2 Dither8Bit2(const in vec2 x, const in float pattern) {
	return clamp(x + vec2((pattern - 0.5) / 255.0), vec2(0.0), vec2(1.0));
}

vec3 Dither8Bit3(const in vec3 x, const in float pattern) {
	return Saturate3(x + vec3((pattern - 0.5) / 255.0));
}

// Derived from David Hoskins' MIT-licensed Hash without Sine collection.
// The required license notice is retained in /THIRD_PARTY_NOTICES.txt.
float Hash12(const in vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float Hash13(const in vec3 p) {
	vec3 p3 = fract(p * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float ValueNoise(const in vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);

	float a = Hash12(i + vec2(0.0, 0.0));
	float b = Hash12(i + vec2(1.0, 0.0));
	float c = Hash12(i + vec2(0.0, 1.0));
	float d = Hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

float ValueNoise3(const in vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	vec3 u = f * f * (3.0 - 2.0 * f);

	float n000 = Hash13(i + vec3(0.0, 0.0, 0.0));
	float n100 = Hash13(i + vec3(1.0, 0.0, 0.0));
	float n010 = Hash13(i + vec3(0.0, 1.0, 0.0));
	float n110 = Hash13(i + vec3(1.0, 1.0, 0.0));
	float n001 = Hash13(i + vec3(0.0, 0.0, 1.0));
	float n101 = Hash13(i + vec3(1.0, 0.0, 1.0));
	float n011 = Hash13(i + vec3(0.0, 1.0, 1.0));
	float n111 = Hash13(i + vec3(1.0, 1.0, 1.0));

	float nx00 = mix(n000, n100, u.x);
	float nx10 = mix(n010, n110, u.x);
	float nx01 = mix(n001, n101, u.x);
	float nx11 = mix(n011, n111, u.x);
	float nxy0 = mix(nx00, nx10, u.y);
	float nxy1 = mix(nx01, nx11, u.y);
	return mix(nxy0, nxy1, u.z);
}

float Fbm2(const in vec2 p) {
	float v = 0.0;
	float a = 0.5;
	vec2 q = p;
	for (int i = 0; i < 5; i++) {
		v += ValueNoise(q) * a;
		q = q * 2.03 + vec2(17.31, 9.17);
		a *= 0.5;
	}
	return v;
}

float Fbm2Fast(const in vec2 p) {
	float v = 0.0;
	float a = 0.58;
	vec2 q = p;
	for (int i = 0; i < 3; i++) {
		v += ValueNoise(q) * a;
		q = q * 2.07 + vec2(11.73, 6.91);
		a *= 0.47;
	}
	return v;
}

float Fbm3(const in vec3 p) {
	float v = 0.0;
	float a = 0.5;
	vec3 q = p;
	for (int i = 0; i < 4; i++) {
		v += ValueNoise3(q) * a;
		q = q * 2.03 + vec3(13.17, 9.37, 17.71);
		a *= 0.5;
	}
	return v;
}

float Fbm3Fast(const in vec3 p) {
	float v = 0.0;
	float a = 0.62;
	vec3 q = p;
	for (int i = 0; i < 2; i++) {
		v += ValueNoise3(q) * a;
		q = q * 2.11 + vec3(8.43, 13.19, 5.71);
		a *= 0.46;
	}
	return v;
}

// Derived from the MIT-licensed BakingLab ACES fit by Stephen Hill/MJP.
// The required license notice is retained in /THIRD_PARTY_NOTICES.txt.
vec3 TonemapAcesFitted(const in vec3 color) {
	// RRT+ODT fit in AP1 working space.
	const mat3 acesInput = mat3(
		0.59719, 0.07600, 0.02840,
		0.35458, 0.90834, 0.13383,
		0.04823, 0.01566, 0.83777
	);
	const mat3 acesOutput = mat3(
		 1.60475, -0.10208, -0.00327,
		-0.53108,  1.10813, -0.07276,
		-0.07367, -0.00605,  1.07602
	);
	vec3 x = acesInput * max(color * 2.0, vec3(0.0));
	vec3 numerator = x * (x + 0.0245786) - 0.000090537;
	vec3 denominator = x * (0.983729 * x + 0.4329510) + 0.238081;
	return Saturate3(acesOutput * (numerator / max(denominator, vec3(1.0e-6))));
}

float TonemapFilmicCurve(const in float x) {
	const float a = 0.15;
	const float b = 0.50;
	const float c = 0.10;
	const float d = 0.20;
	const float e = 0.02;
	const float f = 0.30;
	return ((x * (a * x + c * b) + d * e) /
		(x * (a * x + b) + d * f)) - e / f;
}

vec3 TonemapFilmic(const in vec3 color) {
	// Tone-map luminance while preserving chroma direction.
	vec3 x = max(color, vec3(0.0));
	float sourceLuma = Luma(x);
	if (sourceLuma <= 1.0e-6) return vec3(0.0);
	float displayLuma = TonemapFilmicCurve(sourceLuma * 4.0) /
		TonemapFilmicCurve(11.2);
	vec3 mapped = x * (displayLuma / sourceLuma);
	float peak = max(max(mapped.r, mapped.g), mapped.b);
	return Saturate3(mapped / max(peak, 1.0));
}

// Derived from Benjamin Wrensch's MIT-licensed Minimal AgX implementation.
// The required license notice is retained in /THIRD_PARTY_NOTICES.txt.
vec3 TonemapAgx(const in vec3 color) {
	// AgX inset, log2 contrast, and outset approximation.
	const mat3 inset = mat3(
		0.8424790623, 0.0423282423, 0.0423756549,
		0.0784336000, 0.8784686365, 0.0784336000,
		0.0792237451, 0.0791661275, 0.8791429738
	);
	const mat3 outset = mat3(
		 1.1968790051, -0.0528968518, -0.0529716355,
		-0.0980208811,  1.1519031299, -0.0980434501,
		-0.0990297441, -0.0989611768,  1.1510736726
	);
	vec3 x = max(inset * max(color, vec3(0.0)), vec3(1.0e-8));
	x = clamp((log2(x) + 12.47393) / (12.47393 + 4.026069), vec3(0.0), vec3(1.0));
	vec3 x2 = x * x;
	vec3 x4 = x2 * x2;
	x = 15.5 * x4 * x2 - 40.14 * x4 * x + 31.96 * x4
		- 6.868 * x2 * x + 0.4298 * x2 + 0.1191 * x - 0.00232;
	x = max(outset * x, vec3(0.0));
	return Saturate3(pow(x, vec3(2.2)));
}

vec3 TonemapUchimura(const in vec3 color) {
	const float peak = 1.0;
	const float contrast = 1.0;
	const float linearStart = 0.22;
	const float linearLength = 0.40;
	const float blackCurve = 1.33;
	const float pedestal = 0.0;
	const float linearRange = (peak - linearStart) * linearLength / contrast;
	const float shoulderStart = linearStart + linearRange;
	const float shoulderEnd = linearStart + contrast * linearRange;
	const float shoulderScale = contrast * peak / max(peak - shoulderEnd, 1.0e-6);

	vec3 x = max(color, vec3(0.0));
	vec3 toeWeight = vec3(1.0) - smoothstep(vec3(0.0), vec3(linearStart), x);
	vec3 shoulderWeight = step(vec3(linearStart + linearRange), x);
	vec3 linearWeight = vec3(1.0) - toeWeight - shoulderWeight;
	vec3 toe = linearStart * pow(x / linearStart, vec3(blackCurve)) + pedestal;
	vec3 linear = linearStart + contrast * (x - linearStart);
	vec3 shoulder = peak - (peak - shoulderEnd) * exp(-shoulderScale * (x - shoulderStart) / peak);
	return Saturate3(toe * toeWeight + linear * linearWeight + shoulder * shoulderWeight);
}

vec3 TonemapLottes(const in vec3 color) {
	const float contrast = 1.50;
	const float shoulderContrast = 0.91;
	const float shoulderScale = 1.31205437;
	const float shoulderOffset = 0.20565876;
	vec3 x = max(color, vec3(0.0));
	vec3 numerator = pow(x, vec3(contrast));
	vec3 denominator = pow(x, vec3(contrast * shoulderContrast)) * shoulderScale + shoulderOffset;
	return Saturate3(numerator / max(denominator, vec3(1.0e-6)));
}

vec3 TonemapWithExposure(
	const in vec3 color,
	const in float exposureScale,
	const in float nightAdaptation,
	const in float presentationDayWeight
) {
	vec3 x = max(color * (
		FOXY_PRESENTATION_MANUAL_EXPOSURE *
		exposureScale *
		PresentationPostExposureCalibration(presentationDayWeight) *
		FOXY_POST_EXPOSURE_BRIGHTNESS
	), vec3(0.0));
	#if FOXY_TONEMAPPER == 1
		return TonemapAgx(x);
	#elif FOXY_TONEMAPPER == 2
		return TonemapAcesFitted(x);
	#elif FOXY_TONEMAPPER == 3
		return TonemapFilmic(x);
	#elif FOXY_TONEMAPPER == 4
		return TonemapUchimura(x);
	#elif FOXY_TONEMAPPER == 5
		return TonemapLottes(x);
	#endif
	float luma = Luma(x);
	float toe = mix(1.0, 0.82, Saturate(FOXY_COLOR_SHADOW_CURVE));
	x = pow(max(x, vec3(0.0)), vec3(toe));
	luma = Luma(x);
	float highlightProtect = smoothstep(0.68, 6.0, luma) * FOXY_COLOR_HIGHLIGHT_CURVE;
	float compressedLuma = luma / (1.0 + luma * highlightProtect * 0.62);
	vec3 protectedColor = x * (compressedLuma / max(luma, 1.0e-5));
	protectedColor = mix(protectedColor, vec3(compressedLuma), highlightProtect * 0.12);
	vec3 mapped = (protectedColor * (2.38 * protectedColor + 0.045)) / (protectedColor * (2.32 * protectedColor + 0.62) + 0.16);
	mapped = Saturate3(mapped);
	float mappedLuma = Luma(mapped);
	vec3 toneTint = mix(vec3(0.965, 0.985, 1.035), vec3(1.035, 1.010, 0.955), smoothstep(0.16, 0.78, mappedLuma));
	vec3 tinted = mapped * toneTint;
	mapped = tinted * (mappedLuma / max(Luma(tinted), 1.0e-5));
	mappedLuma = Luma(mapped);
	float gamutProtect = smoothstep(0.62, 1.0, max(max(mapped.r, mapped.g), mapped.b));
	#if FOXY_ATMOSPHERE_STYLE == 1
		float atmosphereSat = 1.02;
		float highlightDesaturation = 0.50;
		float blackPoint = 0.0;
	#elif FOXY_ATMOSPHERE_STYLE == 2
		float atmosphereSat = 1.10;
		float highlightDesaturation = 0.34;
		float blackPoint = 0.006;
	#else
		float atmosphereSat = 1.20;
		float highlightDesaturation = 0.20;
		float blackPoint = 0.012;
	#endif
	float sat = mix(FOXY_COLOR_SATURATION * 1.04 * atmosphereSat, min(FOXY_COLOR_SATURATION * atmosphereSat, 1.02), gamutProtect * highlightDesaturation);
	float night = Saturate(nightAdaptation);
	float nightSaturationLimit = mix(1.02, 0.96, Saturate(FOXY_PURKINJE_SHIFT));
	sat = mix(sat, min(sat, nightSaturationLimit), night * 0.72);
	mapped = mix(vec3(mappedLuma), mapped, sat);
	blackPoint *= mix(1.0, 0.28, night);
	mapped = max(mapped - vec3(blackPoint), vec3(0.0)) / max(1.0 - blackPoint, 0.5);
	return Saturate3(mapped);
}

vec3 TonemapWithExposure(const in vec3 color, const in float exposureScale, const in float nightAdaptation) {
	return TonemapWithExposure(color, exposureScale, nightAdaptation, 1.0 - Saturate(nightAdaptation));
}

vec3 TonemapWithExposure(const in vec3 color, const in float exposureScale) {
	return TonemapWithExposure(color, exposureScale, 0.0);
}

vec3 Tonemap(const in vec3 color) {
	return TonemapWithExposure(color, 1.0);
}

#endif
