#ifndef FOXY_WEATHER_GLSL
#define FOXY_WEATHER_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

#if FOXY_FRAME_CELESTIAL_CACHE == 1 && FOXY_FRAME_WEATHER_CACHE == 1 && defined(FOXY_FRAME_WEATHER_READER) && FOXY_WEATHER_ACTIVE == 1 && !defined(COLORWHEEL) && !defined(FOXY_EXTERNAL_PIPELINE_BINDINGS)
#define FOXY_FRAME_WEATHER_ACTIVE 1
#else
#define FOXY_FRAME_WEATHER_ACTIVE 0
#endif

// Only explicitly opted-in stages AFTER prepare may read frame weather.
// Shadow, prepare, external pipelines and Colorwheel retain the original path.
#if FOXY_FRAME_WEATHER_ACTIVE == 1
#include "/lib/contracts/frame_celestial.glsl"
#endif


struct WeatherDay {
	float cloudFactor;
	float cloudOffset;
	float fogDay;
	float fogTwilight;
	float noonDecay;
	float windSpeed;
	float fogSpeed;
	float sunScale;
};

WeatherDay WeatherPresetSettings(const in int preset) {
	WeatherDay day;
	day.windSpeed = 1.0;
	day.fogSpeed = 1.0;
	day.sunScale = 1.0;
	if (preset == 0) {
		day.cloudFactor = 0.00;
		day.fogDay = 0.55;
		day.fogTwilight = 0.60;
		day.noonDecay = 1.0;
	} else if (preset == 1) {
		day.cloudFactor = 0.50;
		day.fogDay = 0.75;
		day.fogTwilight = 0.82;
		day.noonDecay = 1.0;
	} else if (preset == 3) {
		day.cloudFactor = 1.60;
		day.fogDay = 1.35;
		day.fogTwilight = 1.30;
		day.noonDecay = 1.0;
		day.sunScale = 0.20;
	} else if (preset == 4 || preset == 5) {
		day.cloudFactor = 1.375;
		day.fogDay = 2.60;
		day.fogTwilight = 1.90;
		day.noonDecay = 0.0;
		if (preset == 5) {
			day.cloudFactor = 0.50;
			day.windSpeed = 4.0;
			day.fogSpeed = 12.0;
		}
	} else {
		day.cloudFactor = 1.00;
		day.fogDay = 1.00;
		day.fogTwilight = 1.00;
		day.noonDecay = 1.0;
	}
	day.cloudOffset = 0.0;
	return day;
}

int WeatherDayPreset(const in int dayIndex) {
	if (dayIndex == 0) return FOXY_WEATHER_DAY1;
	if (dayIndex == 1) return FOXY_WEATHER_DAY2;
	if (dayIndex == 2) return FOXY_WEATHER_DAY3;
	if (dayIndex == 3) return FOXY_WEATHER_DAY4;
	if (dayIndex == 4) return FOXY_WEATHER_DAY5;
	return FOXY_WEATHER_DAY6;
}

WeatherDay WeatherDaySettings(const in int dayIndex) {
	WeatherDay day = WeatherPresetSettings(WeatherDayPreset(dayIndex));
	if (dayIndex == 0) {
		day.cloudOffset = FOXY_WEATHER_DAY1_CLOUD;
		day.fogDay *= FOXY_WEATHER_DAY1_FOG_DAY;
		day.fogTwilight *= FOXY_WEATHER_DAY1_FOG_TWILIGHT;
	} else if (dayIndex == 1) {
		day.cloudOffset = FOXY_WEATHER_DAY2_CLOUD;
		day.fogDay *= FOXY_WEATHER_DAY2_FOG_DAY;
		day.fogTwilight *= FOXY_WEATHER_DAY2_FOG_TWILIGHT;
	} else if (dayIndex == 2) {
		day.cloudOffset = FOXY_WEATHER_DAY3_CLOUD;
		day.fogDay *= FOXY_WEATHER_DAY3_FOG_DAY;
		day.fogTwilight *= FOXY_WEATHER_DAY3_FOG_TWILIGHT;
	} else if (dayIndex == 3) {
		day.cloudOffset = FOXY_WEATHER_DAY4_CLOUD;
		day.fogDay *= FOXY_WEATHER_DAY4_FOG_DAY;
		day.fogTwilight *= FOXY_WEATHER_DAY4_FOG_TWILIGHT;
	} else if (dayIndex == 4) {
		day.cloudOffset = FOXY_WEATHER_DAY5_CLOUD;
		day.fogDay *= FOXY_WEATHER_DAY5_FOG_DAY;
		day.fogTwilight *= FOXY_WEATHER_DAY5_FOG_TWILIGHT;
	} else {
		day.cloudOffset = FOXY_WEATHER_DAY6_CLOUD;
		day.fogDay *= FOXY_WEATHER_DAY6_FOG_DAY;
		day.fogTwilight *= FOXY_WEATHER_DAY6_FOG_TWILIGHT;
	}
	return day;
}

int WeatherDayIndex(const in float worldDay) {
	return int(mod(floor(worldDay) + float(FOXY_WEATHER_OFFSET), float(FOXY_WEATHER_DAYS)));
}

WeatherDay WeatherCurrent() {
	#if FOXY_FRAME_WEATHER_ACTIVE == 1
		WeatherDay cached;
		cached.cloudFactor = frameWeatherDayA.x;
		cached.cloudOffset = frameWeatherDayA.y;
		cached.fogDay = frameWeatherDayA.z;
		cached.fogTwilight = frameWeatherDayA.w;
		cached.noonDecay = frameWeatherDayB.x;
		cached.windSpeed = frameWeatherDayB.y;
		cached.fogSpeed = frameWeatherDayB.z;
		cached.sunScale = frameWeatherDayB.w;
		return cached;
	#else

	#if FOXY_WEATHER_ACTIVE == 0
		return WeatherPresetSettings(2);
	#else
		float worldDay = float(FOXY_WORLD_DAY);
		WeatherDay from = WeatherDaySettings(WeatherDayIndex(worldDay - 1.0));
		WeatherDay to = WeatherDaySettings(WeatherDayIndex(worldDay));
		float window = max(FOXY_WEATHER_TRANSITION, 0.0) / 24.0;
		float dayPhase = Saturate(float(FOXY_WORLD_TICK) / 24000.0);
		float blend = window <= 0.0001 ? 1.0 : smoothstep(0.0, window, dayPhase);
		WeatherDay day;
		day.cloudFactor = mix(from.cloudFactor, to.cloudFactor, blend);
		day.cloudOffset = mix(from.cloudOffset, to.cloudOffset, blend);
		day.fogDay = mix(from.fogDay, to.fogDay, blend);
		day.fogTwilight = mix(from.fogTwilight, to.fogTwilight, blend);
		day.noonDecay = mix(from.noonDecay, to.noonDecay, blend);
		day.windSpeed = mix(from.windSpeed, to.windSpeed, blend);
		day.fogSpeed = mix(from.fogSpeed, to.fogSpeed, blend);
		day.sunScale = mix(from.sunScale, to.sunScale, blend);
		return day;
	#endif
	#endif
}

float WeatherCoverageCap() {
	return max(max(0.65, FOXY_CLOUD_COVERAGE), FOXY_CLOUD_RAIN_COVERAGE);
}

// Rain blends toward its own coverage target rather than stacking on top of the
// clear value, so a rainy sky thickens only up to FOXY_CLOUD_RAIN_COVERAGE and
// the horizon stays readable.
float WeatherRainCoverageTarget() {
	return FOXY_CLOUD_RAIN_COVERAGE;
}

// The rain strength is passed in rather than read from a uniform: this helper is
// reached from passes that declare it (composite, gbuffers) and from the sky LUT
// bake, which already declares its own.  Declaring another one here collides
// with that pass's declaration, so the caller supplies the value instead.
float WeatherCloudCoverage(const in float rainStrength) {
	#if FOXY_WEATHER_ACTIVE == 0
		float baseCoverage = FOXY_CLOUD_COVERAGE;
	#else
		WeatherDay day = WeatherCurrent();
		float baseCoverage = min(
			max(FOXY_CLOUD_COVERAGE * day.cloudFactor + day.cloudOffset, 0.0),
			WeatherCoverageCap()
		);
	#endif
	return mix(baseCoverage, WeatherRainCoverageTarget(), Saturate(rainStrength) * 0.85);
}

float WeatherCloudCoverageGain(const in float rainStrength) {
	#if FOXY_WEATHER_ACTIVE == 0
		return 1.0;
	#else
		return Saturate(WeatherCloudCoverage(rainStrength) / 0.15);
	#endif
}

float WeatherAerosolDayScale() {
	return WeatherCurrent().fogDay;
}

float WeatherAerosolTwilightScale() {
	return WeatherCurrent().fogTwilight;
}

float WeatherGaleAmount() {
	return Saturate((WeatherCurrent().windSpeed - 1.0) / 3.0);
}

float WeatherSunScale() {
	return WeatherCurrent().sunScale;
}

float WeatherNoonDecayBypass() {
	return 1.0 - Saturate(WeatherCurrent().noonDecay);
}

#define FOXY_WIND_CLOUDS 0
#define FOXY_WIND_FOG 1

float WeatherDayWindSpeed(const in int slot, const in int kind) {
	WeatherDay day = WeatherDaySettings(slot);
	return kind == FOXY_WIND_FOG ? day.fogSpeed : day.windSpeed;
}

float WeatherWindDrift(const in int kind) {
	#if FOXY_FRAME_WEATHER_ACTIVE == 1
		return kind == FOXY_WIND_FOG ? frameWeatherDrift.y : frameWeatherDrift.x;
	#else

	#if FOXY_WEATHER_ACTIVE == 0
		return 0.0;
	#else
		float completedDays = floor(float(FOXY_WORLD_DAY));
		float cycles = floor(completedDays / float(FOXY_WEATHER_DAYS));
		float daysIntoCycle = completedDays - cycles * float(FOXY_WEATHER_DAYS);
		float cycleExtra = 0.0;
		float doneExtra = 0.0;
		for (int slot = 0; slot < FOXY_WEATHER_DAYS; slot++) {
			float extra = WeatherDayWindSpeed(slot, kind) - 1.0;
			cycleExtra += extra;
			if (float(slot) < daysIntoCycle) {
				doneExtra += extra;
			}
		}
		float todayExtra = WeatherDayWindSpeed(WeatherDayIndex(float(FOXY_WORLD_DAY)), kind) - 1.0;
		float dayPhase = Saturate(float(FOXY_WORLD_TICK) / 24000.0);
		float extraDays = cycles * cycleExtra + doneExtra + dayPhase * todayExtra;
		return extraDays * FOXY_SECONDS_PER_GAME_DAY;
	#endif
	#endif
}

#endif
