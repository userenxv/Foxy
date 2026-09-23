#ifndef FOXY_RSM_GLSL
#define FOXY_RSM_GLSL

// Reflective shadow maps: one diffuse bounce of direct sunlight, tinted by material colour.
//
// Capture runs in the shadow pass and writes albedo into shadowcolor1. The gather below
// projects the receiver into light space and averages those secondary sources over a disk.
//
// Shadow UVs are NOT linear NDC: the shadow vertex stage applies ShadowWarp(), a radial
// remap (r / max(base + slope * r, 0.10), up to ~8.3x magnification near the centre).
// So the sampling disk must be built in linear NDC and warped per sample, and UVs must be
// unwarped analytically (RsmShadowUnwarp) before unprojecting to world space.
#define RSM_MIN_DISTANCE_SQUARED 0.25 // d = max(|x - p|, 0.5 blocks), clamped not rejected

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/shadow.glsl"

uint RsmHashUint(uint x) {
	x ^= x >> 16;
	x *= 0x7feb352du;
	x ^= x >> 15;
	x *= 0x846ca68bu;
	x ^= x >> 16;
	return x;
}

float RsmHashPixelFrame(uvec2 pixel, int frame, uint salt) {
	uint key = pixel.x | (pixel.y << 16);
	uint h = RsmHashUint(key ^ RsmHashUint(uint(frame) ^ salt));
	return float(h & 0x00ffffffu) * (1.0 / 16777216.0);
}
#include "/lib/rsm_axis.glsl"

uniform vec3 shadowLightPosition;
uniform vec3 sunPosition;

#ifndef FOXY_RSM_EXTERNAL_UNIFORMS
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor1;
uniform mat4 shadowProjection;
uniform mat4 shadowProjectionInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;
uniform mat4 gbufferModelViewInverse;
#endif

vec2 RsmShadowUnwarp(const in vec2 warpedClipXY) {
	float warp = Saturate(FOXY_SHADOW_WARP);
	float base = 1.0 - warp;
	float slope = 1.16 * warp * warp;
	float radius = length(warpedClipXY);
	if (radius < 1.0e-9) return vec2(0.0);

	float rawRadius = -1.0;

	float denominator = 1.0 - slope * radius;
	if (denominator > 1.0e-9) {
		float candidate = base * radius / denominator;
		if (base + slope * candidate >= SHADOW_WARP_MIN_FACTOR) {
			rawRadius = candidate;
		}
	}

	if (rawRadius < 0.0) {
		float candidate = SHADOW_WARP_MIN_FACTOR * radius;
		if (base + slope * candidate <= SHADOW_WARP_MIN_FACTOR + 1.0e-6) {
			rawRadius = candidate;
		}
	}

	if (rawRadius < 0.0) return vec2(0.0);

	return warpedClipXY * (rawRadius / radius);
}

bool RsmProjectToShadow(
	const in vec3 playerPosition,
	out vec2 uv,
	out float depth
) {
	vec4 clip = shadowProjection * shadowModelView * vec4(playerPosition, 1.0);
	float w = abs(clip.w) < 1.0e-6 ? (clip.w < 0.0 ? -1.0e-6 : 1.0e-6) : clip.w;
	vec2 ndc = clip.xy / w;
	uv = ShadowWarp(ndc) * 0.5 + 0.5;
	depth = (clip.z / w) * 0.5 + 0.5;
	return all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)));
}

vec3 RsmUnprojectFromShadow(const in vec2 uv, const in float depth) {
	vec2 rawNdc = RsmShadowUnwarp(uv * 2.0 - 1.0);
	vec4 clip = vec4(rawNdc, depth * 2.0 - 1.0, 1.0);
	return (shadowModelViewInverse * (shadowProjectionInverse * clip)).xyz;
}

//
//
vec3 RsmGather(const in vec3 playerPosition, const in vec3 worldNormal) {
	vec4 receiverClip = shadowProjection * shadowModelView * vec4(playerPosition, 1.0);
	float receiverW = abs(receiverClip.w) < 1.0e-6
		? (receiverClip.w < 0.0 ? -1.0e-6 : 1.0e-6)
		: receiverClip.w;
	vec2 receiverNdc = receiverClip.xy / receiverW;

	// Cranley-Patterson rotation of the sample parameters: every pixel shifts the whole
	// low discrepancy sequence by its own 2D offset. This is what converts the projective
	// streaking into plain noise. Streaking comes from all pixels sampling at the same
	// relative offsets, so a small shift in the domain maps to a small shift in the
	// output; shifting the parameters breaks that correspondence. Shifting the parameters
	// rather than rotating the finished disk also decorrelates the radial positions, not
	// just the angles, and wrapping through fract() keeps the sequence uniform.
	vec2 sampleShift = vec2(0.0);
	#if FOXY_RSM_JITTER == 1
		sampleShift = vec2(
			RsmHashPixelFrame(gl_GlobalInvocationID.xy, 0, 0u),
			RsmHashPixelFrame(gl_GlobalInvocationID.xy, 0, 0x68bc21ebu)
		);
		#if FOXY_TAA_ENABLED == 1
			sampleShift += vec2(
				RsmHashPixelFrame(gl_GlobalInvocationID.xy, frameCounter, 0x9e3779b9u),
				RsmHashPixelFrame(gl_GlobalInvocationID.xy, frameCounter, 0x85ebca6bu)
			);
		#endif
	#endif

	float distanceCutoff = max(FOXY_RSM_DISTANCE, 1.0);
	float distanceCutoffSquared = distanceCutoff * distanceCutoff;

	// Length check: if the uniform is unbound it is a zero vector, and normalizing it
	// would produce NaN that spreads through the whole accumulation.
	if (dot(shadowLightPosition, shadowLightPosition) < 1.0e-8) return vec3(0.0);
	vec3 sunDirection = normalize(
		mat3(gbufferModelViewInverse) * normalize(shadowLightPosition)
	);

	// Day/night must come from sunPosition, not from sunDirection: at night Iris swaps
	// shadowLightPosition for the moon, so sunDirection.y stays positive and the bounce
	// would otherwise run at full daylight brightness.
	//
	// sunPosition is a view space direction, so its height is only meaningful after the
	// rotation to world space. Read raw, sunPosition.y measures the sun against the
	// screen's up axis instead of against the horizon, which makes the bounce fade out
	// as the player tilts the camera rather than as the sun moves.
	vec3 worldSunPosition = mat3(gbufferModelViewInverse) * sunPosition;
	float dayFactor = smoothstep(-0.02, 0.06, worldSunPosition.y);
	if (dayFactor <= 0.0) return vec3(0.0);

	float clipPerWorld = max(abs(shadowProjection[0][0]), 1.0e-6);
	float radiusNdc = FOXY_RSM_RADIUS * clipPerWorld;

	vec3 accumulated = vec3(0.0);
	float weightSum = 0.0;
	const float goldenAngle = 2.39996323;
	const float goldenAngleNormalized = goldenAngle * (0.5 / PI);
	for (int sampleIndex = 0; sampleIndex < FOXY_RSM_SAMPLES; sampleIndex++) {
		float sampleOrder = float(sampleIndex) + 0.5;
		// the two parameters of the low discrepancy sequence, each shifted by the pixel's
		// own offset and wrapped, which is the Cranley-Patterson rotation above
		float radialParameter = fract(
			sampleOrder * (1.0 / float(FOXY_RSM_SAMPLES)) + sampleShift.x
		);
		float angularParameter = fract(
			sampleOrder * goldenAngleNormalized + sampleShift.y
		);
		float radiusNormalized = sqrt(max(radialParameter, 1.0e-6));
		float angle = angularParameter * (2.0 * PI);
		vec2 diskOffset = vec2(cos(angle), sin(angle)) *
			(radiusNormalized * radiusNdc);
		vec2 sampleNdc = receiverNdc + diskOffset;
		vec2 sampleUv = ShadowWarp(sampleNdc) * 0.5 + 0.5;
		if (any(lessThan(sampleUv, vec2(0.0))) || any(greaterThan(sampleUv, vec2(1.0)))) continue;

		float sampleDepth = texture2D(shadowtex1, sampleUv).r;
		if (sampleDepth >= 0.9999) continue;

		vec4 rsmSample = texture2D(shadowcolor1, sampleUv);

		vec3 samplePlayerPosition = RsmUnprojectFromShadow(sampleUv, sampleDepth);

		vec3 delta = samplePlayerPosition - playerPosition;
		float distanceSquared = dot(delta, delta);
		if (distanceSquared > distanceCutoffSquared) continue;

		float clampedDistanceSquared = max(distanceSquared, RSM_MIN_DISTANCE_SQUARED);

		vec3 toVpl = delta * inversesqrt(clampedDistanceSquared);
		float receiverCosine = dot(worldNormal, toVpl);
		if (receiverCosine <= 0.0) continue;

		vec3 vplNormal;
		if (!RsmUnpackAxisNormal(rsmSample.a, vplNormal)) continue;
		float vplCosine = -dot(vplNormal, toVpl);
		if (vplCosine <= 0.0) continue;

		// How much sun the secondary source itself receives. shadowcolor1 holds albedo
		// only, so without this every face would emit as if it faced the sun head-on.
		float vplSunCosine = max(0.0, dot(sunDirection, vplNormal));
		if (vplSunCosine <= 0.0) continue;

		// dayFactor can ride the weight: the estimate is normalised by sample count, so
		// scaling every weight scales the result linearly.
		float radialWeight = 1.0 - radiusNormalized * radiusNormalized;
		float distanceFade = 1.0 - smoothstep(distanceCutoff * 0.5, distanceCutoff, sqrt(distanceSquared));
		float weight = radialWeight * receiverCosine * vplCosine * vplSunCosine *
			dayFactor * distanceFade / clampedDistanceSquared;
		if (weight <= 1.0e-6) continue;

		accumulated += rsmSample.rgb * weight;
		weightSum += weight;
	}

	if (weightSum <= 1.0e-6) return vec3(0.0);
	// The samples are uniform over a disk, so each one stands for that area divided by the
	// sample count. The area has to follow the radius slider, otherwise the result would be
	// tied to one radius and the slider would act as a brightness control.
	float sampleArea = PI * FOXY_RSM_RADIUS * FOXY_RSM_RADIUS;
	return accumulated * (sampleArea / float(FOXY_RSM_SAMPLES));
}

#endif
