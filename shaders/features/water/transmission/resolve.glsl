#ifndef FOXY_WATER_TRANSMISSION_RESOLVE_GLSL
#define FOXY_WATER_TRANSMISSION_RESOLVE_GLSL

struct WaterTransmissionResult {
	vec3 color;
	float weight;
	float fogOcclusion;
};

WaterTransmissionResult ResolveWaterTransmission(
	const in vec2 viewTexcoord, const in vec2 renderTexcoord,
	const in vec3 baseNormalView, const in vec3 normalView,
	const in float waterDepth, const in float waterViewDistance,
	const in float waterPathDistance, const in float waterPresent,
	const in vec3 waterWorldPos, const in vec3 upView,
	const in vec3 sunView, const in vec3 moonView,
	const in float sunAltitude, const in float NoV,
	const in float underwaterTransmission
) {
	#if FOXY_WATER_TRANSMISSION_SPECIALIZE == 1
		// The surface-refraction and bottom-fog weights contain (eye == 0).
		// Under water they are exactly zero: only ordered transmission and
		// the already-computed Snell-window weight reach the final blend.
		if (isEyeInWater == 1) {
			WaterTransmissionResult result;
			result.color = OrderedSceneSampleBehind(viewTexcoord, waterViewDistance);
			result.weight = max(0.0, underwaterTransmission);
			result.fogOcclusion = 0.0;
			return result;
		}
	#endif
	float waterFogOcclusion = 0.0;
	float refractionWeight = 0.0;
	float refractionSurface = waterPresent * (0.84 + FOXY_WATER_WAVE_STRENGTH * 0.32);
	vec2 refractedUv = WaterRefractionUv(
		viewTexcoord,
		baseNormalView,
		normalView,
		waterDepth,
		refractionSurface
	);
	float currentDepthRaw = texture2D(depthtex1, renderTexcoord).r;
	float currentNotSky;
	vec3 currentViewPos = WaterSolidViewPosition(viewTexcoord, renderTexcoord, currentDepthRaw, currentNotSky);
	float currentLinearDepth = max(-currentViewPos.z, 0.0);
	float currentRayDistance = max(length(currentViewPos) - waterViewDistance, 0.0);
	float currentDepthSpan = currentLinearDepth - waterDepth;
	float currentBelowSurface = smoothstep(-0.03, 0.18, currentDepthSpan) * smoothstep(0.03, 0.70, currentRayDistance);
	float currentUnderwaterTarget = currentNotSky * currentBelowSurface * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	vec2 refractedRenderUv = WaterCurrentRenderUv(refractedUv);
	float refractedDepthRaw = texture2D(depthtex1, refractedRenderUv).r;
	float refractedNotSky;
	vec3 refractedViewPos = WaterSolidViewPosition(refractedUv, refractedRenderUv, refractedDepthRaw, refractedNotSky);
	float refractedLinearDepth = max(-refractedViewPos.z, 0.0);
	float refractedRayDistance = max(length(refractedViewPos) - waterViewDistance, 0.0);
	float refractedDepthSpan = refractedLinearDepth - waterDepth;
	float refractedBelowSurface = smoothstep(-0.03, 0.18, refractedDepthSpan) * smoothstep(0.03, 0.70, refractedRayDistance);
	float refractionDepthJump = abs(refractedLinearDepth - currentLinearDepth);
	float refractionEdgeReject = smoothstep(0.42 + waterDepth * 0.010, 2.65 + waterDepth * 0.035, refractionDepthJump);
	float stableRefraction = (1.0 - refractionEdgeReject) * refractedNotSky * refractedBelowSurface * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	stableRefraction *= ScreenEdgeFade(refractedUv);
	vec2 transmittedUv = mix(viewTexcoord, refractedUv, stableRefraction);
	vec2 transmittedRenderUv = WaterCurrentRenderUv(transmittedUv);
	float transmittedDepthRaw = texture2D(depthtex1, transmittedRenderUv).r;
	vec3 transmitted = OrderedSceneSampleBehind(
		transmittedUv,
		waterViewDistance
	);
	float transmittedNotSky;
	vec3 transmittedViewPos = WaterSolidViewPosition(transmittedUv, transmittedRenderUv, transmittedDepthRaw, transmittedNotSky);
	float transmittedLinearDepth = max(-transmittedViewPos.z, 0.0);
	float transmittedRayDistance = max(length(transmittedViewPos) - waterViewDistance, 0.0);
	float transmittedDepthSpan = transmittedLinearDepth - waterDepth;
	float belowSurface = smoothstep(-0.03, 0.18, transmittedDepthSpan) * smoothstep(0.03, 0.70, transmittedRayDistance);
	float noBottomWater = (1.0 - transmittedNotSky) * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	float packetUnderwaterTarget = smoothstep(0.03, 0.70, waterPathDistance) * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	float underwaterTarget = max(max(transmittedNotSky * belowSurface, packetUnderwaterTarget), noBottomWater) * waterPresent * (isEyeInWater == 0 ? 1.0 : 0.0);
	if (underwaterTarget > 0.001) {
		float noBottomRayDistance = max(far * 0.35, 96.0);
		float depthStableRayDistance = max(transmittedRayDistance, currentRayDistance * currentUnderwaterTarget);
		float packetFallbackWeight = (1.0 - transmittedNotSky * belowSurface) * smoothstep(0.18, 1.20, waterPathDistance);
		float conservativeRayDistance = max(depthStableRayDistance, mix(depthStableRayDistance, waterPathDistance, 0.18));
		float effectiveWaterRayDistance = noBottomWater > 0.5 ? noBottomRayDistance : mix(conservativeRayDistance, waterPathDistance, packetFallbackWeight);
		float waterFog = Saturate(FOXY_WATER_FOG);
		float waterRayDistance = effectiveWaterRayDistance;
		vec3 waterTransmittance = WaterTransmittance(waterRayDistance * mix(1.15, 2.10, waterFog), waterFog);

		float solarLightingVisibility = DirectCelestialVisibility(sunAltitude);
		float moonLightingVisibility = DirectCelestialVisibility(vertexMoonAltitude);
		float solarIrradiance = WaterSolarIrradiance(vertexSunLightColor, sunAltitude);
		float lunarIrradiance = WaterLunarIrradiance(vertexMoonLightColor, vertexMoonAltitude);
		float sourceIrradiance = solarIrradiance + lunarIrradiance;
		float sunTopLight = max(dot(upView, sunView), 0.0);
		float moonTopLight = max(dot(upView, moonView), 0.0);
		float topLight = (sunTopLight * solarIrradiance + moonTopLight * lunarIrradiance)
			/ max(sourceIrradiance, 1.0e-4);
		vec3 moonLightColor = vertexMoonLightColor;
		vec3 activeDirectColor = vertexSunLightColor * solarLightingVisibility
			+ moonLightColor * moonLightingVisibility;
		float activeDirectAmount = Saturate(topLight * sourceIrradiance);
		vec3 waterAmbient = vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor);
		float skyIrradiance = WaterSkyIrradiance(waterAmbient, rainStrength);
		float stableWaterSkyLight = Saturate((0.26 + smoothstep(-0.08, 0.34, sunAltitude) * 0.42
			+ (1.0 - rainStrength) * 0.10) * mix(0.30, 1.0, skyIrradiance));
		vec3 waterScatter = WaterScatterColor(waterAmbient, activeDirectColor, activeDirectAmount, stableWaterSkyLight, rainStrength);
		vec3 waterInput = mix(waterScatter, transmitted, transmittedNotSky);
		vec3 transmittedWater = waterInput * waterTransmittance + waterScatter * (vec3(1.0) - waterTransmittance);
		if (transmittedNotSky * belowSurface > 0.001) {
			vec3 transmittedPlayerPos = PlayerPosFromViewPos(transmittedViewPos);
			vec3 transmittedWorldPos = transmittedPlayerPos + cameraPosition;
			vec3 sunWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, sunView));
			float verticalWaterDepth = max(waterWorldPos.y - transmittedWorldPos.y, 0.0);
			float caustics = WaterCaustics(
				transmittedWorldPos,
				sunWorld,
				frameTimeCounter,
				verticalWaterDepth,
				verticalWaterDepth
			);
			float causticVisibility = transmittedNotSky * belowSurface;
			causticVisibility *= smoothstep(0.02, 0.30, sunWorld.y);
			causticVisibility *= 1.0 - rainStrength * 0.78;
			causticVisibility *= 1.0 - smoothstep(54.0, 138.0, verticalWaterDepth);
			float causticFocus = max(caustics - 1.0, 0.0)
				* FOXY_WATER_CAUSTICS_BRIGHTNESS * causticVisibility;
			vec3 sunTint = max(vertexSunLightColor, vec3(0.0));
			sunTint /= max(Luma(sunTint), 0.16);
			vec3 causticTint = mix(vec3(1.0), sunTint, 0.18);
			transmittedWater *= vec3(1.0) + causticTint * causticFocus * 0.78;
		}
		float waterOcclusion = Saturate(1.0 - max(max(waterTransmittance.r, waterTransmittance.g), waterTransmittance.b));
		waterFogOcclusion = waterOcclusion * underwaterTarget;
		float waterFogReplace = mix(0.30, 1.0, smoothstep(0.05, 0.72, waterOcclusion));
		transmitted = mix(transmitted, transmittedWater, underwaterTarget * waterFogReplace);
	}
	float refractionCoverage = smoothstep(0.015, 0.18, NoV);
	float refractionReplace = mix(0.97, 1.0, Saturate(FOXY_WATER_FOG));
	float fogReplace = smoothstep(0.08, 0.92, waterFogOcclusion);
	refractionWeight = max(underwaterTarget * refractionCoverage * refractionReplace, fogReplace * waterPresent);
	refractionWeight = max(refractionWeight, underwaterTransmission);
	WaterTransmissionResult result;
	result.color = transmitted;
	result.weight = refractionWeight;
	result.fogOcclusion = waterFogOcclusion;
	return result;
}

#endif
