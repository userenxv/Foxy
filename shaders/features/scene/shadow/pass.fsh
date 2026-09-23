#include "/lib/settings.glsl"

#ifdef COLORWHEEL
uniform sampler2D gtexture;
#else
uniform sampler2D texture;
#endif
uniform mat4 gbufferModelViewInverse;
uniform vec3 shadowLightPosition;

#if FOXY_RAY_MODE == FOXY_RAY_RSM
/* DRAWBUFFERS:01 */
#else
/* DRAWBUFFERS:0 */
#endif

varying vec2 texcoord;
varying vec4 surfaceColor;
varying vec3 surfaceWorldPosition;
varying float isWater;
varying float vertexMaterialId;

#if FOXY_RAY_MODE == FOXY_RAY_RSM
	#include "/lib/rsm_axis.glsl"
	varying vec3 surfaceShadowNormal;
#endif

#include "/lib/math.glsl"
#include "/lib/celestial.glsl"
#include "/lib/water.glsl"
#include "/lib/transmission.glsl"

void main() {
	#ifdef COLORWHEEL
		vec4 texel = texture2D(gtexture, texcoord);
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
		vec4 texel = texture2D(texture, texcoord) * surfaceColor;
	#endif
	if (texel.a < 0.10) discard;

	if (isWater > 0.5) {
		vec3 sunWorld = TiltCelestialWorld(ViewToWorldDir(gbufferModelViewInverse, normalize(shadowLightPosition)));
		float caustics = WaterCaustics(surfaceWorldPosition, sunWorld, frameTimeCounter, 5.0, 5.0);
		float causticFocus = max(caustics - 1.0, 0.0) * FOXY_WATER_CAUSTICS_BRIGHTNESS;
		vec3 waterTransmittance = WaterTransmittance(5.0, FOXY_WATER_FOG);
		vec3 waterTint = waterTransmittance / max(Luma(waterTransmittance), 0.05);
		vec3 directScale = vec3(FOXY_WATER_ABOVE_DIRECT_LIGHT) * mix(vec3(1.0), clamp(waterTint, vec3(0.72), vec3(1.18)), 0.12);
		directScale *= 1.0 + causticFocus;
		gl_FragData[0] = vec4(clamp(directScale, vec3(0.02), vec3(0.985)), 1.0);
		#if FOXY_RAY_MODE == FOXY_RAY_RSM
			gl_FragData[1] = vec4(0.0);
		#endif
		return;
	}

	if (TransmissionIsGlass(vertexMaterialId)) {

vec3 transmission = TransmissionColor(vertexMaterialId);
		gl_FragData[0] = vec4(clamp(transmission, vec3(0.02), vec3(0.96)), 1.0);
		#if FOXY_RAY_MODE == FOXY_RAY_RSM
			gl_FragData[1] = vec4(0.0);
		#endif
		return;
	}

	gl_FragData[0] = vec4(1.0);
	#if FOXY_RAY_MODE == FOXY_RAY_RSM
		gl_FragData[1] = vec4(
			SrgbToLinear(Saturate3(texel.rgb)),
			RsmPackAxisNormal(normalize(surfaceShadowNormal))
		);
	#endif
}
