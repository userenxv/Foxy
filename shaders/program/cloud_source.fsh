#define FOXY_CLOUD_COVERAGE_CACHE_READ
uniform sampler2D colortex1;

#include "/lib/sky.glsl"
#include "/lib/celestial.glsl"
#include "/lib/clouds.glsl"
#include "/lib/cbr.glsl"

uniform sampler2D colortex7;
uniform mat4 gbufferModelView;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTimeCounter;
uniform float rainStrength;
uniform int frameCounter;

varying vec2 texcoord;

#include "/lib/sr.glsl"

float CloudStableRayPhase(
	const in vec3 cameraWorldPos,
	const in vec3 worldDir,
	const in vec4 blueNoise,
	const in int frameIndex
) {
	float bottom = FOXY_CLOUD_HEIGHT - CLOUD_BASE_VARIATION;
	float top = FOXY_CLOUD_HEIGHT + FOXY_CLOUD_THICKNESS;
	float tNear;
	float tFar;
	CloudLayerInterval(cameraWorldPos, worldDir, bottom, top, tNear, tFar);
	float t = tFar > tNear ? mix(tNear, tFar, 0.38) : CLOUD_TRACE_LIMIT * 0.25;
	vec3 anchor = cameraWorldPos + worldDir * clamp(t, 0.0, CLOUD_TRACE_LIMIT);
	vec3 phaseCoord = vec3(
		dot(anchor, vec3(0.00142, 0.00031, 0.00091)),
		dot(anchor, vec3(-0.00073, 0.00127, 0.00049)),
		dot(anchor, vec3(0.00056, -0.00042, 0.00111))
	);
	float worldPhaseA = ValueNoise3(phaseCoord + vec3(13.7, 41.3, 5.9));
	float worldPhaseB = ValueNoise3(phaseCoord * 2.11 + vec3(3.1, 17.9, 29.4));
	float worldPhase = fract(worldPhaseA * 0.72 + worldPhaseB * 0.28);
	float pixelPhase = fract(blueNoise.b + blueNoise.a * 0.61803398875);
	float stablePhase = fract(pixelPhase + (worldPhase - 0.5) * 0.20);
	float sequence = fract(float(frameIndex) * 0.61803398875 + pixelPhase * 0.37 + blueNoise.r * 0.21 + worldPhase * 0.07);
	return fract(stablePhase + (sequence - 0.5) * 0.68);
}

vec4 CloudEncodeSourceBuffer(const in vec4 cloud) {
	return vec4(EncodeSceneColor(max(cloud.rgb, vec3(0.0))), Saturate(cloud.a));
}

void CloudWriteSource(const in vec4 cloud) {
	vec4 encodedCloud = CloudEncodeSourceBuffer(cloud);
	gl_FragData[0] = encodedCloud;
	gl_FragData[1] = vec4(1.0, encodedCloud.a, 0.0, 1.0);
}

void CloudWriteSourceDistance(const in vec4 cloud, const in float cloudDistance) {
	vec4 encodedCloud = CloudEncodeSourceBuffer(cloud);
	gl_FragData[0] = encodedCloud;
	gl_FragData[1] = vec4(Saturate(cloudDistance / CLOUD_TRACE_LIMIT), encodedCloud.a, 0.0, 1.0);
}

float CloudSourceSafeDivisor(const in float x) {
	if (abs(x) < 1.0e-6) {
		return x < 0.0 ? -1.0e-6 : 1.0e-6;
	}
	return x;
}

vec3 CloudSourceScreenViewRay(const in vec2 uv) {
	vec2 ndc = uv * 2.0 - 1.0;
	vec4 view = gbufferProjectionInverse * vec4(ndc, 1.0, 1.0);
	return normalize(view.xyz / CloudSourceSafeDivisor(view.w));
}

vec3 CloudSourceCameraWorldPos() {
	return cameraPosition + gbufferModelViewInverse[3].xyz;
}

ivec2 CloudSourceRenderSize() {
	return max(ivec2(floor(vec2(viewWidth, viewHeight) * SrActiveRenderScale())), ivec2(1));
}

vec4 CloudSourceClamp(const in vec4 cloud) {
	float alpha = Saturate(cloud.a);
	vec3 color = min(max(cloud.rgb, vec3(0.0)), vec3(alpha * 5.20 + 0.16));
	return vec4(color, alpha);
}

void main() {
	#if FOXY_CLOUDS == 0 || defined(FOXY_DIM_NETHER) || defined(FOXY_DIM_END)
		CloudWriteSource(vec4(0.0));
		return;
	#endif



	ivec2 compactPixel = ivec2(floor(gl_FragCoord.xy));
	ivec2 renderSize = CloudSourceRenderSize();
	ivec2 fullPixel = CbrFullPixel(compactPixel, renderSize, frameCounter);
	int cloudSampleIndex = CbrTemporalSampleIndex(frameCounter);
	vec2 sourceUv = (vec2(fullPixel) + vec2(0.5)) / vec2(renderSize);

	vec2 fullPixelCoord = vec2(fullPixel);
	vec4 blueNoise = CloudBlueNoiseSample(fullPixelCoord, cloudSampleIndex, 1.0);
	vec3 viewDir = CloudSourceScreenViewRay(sourceUv);
	vec3 worldDir = normalize(mat3(gbufferModelViewInverse) * viewDir);
	vec3 physicalCameraWorldPos = CloudSourceCameraWorldPos();
	vec3 cloudCameraWorldPos = CloudWorldToReference(physicalCameraWorldPos);
	vec3 sunWorld = cloudVertexSunWorld;
	vec3 moonWorld = cloudVertexMoonWorld;

	vec3 skyColor = DecodeSkyLutColor(texture2D(colortex7, SkyViewLutUv(worldDir)).rgb);
	float rayPhase = CloudStableRayPhase(cloudCameraWorldPos, worldDir, blueNoise, cloudSampleIndex);
	float cloudDistance;
	vec4 clouds = RenderCloudSystemDetailed(cloudCameraWorldPos, worldDir, sunWorld, moonWorld, skyColor, frameTimeCounter, rainStrength, rayPhase, cloudDistance);
	cloudDistance = CloudReferenceDistanceToWorld(cloudDistance);
	clouds = CloudSourceClamp(clouds);



	CloudWriteSourceDistance(clouds, cloudDistance);
}
