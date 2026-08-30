#ifndef texture2D
#define texture2D texture
#endif

#define FOXY_EXTERNAL_PIPELINE_BINDINGS

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/contracts/voxy.glsl"
#include "/lib/contracts/water_surface.glsl"
#include "/lib/contracts/material.glsl"

layout(location = 0) out vec4 voxySceneColor;
layout(location = 1) out vec4 voxyMaterial;
layout(location = 2) out vec4 voxyWaterSurface;

void voxy_emitFragment(VoxyFragmentParameters parameters) {
	float materialId = VoxyMaterialId(parameters.customId);
	float waterSurface = abs(materialId - 10008.0) < 0.5 ? 1.0 : 0.0;
	float alpha = clamp(parameters.sampledColour.a * parameters.tinting.a, 0.0, 1.0);

	if (waterSurface < 0.5 && alpha <= 0.001) discard;

	voxySceneColor = vec4(0.0);
	voxyMaterial = vec4(0.0);
	voxyWaterSurface = vec4(0.0);

	vec2 screenUv = VoxyViewUv(gl_FragCoord.xy, view_pixel_size);
	vec3 normalWorld = VoxyFaceNormal(parameters.face);
	vec3 viewPos = VoxyViewPosition(screenUv, gl_FragCoord.z, vxProjInv);
	vec3 playerPos = VoxyPlayerPosition(viewPos);
	vec3 worldPos = playerPos + cameraPosition;
	vec3 sunWorld = vec3(0.0, 1.0, 0.0);
	vec3 moonWorld = vec3(0.0, -1.0, 0.0);
#if !defined(FOXY_DIM_NETHER) && !defined(FOXY_DIM_END)
	sunWorld = normalize(sun_dir);
	moonWorld = normalize(moon_dir);
#endif
	vec3 ambient;
	vec3 directSun;
	vec3 directMoon;
	vec3 fogColor;
	VoxyLighting(
		parameters.lightMap,
		normalWorld,
		sunWorld,
		moonWorld,
		rainStrength,
		ambient,
		directSun,
		directMoon,
		fogColor
	);

	if (waterSurface > 0.5) {
		float skyLight = clamp(parameters.lightMap.y, 0.0, 1.0);
		float blockLight = clamp(parameters.lightMap.x, 0.0, 1.0);
		vec3 waterColor = SrgbToLinear(max(parameters.sampledColour.rgb * parameters.tinting.rgb, vec3(0.0)));
		waterColor *= 0.35 + skyLight * 0.55 + blockLight * 0.15;
		#if FOXY_VOLUMETRIC_LIGHT == 0
			waterColor = VoxyApplyFog(
				waterColor,
				fogColor,
				viewPos,
				worldPos,
				cameraPosition,
				vec3(0.0, 1.0, 0.0),
				normalize(sunWorld).y,
				far
			);
		#endif

		vec3 mainOpticalNormal = normalize(mat3(gbufferModelView) * normalWorld);
		voxyMaterial = MaterialWaterPacket(mainOpticalNormal, 0.0, 0.0);
		voxyWaterSurface = WaterSurfacePack(
			EncodeSceneColor(max(waterColor, vec3(0.0))),
			clamp(max(alpha, 0.08), 0.08, 0.72)
		);
		return;
	}

	vec3 baseColor = SrgbToLinear(max(parameters.sampledColour.rgb * parameters.tinting.rgb, vec3(0.0)));
	vec3 litColor = baseColor * max(ambient + directSun + directMoon, vec3(0.00015));
	#if FOXY_VOLUMETRIC_LIGHT == 0
		litColor = VoxyApplyFog(
			litColor,
			fogColor,
			viewPos,
			worldPos,
			cameraPosition,
			vec3(0.0, 1.0, 0.0),
			normalize(sunWorld).y,
			far
		);
	#endif
	voxySceneColor = vec4(EncodeSceneColor(max(litColor, vec3(0.0))), alpha);
}
