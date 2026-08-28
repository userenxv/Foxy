#ifndef WATER_REFLECTION_RESOLVE_GLSL
#define WATER_REFLECTION_RESOLVE_GLSL

#include "/ray/signal.glsl"

struct WaterReflectionSignal {
	vec3 color;
	float amount;
	float hitCoverage;
	float fallbackWeight;
	float sourceWeight;
	float roughness;
	vec2 sampleUv;
	vec2 uvDelta;
	float rawHit;
	RaySignal ray;
};

vec3 RoughWaterReflectionSample(const in vec2 uv, const in vec2 rayUvDelta, const in float roughness) {
	vec3 center = ReflectionSample(uv);
	float r = Saturate(roughness);
	if (r <= 0.001) {
		return center;
	}
	vec2 pixel = SrActivePixelSize();
	vec2 axis = rayUvDelta;
	float axisLength = length(axis);
	if (axisLength < 1.0e-5) {
		axis = vec2(1.0, 0.0);
	} else {
		axis /= axisLength;
	}
	vec2 tangent = vec2(-axis.y, axis.x);
	vec2 radius = pixel * mix(0.85, 2.10, r);
	vec3 along = ReflectionSample(clamp(uv + axis * radius, vec2(0.001), vec2(0.999)));
	vec3 across = ReflectionSample(clamp(uv + tangent * radius * 0.72, vec2(0.001), vec2(0.999)));
	return mix(center, center * 0.50 + along * 0.30 + across * 0.20, r);
}


RaySignal WaterReflectionMakeRaySignal(const in WaterReflectionSignal signal) {
	return RaySignalMake(
		signal.color,
		signal.sourceWeight,
		signal.rawHit,
		signal.roughness,
		1.0,
		signal.sampleUv,
		signal.uvDelta
	);
}

WaterReflectionSignal ResolveWaterReflectionSignal(
	const in vec4 trace,
	const in vec4 fallback,
	const in float waterRoughness,
	const in float mask,
	const in float waveStability,
	const in float microfacetVisibility
) {
	WaterReflectionSignal signal;
	signal.sampleUv = clamp(trace.xy, vec2(0.0), vec2(1.0));
	signal.hitCoverage = Saturate(trace.z);
	signal.rawHit = trace.w;
	signal.uvDelta = signal.sampleUv - WaterCurrentViewUv(texcoord);
	signal.fallbackWeight = fallback.a * (1.0 - signal.hitCoverage);
	signal.sourceWeight = signal.hitCoverage + signal.fallbackWeight;
	signal.roughness = waterRoughness;
	vec3 screenReflected = signal.hitCoverage > 0.001 ? RoughWaterReflectionSample(signal.sampleUv, signal.uvDelta, signal.roughness) : vec3(0.0);
	vec3 weightedColor = screenReflected * signal.hitCoverage + fallback.rgb * signal.fallbackWeight;
	signal.color = signal.sourceWeight > 0.001 ? weightedColor / signal.sourceWeight : vec3(0.0);
	signal.amount = mask * waveStability * microfacetVisibility * signal.sourceWeight;
	signal.ray = WaterReflectionMakeRaySignal(signal);
	return signal;
}

vec3 CompositeWaterReflection(const in vec3 baseScene, const in WaterReflectionSignal signal, const in float reflectionAmount, const in float waterFogOcclusion, const in float grazingWater, out float finalReflectionAmount) {
	float reflectionWaterFogGuard = mix(1.0, 0.72, smoothstep(0.45, 0.96, waterFogOcclusion) * (1.0 - smoothstep(0.35, 0.82, grazingWater)));
	finalReflectionAmount = Saturate(reflectionAmount * reflectionWaterFogGuard);
	return mix(baseScene, signal.color, finalReflectionAmount);
}

#endif
