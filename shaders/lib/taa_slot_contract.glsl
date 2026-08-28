#ifndef FOXY_TAA_SLOT_CONTRACT_GLSL
#define FOXY_TAA_SLOT_CONTRACT_GLSL

// Algorithm-independent temporal insertion contract. The public surface is
// assembled before the algorithm from opaque MAIN/DH ownership and the current
// water segment. Cloud presentation, material IDs, SSPT history, and the
// cloud history are not algorithm inputs.
//
// A first-person hand/item is not a second scene layer: Minecraft writes it
// into the canonical depth buffer with a compressed clip-space depth range.
// Treat it as a camera-relative projection domain here, before endpoint and
// reprojection work without consuming a composite pass or exposing a
// hand-specific input to a future TAA algorithm.

#include "/lib/contracts/endpoint.glsl"

// Negative alpha distinguishes valid history from the zero-cleared buffer.
const float FOXY_TAA_SLOT_HISTORY_DEPTH_BASE = 0.25;
const float FOXY_TAA_SLOT_HISTORY_DEPTH_SCALE = 0.50;
const float FOXY_TAA_SLOT_FIRST_PERSON_DEPTH_CUTOFF = 0.56;

struct TaaSlotSurface {
	vec2 rasterUv;
	vec2 viewUv;
	float mainRawDepth;
	float projectionRawDepth;
	float viewDistance;
	float valid;
	float firstPerson;
	float water;
	float reactive;
	Endpoint endpoint;
};

struct TaaSlotReprojection {
	vec2 previousUv;
	vec2 motionUv;
	float expectedPreviousMetric;
	float currentMetric;
	float valid;
	float closestTap;
	float firstPerson;
	float water;
};

float TaaSlotSafeDivisor(const in float value) {
	if (abs(value) < 1.0e-6) return value < 0.0 ? -1.0e-6 : 1.0e-6;
	return value;
}

vec3 TaaSlotViewPosition(const in vec2 viewUv, const in float rawDepth) {
	vec4 clip = vec4(viewUv * 2.0 - 1.0, rawDepth * 2.0 - 1.0, 1.0);
	vec4 view = gbufferProjectionInverse * clip;
	return view.xyz / TaaSlotSafeDivisor(view.w);
}

float TaaSlotDepthMetric(const in float viewDistance, const in float valid) {
	if (valid < 0.5) return 1.0;
	float sceneReach = max(SceneReach(max(far, 1.0)), 1.0);
	float metric = log2(1.0 + max(viewDistance, 0.0)) / log2(1.0 + sceneReach);
	// Reserve exact 1.0 for sky/unoccupied pixels after half-float packing.
	return clamp(metric, 0.0, 0.998);
}

float TaaSlotIsFirstPersonDepth(const in float rawDepth) {
	return 1.0 - step(FOXY_TAA_SLOT_FIRST_PERSON_DEPTH_CUTOFF, rawDepth);
}

float TaaSlotProjectionDepth(const in float rawDepth, const in float firstPerson) {
	if (firstPerson < 0.5) return rawDepth;
	// MC_HAND_DEPTH is supplied by the shader runtime.  Hand depth is encoded
	// in its reduced NDC range and must be restored before inverse projection.
	float ndcDepth = rawDepth * 2.0 - 1.0;
	return clamp(ndcDepth / MC_HAND_DEPTH * 0.5 + 0.5, 0.0, 1.0 - 1.0e-6);
}

TaaSlotSurface TaaSlotLoadSurface(const in vec2 rasterUv) {
	TaaSlotSurface surface;
	surface.rasterUv = rasterUv;
	surface.viewUv = rasterUv - temporalJitter * 0.5;
	ivec2 depthTextureSize = max(textureSize(depthtex0, 0), ivec2(1));
	ivec2 renderSize = min(max(ivec2(SrRenderSize()), ivec2(1)), depthTextureSize);
	ivec2 depthTexel = clamp(
		ivec2(rasterUv * vec2(renderSize)),
		ivec2(0),
		renderSize - ivec2(1)
	);
	vec2 resourceUv = (vec2(depthTexel) + 0.5) / vec2(depthTextureSize);
	// Raster UV carries the subpixel phase used for motion, while depth/water/DH
	// ownership must be fetched from one discrete producer texel. Bilinear depth
	// here would manufacture surfaces at every silhouette.
	surface.mainRawDepth = texelFetch(depthtex0, depthTexel, 0).r;
	surface.firstPerson = TaaSlotIsFirstPersonDepth(surface.mainRawDepth);
	WaterSegment waterSegment = WaterSegmentUnpack(LoadWaterSegment(resourceUv));
	// depthtex0 may contain the translucent water depth itself. Comparing the
	// producer against that nearly identical reconstructed distance creates a
	// wave-shaped green/cyan classification pattern. For water candidates use
	// the pre-translucent opaque depth; all other surfaces retain depthtex0.
	float opaqueRawDepth = texelFetch(depthtex1, depthTexel, 0).r;
	float surfaceRawDepth = mix(
		surface.mainRawDepth,
		opaqueRawDepth,
		waterSegment.valid * (1.0 - surface.firstPerson)
	);
	surface.projectionRawDepth = TaaSlotProjectionDepth(surfaceRawDepth, surface.firstPerson);
	// Rebuild the current sample directly from canonical depth. This keeps the
	// algorithm input in the same raster/view domain as colortex14 and avoids
	// coupling it to the separately cached cloud-presentation endpoint.
	surface.endpoint = ResolveOpaqueEndpoint(
		surface.viewUv,
		resourceUv,
		surface.projectionRawDepth,
		gbufferProjectionInverse
	);
	surface.water = waterSegment.valid * (1.0 - surface.firstPerson) *
		step(waterSegment.frontRayDistance, surface.endpoint.rayDistance - 1.0e-5);
	surface.endpoint = ResolveWaterEndpoint(
		surface.endpoint,
		waterSegment.frontRayDistance,
		waterSegment.frontViewDistance,
		surface.water,
		waterSegment.owner,
		FOXY_ENDPOINT_MEDIUM_WATER
	);
	surface.valid = EndpointValid(surface.endpoint);
	surface.viewDistance = surface.valid > 0.5
		? surface.endpoint.viewDistance
		: FOXY_ENDPOINT_INFINITY;
	// This is a generic confidence input, not a hard rejection policy. Water
	// receives temporal accumulation with reduced confidence; first-person
	// animation is current-only because no previous model transform is exposed.
	surface.reactive = max(surface.firstPerson, surface.water * 0.65);
	return surface;
}

void TaaSlotClosestDepth(
	const in vec2 centerUv,
	out TaaSlotSurface centerSurface,
	out TaaSlotSurface closestSurface,
	out float closestTap,
	out float centerMetric
) {
	ivec2 depthTextureSize = max(textureSize(depthtex0, 0), ivec2(1));
	ivec2 renderSize = min(max(ivec2(SrRenderSize()), ivec2(1)), depthTextureSize);
	vec2 pixel = 1.0 / vec2(renderSize);
	const ivec2 offsets[9] = ivec2[9](
		ivec2(0, 0),
		ivec2(-1, -1), ivec2(0, -1), ivec2(1, -1),
		ivec2(-1,  0),                 ivec2(1,  0),
		ivec2(-1,  1), ivec2(0,  1), ivec2(1,  1)
	);
	// Selection uses the resolve's 3x3 MAIN depth neighborhood, followed by
	// one complete MAIN/DH/water decode for the winner. Equal depths retain the
	// center, so sky and MAIN-empty DH regions cannot randomly exchange taps.
	centerSurface = TaaSlotLoadSurface(centerUv);
	closestSurface = centerSurface;
	centerMetric = TaaSlotDepthMetric(centerSurface.viewDistance, centerSurface.valid);
	closestTap = 0.0;
	float closestRawDepth = centerSurface.mainRawDepth;
	vec2 closestUv = centerUv;
	for (int tap = 1; tap < 9; ++tap) {
		vec2 sampleUv = clamp(centerUv + vec2(offsets[tap]) * pixel, pixel * 0.5, vec2(1.0) - pixel * 0.5);
		ivec2 sampleTexel = clamp(
			ivec2(sampleUv * vec2(renderSize)),
			ivec2(0),
			renderSize - ivec2(1)
		);
		float sampleRawDepth = texelFetch(depthtex0, sampleTexel, 0).r;
		if (sampleRawDepth < closestRawDepth) {
			closestRawDepth = sampleRawDepth;
			closestUv = sampleUv;
			closestTap = float(tap);
		}
	}
	if (closestTap > 0.5) closestSurface = TaaSlotLoadSurface(closestUv);
}

vec4 TaaSlotPreviousViewPosition(const in vec3 currentViewPosition, const in float firstPerson) {
	vec4 player = gbufferModelViewInverse * vec4(currentViewPosition, 1.0);
	player.xyz /= TaaSlotSafeDivisor(player.w);
	// First-person geometry is camera-relative and excludes world translation.
	player.xyz += (cameraPosition - previousCameraPosition) * (1.0 - firstPerson);
	return gbufferPreviousModelView * vec4(player.xyz, 1.0);
}

vec4 TaaSlotPreviousSkyClip(const in vec3 currentViewDirection) {
	vec3 playerDirection = mat3(gbufferModelViewInverse) * currentViewDirection;
	vec3 previousViewDirection = mat3(gbufferPreviousModelView) * playerDirection;
	return gbufferPreviousProjection * vec4(previousViewDirection, 0.0);
}

TaaSlotReprojection TaaSlotBuildReprojection(const in vec2 centerUv) {
	TaaSlotReprojection result;
	TaaSlotSurface centerSurface;
	TaaSlotSurface closestSurface;
	TaaSlotClosestDepth(centerUv, centerSurface, closestSurface, result.closestTap, result.currentMetric);
	// First-person mesh animation has no previous-model transform supplied by
	// Minecraft.  Preserve this domain bit for the temporal resolve policy:
	// write current history, but never blend stale hand/item history back in.
	result.firstPerson = centerSurface.firstPerson;
	result.water = centerSurface.water;

	// History lives on the stable output grid. The current raster phase is
	// removed in TaaSlotLoadSurface; previous jitter must not be re-added.
	vec2 previousJitterUv = vec2(0.0);
	vec4 previousClip;

	// A closest-depth tap may cross the hand/world projection-domain boundary.
	// It is conservative within a domain, but invalid across domains: retain
	// the center motion in that case instead of smearing hand motion onto world.
	TaaSlotSurface motionSurface = closestSurface;
	if (abs(closestSurface.firstPerson - centerSurface.firstPerson) > 0.5) {
		motionSurface = centerSurface;
	}

	if (motionSurface.valid < 0.5) {
		vec3 viewDirection = normalize(TaaSlotViewPosition(motionSurface.viewUv, 1.0));
		previousClip = TaaSlotPreviousSkyClip(viewDirection);
	} else {
		vec3 viewPosition = EndpointViewPosition(
			motionSurface.endpoint,
			motionSurface.viewUv,
			motionSurface.projectionRawDepth,
			gbufferProjectionInverse
		);
		vec4 previousView = TaaSlotPreviousViewPosition(viewPosition, motionSurface.firstPerson);
		previousClip = EndpointPreviousClip(
			motionSurface.endpoint,
			previousView,
			gbufferPreviousProjection
		);
	}

	// The closest surface supplies a conservative camera-motion vector, but
	// history depth belongs to the center pixel.  Using the closest surface for
	// both would reject every static silhouette even when reprojection is exact.
	if (centerSurface.valid < 0.5) {
		result.expectedPreviousMetric = 1.0;
	} else {
		vec3 centerViewPosition = EndpointViewPosition(
			centerSurface.endpoint,
			centerSurface.viewUv,
			centerSurface.projectionRawDepth,
			gbufferProjectionInverse
		);
		vec4 centerPreviousView = TaaSlotPreviousViewPosition(centerViewPosition, centerSurface.firstPerson);
		result.expectedPreviousMetric = TaaSlotDepthMetric(max(-centerPreviousView.z, 0.0), 1.0);
	}

	result.valid = step(1.0e-5, previousClip.w) * step(1.5, float(frameCounter));
	vec3 previousNdc = previousClip.xyz / TaaSlotSafeDivisor(previousClip.w);
	vec2 previousClosestUv = previousNdc.xy * 0.5 + 0.5 + previousJitterUv;
	result.motionUv = motionSurface.rasterUv - previousClosestUv;
	result.previousUv = centerUv - result.motionUv;

	vec2 edge = 0.5 / vec2(max(textureSize(colortex12, 0), ivec2(1)));
	result.valid *= step(edge.x, result.previousUv.x) * step(result.previousUv.x, 1.0 - edge.x);
	result.valid *= step(edge.y, result.previousUv.y) * step(result.previousUv.y, 1.0 - edge.y);
	if (motionSurface.valid > 0.5 && motionSurface.firstPerson < 0.5 && length(cameraPosition - previousCameraPosition) > 8.0) result.valid = 0.0;
	result.previousUv = clamp(result.previousUv, edge, vec2(1.0) - edge);
	return result;
}

bool TaaSlotHistoryValid(const in vec4 historySample) {
	return historySample.a <= -FOXY_TAA_SLOT_HISTORY_DEPTH_BASE + 0.001
		&& historySample.a >= -(FOXY_TAA_SLOT_HISTORY_DEPTH_BASE + FOXY_TAA_SLOT_HISTORY_DEPTH_SCALE) - 0.001;
}

float TaaSlotPackHistoryMetric(const in float depthMetric) {
	return -(FOXY_TAA_SLOT_HISTORY_DEPTH_BASE + FOXY_TAA_SLOT_HISTORY_DEPTH_SCALE * clamp(depthMetric, 0.0, 1.0));
}

float TaaSlotUnpackHistoryMetric(const in vec4 historySample) {
	return clamp((-historySample.a - FOXY_TAA_SLOT_HISTORY_DEPTH_BASE) / FOXY_TAA_SLOT_HISTORY_DEPTH_SCALE, 0.0, 1.0);
}

#endif
