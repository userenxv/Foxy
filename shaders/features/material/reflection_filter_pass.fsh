#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/features/material/reflection_policy.glsl"

uniform float viewWidth;
uniform float viewHeight;

#include "/lib/sr.glsl"
#include "/lib/contracts/backend.glsl"
#include "/lib/contracts/material.glsl"

uniform sampler2D colortex2;
uniform sampler2D depthtex1;
uniform sampler2D depthtex0;
#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 0 || FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1
	uniform sampler2D colortex14;
#elif FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 2
	uniform sampler2D colortex14;
#else
	uniform sampler2D colortex0;
	uniform sampler2D colortex11;
	uniform sampler2D colortex15;
#endif
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 3
	uniform mat4 gbufferPreviousProjection;
	uniform mat4 gbufferPreviousModelView;
	uniform vec3 cameraPosition;
	uniform vec3 previousCameraPosition;
#endif
uniform int frameCounter;
uniform vec2 temporalJitter;
#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 3
	uniform vec2 previousTemporalJitter;
#endif

varying vec2 texcoord;

#define PT_GBUFFER_READ
#include "/lib/pt_gbuffer.glsl"
#undef PT_GBUFFER_READ

#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 3
	#include "/features/reflection/temporal.glsl"
#endif

struct MaterialReflectionGuide {
	vec3 worldNormal;
	vec3 worldGeometricNormal;
	float surfaceClass;
	float perceptualRoughness;
	float metalness;
	float reflectionType;
	float valid;
};

vec3 MaterialReflectionDecodeGeometricNormal(const in float encodedValue) {
	float metadataBits = floor(Saturate(encodedValue) * 65535.0 + 0.5);
	float geometryY = floor(metadataBits * (1.0 / 4096.0));
	metadataBits -= geometryY * 4096.0;
	float geometryX = floor(metadataBits * (1.0 / 256.0));
	vec2 signedOct = (vec2(geometryX, geometryY) - 7.0) * (1.0 / 7.0);
	return PtDecodeOctNormal(signedOct * 0.5 + 0.5);
}

MaterialReflectionGuide DecodeMaterialReflectionGuide(
	const in vec4 surfaceData,
	const in float depthRaw
) {
	MaterialReflectionGuide guide;
	float waterSurface = MaterialIsWater(surfaceData);
	float glassSurface = MaterialIsGlass(surfaceData);
	float transparentSurface = max(waterSurface, glassSurface);
	vec2 albedoBFlags = PtUnpackUnorm2x8(surfaceData.y);
	float materialBits = floor(albedoBFlags.y * 255.0 + 0.5);
	float metalness = step(128.0, materialBits) * (1.0 - transparentSurface);
	guide.metalness = metalness;
	materialBits -= metalness * 128.0;
	float roughnessBits = floor(materialBits * (1.0 / 8.0));
	guide.surfaceClass = (materialBits - roughnessBits * 8.0) * (1.0 - transparentSurface);
	guide.perceptualRoughness = roughnessBits * (1.0 / 15.0);
	guide.worldNormal = PtDecodeOctNormal(PtUnpackUnorm2x8(surfaceData.z));
	guide.worldGeometricNormal = MaterialReflectionDecodeGeometricNormal(surfaceData.a);
	guide.reflectionType = MaterialReflectionType(guide.perceptualRoughness);
	guide.valid = (1.0 - step(0.99999, depthRaw)) * (1.0 - transparentSurface);
	if (glassSurface > 0.5) {
		vec3 glassNormalView = MaterialGlassNormal(surfaceData);
		guide.worldNormal = normalize(mat3(gbufferModelViewInverse) * glassNormalView);
		guide.worldGeometricNormal = guide.worldNormal;
		guide.perceptualRoughness = 0.0;
		guide.metalness = 0.0;
		guide.surfaceClass = 0.0;
		guide.reflectionType = FOXY_REFLECTION_TYPE_SMOOTH;
		guide.valid = 1.0 - step(0.99999, depthRaw);
	}
	return guide;
}

vec2 MaterialReflectionViewUv(const in vec2 rasterUv) {
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return rasterUv - temporalJitter * 0.5;
	#else
		return rasterUv;
	#endif
}

vec2 MaterialReflectionRenderUv(const in vec2 rasterUv) {
	return SrSceneSampleUv(rasterUv);
}

vec2 MaterialReflectionPayloadUv(const in vec2 rasterUv) {
	return SrSceneResourcePixelCenter(rasterUv);
}

BackendOpaqueSurface MaterialReflectionOpaqueSurface(
	const in vec2 rasterUv
) {
	vec2 viewUv = MaterialReflectionViewUv(rasterUv);
	vec2 renderUv = MaterialReflectionRenderUv(rasterUv);
	vec4 packet = texture2D(colortex2, MaterialReflectionPayloadUv(rasterUv));
	float glassSurface = MaterialIsGlass(packet);
	float mainRawDepth = glassSurface > 0.5
		? texture2D(depthtex0, renderUv).r
		: texture2D(depthtex1, renderUv).r;
	return BackendResolveOpaqueSurface(
		viewUv,
		renderUv,
		mainRawDepth,
		gbufferProjectionInverse
	);
}

vec4 MaterialReflectionFilterSource(const in vec2 uv) {
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 0 || FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1 || FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 2
		return texture2D(colortex14, uv);
	#else
		return texture2D(colortex0, uv);
	#endif
}

vec3 MaterialReflectionPowerEncode(const in vec3 color, const in float exponentValue) {
	vec3 safeColor = max(color, vec3(0.0));
	float magnitude = length(safeColor);
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER > 0
		return safeColor * inversesqrt(max(magnitude, 1.0e-8));
	#else
	return normalize(safeColor + vec3(1.0e-8)) * pow(magnitude, exponentValue);
	#endif
}

vec3 MaterialReflectionPowerDecode(const in vec3 color, const in float exponentValue) {
	vec3 safeColor = max(color, vec3(0.0));
	float magnitude = length(safeColor);
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER > 0
		return safeColor * magnitude;
	#else
	return normalize(safeColor + vec3(1.0e-8)) * pow(magnitude, 1.0 / exponentValue);
	#endif
}

float MaterialReflectionSurfaceEnabled(const in MaterialReflectionGuide material) {
	return MaterialReflectionSurfaceEnabled(
		material.valid,
		material.surfaceClass,
		material.perceptualRoughness,
		material.metalness
	);
}

float MaterialReflectionGeometricNormalWeight(
	const in float normalDot,
	const in float perceptualRoughness
) {
	float roughFactor = smoothstep(0.08, 0.72, perceptualRoughness);
	float variance = mix(0.012, 0.085, roughFactor);
	return exp2(-max(1.0 - normalDot, 0.0) / variance);
}

float MaterialReflectionShadingNormalWeight(
	const in float normalDot,
	const in float perceptualRoughness
) {
	float roughFactor = smoothstep(0.08, 0.72, perceptualRoughness);
	float variance = mix(0.025, 0.22, roughFactor);
	return exp2(-max(1.0 - normalDot, 0.0) / variance);
}

#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1 || FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 2

vec4 FilterMaterialReflectionCross(
	const in vec2 centerRasterUv,
	const in MaterialReflectionGuide centerMaterial,
	const in float centerLinearDepth,
	const in vec3 centerViewPosition
) {
	vec4 centerSignal = MaterialReflectionFilterSource(centerRasterUv);
	if (centerMaterial.perceptualRoughness <= 0.085) return centerSignal;
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1 || FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 2
		vec2 sourceSize = vec2(textureSize(colortex14, 0));
	#else
		vec2 sourceSize = vec2(textureSize(colortex0, 0));
	#endif
	vec2 filterAxisX = vec2(0.5, 0.0);
	vec2 filterAxisY = vec2(0.0, 0.5);
	float perceptualRoughness = centerMaterial.perceptualRoughness;

	const vec2 lobeRotations[4] = vec2[4](
		vec2(1.0, 0.0),
		vec2(0.70710678, 0.70710678),
		vec2(0.0, 1.0),
		vec2(-0.70710678, 0.70710678)
	);

	vec2 lobeRotation = vec2(1.0, 0.0);
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1
		lobeRotation = lobeRotations[frameCounter & 3];
	#endif
	vec2 lobeAxisX = filterAxisX * lobeRotation.x + filterAxisY * lobeRotation.y;
	vec2 lobeAxisY = filterAxisY * lobeRotation.x - filterAxisX * lobeRotation.y;
	float roughSpread = min(perceptualRoughness * perceptualRoughness * 20.0, 1.10);
	float radius;
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1
		radius = 30.0 * 1.35 * roughSpread;
	#else
		radius = 15.0 * 1.35 * roughSpread;
	#endif

	vec3 signalSum = vec3(0.0);
	float weightSum = 0.0;
	for (int i = 0; i < 5; ++i) {
		vec2 tapOffset = vec2(0.0);
		if (i == 1) tapOffset = lobeAxisX;
		else if (i == 2) tapOffset = -lobeAxisX;
		else if (i == 3) tapOffset = lobeAxisY;
		else if (i == 4) tapOffset = -lobeAxisY;
		vec2 sampleRasterUv = clamp(
			centerRasterUv + tapOffset * (radius / sourceSize),
			vec2(0.001), vec2(0.999)
		);
		MaterialReflectionGuide sampleMaterial;
		vec4 sampleSignal;
		float sampleLinearDepth;
		if (i == 0) {
			sampleMaterial = centerMaterial;
			sampleSignal = centerSignal;
			sampleLinearDepth = centerLinearDepth;
		} else {
			BackendOpaqueSurface sampleSurface = MaterialReflectionOpaqueSurface(sampleRasterUv);
			float sampleDepthRaw = sampleSurface.rawDepth;
			vec4 samplePacket = texture2D(colortex2, MaterialReflectionPayloadUv(sampleRasterUv));
			sampleMaterial = DecodeMaterialReflectionGuide(samplePacket, sampleDepthRaw);
			sampleSignal = MaterialReflectionFilterSource(sampleRasterUv);
			sampleLinearDepth = max(-sampleSurface.viewPosition.z, 0.0);
		}
		float signalValid = step(1.0e-7, max(sampleSignal.r, max(sampleSignal.g, sampleSignal.b)));
		float weight = signalValid * MaterialReflectionSurfaceEnabled(sampleMaterial);
		weight *= i == 0 ? 1.0 : 0.72;
		weight *= MaterialReflectionGeometricNormalWeight(
			max(dot(centerMaterial.worldGeometricNormal, sampleMaterial.worldGeometricNormal), 0.0),
			perceptualRoughness
		);
		weight *= MaterialReflectionShadingNormalWeight(
			max(dot(centerMaterial.worldNormal, sampleMaterial.worldNormal), 0.0),
			perceptualRoughness
		);
		weight *= exp2(-32.0 * abs(sampleLinearDepth - centerLinearDepth) / max(centerLinearDepth, 0.5));
		weight *= exp2(-24.0 * abs(sampleMaterial.perceptualRoughness - perceptualRoughness));
		signalSum += MaterialReflectionPowerEncode(sampleSignal.rgb, 0.5) * weight;
		weightSum += weight;
	}
	if (weightSum < 1.0e-5) return centerSignal;
	return vec4(MaterialReflectionPowerDecode(signalSum / weightSum, 0.5), 1.0);
}
#endif

vec4 FilterMaterialReflection(
	const in vec2 centerRasterUv,
	const in MaterialReflectionGuide centerMaterial,
	const in float centerLinearDepth,
	const in vec3 centerViewPosition,
	out vec3 temporalLowerBound,
	out vec3 temporalUpperBound
) {
	vec4 centerSignal = MaterialReflectionFilterSource(centerRasterUv);
	temporalLowerBound = vec3(0.0);
	temporalUpperBound = vec3(65504.0);
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 3
		if (centerMaterial.reflectionType < 1.5) return centerSignal;
		vec3 encodedCurrent = ReflectionTemporalEncodeColor(centerSignal.rgb);
		temporalLowerBound = max(encodedCurrent - vec3(1.25), vec3(0.0));
		temporalUpperBound = encodedCurrent + vec3(1.25);
		return centerSignal;
	#endif
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 0
		return centerSignal;
	#endif
	if (centerMaterial.reflectionType < 1.5) return centerSignal;

	const vec2 offsets[9] = vec2[9](
		vec2(-1.0, -1.0), vec2(0.0, -1.0), vec2(1.0, -1.0),
		vec2(-1.0,  0.0), vec2(0.0,  0.0), vec2(1.0,  0.0),
		vec2(-1.0,  1.0), vec2(0.0,  1.0), vec2(1.0,  1.0)
	);
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 0 || FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1 || FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 2
		vec2 sourceSize = vec2(textureSize(colortex14, 0));
	#else
		vec2 sourceSize = vec2(textureSize(colortex0, 0));
	#endif
	float perceptualRoughness = centerMaterial.perceptualRoughness;
	float compression = FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 0
		? mix(0.90, 0.80, smoothstep(0.28, 0.58, perceptualRoughness))
		: 0.50;
	vec2 filterAxisX = vec2(1.0, 0.0);
	vec2 filterAxisY = vec2(0.0, 1.0);
	float filterRadius = 0.0;
	vec2 tapJitter = vec2(0.0);
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER > 0
		filterAxisX = vec2(1.0, 0.0);
		filterAxisY = vec2(0.0, 1.0);
		vec2 jitterSeed = floor(gl_FragCoord.xy) + vec2(
			float(frameCounter) * 0.75487765 + 17.0,
			float(frameCounter) * 0.56984026 + 43.0
		);
		tapJitter = vec2(
			Hash12(jitterSeed),
			Hash12(jitterSeed.yx + vec2(29.0, 71.0) + float(FOXY_MATERIAL_REFLECTION_FILTER_ORDER) * vec2(13.0, 31.0))
		) - vec2(0.5);
		float roughSpread = min(perceptualRoughness * perceptualRoughness * 20.0, 1.10);
		#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1
			filterRadius = 6.0 * roughSpread;
		#elif FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 2
			filterRadius = 12.0 * roughSpread;
		#else
			filterRadius = 10.0 * 1.35 * roughSpread;
			vec2 temporalSeed = floor(gl_FragCoord.xy) + vec2(
				float(frameCounter) * 0.75487765,
				float(frameCounter) * 0.56984026
			);
			tapJitter = vec2(
				Hash12(temporalSeed),
				Hash12(temporalSeed + vec2(37.0, 17.0))
			) - vec2(0.5);
		#endif
	#endif
	vec3 signalSum = vec3(0.0);
	float weightSum = 0.0;
	float neighborSupport = 0.0;

	for (int i = 0; i < 9; ++i) {
		vec2 sampleRasterUv;
		float spatialWeight;
		vec2 pixelSize = 1.0 / sourceSize;
		vec2 filterOffset = offsets[i] + tapJitter * 0.35;
		filterOffset = filterOffset.x * filterAxisX + filterOffset.y * filterAxisY;
		sampleRasterUv = clamp(centerRasterUv + filterOffset * pixelSize * filterRadius, vec2(0.001), vec2(0.999));
		spatialWeight = 1.0;

		MaterialReflectionGuide sampleMaterial;
		vec4 sampleSignal;
		float sampleLinearDepth;
		#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 1 || FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 2
			if (i == 4) {
				sampleMaterial = centerMaterial;
				sampleSignal = centerSignal;
				sampleLinearDepth = centerLinearDepth;
			} else {
				BackendOpaqueSurface sampleSurface = MaterialReflectionOpaqueSurface(sampleRasterUv);
				float sampleDepthRaw = sampleSurface.rawDepth;
				vec4 samplePacket = texture2D(colortex2, MaterialReflectionPayloadUv(sampleRasterUv));
				sampleMaterial = DecodeMaterialReflectionGuide(samplePacket, sampleDepthRaw);
				sampleSignal = MaterialReflectionFilterSource(sampleRasterUv);
				sampleLinearDepth = max(-sampleSurface.viewPosition.z, 0.0);
			}
		#else
			BackendOpaqueSurface sampleSurface = MaterialReflectionOpaqueSurface(sampleRasterUv);
			float sampleDepthRaw = sampleSurface.rawDepth;
			vec4 samplePacket = texture2D(colortex2, MaterialReflectionPayloadUv(sampleRasterUv));
			sampleMaterial = DecodeMaterialReflectionGuide(samplePacket, sampleDepthRaw);
			sampleSignal = MaterialReflectionFilterSource(sampleRasterUv);
			sampleLinearDepth = max(-sampleSurface.viewPosition.z, 0.0);
		#endif

		float signalValid = step(0.01, sampleSignal.a) * sampleSignal.a;
		#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER > 0
			float gaussian = exp2(-0.5 * dot(offsets[i], offsets[i]) / 1.80);
			spatialWeight *= gaussian;
		#endif
		float surfaceWeight = MaterialReflectionSurfaceEnabled(sampleMaterial);
		float weight = spatialWeight * signalValid * surfaceWeight;
		float geometricWeight = MaterialReflectionGeometricNormalWeight(
			max(dot(centerMaterial.worldGeometricNormal, sampleMaterial.worldGeometricNormal), 0.0),
			perceptualRoughness
		);
		weight *= geometricWeight;
		float shadingWeight = MaterialReflectionShadingNormalWeight(
			max(dot(centerMaterial.worldNormal, sampleMaterial.worldNormal), 0.0),
			perceptualRoughness
		);
		weight *= shadingWeight;
		weight *= exp2(-32.0 * abs(sampleLinearDepth - centerLinearDepth) / max(centerLinearDepth, 0.5));
		weight *= exp2(-24.0 * abs(sampleMaterial.perceptualRoughness - perceptualRoughness));
		#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER > 0
			if (i != 4) neighborSupport += weight;
		#endif
		signalSum += MaterialReflectionPowerEncode(sampleSignal.rgb, compression) * weight;
		weightSum += weight;
	}

	vec4 filtered = weightSum < 1.0e-5
		? centerSignal
		: vec4(MaterialReflectionPowerDecode(signalSum / weightSum, compression), clamp(weightSum, 0.0, 1.0));
	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER > 0
		float farComplexSurface = smoothstep(28.0, 110.0, centerLinearDepth)
			* mix(0.35, 1.0, centerMaterial.metalness)
			* mix(0.55, 1.0, smoothstep(0.18, 0.72, perceptualRoughness));
		float support = Saturate(neighborSupport * 0.30);
		float isolatedFade = mix(1.0, smoothstep(0.18, 0.72, support), farComplexSurface);
		filtered.rgb *= isolatedFade;
		filtered.a *= isolatedFade;
	#endif
	return filtered;
}

#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER == 3

	void MaterialReflectionTemporalBounds(
		const in vec2 centerRasterUv,
		const in MaterialReflectionGuide centerMaterial,
		const in float centerLinearDepth,
		const in vec3 currentColor,
		out vec3 lowerBound,
		out vec3 upperBound
	) {
		const ivec2 offsets[5] = ivec2[5](
			ivec2(0, 0), ivec2(-1, 0), ivec2(1, 0), ivec2(0, -1), ivec2(0, 1)
		);
		vec2 sourceSize = vec2(textureSize(colortex0, 0));
		float perceptualRoughness = centerMaterial.perceptualRoughness;
		vec3 encodedSum = vec3(0.0);
		vec3 encodedSquareSum = vec3(0.0);
		float weightSum = 0.0;
		for (int i = 0; i < 5; ++i) {
			vec2 sampleRasterUv = clamp(
				centerRasterUv + vec2(offsets[i]) / sourceSize,
				vec2(0.001), vec2(0.999)
			);
			MaterialReflectionGuide sampleMaterial;
			vec4 sampleSignal;
			float sampleLinearDepth;
			if (i == 0) {
				sampleMaterial = centerMaterial;
				sampleSignal = texture2D(colortex0, sampleRasterUv);
				sampleLinearDepth = centerLinearDepth;
			} else {
				BackendOpaqueSurface sampleSurface = MaterialReflectionOpaqueSurface(sampleRasterUv);
				float sampleDepthRaw = sampleSurface.rawDepth;
				vec4 samplePacket = texture2D(colortex2, MaterialReflectionPayloadUv(sampleRasterUv));
				sampleMaterial = DecodeMaterialReflectionGuide(samplePacket, sampleDepthRaw);
				sampleSignal = texture2D(colortex0, sampleRasterUv);
				sampleLinearDepth = max(-sampleSurface.viewPosition.z, 0.0);
			}
			float signalValid = step(1.0e-7, max(sampleSignal.r, max(sampleSignal.g, sampleSignal.b)));
			float weight = signalValid * MaterialReflectionSurfaceEnabled(sampleMaterial);
			weight *= i == 0 ? 1.0 : 0.72;
			weight *= MaterialReflectionGeometricNormalWeight(
				max(dot(centerMaterial.worldGeometricNormal, sampleMaterial.worldGeometricNormal), 0.0),
				perceptualRoughness
			);
			weight *= MaterialReflectionShadingNormalWeight(
				max(dot(centerMaterial.worldNormal, sampleMaterial.worldNormal), 0.0),
				perceptualRoughness
			);
			weight *= exp2(-32.0 * abs(sampleLinearDepth - centerLinearDepth) / max(centerLinearDepth, 0.5));
			weight *= exp2(-24.0 * abs(sampleMaterial.perceptualRoughness - perceptualRoughness));
			vec3 encoded = ReflectionTemporalEncodeColor(sampleSignal.rgb);
			encodedSum += encoded * weight;
			encodedSquareSum += encoded * encoded * weight;
			weightSum += weight;
		}
		vec3 fallback = ReflectionTemporalEncodeColor(currentColor);
		vec3 mean = weightSum > 1.0e-5 ? encodedSum / weightSum : fallback;
		vec3 variance = weightSum > 1.0e-5
			? max(encodedSquareSum / weightSum - mean * mean, vec3(0.0))
			: vec3(0.0);
		vec3 window = sqrt(variance) * 2.75 + vec3(0.035);
		lowerBound = max(mean - window, vec3(0.0));
		upperBound = mean + window;
	}

	#include "/features/material/reflection_apply.glsl"
#endif

void main() {
	vec2 rasterUv = texcoord;
	vec2 viewUv = MaterialReflectionViewUv(rasterUv);
	vec2 renderUv = MaterialReflectionRenderUv(rasterUv);
	vec4 packedSurface = texture2D(colortex2, MaterialReflectionPayloadUv(rasterUv));
	float depthRaw = MaterialIsGlass(packedSurface) > 0.5
		? texture2D(depthtex0, renderUv).r
		: texture2D(depthtex1, renderUv).r;
	MaterialReflectionGuide material = DecodeMaterialReflectionGuide(packedSurface, depthRaw);
	float enabled = MaterialReflectionSurfaceEnabled(material);

	#if FOXY_MATERIAL_REFLECTION_FILTER_ORDER < 3
		if (enabled < 0.5) {
			gl_FragData[0] = vec4(0.0);
			return;
		}
		BackendOpaqueSurface opaqueSurface = BackendResolveOpaqueSurface(
			viewUv,
			renderUv,
			depthRaw,
			gbufferProjectionInverse
		);
		vec3 currentViewPosition = opaqueSurface.viewPosition;
		float linearDepth = max(-currentViewPosition.z, 0.0);
		vec3 unusedTemporalLowerBound;
		vec3 unusedTemporalUpperBound;
		gl_FragData[0] = FilterMaterialReflection(
			rasterUv,
			material,
			linearDepth,
			currentViewPosition,
			unusedTemporalLowerBound,
			unusedTemporalUpperBound
		);
	#else
		vec4 staging = texture2D(colortex11, rasterUv);
		if (enabled < 0.5) {
			gl_FragData[0] = staging;
			gl_FragData[1] = vec4(0.0);
			return;
		}
		BackendOpaqueSurface opaqueSurface = BackendResolveOpaqueSurface(
			viewUv,
			renderUv,
			depthRaw,
			gbufferProjectionInverse
		);
		vec3 currentViewPosition = opaqueSurface.viewPosition;
		float linearDepth = max(-currentViewPosition.z, 0.0);
		vec3 unusedTemporalLowerBound;
		vec3 unusedTemporalUpperBound;
		if (material.reflectionType < 1.5) {
			vec3 sceneColor = max(DecodeSceneColor(staging.rgb), vec3(0.0));
			vec4 currentReflection = FilterMaterialReflection(
				rasterUv,
				material,
				linearDepth,
				currentViewPosition,
				unusedTemporalLowerBound,
				unusedTemporalUpperBound
			);
			vec3 combined = ApplyMaterialReflection(
				sceneColor,
				viewUv,
				renderUv,
				packedSurface,
				currentReflection
			);
			gl_FragData[0] = vec4(EncodeSceneColor(combined), staging.a);
			gl_FragData[1] = vec4(0.0);
			return;
		}
		vec3 temporalLowerBound;
		vec3 temporalUpperBound;
		vec4 filteredReflection = FilterMaterialReflection(
			rasterUv,
			material,
			linearDepth,
			currentViewPosition,
			temporalLowerBound,
			temporalUpperBound
		);
		float currentAvailable = step(0.01, filteredReflection.a);
		ReflectionReprojection reflectionReprojection = ReflectionBuildReprojection(
			currentViewPosition
		);
		ReflectionTemporalResult temporalReflection = ResolveReflectionTemporal(
			filteredReflection.rgb,
			filteredReflection.a,
			currentAvailable,
			material.reflectionType,
			material.perceptualRoughness,
			material.worldNormal,
			currentViewPosition,
			reflectionReprojection,
			temporalLowerBound,
			temporalUpperBound
		);
		filteredReflection = vec4(temporalReflection.color, temporalReflection.confidence);
		gl_FragData[1] = temporalReflection.packedHistory;
		vec3 sceneColor = max(DecodeSceneColor(staging.rgb), vec3(0.0));
		vec3 combined = ApplyMaterialReflection(sceneColor, viewUv, renderUv, packedSurface, filteredReflection);
		gl_FragData[0] = vec4(EncodeSceneColor(combined), staging.a);
	#endif
}
