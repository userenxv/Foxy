#ifndef FOXY_SURFACE_PBR_GLSL
#define FOXY_SURFACE_PBR_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/emissive.glsl"

struct PbrMaterial {
	vec3 albedo;
	vec3 normalView;
	vec3 f0;

	float emissionMask;
	float roughness;
	float metalness;
	float specularWeight;
	float porosity;
	float sssAmount;
	float sheenAmount;
};

float PbrPow5(const in float value) {
	float value2 = value * value;
	return value2 * value2 * value;
}

vec3 PbrSafeNormal(const in vec3 value, const in vec3 fallbackNormal) {
	float lengthSquared = dot(value, value);
	return lengthSquared > 1.0e-10
		? value * inversesqrt(lengthSquared)
		: fallbackNormal;
}

vec3 PbrVisibleNormal(
	const in vec3 shadingNormal,
	const in vec3 geometricNormal,
	const in vec3 viewDirection
) {
	vec3 surfaceNormal = PbrSafeNormal(geometricNormal, vec3(0.0, 0.0, 1.0));
	vec3 toViewer = PbrSafeNormal(viewDirection, surfaceNormal);
	if (dot(surfaceNormal, toViewer) < 0.0) {
		surfaceNormal = -surfaceNormal;
	}

	vec3 resolvedNormal = PbrSafeNormal(shadingNormal, surfaceNormal);
	float geometricSide = dot(resolvedNormal, surfaceNormal);
	resolvedNormal -= 2.0 * min(geometricSide, 0.0) * surfaceNormal;
	float visibleSide = dot(resolvedNormal, toViewer);
	resolvedNormal -= 2.0 * min(visibleSide, 0.0) * toViewer;
	return PbrSafeNormal(resolvedNormal, surfaceNormal);
}

float PbrAlphaFromPerceptualRoughness(const in float perceptualRoughness) {
	float roughness = Saturate(perceptualRoughness);
	return max(roughness * roughness, 0.002);
}

float PbrFallbackRoughness(const in vec3 albedo) {
	float perceivedLuma = sqrt(Saturate(Luma(max(albedo, vec3(0.0)))));
	float smoothMaterial = smoothstep(0.18, 0.82, perceivedLuma);
	return PbrAlphaFromPerceptualRoughness(mix(0.90, 0.66, smoothMaterial));
}

float PbrFoliageRoughness(const in vec3 albedo) {
	float perceivedLuma = sqrt(Saturate(Luma(max(albedo, vec3(0.0)))));
	float waxySurface = smoothstep(0.14, 0.76, perceivedLuma);
	return PbrAlphaFromPerceptualRoughness(mix(0.82, 0.58, waxySurface));
}

vec3 PbrMetalF0FromBaseColor(const in vec3 albedo) {
	return clamp(albedo * 1.12 + vec3(0.06), vec3(0.12), vec3(0.96));
}

PbrMaterial PbrDefaultMaterial(const in vec3 albedo, const in vec3 normalView) {
	PbrMaterial material;
	material.albedo = albedo;
	material.normalView = normalView;
	material.f0 = vec3(max(FOXY_PBR_FALLBACK_F0, 0.002));
	material.emissionMask = 0.0;
	material.roughness = PbrFallbackRoughness(albedo);
	material.metalness = 0.0;
	material.specularWeight = 1.0;
	material.porosity = 0.0;
	material.sssAmount = 0.0;
	material.sheenAmount = 0.0;
	return material;
}

bool PbrIdInRange(const in float id, const in float firstId, const in float lastId) {
	return id >= firstId - 0.5 && id <= lastId + 0.5;
}

void PbrApplyFallbackMaterial(inout PbrMaterial material, const in float materialId) {
	if (PbrIdInRange(materialId, 10079.0, 10082.0)) {
		material.roughness = PbrAlphaFromPerceptualRoughness(0.22);
		material.f0 = vec3(0.035);
		material.specularWeight = 1.0;
	} else if (PbrIdInRange(materialId, 10100.0, 10103.0)) {
		material.f0 = vec3(max(FOXY_PBR_FALLBACK_F0, 0.002));
		if (materialId < 10100.5) {
			material.roughness = PbrFoliageRoughness(material.albedo);
			material.sssAmount = 1.00;
			material.sheenAmount = 0.50;
		} else if (materialId < 10101.5) {
			material.roughness = PbrAlphaFromPerceptualRoughness(0.72);
			material.sssAmount = 0.72;
			material.sheenAmount = 0.90;
		} else if (materialId < 10102.5) {
			material.roughness = PbrAlphaFromPerceptualRoughness(0.76);
			material.sssAmount = 0.72;
			material.sheenAmount = 0.90;
		} else {
			material.roughness = PbrAlphaFromPerceptualRoughness(0.68);
			material.sssAmount = 0.72;
			material.sheenAmount = 0.90;
		}
	} else if (PbrIdInRange(materialId, 10104.0, 10109.0)) {
		material.roughness = PbrAlphaFromPerceptualRoughness(0.78);
		material.specularWeight = 0.72;
		material.sssAmount = 0.46;
		material.sheenAmount = 0.24;
	} else if (PbrIdInRange(materialId, 10110.0, 10119.0)) {
		material.roughness = PbrAlphaFromPerceptualRoughness(0.74);
		material.f0 = vec3(0.032);
		material.specularWeight = 0.66;
		material.porosity = 0.36;
	} else if (PbrIdInRange(materialId, 10120.0, 10129.0)) {
		material.roughness = PbrAlphaFromPerceptualRoughness(0.82);
		material.f0 = vec3(0.038);
		material.specularWeight = 0.62;
	} else if (PbrIdInRange(materialId, 10130.0, 10139.0)) {
		material.roughness = PbrAlphaFromPerceptualRoughness(0.90);
		material.specularWeight = 0.46;
		material.porosity = 0.76;
	} else if (PbrIdInRange(materialId, 10140.0, 10149.0)) {
		material.roughness = PbrAlphaFromPerceptualRoughness(0.30);
		material.metalness = 1.0;
		material.f0 = PbrMetalF0FromBaseColor(material.albedo);
		material.specularWeight = 1.0;
	} else if (PbrIdInRange(materialId, 10150.0, 10159.0)) {
		material.roughness = PbrAlphaFromPerceptualRoughness(0.38);
		material.f0 = vec3(0.12);
		material.specularWeight = 0.94;
	} else if (PbrIdInRange(materialId, 10160.0, 10169.0)) {
		material.roughness = PbrAlphaFromPerceptualRoughness(0.95);
		material.f0 = vec3(0.024);
		material.specularWeight = 0.24;
		material.porosity = 0.86;
	}

}

vec3 PbrEmissionRadiance(
	const in vec3 albedo,
	const in float emissionMask,
	const in float brightness
) {
	return max(albedo, vec3(0.0)) * Saturate(emissionMask) *
		max(brightness, 0.0);
}

vec3 PbrSurfaceEmission(const in vec3 albedo, const in float emissionMask) {
	return PbrEmissionRadiance(
		albedo,
		emissionMask,
		FOXY_PBR_EMISSION_BRIGHTNESS
	);
}

vec3 PbrSsptEmission(const in vec3 albedo, const in float emissionMask) {
	return PbrEmissionRadiance(
		albedo,
		emissionMask,
		FOXY_SSPT_PBR_EMISSION_BRIGHTNESS
	);
}

float PbrFallbackEmissionMask(
	const in vec3 albedo,
	const in float materialId,
	const in float blockEmissionLevel
) {
	if (blockEmissionLevel < 0.5) return 0.0;

return 1.0;
}

float PbrResolvedEmissionMask(
	const in PbrMaterial material,
	const in float materialId,
	const in float blockEmissionLevel
) {

if (material.emissionMask > 0.003) return Saturate(material.emissionMask);
	return PbrFallbackEmissionMask(material.albedo, materialId, blockEmissionLevel);
}

vec3 PbrFallbackEmissionColor(
	const in vec3 albedo,
	const in float materialId
) {

return max(albedo, vec3(0.0));
}

vec3 PbrFallbackEmissionRadiance(
	const in vec3 albedo,
	const in float materialId,
	const in float blockEmissionLevel,
	const in float resolvedMask,
	const in float brightness
) {
	if (resolvedMask <= 0.0) return vec3(0.0);
	float levelWeight = Saturate(blockEmissionLevel * (1.0 / 15.0));
	float calibration = mix(0.38, 0.72, levelWeight);
	return PbrFallbackEmissionColor(albedo, materialId) * resolvedMask *
		max(brightness, 0.0) * calibration;
}

vec3 PbrResolvedEmissionRadiance(
	const in PbrMaterial material,
	const in float materialId,
	const in float blockEmissionLevel,
	const in float resolvedMask,
	const in float brightness
) {
	if (resolvedMask <= 0.0) return vec3(0.0);
	if (material.emissionMask > 0.003) {
		return PbrEmissionRadiance(material.albedo, resolvedMask, brightness);
	}
	return PbrFallbackEmissionRadiance(
		material.albedo,
		materialId,
		blockEmissionLevel,
		resolvedMask,
		brightness
	);
}

vec3 PbrResolvedSurfaceEmission(
	const in PbrMaterial material,
	const in float materialId,
	const in float blockEmissionLevel,
	const in float resolvedMask
) {
	return PbrResolvedEmissionRadiance(
		material,
		materialId,
		blockEmissionLevel,
		resolvedMask,
		FOXY_PBR_EMISSION_BRIGHTNESS
	);
}

vec3 PbrResolvedSsptEmission(
	const in PbrMaterial material,
	const in float materialId,
	const in float blockEmissionLevel,
	const in float resolvedMask
) {
	return PbrResolvedEmissionRadiance(
		material,
		materialId,
		blockEmissionLevel,
		resolvedMask,
		FOXY_SSPT_PBR_EMISSION_BRIGHTNESS
	);
}

float PbrLabEmissionMask(const in float encodedEmission) {

	return encodedEmission < 0.999 ? Saturate(encodedEmission) : 0.0;
}

#if FOXY_PBR_SPECULAR_MAPS == 1
void PbrApplyLabSpecularMap(inout PbrMaterial material, const in vec4 specularMap) {
	material.roughness = PbrAlphaFromPerceptualRoughness(1.0 - specularMap.r);
	material.emissionMask = max(material.emissionMask, PbrLabEmissionMask(specularMap.a));

	float encodedF0 = specularMap.g * 255.0;
	if (encodedF0 < 229.5) {
		material.f0 = vec3(clamp(specularMap.g, 0.002, 0.16));
		float encodedData = specularMap.b * 255.0;
		if (encodedData >= 64.5) {
			material.sssAmount = max(material.sssAmount, Saturate((encodedData - 64.0) / 191.0));
		} else {
			material.porosity = max(material.porosity, Saturate(encodedData / 64.0));
		}
	} else {
		material.metalness = 1.0;
		material.f0 = PbrMetalF0FromBaseColor(material.albedo);
		material.specularWeight = 1.0;
	}
}

void PbrApplyOldSpecularMap(inout PbrMaterial material, const in vec4 specularMap) {
	material.roughness = PbrAlphaFromPerceptualRoughness(1.0 - specularMap.r);
	material.metalness = smoothstep(0.45, 0.55, specularMap.g);
	material.f0 = mix(material.f0, PbrMetalF0FromBaseColor(material.albedo), material.metalness);
	material.emissionMask = max(material.emissionMask, Saturate(specularMap.b));
	material.specularWeight = mix(material.specularWeight, 1.0, material.metalness);
}

void PbrApplySpecularMap(inout PbrMaterial material, const in vec4 specularMap) {
	#if FOXY_PBR_TEXTURE_FORMAT == 0
		PbrApplyLabSpecularMap(material, specularMap);
	#else
		PbrApplyOldSpecularMap(material, specularMap);
	#endif
}
#endif

#if FOXY_PBR_NORMAL_MAPS == 1
vec3 PbrDecodeNormalMap(const in vec3 normalMap) {
	#if FOXY_PBR_TEXTURE_FORMAT == 0
		vec2 xy = normalMap.xy * 2.0 - 1.0;
		float xyLengthSquared = dot(xy, xy);
		if (xyLengthSquared > 1.0) {
			xy *= inversesqrt(xyLengthSquared);
			xyLengthSquared = 1.0;
		}
		return vec3(xy, sqrt(max(1.0 - xyLengthSquared, 0.0)));
	#else
		return PbrSafeNormal(normalMap * 2.0 - 1.0, vec3(0.0, 0.0, 1.0));
	#endif
}
#endif

vec3 PbrFresnelSchlick(const in float viewHalf, const in vec3 f0) {
	float grazing = PbrPow5(1.0 - Saturate(viewHalf));
	return f0 + (vec3(1.0) - f0) * grazing;
}

float PbrDistributionGGX(const in float normalHalf, const in float alpha) {
	float alpha2 = alpha * alpha;
	float normalHalf2 = normalHalf * normalHalf;
	float denominator = normalHalf2 * (alpha2 - 1.0) + 1.0;
	return alpha2 / max(PI * denominator * denominator, 1.0e-6);
}

float PbrGeometrySchlick(const in float normalDirection, const in float k) {
	return normalDirection / max(normalDirection * (1.0 - k) + k, 1.0e-5);
}

vec3 PbrDirectSpecular(
	const in PbrMaterial material,
	const in vec3 lightDirView,
	const in vec3 viewDirView,
	const in float lightVisibility,
	const in vec3 lightColor
) {
	float lightEnergy = max(lightColor.r, max(lightColor.g, lightColor.b));
	if (lightVisibility <= 1.0e-4 || material.specularWeight <= 1.0e-4 || lightEnergy <= 0.0) {
		return vec3(0.0);
	}

	vec3 normalView = material.normalView;
	vec3 lightDir = lightDirView;
	vec3 viewDir = viewDirView;
	float normalLight = Saturate(dot(normalView, lightDir));
	float normalViewDot = Saturate(dot(normalView, viewDir));
	if (normalLight <= 1.0e-4 || normalViewDot <= 1.0e-4) {
		return vec3(0.0);
	}

	vec3 halfVectorRaw = lightDir + viewDir;
	float halfLength2 = dot(halfVectorRaw, halfVectorRaw);
	if (halfLength2 <= 1.0e-8) {
		return vec3(0.0);
	}
	vec3 halfVector = halfVectorRaw * inversesqrt(halfLength2);
	float normalHalf = Saturate(dot(normalView, halfVector));
	float viewHalf = Saturate(dot(viewDir, halfVector));

	float angularFloor = max(tan(max(FOXY_PBR_LIGHT_ANGULAR_RADIUS, 0.0)), 0.002);
	float alpha = clamp(max(material.roughness, angularFloor), 0.002, 1.0);
	float distribution = PbrDistributionGGX(normalHalf, alpha);
	float geometryK = 0.5 * alpha;
	float geometry = PbrGeometrySchlick(normalLight, geometryK) * PbrGeometrySchlick(normalViewDot, geometryK);
	vec3 f0 = mix(clamp(material.f0, vec3(0.002), vec3(0.96)), PbrMetalF0FromBaseColor(material.albedo), Saturate(material.metalness));
	vec3 fresnel = PbrFresnelSchlick(viewHalf, f0);
	vec3 brdf = fresnel * (distribution * geometry / max(4.0 * normalLight * normalViewDot, 1.0e-5));
	vec3 specular = lightColor * (PI * normalLight) * brdf;
	specular *= material.specularWeight * FOXY_PBR_SPECULAR_STRENGTH * lightVisibility;
	return min(max(specular, vec3(0.0)), vec3(FOXY_PBR_SPECULAR_CLAMP));
}

vec3 PbrTransmissionTint(const in vec3 albedo) {
	vec3 rootColor = sqrt(max(albedo, vec3(0.0)));
	float peak = max(rootColor.r, max(rootColor.g, rootColor.b));
	vec3 chroma = rootColor / max(peak, 1.0e-4);
	return mix(vec3(1.0), chroma, 0.42);
}

vec3 PbrThinSss(
	const in PbrMaterial material,
	const in vec3 lightDirView,
	const in vec3 viewDirView,
	const in float lightVisibility,
	const in vec3 lightColor
) {
	#if FOXY_PBR_SSS == 1
		float amount = Saturate(material.sssAmount);
		float intensity = max(FOXY_PBR_SSS_INTENSITY, 0.0);
		float lightEnergy = max(lightColor.r, max(lightColor.g, lightColor.b));
		if (amount <= 1.0e-4 || intensity <= 1.0e-4 || lightVisibility <= 1.0e-4 || lightEnergy <= 0.0) {
			return vec3(0.0);
		}

		vec3 lightDir = lightDirView;
		vec3 viewDir = viewDirView;
		vec3 normalView = material.normalView;
		float lightView = clamp(dot(lightDir, viewDir), -1.0, 1.0);
		float backAlignment = 0.5 - 0.5 * lightView;
		float back2 = backAlignment * backAlignment;
		float back4 = back2 * back2;
		float thinSheetLobe = 0.10 + 0.55 * back2 + 0.78 * back4;
		float normalLight = dot(normalView, lightDir);
		float sheetOrientation = max(Saturate(-normalLight), 1.0 - abs(normalLight));
		float orientationGate = 0.55 + 0.45 * sheetOrientation;
		float shapedAmount = amount * (0.65 + 0.35 * amount);
		vec3 tint = PbrTransmissionTint(material.albedo);
		vec3 response = tint * (thinSheetLobe * orientationGate * shapedAmount * intensity);

		#if FOXY_PBR_SSS_SHEEN == 1
			float viewRim = 1.0 - abs(dot(normalView, viewDir));
			viewRim *= viewRim;
			float sheen = material.sheenAmount * intensity * viewRim * (0.20 + 0.80 * back4) * 0.38;
			response += mix(vec3(1.0), tint, 0.25) * sheen;
		#endif

		return max(response, vec3(0.0)) * lightColor * lightVisibility;
	#else
		return vec3(0.0);
	#endif
}

vec3 PbrAmbientSss(
	const in PbrMaterial material,
	const in vec3 ambientLight,
	const in float skyLight
) {
	#if FOXY_PBR_SSS == 1
		float amount = Saturate(material.sssAmount) * max(FOXY_PBR_SSS_INTENSITY, 0.0) * Saturate(skyLight);
		return ambientLight * PbrTransmissionTint(material.albedo) * (amount * 0.11);
	#else
		return vec3(0.0);
	#endif
}

vec3 PbrDiffuseAlbedo(const in PbrMaterial material) {
	return material.albedo * mix(1.0, FOXY_PBR_METAL_DIFFUSE, Saturate(material.metalness));
}

#endif
