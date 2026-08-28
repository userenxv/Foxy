#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/lighting.glsl"
#include "/lib/sky.glsl"
#include "/lib/shadow.glsl"
#include "/lib/celestial.glsl"
#include "/lib/clouds.glsl"
#include "/lib/water.glsl"
#include "/lib/surface_pbr.glsl"
#include "/lib/rain.glsl"
#include "/lib/contracts/endpoint.glsl"
#if FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
	#include "/lib/contracts/direct_shadow.glsl"
#endif
#define PT_GBUFFER_WRITE
#include "/lib/pt_gbuffer.glsl"
#undef PT_GBUFFER_WRITE
#if FOXY_VOXEL_GI_ACTIVE == 1
	#include "/lib/contracts/sky_lut.glsl"
	#include "/lib/dimension_sky.glsl"
	#include "/lib/voxel/vrtgi_fallback.glsl"
#endif

#if FOXY_PT_GBUFFER_ACTIVE == 1
	#if FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
	/* RENDERTARGETS: 0,2,13 */
	#else
	/* RENDERTARGETS: 0,2 */
	#endif
#else
	#if FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
	/* RENDERTARGETS: 0,13 */
	#else
	/* DRAWBUFFERS:0 */
	#endif
#endif

#ifdef COLORWHEEL
uniform sampler2D gtexture;
#define MATERIAL_TEXTURE_GRAD(samplerName, uv, dx, dy) textureGrad(samplerName, uv, dx, dy)
#else
uniform sampler2D texture;
#define MATERIAL_TEXTURE_GRAD(samplerName, uv, dx, dy) texture2DGradARB(samplerName, uv, dx, dy)
#endif
uniform sampler2D lightmap;
uniform ivec2 atlasSize;
#if FOXY_PBR_SPECULAR_MAPS == 1
uniform sampler2D specular;
#endif
#if FOXY_PBR_NORMAL_MAPS == 1
uniform sampler2D normals;
#endif
uniform sampler2D shadowtex0;
uniform sampler2DShadow shadowtex1;
uniform sampler2D shadowcolor0;
uniform sampler2D colortex7;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowProjection;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform float far;
uniform float rainStrength;
uniform float frameTimeCounter;
uniform float waterEnteredAltitude;
uniform int isEyeInWater;
uniform int frameCounter;
uniform ivec2 eyeBrightnessSmooth;

varying vec2 texcoord;
varying vec2 spriteUv;
varying vec2 spriteHalfSize;
varying vec2 vertexLmcoord;
varying vec4 surfaceColor;
varying vec3 surfaceNormalView;
varying vec3 surfaceViewPosition;
varying vec3 surfaceWorldPosition;
varying float vertexMaterialId;
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying vec3 vertexSunView;
varying vec3 vertexMoonView;
varying vec3 vertexUpView;
varying vec2 vertexShadowSelection;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;

#if FOXY_PBR_NORMAL_MAPS == 1 && defined(TERRAIN)
varying vec3 surfaceTangentView;
varying vec3 surfaceBitangentView;
#endif

#include "/features/material/parallax.glsl"

#include "/lib/foliage.glsl"

float ShadowSafeDivisor(const in float x) {
	if (abs(x) < 1.0e-6) {
		return x < 0.0 ? -1.0e-6 : 1.0e-6;
	}
	return x;
}

struct ShadowReceiver {
	vec3 coord;
	vec2 clipXY;
	vec2 depthSlope;
	float bias;
	float edgeFade;
};

vec3 ShadowNdcFromPlayerPos(const in vec3 playerPos) {
	vec4 shadowClip = shadowProjection * shadowModelView * vec4(playerPos, 1.0);
	return shadowClip.xyz / ShadowSafeDivisor(shadowClip.w);
}

ShadowReceiver ShadowBuildReceiver(
	const in float NoL,
	const in float biasLift,
	const in vec3 normalView,
	const in float skyLight
) {
	ShadowReceiver receiver;
	receiver.coord = vec3(0.5);
	receiver.clipXY = vec2(0.0);
	receiver.depthSlope = vec2(0.0);
	receiver.bias = 0.0;
	receiver.edgeFade = 0.0;

	float surfaceNoL = Saturate(NoL);
	float grazing = 1.0 - smoothstep(0.035, 0.32, surfaceNoL);
	float viewDistance = length(surfaceViewPosition);
	float distanceRatio = Saturate(viewDistance / max(FOXY_SHADOW_DISTANCE, 1.0));
	float projectionScale = max(abs(shadowProjection[0][0]), 1.0e-6);
	float worldTexel = 2.0 / (float(FOXY_SHADOW_RESOLUTION) * projectionScale);
	float normalOffset = worldTexel * (0.18 + distanceRatio * 0.18 + grazing * (0.38 + distanceRatio * 0.42));
	normalOffset = clamp(normalOffset, 0.018, 0.220);
	vec3 normalPlayer = normalize(mat3(gbufferModelViewInverse) * normalView);
	vec3 receiverPlayerPos = surfaceWorldPosition + normalPlayer * normalOffset;
	// Enclosed terrain contracts the receiver to prevent cave-edge shadow leaks.
	float interiorReceiver = 1.0 - smoothstep(0.045, 0.115, skyLight);
	if (interiorReceiver > 0.001) {
		vec3 receiverWorldPos = receiverPlayerPos + cameraPosition;
		vec3 blockCenter = floor(receiverWorldPos) + vec3(0.5);
		vec3 contractedWorldPos = blockCenter +
			(receiverWorldPos - blockCenter) * 0.54;
		receiverPlayerPos = mix(
			receiverPlayerPos,
			contractedWorldPos - cameraPosition,
			interiorReceiver
		);
	}
	vec3 shadowNdc = ShadowNdcFromPlayerPos(receiverPlayerPos);

	receiver.clipXY = shadowNdc.xy;
	receiver.coord = vec3(ShadowWarp(receiver.clipXY), shadowNdc.z) * 0.5 + 0.5;
	if (receiver.coord.x <= 0.0 || receiver.coord.y <= 0.0 || receiver.coord.x >= 1.0 || receiver.coord.y >= 1.0 || receiver.coord.z <= 0.0 || receiver.coord.z >= 1.0) {
		return receiver;
	}

	receiver.edgeFade = ShadowSurfaceCoverageFade(receiver.coord.xy, viewDistance);

	vec3 normalShadow = normalize(mat3(shadowModelView) * normalPlayer);
	float normalShadowZ = normalShadow.z;
	if (abs(normalShadowZ) < 0.08) {
		normalShadowZ = normalShadowZ < 0.0 ? -0.08 : 0.08;
	}
	float projectionX = ShadowSafeDivisor(shadowProjection[0][0]);
	float projectionY = ShadowSafeDivisor(shadowProjection[1][1]);
	receiver.depthSlope = -0.5 * shadowProjection[2][2] * vec2(
		normalShadow.x / projectionX,
		normalShadow.y / projectionY
	) / normalShadowZ;
	receiver.depthSlope = clamp(receiver.depthSlope, vec2(-8.0), vec2(8.0));

	float baseBias = mix(0.00034, 0.000045, surfaceNoL);
	float distanceBias = distanceRatio * distanceRatio * 0.00010;
	float slopeBias = grazing * grazing * mix(0.00008, 0.00030, distanceRatio);
	float receiverPlaneBias = min(
		ShadowReceiverPlaneBias(receiver.clipXY, receiver.depthSlope) *
			SHADOW_RECEIVER_PLANE_BIAS_SCALE,
		SHADOW_RECEIVER_PLANE_BIAS_MAX
	);
	receiver.bias = baseBias + distanceBias + slopeBias + receiverPlaneBias + biasLift * 0.30;
	return receiver;
}

vec2 ShadowReceiverUv(const in ShadowReceiver receiver, const in vec2 offsetTexels) {
	return clamp(ShadowSampleUv(receiver.clipXY, offsetTexels), vec2(0.001), vec2(0.999));
}

float ShadowReceiverDepth(const in ShadowReceiver receiver, const in vec2 offsetTexels) {
	vec2 clipOffset = ShadowTexelOffsetToClip(offsetTexels);
	return receiver.coord.z + dot(receiver.depthSlope, clipOffset) - receiver.bias;
}

float ShadowHardwareCompare(const in ShadowReceiver receiver, const in vec2 offsetTexels) {
	vec2 uv = ShadowReceiverUv(receiver, offsetTexels);
	return shadow2D(shadowtex1, vec3(uv, ShadowReceiverDepth(receiver, offsetTexels))).x;
}

float ShadowHardwareCompareFiltered(
	const in ShadowReceiver receiver,
	const in ShadowFilterWarp filterWarp,
	const in vec2 offsetTexels
) {
	vec2 uv = ShadowFilterSampleUv(receiver.clipXY, receiver.coord.xy, filterWarp, offsetTexels);
	return shadow2D(shadowtex1, vec3(uv, ShadowReceiverDepth(receiver, offsetTexels))).x;
}

float ShadowTransmissionMarker(const in vec4 transmissionSample) {
	float transmissionCoverage = Saturate(transmissionSample.a);
	vec3 transmission = clamp(
		transmissionSample.rgb / max(transmissionCoverage, 1.0e-4),
		vec3(0.02),
		vec3(1.0)
	);
	return transmissionCoverage *
		(1.0 - step(0.998, max(max(transmission.r, transmission.g), transmission.b)));
}

bool ShadowHasTransmission(
	const in ShadowReceiver receiver,
	const in ShadowFilterWarp filterWarp,
	const in float filterRadius,
	const in float phase
) {
	vec2 centerUv = ShadowFilterSampleUv(
		receiver.clipXY,
		receiver.coord.xy,
		filterWarp,
		vec2(0.0)
	);
	float marker = ShadowTransmissionMarker(texture2D(shadowcolor0, centerUv));
	vec2 direction = ShadowDirection(fract(phase + 0.61803398875));
	float probeRadius = max(filterRadius * 0.82, 0.18);
	for (int i = 0; i < 4; i++) {
		vec2 uv = ShadowFilterSampleUv(
			receiver.clipXY,
			receiver.coord.xy,
			filterWarp,
			direction * probeRadius
		);
		marker = max(marker, ShadowTransmissionMarker(texture2D(shadowcolor0, uv)));
		direction = vec2(-direction.y, direction.x);
	}
	return marker > 0.002;
}

vec2 ShadowBlockerSearch(
	const in ShadowReceiver receiver,
	const in float centerDepth,
	const in float centerVisibility,
	const in float searchRadius,
	const in float phase
) {
	float sampleCount = float(FOXY_SHADOW_BLOCKER_SAMPLES);
	float radialJitter = fract(phase * 1.32471795724 + 0.37);
	float blockerGapSum = 0.0;
	float blockerWeight = 0.0;
	float threshold = max(receiver.bias * 0.12, 0.000015);

	float centerGap = max(ShadowReceiverDepth(receiver, vec2(0.0)) - centerDepth, 0.0);
	float centerWeight = smoothstep(threshold, threshold * 3.0, centerGap);
	blockerGapSum += centerGap * centerWeight;
	blockerWeight += centerWeight;

	vec2 direction = ShadowDirection(fract(phase + 0.38196601125));
	for (int i = 1; i < FOXY_SHADOW_BLOCKER_SAMPLES; i++) {
		if (
			i == FOXY_SHADOW_BLOCKER_BASE_SAMPLES &&
			centerVisibility >= 0.999 &&
			blockerWeight <= 0.0001
		) {
			return vec2(0.0);
		}
		direction = ShadowGoldenRotate(direction);
		float radius = ShadowDiskRadius(float(i), sampleCount, radialJitter);
		vec2 offsetTexels = direction * (searchRadius * radius);
		vec2 uv = ShadowReceiverUv(receiver, offsetTexels);
		float sampleDepth = texture2D(shadowtex0, uv).r;
		float gap = max(ShadowReceiverDepth(receiver, offsetTexels) - sampleDepth, 0.0);
		float weight = smoothstep(threshold, threshold * 3.0, gap);
		blockerGapSum += gap * weight;
		blockerWeight += weight;
	}

	if (blockerWeight <= 0.0001) {
		return vec2(0.0);
	}
	return vec2(blockerGapSum / blockerWeight, blockerWeight / sampleCount);
}

float ShadowFilterPcf(
	const in ShadowReceiver receiver,
	const in ShadowFilterWarp filterWarp,
	const in float filterRadius,
	const in float phase,
	const in bool sampleTransmission,
	out vec3 transmissionFactor
) {
	#if FOXY_SHADOW_FILTER_SAMPLES > 12
		const int maxFilterSamples = 12;
	#else
		const int maxFilterSamples = FOXY_SHADOW_FILTER_SAMPLES;
	#endif
	int activeSamples = maxFilterSamples;
	#if FOXY_SHADOW_FILTER_SAMPLES > 8
		if (filterRadius < 1.65) {
			activeSamples = 8;
		}
	#endif
	#if FOXY_SHADOW_FILTER_SAMPLES > 12
		if (filterRadius >= 1.65 && filterRadius < 3.10) {
			activeSamples = 12;
		}
	#endif

	float sampleCount = float(activeSamples);
	float radialJitter = fract(phase * 1.61803398875 + 0.21);
	vec2 direction = ShadowDirection(fract(phase + 0.17320508076));
	float visibility = 0.0;
	vec3 transmissionEnergy = vec3(0.0);
	for (int i = 0; i < maxFilterSamples; i++) {
		if (i >= activeSamples) break;
		direction = ShadowGoldenRotate(direction);
		float radius = ShadowDiskRadius(float(i), sampleCount, radialJitter);
		vec2 offsetTexels = direction * (filterRadius * radius);
		float opaqueVisibility = ShadowHardwareCompareFiltered(
			receiver,
			filterWarp,
			offsetTexels
		);
		visibility += opaqueVisibility;
		vec3 sampleEnergy = vec3(opaqueVisibility);

		// Opaque and transmissive shadows share one PCF footprint.
		if (sampleTransmission) {
			vec2 uv = ShadowFilterSampleUv(
				receiver.clipXY,
				receiver.coord.xy,
				filterWarp,
				offsetTexels
			);
			vec4 transmissionSample = texture2D(shadowcolor0, uv);
			float transmissionCoverage = Saturate(transmissionSample.a);
			vec3 transmission = clamp(
				transmissionSample.rgb / max(transmissionCoverage, 1.0e-4),
				vec3(0.02),
				vec3(1.0)
			);
			float transmissionMarker = transmissionCoverage *
				(1.0 - step(
					0.998,
					max(max(transmission.r, transmission.g), transmission.b)
				));
			if (transmissionMarker > 0.0) {
				float allGeometryDepth = texture2D(shadowtex0, uv).r;
				float allGeometryVisibility = ShadowCompareDepth(
					ShadowReceiverDepth(receiver, offsetTexels),
					allGeometryDepth,
					0.0
				);
				float glassVisibility = max(
					opaqueVisibility - allGeometryVisibility,
					0.0
				) * transmissionMarker;
				sampleEnergy += glassVisibility *
					(transmission - vec3(1.0));
			}
		}
		transmissionEnergy += sampleEnergy;
	}
	float filteredVisibility = visibility / max(sampleCount, 1.0);
	vec3 filteredEnergy = transmissionEnergy / max(sampleCount, 1.0);
	transmissionFactor = filteredVisibility > 0.001
		? clamp(
			filteredEnergy / filteredVisibility,
			vec3(0.02),
			vec3(1.0)
		)
		: vec3(1.0);
	return filteredVisibility;
}

vec4 ShadowEvaluate(
	const in ShadowReceiver receiver,
	const in float lightAltitude,
	const in bool sampleTransmission,
	out float visibility
) {
	visibility = 1.0;
	if (receiver.edgeFade <= 0.0001) {
		return vec4(1.0, 1.0, 1.0, 0.0);
	}

	float centerDepth = texture2D(shadowtex0, receiver.coord.xy).r;
	float center = ShadowHardwareCompare(receiver, vec2(0.0));
	#if FOXY_SHADOW_FILTERING == 0
		float hardFloorVisibility = 1.0 - FOXY_SHADOW_STRENGTH;
		float hardShadowVisibility = mix(hardFloorVisibility, 1.0, center);
		visibility = mix(1.0, hardShadowVisibility, receiver.edgeFade);
		return vec4(1.0, 1.0, 1.0, 0.0);
	#endif
	float phase = ShadowTemporalPhase(gl_FragCoord.xy, frameCounter);
	float altitudeStability = smoothstep(0.025, 0.20, max(lightAltitude, 0.0));
	float searchRadius = (4.00 + FOXY_SHADOW_SOFTNESS * 5.00) * mix(0.75, 1.0, altitudeStability);
	vec2 blockerInfo = ShadowBlockerSearch(receiver, centerDepth, center, searchRadius, phase);

	float gapLimit = 0.0065 + FOXY_SHADOW_SOFTNESS * 0.0050;
	float gapResponse = sqrt(smoothstep(0.00018, gapLimit, blockerInfo.x));
	float coverageResponse = smoothstep(0.02, 0.22, blockerInfo.y);
	float minimumRadius = SHADOW_MIN_FILTER_TEXELS *
		mix(1.06, 1.0, altitudeStability);
	float maximumPenumbra = (0.12 + FOXY_SHADOW_SOFTNESS * 1.00) * mix(0.80, 1.0, altitudeStability);
	float filterRadius = minimumRadius + maximumPenumbra * gapResponse * coverageResponse;
	float centerGap = max(ShadowReceiverDepth(receiver, vec2(0.0)) - centerDepth, 0.0);
	float contactScale = mix(0.62, 1.0, smoothstep(0.00018, 0.0028 + FOXY_SHADOW_SOFTNESS * 0.0022, centerGap));
	filterRadius *= mix(1.0, contactScale, 1.0 - Saturate(center));
	filterRadius = clamp(filterRadius, 0.10, 2.50);
	ShadowFilterWarp filterWarp = ShadowBuildFilterWarp(receiver.clipXY);
	bool hasTransmission = sampleTransmission && ShadowHasTransmission(
		receiver,
		filterWarp,
		filterRadius,
		phase
	);
	vec3 filteredTransmission = vec3(1.0);
	float filtered = ShadowFilterPcf(
		receiver,
		filterWarp,
		filterRadius,
		phase,
		hasTransmission,
		filteredTransmission
	);

	float floorVisibility = 1.0 - FOXY_SHADOW_STRENGTH;
	float shadowVisibility = mix(floorVisibility, 1.0, Saturate(filtered));
	visibility = mix(1.0, shadowVisibility, receiver.edgeFade);
	if (!hasTransmission || visibility <= 0.0) {
		return vec4(1.0, 1.0, 1.0, 0.0);
	}
	vec3 transmissionColor = mix(
		vec3(1.0),
		filteredTransmission,
		receiver.edgeFade
	);
	float transmissionAmount = max(
		max(1.0 - filteredTransmission.r, 1.0 - filteredTransmission.g),
		1.0 - filteredTransmission.b
	);
	return vec4(
		transmissionColor,
		Saturate(transmissionAmount) * receiver.edgeFade
	);
}

PbrMaterial BuildLitPbrMaterial(
	const in vec3 albedo,
	const in vec3 normalView,
	const in vec2 materialUv,
	const in mat2 materialGradients
) {
	PbrMaterial material = PbrDefaultMaterial(albedo, normalView);
	#if FOXY_PBR == 1
		PbrApplyFallbackMaterial(material, vertexMaterialId);
		#if FOXY_PBR_SPECULAR_MAPS == 1
			#if FOXY_PBR_PARALLAX == 1 && FOXY_PBR_NORMAL_MAPS == 1 && defined(TERRAIN)
				PbrApplySpecularMap(material, MATERIAL_TEXTURE_GRAD(
					specular,
					materialUv,
					materialGradients[0],
					materialGradients[1]
				));
			#else
				PbrApplySpecularMap(material, texture2D(specular, materialUv));
			#endif
		#endif
	#endif
	return material;
}

#if FOXY_PBR_NORMAL_MAPS == 1 && !defined(TERRAIN)
// Rebuild tangent frames for geometry without a reliable terrain tangent attribute.
bool GbufferLitDerivativeTangentFrame(
	const in vec3 normalView,
	out vec3 tangentView,
	out vec3 bitangentView
) {
	vec2 uvDx = dFdx(texcoord);
	vec2 uvDy = dFdy(texcoord);
	float determinant = uvDx.x * uvDy.y - uvDx.y * uvDy.x;
	if (abs(determinant) <= 1.0e-8) return false;

	vec3 positionDx = dFdx(surfaceViewPosition);
	vec3 positionDy = dFdy(surfaceViewPosition);
	vec3 frameNormal = PbrSafeNormal(normalView, vec3(0.0, 0.0, 1.0));
	vec3 rawTangent = (positionDx * uvDy.y - positionDy * uvDx.y) / determinant;
	vec3 rawBitangent = (positionDy * uvDx.x - positionDx * uvDy.x) / determinant;

	rawTangent -= frameNormal * dot(rawTangent, frameNormal);
	float tangentLengthSquared = dot(rawTangent, rawTangent);
	if (tangentLengthSquared <= 1.0e-10) return false;
	tangentView = rawTangent * inversesqrt(tangentLengthSquared);

	rawBitangent -= frameNormal * dot(rawBitangent, frameNormal);
	rawBitangent -= tangentView * dot(rawBitangent, tangentView);
	float bitangentLengthSquared = dot(rawBitangent, rawBitangent);
	if (bitangentLengthSquared <= 1.0e-10) return false;
	bitangentView = rawBitangent * inversesqrt(bitangentLengthSquared);
	return true;
}
#endif

#if FOXY_VOXEL_GI_ACTIVE == 1
// Build fallback from the continuous raster lightmap, not quantized PT metadata.
vec3 GbufferLitVrtgiFallbackIndirect(
	const in vec2 continuousLightmap,
	const in vec3 geometricWorldNormal,
	const in vec3 diffuseAlbedo,
	const in float reflectedLightWeight
) {
	float originBias = max(0.025, max(-surfaceViewPosition.z, 1.0e-3) * 0.00065);
	vec3 originPlayerPosition = surfaceWorldPosition + geometricWorldNormal * originBias;
	float domainWeight = VrtgiReceiverDomainWeight(originPlayerPosition, cameraPosition);

	vec3 skyFluence = vec3(0.0);
	#if !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
		skyFluence = DecodeBufferColor(texelFetch(
			colortex7,
			SkyUpperHemisphereFluenceTexel(),
			0
		).rgb);
	#endif
	vec3 fallbackRadiance = VrtgiReceiverFallbackRadiance(
		continuousLightmap,
		geometricWorldNormal,
		skyFluence
	);
	#if defined(FOXY_DIM_END)
		float indirectIntensity = clamp(FOXY_VOXEL_GI_INTENSITY, 0.0, 3.0) * 8.0;
	#else
		float indirectIntensity = clamp(FOXY_VOXEL_GI_INTENSITY, 0.0, 3.0) *
			(8.0 * FOXY_VXGI_MASTER_CALIBRATION);
	#endif
	return diffuseAlbedo * fallbackRadiance * indirectIntensity *
		(1.0 - domainWeight) * reflectedLightWeight;
}
#endif

void main() {
	vec3 pbrViewDirection = normalize(-surfaceViewPosition);
	vec2 materialUv = texcoord;
	mat2 materialGradients = mat2(dFdx(texcoord), dFdy(texcoord));
	#if FOXY_PBR_PARALLAX == 1 && FOXY_PBR_NORMAL_MAPS == 1 && defined(TERRAIN)
		vec3 parallaxViewDirTangent = vec3(
			dot(pbrViewDirection, surfaceTangentView),
			dot(pbrViewDirection, surfaceBitangentView),
			dot(pbrViewDirection, normalize(surfaceNormalView))
		);
		PbrParallaxHit parallaxHit = PbrTraceParallax(texcoord, parallaxViewDirTangent);
		materialUv = parallaxHit.atlasUv;
	#endif
	#if FOXY_PBR_PARALLAX == 1 && FOXY_PBR_NORMAL_MAPS == 1 && defined(TERRAIN)
		#ifdef COLORWHEEL
			vec4 texel = textureGrad(
				gtexture,
				materialUv,
				materialGradients[0],
				materialGradients[1]
			);
		#else
			vec4 texel = texture2DGradARB(
				texture,
				materialUv,
				materialGradients[0],
				materialGradients[1]
			);
		#endif
	#else
		#ifdef COLORWHEEL
			vec4 texel = texture2D(gtexture, materialUv);
		#else
			vec4 texel = texture2D(texture, materialUv);
		#endif
	#endif
	#ifdef COLORWHEEL
		vec2 materialLmcoord;
		float materialAo;
		vec4 materialOverlay;
		clrwl_computeFragment(
			texel,
			texel,
			materialLmcoord,
			materialAo,
			materialOverlay
		);
		texel.rgb = mix(texel.rgb, materialOverlay.rgb, materialOverlay.a);
	#else
		texel *= surfaceColor;
		vec2 materialLmcoord = vertexLmcoord;
	#endif
	#ifdef ALPHA_TEST
		if (texel.a < 0.10) discard;
	#endif

	vec3 geometricNormalView = normalize(surfaceNormalView);
	vec3 normalView = geometricNormalView;
	#if FOXY_PBR == 1
		#if FOXY_PBR_NORMAL_MAPS == 1
			#if FOXY_PBR_PARALLAX == 1 && defined(TERRAIN)
				vec3 mappedNormalTangent = PbrDecodeNormalMap(MATERIAL_TEXTURE_GRAD(
					normals,
					materialUv,
					materialGradients[0],
					materialGradients[1]
				).rgb);
			#else
				vec3 mappedNormalTangent = PbrDecodeNormalMap(texture2D(normals, materialUv).rgb);
			#endif
			#if FOXY_PBR_PARALLAX == 1 && defined(TERRAIN)
				mappedNormalTangent = mix(
					mappedNormalTangent,
					parallaxHit.heightNormalTangent,
					parallaxHit.sideMask
				);
			#endif
			#if defined(TERRAIN)
				vec3 mappedNormalView =
					surfaceTangentView * mappedNormalTangent.x +
					surfaceBitangentView * mappedNormalTangent.y +
					geometricNormalView * mappedNormalTangent.z;
				normalView = PbrSafeNormal(mappedNormalView, geometricNormalView);
			#else
				vec3 tangentView;
				vec3 bitangentView;
				if (GbufferLitDerivativeTangentFrame(
					geometricNormalView,
					tangentView,
					bitangentView
				)) {
					vec3 mappedNormalView =
						tangentView * mappedNormalTangent.x +
						bitangentView * mappedNormalTangent.y +
						geometricNormalView * mappedNormalTangent.z;
					normalView = PbrSafeNormal(mappedNormalView, geometricNormalView);
				}
			#endif
		#endif
		normalView = PbrVisibleNormal(normalView, geometricNormalView, pbrViewDirection);
	#endif
	vec3 upDir = vertexUpView;
	vec3 sunDir = vertexSunView;
	vec3 moonDir = vertexMoonView;
	vec3 shadowDir = normalize(shadowLightPosition);
	float sunAltitude = vertexSunAltitude;
	float moonAltitude = vertexMoonAltitude;

	vec3 mainDayLightDir = sunDir;
	float sunNoL = max(dot(normalView, mainDayLightDir), 0.0);
	float moonNoL = max(dot(normalView, moonDir), 0.0);
	float sunGeomNoL = max(dot(geometricNormalView, mainDayLightDir), 0.0);
	float moonGeomNoL = max(dot(geometricNormalView, moonDir), 0.0);
	float dither = Bayer16(gl_FragCoord.xy);
	vec2 ditheredLmcoord = Dither8Bit2(clamp(materialLmcoord, vec2(0.0), vec2(1.0)), dither);
	vec3 lightmapColor = SrgbToLinear(texture2D(lightmap, ditheredLmcoord).rgb);
	float blockLight = ditheredLmcoord.x;
	float skyLight = ditheredLmcoord.y;
	// Remove the positive texel-center floor from light level zero.
	float directSkyVisibility = smoothstep(0.045, 0.155, skyLight);
	float underwaterView = isEyeInWater == 1 ? 1.0 : 0.0;
	vec3 worldPosForLighting = surfaceWorldPosition + cameraPosition;
	float waterDepthForLighting = max(waterEnteredAltitude - worldPosForLighting.y, 0.0) * underwaterView;
	float foliageTransmissionMask = 0.0;
	if (PbrIdInRange(vertexMaterialId, 10100.0, 10103.0)) {
		foliageTransmissionMask = FoliageTransmissionMask(texel.a);
	}
	vec3 sunTransmission = vec3(1.0);
	vec3 moonTransmission = vec3(1.0);
	float useSunShadow = vertexShadowSelection.x;
	float activeShadowMatch = vertexShadowSelection.y;
	float activeShadowNoL = mix(moonGeomNoL, sunGeomNoL, useSunShadow);
	float activeShadowAltitude = mix(moonAltitude, sunAltitude, useSunShadow);
	float activeDirectWeight = activeShadowMatch * DirectCelestialVisibility(activeShadowAltitude);
	float activeShadowNeed = max(smoothstep(0.002, 0.050, mix(moonNoL, sunNoL, useSunShadow)), foliageTransmissionMask);
	float activeShadow = 1.0;
	float activeShadowCoverage = 0.0;
	if (directSkyVisibility > 0.001 && activeShadowAltitude > 0.0 && activeShadowNeed > 0.001 && activeShadowMatch > 0.001) {
		float waterShadowBiasLift = underwaterView * useSunShadow * min(0.0022, 0.00035 + waterDepthForLighting * 0.00010);
		ShadowReceiver shadowReceiver = ShadowBuildReceiver(
			activeShadowNoL,
			waterShadowBiasLift,
			geometricNormalView,
			skyLight
		);
		activeShadowCoverage = shadowReceiver.edgeFade;
		float evaluatedShadow = 1.0;
		bool sampleTransmission = isEyeInWater == 0;
		vec4 evaluatedTransmission = ShadowEvaluate(shadowReceiver, activeShadowAltitude, sampleTransmission, evaluatedShadow);
		activeShadow = mix(1.0, evaluatedShadow, activeShadowMatch);
		#if FOXY_CLOUDS == 1
			if (activeShadow > 0.0) {
				vec3 activeShadowDir = mix(moonDir, sunDir, useSunShadow);
				vec3 activeShadowWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, activeShadowDir));
				activeShadow *= CloudShadowVisibilityCached(colortex7, worldPosForLighting, cameraPosition, activeShadowWorld, frameTimeCounter, rainStrength);
			}
		#endif
		if (sampleTransmission) {
			vec3 activeTransmission = mix(vec3(1.0), evaluatedTransmission.rgb, activeShadowMatch);
			if (useSunShadow > 0.5) {
				sunTransmission = activeTransmission;
			} else {
				moonTransmission = activeTransmission;
			}
		}
	}
	float sunShadow = mix(1.0, activeShadow, useSunShadow);
	float moonShadow = mix(activeShadow, 1.0, useSunShadow);

	vec3 albedo = SrgbToLinear(texel.rgb);
	PbrMaterial material = BuildLitPbrMaterial(albedo, normalView, materialUv, materialGradients);
	float puddleMask = 0.0;
	#if defined(TERRAIN)
		if (rainStrength > 0.001) {
			vec3 geometricWorldNormal = normalize(mat3(gbufferModelViewInverse) * geometricNormalView);
			vec3 materialWorldNormal = normalize(mat3(gbufferModelViewInverse) * material.normalView);
			float puddleNoise = texture2D(noisetex, worldPosForLighting.xz * 0.018 + vec2(0.17, 0.41)).a;
			puddleMask = RainPuddleMask(
				worldPosForLighting,
				geometricWorldNormal,
				skyLight,
				rainStrength,
				vertexMaterialId,
				puddleNoise
			);
			float puddleSurface = puddleMask * (1.0 - material.metalness) * (1.0 - material.porosity * 0.62);
			if (puddleMask > 0.001) {
				float wetDarkening = mix(0.70, 0.82, material.porosity);
				material.albedo *= mix(vec3(1.0), vec3(wetDarkening), puddleMask);
				material.f0 = mix(material.f0, vec3(0.022), puddleSurface);
				material.roughness = mix(material.roughness, 0.018, puddleSurface);
				material.specularWeight = mix(material.specularWeight, 1.0, puddleSurface);
				vec3 flatWetNormal = normalize(mix(materialWorldNormal, geometricWorldNormal, puddleSurface * 0.78));
				vec3 rippleWorldNormal = RainPerturbWorldNormal(
					flatWetNormal,
					worldPosForLighting.xz,
					frameTimeCounter,
					puddleSurface * rainStrength
				);
				materialWorldNormal = normalize(mix(materialWorldNormal, rippleWorldNormal, puddleSurface));
				material.normalView = normalize(mat3(gbufferModelView) * materialWorldNormal);
				normalView = material.normalView;
				sunNoL = max(dot(normalView, mainDayLightDir), 0.0);
				moonNoL = max(dot(normalView, moonDir), 0.0);
			}
		}
	#endif
	vec3 puddleEnvironmentReflection = vec3(0.0);
	#if FOXY_MATERIAL_REFLECTIONS == 0
		if (puddleMask > 0.001) {
			vec3 puddleIncidentView = normalize(surfaceViewPosition);
			vec3 puddleReflectedView = normalize(reflect(puddleIncidentView, material.normalView));
			vec3 puddleReflectedWorld = normalize(mat3(gbufferModelViewInverse) * puddleReflectedView);
			vec3 puddleSky = DecodeSkyLutColor(
				texture2D(colortex7, SkyViewLutUv(puddleReflectedWorld)).rgb
			);
			float puddleNoV = max(dot(material.normalView, -puddleIncidentView), 0.0);
			float puddleFresnel = 0.030 + 0.970 * pow(1.0 - puddleNoV, 5.0);
			float puddleSkyAccess = smoothstep(0.08, 0.56, skyLight);
			float puddleReflectionWeight = puddleMask * puddleSkyAccess * (0.16 + 0.84 * puddleFresnel);
			puddleEnvironmentReflection = puddleSky * puddleReflectionWeight;
		}
	#endif
	#if FOXY_PT_GBUFFER_ACTIVE == 1
		float ptSurfaceClass = PT_SURFACE_OPAQUE;
		#ifdef ALPHA_TEST
			ptSurfaceClass = PT_SURFACE_ALPHA_TEST;
		#endif
		if (PbrIdInRange(vertexMaterialId, 10100.0, 10100.0)) {
			ptSurfaceClass = PT_SURFACE_FOLIAGE;
		} else if (PbrIdInRange(vertexMaterialId, 10101.0, 10103.0)) {
			ptSurfaceClass = PT_SURFACE_PLANT;
		}
		bool ptEmissiveTexel = material.emissionMask > 0.0;
		if (ptEmissiveTexel) {
			ptSurfaceClass = PT_SURFACE_EMISSIVE;
		}
		#ifdef PT_REACTIVE_SURFACE
			if (!ptEmissiveTexel) {
				ptSurfaceClass = PT_SURFACE_DYNAMIC;
			}
		#endif
		vec3 ptWorldNormal = normalize(mat3(gbufferModelViewInverse) * material.normalView);
		vec3 ptWorldGeometricNormal = normalize(
			mat3(gbufferModelViewInverse) * geometricNormalView
		);
		// Emitted RGB is a dedicated field, not albedo.
		vec3 ptDiffuseAlbedo = PbrDiffuseAlbedo(material);
		vec3 ptStoredEmission = PbrSsptEmission(material.albedo, material.emissionMask);
		vec3 ptStoredAlbedo = ptEmissiveTexel
			? Saturate3(ptStoredEmission)
			: ptDiffuseAlbedo;
		vec4 ptSurfaceOutput = PtEncodeGbuffer(
			ptStoredAlbedo,
			ptWorldNormal,
			ptWorldGeometricNormal,
			materialLmcoord,
			ptSurfaceClass,
			material.roughness,
			material.metalness
		);
	#endif
	float sunWrap = sunNoL * 1.08 + pow(sunNoL, 8.0) * 0.24;
	vec3 rawSunLightColor = vertexSunLightColor;
	vec3 rawMoonLightColor = vertexMoonLightColor;
	vec3 sunLightColor = rawSunLightColor * sunTransmission * (useSunShadow * activeDirectWeight);
	vec3 moonLightColor = rawMoonLightColor * moonTransmission * ((1.0 - useSunShadow) * activeDirectWeight);
	vec3 direct = sunLightColor * sunWrap * sunShadow * skyLight * directSkyVisibility;
	direct += moonLightColor * (moonNoL * 1.03 + pow(moonNoL, 8.0) * 0.08) * moonShadow * skyLight * directSkyVisibility;
	#if defined(FOXY_DIM_END)
		float endSunNoL = max(dot(geometricNormalView, vertexSunView), 0.0);
		direct = vec3(0.42, 0.48, 0.70) * endSunNoL * mix(0.35, 1.0, skyLight);
	#endif
	vec3 directSpecular = vec3(0.0);
	vec3 directSss = vec3(0.0);
	#if FOXY_PBR == 1
		vec3 sunSpecularLight = vec3(0.0);
		vec3 moonSpecularLight = vec3(0.0);
		sunSpecularLight = sunLightColor * skyLight * directSkyVisibility;
		moonSpecularLight = moonLightColor * skyLight * directSkyVisibility;
		directSpecular += PbrDirectSpecular(material, mainDayLightDir, pbrViewDirection, sunShadow, sunSpecularLight);
		directSpecular += PbrDirectSpecular(material, moonDir, pbrViewDirection, moonShadow, moonSpecularLight);
		directSpecular *= mix(1.0, 0.72, rainStrength);
	#endif
	float ambientSunShadow = mix(1.0, sunShadow, smoothstep(0.015, 0.18, sunGeomNoL));
	float ambientMoonShadow = mix(1.0, moonShadow, smoothstep(0.015, 0.18, moonGeomNoL));
	float solarVisibility = SolarDiscVisibility(sunAltitude);
	float ambientCelestialShadow = mix(ambientMoonShadow, ambientSunShadow, solarVisibility);
	float ambientShadowed = mix(1.0 - FOXY_SHADOW_AMBIENT_DARKEN, 1.0, ambientCelestialShadow);
	float ambientShadowInfluence = mix(0.10, 1.0, smoothstep(-0.04, 0.16, sunAltitude));
	float ambientOcclusionFromCelestial = mix(1.0, ambientShadowed, ambientShadowInfluence);
	float ambientSkyVisibility = AmbientSkyVisibility(sunAltitude, skyLight);
	vec3 ambient = (vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor)) * ambientSkyVisibility * ambientOcclusionFromCelestial;
	vec3 ambientSss = vec3(0.0);
	#if FOXY_PBR == 1 && FOXY_PBR_SSS == 1
		if (material.sssAmount > 0.0 && foliageTransmissionMask > 0.0) {
			float foliageDirectTransmissionMask = foliageTransmissionMask * activeShadowCoverage;
			directSss += PbrThinSss(material, mainDayLightDir, pbrViewDirection, sunShadow, sunSpecularLight) * foliageDirectTransmissionMask;
			directSss += PbrThinSss(material, moonDir, pbrViewDirection, moonShadow, moonSpecularLight) * foliageDirectTransmissionMask;
			directSss *= mix(1.0, 0.62, rainStrength);
			ambientSss = PbrAmbientSss(material, ambient, skyLight) * foliageTransmissionMask;
			ambient = mix(ambient, ambient * (0.80 + 0.20 * skyLight), material.sssAmount * FOXY_PBR_SSS_INTENSITY * foliageTransmissionMask * 0.18);
		}
	#endif
	vec3 diffuseAlbedo = PbrDiffuseAlbedo(material);
	vec3 pbrDirectAdditive = diffuseAlbedo * directSss + directSpecular;
	vec3 surfaceEmission = PbrSurfaceEmission(material.albedo, material.emissionMask);
	// LabPBR emission replaces reflected light according to its mask.
	float reflectedLightWeight = 1.0 - Saturate(material.emissionMask);
	vec3 torch = TorchColor(blockLight);
	float underwaterLightMod = 1.0;
	float underwaterCausticBoost = 0.0;
	if (isEyeInWater == 1) {
		vec3 worldPosForWater = worldPosForLighting;
		vec3 sunWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, shadowDir));
		float waterDepth = waterDepthForLighting;
		float caustics = WaterCaustics(worldPosForWater, sunWorld, frameTimeCounter, waterDepth, waterDepth);
		float causticFade = smoothstep(0.012, 0.24, sunWorld.y) * smoothstep(0.02, 0.42, skyLight) * (1.0 - rainStrength * 0.62);
		causticFade *= 1.0 - smoothstep(54.0, 138.0, waterDepth);
		causticFade *= smoothstep(0.06, 0.48, sunGeomNoL);
		causticFade *= smoothstep(0.10, 0.78, sunShadow);
		underwaterCausticBoost = max(caustics - 1.0, 0.0) * causticFade;
		float visibility = exp(-max(length(surfaceViewPosition), 0.0) * (0.020 + FOXY_WATER_FOG * 0.055));
		vec3 waterAbsorption = mix(vec3(0.36, 0.62, 0.88), vec3(0.16, 0.36, 0.70), Saturate(1.0 - visibility));
		float waterAmount = Saturate(FOXY_WATER_UNDERWATER);
		float underwaterShadow = sunShadow;
		float directionalWater = smoothstep(0.015, 0.36, skyLight) * smoothstep(0.02, 0.30, sunWorld.y);
		vec3 underwaterSun = sunLightColor * (sunNoL * 1.05 + pow(sunNoL, 10.0) * 0.30) * underwaterShadow * directionalWater;
		float directionalMoonWater = smoothstep(0.015, 0.36, skyLight) * smoothstep(0.02, 0.30, moonAltitude);
		vec3 underwaterMoon = moonLightColor * (moonNoL * 1.02 + pow(moonNoL, 10.0) * 0.10) * moonShadow * directionalMoonWater;
		direct = mix(direct, underwaterSun + underwaterMoon + direct * 0.35, 0.78 * waterAmount);
		ambient *= mix(vec3(1.0), waterAbsorption, 0.34 * waterAmount);
		direct *= mix(vec3(1.0), waterAbsorption, 0.22 * waterAmount);
		float shadowDarken = mix(0.12, 1.0, ambientCelestialShadow);
		ambient *= mix(1.0, shadowDarken, 0.88 * waterAmount * smoothstep(0.04, 0.70, skyLight));
		direct *= mix(0.34, 1.0, visibility * 0.45 + 0.55);
		underwaterLightMod = mix(0.72, 1.0, visibility);
	}
	float noLightFloor = mix(0.00035, 0.0035, Saturate(blockLight * 1.80 + skyLight * 0.85));
	float underwaterDirectLightScale = isEyeInWater == 1 ? FOXY_WATER_UNDERWATER_DIRECT_LIGHT : 1.0;
	vec3 causticDirect = direct * underwaterCausticBoost * FOXY_WATER_CAUSTICS_BRIGHTNESS;
	vec3 removableDirectBeforeFog =
		pbrDirectAdditive * underwaterLightMod * underwaterDirectLightScale * reflectedLightWeight;
	#if FOXY_RAY_ACTIVE == 1
		vec3 ptMinimumAmbient = vec3(0.00045, 0.00050, 0.00062);
		#if FOXY_SSPT_MINIMUM_LIGHT == 1
			float ptIndoorFactor = 1.0 - smoothstep(0.10, 0.60, skyLight);
			vec3 ptAdaptiveFloor = mix(
				vec3(0.00055, 0.00062, 0.00074),
				vec3(0.0038, 0.0041, 0.0047),
				ptIndoorFactor
			);
			ptMinimumAmbient += ptAdaptiveFloor * max(FOXY_SSPT_MINIMUM_LIGHT_STRENGTH, 0.0);
		#endif
		vec3 baseLighting = isEyeInWater == 1
			? lightmapColor * 0.34 + ambient + ambientSss + direct * underwaterDirectLightScale + causticDirect + torch + vec3(noLightFloor)
			: direct + causticDirect + ptMinimumAmbient;
		removableDirectBeforeFog += diffuseAlbedo *
			(direct * underwaterDirectLightScale + causticDirect) *
			underwaterLightMod * reflectedLightWeight;
		#ifdef ENTITY_MODEL
			vec3 entityLightingFloor = (
				lightmapColor * 0.34 + ambient + ambientSss + torch + vec3(noLightFloor)
			) * 0.32;
			baseLighting = max(baseLighting, entityLightingFloor);
		#endif
	#else
		vec3 baseLighting = lightmapColor * 0.34 + ambient + ambientSss + direct * underwaterDirectLightScale + causticDirect + torch + vec3(noLightFloor);
		removableDirectBeforeFog += diffuseAlbedo *
			(direct * underwaterDirectLightScale + causticDirect) *
			underwaterLightMod * reflectedLightWeight;
	#endif
	vec3 lit = diffuseAlbedo * baseLighting * underwaterLightMod * reflectedLightWeight;
	lit += pbrDirectAdditive * underwaterLightMod * underwaterDirectLightScale * reflectedLightWeight + surfaceEmission + puddleEnvironmentReflection;
	vec3 litBeforeFog = lit;

	float sunRainScale = mix(1.0, 0.35, rainStrength);
	vec3 fogColor = FogColorFromClearSunColor(sunAltitude, rainStrength, rawSunLightColor / max(sunRainScale, 1.0e-4));
	float boundaryFar = SceneReach(far);
	vec2 boundaryFogWeights = SkyBoundaryFogWeights(surfaceWorldPosition, sunAltitude, boundaryFar);
	vec3 boundaryFogColor = fogColor;
	if (max(boundaryFogWeights.x, boundaryFogWeights.y) > 0.001) {
		boundaryFogColor = SkyBoundaryFogColor(colortex7, surfaceViewPosition, gbufferModelViewInverse);
	}
	vec3 directSurfaceTransmission = vec3(1.0);
	#if FOXY_VOLUMETRIC_LIGHT == 0
		lit = ApplyFogWithSurfaceTransmission(
			lit,
			fogColor,
			boundaryFogColor,
			boundaryFogWeights,
			surfaceViewPosition,
			surfaceWorldPosition + cameraPosition,
			cameraPosition,
			upDir,
			directSurfaceTransmission
		);
	#endif
	float eyeSkyLight = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
	vec3 litBeforePurkinje = lit;
	lit = ApplyPurkinjeVision(lit, sunAltitude, blockLight, skyLight, eyeSkyLight);
	#if FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
		vec3 removableDirectAfterFog = removableDirectBeforeFog * directSurfaceTransmission;
		vec3 litWithoutDirect = ApplyPurkinjeVision(
			max(litBeforePurkinje - removableDirectAfterFog, vec3(0.0)),
			sunAltitude,
			blockLight,
			skyLight,
			eyeSkyLight
		);
		vec4 directShadowOutput = DirectShadowPack(
			max(lit - litWithoutDirect, vec3(0.0)),
			activeShadow
		);
	#endif
	#if FOXY_VOXEL_GI_ACTIVE == 1
		#if FOXY_IRC_MODE == 0 && FOXY_RAY_MODE != FOXY_RAY_SSPT_VRTGI
		// Outside VRTGI, use the continuous pre-quantization lightmap.
		vec3 vrtgiFallbackIndirect = GbufferLitVrtgiFallbackIndirect(
			clamp(materialLmcoord, vec2(0.0), vec2(1.0)),
			normalize(mat3(gbufferModelViewInverse) * geometricNormalView),
			diffuseAlbedo,
			reflectedLightWeight
		);
			lit += vrtgiFallbackIndirect;
		#endif
	#endif
	gl_FragData[0] = vec4(EncodeSceneColor(lit), texel.a);
	#if FOXY_PT_GBUFFER_ACTIVE == 1
		gl_FragData[1] = ptSurfaceOutput;
		#if FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
			gl_FragData[2] = directShadowOutput;
		#endif
	#elif FOXY_DIRECT_SHADOW_BRIDGE_ACTIVE == 1
		gl_FragData[1] = directShadowOutput;
	#endif
}
