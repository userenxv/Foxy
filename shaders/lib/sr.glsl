#ifndef FOXY_SR_GLSL
#define FOXY_SR_GLSL

#include "/lib/settings.glsl"

float SrScale() {
	#if FOXY_TAAU_ACTIVE == 1
		return clamp(FOXY_TAAU_RENDER_SCALE, 0.5, 1.0);
	#else
		return 1.0;
	#endif
}

float SrInternalActive() {
	#if FOXY_TAAU_ACTIVE == 1
		return 1.0;
	#else
		return 0.0;
	#endif
}

vec2 SrFullSize() {
	return vec2(max(viewWidth, 1.0), max(viewHeight, 1.0));
}

vec2 SrRenderSize() {
	return max(floor(SrFullSize() * SrScale()), vec2(1.0));
}

vec2 SrRenderScale() {
	return SrRenderSize() / SrFullSize();
}

vec2 SrActiveRenderScale() {
	return mix(vec2(1.0), SrRenderScale(), SrInternalActive());
}

vec2 SrFullPixelSize() {
	return 1.0 / SrFullSize();
}

vec2 SrRenderPixelSize() {
	return 1.0 / SrRenderSize();
}

vec2 SrActivePixelSize() {
	return 1.0 / max(SrFullSize() * SrActiveRenderScale(), vec2(1.0));
}

// Coordinate-domain contract -------------------------------------------------
//
// View UV: logical camera/projection coordinates in [0, 1].
// Scene resource UV: the packed lower-left scene rectangle in a display-sized
// attachment (gbuffers, depth, DH, translucent layers and scene staging).
// Local resource UV: a producer with its own attachment size (cloud source,
// volume source, SSPT/AO) packed by the same scene scale in that attachment.
// Presentation UV: full-resolution temporal history/output and post effects.
//
// Explicit domains prevent scene, local, and presentation resources from
// being sampled with interchangeable coordinates.

vec2 SrSceneResourceMaxUv() {
	return SrActiveRenderScale();
}

vec2 SrViewUv(const in vec2 uv) {
	return clamp(uv, vec2(0.0), vec2(1.0));
}

vec2 SrPresentationUv(const in vec2 uv) {
	return clamp(uv, vec2(0.0), vec2(1.0));
}

vec2 SrSceneResourceUv(const in vec2 viewUv) {
	return SrViewUv(viewUv) * SrActiveRenderScale();
}

vec2 SrViewUvFromSceneResourceUv(const in vec2 resourceUv) {
	return clamp(
		resourceUv / max(SrActiveRenderScale(), vec2(1.0e-6)),
		vec2(0.0),
		vec2(1.0)
	);
}

vec2 SrViewOffsetFromSceneResourceOffset(const in vec2 offset) {
	return offset / max(SrActiveRenderScale(), vec2(1.0e-6));
}

vec2 SrClampSceneResourceUv(const in vec2 resourceUv) {
	vec2 scale = SrActiveRenderScale();
	vec2 pixel = SrFullPixelSize();
	return clamp(resourceUv, pixel * 0.5, max(scale - pixel * 0.5, pixel * 0.5));
}

vec2 SrSceneSampleUv(const in vec2 viewUv) {
	return SrClampSceneResourceUv(SrSceneResourceUv(viewUv));
}

vec2 SrLocalResourceUv(
	const in vec2 localUv,
	const in ivec2 resourceSize
) {
	vec2 safeSize = vec2(max(resourceSize, ivec2(1)));
	vec2 pixel = 1.0 / safeSize;
	vec2 scale = SrActiveRenderScale();
	vec2 packedUv = SrViewUv(localUv) * scale;
	return clamp(packedUv, pixel * 0.5, max(scale - pixel * 0.5, pixel * 0.5));
}

vec2 SrPixelCenter(const in vec2 uv) {
	vec2 fullSize = SrFullSize();
	vec2 safeUv = clamp(uv, vec2(0.0), vec2(0.999999));
	return (floor(safeUv * fullSize) + vec2(0.5)) / fullSize;
}

vec2 SrSceneResourcePixelCenter(const in vec2 viewUv) {
	vec2 sceneSize = SrRenderSize();
	vec2 scenePixel = floor(SrViewUv(viewUv) * sceneSize) + vec2(0.5);
	return SrClampSceneResourceUv(scenePixel / SrFullSize());
}

ivec2 SrHalfSceneSize() {
	return max((ivec2(SrRenderSize()) + ivec2(1)) / 2, ivec2(1));
}

ivec2 SrActiveHalfSceneSize(const in ivec2 resourceSize) {
	return min(SrHalfSceneSize(), max(resourceSize, ivec2(1)));
}

// Ray-domain contract --------------------------------------------------------
//
// FOXY_RAY_RESOLUTION is a compile-time shader option because Iris custom
// images and compute dispatches must be resized together.  The helpers below
// use the actual active image size so fractional presets and odd window sizes
// partition every render pixel without gaps or overlaps.

float SrRayScale() {
	return clamp(FOXY_RAY_RESOLUTION, 0.25, 1.0);
}

ivec2 SrRaySceneSize() {
	return max(
		ivec2(ceil(SrRenderSize() * SrRayScale())),
		ivec2(1)
	);
}

ivec2 SrActiveRaySceneSize(const in ivec2 resourceSize) {
	return min(SrRaySceneSize(), max(resourceSize, ivec2(1)));
}

void SrRayCellPixelBounds(
	const in ivec2 rayPixel,
	const in ivec2 raySize,
	const in ivec2 renderSize,
	out ivec2 minimumPixel,
	out ivec2 maximumPixel
) {
	ivec2 safeRaySize = max(raySize, ivec2(1));
	vec2 rayToRenderScale = vec2(renderSize) / vec2(safeRaySize);
	minimumPixel = clamp(
		ivec2(ceil(vec2(rayPixel) * rayToRenderScale - vec2(1.0e-5))),
		ivec2(0),
		renderSize - ivec2(1)
	);
	maximumPixel = clamp(
		ivec2(ceil(
			vec2(rayPixel + ivec2(1)) * rayToRenderScale - vec2(1.0e-5)
		)) - ivec2(1),
		ivec2(0),
		renderSize - ivec2(1)
	);
}

ivec2 SrRayPrimaryPixel(
	const in ivec2 rayPixel,
	const in ivec2 raySize,
	const in ivec2 renderSize,
	const in int cornerIndex
) {
	bvec2 useMaximum = bvec2(
		(cornerIndex & 1) != 0,
		(cornerIndex & 2) != 0
	);
	vec2 boundaryOffset = vec2(
		useMaximum.x ? 1.0 : 0.0,
		useMaximum.y ? 1.0 : 0.0
	);
	vec2 rayToRenderScale = vec2(renderSize) /
		vec2(max(raySize, ivec2(1)));
	return clamp(
		ivec2(ceil(
			(vec2(rayPixel) + boundaryOffset) * rayToRenderScale -
			vec2(1.0e-5)
		)) - ivec2(boundaryOffset),
		ivec2(0),
		renderSize - ivec2(1)
	);
}

// Hot denoiser paths reuse this scale for every tap.  Keeping the exact same
// boundary formula while accepting the precomputed ratio avoids two divisions
// for each history/filter lookup.
ivec2 SrRayPrimaryPixelScaled(
	const in ivec2 rayPixel,
	const in vec2 rayToRenderScale,
	const in ivec2 renderSize,
	const in int cornerIndex
) {
	bvec2 useMaximum = bvec2(
		(cornerIndex & 1) != 0,
		(cornerIndex & 2) != 0
	);
	vec2 boundaryOffset = vec2(
		useMaximum.x ? 1.0 : 0.0,
		useMaximum.y ? 1.0 : 0.0
	);
	return clamp(
		ivec2(ceil(
			(vec2(rayPixel) + boundaryOffset) * rayToRenderScale -
			vec2(1.0e-5)
		)) - ivec2(boundaryOffset),
		ivec2(0),
		renderSize - ivec2(1)
	);
}

ivec2 SrRayPixelFromRenderPixel(
	const in ivec2 renderPixel,
	const in ivec2 renderSize,
	const in ivec2 raySize
) {
	return clamp(
		ivec2(floor(
			vec2(renderPixel) * vec2(raySize) /
			vec2(max(renderSize, ivec2(1))) + vec2(1.0e-5)
		)),
		ivec2(0),
		max(raySize - ivec2(1), ivec2(0))
	);
}

bool SrInsideRenderTexel(const in vec2 fragCoord) {
	vec2 renderSize = SrRenderSize();
	return fragCoord.x >= 0.0 && fragCoord.y >= 0.0 && fragCoord.x < renderSize.x && fragCoord.y < renderSize.y;
}

bool SrInsideActiveRenderTexel(const in vec2 fragCoord) {
	vec2 activeSize = SrFullSize() * SrActiveRenderScale();
	return fragCoord.x >= 0.0 && fragCoord.y >= 0.0 && fragCoord.x < activeSize.x && fragCoord.y < activeSize.y;
}

void SrScaleClipPosition(inout vec4 position) {
	#if FOXY_TAAU_ACTIVE == 1
		// Iris exposes one display-sized viewport for the main scene. Pack the
		// internal render domain into its lower-left sub-rectangle; scene
		// consumers convert logical view UVs through SrSceneResourceUv().
		vec2 scale = SrRenderScale();
		float safeW = abs(position.w) < 1.0e-6
			? (position.w < 0.0 ? -1.0e-6 : 1.0e-6)
			: position.w;
		position.xy /= safeW;
		position.xy = position.xy * scale + scale - vec2(1.0);
		position.xy *= position.w;
	#endif
}

void SrScaleClipPositionJittered(inout vec4 position, const in vec2 jitterUv) {
	SrScaleClipPosition(position);
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		position.xy += jitterUv * position.w;
	#endif
}

#endif
