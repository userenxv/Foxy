#define FOXY_FRAME_WEATHER_READER
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
#include "/lib/seasons.glsl"
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
uniform mat4 shadowModelViewInverse;
uniform mat4 shadowProjection;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform float far;
uniform float rainStrength;
#include "/lib/blackhole_sky.glsl"
uniform float waterEnteredAltitude;
uniform int isEyeInWater;
uniform int frameCounter;
uniform ivec2 eyeBrightnessSmooth;
uniform int heldItemId;
uniform int heldBlockLightValue;
uniform int heldItemId2;
uniform int heldBlockLightValue2;
uniform int entityId;

varying vec2 texcoord;
varying vec2 spriteUv;
varying vec2 spriteHalfSize;
varying vec2 vertexLmcoord;
varying vec4 surfaceColor;
varying vec3 surfaceNormalView;
varying vec3 surfaceViewPosition;
varying vec3 surfaceWorldPosition;
varying float vertexMaterialId;
varying float vertexEmissionLevel;
varying float vertexSubLevel;
#if FOXY_FRAME_CELESTIAL_ACTIVE == 1
#include "/lib/contracts/frame_celestial.glsl"
#define vertexSunLightColor frameSunLight.rgb
#define vertexMoonLightColor frameMoonLight.rgb
#define vertexSkyAmbientColor frameSkyAmbient.rgb
#define vertexSunView frameSunView.xyz
#define vertexMoonView frameMoonView.xyz
#define vertexUpView frameUpView.xyz
#define vertexShadowSelection frameShadowSelection.xy
#define vertexSunAltitude frameSunView.w
#define vertexMoonAltitude frameMoonView.w
#else
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying vec3 vertexSunView;
varying vec3 vertexMoonView;
varying vec3 vertexUpView;
varying vec2 vertexShadowSelection;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;
#endif

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

vec3 HandheldLightContribution(
	const in vec3 surfacePositionView,
	const in vec3 surfaceNormalView
) {
	#if FOXY_HANDHELD_LIGHT == 1
		float range = max(FOXY_HANDHELD_LIGHT_RANGE, 0.1);
		vec3 contribution = vec3(0.0);
		if (heldBlockLightValue > 0) {
			vec3 toLight = vec3(0.38, -0.24, -0.72) - surfacePositionView;
			float distanceToLight = length(toLight);
			vec3 lightDirection = toLight / max(distanceToLight, 1.0e-4);
			float falloff = pow(Saturate(1.0 - distanceToLight / range), 2.0);
			float level = Saturate(float(heldBlockLightValue) / 15.0);
			contribution += HeldItemLightColor(heldItemId, level) * FOXY_HANDHELD_LIGHT_STRENGTH * falloff * max(dot(surfaceNormalView, lightDirection), 0.0);
		}
		if (heldBlockLightValue2 > 0) {
			vec3 toLight = vec3(-0.38, -0.24, -0.72) - surfacePositionView;
			float distanceToLight = length(toLight);
			vec3 lightDirection = toLight / max(distanceToLight, 1.0e-4);
			float falloff = pow(Saturate(1.0 - distanceToLight / range), 2.0);
			float level = Saturate(float(heldBlockLightValue2) / 15.0);
			contribution += HeldItemLightColor(heldItemId2, level) * FOXY_HANDHELD_LIGHT_STRENGTH * falloff * max(dot(surfaceNormalView, lightDirection), 0.0);
		}
		return contribution;
	#else
		return vec3(0.0);
	#endif
}

#include "/features/lighting/gbuffer_shadow.glsl"

PbrMaterial BuildLitPbrMaterial(
	const in vec3 albedo,
	const in vec3 normalView,
	const in vec2 materialUv,
	const in mat2 materialGradients
) {
	PbrMaterial material = PbrDefaultMaterial(albedo, normalView);
	#if FOXY_PBR == 1
		PbrApplyFallbackMaterial(material, vertexMaterialId);
		PbrApplyBuiltinSurfaceDetail(material, vertexMaterialId, albedo, normalView, materialUv);
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
		if (FoliageIsLeaf(vertexMaterialId)) {
			material.roughness = max(
				material.roughness,
				PbrAlphaFromPerceptualRoughness(0.70)
			);
			material.f0 = max(material.f0, vec3(0.045));
			material.specularWeight = max(material.specularWeight, 0.82);
			material.sssAmount = max(material.sssAmount, 0.85);
			material.sheenAmount = max(material.sheenAmount, 0.35);
		}
	#endif
	return material;
}

#if FOXY_PBR_NORMAL_MAPS == 1 && !defined(TERRAIN)

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
		#if defined(TERRAIN)
			texel.rgb = SeasonApplyFoliageTint(texel.rgb, vertexMaterialId, surfaceColor.rgb);
		#endif
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

	float directSkyVisibility = smoothstep(0.045, 0.155, skyLight);
	#if defined(FOXY_DIM_END)
		directSkyVisibility = 1.0;
	#endif
	float underwaterView = isEyeInWater == 1 ? 1.0 : 0.0;
	vec3 worldPosForLighting = surfaceWorldPosition + cameraPosition;
	float waterDepthForLighting = max(waterEnteredAltitude - worldPosForLighting.y, 0.0) * underwaterView;
	float foliageTransmissionMask = 0.0;
	if (FoliageIsLeaf(vertexMaterialId) || PbrIdInRange(vertexMaterialId, 10101.0, 10103.0)) {
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
	#if defined(FOXY_DIM_END)
		activeShadowNeed = max(
			activeShadowNeed,
			smoothstep(0.002, 0.050, mix(moonGeomNoL, sunGeomNoL, useSunShadow))
		);
	#endif
	float activeShadow = 1.0;
	float activeShadowCoverage = 0.0;
	// Cloud shadow attenuates the direct light only, never the ambient term below
	// (through ambientCelestialShadow): a cloud blocks the sun, not the sky dome.
	// Declared here because it is consumed far below, outside this branch, and
	// stays 1.0 whenever no shadow is being evaluated.
	float cloudShadow = 1.0;
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
		bool sampleTransmission = isEyeInWater == 0 && !FoliageIsLeaf(vertexMaterialId);
		vec4 evaluatedTransmission = ShadowEvaluate(shadowReceiver, activeShadowAltitude, sampleTransmission, evaluatedShadow);
		activeShadow = mix(1.0, evaluatedShadow, activeShadowMatch);
		#if FOXY_CLOUDS == 1
			if (activeShadow > 0.0) {
				vec3 activeShadowDir = mix(moonDir, sunDir, useSunShadow);
				vec3 activeShadowWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, activeShadowDir));
				cloudShadow = Saturate(CloudShadowVisibilityCached(colortex7, worldPosForLighting, cameraPosition, activeShadowWorld, frameTimeCounter + WeatherWindDrift(FOXY_WIND_CLOUDS), rainStrength));
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
	float resolvedEmissionMask = PbrResolvedEmissionMask(
		material,
		vertexMaterialId,
		vertexEmissionLevel
	);
	#ifdef HANDHELD_MATERIAL
		float heldLightValue = max(float(heldBlockLightValue), float(heldBlockLightValue2));
		float handheldFullbright = step(0.985, blockLight) * step(0.985, skyLight) * step(0.5, heldLightValue);
		resolvedEmissionMask = max(resolvedEmissionMask, handheldFullbright);
	#endif
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

bool ptHasAuthoredEmission = material.emissionMask > 0.003;
		bool ptFallbackEmitter = vertexEmissionLevel > 0.5 && !ptHasAuthoredEmission;
		bool ptEmissiveTexel = ptHasAuthoredEmission || ptFallbackEmitter;
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

		vec3 ptDiffuseAlbedo = PbrDiffuseAlbedo(material);
		vec3 ptStoredEmission = PbrResolvedSsptEmission(
			material,
			vertexMaterialId,
			vertexEmissionLevel,
			resolvedEmissionMask
		);
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
	#if FOXY_SINGLE_LIGHT_BRDF == 1 && FOXY_FRAME_CELESTIAL_ACTIVE == 1 && !defined(FOXY_DIM_END)
		// Frame cache stores step() exactly: the other light's energy is zero.
		// Select one BRDF input set rather than carrying two inlined call sites.
		vec3 activePbrDirection = useSunShadow > 0.5 ? mainDayLightDir : moonDir;
		vec3 activePbrColor = useSunShadow > 0.5 ? sunLightColor : moonLightColor;
		float activePbrVisibility = useSunShadow > 0.5 ? sunShadow : moonShadow;
	#endif
	bool leafSurface = FoliageIsLeaf(vertexMaterialId) && foliageTransmissionMask > 0.001;
	vec3 direct = leafSurface
		? vec3(0.0)
		: sunLightColor * sunWrap * sunShadow * skyLight * directSkyVisibility * cloudShadow;
	direct += moonLightColor * (moonNoL * 1.03 + pow(moonNoL, 8.0) * 0.08) * moonShadow * skyLight * directSkyVisibility * cloudShadow;
	#if FOXY_LEAF_TRANSMISSION_ENABLED == 1
		if (leafSurface) {
			float leafSunMask = FoliageSoftSunMask(texel.a, geometricNormalView, mainDayLightDir);
			leafSunMask *= ShadowDistanceFade(length(surfaceViewPosition));
			vec3 leafSunTint = vec3(1.0, 0.965, 0.84);
			direct += leafSunTint * rawSunLightColor * leafSunMask * sunShadow *
				skyLight * directSkyVisibility * FOXY_LEAF_SOFT_LIGHT_STRENGTH_ACTIVE *
				(0.72 + 0.28 * smoothstep(0.05, 0.45, skyLight));
		}
	#endif
	#if defined(FOXY_DIM_END)
		float endSunNoL = max(dot(geometricNormalView, vertexSunView), 0.0);
		vec3 endKeyTransmission = mix(moonTransmission, sunTransmission, useSunShadow);
		direct = ColorTemperatureTint(EndKeyLightTemperature(frameTimeCounter)) * 2.10 *
			endSunNoL * mix(0.35, 1.0, skyLight) * sunShadow *
			endKeyTransmission *
			EndKeyLightFlux(frameTimeCounter);
	#endif
	vec3 directSpecular = vec3(0.0);
	vec3 directSss = vec3(0.0);
	#if FOXY_PBR == 1 && FOXY_PBR_SSS == 1
		if (PbrIdInRange(vertexMaterialId, 10101.0, 10103.0) && foliageTransmissionMask > 0.001) {
			float plantMask = foliageTransmissionMask * ShadowDistanceFade(length(surfaceViewPosition));
			#if FOXY_SINGLE_LIGHT_BRDF == 1 && FOXY_FRAME_CELESTIAL_ACTIVE == 1 && !defined(FOXY_DIM_END)
				vec3 plantActive = PbrThinSss(material, activePbrDirection, pbrViewDirection,
					activePbrVisibility, activePbrColor * cloudShadow);
				directSss = plantActive * plantMask * skyLight * directSkyVisibility * 1.35;
			#else
			vec3 plantSun = PbrThinSss(material, mainDayLightDir, pbrViewDirection,
				sunShadow, sunLightColor * cloudShadow);
			vec3 plantMoon = PbrThinSss(material, moonDir, pbrViewDirection,
				moonShadow, moonLightColor * cloudShadow);
			directSss = (plantSun + plantMoon) * plantMask * skyLight * directSkyVisibility * 1.35;
			#endif
		}
	#endif
	#if FOXY_PBR == 1
		vec3 sunSpecularLight = vec3(0.0);
		vec3 moonSpecularLight = vec3(0.0);
		sunSpecularLight = sunLightColor * skyLight * directSkyVisibility * cloudShadow;
		moonSpecularLight = moonLightColor * skyLight * directSkyVisibility * cloudShadow;
		#if defined(FOXY_DIM_END)
			sunSpecularLight = ColorTemperatureTint(EndKeyLightTemperature(frameTimeCounter)) * 2.10 *
				mix(0.35, 1.0, skyLight) * directSkyVisibility *
				endKeyTransmission *
				EndKeyLightFlux(frameTimeCounter);
			directSpecular += PbrDirectSpecular(
				material,
				vertexSunView,
				pbrViewDirection,
				sunShadow,
				sunSpecularLight
			);
		#else
			#if FOXY_SINGLE_LIGHT_BRDF == 1 && FOXY_FRAME_CELESTIAL_ACTIVE == 1
				vec3 activeSpecularLight = activePbrColor * skyLight * directSkyVisibility * cloudShadow;
				directSpecular = PbrDirectSpecular(material, activePbrDirection, pbrViewDirection,
					activePbrVisibility, activeSpecularLight);
			#else
			directSpecular += PbrDirectSpecular(material, mainDayLightDir, pbrViewDirection, sunShadow, sunSpecularLight);
			directSpecular += PbrDirectSpecular(material, moonDir, pbrViewDirection, moonShadow, moonSpecularLight);
			#endif
		#endif
		directSpecular *= mix(1.0, 0.72, rainStrength);
	#endif
	float ambientSunShadow = mix(1.0, sunShadow, smoothstep(0.015, 0.18, sunGeomNoL));
	float ambientMoonShadow = mix(1.0, moonShadow, smoothstep(0.015, 0.18, moonGeomNoL));
	float solarVisibility = SolarDiscVisibility(sunAltitude);
	float ambientShadowSource = max(solarVisibility, TwilightFactor(sunAltitude));
	float ambientCelestialShadow = mix(ambientMoonShadow, ambientSunShadow, ambientShadowSource);
	float ambientShadowed = mix(1.0 - FOXY_SHADOW_AMBIENT_DARKEN, 1.0, ambientCelestialShadow);
	float ambientShadowInfluence = mix(0.10, 1.0, smoothstep(-0.04, 0.16, sunAltitude));
	float ambientOcclusionFromCelestial = mix(1.0, ambientShadowed, ambientShadowInfluence);
	#if defined(FOXY_DIM_NETHER) || defined(FOXY_DIM_END)
		#if FOXY_RAY_ACTIVE == 1
			float ambientSkyVisibility = AmbientSkyVisibility(sunAltitude, skyLight);
			vec3 ambient = (vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor)) * ambientSkyVisibility * ambientOcclusionFromCelestial;
		#else
			// These dimensions have no skylight; AO still receives their base ambient.
			vec3 ambient = vertexSkyAmbientColor;
		#endif
	#else
		float ambientSkyVisibility = AmbientSkyVisibility(sunAltitude, skyLight);
		vec3 ambient = (vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor)) * ambientSkyVisibility * ambientOcclusionFromCelestial;
	#endif
	vec3 ambientSss = vec3(0.0);
	vec3 diffuseAlbedo = PbrDiffuseAlbedo(material);
	vec3 pbrDirectAdditive = diffuseAlbedo * directSss + directSpecular;
	#if FOXY_VOXEL_DDA_HARD_SHADOW == 1 && FOXY_VOXEL_TRACING == 1
		direct *= 2.0;
		pbrDirectAdditive *= 2.0;
	#endif
	vec3 surfaceEmission = PbrResolvedSurfaceEmission(
		material,
		vertexMaterialId,
		vertexEmissionLevel,
		resolvedEmissionMask
	);

	float reflectedLightWeight = 1.0 - resolvedEmissionMask;
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
		vec3 underwaterSun = sunLightColor * (sunNoL * 1.05 + pow(sunNoL, 10.0) * 0.30) * underwaterShadow * directionalWater * cloudShadow;
		float directionalMoonWater = smoothstep(0.015, 0.36, skyLight) * smoothstep(0.02, 0.30, moonAltitude);
		vec3 underwaterMoon = moonLightColor * (moonNoL * 1.02 + pow(moonNoL, 10.0) * 0.10) * moonShadow * directionalMoonWater * cloudShadow;
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
	vec3 handheldLight = HandheldLightContribution(
		surfaceViewPosition,
		normalView
	);
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
			? ambient + ambientSss + direct * underwaterDirectLightScale + causticDirect + torch + vec3(noLightFloor)
			: direct + causticDirect + ptMinimumAmbient;
		if (vertexSubLevel > 0.5) {
			baseLighting = max(
				baseLighting,
				(ambient + ambientSss + torch + vec3(noLightFloor)) * 0.32
			);
		}
		removableDirectBeforeFog += diffuseAlbedo *
			(direct * underwaterDirectLightScale + causticDirect) *
			underwaterLightMod * reflectedLightWeight;
		#ifndef TERRAIN
			#if FOXY_ENTITY_BASE_LIGHT == 1
				vec3 entityLightingFloor = (
					ambient + ambientSss + torch + vec3(noLightFloor)
				) * 0.32;
				baseLighting = max(baseLighting, entityLightingFloor);
			#endif
		#endif
	#else
		vec3 baseLighting = ambient + ambientSss + direct * underwaterDirectLightScale + causticDirect + torch + vec3(noLightFloor);
		removableDirectBeforeFog += diffuseAlbedo *
			(direct * underwaterDirectLightScale + causticDirect) *
			underwaterLightMod * reflectedLightWeight;
	#endif
	baseLighting += handheldLight;
	vec3 lit = diffuseAlbedo * baseLighting * underwaterLightMod * reflectedLightWeight;
	lit += pbrDirectAdditive * underwaterLightMod * underwaterDirectLightScale * reflectedLightWeight + surfaceEmission;
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
		#if FOXY_IRC_MODE == 0 && FOXY_RAY_MODE != FOXY_RAY_SSPT_VRTGI && FOXY_RAY_MODE != FOXY_RAY_IRC_SSPT

		vec3 vrtgiFallbackIndirect = GbufferLitVrtgiFallbackIndirect(
			clamp(materialLmcoord, vec2(0.0), vec2(1.0)),
			normalize(mat3(gbufferModelViewInverse) * geometricNormalView),
			diffuseAlbedo,
			reflectedLightWeight
		);
			lit += vrtgiFallbackIndirect;
	if (vertexSubLevel > 0.5) lit -= vrtgiFallbackIndirect;
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
