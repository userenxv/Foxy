#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/celestial.glsl"
#include "/lib/lighting.glsl"
#include "/lib/sky.glsl"
#include "/lib/water.glsl"
#define FOXY_IMAGE_LOD_WATER_PRODUCER_CURRENT
#include "/lib/contracts/water.glsl"
#include "/lib/contracts/material.glsl"

/* RENDERTARGETS: 0,2,13 */

uniform sampler2D lightmap;
uniform sampler2D colortex7;
uniform sampler2D depthtex0;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 shadowLightPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform float frameTimeCounter;
uniform float rainStrength;
uniform float far;
uniform float viewWidth;
uniform float viewHeight;
uniform ivec2 eyeBrightnessSmooth;

in vec4 dhWaterColor;
in vec2 dhWaterLightmap;
in vec3 dhWaterNormalView;
in vec3 dhWaterViewPos;
in vec3 dhWaterPlayerPos;
flat in float dhIsWater;

#include "/lib/sr.glsl"

void main() {
	vec2 sceneResourceUv = gl_FragCoord.xy / vec2(viewWidth, viewHeight);
	vec2 viewUv = SrViewUvFromSceneResourceUv(sceneResourceUv);
	float mainDepthRaw = texture2D(depthtex0, sceneResourceUv).r;
	if (mainDepthRaw < 0.99999) {
		vec4 mainClip = vec4(viewUv * 2.0 - 1.0, mainDepthRaw * 2.0 - 1.0, 1.0);
		vec4 mainViewHomogeneous = gbufferProjectionInverse * mainClip;
		float mainViewW = abs(mainViewHomogeneous.w) < 1.0e-6 ? 1.0e-6 : mainViewHomogeneous.w;
		float mainViewDepth = -(mainViewHomogeneous.z / mainViewW);
		float dhWaterViewDepth = max(-dhWaterViewPos.z, 0.0);
		if (mainViewDepth <= dhWaterViewDepth + 0.25) {
			discard;
		}
	}

	float viewDistance = length(dhWaterViewPos);

	vec3 upView = normalize(upPosition);
	vec3 baseNormalView = normalize(dhWaterNormalView);
	vec3 normalView = baseNormalView;
	float normalAaReduction = 0.0;
	if (dhIsWater > 0.5) {
		vec3 waterWorldPos = dhWaterPlayerPos + cameraPosition;
		vec3 baseNormalPlayer = normalize(mat3(gbufferModelViewInverse) * baseNormalView);
		vec2 waterSurfaceCoord = WaterSurfaceCoordPlayer(baseNormalPlayer, waterWorldPos);
		float footprint = max(length(dFdx(waterSurfaceCoord)), length(dFdy(waterSurfaceCoord)));
		normalView = WaterDetailNormalViewShared(gbufferModelView, baseNormalView, waterWorldPos, cameraPosition, frameTimeCounter, footprint, normalAaReduction);
		float backDepth = BackendLodSolidRaw(sceneResourceUv);
		float backValid = 1.0 - step(0.99999, backDepth);
		float waterPath = 0.0;
		if (backValid > 0.5) {
			vec3 backViewPosition = BackendLodViewPosition(viewUv, backDepth);
			waterPath = max(length(backViewPosition) - viewDistance, 0.0);
		}
		vec3 sunView;
		vec3 moonView;
		StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, upView, sunView, moonView);
		float sunAltitude = dot(sunView, upView);
		float moonAltitude = dot(moonView, upView);
		vec3 sunLightColor = SunColor(sunAltitude, rainStrength);
		vec3 moonLightColor = MoonColor(moonAltitude, rainStrength);
		vec2 directSourceWeights = CelestialShadowSourceWeights(normalize(shadowLightPosition), sunView, moonView);
		float waterSolarIrradiance = WaterSolarIrradiance(sunLightColor, sunAltitude) * directSourceWeights.x;
		float waterLunarIrradiance = WaterLunarIrradiance(moonLightColor, moonAltitude) * directSourceWeights.y;
		vec3 directSunLightColor = sunLightColor * directSourceWeights.x * DirectCelestialVisibility(sunAltitude);
		vec3 directMoonLightColor = moonLightColor * directSourceWeights.y * DirectCelestialVisibility(moonAltitude);
		vec3 skyAmbientColor = SkyAmbientColor(sunAltitude, rainStrength);
		vec2 lmcoord = Dither8Bit2(dhWaterLightmap, Bayer16(gl_FragCoord.xy));
		float blockLight = lmcoord.x;
		float skyLight = lmcoord.y;
		float sunNoL = max(dot(normalView, sunView), 0.0);
		float moonNoL = max(dot(normalView, moonView), 0.0);
		vec3 directColor = directSunLightColor * (sunNoL * 0.78 + pow(sunNoL, 12.0) * 0.28) * skyLight;
		directColor += directMoonLightColor * (moonNoL * 0.88 + pow(moonNoL, 12.0) * 0.12) * skyLight;
		vec3 ambientColor = (skyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor)) * AmbientSkyVisibility(sunAltitude, skyLight) * 1.10;
		vec3 lightmapColor = SrgbToLinear(texture2D(lightmap, lmcoord).rgb);
		float noLightFloor = mix(0.00015, 0.0014, Saturate(blockLight * 1.55 + skyLight * 0.68));
		vec3 environmentLight = lightmapColor * 0.16 + ambientColor + directColor + TorchColor(blockLight) * 0.46 + vec3(noLightFloor);
		float environmentLuma = Luma(environmentLight);

		vec3 incidentView = dhWaterViewPos / max(viewDistance, 1.0e-6);
		float noV = max(dot(normalView, -incidentView), 0.0);
		float grazingFog = pow(1.0 - noV, 2.0) * 0.42;
		float waterFog = Saturate(FOXY_WATER_FOG);
		float surfaceDistance = max(-dhWaterViewPos.z * 0.040, 0.0);
		float depthFog = 1.0 - exp(-surfaceDistance * (0.20 + waterFog * 0.30) * FOXY_WATER_DENSITY);
		vec3 waterTransmittance = WaterTransmittance(surfaceDistance * mix(0.55, 0.90, waterFog) * mix(1.0, 2.25, grazingFog), waterFog);
		float solarVisibility = SolarDiscVisibility(sunAltitude);
		vec3 activeDirectColor = directSunLightColor + directMoonLightColor;
		float activeDirectAmount = (sunNoL * waterSolarIrradiance + moonNoL * waterLunarIrradiance) * skyLight;
		vec3 scatterColor = WaterScatterColor(ambientColor, activeDirectColor, activeDirectAmount, skyLight, rainStrength);
		float twilight = TwilightFactor(sunAltitude);
		float sunRainScale = mix(1.0, 0.35, rainStrength);
		vec3 timeFog = FogColorFromClearSunColor(sunAltitude, rainStrength, sunLightColor / max(sunRainScale, 1.0e-4));
		vec3 distanceFogColor = mix(scatterColor, timeFog * vec3(0.22, 0.28, 0.30), twilight * 0.22);
		float darkWater = smoothstep(0.020, 0.18, environmentLuma + blockLight * 0.10 + skyLight * 0.055);
		float troughShade = mix(0.78, 1.0, darkWater) * 0.91;
		vec3 litBase = vec3(0.010, 0.065, 0.082) * environmentLight * vec3(0.56, 0.70, 0.78) * troughShade;
		vec3 waterVolume = litBase * waterTransmittance + distanceFogColor * (vec3(1.0) - waterTransmittance) * (0.72 + environmentLuma * 0.52);
		vec3 waterColor = mix(waterVolume, distanceFogColor, Saturate(depthFog * 0.30 + grazingFog * waterFog * 0.42));
		float visibleTransmittance = max(max(waterTransmittance.r, waterTransmittance.g), waterTransmittance.b);
		float opticalOpacity = Saturate(1.0 - visibleTransmittance);
		float alphaShape = Saturate(opticalOpacity * 0.42 + depthFog * waterFog * 0.18 + grazingFog * waterFog * 0.62);
		float waterAlpha = mix(0.14, 0.52, alphaShape);
		waterAlpha = mix(waterAlpha, 0.985, pow(1.0 - noV, 2.35));
		waterAlpha = max(waterAlpha, mix(0.12, 0.26, waterFog));
		float waterSunGlintSignal = 0.0;
		if (FOXY_WATER_SUN_GLINT > 0.001) {

vec3 sunGlint = WaterSunGlint(
				normalView,
				-incidentView,
				sunView,
				directSunLightColor,
				1.0,
				skyLight,
				solarVisibility,
				rainStrength,
				0.0,
				normalAaReduction,
				waterWorldPos,
				frameTimeCounter
			);
			waterSunGlintSignal = Luma(sunGlint) / max(Luma(max(directSunLightColor, vec3(0.0))), 0.08);
		}
		vec4 waterMetadata = MaterialWaterPacket(normalView, normalAaReduction, waterSunGlintSignal);
		vec3 fogColor = FogColorFromClearSunColor(sunAltitude, rainStrength, SunColor(sunAltitude, 0.0));
		vec2 boundaryWeights = SkyBoundaryFogWeights(dhWaterPlayerPos, sunAltitude, SceneReach(far));
		vec3 boundaryColor = fogColor;
		if (max(boundaryWeights.x, boundaryWeights.y) > 0.001) {
			boundaryColor = SkyBoundaryFogColor(colortex7, dhWaterViewPos, gbufferModelViewInverse);
		}
		#if FOXY_VOLUMETRIC_LIGHT == 0
			waterColor = ApplyFog(waterColor, fogColor, boundaryColor, boundaryWeights, dhWaterViewPos, waterWorldPos, cameraPosition, upView);
		#endif
		float eyeSkyLight = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
		waterColor = ApplyPurkinjeVision(waterColor, sunAltitude, blockLight, skyLight, eyeSkyLight);
		vec2 producerUv = ProducerScreenUv(vec2(viewWidth, viewHeight));
		StoreLodWaterProducer(
			producerUv,
			WaterProducerPack(
				viewDistance,
				baseNormalView,
				viewDistance + waterPath,
				FOXY_ENDPOINT_OWNER_LOD_WATER
			)
		);

		gl_FragData[0] = vec4(0.0);
		gl_FragData[1] = waterMetadata;
		gl_FragData[2] = WaterSurfacePack(EncodeSceneColor(max(waterColor, vec3(0.0))), waterAlpha);
		return;
	}

	vec3 sunView;
	vec3 moonView;
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, upView, sunView, moonView);
	float sunAltitude = dot(sunView, upView);
	float moonAltitude = dot(moonView, upView);
	vec3 sunLightColor = SunColor(sunAltitude, rainStrength);
	vec3 moonLightColor = MoonColor(moonAltitude, rainStrength);
	vec2 directSourceWeights = CelestialShadowSourceWeights(normalize(shadowLightPosition), sunView, moonView);
	vec3 directSunLightColor = sunLightColor * directSourceWeights.x * DirectCelestialVisibility(sunAltitude);
	vec3 directMoonLightColor = moonLightColor * directSourceWeights.y * DirectCelestialVisibility(moonAltitude);
	vec3 skyAmbientColor = SkyAmbientColor(sunAltitude, rainStrength);
	vec2 lmcoord = Dither8Bit2(dhWaterLightmap, Bayer16(gl_FragCoord.xy));
	float blockLight = lmcoord.x;
	float skyLight = lmcoord.y;
	float sunNoL = max(dot(normalView, sunView), 0.0);
	float moonNoL = max(dot(normalView, moonView), 0.0);
	vec3 direct = directSunLightColor * (sunNoL * 0.78 + pow(sunNoL, 12.0) * 0.28) * skyLight;
	direct += directMoonLightColor * (moonNoL * 0.88 + pow(moonNoL, 12.0) * 0.12) * skyLight;
	vec3 ambient = (skyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor)) * AmbientSkyVisibility(sunAltitude, skyLight) * 1.10;
	vec3 lightmapColor = SrgbToLinear(texture2D(lightmap, lmcoord).rgb);
	vec3 environment = lightmapColor * 0.16 + ambient + direct + TorchColor(blockLight) * 0.46 + vec3(0.0004);
	vec3 baseColor = SrgbToLinear(clamp(dhWaterColor.rgb, vec3(0.0), vec3(1.0)));
	vec3 color = baseColor * environment;
	float alpha = clamp(dhWaterColor.a, 0.0, 1.0);
	vec3 fogColor = FogColorFromClearSunColor(sunAltitude, rainStrength, SunColor(sunAltitude, 0.0));
	vec2 boundaryWeights = SkyBoundaryFogWeights(dhWaterPlayerPos, sunAltitude, SceneReach(far));
	vec3 boundaryColor = fogColor;
	if (max(boundaryWeights.x, boundaryWeights.y) > 0.001) {
		boundaryColor = SkyBoundaryFogColor(colortex7, dhWaterViewPos, gbufferModelViewInverse);
	}
	#if FOXY_VOLUMETRIC_LIGHT == 0
		color = ApplyFog(color, fogColor, boundaryColor, boundaryWeights, dhWaterViewPos, dhWaterPlayerPos + cameraPosition, cameraPosition, upView);
	#endif
	float eyeSkyLight = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
	color = ApplyPurkinjeVision(color, sunAltitude, blockLight, skyLight, eyeSkyLight);

	gl_FragData[0] = vec4(EncodeSceneColor(max(color, vec3(0.0))), alpha);
	gl_FragData[1] = vec4(0.0);
	gl_FragData[2] = vec4(0.0);
}
