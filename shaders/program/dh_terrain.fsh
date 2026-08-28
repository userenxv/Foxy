#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/celestial.glsl"
#include "/lib/lighting.glsl"
#include "/lib/sky.glsl"
#include "/lib/contracts/endpoint.glsl"
#include "/lib/dh_shadow.glsl"

#if FOXY_PT_GBUFFER_ACTIVE == 1
/* RENDERTARGETS: 0,2 */
#else
/* DRAWBUFFERS:0 */
#endif

uniform sampler2D lightmap;
uniform sampler2D colortex7;
uniform sampler2D noisetex;
uniform mat4 gbufferModelViewInverse;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform float rainStrength;
uniform float far;
uniform ivec2 eyeBrightnessSmooth;

in vec4 dhColor;
in vec2 dhLightmap;
in vec3 dhNormalView;
in vec3 dhViewPos;
in vec3 dhPlayerPos;

void main() {
	vec3 normalView = normalize(dhNormalView);
	vec3 upView = normalize(upPosition);
	vec3 sunView;
	vec3 moonView;
	StableSunMoonViewDirsFromUnitUp(sunPosition, moonPosition, upView, sunView, moonView);
	float sunAltitude = dot(sunView, upView);
	float moonAltitude = dot(moonView, upView);
	vec3 sunLightColor = SunColor(sunAltitude, rainStrength);
	vec3 moonLightColor = MoonColor(moonAltitude, rainStrength);
	vec3 skyAmbientColor = SkyAmbientColor(sunAltitude, rainStrength);

	float dither = Bayer16(gl_FragCoord.xy);
	vec2 lmcoord = Dither8Bit2(dhLightmap, dither);
	float blockLight = lmcoord.x;
	float skyLight = lmcoord.y;
	vec3 lightmapColor = SrgbToLinear(texture2D(lightmap, lmcoord).rgb);
	float sunNoL = max(dot(normalView, sunView), 0.0);
	float moonNoL = max(dot(normalView, moonView), 0.0);
	vec3 shadowView = normalize(shadowLightPosition);
	float shadowMatchesSun = smoothstep(0.05, 0.45, dot(shadowView, sunView));
	float shadowMatchesMoon = smoothstep(0.05, 0.45, dot(shadowView, moonView));
	float useSunShadow = step(shadowMatchesMoon, shadowMatchesSun);
	float activeShadowMatch = max(shadowMatchesSun, shadowMatchesMoon);
	float activeShadowNoL = mix(moonNoL, sunNoL, useSunShadow);
	float activeShadowAltitude = mix(moonAltitude, sunAltitude, useSunShadow);
	float activeDirectWeight = activeShadowMatch * DirectCelestialVisibility(activeShadowAltitude);
	float activeShadow = 1.0;
	if (skyLight > 0.015 && activeShadowAltitude > 0.0 && activeShadowNoL > 0.001 && activeShadowMatch > 0.001) {
		DhShadowReceiver receiver = DhBuildShadowReceiver(
			dhPlayerPos,
			dhViewPos,
			normalView,
			gbufferModelViewInverse,
			cameraPosition,
			activeShadowNoL
		);
		activeShadow = mix(1.0, DhShadowVisibility(receiver, activeShadowAltitude), activeShadowMatch);
	}
	float sunShadow = mix(1.0, activeShadow, useSunShadow);
	float moonShadow = mix(activeShadow, 1.0, useSunShadow);
	vec3 directSunColor = sunLightColor * (useSunShadow * activeDirectWeight);
	vec3 directMoonColor = moonLightColor * ((1.0 - useSunShadow) * activeDirectWeight);
	vec3 direct = directSunColor * (sunNoL * 1.08 + pow(sunNoL, 8.0) * 0.24) * sunShadow * skyLight;
	direct += directMoonColor * (moonNoL * 1.03 + pow(moonNoL, 8.0) * 0.08) * moonShadow * skyLight;
	float ambientVisibility = AmbientSkyVisibility(sunAltitude, skyLight);
	float ambientSunShadow = mix(1.0, sunShadow, smoothstep(0.015, 0.18, sunNoL));
	float ambientMoonShadow = mix(1.0, moonShadow, smoothstep(0.015, 0.18, moonNoL));
	float ambientCelestialShadow = mix(ambientMoonShadow, ambientSunShadow, SolarDiscVisibility(sunAltitude));
	float ambientShadowed = mix(1.0 - FOXY_SHADOW_AMBIENT_DARKEN, 1.0, ambientCelestialShadow);
	float ambientShadowInfluence = mix(0.10, 1.0, smoothstep(-0.04, 0.16, sunAltitude));
	vec3 ambient = (skyAmbientColor + MoonAmbientColorFromMoonColor(moonLightColor)) * ambientVisibility * mix(1.0, ambientShadowed, ambientShadowInfluence);
	vec3 torch = TorchColor(blockLight);
	float lightFloor = mix(0.00035, 0.0035, Saturate(blockLight * 1.8 + skyLight * 0.85));

	vec3 worldNormal = normalize(mat3(gbufferModelViewInverse) * normalView);
	vec3 absoluteWorldPos = dhPlayerPos + cameraPosition;
	vec3 axisWeight = abs(worldNormal);
	vec2 detailUv = absoluteWorldPos.xz;
	if (axisWeight.x > axisWeight.y && axisWeight.x > axisWeight.z) {
		detailUv = absoluteWorldPos.zy;
	} else if (axisWeight.z > axisWeight.y) {
		detailUv = absoluteWorldPos.xy;
	}
	float terrainDetail = texture2D(noisetex, detailUv * 0.03125).r * 2.0 - 1.0;
	vec3 albedo = SrgbToLinear(clamp(dhColor.rgb, vec3(0.0), vec3(1.0)));
	albedo *= 1.0 + terrainDetail * 0.08;
	vec3 lit = albedo * (lightmapColor * 0.34 + ambient + direct + torch + vec3(lightFloor));
	vec3 clearSunColor = SunColor(sunAltitude, 0.0);
	vec3 fogColor = FogColorFromClearSunColor(sunAltitude, rainStrength, clearSunColor);
	vec2 boundaryWeights = SkyBoundaryFogWeights(dhPlayerPos, sunAltitude, SceneReach(far));
	vec3 boundaryColor = fogColor;
	if (max(boundaryWeights.x, boundaryWeights.y) > 0.001) {
		boundaryColor = SkyBoundaryFogColor(colortex7, dhViewPos, gbufferModelViewInverse);
	}
	#if FOXY_VOLUMETRIC_LIGHT == 0
		lit = ApplyFog(lit, fogColor, boundaryColor, boundaryWeights, dhViewPos, dhPlayerPos + cameraPosition, cameraPosition, upView);
	#endif
	float eyeSkyLight = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
	lit = ApplyPurkinjeVision(lit, sunAltitude, blockLight, skyLight, eyeSkyLight);

	gl_FragData[0] = vec4(EncodeSceneColor(max(lit, vec3(0.0))), 1.0);
	#if FOXY_PT_GBUFFER_ACTIVE == 1
		gl_FragData[1] = vec4(0.0);
	#endif
}
