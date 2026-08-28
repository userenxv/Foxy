#ifndef FOXY_FIRST_PERSON_DEPTH_GLSL
#define FOXY_FIRST_PERSON_DEPTH_GLSL

#ifndef MC_HAND_DEPTH
	#define MC_HAND_DEPTH 0.125
#endif

const float FOXY_FIRST_PERSON_DEPTH_CUTOFF = 0.56;

float FirstPersonDepthMask(const in float rawDepth) {
	return 1.0 - step(FOXY_FIRST_PERSON_DEPTH_CUTOFF, rawDepth);
}

float FirstPersonProjectionDepth(
	const in float rawDepth,
	const in float firstPerson
) {
	if (firstPerson < 0.5) return rawDepth;
	float ndcDepth = rawDepth * 2.0 - 1.0;
	return clamp(ndcDepth / MC_HAND_DEPTH * 0.5 + 0.5, 0.0, 1.0 - 1.0e-6);
}

#endif
