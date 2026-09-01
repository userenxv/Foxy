#ifndef FOXY_MATERIAL_REFLECTION_APPLY_GLSL
#define FOXY_MATERIAL_REFLECTION_APPLY_GLSL

#if FOXY_MATERIAL_REFLECTIONS == 1
#include "/features/material/reflection_policy.glsl"

vec3 ApplyMaterialReflection(
	const in vec3 sceneColor,
	const in vec2 viewUv,
	const in vec2 renderUv,
	const in vec4 packedSurface,
	const in vec4 filteredReflection
) {
	if (max(filteredReflection.r, max(filteredReflection.g, filteredReflection.b)) < 1.0e-7) return sceneColor;
	float glassSurface = MaterialIsGlass(packedSurface);
	if (glassSurface > 0.5) {
		float glassDepth = texture2D(depthtex0, renderUv).r;
		if (glassDepth >= 0.99999) return sceneColor;
		vec3 glassViewPos = BackendMainViewPosition(viewUv, glassDepth, gbufferProjectionInverse);
		vec3 incidentView = normalize(glassViewPos);
		vec3 glassNormal = MaterialGlassNormal(packedSurface);
		if (dot(glassNormal, -incidentView) < 0.0) glassNormal = -glassNormal;
		float NoV = max(dot(glassNormal, -incidentView), 0.0);
		float fresnel = 0.04 + 0.96 * pow(1.0 - NoV, 5.0);
		return max(
			mix(sceneColor, filteredReflection.rgb, Saturate(fresnel * 0.82 * FOXY_MATERIAL_REFLECTION_STRENGTH)),
			vec3(0.0)
		);
	}
	BackendOpaqueSurface opaqueSurface = BackendResolveOpaqueSurface(
		viewUv,
		renderUv,
		texture2D(depthtex1, renderUv).r,
		gbufferProjectionInverse
	);
	float depthRaw = opaqueSurface.rawDepth;
	PtGbufferSample material = PtDecodeGbuffer(packedSurface, depthRaw);
	if (material.valid < 0.5) return sceneColor;

	float perceptualRoughness = sqrt(Saturate(material.roughness));
	float smoothness = MaterialReflectionSmoothness(perceptualRoughness);
	if (MaterialReflectionSurfaceEnabled(
		material.valid,
		material.surfaceClass,
		perceptualRoughness,
		material.metalness
	) < 0.5) return sceneColor;

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
	float NoV = max(dot(normalView, -incidentView), 0.0);

	vec3 dielectricF0 = vec3(max(FOXY_PBR_FALLBACK_F0, 0.02));
	vec3 f0 = mix(dielectricF0, clamp(material.albedo * 1.12 + vec3(0.06), vec3(0.12), vec3(0.96)), material.metalness);
	vec3 fresnel = f0 + (vec3(1.0) - f0) * pow(1.0 - NoV, 5.0);
	vec3 amount = fresnel * FOXY_MATERIAL_REFLECTION_STRENGTH;
	return max(sceneColor + filteredReflection.rgb * amount, vec3(0.0));
}
#else
vec3 ApplyMaterialReflection(
	const in vec3 sceneColor,
	const in vec2 viewUv,
	const in vec2 renderUv,
	const in vec4 packedSurface,
	const in vec4 filteredReflection
) {
	return sceneColor;
}
#endif

#endif
