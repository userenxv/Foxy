#include "/lib/settings.glsl"
#include "/lib/math.glsl"

/* DRAWBUFFERS:0 */

#ifdef COLORWHEEL
uniform sampler2D gtexture;
#else
uniform sampler2D texture;
#endif
#ifdef WEATHER
uniform float rainStrength;
#endif
#ifdef PARTICLES
uniform float rainStrength;
#endif

varying vec2 texcoord;
varying vec4 surfaceColor;

void main() {
	#ifdef COLORWHEEL
		vec4 baseTexel = texture2D(gtexture, texcoord);
		vec4 texel = baseTexel;
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
		vec4 baseTexel = texture2D(texture, texcoord);
		vec4 texel = baseTexel * surfaceColor;
	#endif
	#ifdef ALPHA_TEST
		if (texel.a < 0.10) discard;
	#endif
	#ifdef PARTICLES
		// Exclude the blue vanilla rain-impact particle, not weather streaks.
		if (
			rainStrength > 0.01 &&
			baseTexel.r < 0.29 &&
			baseTexel.g < 0.45 &&
			baseTexel.b > 0.75
		) discard;
	#endif
	#ifdef WEATHER
		// Channel ratios remain stable under mip-filtered rain energy loss.
		float weatherEnergy = max(max(baseTexel.r, baseTexel.g), baseTexel.b);
		float rainChroma = (baseTexel.b - baseTexel.r) / max(weatherEnergy, 1.0e-4);
		float isRain = step(0.12, rainChroma);
		if (isRain > 0.5) {
			vec3 rainTint = SrgbToLinear(vec3(0.68, 0.75, 0.80) * surfaceColor.rgb);
			float rainAlpha = baseTexel.a * surfaceColor.a * mix(0.14, 0.22, Saturate(rainStrength));
			gl_FragData[0] = vec4(EncodeSceneColor(rainTint) * rainAlpha, rainAlpha);
			return;
		}
		vec3 weatherColor = EncodeSceneColor(SrgbToLinear(texel.rgb));
		gl_FragData[0] = vec4(weatherColor * texel.a, texel.a);
		return;
	#endif
	gl_FragData[0] = vec4(EncodeSceneColor(SrgbToLinear(texel.rgb)), texel.a);
	gl_FragData[1] = vec4(0.0);
}
