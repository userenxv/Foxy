#ifndef RAY_TRACE_SCREEN_GLSL
#define RAY_TRACE_SCREEN_GLSL

struct ScreenTraceResult {
	RayHit hit;
	vec2 screenUv;
	float normalizedDistance;
	float rejection;
	float terminal;
	vec3 transmittance;
};

float SsptSafeDivisor(const in float value) {
	if (abs(value) < 1.0e-6) {
		return value < 0.0 ? -1.0e-6 : 1.0e-6;
	}
	return value;
}

float SsptLinearDepth(const in float rawDepth) {
	float ndcZ = rawDepth * 2.0 - 1.0;
	return (2.0 * near * far) / max(far + near - ndcZ * (far - near), 1.0e-4);
}

float SsptStepPhase(
	const in ivec2 pixel,
	const in int stepIndex,
	const in int sampleIndex
) {
	uint state = uint(pixel.x) * 747796405u;
	state += uint(pixel.y) * 2891336453u;
	state += uint(max(frameCounter, 0)) * 277803737u;
	state += uint(stepIndex + 1) * 3266489917u;
	state += uint(sampleIndex + 1) * 668265263u;
	state ^= state >> 16u;
	state *= 2246822519u;
	state ^= state >> 13u;
	state *= 3266489917u;
	state ^= state >> 16u;
	return float(state) * (1.0 / 4294967296.0);
}

vec3 SsptViewPosFromDepth(const in vec2 viewUv, const in float rawDepth) {
	vec4 clip = vec4(viewUv * 2.0 - 1.0, rawDepth * 2.0 - 1.0, 1.0);
	vec4 view = gbufferProjectionInverse * clip;
	return view.xyz / SsptSafeDivisor(view.w);
}

vec4 SsptProjectViewPos(const in vec3 viewPos) {
	vec4 clip = gbufferProjection * vec4(viewPos, 1.0);
	vec3 ndc = clip.xyz / SsptSafeDivisor(clip.w);
	return vec4(ndc * 0.5 + 0.5, clip.w);
}

vec2 SsptRasterUvFromViewUv(const in vec2 viewUv) {
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return viewUv + temporalJitter * 0.5;
	#else
		return viewUv;
	#endif
}

vec2 SsptViewUvFromRasterUv(const in vec2 rasterUv) {
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return rasterUv - temporalJitter * 0.5;
	#else
		return rasterUv;
	#endif
}

ivec2 SsptRenderPixelFromViewUv(const in vec2 viewUv) {
	ivec2 renderSize = max(ivec2(SrRenderSize()), ivec2(1));
	vec2 rasterUv = clamp(SsptRasterUvFromViewUv(viewUv), vec2(0.0), vec2(0.999999));
	return clamp(ivec2(floor(rasterUv * vec2(renderSize))), ivec2(0), renderSize - ivec2(1));
}

vec2 SsptViewUvFromRenderPixel(const in ivec2 pixel) {
	vec2 renderSize = max(SrRenderSize(), vec2(1.0));
	vec2 rasterUv = (vec2(pixel) + vec2(0.5)) / renderSize;
	return SsptViewUvFromRasterUv(rasterUv);
}

float SsptAxisLimit(const in float position, const in float direction) {
	if (abs(direction) < 1.0e-6) {
		return 1.0e6;
	}
	float boundary = direction > 0.0 ? 1.0 : 0.0;
	float limit = (boundary - position) / direction;
	return limit > 0.0 ? limit : 1.0e6;
}

float SsptScreenLimit(const in vec3 position, const in vec3 direction) {
	return min(
		min(SsptAxisLimit(position.x, direction.x), SsptAxisLimit(position.y, direction.y)),
		SsptAxisLimit(position.z, direction.z)
	);
}

ScreenTraceResult TraceScreen(
	const in RayQuery query,
	const in ivec2 stratificationPixel,
	const in int sampleIndex
) {
	ScreenTraceResult result;
	result.hit = RayHitEmpty();
	result.screenUv = vec2(0.0);
	result.normalizedDistance = 0.0;
	result.rejection = 0.0;
	result.terminal = 0.0;
	result.transmittance = vec3(1.0);

	vec3 relativeOrigin = query.worldOrigin - cameraPosition;
	vec3 viewOrigin = (gbufferModelView * vec4(relativeOrigin, 1.0)).xyz;
	vec3 viewDirection = normalize(mat3(gbufferModelView) * query.worldDirection);
	float traceLength = max(query.maxDistance, 0.0);

	if (viewDirection.z > 1.0e-5) {
		float nearDistance = (-near - viewOrigin.z) / viewDirection.z;
		if (nearDistance <= 0.01) {
			return result;
		}
		traceLength = min(traceLength, nearDistance * 0.995);
	}
	if (traceLength <= 0.05) {
		return result;
	}

	vec4 startProjected = SsptProjectViewPos(viewOrigin);
	vec4 endProjected = SsptProjectViewPos(viewOrigin + viewDirection * traceLength);
	if (startProjected.w <= 0.0 || endProjected.w <= 0.0) {
		return result;
	}

	vec3 startScreen = startProjected.xyz;
	vec3 screenDelta = endProjected.xyz - startScreen;
	float screenLimit = min(SsptScreenLimit(startScreen, screenDelta), 1.0);
	if (screenLimit <= 0.0) {
		return result;
	}

	vec2 renderSize = max(SrRenderSize(), vec2(1.0));
	float pixelLength = length(screenDelta.xy * renderSize) * screenLimit;
	if (pixelLength < 1.5) {
		return result;
	}

	const int maxTraceSteps = 32;
	float configuredSteps = float(FOXY_SSPT_TRACE_STEPS);
	float activeSteps = clamp(ceil(pixelLength * 0.20), 6.0, configuredSteps);
	vec3 screenStep = screenDelta * (screenLimit / activeSteps);
	ivec2 originPixel = SsptRenderPixelFromViewUv(startScreen.xy);
	vec3 previousScreen = startScreen + screenStep * 0.005;
	float initialPhase = SsptStepPhase(stratificationPixel, 0, sampleIndex);
	vec3 currentScreen = startScreen + screenStep * (0.02 + initialPhase * 0.96);
	ivec2 previousPixel = SsptRenderPixelFromViewUv(previousScreen.xy);
	float previousDepthRaw = texelFetch(depthtex0, previousPixel, 0).r;
	vec2 previousPixelOffset = abs(vec2(previousPixel - originPixel));
	float previousDepthValid = (1.0 - step(0.99999, previousDepthRaw)) * step(0.5, max(previousPixelOffset.x, previousPixelOffset.y));
	float previousRayDepth = SsptLinearDepth(previousScreen.z);
	float previousSceneDepth = previousDepthValid > 0.5 ? SsptLinearDepth(previousDepthRaw) : previousRayDepth + 1.0e4;
	float previousDepthDelta = previousRayDepth - previousSceneDepth;
	float previousValid = previousDepthValid;
	if (previousDepthDelta >= 0.0 && previousDepthValid > 0.5) {
		previousValid *= 1.0 - MaterialIsWater(texelFetch(colortex2, previousPixel, 0));
	}
	bool emissiveFallbackBlocked = false;
	bool transmissionSeen = false;

	for (int stepIndex = 0; stepIndex < maxTraceSteps; stepIndex++) {
		if (float(stepIndex) >= activeSteps) {
			break;
		}
		if (any(lessThan(currentScreen, vec3(0.0))) || any(greaterThan(currentScreen, vec3(1.0)))) {
			break;
		}

		ivec2 scenePixel = SsptRenderPixelFromViewUv(currentScreen.xy);
		float frontDepthRaw = texelFetch(depthtex0, scenePixel, 0).r;
		vec4 frontSurface = texelFetch(colortex2, scenePixel, 0);
		float frontGlass = MaterialIsGlass(frontSurface);
		float sceneDepthRaw = transmissionSeen && frontGlass > 0.5
			? texelFetch(depthtex1, scenePixel, 0).r
			: frontDepthRaw;
		vec2 pixelOffset = abs(vec2(scenePixel - originPixel));
		float sceneDepthValid = (1.0 - step(0.99999, sceneDepthRaw)) * step(0.5, max(pixelOffset.x, pixelOffset.y));
		float currentRayDepth = SsptLinearDepth(currentScreen.z);
		float sceneDepth = sceneDepthValid > 0.5 ? SsptLinearDepth(sceneDepthRaw) : currentRayDepth + 1.0e4;
		float depthDelta = currentRayDepth - sceneDepth;
		float sceneValid = sceneDepthValid;
		vec4 sceneSurface = frontSurface;
		if (depthDelta >= 0.0 && sceneDepthValid > 0.5) {
			if (frontGlass > 0.5 && !transmissionSeen) {
				result.transmittance *= MaterialGlassTransmission(frontSurface);
				transmissionSeen = true;
			}
			sceneValid *= (1.0 - MaterialIsWater(sceneSurface)) *
				(1.0 - frontGlass);
		}

		if (sceneValid > 0.5 && depthDelta >= 0.0) {
			float stepDepthSpan = abs(currentRayDepth - previousRayDepth);
			float frontSlack = clamp(0.012 + sceneDepth * 0.00030, 0.015, 0.060);
			float thickness = clamp(0.040 + sceneDepth * 0.0020 + min(stepDepthSpan, 0.75) * 0.24, 0.060, 0.55);
			float refinementReach = min(thickness + stepDepthSpan * 1.15, 4.0);
			bool crossedFromFront = previousValid < 0.5 || previousDepthDelta <= frontSlack;

			if (crossedFromFront && depthDelta >= 0.0 && depthDelta <= refinementReach) {
				vec3 lowScreen = previousScreen;
				vec3 highScreen = currentScreen;

				for (int refineIndex = 0; refineIndex < 5; refineIndex++) {
					vec3 middleScreen = (lowScreen + highScreen) * 0.5;
					ivec2 middlePixel = SsptRenderPixelFromViewUv(middleScreen.xy);
					float middleDepthRaw = texelFetch(depthtex0, middlePixel, 0).r;
					float middleDepthValid = 1.0 - step(0.99999, middleDepthRaw);
					if (middleDepthValid < 0.5) {
						lowScreen = middleScreen;
						continue;
					}
					float middleDelta = SsptLinearDepth(middleScreen.z) - SsptLinearDepth(middleDepthRaw);
					if (middleDelta < 0.0) {
						lowScreen = middleScreen;
						continue;
					}
					float middleOpaque = 1.0 - MaterialIsWater(texelFetch(colortex2, middlePixel, 0));
					if (middleOpaque > 0.5) {
						highScreen = middleScreen;
					} else {
						lowScreen = middleScreen;
					}
				}

				ivec2 hitPixel = SsptRenderPixelFromViewUv(highScreen.xy);
				float hitDepthRaw = texelFetch(depthtex0, hitPixel, 0).r;
				vec4 hitSurface = texelFetch(colortex2, hitPixel, 0);
				float hitValid = (1.0 - step(0.99999, hitDepthRaw)) * (1.0 - MaterialIsWater(hitSurface));
				float refinedDelta = SsptLinearDepth(highScreen.z) - SsptLinearDepth(hitDepthRaw);
				float hitDepth = SsptLinearDepth(hitDepthRaw);
				float refinedThickness = clamp(0.035 + hitDepth * 0.0018 + min(stepDepthSpan, 0.75) * 0.16, 0.050, 0.42);

				if (hitValid > 0.5 && refinedDelta >= 0.0 && refinedDelta <= refinedThickness) {
					vec2 hitViewUv = SsptViewUvFromRenderPixel(hitPixel);
					vec3 hitViewPos = SsptViewPosFromDepth(hitViewUv, hitDepthRaw);
					vec3 hitPlayerPos = (gbufferModelViewInverse * vec4(hitViewPos, 1.0)).xyz;
					PtGbufferSample hitGbuffer = PtDecodeGbuffer(hitSurface, hitDepthRaw);
					result.hit.worldPosition = cameraPosition + hitPlayerPos;
					// History metadata stores the stable geometry normal.  Feedback
					// matching must use the same guide while the primary ray direction
					// remains driven by the full PBR shading normal.
					result.hit.worldNormal = hitGbuffer.worldGeometricNormal;
					result.hit.albedo = hitGbuffer.albedo;
					result.hit.emission = hitGbuffer.emission;
					result.hit.lightmap = hitGbuffer.lightmap;
					result.hit.surfaceClass = hitGbuffer.surfaceClass;
					result.hit.roughness = hitGbuffer.roughness;
					result.hit.metalness = hitGbuffer.metalness;
					result.hit.distance = length(hitViewPos - viewOrigin);
					result.hit.validity = hitGbuffer.valid;
					result.hit.backend = RAY_BACKEND_SCREEN;
					result.screenUv = hitViewUv;
					result.normalizedDistance = Saturate(result.hit.distance / max(query.maxDistance, 1.0e-4));
					return result;
				} else {
					result.rejection = max(result.rejection, 1.0);
				}
			} else if (depthDelta > refinementReach && crossedFromFront) {
				PtGbufferSample looseGbuffer = PtDecodeGbuffer(sceneSurface, sceneDepthRaw);
				float looseEmitter = PtSurfaceIsEmissive(looseGbuffer.surfaceClass) * looseGbuffer.valid;
				float emissiveCaptureReach = clamp(1.20 + sceneDepth * 0.055, 1.50, 7.50);
				if (!emissiveFallbackBlocked && looseEmitter > 0.5 && depthDelta <= emissiveCaptureReach) {
					vec2 hitViewUv = SsptViewUvFromRenderPixel(scenePixel);
					vec3 hitViewPos = SsptViewPosFromDepth(hitViewUv, sceneDepthRaw);
					vec3 hitPlayerPos = (gbufferModelViewInverse * vec4(hitViewPos, 1.0)).xyz;
					result.hit.worldPosition = cameraPosition + hitPlayerPos;
					result.hit.worldNormal = looseGbuffer.worldGeometricNormal;
					result.hit.albedo = looseGbuffer.albedo;
					result.hit.emission = looseGbuffer.emission;
					result.hit.lightmap = looseGbuffer.lightmap;
					result.hit.surfaceClass = looseGbuffer.surfaceClass;
					result.hit.roughness = looseGbuffer.roughness;
					result.hit.metalness = looseGbuffer.metalness;
					result.hit.distance = length(hitViewPos - viewOrigin);
					result.hit.validity = looseGbuffer.valid;
					result.hit.backend = RAY_BACKEND_SCREEN;
					result.screenUv = hitViewUv;
					result.normalizedDistance = Saturate(result.hit.distance / max(query.maxDistance, 1.0e-4));
					return result;
				}
				emissiveFallbackBlocked = true;
				result.rejection = max(result.rejection, 1.0);
			}
		}

		previousScreen = currentScreen;
		previousPixel = scenePixel;
		previousValid = sceneValid;
		previousRayDepth = currentRayDepth;
		previousSceneDepth = previousValid > 0.5 ? SsptLinearDepth(sceneDepthRaw) : previousRayDepth + 1.0e4;
		previousDepthDelta = previousRayDepth - previousSceneDepth;
		float nextOffset = float(stepIndex + 1) + 0.02
			+ SsptStepPhase(stratificationPixel, stepIndex + 1, sampleIndex) * 0.96;
		currentScreen = startScreen + screenStep * nextOffset;
	}

	if (result.rejection < 0.5 && screenLimit >= 0.999) {
		result.terminal = 1.0;
	}
	return result;
}

#endif
