#ifndef FOXY_END_KEY_LIGHT_GLSL
#define FOXY_END_KEY_LIGHT_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

const float END_KEY_BH_MASS = 0.5;
const float END_KEY_PROFILE_NORM = 0.4879;
const float END_KEY_REF_RIN = 3.0;
const float END_KEY_REF_PROFILE = 1.0 / 12.0;
const float END_KEY_REF_OPACITY = 0.9;
const float END_KEY_REF_EMIT = 0.5;
const float END_KEY_REF_DIST = 5.62;
const float END_KEY_REF_COS_EXTENT = 0.0;
const float END_KEY_ARC_SCALE = 0.70;
const float END_KEY_EDGE_FACTOR = 1.5;
const float END_KEY_BLUE_SHIFT_CLAMP = 4.0;
const float END_KEY_FLUX_RESPONSE = 0.0;

float EndKeyFluxProfile(const in float u) {
	float u2 = u * u;
	return 1.0 / 6.0 - 0.5 * u2 + u2 * u * (1.0 / 3.0);
}

float EndKeyRadiusProfile(const in float u) {
	return u - 1.0 - log(max(u, 1.0e-6));
}

float EndKeyIscoRadius(const in float a) {
	if (a * a < 1.0e-12) return 6.0 * END_KEY_BH_MASS;
	float ap = clamp(a / END_KEY_BH_MASS, 0.0, 0.999999);
	float c = pow(1.0 - ap * ap, 1.0 / 3.0);
	float z1 = 1.0 + c * (pow(1.0 + ap, 1.0 / 3.0) + pow(1.0 - ap, 1.0 / 3.0));
	float z2 = sqrt(3.0 * ap * ap + z1 * z1);
	return END_KEY_BH_MASS * (
		3.0 + z2 - sqrt(max((3.0 - z1) * (3.0 + z1 + 2.0 * z2), 0.0))
	);
}

float EndKeyDiskTemperature(const in float r, const in float rin) {
	float x = rin / max(r, 1.0e-4);
	if (x >= 1.0) return 0.0;
	float sx = sqrt(x);
	float x75 = sx * sqrt(sx);
	float q = max(1.0 - sx, 0.0);
	return x75 * sqrt(sqrt(q)) / END_KEY_PROFILE_NORM;
}

vec3 EndKeyObserverPosition(const in float bhTime) {
	float pitch = FOXY_BLACKHOLE_CAM_PITCH * PI / 180.0;
	float cp = cos(pitch);
	float sp = sin(pitch);
	float yaw = FOXY_BLACKHOLE_CAM_YAW;
	float distance = FOXY_BLACKHOLE_CAM_DIST;
	#if FOXY_BLACKHOLE_ORBIT == 1
		float nu = bhTime * FOXY_BLACKHOLE_ORBIT_SPEED;
		float rMax = FOXY_BLACKHOLE_ORBIT_FAR;
		float rMin = clamp(FOXY_BLACKHOLE_ORBIT_NEAR, rMax * 1.0e-3, rMax * 0.999);
		float ecc = min((rMax - rMin) / max(rMax + rMin, 1.0e-4), 0.999);
		float semiLatus = rMax * (1.0 - ecc);
		yaw += nu;
		distance = semiLatus / max(1.0 - ecc * cos(nu), 1.0e-4);
	#endif
	return vec3(
		distance * cp * sin(yaw),
		-distance * cp * cos(yaw),
		distance * sp
	);
}

float EndKeyBlueShift(const in float distance) {
	return clamp(
		1.0 / sqrt(max(1.0 - 1.0 / max(distance, 1.0e-3), 1.0e-4)),
		0.0,
		END_KEY_BLUE_SHIFT_CLAMP
	);
}

struct EndKeyLight {
	vec3 dirWorld;
	float flux;
	float temperature;
};

EndKeyLight EndKeyLightSample(const in float bhTime) {
	EndKeyLight key;
	float a = FOXY_BLACKHOLE_SPIN * END_KEY_BH_MASS;
	float rin = EndKeyIscoRadius(a);
	float rout = max(FOXY_BLACKHOLE_DISK_OUTER, rin);

	float uOut = sqrt(clamp(rin / rout, 0.0, 1.0));
	float profile = EndKeyFluxProfile(uOut);
	float radiusProfile = max(EndKeyRadiusProfile(uOut), 0.0);
	float meanRadius = max(
		rin * 1.25,
		rin * radiusProfile / max(profile, 1.0e-6)
	);

	float effectiveProfile = EndKeyDiskTemperature(meanRadius, rin);
	key.temperature = FOXY_BLACKHOLE_DISK_TEMP * mix(
		1.0,
		effectiveProfile,
		Saturate(FOXY_BLACKHOLE_TEMP_CONTRAST)
	);

	float opacity = FOXY_BLACKHOLE_DISK_OPACITY * FOXY_BLACKHOLE_DISK_ABSORB;
	float opacityGain = (1.0 - exp(-opacity)) /
		max(1.0 - exp(-END_KEY_REF_OPACITY), 1.0e-4);
	float physicalFlux = (rin * rin * profile) /
		(END_KEY_REF_RIN * END_KEY_REF_RIN * END_KEY_REF_PROFILE) *
		opacityGain *
		(FOXY_BLACKHOLE_DISK_EMIT / END_KEY_REF_EMIT);

	vec3 observer = EndKeyObserverPosition(bhTime);
	float distance = max(length(observer), 1.0e-4);

	float horizonRadius = 2.0 * END_KEY_BH_MASS;
	float photonSphere = 3.0 * END_KEY_BH_MASS;
	float criticalImpact = 3.0 * sqrt(3.0) * END_KEY_BH_MASS;

	float edgeSin = clamp(
		criticalImpact / distance *
			sqrt(max(1.0 - horizonRadius / distance, 0.0)),
		0.0,
		1.0
	);
	float edgeAngle = asin(edgeSin);

	float edgeOffset = (END_KEY_EDGE_FACTOR - 1.0) * edgeAngle;
	float anchorAzimuth = distance > photonSphere
		? edgeAngle + edgeOffset
		: PI - edgeAngle + edgeOffset;
	vec2 anchorDirection = vec2(cos(anchorAzimuth), sin(anchorAzimuth));

	float elevation = edgeAngle * END_KEY_ARC_SCALE *
		max(cos(FOXY_BLACKHOLE_CAM_PITCH * PI / 180.0), 0.0);
	key.dirWorld = normalize(vec3(
		anchorDirection.x * cos(elevation),
		sin(elevation),
		anchorDirection.y * cos(elevation)
	));

	float tiltAngle = radians(FOXY_BLACKHOLE_TILT);
	float tiltCos = cos(tiltAngle);
	float tiltSin = sin(tiltAngle);
	vec3 tiltAxis = vec3(1.0, 0.0, 0.0);
	vec3 tiltDir = key.dirWorld;
	key.dirWorld = normalize(
		tiltDir * tiltCos + cross(tiltAxis, tiltDir) * tiltSin
		+ tiltAxis * (dot(tiltAxis, tiltDir) * (1.0 - tiltCos)));

	float shiftRatio = EndKeyBlueShift(distance) /
		max(EndKeyBlueShift(END_KEY_REF_DIST), 1.0e-4);
	physicalFlux *= shiftRatio * shiftRatio * shiftRatio;

	key.flux = mix(1.0, physicalFlux, END_KEY_FLUX_RESPONSE);

	#if FOXY_BLACKHOLE_SKY == 0
		key.dirWorld = normalize(FOXY_END_LIGHT_DIR);
		key.flux = 1.0;
		key.temperature = FOXY_BLACKHOLE_DISK_TEMP;
	#endif
	return key;
}

vec3 EndKeyLightDirection(const in float bhTime) {
	return EndKeyLightSample(bhTime).dirWorld;
}

float EndKeyLightFlux(const in float bhTime) {
	return EndKeyLightSample(bhTime).flux;
}

float EndKeyLightTemperature(const in float bhTime) {
	return EndKeyLightSample(bhTime).temperature;
}

float EndKeySkyCoverage(const in float bhTime) {
	float a = FOXY_BLACKHOLE_SPIN * END_KEY_BH_MASS;
	float rin = EndKeyIscoRadius(a);
	float rout = max(FOXY_BLACKHOLE_DISK_OUTER, rin);
	float distance = max(length(EndKeyObserverPosition(bhTime)), 1.0e-4);
	float ratio = clamp(rout / distance, 0.0, 1.0);
	float cosExtent = sqrt(max(1.0 - ratio * ratio, 0.0));
	#if FOXY_BLACKHOLE_SKY == 0
		return 1.0;
	#endif
	float coverage = (1.0 - cosExtent) / max(1.0 - END_KEY_REF_COS_EXTENT, 1.0e-4);
	return mix(1.0, coverage, END_KEY_FLUX_RESPONSE);
}

#endif
