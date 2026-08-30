#ifndef FOXY_MATERIAL_REFLECTION_GLSL
#define FOXY_MATERIAL_REFLECTION_GLSL

#if FOXY_MATERIAL_REFLECTIONS == 1
#include "/features/material/reflection_policy.glsl"
#include "/lib/contracts/backend.glsl"

vec3 MaterialRoughReflectionDirection(
	const in vec3 incidentView,
	const in vec3 normalView,
	const in float roughness
) {
	// Technique: Dupuy and Benyoub, "Sampling Visible GGX Normals with Spherical Caps," HPG 2023.
	// Source: https://arxiv.org/abs/2306.05044
	float alpha = clamp(roughness, 0.002, 1.0);
	if (alpha <= 0.006) return normalize(reflect(incidentView, normalView));

	vec3 viewDirection = -incidentView;
	vec3 tangent = abs(normalView.z) < 0.999
		? normalize(cross(vec3(0.0, 0.0, 1.0), normalView))
		: vec3(1.0, 0.0, 0.0);
	vec3 bitangent = cross(normalView, tangent);
	float viewNoV = dot(viewDirection, normalView);
	if (viewNoV <= 1.0e-4) return normalize(reflect(incidentView, normalView));
	vec3 localView = vec3(
		dot(viewDirection, tangent),
		dot(viewDirection, bitangent),
		viewNoV
	);

	vec2 pixel = floor(gl_FragCoord.xy);
	float sampleEpoch = float(frameCounter);
	vec2 pixelRotation = vec2(
		Hash12(pixel + vec2(11.0, 37.0)),
		Hash12(pixel.yx + vec2(53.0, 79.0))
	);
	vec2 randomSample = fract(pixelRotation + sampleEpoch * vec2(0.61803399, 0.75487766));
	randomSample = clamp(randomSample, vec2(1.0e-4), vec2(0.9999));

	vec3 stretchedView = normalize(vec3(alpha * localView.xy, localView.z));
	float capCosine = 1.0 - (1.0 + stretchedView.z) * clamp(randomSample.y, 0.0, 1.0);
	float capSine = sqrt(max(1.0 - capCosine * capCosine, 0.0));
	float capAngle = 2.0 * PI * randomSample.x;
	vec3 stretchedHalf = vec3(
		cos(capAngle) * capSine,
		sin(capAngle) * capSine,
		capCosine
	) + stretchedView;
	stretchedHalf = normalize(stretchedHalf);
	vec3 localHalf = normalize(vec3(alpha * stretchedHalf.xy, stretchedHalf.z));
	vec3 halfVector = normalize(
		tangent * localHalf.x + bitangent * localHalf.y + normalView * localHalf.z
	);
	vec3 sampledDirection = normalize(reflect(incidentView, halfVector));
	return dot(sampledDirection, normalView) > 1.0e-4
		? sampledDirection
		: normalize(reflect(incidentView, normalView));
}

struct MaterialReflectionTrace {
	vec2 sampleUv;
	float hitCoverage;
	float hit;
	float skyVisible;
};

MaterialReflectionTrace TraceMaterialReflection(const in vec3 viewPos, const in vec3 reflectedDir, const in int traceSteps) {
	MaterialReflectionTrace trace;
	trace.sampleUv = texcoord;
	trace.hitCoverage = 0.0;
	trace.hit = 0.0;
	trace.skyVisible = 0.0;
	vec3 startView = viewPos + reflectedDir * 0.08;
	float rayLength = clamp(max(-viewPos.z * 1.6, 18.0), 18.0, 96.0);
	if (reflectedDir.z > 0.0001) {
		float nearLimit = (-near - startView.z) / reflectedDir.z;
		if (nearLimit <= 0.01) return trace;
		rayLength = min(rayLength, nearLimit * 0.98);
	}
	vec3 endView = startView + reflectedDir * rayLength;
	vec4 startProjected = ProjectViewPos(startView);
	vec4 endProjected = ProjectViewPos(endView);
	if (startProjected.w <= 0.0 || endProjected.w <= 0.0) {
		return trace;
	}

	vec2 screenDelta = endProjected.xy - startProjected.xy;
	float startK = 1.0 / SafeDivisor(startProjected.w);
	float endK = 1.0 / SafeDivisor(endProjected.w);
	vec2 startQzAndK = vec2(startView.z * startK, startK);
	vec2 endQzAndK = vec2(endView.z * endK, endK);
	float jitter = 0.35 + Hash12(floor(gl_FragCoord.xy)) * 0.45;
	float screenSpan = length(screenDelta * vec2(viewWidth, viewHeight));
	int adaptiveSteps = clamp(
		int(ceil(screenSpan / 12.0)),
		traceSteps,
		FOXY_MATERIAL_REFLECTION_STEPS
	);
	float previousT = 0.0;
	float previousValidT = 0.0;
	float previousDelta = -1.0e20;
	float previousValid = 0.0;

	for (int i = 0; i < FOXY_MATERIAL_REFLECTION_STEPS; i++) {
		if (i >= adaptiveSteps) break;
		float t = (float(i) + jitter) / float(adaptiveSteps);
		vec2 rawUv = startProjected.xy + screenDelta * t;
		if (rawUv.x <= 0.001 || rawUv.x >= 0.999 || rawUv.y <= 0.001 || rawUv.y >= 0.999) break;
		vec2 uv = PixelCenter(rawUv);
		vec2 sampleUv = WaterCurrentRenderUv(uv);
		float sampleValid;
		float sceneDepth = WaterSceneLinearDepth(uv, sampleUv, sampleValid);
		trace.skyVisible = max(trace.skyVisible, 1.0 - sampleValid);
		if (sampleValid > 0.5) {
			float rayDepth = TraceViewDepth(t, startQzAndK, endQzAndK);
			float previousRayDepth = TraceViewDepth(previousT, startQzAndK, endQzAndK);
			float thickness = clamp(sceneDepth * 0.012 + abs(rayDepth - previousRayDepth) * 1.5, 0.12, 2.2);
			float delta = rayDepth - sceneDepth;
			bool crossedSurface = previousValid > 0.5 && previousDelta < 0.0 && delta >= 0.0;
			bool nearSurface = abs(delta) <= thickness * 0.16;
			if ((crossedSurface || nearSurface) && delta >= -thickness * 0.10 && delta <= thickness * 0.65) {

				float refinedT = t;
				float crossingDenominator = delta - previousDelta;
				if (previousValid > 0.5 && previousDelta < 0.0 && delta >= 0.0 && abs(crossingDenominator) > 1.0e-5) {
					float refineLow = previousValidT;
					float refineHigh = t;
					for (int refine = 0; refine < 3; ++refine) {
						float refineMid = (refineLow + refineHigh) * 0.5;
						vec2 refineUv = PixelCenter(startProjected.xy + screenDelta * refineMid);
						vec2 refineSampleUv = WaterCurrentRenderUv(refineUv);
						float refineValid;
						float refineDepth = WaterSceneLinearDepth(refineUv, refineSampleUv, refineValid);
						float refineRayDepth = TraceViewDepth(refineMid, startQzAndK, endQzAndK);
						if (refineValid > 0.5 && refineRayDepth - refineDepth >= 0.0) refineHigh = refineMid;
						else refineLow = refineMid;
					}
					refinedT = refineHigh;
				}
				vec2 refinedUv = PixelCenter(startProjected.xy + screenDelta * refinedT);
				trace.sampleUv = refinedUv;
				trace.hitCoverage = ScreenEdgeFade(refinedUv);
				trace.hit = 1.0;
				return trace;
			}
			previousDelta = delta;
			previousValidT = t;
			previousValid = 1.0;
		}
		previousT = t;
	}
	return trace;
}

#if FOXY_MATERIAL_REFLECTION_GLOBAL == 1 && FOXY_VOXEL_GI_ACTIVE == 1

vec4 TraceGlobalMaterialReflection(
	const in vec3 viewPos,
	const in vec3 worldNormal,
	const in vec3 reflectedWorldDir
) {
	vec3 originPlayerPos = (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
	vec3 voxelRayOrigin = VoxelGridSceneToGrid(
		originPlayerPos,
		cameraPosition
	) + worldNormal * 0.020 + reflectedWorldDir * 0.035;

	uint hitPayload;
	float hitDistance;
	ivec3 hitCell;
	vec3 hitNormal;
	vec3 sphereRadiance;
	vec3 rayTransmittance;
	int traceResult = VoxelGiTrace(
		voxelRayOrigin,
		reflectedWorldDir,
		min(FOXY_VOXEL_GI_MAX_DISTANCE, 48.0),
		min(FOXY_VOXEL_GI_TRACE_ITERATIONS, 48),
		true,
		hitPayload,
		hitDistance,
		hitCell,
		hitNormal,
		sphereRadiance,
		rayTransmittance
	);

	vec3 reflectedRadiance = sphereRadiance;
	float resolved = max(max(sphereRadiance.r, sphereRadiance.g), sphereRadiance.b) > 1.0e-5
		? 1.0
		: 0.0;
	if (traceResult == FOXY_VOXEL_GI_TRACE_SURFACE_HIT) {

		vec3 neutralSkyMeanRadiance = vec3(0.0);
		vec3 directLightView = normalize(shadowLightPosition);
		vec3 directLightWorldDirection = normalize(
			mat3(gbufferModelViewInverse) * directLightView
		);
		float directLightCosine = max(
			dot(hitNormal, directLightWorldDirection),
			0.0
		);
		float directLightAltitude = dot(
			 directLightView,
			normalize(upPosition)
		);
		float directLightVisibility = 0.0;
		float hitSkyLight = VoxelSkyLight(hitPayload);
		vec3 directLightRadiance = vec3(0.0);
		#if defined(FOXY_DIM_END)
			directLightWorldDirection = EndSunWorldDirection();
			directLightCosine = max(dot(hitNormal, directLightWorldDirection), 0.0);
			directLightVisibility = directLightCosine > 0.001 ? 1.0 : 0.0;
			directLightRadiance = vec3(0.62, 0.72, 1.00);
		#else
			if (
				directLightAltitude > 0.001 &&
				directLightCosine > 0.001 &&
				hitSkyLight > 0.0001
			) {
				vec3 hitPosition = voxelRayOrigin + reflectedWorldDir * hitDistance;
				directLightRadiance = DecodeSkyLutColor(texelFetch(
					colortex7,
					SkyDirectSunColorTexel(),
					0
				).rgb);
				directLightVisibility = VoxelGiDirectVisibility(
					hitPosition,
					hitNormal,
					directLightCosine
				);
			}
		#endif
		vec3 hitRadiance = VoxelGiHitRadiance(
			hitPayload,
			VoxelGiAlbedo(hitPayload),
			hitNormal,
			hitSkyLight,
			neutralSkyMeanRadiance,
			directLightRadiance,
			directLightCosine,
			directLightVisibility,
			true,
			1.0,
			1.0
		);
		reflectedRadiance += rayTransmittance * hitRadiance;
		resolved = 1.0;
	} else if (
		traceResult == FOXY_VOXEL_GI_TRACE_DOMAIN_EXIT ||
		traceResult == FOXY_VOXEL_GI_TRACE_DISTANCE_LIMIT
	) {
		float skyTerminal = smoothstep(-0.08, 0.12, reflectedWorldDir.y);
		#if !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
			if (skyTerminal > 0.0) {
				reflectedRadiance += rayTransmittance * DecodeSkyLutColor(
					texture2D(colortex7, SsptSkyLutUv(reflectedWorldDir)).rgb
				) * (FOXY_VOXEL_GI_SKY_BRIGHTNESS * skyTerminal);
				resolved = max(resolved, skyTerminal);
			}
		#endif
	}
	return vec4(max(reflectedRadiance, vec3(0.0)), resolved);
}
#endif

vec4 TraceMaterialReflectionSignal(
	const in vec3 sceneColor,
	const in vec2 viewUv,
	const in vec2 renderUv,
	const in vec4 packedSurface
) {
	BackendOpaqueSurface opaqueSurface = BackendResolveOpaqueSurface(
		viewUv,
		renderUv,
		texture2D(depthtex1, renderUv).r,
		gbufferProjectionInverse
	);
	float depthRaw = opaqueSurface.rawDepth;
	PtGbufferSample material = PtDecodeGbuffer(packedSurface, depthRaw);
	if (material.valid < 0.5) return vec4(0.0);

	float perceptualRoughness = sqrt(Saturate(material.roughness));
	float smoothness = MaterialReflectionSmoothness(perceptualRoughness);
	if (MaterialReflectionSurfaceEnabled(
		material.valid,
		material.surfaceClass,
		perceptualRoughness,
		material.metalness
	) < 0.5) return vec4(0.0);

	vec3 viewPos = opaqueSurface.viewPosition;
	vec3 incidentView = normalize(viewPos);
	mat3 viewToWorld = mat3(gbufferModelViewInverse);
	vec3 normalView = normalize(vec3(
		dot(viewToWorld[0], material.worldNormal),
		dot(viewToWorld[1], material.worldNormal),
		dot(viewToWorld[2], material.worldNormal)
	));
	vec3 geometricNormalView = normalize(vec3(
		dot(viewToWorld[0], material.worldGeometricNormal),
		dot(viewToWorld[1], material.worldGeometricNormal),
		dot(viewToWorld[2], material.worldGeometricNormal)
	));
	if (dot(geometricNormalView, -incidentView) < 0.0) {
		geometricNormalView = -geometricNormalView;
	}
	normalView = PbrVisibleNormal(
		normalView,
		geometricNormalView,
		-incidentView
	);
	vec3 sampledDirection = MaterialRoughReflectionDirection(
		incidentView,
		normalView,
		material.roughness
	);
	vec3 reflectedDir = MaterialReflectionAboveSurface(
		sampledDirection,
		geometricNormalView
	);
	vec3 reflectedWorldDir = normalize(mat3(gbufferModelViewInverse) * reflectedDir);
	vec3 reflectionWorldNormal = normalize(mat3(gbufferModelViewInverse) * normalView);
	int traceSteps = FOXY_MATERIAL_REFLECTION_STEPS;
	#if FOXY_MATERIAL_REFLECTION_HIGH_QUALITY == 0
		traceSteps = min(traceSteps, 8);
	#endif
	MaterialReflectionTrace hit = TraceMaterialReflection(viewPos, reflectedDir, traceSteps);

	float skyAccess = smoothstep(0.22, 0.82, material.lightmap.y);
	skyAccess *= skyAccess;
	float skyWeight = smoothstep(-0.08, 0.12, reflectedWorldDir.y) * skyAccess * hit.skyVisible;
	vec3 localFallback = sceneColor * mix(0.055, 0.12, skyAccess);
	vec3 fallback = localFallback;
	if (skyWeight > 0.0) {
		vec3 skyReflection = DecodeSkyLutColor(texture2D(
			colortex7,
			SkyViewLutUv(reflectedWorldDir)
		).rgb);
		fallback = mix(localFallback, skyReflection, skyWeight);
	}
	vec3 reflectedColor = fallback;
	float reflectionConfidence = 0.12 * skyWeight;
	if (hit.hit > 0.5) {
		vec3 screenReflection = max(ReflectionSample(hit.sampleUv), vec3(0.0));
		reflectedColor = mix(fallback, screenReflection, hit.hitCoverage);
		reflectionConfidence = hit.hitCoverage;
	}
	#if FOXY_MATERIAL_REFLECTION_GLOBAL == 1 && FOXY_VOXEL_GI_ACTIVE == 1
	else {
		float NoV = max(dot(normalView, -incidentView), 0.0);
		vec3 metalF0 = clamp(material.albedo * 1.12 + vec3(0.06), vec3(0.12), vec3(0.96));
		float f0Energy = max(
			mix(
				max(FOXY_PBR_FALLBACK_F0, 0.02),
				max(metalF0.r, max(metalF0.g, metalF0.b)),
				material.metalness
			),
			0.0
		);
		if (MaterialReflectionGlobalEnabled(smoothness, f0Energy, NoV) > 0.5) {
			vec4 globalReflection = TraceGlobalMaterialReflection(
				viewPos,
				reflectionWorldNormal,
				reflectedWorldDir
			);
			reflectedColor = mix(fallback, globalReflection.rgb, globalReflection.a);
			reflectionConfidence = max(reflectionConfidence, globalReflection.a);
		}
	}
	#endif
	return vec4(max(reflectedColor, vec3(0.0)), clamp(reflectionConfidence, 0.0, 1.0));
}

#endif

#endif
