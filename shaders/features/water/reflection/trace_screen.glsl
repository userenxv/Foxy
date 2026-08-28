#ifndef WATER_REFLECTION_TRACE_SCREEN_GLSL
#define WATER_REFLECTION_TRACE_SCREEN_GLSL

vec4 ProjectViewPos(const in vec3 viewPos) {
	// Decode Voxy depth with Voxy matrices, then project through the shared scene grid.
	vec4 clip = gbufferProjection * vec4(viewPos, 1.0);
	vec3 ndc = clip.xyz / SafeDivisor(clip.w);
	return vec4(ndc * 0.5 + 0.5, clip.w);
}

float TraceViewDepth(
	const in float rayT,
	const in vec2 startQzAndK,
	const in vec2 endQzAndK
) {
	// McGuire and Mara 2014: Q*k and k are affine in screen space.
	vec2 qzAndK = startQzAndK * (1.0 - rayT) + endQzAndK * rayT;
	return max(-qzAndK.x / SafeDivisor(qzAndK.y), 0.0);
}

float TraceNextT(
	const in float currentT,
	const in float fixedStep,
	const in float sampleDepth,
	const in vec2 startQzAndK,
	const in vec2 endQzAndK
) {
	// Approach Q/k depth crossings within the fixed iteration budget.
	float startEquation = startQzAndK.x + sampleDepth * startQzAndK.y;
	float endEquation = endQzAndK.x + sampleDepth * endQzAndK.y;
	float denominator = startEquation - endEquation;
	if (abs(denominator) > 1.0e-7) {
		float targetT = startEquation / denominator;
		float targetStep = (targetT - currentT) * 0.86;
		if (targetStep > 0.0 && targetStep < fixedStep) {
			return currentT + clamp(targetStep, fixedStep * 0.18, fixedStep);
		}
	}
	return currentT + fixedStep;
}

float AxisLimit(const in float pos, const in float dir) {
	if (abs(dir) < 1.0e-6) {
		return 1.0e6;
	}
	float target = dir > 0.0 ? 1.0 : 0.0;
	float t = (target - pos) / dir;
	return t > 0.0 ? t : 1.0e6;
}

float TraceLimit(const in vec3 screenPos, const in vec3 screenDelta) {
	float limitX = AxisLimit(screenPos.x, screenDelta.x);
	float limitY = AxisLimit(screenPos.y, screenDelta.y);
	// Only XY viewport bounds terminate the analytically extended depth ray.
	return min(limitX, limitY);
}

vec2 PixelCenter(const in vec2 uv) {
	vec2 viewSize = max(vec2(viewWidth, viewHeight) * SrActiveRenderScale(), vec2(1.0));
	#if defined(VOXY)
		// Quantize Voxy hits on the stable endpoint grid; add jitter after hit validation.
		vec2 safeViewUv = clamp(uv, vec2(0.0), vec2(0.999999));
		return (floor(safeViewUv * viewSize) + vec2(0.5)) / viewSize;
	#else
	vec2 rasterUv = WaterCurrentRasterUv(uv);
	vec2 safeRasterUv = clamp(rasterUv, vec2(0.0), vec2(0.999999));
	vec2 rasterCenter = (floor(safeRasterUv * viewSize) + vec2(0.5)) / viewSize;
	return WaterCurrentViewUv(rasterCenter);
	#endif
}

vec4 TraceWaterReflection(
	const in vec3 waterViewPos,
	const in vec3 reflectedDir
) {
	vec4 startProjected = ProjectViewPos(waterViewPos);
	if (startProjected.w <= 0.0) {
		return vec4(texcoord, 0.0, 0.0);
	}

	float waterDepth = max(-waterViewPos.z, 0.25);
	float reach = Saturate(FOXY_WATER_REFLECTION_STRETCH);
	// The bounded loop spans full MAIN/DH reach without a world-distance ceiling.
	float sceneReach = clamp(SceneReach(far), 72.0, 65536.0);
	float maxTraceRange = max(mix(96.0, 184.0, reach), sceneReach * mix(0.90, 1.0, reach));
	float rayLength = maxTraceRange;

	if (reflectedDir.z > 1.0e-5) {
		float nearHit = (-near - waterViewPos.z) / reflectedDir.z;
		if (nearHit <= 0.004) {
			return vec4(texcoord, 0.0, 0.0);
		}
		rayLength = min(rayLength, nearHit * 0.995);
	}

	if (rayLength <= 0.05) {
		return vec4(texcoord, 0.0, 0.0);
	}

	vec3 endViewPos = waterViewPos + reflectedDir * rayLength;
	vec4 endProjected = ProjectViewPos(endViewPos);
	if (endProjected.w <= 0.0) {
		return vec4(texcoord, 0.0, 0.0);
	}

	vec3 startScreen = startProjected.xyz;
	vec3 screenDelta = endProjected.xyz - startScreen;
	float pixelLength = length(screenDelta.xy / SrActivePixelSize());
	if (pixelLength < 2.0) {
		return vec4(texcoord, 0.0, 0.0);
	}

	const int stepCount = 28;
	float traceLimit = min(TraceLimit(startScreen, screenDelta), 1.0);
	if (traceLimit <= 0.0) {
		return vec4(texcoord, 0.0, 0.0);
	}
	float activeStepCount = mix(14.0, 28.0, reach);
	activeStepCount = mix(activeStepCount * 0.72, activeStepCount, smoothstep(180.0, 720.0, pixelLength));
#if FOXY_WATER_OPT_FAST_REFLECTION_TRACE == 1
	activeStepCount *= mix(0.72, 0.84, smoothstep(120.0, 620.0, pixelLength));
#endif
	activeStepCount = clamp(activeStepCount, 10.0, float(stepCount));
	float startK = 1.0 / SafeDivisor(startProjected.w);
	float endK = 1.0 / SafeDivisor(endProjected.w);
	vec2 startQzAndK = vec2(waterViewPos.z * startK, startK);
	vec2 endQzAndK = vec2(endViewPos.z * endK, endK);
	vec3 startRay = vec3(startScreen.xy, 0.0);
	vec3 rayDirection = vec3(screenDelta.xy, 1.0);
	float traceStep = traceLimit / activeStepCount;
	vec2 stablePixel = floor(WaterCurrentViewUv(texcoord) / SrActivePixelSize());
	float dither = 0.20 + Hash12(stablePixel) * 0.30;
	vec3 previousRay = startRay + rayDirection * (traceStep * 0.05);
	vec3 ray = startRay + rayDirection * (traceStep * dither);

	vec2 hitUv = texcoord;
	float hitCoverage = 0.0;
	float hitRaw = 0.0;

	for (int i = 0; i < stepCount; i++) {
		if (float(i) >= activeStepCount) {
			break;
		}
		vec2 rawUv = ray.xy;
		float onScreen = step(0.0, rawUv.x) * step(rawUv.x, 1.0) * step(0.0, rawUv.y) * step(rawUv.y, 1.0);
		if (onScreen < 0.5) {
			break;
		}
		vec2 uv = PixelCenter(rawUv);
		vec2 sampleUv = WaterCurrentRenderUv(uv);

		float sampleNotSky;
		float sampleLinearDepth = WaterSceneLinearDepth(uv, sampleUv, sampleNotSky);

		if (sampleNotSky > 0.5) {
			float previousRayDepth = TraceViewDepth(previousRay.z, startQzAndK, endQzAndK);
			float rayLinearDepth = TraceViewDepth(ray.z, startQzAndK, endQzAndK);
			float depthDelta = rayLinearDepth - sampleLinearDepth;
			float stepDepthSpan = abs(rayLinearDepth - previousRayDepth);
			float closeWater = 1.0 - smoothstep(2.0, 9.0, waterDepth);
			float farReflection = smoothstep(18.0, 96.0, sampleLinearDepth);
			float thickness = clamp(sampleLinearDepth * 0.013 + waterDepth * 0.0035 + closeWater * 0.75 + farReflection * 0.86, 0.15, 3.10);
			float candidateWindow = thickness + stepDepthSpan * 2.35 + 0.12 + farReflection * 0.48;

			if (depthDelta > -thickness * 0.35 && depthDelta < candidateWindow) {
				float sampleIsWater = WaterProducerValidAtViewUv(uv);
				if (sampleIsWater > 0.5) {
					previousRay = ray;
					ray = startRay + rayDirection * (ray.z + traceStep);
					continue;
				}
				vec3 low = previousRay;
				vec3 high = ray;

#if FOXY_WATER_OPT_SKIP_REFLECTION_REFINE == 0
				for (int refine = 0; refine < 2; refine++) {
					vec3 mid = (low + high) * 0.5;
					vec2 midRawUv = mid.xy;
					vec2 midUv = PixelCenter(mid.xy);
					float midOnScreen = step(0.0, midRawUv.x) * step(midRawUv.x, 1.0) * step(0.0, midRawUv.y) * step(midRawUv.y, 1.0);
					vec2 midSampleUv = WaterCurrentRenderUv(midUv);
					float midNotSky;
					float midSampleDepth = WaterSceneLinearDepth(midUv, midSampleUv, midNotSky);
					float midIsWater = midNotSky > 0.5 ? WaterProducerValidAtViewUv(midUv) : 0.0;

					if (midOnScreen < 0.5 || midNotSky < 0.5 || midIsWater > 0.5) {
						low = mid;
					} else {
						float midRayDepth = TraceViewDepth(mid.z, startQzAndK, endQzAndK);
						if (midRayDepth - midSampleDepth >= 0.0) {
							high = mid;
						} else {
							low = mid;
						}
					}
				}
#endif

				vec2 refinedUv = PixelCenter(high.xy);
				vec2 refinedSampleUv = WaterCurrentRenderUv(refinedUv);
				float refinedNotSky;
				float refinedSampleDepth = WaterSceneLinearDepth(refinedUv, refinedSampleUv, refinedNotSky);
				float refinedIsWater = WaterProducerValidAtViewUv(refinedUv);

				if (refinedNotSky > 0.5 && refinedIsWater < 0.5) {
					float refinedRayDepth = TraceViewDepth(high.z, startQzAndK, endQzAndK);
					float refinedDelta = refinedRayDepth - refinedSampleDepth;
					float refinedFarReflection = smoothstep(18.0, 96.0, refinedSampleDepth);
					float refinedThickness = clamp(refinedSampleDepth * 0.016 + waterDepth * 0.0038 + stepDepthSpan * 0.36 + closeWater * 1.10 + refinedFarReflection * 1.55, 0.18, 5.20);

					if (refinedDelta > -refinedThickness * 0.30 && refinedDelta < refinedThickness) {
						float edgeFade = ScreenEdgeFade(refinedUv);
						// Validated hits are opaque; only viewport exits blend to fallback.
						hitUv = refinedUv;
						hitCoverage = edgeFade;
						hitRaw = 1.0;
						break;
					}
				}
			}
		}

		float nextT = ray.z + traceStep;
		if (sampleNotSky > 0.5) {
			nextT = TraceNextT(
				ray.z,
				traceStep,
				sampleLinearDepth,
				startQzAndK,
				endQzAndK
			);
		}
		previousRay = ray;
		ray = startRay + rayDirection * nextT;
	}

	return vec4(hitUv, Saturate(hitCoverage), hitRaw);
}

#endif
