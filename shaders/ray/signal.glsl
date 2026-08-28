#ifndef RAY_SIGNAL_GLSL
#define RAY_SIGNAL_GLSL

struct RaySignal {
	vec3 radiance;
	float validity;
	float hitDistance;
	float roughness;
	float reactivity;
	vec2 sampleUv;
	vec2 motion;
};

RaySignal RaySignalEmpty() {
	RaySignal signal;
	signal.radiance = vec3(0.0);
	signal.validity = 0.0;
	signal.hitDistance = 0.0;
	signal.roughness = 1.0;
	signal.reactivity = 1.0;
	signal.sampleUv = vec2(0.0);
	signal.motion = vec2(0.0);
	return signal;
}

RaySignal RaySignalMake(
	const in vec3 radiance,
	const in float validity,
	const in float hitDistance,
	const in float roughness,
	const in float reactivity,
	const in vec2 sampleUv,
	const in vec2 motion
) {
	RaySignal signal;
	signal.radiance = radiance;
	signal.validity = validity;
	signal.hitDistance = hitDistance;
	signal.roughness = roughness;
	signal.reactivity = reactivity;
	signal.sampleUv = sampleUv;
	signal.motion = motion;
	return signal;
}

#endif
