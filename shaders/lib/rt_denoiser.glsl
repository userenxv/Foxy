#ifndef FOXY_DENOISER_GLSL
#define FOXY_DENOISER_GLSL

float RtDenoiserLuma(const in vec3 color) {
	return dot(max(color, vec3(0.0)), vec3(0.2126, 0.7152, 0.0722));
}

bool RtDenoiserFinite3(const in vec3 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

bool RtDenoiserFinite4(const in vec4 value) {
	return !any(isnan(value)) && !any(isinf(value));
}

vec2 RtDenoiserMaterialSignature(const in vec3 albedo) {
	vec3 color = clamp(albedo, vec3(0.0), vec3(1.0));
	return vec2(
		dot(color, vec3(0.52, 0.33, 0.15)),
		dot(color, vec3(0.12, 0.31, 0.57))
	);
}

float RtDenoiserMaterialWeight(const in vec2 centerSignature, const in vec2 sampleSignature) {
	float signatureError = length(sampleSignature - centerSignature);
	return 1.0 - smoothstep(0.055, 0.26, signatureError);
}

float RtDenoiserNormalWeight(const in vec3 centerNormal, const in vec3 sampleNormal) {
	return smoothstep(0.79, 0.965, dot(centerNormal, sampleNormal));
}

float RtDenoiserGrazingSurfaceFloor(
	const in float sameSurfaceClass,
	const in float grazingRelax
) {
	return sameSurfaceClass * smoothstep(1.02, 2.35, grazingRelax) * 0.18;
}

float RtDenoiserRelativeDepthWeight(
	const in float centerDepth,
	const in float sampleDepth,
	const in float nearThreshold,
	const in float farThreshold
) {
	float relativeError = abs(sampleDepth - centerDepth) / max(centerDepth, 0.25);
	return 1.0 - smoothstep(nearThreshold, farThreshold, relativeError);
}

float RtDenoiserHistorySupport(const in float validBilinearWeight) {
	return smoothstep(0.10, 0.46, validBilinearWeight);
}

float RtDenoiserTracePrimaryOffsetIndex(const in float packedState) {
	return clamp(floor((packedState + 1.0) * 0.25 + 1.0e-4), 0.0, 3.0);
}

float RtDenoiserTraceState(const in float packedState) {
	float offsetIndex = RtDenoiserTracePrimaryOffsetIndex(packedState);
	return packedState - offsetIndex * 4.0;
}

float RtDenoiserPackMetaState(
	const in float primaryOffsetIndex,
	const in float historyAge,
	const in float surfaceClass,
	const in float reactive,
	const in float historyAccepted
) {
	float offsetCode = clamp(floor(primaryOffsetIndex + 0.5), 0.0, 3.0);
	float ageCode = clamp(floor(historyAge + 0.5), 1.0, 15.0);
	float surfaceClassCode = clamp(floor(surfaceClass + 0.5), 0.0, 7.0);
	float reactiveCode = step(0.5, reactive);
	float acceptedCode = step(0.5, historyAccepted);
	return -(surfaceClassCode * 256.0 + offsetCode * 64.0 + ageCode * 4.0 + reactiveCode * 2.0 + acceptedCode);
}

float RtDenoiserMetaCode(const in vec4 meta) {
	return max(floor(-meta.w + 0.5), 0.0);
}

float RtDenoiserMetaSurfaceClass(const in vec4 meta) {
	return clamp(floor(RtDenoiserMetaCode(meta) * (1.0 / 256.0)), 0.0, 7.0);
}

float RtDenoiserMetaBaseCode(const in vec4 meta) {
	float code = RtDenoiserMetaCode(meta);
	return code - floor(code * (1.0 / 256.0)) * 256.0;
}

float RtDenoiserSurfaceClassWeight(const in float centerClass, const in float sampleClass) {
	return 1.0 - step(0.5, abs(centerClass - sampleClass));
}

float RtDenoiserMetaValid(const in vec4 meta) {
	return step(0.5, RtDenoiserMetaBaseCode(meta));
}

float RtDenoiserMetaPrimaryOffsetIndex(const in vec4 meta) {
	return clamp(floor(RtDenoiserMetaBaseCode(meta) * (1.0 / 64.0)), 0.0, 3.0);
}

vec2 RtDenoiserMetaPrimaryOffset(const in vec4 meta) {
	float offsetIndex = RtDenoiserMetaPrimaryOffsetIndex(meta);
	return vec2(mod(offsetIndex, 2.0), floor(offsetIndex * 0.5));
}

float RtDenoiserMetaAge(const in vec4 meta) {
	float code = RtDenoiserMetaBaseCode(meta);
	float offsetIndex = floor(code * (1.0 / 64.0));
	float remainder = code - offsetIndex * 64.0;
	return clamp(floor(remainder * 0.25), 0.0, 15.0);
}

float RtDenoiserMetaReactive(const in vec4 meta) {
	float code = RtDenoiserMetaBaseCode(meta);
	float offsetIndex = floor(code * (1.0 / 64.0));
	float remainder = code - offsetIndex * 64.0;
	float ageCode = floor(remainder * 0.25);
	float flags = remainder - ageCode * 4.0;
	return step(1.5, flags);
}

float RtDenoiserMetaHistoryAccepted(const in vec4 meta) {
	float code = RtDenoiserMetaBaseCode(meta);
	float offsetIndex = floor(code * (1.0 / 64.0));
	float remainder = code - offsetIndex * 64.0;
	float ageCode = floor(remainder * 0.25);
	float flags = remainder - ageCode * 4.0;
	flags -= RtDenoiserMetaReactive(meta) * 2.0;
	return step(0.5, flags);
}

#endif
