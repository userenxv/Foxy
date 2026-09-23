#include "/lib/cloud_coverage.glsl"

uniform sampler2D cloudWeatherMap;
uniform mat4 gbufferModelViewInverse;
uniform vec3 cameraPosition;

varying vec2 texcoord;

void main() {
	vec2 uv = clamp(texcoord, vec2(0.0), vec2(1.0));
	vec3 cameraWorldPos = cameraPosition + gbufferModelViewInverse[3].xyz;
	vec3 referenceCameraPos = CloudWorldToReference(cameraWorldPos);
	vec3 densityCameraPos = CloudCoverageUnscaleWorld(referenceCameraPos);
	float cloudTime = frameTimeCounter + WeatherWindDrift(FOXY_WIND_CLOUDS);
	vec2 advectedPosition = CloudCoverageCachePosition(uv, densityCameraPos, cloudTime);
	vec4 weather = texture2D(cloudWeatherMap, CloudCoverageWeatherUv(advectedPosition, cloudTime));
	float broadCoverage = texture2D(cloudWeatherMap, CloudCoverageBroadUv(advectedPosition, cloudTime)).r;
	gl_FragData[0] = vec4(weather.rgb, broadCoverage);
}
