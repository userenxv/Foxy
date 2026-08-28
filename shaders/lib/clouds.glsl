#ifndef FOXY_CLOUDS_GLSL
#define FOXY_CLOUDS_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/lighting.glsl"
#include "/lib/cloud_coverage.glsl"

#if FOXY_CLOUD_QUALITY == 0
	#define FOXY_CLOUD_VOLUME_LOOP_STEPS 96
	#define FOXY_CLOUD_LIGHT_ALPHA_EPS 0.0014
	#define FOXY_CLOUD_TRANSMIT_BREAK 0.052
#elif FOXY_CLOUD_QUALITY == 2
	#define FOXY_CLOUD_VOLUME_LOOP_STEPS 104
	#define FOXY_CLOUD_LIGHT_ALPHA_EPS 0.00035
	#define FOXY_CLOUD_TRANSMIT_BREAK 0.028
#else
	#define FOXY_CLOUD_VOLUME_LOOP_STEPS 84
	#define FOXY_CLOUD_LIGHT_ALPHA_EPS 0.00065
	#define FOXY_CLOUD_TRANSMIT_BREAK 0.035
#endif

#define FOXY_CLOUD_VOLUME_STEPS FOXY_CLOUD_STEPS
#define FOXY_CLOUD_MAX_LIGHT_STEPS 8

const float CLOUD_LOW_BOTTOM = FOXY_CLOUD_HEIGHT;
const float CLOUD_LOW_TOP = FOXY_CLOUD_HEIGHT + FOXY_CLOUD_THICKNESS;
const float CLOUD_TRACE_LIMIT = FOXY_CLOUD_RANGE;
const float CLOUD_PLANET_RADIUS = 6371000.0;
const float CLOUD_MAP_SCALE = 0.00022;
const float CLOUD_BASE_VARIATION = 120.0;

uniform sampler3D cloudBase3D;
uniform sampler3D cloudDetail3D;
uniform sampler2D cloudWeatherMap;
#if FOXY_CLOUD_BLOCK_SHAPE == 1
uniform sampler2D vanillaCloudMap;
#endif
uniform sampler2D cloudBlueNoise;
uniform sampler3D cloudStbnVec2;

#ifdef FOXY_FULLSCREEN_CLOUD_CACHE
varying vec3 cloudVertexSunWorld;
varying vec3 cloudVertexMoonWorld;
varying vec3 cloudVertexWorldSunLightColor;
varying vec3 cloudVertexWorldMoonLightColor;
varying vec3 cloudVertexWorldSkyAmbientColor;
varying float cloudVertexWorldSunAltitude;
varying float cloudVertexWorldMoonAltitude;

vec3 CloudUniformSunColor(const in float sunAltitude, const in float rainStrength) {
	return cloudVertexWorldSunLightColor;
}

vec3 CloudUniformMoonColor(const in float moonAltitude, const in float rainStrength) {
	return cloudVertexWorldMoonLightColor;
}

vec3 CloudUniformSkyAmbientColor(const in float sunAltitude, const in float rainStrength) {
	return cloudVertexWorldSkyAmbientColor;
}
#else
vec3 CloudUniformSunColor(const in float sunAltitude, const in float rainStrength) {
	return SunColor(sunAltitude, rainStrength);
}

vec3 CloudUniformMoonColor(const in float moonAltitude, const in float rainStrength) {
	return MoonColor(moonAltitude, rainStrength);
}

vec3 CloudUniformSkyAmbientColor(const in float sunAltitude, const in float rainStrength) {
	return SkyAmbientColor(sunAltitude, rainStrength);
}
#endif


#define CLOUD_UNDERSIDE_HEIGHT_TOGGLE 1.0

float CloudDensityScale() {
	return FOXY_CLOUD_MEDIUM_DENSITY_SCALE;
}

// Density remap preserves porous edges while increasing mature-core optical depth.
float CloudCoreDensityRemap(const in float density) {
	float d = Saturate(density);
	float coreWeight = smoothstep(0.24, 0.74, d);
	return d * mix(0.92, 1.20, coreWeight);
}

float CloudSize() {
	#if FOXY_CLOUD_BLOCK_SHAPE == 1
	return 1.0;
	#else
	return max(FOXY_CLOUD_CLOUD_SIZE, 0.01);
	#endif
}

vec3 CloudUnscaleWorld(const in vec3 worldPos) {
	float size = CloudSize();
	vec3 pivot = vec3(0.0, (CLOUD_LOW_BOTTOM + CLOUD_LOW_TOP) * 0.5, 0.0);
	return pivot + (worldPos - pivot) / size;
}

float CloudTraceLimit() {
	return CloudCoverageDetailRange();
}

float CloudVisibilityTraceLimit() {
	return CloudCoverageVisibilityRange();
}

float CloudRemapRange(const in float low, const in float high, const in float x) {
	return Saturate((x - low) / max(high - low, 1.0e-4));
}

vec4 CloudBlueNoiseSample(const in vec2 fragCoord, const in int frameCounter, const in float temporalEnabled) {
	float frame = mod(float(frameCounter), 64.0);
	vec2 texel = mod(floor(fragCoord), vec2(128.0));
	vec3 stbnUv = (vec3(texel, frame * Saturate(temporalEnabled)) + vec3(0.5)) / vec3(128.0, 128.0, 64.0);
	vec2 stbn = texture3D(cloudStbnVec2, stbnUv).rg;
	vec2 fallbackShift = vec2(17.0, 29.0) * frame * Saturate(temporalEnabled);
	vec2 fallbackUv = fract((floor(fragCoord) + fallbackShift + vec2(0.5)) / 128.0);
	vec4 fallback = texture2D(cloudBlueNoise, fallbackUv);
	vec2 jitter = mix(fallback.rg, stbn, 0.92);
	float scalar = fract(stbn.x + stbn.y * 0.754877666);
	return vec4(jitter, scalar, fallback.a);
}

float CloudAltitude(const in vec3 worldPos, const in vec3 shellOrigin) {
	vec2 localXZ = worldPos.xz - shellOrigin.xz;
	vec3 shellPos = vec3(localXZ.x, CLOUD_PLANET_RADIUS + worldPos.y, localXZ.y);
	return length(shellPos) - CLOUD_PLANET_RADIUS;
}

vec2 CloudSphereIntersection(
	const in vec3 rayOrigin,
	const in vec3 rayDir,
	const in float radius
) {
	vec3 localOrigin = vec3(0.0, CLOUD_PLANET_RADIUS + rayOrigin.y, 0.0);
	float b = dot(localOrigin, rayDir);
	float c = dot(localOrigin, localOrigin) - radius * radius;
	float h = b * b - c;
	if (h < 0.0) {
		return vec2(1.0e8, -1.0e8);
	}
	h = sqrt(h);
	return vec2(-b - h, -b + h);
}

float CloudHenyeyGreenstein(const in float mu, const in float g) {
	float gg = g * g;
	float denom = max(1.0 + gg - 2.0 * g * mu, 0.035);
	return (1.0 - gg) / (4.0 * PI * pow(denom, 1.5));
}

float CloudPhase(const in float mu) {
	float forward = CloudHenyeyGreenstein(mu, 0.70);
	float backward = CloudHenyeyGreenstein(mu, -0.30);
	float silver = CloudHenyeyGreenstein(mu, 0.94) * 0.24;
	return max(mix(forward, backward, 0.35), silver);
}

vec3 CloudWindDir() {
	return CloudCoverageWindDir();
}

#if defined(FOXY_CLOUD_COVERAGE_CACHE_READ)
vec4 CloudCoverageInputs(
	const in vec2 advectedPosition,
	const in vec3 densityCameraPos,
	const in float time
) {
	vec2 cacheUv = CloudCoverageCacheUv(advectedPosition, densityCameraPos, time);
	vec2 cacheSize = max(vec2(textureSize(colortex1, 0)), vec2(1.0));
	vec2 edge = 0.5 / cacheSize;
	if (all(greaterThanEqual(cacheUv, edge)) && all(lessThanEqual(cacheUv, vec2(1.0) - edge))) {
		return texture2D(colortex1, cacheUv);
	}

	vec4 weather = texture2D(cloudWeatherMap, CloudCoverageWeatherUv(advectedPosition, time));
	float broadCoverage = texture2D(cloudWeatherMap, CloudCoverageBroadUv(advectedPosition, time)).r;
	return vec4(weather.rgb, broadCoverage);
}
#endif

void CloudLayerInterval(
	const in vec3 rayOrigin,
	const in vec3 rayDir,
	const in float bottom,
	const in float top,
	out float tNear,
	out float tFar
) {
	float altitude = rayOrigin.y;
	if (altitude < bottom && rayDir.y <= 0.0) {
		tNear = 1.0e8;
		tFar = -1.0e8;
		return;
	}
	if (altitude > top && rayDir.y >= 0.0) {
		tNear = 1.0e8;
		tFar = -1.0e8;
		return;
	}

	vec2 outer = CloudSphereIntersection(rayOrigin, rayDir, CLOUD_PLANET_RADIUS + top);
	vec2 inner = CloudSphereIntersection(rayOrigin, rayDir, CLOUD_PLANET_RADIUS + bottom);
	tNear = 1.0e8;
	tFar = -1.0e8;

	if (outer.y <= 0.0) {
		return;
	}
	if (altitude < bottom) {
		tNear = max(inner.y, 0.0);
		tFar = outer.y;
	} else if (altitude > top) {
		tNear = max(outer.x, 0.0);
		tFar = inner.x > tNear ? inner.x : outer.y;
	} else {
		tNear = 0.0;
		tFar = rayDir.y < 0.0 && inner.x > 0.0 ? inner.x : outer.y;
	}

	tNear = max(tNear, 0.0);
	tFar = min(tFar, CloudVisibilityTraceLimit());
	if (tFar <= tNear) {
		tNear = 1.0e8;
		tFar = -1.0e8;
	}
}

float CloudHardHeightLimit() {
	#if FOXY_CLOUD_BLOCK_SHAPE == 1
	return 1.0;
	#else
	return max(FOXY_CLOUD_HARD_HEIGHT_LIMIT, 0.01);
	#endif
}

float CloudLowLayerBounds(const in vec3 worldPos, const in float time, out float bottom, out float top) {
	#if FOXY_CLOUD_BLOCK_SHAPE == 1
	float tileSize = 12.0 / max(FOXY_CLOUD_CLOUD_SIZE * FOXY_CLOUD_WORLD_SCALE, 0.01);
	bottom = CLOUD_LOW_BOTTOM;
	top = bottom + tileSize;
	return 0.5;
	#else
	float size = CloudSize();
	float center = (CLOUD_LOW_BOTTOM + CLOUD_LOW_TOP) * 0.5;
	float halfThickness = (FOXY_CLOUD_THICKNESS * size) * 0.5;
	bottom = center - halfThickness;
	top = center + halfThickness;
	return 0.5;
	#endif
}

float CloudPhysicalThickness() {
	#if FOXY_CLOUD_BLOCK_SHAPE == 1
	return 12.0 / max(FOXY_CLOUD_CLOUD_SIZE * FOXY_CLOUD_WORLD_SCALE, 0.01);
	#else
	return FOXY_CLOUD_THICKNESS;
	#endif
}

vec3 CloudAdvectedPosition(const in vec3 worldPos, const in float heightFraction, const in float time) {
	vec3 windDir = CloudWindDir();
	float windSpeed = FOXY_CLOUD_SPEED * 22.0;
	vec3 p = worldPos - windDir * (time * windSpeed);
	float topShear = heightFraction * heightFraction * FOXY_CLOUD_THICKNESS * 0.30;
	p -= windDir * topShear;
	return p;
}

vec3 CloudApplyTemperature(const in vec3 color, const in float temperature) {
	float warm = Saturate(temperature);
	float cool = Saturate(-temperature);
	vec3 tint = mix(vec3(1.0), vec3(0.82, 0.91, 1.10), cool);
	tint = mix(tint, vec3(1.13, 1.02, 0.84), warm);
	vec3 tinted = max(color, vec3(0.0)) * tint;
	float sourceLuma = max(Luma(color), 1.0e-4);
	float tintedLuma = max(Luma(tinted), 1.0e-4);
	return tinted * (sourceLuma / tintedLuma);
}

vec4 CloudShapeGradients(const in float cloudType) {
	const vec4 stratus = vec4(0.02, 0.05, 0.09, 0.11);
	const vec4 stratocumulus = vec4(0.02, 0.20, 0.48, 0.625);
	const vec4 cumulus = vec4(0.01, 0.0625, 0.78, 1.0);
	float stratusWeight = 1.0 - Saturate(cloudType * 2.0);
	float stratocumulusWeight = 1.0 - Saturate(abs(cloudType - 0.5) * 2.0);
	float cumulusWeight = Saturate((cloudType - 0.5) * 2.0);
	return stratus * stratusWeight + stratocumulus * stratocumulusWeight + cumulus * cumulusWeight;
}

float CloudShapeHeightGradient(const in float h, const in float cloudType) {
	vec4 gradient = CloudShapeGradients(cloudType);
	return smoothstep(gradient.x, gradient.y, h) - smoothstep(gradient.z, gradient.w, h);
}

float CloudShapeMacroCoverage(const in float weatherCoverage, const in float broadCoverage, const in float coverageLift) {
	float localState = Saturate(weatherCoverage + coverageLift);
	float regionalState = Saturate(broadCoverage + coverageLift * 0.45);
	float regionalGate = smoothstep(0.46, 0.70, regionalState);
	float cloudyCore = smoothstep(0.66, 0.90, regionalState);
	float brokenCoverage = localState * regionalGate;
	float cloudyFloor = cloudyCore * mix(0.38, 0.72, localState);
	float localStructure = smoothstep(0.25, 0.55, localState + cloudyCore * 0.20);
	return Saturate(max(brokenCoverage, cloudyFloor) * localStructure);
}

float CloudShapeHeightGradientControlled(
	const in float h,
	const in float cloudType,
	const in float verticalScale,
	const in float verticalContrast
) {
	float scaledH = Saturate((h - 0.5) / max(verticalScale, 0.01) + 0.5);
	float gradient = CloudShapeHeightGradient(scaledH, cloudType);
	return pow(Saturate(gradient), max(verticalContrast, 0.01));
}

struct CloudShapeWeather {
	float broadCoverage;
	float coverage;
	float convective;
	float cloudType;
};

CloudShapeWeather CloudShapeWeatherAt(
	const in vec3 worldPos,
	const in vec3 shellOrigin,
	const in float time,
	const in float rainStrength
) {
	CloudShapeWeather state;
	vec4 weatherSample;
	#if defined(FOXY_CLOUD_COVERAGE_CACHE_READ)
		vec4 weatherInputs = CloudCoverageInputs(worldPos.xz, shellOrigin, time);
		weatherSample = vec4(weatherInputs.rgb, 1.0);
		state.broadCoverage = Saturate(weatherInputs.a);
	#else
		weatherSample = texture2D(cloudWeatherMap, CloudCoverageWeatherUv(worldPos.xz, time));
		state.broadCoverage = Saturate(texture2D(cloudWeatherMap, CloudCoverageBroadUv(worldPos.xz, time)).r);
	#endif

	float coverageControl = Saturate(FOXY_CLOUD_COVERAGE + rainStrength * 0.20 + FOXY_CLOUD_HORIZONTAL_COVERAGE_BIAS);
	float coverageLift = coverageControl - 0.50 + max(FOXY_CLOUD_HORIZONTAL_COVERAGE_BIAS, 0.0) * 1.80;
	state.coverage = CloudShapeMacroCoverage(Saturate(weatherSample.r), state.broadCoverage, coverageLift);
	state.convective = smoothstep(0.58, 0.92, state.broadCoverage) * smoothstep(0.38, 0.82, state.coverage);
	float derivedType = smoothstep(0.28, 0.88, state.coverage);
	state.cloudType = Saturate(mix(mix(max(derivedType, state.convective), weatherSample.b, 0.35), 1.0, FOXY_CLOUD_CUMULUS_BIAS));
	return state;
}

struct CloudShapeProfile {
	float height;
	float normalizedHeight;
	float towerHeight;
	float rawCoverage;
	float coverage;
	float vertical;
	float occupancy;
};

CloudShapeProfile CloudShapeProfileAt(
	const in float heightFraction,
	const in float rainStrength,
	const in CloudShapeWeather weather
) {
	CloudShapeProfile profile;
	float hardHeightLimit = max(FOXY_CLOUD_HARD_HEIGHT_LIMIT, 0.01);
	profile.height = min(heightFraction, hardHeightLimit);
	profile.normalizedHeight = min(profile.height, 1.0);

	float extensionHeight = max(profile.height - 1.0, 0.0);
	float extensionSpan = max(hardHeightLimit - 1.0, 0.01);
	float extensionFade = 1.0 - smoothstep(extensionSpan * 0.20, extensionSpan, extensionHeight);
	float towerTop = mix(0.56, 1.0, weather.convective);
	profile.towerHeight = Saturate(profile.normalizedHeight / max(towerTop, 0.05));

	float verticalCoverage = Saturate(FOXY_CLOUD_COVERAGE + rainStrength * 0.20 + FOXY_CLOUD_VERTICAL_COVERAGE_BIAS);
	profile.rawCoverage = Saturate(verticalCoverage * weather.coverage);
	float baseCoverage = Saturate(profile.rawCoverage + (1.0 - profile.towerHeight) * mix(0.0, 0.14, weather.convective));
	float topCoverage = Saturate(profile.rawCoverage - smoothstep(mix(0.34, 0.62, weather.convective), 1.0, profile.towerHeight) * mix(0.30, 0.10, weather.convective));
	profile.coverage = mix(baseCoverage, topCoverage, profile.normalizedHeight * profile.normalizedHeight);

	profile.vertical = CloudShapeHeightGradientControlled(
		profile.towerHeight,
		weather.cloudType,
		max(FOXY_CLOUD_HEIGHT_GRADIENT_SCALE, 0.01),
		max(FOXY_CLOUD_HEIGHT_GRADIENT_CONTRAST, 0.01)
	);
	profile.vertical *= extensionFade;
	float gradientTop = towerTop * max(FOXY_CLOUD_TOP_LIMIT, 0.01);
	profile.vertical *= 1.0 - smoothstep(gradientTop, gradientTop + 0.10, profile.normalizedHeight);
	profile.occupancy = Saturate(profile.vertical * max(profile.coverage, profile.rawCoverage));
	return profile;
}

float CloudShapeAuthoredBody(
	const in vec4 baseNoise,
	const in CloudShapeProfile profile
) {
	float upperBody = smoothstep(0.12, 0.82, profile.towerHeight);
	float lobeVariation = baseNoise.b - 0.70;
	float cavityVariation = baseNoise.a - 0.71;
	float secondaryShape = lobeVariation * mix(0.10, 0.28, upperBody);
	secondaryShape -= cavityVariation * mix(0.04, 0.12, upperBody);
	secondaryShape += (baseNoise.g - 0.70) * 0.06 * (1.0 - upperBody);

	float lowerMass = smoothstep(0.00, 0.18, profile.towerHeight) * (1.0 - smoothstep(0.40, 0.82, profile.towerHeight));
	return Saturate(baseNoise.r + secondaryShape + lowerMass * profile.rawCoverage * 0.22);
}

float CloudShapeUndersideProfile(
	const in vec3 baseUv,
	const in float shapeHeight,
	const in float broadCoverage,
	const in float verticalProfile
) {
	float undersideStrength = max(FOXY_CLOUD_BASE_BREAKUP, 0.0) * max(FOXY_CLOUD_BOTTOM_RELIEF, 0.0) * CLOUD_UNDERSIDE_HEIGHT_TOGGLE;
	float undersideMaxBase = 0.165 * undersideStrength;
	if (undersideStrength <= 0.0 || shapeHeight >= undersideMaxBase + 0.080) {
		return verticalProfile;
	}

	float undersideFrequency = 0.62 / max(FOXY_CLOUD_BOTTOM_EROSION_SIZE, 0.10);
	vec3 undersideUv = vec3(baseUv.x * undersideFrequency, 0.173, baseUv.z * undersideFrequency);
	vec4 undersideNoise = texture3D(cloudBase3D, fract(undersideUv));
	float undersideMacro = Saturate(undersideNoise.r * 0.46 + undersideNoise.b * 0.20 + broadCoverage * 0.34);
	undersideMacro = smoothstep(0.20, 0.94, undersideMacro);
	float localCloudBase = mix(0.004, 0.165, undersideMacro) * undersideStrength;
	float undersideRamp = smoothstep(localCloudBase - 0.050, localCloudBase + 0.080, shapeHeight);
	return verticalProfile * mix(1.0, undersideRamp, Saturate(undersideStrength));
}

float CloudShapeApplyDetail(
	const in float authoredBody,
	const in vec3 detailUv,
	const in float height,
	const in float useDetail
) {
	if (useDetail <= 0.001 || FOXY_CLOUD_EROSION_SCALE <= 0.001) {
		return authoredBody;
	}

	vec3 detailNoise = texture3D(cloudDetail3D, fract(detailUv)).rgb;
	float multiFrequency = dot(detailNoise, vec3(0.52, 0.30, 0.18));
	float detailShape = smoothstep(0.42, 0.88, multiFrequency);
	float altitudeBlend = smoothstep(0.08, 0.52, height);
	float erosionPattern = mix(detailShape, 1.0 - detailShape, altitudeBlend);
	float heightResponse = mix(0.88, 0.72, altitudeBlend);
	float surfaceDisplacement = erosionPattern * 0.22 * max(FOXY_CLOUD_EROSION_SCALE, 0.0) * useDetail * heightResponse;
	return CloudRemapRange(surfaceDisplacement, 1.0, authoredBody);
}

float CloudShapeCoveredDensity(
	const in float authoredBody,
	const in CloudShapeProfile profile
) {
	float shapeField = authoredBody * profile.vertical;
	return CloudRemapRange(1.0 - profile.coverage, 1.0, shapeField) * profile.coverage;
}

float CloudShapeDensityWithCore(
	const in vec3 worldPos,
	const in vec3 shellOrigin,
	const in float time,
	const in float rainStrength,
	const in float useDetail,
	const in float heightFraction,
	out float dimensionalProfile,
	out float coreDensity
) {
	coreDensity = 0.0;
	if (heightFraction > max(FOXY_CLOUD_HARD_HEIGHT_LIMIT, 0.01)) {
		dimensionalProfile = 0.0;
		return 0.0;
	}

	vec3 windDir = CloudWindDir();
	vec3 p = worldPos;
	p.xz += windDir.xz * (time * FOXY_CLOUD_SPEED * 22.0);
	p.xz += windDir.xz * heightFraction * FOXY_CLOUD_THICKNESS * max(FOXY_CLOUD_VERTICAL_SHEAR, 0.0);
	vec3 shapeNoisePos = p;
	shapeNoisePos.y = CLOUD_LOW_BOTTOM + (p.y - CLOUD_LOW_BOTTOM) * (2500.0 / max(FOXY_CLOUD_THICKNESS, 1.0));

	CloudShapeWeather weather = CloudShapeWeatherAt(p, shellOrigin, time, rainStrength);
	CloudShapeProfile profile = CloudShapeProfileAt(heightFraction, rainStrength, weather);
	if (profile.occupancy <= 0.0015) {
		dimensionalProfile = profile.occupancy;
		return 0.0;
	}

	vec3 baseUv = shapeNoisePos * max(FOXY_CLOUD_SHAPE_BASE_SCALE, 1.0e-6);
	baseUv.xz += windDir.xz * time * FOXY_CLOUD_SPEED * 0.003;
	vec4 baseNoise = texture3D(cloudBase3D, fract(baseUv));
	profile.vertical = CloudShapeUndersideProfile(baseUv, profile.height, weather.broadCoverage, profile.vertical);
	float authoredBody = CloudShapeAuthoredBody(baseNoise, profile);
	float macroDensity = CloudShapeCoveredDensity(authoredBody, profile);
	dimensionalProfile = profile.vertical * profile.coverage;
	if (macroDensity <= 0.0001) {
		return 0.0;
	}

	vec3 detailUv = shapeNoisePos * max(FOXY_CLOUD_SHAPE_DETAIL_SCALE, 1.0e-6);
	detailUv.xz -= windDir.xz * time * FOXY_CLOUD_SPEED * 0.005;
	detailUv.y -= time * FOXY_CLOUD_SPEED * 0.020;
	float detailedBody = CloudShapeApplyDetail(authoredBody, detailUv, profile.normalizedHeight, useDetail);
	float finalCloud = CloudShapeCoveredDensity(detailedBody, profile);
	float densityPower = max(mix(FOXY_CLOUD_BOTTOM_DENSITY_POWER, 0.5, profile.normalizedHeight), 0.08);
	float densityScale = FOXY_CLOUD_DENSITY * CloudDensityScale();
	coreDensity = CloudCoreDensityRemap(pow(Saturate(macroDensity), densityPower)) * densityScale;
	return CloudCoreDensityRemap(pow(Saturate(finalCloud), densityPower)) * densityScale;
}

#if FOXY_CLOUD_BLOCK_SHAPE == 1
const float CLOUD_BLOCK_CORNER_RADIUS = 0.35;

float CloudBlockCellOccupancy(const in vec2 cell) {
	const float atlasSize = 256.0;
	vec2 atlasUv = (fract(cell / atlasSize) * atlasSize + vec2(0.5)) / atlasSize;
	return step(0.5, texture2D(vanillaCloudMap, atlasUv).a);
}

float CloudBlockHorizontalShape(const in vec2 worldPos, const in float time, out float interiorDistance) {
	float tileSize = 12.0 / max(FOXY_CLOUD_CLOUD_SIZE * FOXY_CLOUD_WORLD_SCALE, 0.01);
	vec2 cellPosition = (worldPos + vec2(time * 0.60, 0.0)) / tileSize;
	vec2 cell = floor(cellPosition);
	vec2 localPosition = fract(cellPosition);
	float occupancy = CloudBlockCellOccupancy(cell);
	vec2 sideDirection = mix(vec2(-1.0), vec2(1.0), step(vec2(0.5), localPosition));
	vec2 sideDistance = min(localPosition, 1.0 - localPosition);
	bool nearX = sideDistance.x < CLOUD_BLOCK_CORNER_RADIUS;
	bool nearY = sideDistance.y < CLOUD_BLOCK_CORNER_RADIUS;
	float neighborX = nearX ? CloudBlockCellOccupancy(cell + vec2(sideDirection.x, 0.0)) : occupancy;
	float neighborY = nearY ? CloudBlockCellOccupancy(cell + vec2(0.0, sideDirection.y)) : occupancy;

	if (occupancy > 0.5) {
		vec2 exposedDistance = vec2(CLOUD_BLOCK_CORNER_RADIUS);
		if (nearX && neighborX < 0.5) exposedDistance.x = sideDistance.x;
		if (nearY && neighborY < 0.5) exposedDistance.y = sideDistance.y;
		vec2 roundingDeficit = max(vec2(CLOUD_BLOCK_CORNER_RADIUS) - exposedDistance, vec2(0.0));
		interiorDistance = CLOUD_BLOCK_CORNER_RADIUS - length(roundingDeficit);
		return step(0.0, interiorDistance);
	}

	interiorDistance = -CLOUD_BLOCK_CORNER_RADIUS;
	if (nearX && nearY && neighborX > 0.5 && neighborY > 0.5
		&& CloudBlockCellOccupancy(cell + sideDirection) > 0.5) {
		vec2 cornerCenter = mix(
			vec2(CLOUD_BLOCK_CORNER_RADIUS),
			vec2(1.0 - CLOUD_BLOCK_CORNER_RADIUS),
			step(vec2(0.0), sideDirection)
		);
		interiorDistance = length(localPosition - cornerCenter) - CLOUD_BLOCK_CORNER_RADIUS;
		return step(0.0, interiorDistance);
	}
	return 0.0;
}

float CloudBlockDensityWithCore(
	const in vec3 worldPos,
	const in float time,
	const in float rainStrength,
	const in float heightFraction,
	out float dimensionalProfile,
	out float coreDensity
) {
	float horizontalInterior;
	float horizontalShape = CloudBlockHorizontalShape(worldPos.xz, time, horizontalInterior);
	if (horizontalShape < 0.5 || heightFraction <= 0.0 || heightFraction >= 1.0) {
		dimensionalProfile = 0.0;
		coreDensity = 0.0;
		return 0.0;
	}

	float verticalInterior = min(heightFraction, 1.0 - heightFraction);
	vec2 roundingDeficit = max(
		vec2(CLOUD_BLOCK_CORNER_RADIUS) - vec2(max(horizontalInterior, 0.0), verticalInterior),
		vec2(0.0)
	);
	float roundedShape = 1.0 - smoothstep(0.325, 0.375, length(roundingDeficit));
	float coverage = Saturate(FOXY_CLOUD_COVERAGE + FOXY_CLOUD_VERTICAL_COVERAGE_BIAS + rainStrength * 0.20);
	dimensionalProfile = horizontalShape * roundedShape * coverage;
	float densityPower = max(FOXY_CLOUD_BOTTOM_DENSITY_POWER, 0.08);
	float density = CloudCoreDensityRemap(pow(Saturate(dimensionalProfile), densityPower)) * FOXY_CLOUD_DENSITY * CloudDensityScale();
	coreDensity = density;
	return density;
}
#endif

float CloudLowDensityCoreWithCore(
	const in vec3 worldPos,
	const in vec3 shellOrigin,
	const in float time,
	const in float rainStrength,
	const in float useDetail,
	out float heightFraction,
	out float dimensionalProfile,
	out float coreDensity
) {
	coreDensity = 0.0;
	float bottom;
	float top;
	CloudLowLayerBounds(worldPos, time, bottom, top);
	float altitude = CloudAltitude(worldPos, shellOrigin);
	float h = (altitude - bottom) / max(top - bottom, 1.0e-4);
	heightFraction = Saturate(h);
	dimensionalProfile = 0.0;
	float traceTop = bottom + (top - bottom) * CloudHardHeightLimit();
	float traceH = (altitude - bottom) / max(traceTop - bottom, 1.0e-4);
	if (traceH <= -0.18 || traceH >= 1.035) {
		return 0.0;
	}

	float clampedH = clamp(h, 0.0, max(1.5, CloudHardHeightLimit()));
	#if FOXY_CLOUD_BLOCK_SHAPE == 1
	return CloudBlockDensityWithCore(worldPos, time, rainStrength, clampedH, dimensionalProfile, coreDensity);
	#else
	vec3 densityWorldPos = CloudUnscaleWorld(worldPos);
	vec3 densityShellOrigin = CloudUnscaleWorld(shellOrigin);
	return CloudShapeDensityWithCore(densityWorldPos, densityShellOrigin, time, rainStrength, useDetail, clampedH, dimensionalProfile, coreDensity);
	#endif
}

float CloudLowDensityCoarse(
	const in vec3 worldPos,
	const in vec3 shellOrigin,
	const in float time,
	const in float rainStrength
) {
	float h;
	float dimensionalProfile;
	float coreDensity;
	return CloudLowDensityCoreWithCore(worldPos, shellOrigin, time, rainStrength, 0.0, h, dimensionalProfile, coreDensity);
}

float CloudLightOpticalDepth(
	const in vec3 worldPos,
	const in vec3 shellOrigin,
	const in vec3 lightDir,
	const in float time,
	const in float rainStrength
) {
	float bottom;
	float top;
	CloudLowLayerBounds(worldPos, time, bottom, top);
	top = bottom + (top - bottom) * CloudHardHeightLimit();
	float tNear;
	float tFar;
	CloudLayerInterval(worldPos, lightDir, bottom, top, tNear, tFar);
	if (tFar <= tNear) {
		return 0.0;
	}
	float activeThickness = CloudPhysicalThickness();
	float maxLength = min(tFar - tNear, activeThickness * max(1.55, CloudHardHeightLimit() * 1.12));
	int lightSteps = int(FOXY_CLOUD_LIGHT_STEPS);
	if (lightSteps < 1) {
		lightSteps = 1;
	}
	if (lightSteps > FOXY_CLOUD_MAX_LIGHT_STEPS) {
		lightSteps = FOXY_CLOUD_MAX_LIGHT_STEPS;
	}
	float viewDistance = length(worldPos - shellOrigin);
	float farLighting = smoothstep(CloudTraceLimit(), CloudTraceLimit() * 1.5, viewDistance);
	int farLightSteps = min(lightSteps, 2);
	lightSteps = int(floor(mix(float(lightSteps), float(farLightSteps), farLighting) + 0.5));
	const float stepGrowth = 1.65;
	float stepWeightSum = (pow(stepGrowth, float(lightSteps)) - 1.0) / (stepGrowth - 1.0);
	float segmentLength = maxLength / max(stepWeightSum, 1.0);
	float segmentStart = tNear;
	float opticalDepth = 0.0;
	for (int i = 0; i < FOXY_CLOUD_MAX_LIGHT_STEPS; i++) {
		if (i >= lightSteps) {
			break;
		}
		vec3 p = worldPos + lightDir * (segmentStart + segmentLength * 0.5);
		opticalDepth += CloudLowDensityCoarse(p, shellOrigin, time, rainStrength) * segmentLength;
		segmentStart += segmentLength;
		segmentLength *= stepGrowth;
	}
	return opticalDepth;
}

#if FOXY_CLOUD_MULTISCATTERING > 0
float CloudTransportIntegral(
	const in float opticalDepth,
	const in float sourceLoss,
	const in float receiverLoss
) {
	float rateDifference = receiverLoss - sourceLoss;
	if (abs(rateDifference) < 1.0e-4) {
		return opticalDepth * exp(-sourceLoss * opticalDepth);
	}
	return (
		exp(-sourceLoss * opticalDepth) -
		exp(-receiverLoss * opticalDepth)
	) / rateDifference;
}

vec2 CloudDiffuseReservoirs(
	const in float opticalDepth,
	const in float powder
) {
	float tau = max(opticalDepth, 0.0);
	float scatteringProbability = Saturate(powder);
	float firstLoss = mix(0.46, 0.30, scatteringProbability);
	float firstFeed = mix(0.18, 0.30, scatteringProbability);
	float firstReservoir = firstFeed * CloudTransportIntegral(
		tau,
		1.0,
		firstLoss
	);

	float secondReservoir = 0.0;
	#if FOXY_CLOUD_MULTISCATTERING == 2
		float secondLoss = mix(0.26, 0.16, scatteringProbability);
		float secondFeed = mix(0.08, 0.16, scatteringProbability);
		float firstResponse = CloudTransportIntegral(
			tau,
			firstLoss,
			secondLoss
		);
		float directResponse = CloudTransportIntegral(
			tau,
			1.0,
			secondLoss
		);
		secondReservoir = firstFeed * secondFeed /
			max(1.0 - firstLoss, 1.0e-4) *
			max(firstResponse - directResponse, 0.0);
	#endif
	return max(vec2(firstReservoir, secondReservoir), vec2(0.0));
}

float CloudSunMultipleScattering(
	const in float opticalDepth,
	const in float primaryPhase,
	const in float powder
) {
	float tau = max(opticalDepth, 0.0);
	vec2 diffuseReservoirs = CloudDiffuseReservoirs(tau, powder);
	float angularMemory = exp(-tau * mix(0.80, 0.45, Saturate(powder)));
	float diffusePhase = mix(
		5.6 / (4.0 * PI),
		primaryPhase,
		0.18 * angularMemory
	);
	return exp(-tau) * primaryPhase +
		(diffuseReservoirs.x + diffuseReservoirs.y) * diffusePhase * FOXY_CLOUD_MULTISCATTER_SCALE;
}

float CloudIsotropicMultipleScattering(
	const in float opticalDepth,
	const in float powder
) {
	float tau = max(opticalDepth, 0.0);
	vec2 diffuseReservoirs = CloudDiffuseReservoirs(tau, powder);
	return exp(-tau) + (diffuseReservoirs.x + diffuseReservoirs.y) * FOXY_CLOUD_MULTISCATTER_SCALE;
}
#endif

vec3 CloudSampleLighting(
	const in vec3 worldPos,
	const in vec3 shellOrigin,
	const in vec3 viewDir,
	const in vec3 sunDir,
	const in vec3 moonDir,
	const in vec3 skyColor,
	const in float density,
	const in float sampleHeightFraction,
	const in float sampleDimensionalProfile,
	const in float sampleCoreDensity,
	const in float time,
	const in float rainStrength,
	const in float cachedOpticalDepthSun,
	const in float reuseOpticalDepthSun,
	out float resolvedOpticalDepthSun
) {
	float sunAltitude = sunDir.y;
	float moonAltitude = moonDir.y;
	float solarDiscVisibility = SolarDiscVisibility(sunAltitude);
	float useSunDirection = step(0.01, solarDiscVisibility);
	vec3 lightDir = normalize(mix(moonDir, sunDir, useSunDirection));
	vec3 lightColor = CloudUniformSunColor(sunAltitude, rainStrength) * solarDiscVisibility;
	lightColor += CloudUniformMoonColor(moonAltitude, rainStrength) * (1.0 - solarDiscVisibility) * 1.18;

	float h = sampleHeightFraction;
	float dimensionalProfile = sampleDimensionalProfile;
	float localDensity = max(sampleCoreDensity, 0.0);

	float opticalDepthSun = 0.0;
	if (reuseOpticalDepthSun > 0.5) {
		opticalDepthSun = max(cachedOpticalDepthSun, 0.0);
	} else {
		opticalDepthSun = CloudLightOpticalDepth(worldPos, shellOrigin, lightDir, time, rainStrength);
	}
	resolvedOpticalDepthSun = opticalDepthSun;

	float mu = dot(viewDir, lightDir);
	float coreOcclusion = smoothstep(0.22, 0.78, dimensionalProfile) * smoothstep(0.030, 0.22, localDensity);
	float sunOptical = (opticalDepthSun * 0.0070 + density * 0.54 + dimensionalProfile * 0.36 + coreOcclusion * 0.18) * mix(0.96, 1.22, rainStrength);
	float primaryTransmission = exp(-sunOptical);
	float softTransmission = exp(-sunOptical * 0.28);
	float rawPhase = CloudPhase(mu) * 5.6;
	float phasePeak = rawPhase / (1.0 + max(rawPhase - 0.55, 0.0) * 0.70);
	float broadPhase = mix(0.44, phasePeak, 0.28);
	float structure = smoothstep(0.018, 0.30, density + dimensionalProfile * 0.72);
	float verticalProbability = 0.22 + 0.78 * smoothstep(0.020, 0.30, h);
	float powder = 1.0 - exp(-(localDensity * 3.8 + dimensionalProfile * 1.10) * 1.75);
	#if FOXY_CLOUD_MULTISCATTERING == 0
		float softDirect = softTransmission * broadPhase * 0.24;
		float directionalScatter = primaryTransmission * phasePeak + softDirect;
	#else
		float directionalScatter = CloudSunMultipleScattering(
			sunOptical,
			phasePeak,
			powder
		);
	#endif
	// Sunset lighting separates the powder rim from dense-body illumination.
	float sunsetBand = smoothstep(-0.12, 0.015, sunAltitude)
		* (1.0 - smoothstep(0.08, 0.42, sunAltitude));
	float sunFacingBase = Saturate(mu * 0.5 + 0.5);
	float sunFacing = sunFacingBase * sunFacingBase * sunFacingBase;
	float thinEdge = smoothstep(0.05, 0.85, primaryTransmission);
	float upperCloud = smoothstep(0.15, 0.85, h);
	float firePresence = sunsetBand * sunFacing
		* mix(0.35, 1.0, thinEdge)
		* mix(0.55, 1.0, upperCloud)
		* (1.0 - rainStrength * 0.70);
	float solarLuma = max(Luma(lightColor), 0.0);
	vec3 warmSun = lightColor / max(solarLuma, 1.0e-4);
	float silverLining = firePresence * (0.12 + 0.70 * thinEdge);
	// Silver lining is view-dependent; illuminated-face warmth is not.
	float sunlitSurface = sunsetBand
		* (0.28 + 0.72 * verticalProbability)
		* (0.34 + 0.66 * structure)
		* (0.42 + 0.58 * Saturate(powder))
		* (1.0 - rainStrength * 0.58);
	float surfaceTint = Saturate(sunlitSurface * 0.84);
	float powderSilver = sunsetBand * sunFacing * thinEdge
		* (0.55 + 0.45 * Saturate(powder));
	directionalScatter += powderSilver * (0.16 + 0.34 * Saturate(1.0 - powder));
	float directEnergy = directionalScatter * (0.22 + 0.94 * structure) * verticalProbability * mix(0.82, 1.08, powder);
	vec3 direct = lightColor * directEnergy * mix(0.70, 0.46, rainStrength);
	// Warm face lighting modifies direct scattering only.
	direct *= mix(vec3(1.0), warmSun, surfaceTint);
	direct *= mix(vec3(1.0), warmSun, silverLining * 0.78);

	float skyOptical = (density * 0.46 + dimensionalProfile * 0.82 + coreOcclusion * 0.16) * CloudPhysicalThickness() * mix(0.20, 0.38, Saturate(1.0 - h)) * 0.0038;
	skyOptical += density * 0.20 + dimensionalProfile * 0.28;
	float skyPrimary = exp(-skyOptical);
	float skySoft = exp(-skyOptical * 0.22);
	float topAccess = 0.18 + 0.82 * smoothstep(0.04, 0.84, h);
	float bottomAccess = 1.0 - smoothstep(0.08, 0.45, h);
	vec3 skyAmbient = CloudUniformSkyAmbientColor(sunAltitude, rainStrength);
	vec3 skyIrradiance = mix(skyAmbient, skyColor, 0.18);
	float primarySkyEnergy = skyPrimary * topAccess * (0.36 + 0.46 * exp(-dimensionalProfile * 0.90));
	#if FOXY_CLOUD_MULTISCATTERING == 0
		float diffuseSkyEnergy = skySoft * (0.065 + 0.105 * structure) * (0.72 + 0.28 * topAccess + 0.10 * bottomAccess);
	#else
		float skyMultipleEnergy = CloudIsotropicMultipleScattering(skyOptical, powder);
		float skyHigherOrders = max(skyMultipleEnergy - skyPrimary, 0.0);
		float diffuseSkyEnergy = skySoft * (0.035 + 0.055 * structure)
			+ skyHigherOrders * (0.055 + 0.085 * structure);
		diffuseSkyEnergy *= 0.72 + 0.28 * topAccess + 0.10 * bottomAccess;
	#endif
	vec3 neutralSky = mix(vec3(Luma(skyIrradiance)), skyIrradiance, 0.52);
	vec3 skyIndirect = skyIrradiance * primarySkyEnergy + neutralSky * diffuseSkyEnergy;
	float warmFacing = sunFacing * sunFacingBase;
	vec3 warmFill = warmSun * solarLuma * sunsetBand
		* warmFacing
		* smoothstep(0.42, 0.92, h)
		* smoothstep(0.08, 0.75, primaryTransmission)
		* (0.018 + 0.032 * Saturate(powder));
	skyIndirect += warmFill;

	float groundTransmission = 1.0;
	float groundGate = 0.0;
	vec3 groundBounce = vec3(0.0);
	if (solarDiscVisibility > 0.0) {
		float groundOptical = density * Saturate(h) * CloudPhysicalThickness() * 0.0015 + dimensionalProfile * 0.18;
		groundTransmission = exp(-groundOptical);
		groundGate = solarDiscVisibility * (1.0 - smoothstep(0.58, 1.0, h));
		#if FOXY_CLOUD_MULTISCATTERING == 2
			float groundMultipleEnergy = CloudIsotropicMultipleScattering(groundOptical, powder);
			float groundEnergy = groundMultipleEnergy * groundGate * (0.030 + 0.012 * structure);
		#else
			float groundEnergy = groundTransmission * groundGate * (0.052 + 0.018 * structure);
		#endif
		vec3 groundAlbedo = vec3(0.58, 0.56, 0.50);
		vec3 groundRadiance = groundAlbedo * (skyIrradiance + lightColor * (max(lightDir.y, 0.0) / PI));
		groundBounce = groundRadiance * groundEnergy * (1.0 - rainStrength * 0.35);
	}
	vec3 lighting = direct + skyIndirect + groundBounce;
	float sunsetTemperature = FOXY_CLOUD_TEMPERATURE * (1.0 - sunsetBand * 0.85);
	vec3 correctedLighting = CloudApplyTemperature(lighting, sunsetTemperature);
	float edgeGain = 1.0 + firePresence * (0.18 + 0.42 * thinEdge);
	return correctedLighting * edgeGain;
}

float CloudMarchWarp(const in float u, const in float viewFlatness) {
	float s = u * u * (3.0 - 2.0 * u);
	return mix(s, u, viewFlatness * 0.35);
}

float CloudMarchDistance(
	const in float u,
	const in float tNear,
	const in float tFar,
	const in float detailLimit,
	const in float viewFlatness
) {
	float nearEnd = clamp(detailLimit, tNear, tFar);
	bool hasNear = nearEnd > tNear + 1.0;
	bool hasFar = tFar > nearEnd + 1.0;
	if (hasNear && hasFar) {
		const float nearStepShare = 0.78;
		if (u < nearStepShare) {
			float nearU = Saturate(u / nearStepShare);
			return mix(tNear, nearEnd, CloudMarchWarp(nearU, viewFlatness));
		}
		float farU = Saturate((u - nearStepShare) / (1.0 - nearStepShare));
		return mix(nearEnd, tFar, pow(farU, 1.28));
	}
	return mix(tNear, tFar, CloudMarchWarp(u, viewFlatness));
}

float CloudSegmentDensity(
	const in vec3 rayOrigin,
	const in vec3 rayDir,
	const in float t0,
	const in float t1,
	const in vec3 shellOrigin,
	const in float time,
	const in float rainStrength,
	const in float detail,
	out vec3 samplePos,
	out float sampleDistance,
	out float sampleHeightFraction,
	out float sampleDimensionalProfile,
	out float sampleCoreDensity
) {
	float midDistance = (t0 + t1) * 0.5;
	sampleHeightFraction = 0.0;
	sampleDimensionalProfile = 0.0;
	sampleCoreDensity = 0.0;
	float tm = midDistance;
	vec3 pm = rayOrigin + rayDir * tm;
	float density = CloudLowDensityCoreWithCore(pm, shellOrigin, time, rainStrength, detail, sampleHeightFraction, sampleDimensionalProfile, sampleCoreDensity);
	samplePos = pm;
	sampleDistance = tm;
	return density;
}

vec4 CloudMarchLayer(
	const in vec3 rayOrigin,
	const in vec3 rayDir,
	const in vec3 sunDir,
	const in vec3 moonDir,
	const in vec3 skyColor,
	const in float bottom,
	const in float top,
	const in float extinction,
	const in float time,
	const in float rainStrength,
	const in float rayPhaseSample,
	out vec3 undersideSampling,
	out float apparentDistance
) {
	float tNear;
	float tFar;
	CloudLayerInterval(rayOrigin, rayDir, bottom, top, tNear, tFar);
	apparentDistance = 1.0e8;
	undersideSampling = vec3(0.0);
	if (tFar <= tNear) {
		return vec4(0.0);
	}

	float traceLength = tFar - tNear;
	float detailLimit = CloudTraceLimit();
	float viewFlatness = 1.0 - abs(rayDir.y);
	if (traceLength <= 1.0) {
		return vec4(0.0);
	}

	int baseSteps = int(FOXY_CLOUD_VOLUME_STEPS);
	int maxBaseSteps = FOXY_CLOUD_VOLUME_LOOP_STEPS - 1;
	if (baseSteps < 4) {
		baseSteps = 4;
	}
	if (baseSteps > maxBaseSteps) {
		baseSteps = maxBaseSteps;
	}
	int maxSteps = baseSteps;
	float invSteps = 1.0 / max(float(maxSteps), 1.0);
	vec3 scattering = vec3(0.0);
	float transmittance = 1.0;
	float weightedDistance = 0.0;
	float weightSum = 0.0;
	float rayPhase = fract(rayPhaseSample) - 0.5;
	float phaseStrength = 0.92;
	float phaseOffset = rayPhase * invSteps * phaseStrength;
	float layerPad = max((top - bottom) * 0.035, 24.0);
	float lowerHorizonCut = Saturate((bottom - rayOrigin.y) / max(detailLimit, 1.0));
	float upperHorizonCut = Saturate((rayOrigin.y - top) / max(detailLimit, 1.0));
	float upwardGate = rayOrigin.y < bottom - layerPad ? smoothstep(lowerHorizonCut + 0.010, lowerHorizonCut + 0.065, rayDir.y) : 1.0;
	float downwardGate = rayOrigin.y > top + layerPad ? smoothstep(upperHorizonCut + 0.010, upperHorizonCut + 0.065, -rayDir.y) : 1.0;
	float flatViewStability = smoothstep(0.50, 0.98, viewFlatness);
	float cachedOpticalDepthSun = 0.0;
	float cachedOpticalDepthValid = 0.0;
	float cachedOpticalDepthDistance = 0.0;
	float cachedOpticalDepthDensity = 0.0;
	float cachedOpticalDepthProfile = 0.0;

	for (int i = 0; i < FOXY_CLOUD_VOLUME_LOOP_STEPS; i++) {
		if (i >= maxSteps) {
			break;
		}
		float fi = float(i);
		float u0Base = fi * invSteps;
		float u1Base = (fi + 1.0) * invSteps;
		float u0 = clamp(u0Base + phaseOffset, 0.0, 1.0);
		float u1 = clamp(u1Base + phaseOffset, 0.0, 1.0);
		if (i == 0) {
			u0 = 0.0;
		}
		if (i == maxSteps - 1) {
			u1 = 1.0;
		}
		if (u1 <= u0 + 1.0e-4) {
			continue;
		}
		float t0 = CloudMarchDistance(u0, tNear, tFar, detailLimit, viewFlatness);
		float t1 = CloudMarchDistance(u1, tNear, tFar, detailLimit, viewFlatness);
		float segmentLength = max(t1 - t0, traceLength * 1.0e-4);
		float segmentMid = (t0 + t1) * 0.5;
		float detail = 1.0 - smoothstep(detailLimit * 0.82, detailLimit, segmentMid);
		vec3 p;
		float distanceToSample;
		float sampleHeightFraction;
		float sampleDimensionalProfile;
		float sampleCoreDensity;
		float density = CloudSegmentDensity(rayOrigin, rayDir, t0, t1, rayOrigin, time, rainStrength, detail, p, distanceToSample, sampleHeightFraction, sampleDimensionalProfile, sampleCoreDensity);
		if (density > 0.001) {
			float visibilityGate = upwardGate * downwardGate;
			float effectiveDensity = density * visibilityGate;
			float farAlphaStability = smoothstep(2600.0, 7800.0, distanceToSample) * flatViewStability;
			float stableDensity = min(effectiveDensity, sqrt(max(effectiveDensity, 0.0)) * 0.36);
			effectiveDensity = mix(effectiveDensity, stableDensity, farAlphaStability);
			if (effectiveDensity <= 0.001) {
				continue;
			}

			float optical = effectiveDensity * segmentLength * extinction;
			float stepTransmittance = exp(-optical);
			float visibleAlpha = transmittance * (1.0 - stepTransmittance);
			float nextTransmittance = transmittance * stepTransmittance;
			if (visibleAlpha > FOXY_CLOUD_LIGHT_ALPHA_EPS) {
				float lightingReuseLod = smoothstep(3600.0, 10500.0, distanceToSample) * flatViewStability;
				float weakVisible = 1.0 - smoothstep(FOXY_CLOUD_LIGHT_ALPHA_EPS * 3.0, FOXY_CLOUD_LIGHT_ALPHA_EPS * 28.0, visibleAlpha);
				float weakDensity = 1.0 - smoothstep(0.035, 0.16, effectiveDensity);
				float cacheFresh = 1.0 - smoothstep(2600.0, 14000.0, abs(distanceToSample - cachedOpticalDepthDistance));
				float cacheShapeDelta = abs(effectiveDensity - cachedOpticalDepthDensity) + abs(sampleDimensionalProfile - cachedOpticalDepthProfile) * 0.55;
				float cacheShape = 1.0 - smoothstep(0.020, 0.14, cacheShapeDelta);
				float reuseOpticalDepth = cachedOpticalDepthValid * lightingReuseLod * max(weakVisible, weakDensity) * cacheFresh * cacheShape;
				float resolvedOpticalDepthSun = 0.0;
				vec3 lighting = CloudSampleLighting(p, rayOrigin, rayDir, sunDir, moonDir, skyColor, effectiveDensity, sampleHeightFraction, sampleDimensionalProfile, sampleCoreDensity, time, rainStrength, cachedOpticalDepthSun, reuseOpticalDepth, resolvedOpticalDepthSun
				);
				if (reuseOpticalDepth <= 0.48) {
					cachedOpticalDepthSun = resolvedOpticalDepthSun;
					cachedOpticalDepthValid = 1.0;
					cachedOpticalDepthDistance = distanceToSample;
					cachedOpticalDepthDensity = effectiveDensity;
					cachedOpticalDepthProfile = sampleDimensionalProfile;
				}
				scattering += lighting * visibleAlpha;
				weightedDistance += distanceToSample * visibleAlpha;
				weightSum += visibleAlpha;
			}
			transmittance = nextTransmittance;
			if (transmittance < FOXY_CLOUD_TRANSMIT_BREAK) {
				break;
			}
		}
	}

	float alpha = Saturate(1.0 - transmittance);
	if (weightSum > 1.0e-5) {
		apparentDistance = weightedDistance / weightSum;
	}
	// Apply aerial perspective after cloud lighting to preserve distant atmospheric hue.
	float distanceFog = 1.0 - exp(-apparentDistance * (0.000010 + FOXY_FOG_DENSITY * 0.000014));
	float horizonAerial = smoothstep(0.32, 0.96, 1.0 - abs(rayDir.y));
	float aerialPerspective = distanceFog * mix(0.16, 0.70, horizonAerial);
	scattering = mix(scattering, skyColor * alpha, Saturate(aerialPerspective));
	return vec4(max(scattering, vec3(0.0)), alpha);
}

vec4 RenderCloudSystemDetailed(
	const in vec3 cameraWorldPos,
	const in vec3 worldDir,
	const in vec3 sunDir,
	const in vec3 moonDir,
	const in vec3 skyColor,
	const in float time,
	const in float rainStrength,
	const in float rayPhaseSample,
	out float apparentDistance
) {
	apparentDistance = CLOUD_TRACE_LIMIT;
	if (FOXY_CLOUDS == 0) {
		return vec4(0.0);
	}

	float mainDistance = CLOUD_TRACE_LIMIT;
	vec4 cloud = vec4(0.0);
	vec3 undersideSampling = vec3(0.0);
	float lowLayerBottom;
	float lowLayerTop;
	CloudLowLayerBounds(cameraWorldPos, time, lowLayerBottom, lowLayerTop);
	float lowLayerRawBottom = lowLayerBottom;
	float lowLayerRawTop = lowLayerTop;
	#if FOXY_CLOUD_BLOCK_SHAPE == 0
	lowLayerBottom -= CLOUD_BASE_VARIATION * CloudSize();
	#endif
	lowLayerTop = lowLayerRawBottom + (lowLayerRawTop - lowLayerRawBottom) * CloudHardHeightLimit();
	cloud = CloudMarchLayer(
		cameraWorldPos,
		worldDir,
		sunDir,
		moonDir,
		skyColor,
		lowLayerBottom,
		lowLayerTop,
		0.0102 * FOXY_CLOUD_EXTINCTION_SCALE,
		time,
		rainStrength,
		rayPhaseSample,
		undersideSampling,
		mainDistance
	);
	apparentDistance = mainDistance;

	cloud.a = Saturate(cloud.a);
	cloud.rgb = min(max(cloud.rgb, vec3(0.0)), vec3(cloud.a * 5.40 + 0.18));
	return cloud;
}

const vec2 CLOUD_SHADOW_CACHE_SIZE = vec2(256.0, 192.0);
const vec2 CLOUD_SHADOW_CACHE_EXTENT = vec2(4096.0, 3072.0);

vec2 CloudShadowCacheCenter(const in vec3 cameraWorldPos, const in vec3 lightDir) {
	vec3 referenceCameraWorldPos = CloudWorldToReference(cameraWorldPos);
	float cloudPlane = CLOUD_LOW_BOTTOM + CloudPhysicalThickness() * 0.42;
	float t = max((cloudPlane - referenceCameraWorldPos.y) / max(lightDir.y, 0.006), 0.0);
	return referenceCameraWorldPos.xz + lightDir.xz * t;
}

float CloudShadowVisibilityAtPlane(
	const in vec2 planePosition,
	const in float lightAltitude,
	const in float time,
	const in float rainStrength
) {
	if (FOXY_CLOUDS == 0 || FOXY_CLOUD_SHADOW_STRENGTH <= 0.001 || lightAltitude <= 0.006) {
		return 1.0;
	}

	#if FOXY_CLOUD_BLOCK_SHAPE == 1
	float blockInterior;
	float blockCoverage = CloudBlockHorizontalShape(planePosition, time, blockInterior);
	float blockAngleFade = smoothstep(0.006, 0.15, lightAltitude);
	return 1.0 - blockCoverage * FOXY_CLOUD_SHADOW_STRENGTH * blockAngleFade;
	#else
	float cloudPlane = CLOUD_LOW_BOTTOM + CloudPhysicalThickness() * 0.42;
	vec3 p = vec3(planePosition.x, cloudPlane, planePosition.y);
	vec3 advected = CloudAdvectedPosition(p, 0.46, time);
	float coverage = Saturate(FOXY_CLOUD_COVERAGE * 0.96 + rainStrength * 0.18);
	vec2 weather = texture2D(cloudWeatherMap, fract((advected.xz + cloudDailyOffset) * (CLOUD_MAP_SCALE * FOXY_CLOUD_SHAPE_SCALE))).xy;
	float localCoverage = Saturate(weather.x * (coverage * 1.62));
	if (localCoverage <= 0.015) {
		return 1.0;
	}

	vec2 wind = CloudWindDir().xz;
	vec2 q = advected.xz * (0.00016 * FOXY_CLOUD_SHAPE_SCALE) + wind * (time * FOXY_CLOUD_SPEED * 0.0012);
	float broad = ValueNoise(q + vec2(2.7, 5.1));
	float soft = ValueNoise(q * 1.86 + vec2(broad * 0.23, -broad * 0.18));
	float field = broad * 0.56 + soft * 0.24 + localCoverage * 0.34 + coverage * 0.05;
	float threshold = mix(0.74, 0.48, coverage) - localCoverage * 0.08;
	float occlusion = smoothstep(threshold, threshold + 0.22 * FOXY_CLOUD_EDGE_SOFTNESS, field);
	occlusion *= smoothstep(0.035, 0.50, localCoverage);
	occlusion *= mix(0.72, 1.08, FOXY_CLOUD_DENSITY);
	float angleFade = smoothstep(0.006, 0.15, lightAltitude);
	float rainFade = mix(1.0, 0.50, rainStrength);
	return 1.0 - occlusion * FOXY_CLOUD_SHADOW_STRENGTH * 1.35 * angleFade * rainFade;
	#endif
}

float CloudShadowVisibilityReference(
	const in vec3 referenceWorldPos,
	const in vec3 sunDir,
	const in float time,
	const in float rainStrength
) {
	if (FOXY_CLOUDS == 0 || FOXY_CLOUD_SHADOW_STRENGTH <= 0.001 || sunDir.y <= 0.006) {
		return 1.0;
	}

	float cloudPlane = CLOUD_LOW_BOTTOM + CloudPhysicalThickness() * 0.42;
	float t = (cloudPlane - referenceWorldPos.y) / max(sunDir.y, 0.006);
	if (t <= 0.0 || t > CLOUD_TRACE_LIMIT) {
		return 1.0;
	}

	vec3 p = referenceWorldPos + sunDir * t;
	return CloudShadowVisibilityAtPlane(p.xz, sunDir.y, time, rainStrength);
}

float CloudShadowVisibilityCached(
	sampler2D cacheTexture,
	const in vec3 worldPos,
	const in vec3 cameraWorldPos,
	const in vec3 lightDir,
	const in float time,
	const in float rainStrength
) {
	if (FOXY_CLOUDS == 0 || FOXY_CLOUD_SHADOW_STRENGTH <= 0.001 || lightDir.y <= 0.006) {
		return 1.0;
	}
	#if FOXY_CLOUD_BLOCK_SHAPE == 1
	return CloudShadowVisibilityReference(CloudWorldToReference(worldPos), lightDir, time, rainStrength);
	#endif

	vec3 referenceWorldPos = CloudWorldToReference(worldPos);
	float cloudPlane = CLOUD_LOW_BOTTOM + CloudPhysicalThickness() * 0.42;
	float t = (cloudPlane - referenceWorldPos.y) / max(lightDir.y, 0.006);
	if (t <= 0.0 || t > CLOUD_TRACE_LIMIT) {
		return 1.0;
	}

	vec2 planePosition = referenceWorldPos.xz + lightDir.xz * t;
	vec2 cacheUv = (planePosition - CloudShadowCacheCenter(cameraWorldPos, lightDir)) / CLOUD_SHADOW_CACHE_EXTENT + vec2(0.5);
	vec2 halfTexel = 0.5 / CLOUD_SHADOW_CACHE_SIZE;
	bool insideCache = all(greaterThanEqual(cacheUv, halfTexel)) && all(lessThanEqual(cacheUv, vec2(1.0) - halfTexel));
	if (insideCache) {
		return texture2D(cacheTexture, cacheUv).a;
	}
	return CloudShadowVisibilityReference(referenceWorldPos, lightDir, time, rainStrength);
}

#endif
