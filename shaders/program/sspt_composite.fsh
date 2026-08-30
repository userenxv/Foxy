#include "/lib/settings.glsl"

layout(rgba16f) readonly uniform image2D img_ptTrace;
layout(rgba16f) readonly uniform image2D img_ptHistoryMetaA;
layout(rgba16f) readonly uniform image2D img_ptHistoryMetaB;
#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 1
	layout(rgba16f) readonly uniform image2D img_ptFilteredA;
#else
	layout(rgba16f) readonly uniform image2D img_ptFiltered;
#endif

#include "/lib/math.glsl"
#include "/lib/rt_denoiser.glsl"
#include "/lib/first_person_depth.glsl"
#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_RAY_MODE != FOXY_RAY_IRC_SSPT
	#include "/lib/contracts/sky_lut.glsl"
	#include "/lib/dimension_sky.glsl"
	#include "/lib/voxel/vrtgi_fallback.glsl"
#endif
#define PT_GBUFFER_READ
#include "/lib/pt_gbuffer.glsl"
#undef PT_GBUFFER_READ

uniform sampler2D colortex0;
uniform sampler2D colortex2;
uniform sampler2D depthtex0;
uniform mat4 gbufferProjection;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
#if FOXY_VOXEL_TRACING == 1
	uniform mat4 gbufferModelViewInverse;
	uniform vec3 cameraPosition;
#endif
#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_RAY_MODE != FOXY_RAY_IRC_SSPT
uniform sampler2D colortex7;
#endif
uniform float viewWidth;
uniform float viewHeight;
uniform int isEyeInWater;
uniform int frameCounter;
uniform vec2 temporalJitter;

#include "/lib/sr.glsl"

varying vec2 texcoord;

ivec2 ssptCompositeRenderSize;
vec2 ssptCompositeRayToRenderScale;
vec2 ssptCompositeViewPixelScale;
vec2 ssptCompositeViewBias;
float ssptCompositeGrazingRelax;

bool SsptCompositeReadsA() {
	return mod(float(frameCounter), 2.0) < 1.0;
}

vec4 SsptCompositeSignal(const in ivec2 pixel) {
	#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 1
		return imageLoad(img_ptFilteredA, pixel);
	#else
		return imageLoad(img_ptFiltered, pixel);
	#endif
}

ivec2 SsptCompositeSignalSize() {
	#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 1
		return SrActiveRaySceneSize(imageSize(img_ptFilteredA));
	#else
		return SrActiveRaySceneSize(imageSize(img_ptFiltered));
	#endif
}

vec4 SsptCompositeMeta(const in ivec2 pixel) {
	if (SsptCompositeReadsA()) return imageLoad(img_ptHistoryMetaA, pixel);
	return imageLoad(img_ptHistoryMetaB, pixel);
}

float SsptCompositeSafeDivisor(const in float value) {
	if (abs(value) < 1.0e-6) return value < 0.0 ? -1.0e-6 : 1.0e-6;
	return value;
}

float SsptCompositeIndirectIntensity() {
	#if FOXY_VOXEL_GI_ACTIVE == 1
		#if FOXY_RAY_MODE == FOXY_RAY_IRC_SSPT

return 8.0;
		#elif FOXY_RAY_MODE == FOXY_RAY_SSPT_VRTGI

			return clamp(FOXY_SSPT_BOUNCE_BRIGHTNESS, 0.0, 15.0);
		#else
		#if defined(FOXY_DIM_END)
			return clamp(FOXY_VOXEL_GI_INTENSITY, 0.0, 3.0) * 8.0;
		#else

		return clamp(FOXY_VOXEL_GI_INTENSITY, 0.0, 3.0) *
			(8.0 * FOXY_VXGI_MASTER_CALIBRATION);
		#endif
		#endif
	#else
		return clamp(FOXY_SSPT_BOUNCE_BRIGHTNESS, 0.0, 15.0);
	#endif
}

#if FOXY_VOXEL_TRACING == 1
float SsptCompositeVrtgiDomainWeight(
	const in vec2 viewUv,
	const in float depthRaw,
	const in vec3 worldGeometricNormal
) {
	vec4 clip = vec4(viewUv * 2.0 - 1.0, depthRaw * 2.0 - 1.0, 1.0);
	vec4 view = gbufferProjectionInverse * clip;
	vec3 viewPosition = view.xyz / SsptCompositeSafeDivisor(view.w);
	vec3 viewNormal = normalize(mat3(gbufferModelView) * worldGeometricNormal);
	float originBias = max(0.025, max(-viewPosition.z, 1.0e-3) * 0.00065);
	vec3 originViewPosition = viewPosition + viewNormal * originBias;
	vec3 originPlayerPosition = (
		gbufferModelViewInverse * vec4(originViewPosition, 1.0)
	).xyz;
	return VrtgiReceiverDomainWeight(originPlayerPosition, cameraPosition);
}

#endif

vec3 SsptCompositeViewPos(const in vec2 viewUv, const in float depthRaw) {
	vec4 clip = vec4(viewUv * 2.0 - 1.0, depthRaw * 2.0 - 1.0, 1.0);
	vec4 view = gbufferProjectionInverse * clip;
	return view.xyz / SsptCompositeSafeDivisor(view.w);
}

vec3 SsptCompositeSampleViewPos(
	const in ivec2 historyPixel,
	const in float primaryOffsetIndex,
	const in float viewDepth
) {
	vec2 fullPixel = vec2(SrRayPrimaryPixelScaled(
		historyPixel,
		ssptCompositeRayToRenderScale,
		ssptCompositeRenderSize,
		int(floor(primaryOffsetIndex + 0.5))
	));
	vec2 viewRay = (fullPixel + vec2(0.5)) *
		ssptCompositeViewPixelScale + ssptCompositeViewBias;
	return vec3(viewRay * viewDepth, -viewDepth);
}

float SsptCompositeThinSurface(const in float surfaceClass) {
	float plant = 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_PLANT));
	float strand = 1.0 - step(0.5, abs(surfaceClass - PT_SURFACE_STRAND));
	return max(plant, strand);
}

float SsptCompositeDiffuseReceiver(const in float surfaceClass) {

	return 1.0 - PtSurfaceIsEmissive(surfaceClass);
}

vec3 SsptCompositeThinViewNormal(const in vec3 viewPosition) {
	float viewLengthSquared = dot(viewPosition, viewPosition);
	if (viewLengthSquared <= 1.0e-6) return vec3(0.0, 0.0, 1.0);
	vec3 viewToCamera = -viewPosition * inversesqrt(viewLengthSquared);
	vec3 strandTangent = normalize(mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0));
	vec3 projectedNormal = viewToCamera - strandTangent * dot(viewToCamera, strandTangent);
	float projectedLengthSquared = dot(projectedNormal, projectedNormal);
	return projectedLengthSquared > 1.0e-6
		? projectedNormal * inversesqrt(projectedLengthSquared)
		: viewToCamera;
}

void SsptCompositeTap(
	const in ivec2 pixel,
	const in ivec2 historySize,
	const in float spatialWeight,
	const in float spatialRadius,
	const in vec3 centerNormal,
	const in vec3 centerViewNormal,
	const in vec3 centerViewPosition,
	const in float centerDepth,
	const in float centerSurfaceClass,
	inout vec3 radianceSum,
	inout float weightSum,
	inout vec3 bestRadiance,
	inout float bestScore,
	inout float bestFound,
	inout float acceptedTapCount
) {
	if (any(lessThan(pixel, ivec2(0))) || any(greaterThanEqual(pixel, historySize))) return;

	vec4 meta = SsptCompositeMeta(pixel);
	if (!RtDenoiserFinite4(meta)) return;
	float markerValid = RtDenoiserMetaValid(meta);
	float ageValid = step(0.5, RtDenoiserMetaAge(meta));
	if (markerValid * ageValid < 0.5) return;
	if (RtDenoiserSurfaceClassWeight(centerSurfaceClass, RtDenoiserMetaSurfaceClass(meta)) < 0.5) return;
	vec3 sampleNormal = PtDecodeOctNormal(meta.xy);
	vec3 sampleViewNormal = normalize(mat3(gbufferModelView) * sampleNormal);
	float sampleDepth = max(meta.z, 1.0e-3);
	vec3 sampleViewPosition = SsptCompositeSampleViewPos(
		pixel,
		RtDenoiserMetaPrimaryOffsetIndex(meta),
		sampleDepth
	);
	vec3 positionDelta = sampleViewPosition - centerViewPosition;
	float thinSurface = SsptCompositeThinSurface(centerSurfaceClass);
	float dynamicSurface = 1.0 - step(
		0.5,
		abs(centerSurfaceClass - PT_SURFACE_DYNAMIC)
	);
	float physicalNormalAlignment = dot(centerNormal, sampleNormal);
	float normalAlignment = physicalNormalAlignment;
	float planeDistance = max(abs(dot(positionDelta, centerViewNormal)), abs(dot(positionDelta, sampleViewNormal)));
	float planeTolerance = (0.020 + max(centerDepth, sampleDepth) * 0.00075 * (1.0 + spatialRadius * 0.30)) * ssptCompositeGrazingRelax;
	float planeWeight = exp2(-planeDistance / max(planeTolerance, 1.0e-4));
	float thinDepthWeight = 0.0;
	if (thinSurface > 0.5) {
		thinDepthWeight = RtDenoiserRelativeDepthWeight(
			centerDepth,
			sampleDepth,
			0.010,
			0.10
		);
		planeWeight = thinDepthWeight;
		float envelopeNormalAlignment = dot(
			SsptCompositeThinViewNormal(centerViewPosition),
			SsptCompositeThinViewNormal(sampleViewPosition)
		);
		normalAlignment = max(physicalNormalAlignment, envelopeNormalAlignment);
	} else if (dynamicSurface > 0.5) {
		float dynamicDepthWeight = RtDenoiserRelativeDepthWeight(
			centerDepth,
			sampleDepth,
			0.025,
			0.18
		);
		planeWeight = dynamicDepthWeight;
	}
	float staticNormalWeight = smoothstep(0.82, 0.975, normalAlignment);
	staticNormalWeight *= staticNormalWeight;
	float dynamicNormalWeight = smoothstep(-0.15, 0.80, normalAlignment);
	float normalWeight = mix(staticNormalWeight, dynamicNormalWeight, dynamicSurface);
	float geometryValid = step(planeDistance, planeTolerance * 5.0);
	float geometryScore = planeDistance / max(planeTolerance, 1.0e-4);
	if (thinSurface > 0.5) {
		geometryValid = step(0.02, thinDepthWeight);
		geometryScore = (1.0 - thinDepthWeight) * 4.0;
	} else if (dynamicSurface > 0.5) {
		geometryValid = step(0.03, planeWeight);
		geometryScore = (1.0 - planeWeight) * 3.0;
	}
	float normalThreshold = mix(0.62, -0.10, dynamicSurface);
	float normalPenalty = mix(5.0, 1.5, dynamicSurface);
	float guideValid = markerValid * ageValid * step(normalThreshold, normalAlignment) * geometryValid;
	float guideScore = geometryScore + max(1.0 - normalAlignment, 0.0) * normalPenalty + spatialRadius * 0.015;
	float weight = spatialWeight * guideValid * normalWeight * planeWeight;
	bool replacesBest = guideValid > 0.5 && guideScore < bestScore;
	if (!replacesBest && weight <= 1.0e-5) return;

	vec4 signal = SsptCompositeSignal(pixel);
	if (!RtDenoiserFinite4(signal)) return;
	vec3 sampleRadiance = max(signal.rgb, vec3(0.0));
	if (replacesBest) {
		bestRadiance = sampleRadiance;
		bestScore = guideScore;
		bestFound = 1.0;
	}

	if (weight <= 1.0e-5) return;
	acceptedTapCount += 1.0;
	radianceSum += sampleRadiance * weight;
	weightSum += weight;
}

void SsptCompositeOwnCellFallback(
	const in ivec2 centerPixel,
	const in ivec2 historySize,
	const in vec3 centerAlbedo,
	const in float centerSurfaceClass,
	inout vec3 bestRadiance,
	inout float bestFound
) {
	if (centerSurfaceClass > 0.5) return;

	ivec2 ownerPixel = SrRayPixelFromRenderPixel(
		centerPixel,
		ssptCompositeRenderSize,
		historySize
	);
	vec4 meta = SsptCompositeMeta(ownerPixel);
	if (!RtDenoiserFinite4(meta)) return;
	float markerValid = RtDenoiserMetaValid(meta);
	float ageValid = step(0.5, RtDenoiserMetaAge(meta));
	if (markerValid * ageValid < 0.5) return;
	if (RtDenoiserSurfaceClassWeight(
		centerSurfaceClass,
		RtDenoiserMetaSurfaceClass(meta)
	) < 0.5) return;

	ivec2 sourcePixel = SrRayPrimaryPixelScaled(
		ownerPixel,
		ssptCompositeRayToRenderScale,
		ssptCompositeRenderSize,
		int(floor(RtDenoiserMetaPrimaryOffsetIndex(meta) + 0.5))
	);
	ivec2 sourceDelta = abs(sourcePixel - centerPixel);
	if (any(greaterThan(sourceDelta, ivec2(1)))) return;

	float sourceDepthRaw = texelFetch(depthtex0, sourcePixel, 0).r;
	PtGbufferSample sourceGbuffer = PtDecodeGbuffer(
		texelFetch(colortex2, sourcePixel, 0),
		sourceDepthRaw
	);
	if (sourceGbuffer.valid < 0.5) return;
	if (RtDenoiserSurfaceClassWeight(centerSurfaceClass, sourceGbuffer.surfaceClass) < 0.5) return;
	if (RtDenoiserMaterialWeight(
		RtDenoiserMaterialSignature(centerAlbedo),
		RtDenoiserMaterialSignature(sourceGbuffer.albedo)
	) < 0.90) return;

	vec4 signal = SsptCompositeSignal(ownerPixel);
	if (!RtDenoiserFinite4(signal)) return;
	bestRadiance = max(signal.rgb, vec3(0.0));
	bestFound = 1.0;
}

void main() {
	ivec2 renderSizeInt = max(ivec2(SrRenderSize()), ivec2(1));
	vec2 renderSize = vec2(renderSizeInt);
	ivec2 centerPixel = clamp(
		ivec2(floor(SrViewUv(texcoord) * renderSize)),
		ivec2(0),
		renderSizeInt - ivec2(1)
	);
	vec4 sceneSample = texelFetch(colortex0, centerPixel, 0);

	if (isEyeInWater == 1) {
		gl_FragData[0] = sceneSample;
		return;
	}

	float centerDepthRaw = texelFetch(depthtex0, centerPixel, 0).r;
	vec4 centerSurface = texelFetch(colortex2, centerPixel, 0);
	PtGbufferSample centerGbuffer = PtDecodeGbuffer(centerSurface, centerDepthRaw);
	if (centerGbuffer.valid < 0.5) {
		gl_FragData[0] = sceneSample;
		return;
	}

	vec2 centerRasterUv = (vec2(centerPixel) + vec2(0.5)) / renderSize;
	vec2 centerViewUv = centerRasterUv;
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		centerViewUv -= temporalJitter * 0.5;
	#endif
	#if FOXY_VOXEL_TRACING == 1
		float vrtgiDomainWeight = SsptCompositeVrtgiDomainWeight(
			centerViewUv,
			centerDepthRaw,
			centerGbuffer.worldNormal
		);
	#endif

	#if FOXY_VOXEL_GI_ACTIVE == 1 && FOXY_IRC_MODE == 1

		ivec2 ircSignalSize = max(SsptCompositeSignalSize(), ivec2(1));
		ivec2 ircSignalPixel = SrRayPixelFromRenderPixel(
			centerPixel,
			renderSizeInt,
			ircSignalSize
		);
		vec4 ircSignal = SsptCompositeSignal(ircSignalPixel);
		float ircWeight = clamp(ircSignal.a, 0.0, 1.0);
		vec3 ircIncoming = max(ircSignal.rgb, vec3(0.0));
		vec3 fallbackSkyFluence = vec3(0.0);
		#if !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
			fallbackSkyFluence = DecodeBufferColor(texelFetch(
				colortex7,
				SkyUpperHemisphereFluenceTexel(),
				0
			).rgb);
		#endif
		vec3 fallbackIncoming = VrtgiReceiverFallbackRadiance(
			centerGbuffer.lightmap,
			centerGbuffer.worldGeometricNormal,
			fallbackSkyFluence
		);
		ircIncoming = mix(fallbackIncoming, ircIncoming, ircWeight);

		vec3 ircSceneColor = DecodeSceneColor(sceneSample.rgb);
		ircSceneColor += ircIncoming * centerGbuffer.albedo *
			SsptCompositeIndirectIntensity();
		gl_FragData[0] = vec4(
			EncodeSceneColor(max(ircSceneColor, vec3(0.0))),
			sceneSample.a
		);
		return;
	#endif

	#if FOXY_SSPT_DENOISER == 0
		ivec2 rawTraceSize = SrActiveRaySceneSize(imageSize(img_ptTrace));
		ivec2 rawTracePixel = SrRayPixelFromRenderPixel(
			centerPixel,
			renderSizeInt,
			rawTraceSize
		);
		vec4 rawTrace = imageLoad(img_ptTrace, rawTracePixel);
		float rawPrimaryValid = step(
			-0.99,
			RtDenoiserTraceState(rawTrace.a)
		);
		vec3 rawIncoming = max(rawTrace.rgb, vec3(0.0)) * rawPrimaryValid;
		#if FOXY_RAY_MODE == FOXY_RAY_VRTGI
			float rawVrtgiWeight = vrtgiDomainWeight * rawPrimaryValid;
			rawIncoming *= rawVrtgiWeight;
		#endif
		float rawBounceBrightness = SsptCompositeIndirectIntensity();
		vec3 rawSceneColor = DecodeSceneColor(sceneSample.rgb);
		float rawDiffuseReceiver = SsptCompositeDiffuseReceiver(centerGbuffer.surfaceClass);
		rawSceneColor += rawIncoming * centerGbuffer.albedo *
			rawBounceBrightness * rawDiffuseReceiver;
		gl_FragData[0] = vec4(EncodeSceneColor(max(rawSceneColor, vec3(0.0))), sceneSample.a);
		return;
	#endif

	ivec2 historySize = max(SsptCompositeSignalSize(), ivec2(1));
	ssptCompositeRenderSize = renderSizeInt;
	ssptCompositeRayToRenderScale = renderSize / vec2(historySize);
	vec2 projectionScale = vec2(
		abs(gbufferProjection[0][0]) > 1.0e-6 ? gbufferProjection[0][0] : 1.0,
		abs(gbufferProjection[1][1]) > 1.0e-6 ? gbufferProjection[1][1] : 1.0
	);
	ssptCompositeViewPixelScale = vec2(2.0) /
		(renderSize * projectionScale);
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		ssptCompositeViewBias = (-vec2(1.0) - temporalJitter) /
			projectionScale;
	#else
		ssptCompositeViewBias = -vec2(1.0) / projectionScale;
	#endif
	float centerDynamicSurface = 1.0 - step(
		0.5,
		abs(centerGbuffer.surfaceClass - PT_SURFACE_DYNAMIC)
	);
	float centerFirstPerson = FirstPersonDepthMask(centerDepthRaw) * centerDynamicSurface;
	float centerProjectionDepthRaw = FirstPersonProjectionDepth(
		centerDepthRaw,
		centerFirstPerson
	);
	vec3 centerViewPosition = SsptCompositeViewPos(centerViewUv, centerProjectionDepthRaw);
	float centerDepth = max(-centerViewPosition.z, 1.0e-3);
	vec3 centerViewNormal = normalize(
		mat3(gbufferModelView) * centerGbuffer.worldGeometricNormal
	);
	ssptCompositeGrazingRelax = mix(
		2.25,
		1.0,
		sqrt(Saturate(abs(centerViewNormal.z)))
	);
	float bounceBrightness = SsptCompositeIndirectIntensity();

	vec2 historyPosition = centerRasterUv * vec2(historySize) - vec2(0.5);
	ivec2 historyBase = ivec2(floor(historyPosition));
	vec2 fractionValue = fract(historyPosition);
	vec3 radianceSum = vec3(0.0);
	float weightSum = 0.0;
	vec3 bestRadiance = vec3(0.0);
	float bestScore = 1.0e20;
	float bestFound = 0.0;
	float acceptedTapCount = 0.0;
	for (int tapIndex = 0; tapIndex < 4; tapIndex++) {
		ivec2 offset = ivec2(tapIndex % 2, tapIndex / 2);
		vec2 axisWeight = mix(vec2(1.0) - fractionValue, fractionValue, vec2(offset));
		SsptCompositeTap(
			historyBase + offset,
			historySize,
			axisWeight.x * axisWeight.y,
			length(vec2(offset) - fractionValue),
			centerGbuffer.worldGeometricNormal,
			centerViewNormal,
			centerViewPosition,
			centerDepth,
			centerGbuffer.surfaceClass,
			radianceSum,
			weightSum,
			bestRadiance,
			bestScore,
			bestFound,
			acceptedTapCount
		);
	}

	if (weightSum < 0.42 || bestFound < 0.5 || acceptedTapCount < 1.5) {
		radianceSum = vec3(0.0);
		weightSum = 0.0;
		bestRadiance = vec3(0.0);
		bestScore = 1.0e20;
		bestFound = 0.0;
		acceptedTapCount = 0.0;
		ivec2 wideCenter = ivec2(floor(historyPosition + vec2(0.5)));

		int fallbackRadius = centerGbuffer.surfaceClass < 0.5 ? 1 : 2;
		for (int offsetY = -2; offsetY <= 2; offsetY++) {
			for (int offsetX = -2; offsetX <= 2; offsetX++) {
				if (abs(offsetX) > fallbackRadius || abs(offsetY) > fallbackRadius) continue;
				ivec2 offset = ivec2(offsetX, offsetY);
				float radiusSquared = float(offsetX * offsetX + offsetY * offsetY);
				float spatialWeight = exp2(-0.42 * radiusSquared);
				SsptCompositeTap(
					wideCenter + offset,
					historySize,
					spatialWeight,
					sqrt(radiusSquared),
					centerGbuffer.worldGeometricNormal,
					centerViewNormal,
					centerViewPosition,
					centerDepth,
					centerGbuffer.surfaceClass,
					radianceSum,
					weightSum,
					bestRadiance,
					bestScore,
					bestFound,
					acceptedTapCount
				);
			}
		}
	}
	if (bestFound < 0.5) {
		SsptCompositeOwnCellFallback(
			centerPixel,
			historySize,
			centerGbuffer.albedo,
			centerGbuffer.surfaceClass,
			bestRadiance,
			bestFound
		);
	}

	vec3 sceneColor = DecodeSceneColor(sceneSample.rgb);
	vec3 indirectDiffuse = vec3(0.0);
	vec3 incomingRadiance = vec3(0.0);
	float incomingValid = bestFound;
	if (bestFound > 0.5) {
		vec3 weightedRadiance = weightSum > 1.0e-5 ? radianceSum / weightSum : bestRadiance;
		float interpolationConfidence = smoothstep(0.24, 0.70, weightSum);
		vec3 tracedIncoming = mix(bestRadiance, weightedRadiance, interpolationConfidence);
		#if FOXY_RAY_MODE == FOXY_RAY_VRTGI
			incomingRadiance = tracedIncoming * vrtgiDomainWeight;
		#else
			incomingRadiance = tracedIncoming;
		#endif
	}
	#if FOXY_VOXEL_GI_ACTIVE == 0

		if (bestFound < 0.5) {
			ivec2 ownerPixel = SrRayPixelFromRenderPixel(
				centerPixel,
				renderSizeInt,
				historySize
			);
			vec4 ownerSignal = SsptCompositeSignal(ownerPixel);
			incomingRadiance = RtDenoiserFinite4(ownerSignal)
				? max(ownerSignal.rgb, vec3(0.0))
				: vec3(0.0);
		}
		float diffuseReceiver = SsptCompositeDiffuseReceiver(centerGbuffer.surfaceClass);
		indirectDiffuse = incomingRadiance * centerGbuffer.albedo *
			bounceBrightness * diffuseReceiver;
	#else
		if (incomingValid > 0.5) {
			float diffuseReceiver = SsptCompositeDiffuseReceiver(centerGbuffer.surfaceClass);
			indirectDiffuse = incomingRadiance * centerGbuffer.albedo *
				bounceBrightness * diffuseReceiver;
		}
		#if FOXY_RAY_MODE == FOXY_RAY_SSPT_VRTGI

if (incomingValid < 0.5) {
				vec3 fallbackSkyFluence = vec3(0.0);
				#if !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
					fallbackSkyFluence = DecodeBufferColor(texelFetch(
						colortex7,
						SkyUpperHemisphereFluenceTexel(),
						0
					).rgb);
				#endif
				vec3 fallbackIncoming = VrtgiReceiverFallbackRadiance(
					centerGbuffer.lightmap,
					centerGbuffer.worldGeometricNormal,
					fallbackSkyFluence
				);
				float diffuseReceiver = SsptCompositeDiffuseReceiver(centerGbuffer.surfaceClass);
				indirectDiffuse += fallbackIncoming * centerGbuffer.albedo *
					bounceBrightness * diffuseReceiver;
			}
		#endif
	#endif

	indirectDiffuse = min(max(indirectDiffuse, vec3(0.0)), vec3(32.0));
	sceneColor += indirectDiffuse;
	gl_FragData[0] = vec4(EncodeSceneColor(max(sceneColor, vec3(0.0))), sceneSample.a);
}
