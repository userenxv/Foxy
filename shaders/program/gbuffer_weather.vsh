// Included by gbuffers_weather.vsh, which owns the #version directive.

#define WEATHER

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform mat4 gbufferModelViewInverse;
uniform vec2 srJitter;
// Declared here as in every other sr.glsl consumer rather than inside sr.glsl: the
// type is uniform float everywhere, but centralizing it would mean touching every
// program to drop the duplicate.
uniform float viewWidth;
uniform float viewHeight;

#include "/lib/sr.glsl"
#include "/lib/weather_particles.glsl"

varying vec2 texcoord;
varying vec4 surfaceColor;
// Distance from the eye to this vertex, in blocks.
varying float weatherViewDistance;

void main() {
	vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;

	#if FOXY_WEATHER_SLANT > 0.0
		// Lean the streak in world space so it is a property of the falling particle
		// rather than of the camera.  The full 4x4 transform is used, not its rotation
		// part: the lean is a function of absolute height and of the particle's world
		// position, so dropping the translation would shear about the eye instead.
		vec3 scenePos = (gbufferModelViewInverse * (gl_ModelViewMatrix * gl_Vertex)).xyz;
		scenePos = WeatherParticleSlant(scenePos, frameTimeCounter, rainStrength);
		viewPos = gl_ModelViewMatrix * vec4(scenePos, 1.0);
	#endif

	gl_Position = gl_ProjectionMatrix * viewPos;
	SrScaleClipPositionJittered(gl_Position, srJitter);
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	surfaceColor = gl_Color;
	weatherViewDistance = length(viewPos.xyz);
}
