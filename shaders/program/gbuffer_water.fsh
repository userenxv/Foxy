#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/lighting.glsl"
#include "/lib/sky.glsl"
#include "/lib/shadow.glsl"
#include "/lib/celestial.glsl"
#include "/lib/water.glsl"
#include "/lib/rain.glsl"
#define FOXY_IMAGE_MAIN_WATER_PRODUCER_CURRENT
#include "/lib/contracts/water.glsl"
#include "/lib/contracts/material.glsl"
#include "/lib/transmission.glsl"

/* RENDERTARGETS: 0,2,13 */

#ifdef COLORWHEEL
uniform sampler2D gtexture;
#else
uniform sampler2D texture;
#endif
uniform sampler2D lightmap;
uniform sampler2D colortex7;
uniform sampler2D depthtex1;
uniform sampler2D shadowtex0;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform float rainStrength;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTimeCounter;
uniform int isEyeInWater;
uniform int frameCounter;
uniform ivec2 eyeBrightnessSmooth;

varying vec2 texcoord;
varying vec2 vertexLmcoord;
varying vec4 surfaceColor;
varying vec3 surfaceNormalView;
varying vec3 surfaceViewPosition;
varying vec3 surfaceWorldPosition;
varying vec4 vertexShadowClip;
varying float waterWaveHeight;
varying float isWater;
varying float isIce;
varying float vertexMaterialId;
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;

#include "/lib/sr.glsl"

float SafeDivisorWater(const in float x) {
	if (abs(x) < 1.0e-6) {
		return x < 0.0 ? -1.0e-6 : 1.0e-6;
	}
	return x;
}

vec3 ViewPosFromDepthWater(const in vec2 uv, const in float depth) {
	vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 view = gbufferProjectionInverse * clip;
	return view.xyz / SafeDivisorWater(view.w);
}

vec3 WaterDetailNormalView(const in vec3 baseNormalView, const in vec3 worldPos, const in float worldFootprint) {
	float aaReduction;
	return WaterDetailNormalViewShared(gbufferModelView, baseNormalView, worldPos, cameraPosition, frameTimeCounter, worldFootprint, aaReduction);
}

float WaterShadowVisibility(const in float NoL, const in vec3 normalView) {
	vec4 receiverShadowClip = vertexShadowClip;
	vec3 shadowNdc = receiverShadowClip.xyz / receiverShadowClip.w;
	vec2 waveOffset = normalView.xz * (0.0012 + FOXY_WATER_WAVE_STRENGTH * 0.0032);
	vec2 shadowClipXY = shadowNdc.xy + waveOffset;
	shadowNdc.xy = ShadowWarp(shadowClipXY);
	vec3 shadowCoord = shadowNdc * 0.5 + 0.5;
	if (shadowCoord.x <= 0.0 || shadowCoord.y <= 0.0 || shadowCoord.x >= 1.0 || shadowCoord.y >= 1.0 || shadowCoord.z <= 0.0 || shadowCoord.z >= 1.0) {
		return 1.0;
	}
	float coverageFade = ShadowSurfaceCoverageFade(shadowCoord.xy, length(surfaceViewPosition));
	if (coverageFade <= 0.0001) {
		return 1.0;
	}
	float bias = mix(0.0024, 0.00075, Saturate(NoL));
	float centerDepth = texture2D(shadowtex0, shadowCoord.xy).r;
	float center = ShadowCompareDepth(shadowCoord.z, centerDepth, bias);
	#if FOXY_SHADOW_FILTERING == 0
		float hardFloorVisibility = 1.0 - FOXY_SHADOW_STRENGTH * 0.78;
		return mix(1.0, mix(hardFloorVisibility, 1.0, center), coverageFade);
	#endif
	float contactGap = max(shadowCoord.z - bias - centerDepth, 0.0);
	float contactScale = mix(0.68, 1.0, smoothstep(0.00045, 0.0055 + FOXY_SHADOW_SOFTNESS * 0.0030, contactGap));
	float filterRadius = (1.10 + FOXY_SHADOW_SOFTNESS * 2.00) * mix(1.0, contactScale, 1.0 - center);
	float phase = ShadowTemporalPhase(gl_FragCoord.xy, frameCounter);
	float radialJitter = fract(phase * 1.41421356237 + 0.31);
	vec2 direction = ShadowDirection(fract(phase + 0.22360679775));
#if FOXY_WATER_OPT_FAST_SHADOW == 1
	const int waterShadowSamples = 4;
#else
	const int waterShadowSamples = 8;
#endif
	float visibility = 0.0;
	for (int i = 0; i < waterShadowSamples; i++) {
		direction = ShadowGoldenRotate(direction);
		float radius = ShadowDiskRadius(float(i), float(waterShadowSamples), radialJitter);
		vec2 sampleUv = clamp(ShadowSampleUv(shadowClipXY, direction * (filterRadius * radius)), vec2(0.001), vec2(0.999));
		float sampleDepth = texture2D(shadowtex0, sampleUv).r;
		visibility += ShadowCompareDepth(shadowCoord.z, sampleDepth, bias);
	}
	visibility /= float(waterShadowSamples);
	float floorVisibility = 1.0 - FOXY_SHADOW_STRENGTH * 0.78;
	return mix(1.0, mix(floorVisibility, 1.0, visibility), coverageFade);
}

void main() {
	#ifdef COLORWHEEL
		vec4 texel = texture2D(gtexture, texcoord);
	#else
		vec4 texel = texture2D(texture, texcoord);
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
	bool isGlass = TransmissionIsGlass(vertexMaterialId);
	if (!isGlass && texel.a <= 0.001) {
		discard;
	}
	if (isWater < 0.5) {
		vec3 baseColor = SrgbToLinear(texel.rgb);
		vec3 normalView = normalize(surfaceNormalView);
		vec3 upView = normalize(upPosition);
		vec3 sunView;
		vec3 moonView;
		StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, upView, sunView, moonView);
		vec3 shadowView = normalize(shadowLightPosition);
		float sunAltitude = vertexSunAltitude;
		float moonAltitude = vertexMoonAltitude;
		vec3 sunLightColor = vertexSunLightColor;
		vec3 moonLightColor = vertexMoonLightColor;
		float dither = Bayer16(gl_FragCoord.xy);
		vec2 ditheredLmcoord = Dither8Bit2(clamp(materialLmcoord, vec2(0.0), vec2(1.0)), dither);
		float skyLight = ditheredLmcoord.y;
		float blockLight = ditheredLmcoord.x;
		float sunNoL = max(dot(normalView, sunView), 0.0);
		float moonNoL = max(dot(normalView, moonView), 0.0);
		float sunShadow = 1.0;
		float moonShadow = 1.0;
		float shadowMatchesSun = smoothstep(0.05, 0.45, dot(shadowView, sunView));
		float shadowMatchesMoon = smoothstep(0.05, 0.45, dot(shadowView, moonView));
		vec2 directSourceWeights = CelestialShadowSourceWeights(shadowView, sunView, moonView);
		sunLightColor *= directSourceWeights.x * DirectCelestialVisibility(sunAltitude);
		moonLightColor *= directSourceWeights.y * DirectCelestialVisibility(moonAltitude);
		if (sunNoL > 0.002 && skyLight > 0.015 && sunAltitude > 0.0) {
			if (shadowMatchesSun > 0.001) {
				sunShadow = mix(1.0, WaterShadowVisibility(sunNoL, normalView), shadowMatchesSun);
			}
		}
		if (moonNoL > 0.002 && skyLight > 0.015 && moonAltitude > 0.0 && shadowMatchesMoon > 0.001) {
			moonShadow = mix(1.0, WaterShadowVisibility(moonNoL, normalView), shadowMatchesMoon);
		}
		vec3 lightmapColor = SrgbToLinear(texture2D(lightmap, ditheredLmcoord).rgb);
		float ambientSkyVisibility = AmbientSkyVisibility(sunAltitude, skyLight);
		vec3 ambientColor = (vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor)) * ambientSkyVisibility * 1.02;
		vec3 directColor = sunLightColor * (sunNoL * 0.78 + pow(sunNoL, 10.0) * 0.18) * sunShadow * skyLight;
		directColor += moonLightColor * (moonNoL * 0.82 + pow(moonNoL, 10.0) * 0.08) * moonShadow * skyLight;
		vec3 torchColor = TorchColor(blockLight) * 0.38;
		float noLightFloor = mix(0.00020, 0.0018, Saturate(blockLight * 1.70 + skyLight * 0.75));
		vec3 color = baseColor * (lightmapColor * 0.22 + ambientColor + directColor + torchColor + vec3(noLightFloor));
		float eyeSkyLight = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
		color = ApplyPurkinjeVision(color, sunAltitude, blockLight, skyLight, eyeSkyLight);
		float iceAlpha = mix(0.50, 0.70, Saturate(skyLight * 0.65 + blockLight * 0.25));
		float alpha = mix(texel.a, min(texel.a, iceAlpha), Saturate(isIce));
		// composite2 exclusively owns optical glass resolution.
		gl_FragData[0] = vec4(EncodeSceneColor(max(color, vec3(0.0))), isGlass ? 0.0 : alpha);
		gl_FragData[1] = isGlass
			? MaterialGlassPacket(TransmissionColor(vertexMaterialId), normalView)
			: vec4(0.0);
		gl_FragData[2] = vec4(0.0);
		return;
	}
		vec3 baseWater = vec3(0.010, 0.065, 0.082);
	vec3 baseNormalView = normalize(surfaceNormalView);
	vec3 baseNormalPlayer = normalize(mat3(gbufferModelViewInverse) * baseNormalView);
	vec2 waterSurfaceCoord = WaterSurfaceCoordPlayer(baseNormalPlayer, surfaceWorldPosition);
	float waterWorldFootprint = max(length(dFdx(waterSurfaceCoord)), length(dFdy(waterSurfaceCoord)));
	vec3 upView = normalize(upPosition);
	float waterNormalAaReduction;
	vec3 wavedNormalView = WaterDetailNormalViewShared(gbufferModelView, baseNormalView, surfaceWorldPosition, cameraPosition, frameTimeCounter, waterWorldFootprint, waterNormalAaReduction);
	float rainFacing = smoothstep(0.55, 0.92, max(baseNormalPlayer.y, 0.0));
	float rainRippleExposure = rainStrength * rainFacing * smoothstep(0.82, 0.985, Saturate(materialLmcoord.y));
	if (rainRippleExposure > 0.001) {
		vec3 wavedNormalWorld = normalize(mat3(gbufferModelViewInverse) * wavedNormalView);
		wavedNormalWorld = RainPerturbWorldNormal(
			wavedNormalWorld,
			surfaceWorldPosition.xz,
			frameTimeCounter,
			rainRippleExposure
		);
		wavedNormalView = normalize(mat3(gbufferModelView) * wavedNormalWorld);
	}
	vec3 normalView = wavedNormalView;
	if (isEyeInWater == 1) {
		normalView = normalize(mix(baseNormalView, wavedNormalView, 0.42));
	}
	float surfaceViewDistance = length(surfaceViewPosition);
	vec3 incidentView = surfaceViewPosition / max(surfaceViewDistance, 1.0e-6);
	vec3 viewDir = -incidentView;
	vec3 sunView;
	vec3 moonView;
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, upView, sunView, moonView);
	vec3 shadowView = normalize(shadowLightPosition);

	float sunAltitude = vertexSunAltitude;
	float moonAltitude = vertexMoonAltitude;
	float solarVisibility = SolarDiscVisibility(sunAltitude);
	vec3 sunLightColor = vertexSunLightColor;
	vec3 moonLightColor = vertexMoonLightColor;
	float dither = Bayer16(gl_FragCoord.xy);
	vec2 ditheredLmcoord = Dither8Bit2(clamp(materialLmcoord, vec2(0.0), vec2(1.0)), dither);
	float skyLight = ditheredLmcoord.y;
	float blockLight = ditheredLmcoord.x;
	float sunNoL = max(dot(normalView, sunView), 0.0);
	float moonNoL = max(dot(normalView, moonView), 0.0);
	float sunShadow = 1.0;
	float moonShadow = 1.0;
	float shadowMatchesSun = smoothstep(0.05, 0.45, dot(shadowView, sunView));
	float shadowMatchesMoon = smoothstep(0.05, 0.45, dot(shadowView, moonView));
	vec2 directSourceWeights = CelestialShadowSourceWeights(shadowView, sunView, moonView);
	float waterSolarIrradiance = WaterSolarIrradiance(vertexSunLightColor, sunAltitude) * directSourceWeights.x;
	float waterLunarIrradiance = WaterLunarIrradiance(vertexMoonLightColor, moonAltitude) * directSourceWeights.y;
	sunLightColor *= directSourceWeights.x * DirectCelestialVisibility(sunAltitude);
	moonLightColor *= directSourceWeights.y * DirectCelestialVisibility(moonAltitude);
	if (sunNoL > 0.002 && skyLight > 0.015 && sunAltitude > 0.0) {
		if (shadowMatchesSun > 0.001) {
			sunShadow = mix(1.0, WaterShadowVisibility(sunNoL, normalView), shadowMatchesSun);
		}
	}
	if (moonNoL > 0.002 && skyLight > 0.015 && moonAltitude > 0.0 && shadowMatchesMoon > 0.001) {
		moonShadow = mix(1.0, WaterShadowVisibility(moonNoL, normalView), shadowMatchesMoon);
	}
	float NoV = max(dot(normalView, viewDir), 0.0);
	vec3 lightmapColor = SrgbToLinear(texture2D(lightmap, ditheredLmcoord).rgb);
	float activeCelestialShadow = mix(moonShadow, sunShadow, solarVisibility);
	float ambientShadowed = mix(1.0 - FOXY_SHADOW_AMBIENT_DARKEN * 0.82, 1.0, activeCelestialShadow);
	float ambientShadowInfluence = mix(0.10, 1.0, smoothstep(-0.04, 0.16, sunAltitude));
	float ambientOcclusionFromCelestial = mix(1.0, ambientShadowed, ambientShadowInfluence);
	float ambientSkyVisibility = AmbientSkyVisibility(sunAltitude, skyLight);
	vec3 ambientColor = (vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor)) * ambientSkyVisibility * 1.10 * ambientOcclusionFromCelestial;
	vec3 directColor = sunLightColor * (sunNoL * 0.78 + pow(sunNoL, 12.0) * 0.28) * sunShadow * skyLight;
	directColor += moonLightColor * (moonNoL * 0.88 + pow(moonNoL, 12.0) * 0.12) * moonShadow * skyLight;
	vec3 torchColor = TorchColor(blockLight) * 0.46;
	float noLightFloor = mix(0.00015, 0.0014, Saturate(blockLight * 1.55 + skyLight * 0.68));
	vec3 environmentLight = lightmapColor * 0.16 + ambientColor + directColor + torchColor + vec3(noLightFloor);
	float environmentLuma = Luma(environmentLight);
	float darkWater = smoothstep(0.020, 0.18, environmentLuma + blockLight * 0.10 + skyLight * 0.055);
	float waveRelief = Saturate(waterWaveHeight * 1.65 + 0.50);
	float troughShade = mix(0.70, 1.12, waveRelief);
	troughShade *= mix(0.78, 1.0, darkWater);
	float viewDepth = max(-surfaceViewPosition.z, 0.0);
	float waterFog = Saturate(FOXY_WATER_FOG);
	float waterDensity = FOXY_WATER_DENSITY;
	float surfaceDistance = max(viewDepth * 0.040, 0.0);
	float depthFog = 1.0 - exp(-surfaceDistance * (0.20 + waterFog * 0.30) * waterDensity);
	float grazingFog = pow(1.0 - NoV, 2.0) * 0.42;
	float waveFoam = Saturate(abs(waterWaveHeight) * 0.34) * FOXY_WATER_WAVE_STRENGTH;
	float twilight = TwilightFactor(sunAltitude);
	float sunRainScale = mix(1.0, 0.35, rainStrength);
	vec3 timeFog = FogColorFromClearSunColor(sunAltitude, rainStrength, sunLightColor / max(sunRainScale, 1.0e-4));
	vec3 activeDirectColor = sunLightColor + moonLightColor;
	float activeDirectAmount = sunNoL * waterSolarIrradiance * skyLight * sunShadow;
	activeDirectAmount += moonNoL * waterLunarIrradiance * skyLight * moonShadow;
	float surfaceOpticalDepth = surfaceDistance * mix(0.55, 0.90, waterFog) * mix(1.0, 2.25, grazingFog);
	vec3 waterTransmittance = WaterTransmittance(surfaceOpticalDepth, waterFog);
	vec3 scatterColor = WaterScatterColor(ambientColor, activeDirectColor, activeDirectAmount, skyLight, rainStrength);
	vec3 distanceFogColor = mix(scatterColor, timeFog * vec3(0.22, 0.28, 0.30), twilight * 0.22);
	vec3 litBase = baseWater * environmentLight * vec3(0.56, 0.70, 0.78) * troughShade;
	vec3 waterVolume = litBase * waterTransmittance + distanceFogColor * (vec3(1.0) - waterTransmittance) * (0.72 + environmentLuma * 0.52);
	waterVolume += scatterColor * waveFoam * (0.18 + activeCelestialShadow * 0.20);
	vec3 litWater = mix(waterVolume, distanceFogColor, Saturate(depthFog * 0.30 + grazingFog * waterFog * 0.42));
	vec3 color = litWater;
	float grazingOpacity = pow(1.0 - NoV, 2.35);
	float visibleTransmittance = max(max(waterTransmittance.r, waterTransmittance.g), waterTransmittance.b);
	float opticalOpacity = Saturate(1.0 - visibleTransmittance);
	float alphaShape = Saturate(opticalOpacity * 0.42 + depthFog * waterFog * 0.18 + grazingFog * waterFog * 0.62);
	float alpha = mix(0.14, 0.52, alphaShape);
	alpha = mix(alpha, 0.985, grazingOpacity);
	alpha = max(alpha, mix(0.12, 0.26, waterFog));
	float waterSunGlintSignal = 0.0;
	if (FOXY_WATER_SUN_GLINT > 0.001) {
		vec3 sunGlint = WaterSunGlint(
			normalView,
			viewDir,
			sunView,
			sunLightColor,
			sunShadow,
			skyLight,
			solarVisibility,
			rainStrength,
			waterWaveHeight,
			waterNormalAaReduction,
			surfaceWorldPosition,
			frameTimeCounter
		);
		// Surface reflection stays outside the transmissive payload.
		waterSunGlintSignal = Luma(sunGlint) / max(Luma(max(sunLightColor, vec3(0.0))), 0.08);
	}

	vec2 sceneResourceUv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
	vec2 viewUv = SrViewUvFromSceneResourceUv(sceneResourceUv);
	float backDepthRaw = texture2D(depthtex1, sceneResourceUv).r;
	float backValid = 1.0 - step(0.99999, backDepthRaw);
	vec3 backViewPos = ViewPosFromDepthWater(viewUv, backDepthRaw);
	float waterPath = max(length(backViewPos) - surfaceViewDistance, 0.0) * backValid;
	float eyeSkyLight = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
	color = ApplyPurkinjeVision(color, sunAltitude, blockLight, skyLight, eyeSkyLight);
	vec2 producerUv = ProducerScreenUv(vec2(viewWidth, viewHeight));
	StoreMainWaterProducer(
		producerUv,
		WaterProducerPack(
			surfaceViewDistance,
			baseNormalView,
			surfaceViewDistance + waterPath,
			FOXY_ENDPOINT_OWNER_MAIN_WATER
		)
	);

	gl_FragData[0] = vec4(0.0);
	gl_FragData[1] = MaterialWaterPacket(wavedNormalView, waterNormalAaReduction, waterSunGlintSignal);
	gl_FragData[2] = WaterSurfacePack(EncodeSceneColor(max(color, vec3(0.0))), alpha);
}
