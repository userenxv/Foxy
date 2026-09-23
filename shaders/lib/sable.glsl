#ifndef FOXY_SABLE_GLSL
#define FOXY_SABLE_GLSL

#if !defined(FOXY_SABLE_SUPPORT) || FOXY_SABLE_SUPPORT == 1

float SableMatrixDifference(const in mat4 a, const in mat4 b) {
	vec4 total =
		abs(a[0] - b[0]) + abs(a[1] - b[1]) +
		abs(a[2] - b[2]) + abs(a[3] - b[3]);
	return dot(total, vec4(1.0));
}

bool SableSubLevelDraw(
	const in mat4 modelView,
	const in mat4 gbufferView,
	const in mat4 shadowView
) {
	return SableMatrixDifference(modelView, gbufferView) > 1.0e-4 &&
		SableMatrixDifference(modelView, shadowView) > 1.0e-4;
}

#else

bool SableSubLevelDraw(
	const in mat4 modelView,
	const in mat4 gbufferView,
	const in mat4 shadowView
) {
	return false;
}

#endif

#endif