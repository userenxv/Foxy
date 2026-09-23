#version 430 compatibility

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

#if FOXY_RAY_MODE == FOXY_RAY_RSM
/* DRAWBUFFERS:01 */
#else
/* DRAWBUFFERS:0 */
#endif

#if FOXY_RAY_MODE == FOXY_RAY_RSM
	#include "/lib/rsm_axis.glsl"
#endif

uniform sampler2D texture;

varying vec2 texcoord;
varying vec4 surfaceColor;

#if FOXY_RAY_MODE == FOXY_RAY_RSM
varying vec3 surfaceShadowNormal;
#endif

void main() {
	vec4 texel = texture2D(texture, texcoord) * surfaceColor;
	if (texel.a < 0.10) {
		discard;
	}
	gl_FragData[0] = vec4(1.0);

	#if FOXY_RAY_MODE == FOXY_RAY_RSM
		gl_FragData[1] = vec4(
			SrgbToLinear(Saturate3(texel.rgb)),
			RsmPackAxisNormal(normalize(surfaceShadowNormal))
		);
	#endif
}
