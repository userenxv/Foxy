#include "/lib/settings.glsl"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
const vec2 workGroupsRender = vec2(
	FOXY_RAY_RESOLUTION,
	FOXY_RAY_RESOLUTION
);

layout(rgba16f) readonly uniform image2D img_ptHistoryMetaA;
layout(rgba16f) readonly uniform image2D img_ptHistoryMetaB;
layout(rgba16f) readonly uniform image2D img_ptFilteredA;
layout(rgba16f) writeonly uniform image2D img_ptFiltered;

uniform sampler2D colortex2;
uniform int frameCounter;
uniform float viewWidth;
uniform float viewHeight;

#include "/lib/math.glsl"
#include "/lib/sr.glsl"
#include "/lib/rt_denoiser.glsl"
#define PT_GBUFFER_READ
#include "/lib/pt_gbuffer.glsl"
#undef PT_GBUFFER_READ

#define SSPT_OUTLIER_GROUP_SIZE 16
#define SSPT_OUTLIER_TILE_SIDE (SSPT_OUTLIER_GROUP_SIZE + 2)
#define SSPT_OUTLIER_TILE_AREA (SSPT_OUTLIER_TILE_SIDE * SSPT_OUTLIER_TILE_SIDE)

shared float ssptOutlierVisibleLuma[SSPT_OUTLIER_TILE_AREA];
vec2 ssptOutlierRayToRenderScale;

bool SsptOutlierReadsA() {
	return (frameCounter % 2) == 0;
}

vec4 SsptOutlierMeta(const in ivec2 pixel) {
	if (SsptOutlierReadsA()) return imageLoad(img_ptHistoryMetaA, pixel);
	return imageLoad(img_ptHistoryMetaB, pixel);
}

float SsptOutlierIndirectIntensity() {
	#if FOXY_VOXEL_GI_ACTIVE == 1
		return clamp(FOXY_VOXEL_GI_INTENSITY, 0.0, 3.0) *
			(8.0 * FOXY_VXGI_MASTER_CALIBRATION);
	#else
		return clamp(FOXY_SSPT_BOUNCE_BRIGHTNESS, 0.0, 15.0);
	#endif
}

float SsptOutlierVisibleLuma(
	const in ivec2 requestedPixel,
	const in ivec2 signalSize,
	const in ivec2 renderSize,
	const in float bounceBrightness
) {
	ivec2 pixel = clamp(requestedPixel, ivec2(0), signalSize - ivec2(1));
	vec4 signal = imageLoad(img_ptFilteredA, pixel);
	vec4 meta = SsptOutlierMeta(pixel);
	if (!RtDenoiserFinite4(signal) || !RtDenoiserFinite4(meta)) return 0.0;
	float valid = RtDenoiserMetaValid(meta) * step(0.5, RtDenoiserMetaAge(meta));
	if (valid < 0.5) return 0.0;
	int primaryOffsetIndex = int(floor(
		RtDenoiserMetaPrimaryOffsetIndex(meta) + 0.5
	));
	ivec2 primaryPixel = SrRayPrimaryPixelScaled(
		pixel,
		ssptOutlierRayToRenderScale,
		renderSize,
		primaryOffsetIndex
	);
	vec3 albedo = PtDecodeGbufferAlbedo(
		texelFetch(colortex2, primaryPixel, 0)
	);
	return RtDenoiserLuma(
		max(signal.rgb, vec3(0.0)) * albedo * bounceBrightness
	);
}

int SsptOutlierSharedIndex(const in ivec2 localPixel) {
	return localPixel.y * SSPT_OUTLIER_TILE_SIDE + localPixel.x;
}

void SsptOutlierPreload(
	const in ivec2 signalSize,
	const in ivec2 renderSize,
	const in float bounceBrightness
) {
	ivec2 groupBase = ivec2(gl_WorkGroupID.xy) *
		SSPT_OUTLIER_GROUP_SIZE - ivec2(1);
	int localIndex = int(gl_LocalInvocationIndex);
	for (
		int tileIndex = localIndex;
		tileIndex < SSPT_OUTLIER_TILE_AREA;
		tileIndex += SSPT_OUTLIER_GROUP_SIZE *
			SSPT_OUTLIER_GROUP_SIZE
	) {
		ivec2 tilePixel = ivec2(
			tileIndex % SSPT_OUTLIER_TILE_SIDE,
			tileIndex / SSPT_OUTLIER_TILE_SIDE
		);
		ssptOutlierVisibleLuma[tileIndex] =
			SsptOutlierVisibleLuma(
				groupBase + tilePixel,
				signalSize,
				renderSize,
				bounceBrightness
			);
	}
	memoryBarrierShared();
	barrier();
}

void main() {
	ivec2 signalSize = SrActiveRaySceneSize(imageSize(img_ptFilteredA));
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, signalSize))) return;

	#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 1

		imageStore(img_ptFiltered, pixel, imageLoad(img_ptFilteredA, pixel));
		return;
	#endif

	ivec2 renderSize = max(ivec2(SrRenderSize()), ivec2(1));
	ssptOutlierRayToRenderScale = vec2(renderSize) /
		vec2(max(signalSize, ivec2(1)));
	float bounceBrightness = SsptOutlierIndirectIntensity();
	SsptOutlierPreload(signalSize, renderSize, bounceBrightness);

	vec4 centerSignal = imageLoad(img_ptFilteredA, pixel);
	vec4 centerMeta = SsptOutlierMeta(pixel);
	if (!RtDenoiserFinite4(centerSignal) || !RtDenoiserFinite4(centerMeta)) {
		imageStore(img_ptFiltered, pixel, vec4(0.0));
		return;
	}

	ivec2 centerLocalPixel = ivec2(gl_LocalInvocationID.xy) + ivec2(1);
	float center = ssptOutlierVisibleLuma[
		SsptOutlierSharedIndex(centerLocalPixel)
	];
	float left = ssptOutlierVisibleLuma[
		SsptOutlierSharedIndex(centerLocalPixel + ivec2(-1, 0))
	];
	float right = ssptOutlierVisibleLuma[
		SsptOutlierSharedIndex(centerLocalPixel + ivec2(1, 0))
	];
	float up = ssptOutlierVisibleLuma[
		SsptOutlierSharedIndex(centerLocalPixel + ivec2(0, -1))
	];
	float down = ssptOutlierVisibleLuma[
		SsptOutlierSharedIndex(centerLocalPixel + ivec2(0, 1))
	];
	float minimumValue = min(center, min(left, min(right, min(up, down))));
	float maximumValue = max(center, max(left, max(right, max(up, down))));
	float robustVisibleLuma =
		(center + left + right + up + down - minimumValue - maximumValue) * (1.0 / 3.0);
	float visibleCap = max(0.012, robustVisibleLuma * 1.35 + 0.020);
	float limiter = min(1.0, visibleCap / max(center, 1.0e-5));

	#if FOXY_SSPT_DENOISE_QUALITY == 1

		float release = smoothstep(1.0, 8.0, RtDenoiserMetaAge(centerMeta));
		limiter += (1.0 - limiter) * release;
	#endif

	centerSignal.rgb *= clamp(limiter, 0.0, 1.0);
	imageStore(img_ptFiltered, pixel, centerSignal);
}
