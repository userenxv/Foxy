#ifndef FOXY_SEASONS_GLSL
#define FOXY_SEASONS_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"


vec3 SeasonRgbToHsv(const in vec3 color) {
	float maxChannel = max(max(color.r, color.g), color.b);
	float minChannel = min(min(color.r, color.g), color.b);
	float delta = maxChannel - minChannel;
	float hue = 0.0;
	if (delta > 1.0e-6) {
		if (maxChannel == color.r) {
			hue = (color.g - color.b) / delta;
			hue = hue < 0.0 ? hue + 6.0 : hue;
		} else if (maxChannel == color.g) {
			hue = (color.b - color.r) / delta + 2.0;
		} else {
			hue = (color.r - color.g) / delta + 4.0;
		}
		hue /= 6.0;
	}
	float saturation = maxChannel > 1.0e-6 ? delta / maxChannel : 0.0;
	return vec3(hue, saturation, maxChannel);
}

vec3 SeasonHsvToRgb(const in vec3 hsv) {
	float h = fract(hsv.x) * 6.0;
	float sector = floor(h);
	float f = h - sector;
	float p = hsv.z * (1.0 - hsv.y);
	float q = hsv.z * (1.0 - hsv.y * f);
	float t = hsv.z * (1.0 - hsv.y * (1.0 - f));
	if (sector < 1.0) return vec3(hsv.z, t, p);
	if (sector < 2.0) return vec3(q, hsv.z, p);
	if (sector < 3.0) return vec3(p, hsv.z, t);
	if (sector < 4.0) return vec3(p, q, hsv.z);
	if (sector < 5.0) return vec3(t, p, hsv.z);
	return vec3(hsv.z, p, q);
}

void SeasonPhase(out int season, out int next, out float blend) {
	#if FOXY_SEASON_ACTIVE == 0
		season = 0;
		next = 1;
		blend = 0.0;
	#else
		float seasonLength = float(max(FOXY_SEASON_DAYS, 1));
		float phase = mod(float(FOXY_WORLD_DAY), seasonLength * 4.0) / seasonLength;
		season = int(floor(phase));
		next = int(mod(float(season) + 1.0, 4.0));
		float window = min(float(max(FOXY_SEASON_TRANSITION, 0)) / seasonLength, 1.0);
		float within = fract(phase);
		blend = window <= 0.0001 ? 0.0 : smoothstep(1.0 - window, 1.0, within);
	#endif
}

float SeasonStrength() {
	#if FOXY_SEASON_ACTIVE == 0
		return 0.0;
	#else
		return max(FOXY_SEASON_STRENGTH, 0.0);
	#endif
}

struct SeasonLook {
	float hueTarget;
	float hueBlend;
	float saturation;
	float value;
	float snowBlend;
};

SeasonLook SeasonLookForSeason(const in int season) {
	SeasonLook look;
	look.snowBlend = 0.0;
	if (season == 2) {
		look.hueTarget = FOXY_SEASON_AUTUMN_HUE;
		look.hueBlend = 1.0;
		look.saturation = FOXY_SEASON_AUTUMN_SATURATION;
		look.value = FOXY_SEASON_AUTUMN_BRIGHTNESS;
	} else if (season == 3) {
		look.hueTarget = 0.30;
		look.hueBlend = 0.0;
		look.saturation = 1.0;
		look.value = 1.0;
		look.snowBlend = FOXY_SEASON_WINTER_WHITENESS;
	} else {
		look.hueTarget = 0.30;
		look.hueBlend = 0.0;
		look.saturation = 1.0;
		look.value = 1.0;
	}
	return look;
}

SeasonLook SeasonCurrentLook() {
	int season;
	int next;
	float blend;
	SeasonPhase(season, next, blend);
	SeasonLook from = SeasonLookForSeason(season);
	SeasonLook to = SeasonLookForSeason(next);
	float strength = SeasonStrength();
	SeasonLook look;
	look.hueTarget = mix(from.hueTarget, to.hueTarget, blend);
	look.hueBlend = mix(from.hueBlend, to.hueBlend, blend) * strength;
	look.saturation = mix(1.0, mix(from.saturation, to.saturation, blend), strength);
	look.value = mix(1.0, mix(from.value, to.value, blend), strength);
	look.snowBlend = mix(from.snowBlend, to.snowBlend, blend) * strength;
	return look;
}

float SeasonSunIlluminance() {
	int season;
	int next;
	float blend;
	SeasonPhase(season, next, blend);
	float summer = FOXY_SEASON_SUN_ILLUMINANCE_SUMMER;
	float winter = FOXY_SEASON_SUN_ILLUMINANCE_WINTER;
	float from = 1.0;
	float to = 1.0;
	if (season == 1) {
		from = summer;
	} else if (season == 3) {
		from = winter;
	}
	if (next == 1) {
		to = summer;
	} else if (next == 3) {
		to = winter;
	}
	return mix(1.0, mix(from, to, blend), SeasonStrength());
}

float SeasonGreenishMask(const in vec3 color) {
	// Already-tinted colour (Distant Horizons terrain has no separate tint to
	// divide out): only a clearly red-dominant pixel is not vegetation.
	return 1.0 - smoothstep(1.04, 1.10, color.r / max(color.g, 1.0e-4));
}

float SeasonTextureGreenishMask(const in vec3 color, const in vec3 biomeTint) {
	// Grass, leaf and plant textures are greyscale and the biome tint carries the
	// colour, so the tint has to be divided back out first. A neutral result is
	// vegetation; a brown (red-dominant) one is dirt, i.e. a grass block's side
	// or bottom, which must keep its own colour. The tint is folded into the one
	// division instead of dividing the colour by it first.
	float redDominance = (color.r * max(biomeTint.g, 1.0e-4)) /
		max(color.g * max(biomeTint.r, 1.0e-4), 1.0e-8);
	return 1.0 - smoothstep(1.02, 1.14, redDominance);
}

float SeasonVegetationMask(
	const in float materialId,
	const in vec3 biomeTint,
	const in vec3 color
) {
	float leaves = abs(materialId - 10100.0) < 0.5 ? 1.0 : 0.0;
	float plants = (materialId > 10100.5 && materialId < 10103.5) ? 1.0 : 0.0;
	// 10131 grass block, 10132 vine
	float grass = (materialId > 10130.5 && materialId < 10132.5) ? 1.0 : 0.0;
	float biomeTinted = 1.0 - step(0.995, min(min(biomeTint.r, biomeTint.g), biomeTint.b));
	float greenish = SeasonTextureGreenishMask(color, biomeTint);
	return greenish * biomeTinted * max(max(leaves, plants), grass);
}

vec3 SeasonApplyLook(const in vec3 color, const in SeasonLook look) {
	vec3 hsv = SeasonRgbToHsv(color);
	hsv.x = mix(hsv.x, look.hueTarget, Saturate(look.hueBlend));
	hsv.y = Saturate(hsv.y * look.saturation);
	hsv.z = Saturate(hsv.z * look.value);
	vec3 result = SeasonHsvToRgb(hsv);
	float snowAmount = Saturate(look.snowBlend);
	if (snowAmount > 0.001) {
		float luma = dot(result, vec3(0.2126, 0.7152, 0.0722));
		float snowLevel = mix(
			1.0,
			Saturate(luma * 2.0),
			Saturate(FOXY_SEASON_WINTER_DETAIL)
		);
		vec3 snow = vec3(
			FOXY_SEASON_WINTER_R,
			FOXY_SEASON_WINTER_G,
			FOXY_SEASON_WINTER_B
		) * snowLevel;
		result = mix(result, snow, snowAmount);
	}
	return result;
}

bool SeasonLookIsIdentity(const in SeasonLook look) {
	return look.hueBlend + abs(look.saturation - 1.0) + abs(look.value - 1.0) +
		Saturate(look.snowBlend) <= 0.0005;
}

vec3 SeasonApplyFoliageTint(
	const in vec3 color,
	const in float materialId,
	const in vec3 biomeTint
) {
	float mask = SeasonVegetationMask(materialId, biomeTint, color);
	if (mask <= 0.001) {
		return color;
	}
	SeasonLook look = SeasonCurrentLook();
	if (SeasonLookIsIdentity(look)) {
		return color;
	}
	return mix(color, SeasonApplyLook(color, look), Saturate(mask));
}

vec3 SeasonApplyBiomeTint(const in vec3 color, const in vec3 biomeTint) {
	float mask = SeasonGreenishMask(color);
	if (mask <= 0.001) {
		return color;
	}
	SeasonLook look = SeasonCurrentLook();
	if (SeasonLookIsIdentity(look)) {
		return color;
	}
	return mix(color, SeasonApplyLook(color, look), mask);
}

#endif
