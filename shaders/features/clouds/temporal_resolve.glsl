#ifndef FOXY_CLOUD_TEMPORAL_RESOLVE_GLSL
#define FOXY_CLOUD_TEMPORAL_RESOLVE_GLSL

// Cloud CBR sampling and history only. Resource writes belong to the caller.
vec4 CloudEncodeHistoryBuffer(const in vec4 cloud) {
	return vec4(EncodeSceneColor(max(cloud.rgb, vec3(0.0))), Saturate(cloud.a));
}

vec4 CloudDecodeHistoryBuffer(const in vec4 cloud) {
	return CloudCompositeClamp(vec4(DecodeSceneColor(cloud.rgb), Saturate(cloud.a)));
}

ivec2 CloudRenderSize() {
	return max(ivec2(floor(vec2(viewWidth, viewHeight) * SrActiveRenderScale())), ivec2(1));
}

ivec2 CloudFullPixel(const in vec2 uv) {
	ivec2 renderSize = CloudRenderSize();
	return clamp(ivec2(floor(clamp(uv, vec2(0.0), vec2(0.999999)) * vec2(renderSize))), ivec2(0), renderSize - ivec2(1));
}

ivec2 CloudActiveSourceSize() {
	ivec2 requiredSize = (CloudRenderSize() + ivec2(CBR_BLOCK_SIZE - 1)) / CBR_BLOCK_SIZE;
	return max(min(requiredSize, textureSize(colortex1, 0)), ivec2(1));
}

ivec2 CloudClampSourcePixel(const in ivec2 pixel) {
	ivec2 sourceSize = CloudActiveSourceSize();
	return clamp(pixel, ivec2(0), sourceSize - ivec2(1));
}

vec4 CloudReadSourceCompact(const in ivec2 compactPixel) {
	return CloudDecodeHistoryBuffer(texelFetch(colortex1, CloudClampSourcePixel(compactPixel), 0));
}

vec4 CloudReadDistanceCompact(const in ivec2 compactPixel) {
	ivec2 sourceSize = max(min(CloudActiveSourceSize(), textureSize(colortex10, 0)), ivec2(1));
	return texelFetch(colortex10, clamp(compactPixel, ivec2(0), sourceSize - ivec2(1)), 0);
}

void CloudCurrentLattice(const in vec2 uv, out ivec2 basePixel, out vec2 fraction) {
	vec2 fullPosition = clamp(uv, vec2(0.0), vec2(1.0)) * vec2(CloudRenderSize()) - vec2(0.5);
	vec2 latticePosition = (fullPosition - vec2(CbrPhaseOffset(frameCounter))) / float(CBR_BLOCK_SIZE);
	basePixel = ivec2(floor(latticePosition));
	fraction = clamp(fract(latticePosition), vec2(0.0), vec2(1.0));
}

vec4 CloudReadCurrentSpatial(const in vec2 uv) {
	ivec2 basePixel;
	vec2 fraction;
	CloudCurrentLattice(uv, basePixel, fraction);
	vec4 s00 = CloudReadSourceCompact(basePixel);
	vec4 s10 = CloudReadSourceCompact(basePixel + ivec2(1, 0));
	vec4 s01 = CloudReadSourceCompact(basePixel + ivec2(0, 1));
	vec4 s11 = CloudReadSourceCompact(basePixel + ivec2(1, 1));
	return CloudCompositeClamp(mix(mix(s00, s10, fraction.x), mix(s01, s11, fraction.x), fraction.y));
}

vec4 CloudReadCurrentPoint(const in vec2 uv) {
	return CloudReadSourceCompact(CbrCompactPixel(CloudFullPixel(uv)));
}

vec4 CloudReadCurrentDistance(const in vec2 uv) {
	ivec2 basePixel;
	vec2 fraction;
	CloudCurrentLattice(uv, basePixel, fraction);
	vec4 d00 = CloudReadDistanceCompact(basePixel);
	vec4 d10 = CloudReadDistanceCompact(basePixel + ivec2(1, 0));
	vec4 d01 = CloudReadDistanceCompact(basePixel + ivec2(0, 1));
	vec4 d11 = CloudReadDistanceCompact(basePixel + ivec2(1, 1));
	return mix(mix(d00, d10, fraction.x), mix(d01, d11, fraction.x), fraction.y);
}

vec4 CloudReadHistory(const in vec2 uv) {
	return CloudDecodeHistoryBuffer(texture2D(
		colortex8,
		SrLocalResourceUv(uv, textureSize(colortex8, 0))
	));
}

vec4 CloudReadHistoryMeta(const in vec2 uv) {
	ivec2 renderSize = CloudRenderSize();
	ivec2 historyPixel = clamp(
		ivec2(floor(clamp(uv, vec2(0.0), vec2(0.999999)) * vec2(renderSize))),
		ivec2(0),
		renderSize - ivec2(1)
	);
	if (all(equal(historyPixel, ivec2(0)))) {
		historyPixel.x = min(1, renderSize.x - 1);
	}
	return texelFetch(colortex9, historyPixel, 0);
}

vec3 CloudScreenViewRay(const in vec2 uv) {
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 view = gbufferProjectionInverse * vec4(ndc, 1.0, 1.0);
	return normalize(view.xyz / CloudSafeDivisor(view.w));
}

vec3 CloudCameraWorldPos() {
	return cameraPosition + gbufferModelViewInverse[3].xyz;
}

vec3 CloudPreviousViewOffset() {
	vec3 previousViewTranslation = gbufferPreviousModelView[3].xyz;
	return -vec3(
		dot(gbufferPreviousModelView[0].xyz, previousViewTranslation),
		dot(gbufferPreviousModelView[1].xyz, previousViewTranslation),
		dot(gbufferPreviousModelView[2].xyz, previousViewTranslation)
	);
}

vec3 CloudCompositeWindDir() {
	return normalize(vec3(0.78, 0.0, 0.62));
}

vec2 CloudCompositeSphereIntersection(
	const in vec3 rayOrigin,
	const in vec3 rayDir,
	const in float radius
) {
	vec3 localOrigin = vec3(0.0, CLOUD_COMPOSITE_PLANET_RADIUS + rayOrigin.y, 0.0);
	float b = dot(localOrigin, rayDir);
	float c = dot(localOrigin, localOrigin) - radius * radius;
	float h = b * b - c;
	if (h < 0.0) {
		return vec2(1.0e8, -1.0e8);
	}
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}

void CloudCompositeLayerInterval(
	const in vec3 rayOrigin,
	const in vec3 rayDir,
	const in float bottom,
	const in float top,
	out float tNear,
	out float tFar
) {
	float altitude = rayOrigin.y;
	if (altitude < bottom && rayDir.y <= 0.0) {
		tNear = 1.0e8;
		tFar = -1.0e8;
		return;
	}
	if (altitude > top && rayDir.y >= 0.0) {
		tNear = 1.0e8;
		tFar = -1.0e8;
		return;
	}

	vec2 outer = CloudCompositeSphereIntersection(rayOrigin, rayDir, CLOUD_COMPOSITE_PLANET_RADIUS + top);
	vec2 inner = CloudCompositeSphereIntersection(rayOrigin, rayDir, CLOUD_COMPOSITE_PLANET_RADIUS + bottom);
	tNear = 1.0e8;
	tFar = -1.0e8;

	if (outer.y <= 0.0) {
		return;
	}
	if (altitude < bottom) {
		tNear = max(inner.y, 0.0);
		tFar = outer.y;
	} else if (altitude > top) {
		tNear = max(outer.x, 0.0);
		tFar = inner.x > tNear ? inner.x : outer.y;
	} else {
		tNear = 0.0;
		tFar = rayDir.y < 0.0 && inner.x > 0.0 ? inner.x : outer.y;
	}

	tNear = max(tNear, 0.0);
	tFar = min(tFar, CLOUD_COMPOSITE_TRACE_LIMIT);
	if (tFar <= tNear) {
		tNear = 1.0e8;
		tFar = -1.0e8;
	}
}

float CloudStableLayerDistance(const in vec3 cameraWorldPos, const in vec3 worldDir) {
	vec3 referenceCameraWorldPos = CloudWorldToReference(cameraWorldPos);
	float bottom = FOXY_CLOUD_HEIGHT - CLOUD_COMPOSITE_BASE_VARIATION;
	float top = FOXY_CLOUD_HEIGHT + FOXY_CLOUD_THICKNESS;
	float tNear;
	float tFar;
	CloudCompositeLayerInterval(referenceCameraWorldPos, worldDir, bottom, top, tNear, tFar);
	if (tFar <= tNear) {
		return CloudReferenceDistanceToWorld(CLOUD_COMPOSITE_TRACE_LIMIT);
	}
	float traceLength = tFar - tNear;
	float viewFlatness = 1.0 - abs(worldDir.y);
	float layerWeight = mix(0.43, 0.52, smoothstep(0.55, 0.98, viewFlatness));
	float referenceDistance = clamp(tNear + traceLength * layerWeight, 0.0, CLOUD_COMPOSITE_TRACE_LIMIT);
	return CloudReferenceDistanceToWorld(referenceDistance);
}

vec2 CloudPreviousUv(
	const in vec3 cameraWorldPos,
	const in vec3 worldDir,
	const in float cloudDistance,
	const in float timeDelta,
	out float valid
) {
	valid = 0.0;
	float reprojectionDistance = min(cloudDistance, CLOUD_COMPOSITE_TRACE_LIMIT * 0.982);
	vec3 cloudWorldPos = cameraWorldPos + worldDir * reprojectionDistance;
	cloudWorldPos -= CloudCompositeWindDir() * (FOXY_CLOUD_SPEED * 22.0 * CloudWorldScale() * timeDelta);
	vec3 previousScenePos = cloudWorldPos - cameraPosition;
	previousScenePos += cameraPosition - previousCameraPosition;
	previousScenePos += CloudPreviousViewOffset() - gbufferModelViewInverse[3].xyz;
	vec4 previousView = gbufferPreviousModelView * vec4(previousScenePos, 1.0);
	if (previousView.z > -0.02) {
		return texcoord;
	}
	vec4 previousClip = gbufferPreviousProjection * previousView;
	vec2 previousUv = previousClip.xy / CloudSafeDivisor(previousClip.w) * 0.5 + 0.5;
	if (previousUv.x > 0.001 && previousUv.x < 0.999 && previousUv.y > 0.001 && previousUv.y < 0.999) {
		valid = 1.0;
	}
	return previousUv;
}

vec4 CloudResolveCbr(
	const in vec2 uv,
	out vec4 metaOut
) {
	ivec2 renderSize = CloudRenderSize();
	ivec2 fullPixel = CloudFullPixel(uv);
	float phaseActive = CbrPixelActive(fullPixel, renderSize, frameCounter);
	#if FOXY_CLOUD_DEFER_CURRENT_DECODE == 1
		// Reprojection needs current alpha, but valid inactive phases use
		// history RGB directly. Keep the source encoded until RGB is consumed.
		vec4 currentEncoded = texelFetch(colortex1, CloudClampSourcePixel(CbrCompactPixel(fullPixel)), 0);
		float currentAlpha = Saturate(currentEncoded.a);
	#else
		vec4 currentPoint = CloudReadCurrentPoint(uv);
		float currentAlpha = currentPoint.a;
	#endif

	vec3 viewDir = CloudScreenViewRay(uv);
	vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
	vec3 cloudCameraWorldPos = CloudCameraWorldPos();
	vec4 currentDistanceData = CloudReadCurrentDistance(uv);
	float currentDistanceSupport = smoothstep(0.00004, 0.025, currentAlpha);
	float sourceDistance = Saturate(currentDistanceData.r) * CLOUD_COMPOSITE_TRACE_LIMIT;
	float currentDistance = sourceDistance;
	if (currentDistanceSupport < 1.0) {
		float stableDistance = CloudStableLayerDistance(cloudCameraWorldPos, worldDir);
		currentDistance = mix(stableDistance, sourceDistance, currentDistanceSupport);
	}

	float uvHistoryValid;
	vec2 previousUv = CloudPreviousUv(cloudCameraWorldPos, worldDir, currentDistance, max(frameTime, 0.0), uvHistoryValid);
	vec4 historyMeta = CloudReadHistoryMeta(previousUv);
	float historyFrames = Saturate(historyMeta.r) * CLOUD_CBR_HISTORY_FRAMES;
	float finiteHistory = any(isnan(historyMeta)) || any(isinf(historyMeta)) ? 0.0 : 1.0;
	float frameValid = 1.0 - smoothstep(0.080, 0.220, max(frameTime, 0.0));
	float startupValid = step(1.5, float(frameCounter));
	float hardHistoryValid = uvHistoryValid * step(0.5, historyFrames) * finiteHistory * frameValid * startupValid;

	float historyDistance = Saturate(historyMeta.g) * CLOUD_COMPOSITE_TRACE_LIMIT;
	#if FOXY_CLOUD_DEFER_CURRENT_DECODE == 1
		vec4 resolved;
		float resolvedDistance = currentDistance;
		bool useHistory = false;
		if (hardHistoryValid > 0.5) {
			vec4 history = CloudReadHistory(previousUv);
			if (any(isnan(history)) || any(isinf(history))) {
				hardHistoryValid = 0.0;
			} else {
				useHistory = true;
				if (phaseActive > 0.5) {
					vec4 currentPoint = CloudDecodeHistoryBuffer(currentEncoded);
					resolved = CloudCompositeClamp(mix(currentPoint, history, CLOUD_CBR_ACTIVE_HISTORY_WEIGHT));
					resolvedDistance = mix(currentDistance, historyDistance, CLOUD_CBR_ACTIVE_HISTORY_WEIGHT);
				} else {
					resolved = history;
					resolvedDistance = historyDistance;
				}
			}
		}
		if (!useHistory) {
			resolved = phaseActive < 0.5 ? CloudReadCurrentSpatial(uv) : CloudDecodeHistoryBuffer(currentEncoded);
		}
	#else
	vec4 resolved = currentPoint;
	float resolvedDistance = currentDistance;
	if (hardHistoryValid > 0.5) {
		vec4 history = CloudReadHistory(previousUv);
		if (any(isnan(history)) || any(isinf(history))) {
			hardHistoryValid = 0.0;
			if (phaseActive < 0.5) {
				resolved = CloudReadCurrentSpatial(uv);
			}
		} else {
			if (phaseActive > 0.5) {
				resolved = CloudCompositeClamp(mix(currentPoint, history, CLOUD_CBR_ACTIVE_HISTORY_WEIGHT));
				resolvedDistance = mix(currentDistance, historyDistance, CLOUD_CBR_ACTIVE_HISTORY_WEIGHT);
			} else {
				resolved = history;
				resolvedDistance = historyDistance;
			}
		}
	} else if (phaseActive < 0.5) {
		resolved = CloudReadCurrentSpatial(uv);
	}

	#endif
	resolved = CloudCompositeClamp(resolved);
	float newFrames = hardHistoryValid > 0.5 ? min(historyFrames + 1.0, CLOUD_CBR_HISTORY_FRAMES) : 1.0;
	metaOut = vec4(
		newFrames / CLOUD_CBR_HISTORY_FRAMES,
		Saturate(resolvedDistance / CLOUD_COMPOSITE_TRACE_LIMIT),
		0.0,
		0.0
	);

	return resolved;
}


#endif
