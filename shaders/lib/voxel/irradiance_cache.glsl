#ifndef FOXY_IRRADIANCE_CACHE_GLSL
#define FOXY_IRRADIANCE_CACHE_GLSL

#include "/lib/settings.glsl"

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1

#include "/lib/voxel/voxel_grid.glsl"
#include "/lib/voxel/voxel_shape.glsl"

// Fixed 128^3 world-aligned cache with six RGB ambient-cube lobes per probe.
const int FOXY_IRC_SIZE = 128;
const uint FOXY_IRC_COUNT = 2097152u;
const uint FOXY_IRC_WORDS_PER_PROBE = 20u;
const float FOXY_IRC_MAX_RADIANCE = 64.0;
const ivec3 FOXY_IRC_GRID_OFFSET = ivec3(
	(VOXEL_GRID_SIZE - FOXY_IRC_SIZE) / 2
);

layout(std430, binding = 1) coherent buffer IrradianceCacheA {
	uint irradianceCacheA[];
};
layout(std430, binding = 2) coherent buffer IrradianceCacheB {
	uint irradianceCacheB[];
};

struct IrcEntry {
	vec3 radiance;
	vec3 directionMoment;
	float sampleCount;
	float skyLuminance;
	vec3 positiveVisibilityMean;
	vec3 positiveVisibilitySecond;
	vec3 negativeVisibilityMean;
	vec3 negativeVisibilitySecond;
	vec3 positiveIrradianceX;
	vec3 positiveIrradianceY;
	vec3 positiveIrradianceZ;
	vec3 negativeIrradianceX;
	vec3 negativeIrradianceY;
	vec3 negativeIrradianceZ;
	vec3 positiveDirectIrradianceX;
	vec3 positiveDirectIrradianceY;
	vec3 positiveDirectIrradianceZ;
	vec3 negativeDirectIrradianceX;
	vec3 negativeDirectIrradianceY;
	vec3 negativeDirectIrradianceZ;
};

uint IrcIndex(const in ivec3 cell) {
	ivec3 localCell = cell - FOXY_IRC_GRID_OFFSET;
	return uint(localCell.x + FOXY_IRC_SIZE *
		(localCell.y + FOXY_IRC_SIZE * localCell.z));
}

bool IrcInside(const in ivec3 cell) {
	ivec3 localCell = cell - FOXY_IRC_GRID_OFFSET;
	return all(greaterThanEqual(localCell, ivec3(0))) &&
		all(lessThan(localCell, ivec3(FOXY_IRC_SIZE)));
}

uint IrcFrameTag(const in int frameIndex) {
	return uint(max(frameIndex, 0)) + 1u;
}

vec3 IrcProbePosition(const in ivec3 cell) {
	const ivec3 offsets[6] = ivec3[6](
		ivec3(-1, 0, 0), ivec3(1, 0, 0),
		ivec3(0, -1, 0), ivec3(0, 1, 0),
		ivec3(0, 0, -1), ivec3(0, 0, 1)
	);
	vec3 surfaceGradient = vec3(0.0);
	for (int index = 0; index < 6; ++index) {
		ivec3 neighbor = cell + offsets[index];
		if (!VoxelGridInside(neighbor)) continue;
		uint payload = VoxelGridLoadUnchecked(neighbor);
		if (!VoxelGridTopologyOccupied(payload)) continue;
		surfaceGradient += vec3(offsets[index]);
	}
	float gradientLength = length(surfaceGradient);
	vec3 relocation = gradientLength > 1.0e-5
		? surfaceGradient * (0.42 / gradientLength)
		: vec3(0.0);
	return vec3(cell) + vec3(0.5) + relocation;
}

ivec3 IrcCurrentWorldBase(const in vec3 currentCameraPosition) {
	return ivec3(floor(currentCameraPosition)) - ivec3(FOXY_IRC_SIZE / 2);
}

ivec3 IrcPreviousWorldBase(const in vec3 oldCameraPosition) {
	return ivec3(floor(oldCameraPosition)) - ivec3(FOXY_IRC_SIZE / 2);
}

IrcEntry IrcEmptyEntry() {
	return IrcEntry(
		vec3(0.0), vec3(0.0), 0.0, 0.0,
		vec3(0.0), vec3(0.0), vec3(0.0), vec3(0.0),
		vec3(0.0), vec3(0.0), vec3(0.0),
		vec3(0.0), vec3(0.0), vec3(0.0),
		vec3(0.0), vec3(0.0), vec3(0.0),
		vec3(0.0), vec3(0.0), vec3(0.0)
	);
}

IrcEntry IrcDecodeWords(
	const in uvec4 baseWords,
	const in uvec3 positiveWords,
	const in uvec3 negativeWords,
	const in uvec4 lobeWordsA,
	const in uvec4 lobeWordsB,
	const in uint lobeWordC,
	const in uvec4 directLobeWordsA,
	const in uvec4 directLobeWordsB,
	const in uint directLobeWordC
) {
	vec2 dataX = unpackHalf2x16(baseWords.x);
	vec2 dataY = unpackHalf2x16(baseWords.y);
	vec2 dataZ = unpackHalf2x16(baseWords.z);
	vec2 dataW = unpackHalf2x16(baseWords.w);
	IrcEntry entry;
	entry.radiance = max(vec3(dataX.x, dataY.x, dataZ.x), vec3(0.0));
	entry.directionMoment = vec3(dataX.y, dataY.y, dataZ.y);
	entry.sampleCount = max(dataW.x, 0.0);
	entry.skyLuminance = max(dataW.y, 0.0);
	vec2 positiveX = unpackHalf2x16(positiveWords.x);
	vec2 positiveY = unpackHalf2x16(positiveWords.y);
	vec2 positiveZ = unpackHalf2x16(positiveWords.z);
	vec2 negativeX = unpackHalf2x16(negativeWords.x);
	vec2 negativeY = unpackHalf2x16(negativeWords.y);
	vec2 negativeZ = unpackHalf2x16(negativeWords.z);
	entry.positiveVisibilityMean = vec3(positiveX.x, positiveY.x, positiveZ.x);
	entry.positiveVisibilitySecond = vec3(positiveX.y, positiveY.y, positiveZ.y);
	entry.negativeVisibilityMean = vec3(negativeX.x, negativeY.x, negativeZ.x);
	entry.negativeVisibilitySecond = vec3(negativeX.y, negativeY.y, negativeZ.y);
	vec2 lobe0 = unpackHalf2x16(lobeWordsA.x);
	vec2 lobe1 = unpackHalf2x16(lobeWordsA.y);
	vec2 lobe2 = unpackHalf2x16(lobeWordsA.z);
	vec2 lobe3 = unpackHalf2x16(lobeWordsA.w);
	vec2 lobe4 = unpackHalf2x16(lobeWordsB.x);
	vec2 lobe5 = unpackHalf2x16(lobeWordsB.y);
	vec2 lobe6 = unpackHalf2x16(lobeWordsB.z);
	vec2 lobe7 = unpackHalf2x16(lobeWordsB.w);
	vec2 lobe8 = unpackHalf2x16(lobeWordC);
	entry.positiveIrradianceX = max(vec3(lobe0, lobe1.x), vec3(0.0));
	entry.positiveIrradianceY = max(vec3(lobe1.y, lobe2), vec3(0.0));
	entry.positiveIrradianceZ = max(vec3(lobe3, lobe4.x), vec3(0.0));
	entry.negativeIrradianceX = max(vec3(lobe4.y, lobe5), vec3(0.0));
	entry.negativeIrradianceY = max(vec3(lobe6, lobe7.x), vec3(0.0));
	entry.negativeIrradianceZ = max(vec3(lobe7.y, lobe8), vec3(0.0));
	vec2 directLobe0 = unpackHalf2x16(directLobeWordsA.x);
	vec2 directLobe1 = unpackHalf2x16(directLobeWordsA.y);
	vec2 directLobe2 = unpackHalf2x16(directLobeWordsA.z);
	vec2 directLobe3 = unpackHalf2x16(directLobeWordsA.w);
	vec2 directLobe4 = unpackHalf2x16(directLobeWordsB.x);
	vec2 directLobe5 = unpackHalf2x16(directLobeWordsB.y);
	vec2 directLobe6 = unpackHalf2x16(directLobeWordsB.z);
	vec2 directLobe7 = unpackHalf2x16(directLobeWordsB.w);
	vec2 directLobe8 = unpackHalf2x16(directLobeWordC);
	entry.positiveDirectIrradianceX = max(vec3(directLobe0, directLobe1.x), vec3(0.0));
	entry.positiveDirectIrradianceY = max(vec3(directLobe1.y, directLobe2), vec3(0.0));
	entry.positiveDirectIrradianceZ = max(vec3(directLobe3, directLobe4.x), vec3(0.0));
	entry.negativeDirectIrradianceX = max(vec3(directLobe4.y, directLobe5), vec3(0.0));
	entry.negativeDirectIrradianceY = max(vec3(directLobe6, directLobe7.x), vec3(0.0));
	entry.negativeDirectIrradianceZ = max(vec3(directLobe7.y, directLobe8), vec3(0.0));
	return entry;
}

void IrcEncodeWords(
	const in IrcEntry inputEntry,
	out uvec4 baseWords,
	out uvec3 positiveWords,
	out uvec3 negativeWords,
	out uvec4 lobeWordsA,
	out uvec4 lobeWordsB,
	out uint lobeWordC,
	out uvec4 directLobeWordsA,
	out uvec4 directLobeWordsB,
	out uint directLobeWordC
) {
	IrcEntry entry = inputEntry;
	entry.radiance = clamp(entry.radiance, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	float meanLuminance = dot(entry.radiance, vec3(0.2126, 0.7152, 0.0722));
	float momentLength = length(entry.directionMoment);
	if (momentLength > meanLuminance && momentLength > 1.0e-7) {
		entry.directionMoment *= meanLuminance / momentLength;
	}
	entry.directionMoment = clamp(
		entry.directionMoment,
		vec3(-FOXY_IRC_MAX_RADIANCE),
		vec3(FOXY_IRC_MAX_RADIANCE)
	);
	baseWords = uvec4(
		packHalf2x16(vec2(entry.radiance.x, entry.directionMoment.x)),
		packHalf2x16(vec2(entry.radiance.y, entry.directionMoment.y)),
		packHalf2x16(vec2(entry.radiance.z, entry.directionMoment.z)),
		packHalf2x16(vec2(clamp(entry.sampleCount, 0.0, 32768.0), entry.skyLuminance))
	);
	positiveWords = uvec3(
		packHalf2x16(vec2(entry.positiveVisibilityMean.x, entry.positiveVisibilitySecond.x)),
		packHalf2x16(vec2(entry.positiveVisibilityMean.y, entry.positiveVisibilitySecond.y)),
		packHalf2x16(vec2(entry.positiveVisibilityMean.z, entry.positiveVisibilitySecond.z))
	);
	negativeWords = uvec3(
		packHalf2x16(vec2(entry.negativeVisibilityMean.x, entry.negativeVisibilitySecond.x)),
		packHalf2x16(vec2(entry.negativeVisibilityMean.y, entry.negativeVisibilitySecond.y)),
		packHalf2x16(vec2(entry.negativeVisibilityMean.z, entry.negativeVisibilitySecond.z))
	);
	entry.positiveIrradianceX = clamp(entry.positiveIrradianceX, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.positiveIrradianceY = clamp(entry.positiveIrradianceY, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.positiveIrradianceZ = clamp(entry.positiveIrradianceZ, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.negativeIrradianceX = clamp(entry.negativeIrradianceX, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.negativeIrradianceY = clamp(entry.negativeIrradianceY, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.negativeIrradianceZ = clamp(entry.negativeIrradianceZ, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	lobeWordsA = uvec4(
		packHalf2x16(entry.positiveIrradianceX.rg),
		packHalf2x16(vec2(entry.positiveIrradianceX.b, entry.positiveIrradianceY.r)),
		packHalf2x16(entry.positiveIrradianceY.gb),
		packHalf2x16(entry.positiveIrradianceZ.rg)
	);
	lobeWordsB = uvec4(
		packHalf2x16(vec2(entry.positiveIrradianceZ.b, entry.negativeIrradianceX.r)),
		packHalf2x16(entry.negativeIrradianceX.gb),
		packHalf2x16(entry.negativeIrradianceY.rg),
		packHalf2x16(vec2(entry.negativeIrradianceY.b, entry.negativeIrradianceZ.r))
	);
	lobeWordC = packHalf2x16(entry.negativeIrradianceZ.gb);
	entry.positiveDirectIrradianceX = clamp(entry.positiveDirectIrradianceX, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.positiveDirectIrradianceY = clamp(entry.positiveDirectIrradianceY, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.positiveDirectIrradianceZ = clamp(entry.positiveDirectIrradianceZ, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.negativeDirectIrradianceX = clamp(entry.negativeDirectIrradianceX, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.negativeDirectIrradianceY = clamp(entry.negativeDirectIrradianceY, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	entry.negativeDirectIrradianceZ = clamp(entry.negativeDirectIrradianceZ, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE));
	directLobeWordsA = uvec4(
		packHalf2x16(entry.positiveDirectIrradianceX.rg),
		packHalf2x16(vec2(entry.positiveDirectIrradianceX.b, entry.positiveDirectIrradianceY.r)),
		packHalf2x16(entry.positiveDirectIrradianceY.gb),
		packHalf2x16(entry.positiveDirectIrradianceZ.rg)
	);
	directLobeWordsB = uvec4(
		packHalf2x16(vec2(entry.positiveDirectIrradianceZ.b, entry.negativeDirectIrradianceX.r)),
		packHalf2x16(entry.negativeDirectIrradianceX.gb),
		packHalf2x16(entry.negativeDirectIrradianceY.rg),
		packHalf2x16(vec2(entry.negativeDirectIrradianceY.b, entry.negativeDirectIrradianceZ.r))
	);
	directLobeWordC = packHalf2x16(entry.negativeDirectIrradianceZ.gb);
}

uint IrcPackRgb9e5(
	const in vec3 value,
	const in uint roundingSeed
) {
	vec3 color = clamp(value, vec3(0.0), vec3(65408.0));
	float maximum = max(color.x, max(color.y, color.z));
	if (maximum <= 1.0e-20) return 0u;
	int sharedExponent = clamp(int(floor(log2(maximum))) + 16, 0, 31);
	float scale = exp2(float(sharedExponent - 24));
	vec3 rounding = vec3(
		float(roundingSeed & 1023u),
		float((roundingSeed >> 10u) & 1023u),
		float((roundingSeed >> 20u) & 1023u)
	) * (1.0 / 1024.0);
	uvec3 mantissa = uvec3(floor(color / scale + rounding));
	if (max(mantissa.x, max(mantissa.y, mantissa.z)) > 511u && sharedExponent < 31) {
		sharedExponent += 1;
		scale *= 2.0;
		mantissa = uvec3(floor(color / scale + rounding));
	}
	mantissa = min(mantissa, uvec3(511u));
	return mantissa.x | (mantissa.y << 9u) | (mantissa.z << 18u) |
		(uint(sharedExponent) << 27u);
}

vec3 IrcUnpackRgb9e5(const in uint packedValue) {
	float scale = exp2(float(int(packedValue >> 27u) - 24));
	return vec3(
		float(packedValue & 511u),
		float((packedValue >> 9u) & 511u),
		float((packedValue >> 18u) & 511u)
	) * scale;
}

IrcEntry IrcDecodeCompact(
	const in uint baseWord,
	const in uvec3 positiveWords,
	const in uvec3 negativeWords,
	const in uvec3 positiveLobes,
	const in uvec3 negativeLobes,
	const in uvec3 positiveDirectLobes,
	const in uvec3 negativeDirectLobes
) {
	IrcEntry entry = IrcEmptyEntry();
	vec2 base = unpackHalf2x16(baseWord);
	entry.sampleCount = max(base.x, 0.0);
	entry.skyLuminance = max(base.y, 0.0);
	vec2 positiveX = unpackHalf2x16(positiveWords.x);
	vec2 positiveY = unpackHalf2x16(positiveWords.y);
	vec2 positiveZ = unpackHalf2x16(positiveWords.z);
	vec2 negativeX = unpackHalf2x16(negativeWords.x);
	vec2 negativeY = unpackHalf2x16(negativeWords.y);
	vec2 negativeZ = unpackHalf2x16(negativeWords.z);
	entry.positiveVisibilityMean = vec3(positiveX.x, positiveY.x, positiveZ.x);
	entry.positiveVisibilitySecond = vec3(positiveX.y, positiveY.y, positiveZ.y);
	entry.negativeVisibilityMean = vec3(negativeX.x, negativeY.x, negativeZ.x);
	entry.negativeVisibilitySecond = vec3(negativeX.y, negativeY.y, negativeZ.y);
	entry.positiveIrradianceX = IrcUnpackRgb9e5(positiveLobes.x);
	entry.positiveIrradianceY = IrcUnpackRgb9e5(positiveLobes.y);
	entry.positiveIrradianceZ = IrcUnpackRgb9e5(positiveLobes.z);
	entry.negativeIrradianceX = IrcUnpackRgb9e5(negativeLobes.x);
	entry.negativeIrradianceY = IrcUnpackRgb9e5(negativeLobes.y);
	entry.negativeIrradianceZ = IrcUnpackRgb9e5(negativeLobes.z);
	entry.positiveDirectIrradianceX = IrcUnpackRgb9e5(positiveDirectLobes.x);
	entry.positiveDirectIrradianceY = IrcUnpackRgb9e5(positiveDirectLobes.y);
	entry.positiveDirectIrradianceZ = IrcUnpackRgb9e5(positiveDirectLobes.z);
	entry.negativeDirectIrradianceX = IrcUnpackRgb9e5(negativeDirectLobes.x);
	entry.negativeDirectIrradianceY = IrcUnpackRgb9e5(negativeDirectLobes.y);
	entry.negativeDirectIrradianceZ = IrcUnpackRgb9e5(negativeDirectLobes.z);
	entry.radiance = (
		entry.positiveIrradianceX + entry.positiveIrradianceY +
		entry.positiveIrradianceZ + entry.negativeIrradianceX +
		entry.negativeIrradianceY + entry.negativeIrradianceZ
	) * (1.0 / 6.0);
	entry.directionMoment = vec3(
		dot(entry.positiveIrradianceX - entry.negativeIrradianceX, vec3(0.2126, 0.7152, 0.0722)),
		dot(entry.positiveIrradianceY - entry.negativeIrradianceY, vec3(0.2126, 0.7152, 0.0722)),
		dot(entry.positiveIrradianceZ - entry.negativeIrradianceZ, vec3(0.2126, 0.7152, 0.0722))
	) * 0.25;
	return entry;
}

void IrcEncodeCompact(
	const in IrcEntry entry,
	const in uint roundingSeed,
	out uint baseWord,
	out uvec3 positiveWords,
	out uvec3 negativeWords,
	out uvec3 positiveLobes,
	out uvec3 negativeLobes,
	out uvec3 positiveDirectLobes,
	out uvec3 negativeDirectLobes
) {
	baseWord = packHalf2x16(vec2(
		clamp(entry.sampleCount, 0.0, 32768.0),
		max(entry.skyLuminance, 0.0)
	));
	positiveWords = uvec3(
		packHalf2x16(vec2(entry.positiveVisibilityMean.x, entry.positiveVisibilitySecond.x)),
		packHalf2x16(vec2(entry.positiveVisibilityMean.y, entry.positiveVisibilitySecond.y)),
		packHalf2x16(vec2(entry.positiveVisibilityMean.z, entry.positiveVisibilitySecond.z))
	);
	negativeWords = uvec3(
		packHalf2x16(vec2(entry.negativeVisibilityMean.x, entry.negativeVisibilitySecond.x)),
		packHalf2x16(vec2(entry.negativeVisibilityMean.y, entry.negativeVisibilitySecond.y)),
		packHalf2x16(vec2(entry.negativeVisibilityMean.z, entry.negativeVisibilitySecond.z))
	);
	positiveLobes = uvec3(
		IrcPackRgb9e5(clamp(entry.positiveIrradianceX, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed),
		IrcPackRgb9e5(clamp(entry.positiveIrradianceY, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0x9e3779b9u),
		IrcPackRgb9e5(clamp(entry.positiveIrradianceZ, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0x3c6ef372u)
	);
	negativeLobes = uvec3(
		IrcPackRgb9e5(clamp(entry.negativeIrradianceX, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0xdaa66d2bu),
		IrcPackRgb9e5(clamp(entry.negativeIrradianceY, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0x78dde6e4u),
		IrcPackRgb9e5(clamp(entry.negativeIrradianceZ, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0x1715609du)
	);
	positiveDirectLobes = uvec3(
		IrcPackRgb9e5(clamp(entry.positiveDirectIrradianceX, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0xb54cda56u),
		IrcPackRgb9e5(clamp(entry.positiveDirectIrradianceY, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0x5384540fu),
		IrcPackRgb9e5(clamp(entry.positiveDirectIrradianceZ, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0xf1bbcdc8u)
	);
	negativeDirectLobes = uvec3(
		IrcPackRgb9e5(clamp(entry.negativeDirectIrradianceX, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0x8ff34781u),
		IrcPackRgb9e5(clamp(entry.negativeDirectIrradianceY, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0x2e2ac13au),
		IrcPackRgb9e5(clamp(entry.negativeDirectIrradianceZ, vec3(0.0), vec3(FOXY_IRC_MAX_RADIANCE)), roundingSeed + 0xcc623af3u)
	);
}

IrcEntry IrcLoadA(const in ivec3 cell, const in int expectedFrame) {
	if (!IrcInside(cell)) return IrcEmptyEntry();
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	if (irradianceCacheA[word + 19u] != IrcFrameTag(expectedFrame)) {
		return IrcEmptyEntry();
	}
	return IrcDecodeCompact(
		irradianceCacheA[word],
		uvec3(irradianceCacheA[word + 1u], irradianceCacheA[word + 2u], irradianceCacheA[word + 3u]),
		uvec3(irradianceCacheA[word + 4u], irradianceCacheA[word + 5u], irradianceCacheA[word + 6u]),
		uvec3(irradianceCacheA[word + 7u], irradianceCacheA[word + 8u], irradianceCacheA[word + 9u]),
		uvec3(irradianceCacheA[word + 10u], irradianceCacheA[word + 11u], irradianceCacheA[word + 12u]),
		uvec3(irradianceCacheA[word + 13u], irradianceCacheA[word + 14u], irradianceCacheA[word + 15u]),
		uvec3(irradianceCacheA[word + 16u], irradianceCacheA[word + 17u], irradianceCacheA[word + 18u])
	);
}

IrcEntry IrcLoadB(const in ivec3 cell, const in int expectedFrame) {
	if (!IrcInside(cell)) return IrcEmptyEntry();
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	if (irradianceCacheB[word + 19u] != IrcFrameTag(expectedFrame)) {
		return IrcEmptyEntry();
	}
	return IrcDecodeCompact(
		irradianceCacheB[word],
		uvec3(irradianceCacheB[word + 1u], irradianceCacheB[word + 2u], irradianceCacheB[word + 3u]),
		uvec3(irradianceCacheB[word + 4u], irradianceCacheB[word + 5u], irradianceCacheB[word + 6u]),
		uvec3(irradianceCacheB[word + 7u], irradianceCacheB[word + 8u], irradianceCacheB[word + 9u]),
		uvec3(irradianceCacheB[word + 10u], irradianceCacheB[word + 11u], irradianceCacheB[word + 12u]),
		uvec3(irradianceCacheB[word + 13u], irradianceCacheB[word + 14u], irradianceCacheB[word + 15u]),
		uvec3(irradianceCacheB[word + 16u], irradianceCacheB[word + 17u], irradianceCacheB[word + 18u])
	);
}

IrcEntry IrcLoadCurrent(const in ivec3 cell, const in int currentFrame) {
	return (currentFrame & 1) == 0
		? IrcLoadA(cell, currentFrame)
		: IrcLoadB(cell, currentFrame);
}

IrcEntry IrcLoadPrevious(const in ivec3 cell, const in int currentFrame) {
	return (currentFrame & 1) == 0
		? IrcLoadB(cell, currentFrame - 1)
		: IrcLoadA(cell, currentFrame - 1);
}

float IrcLoadPreviousSampleCount(
	const in ivec3 worldCell,
	const in int currentFrame
) {
	ivec3 cell = worldCell - IrcPreviousWorldBase(previousCameraPosition) +
		FOXY_IRC_GRID_OFFSET;
	if (!IrcInside(cell)) return 0.0;
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	uint expectedFrame = IrcFrameTag(currentFrame - 1);
	if ((currentFrame & 1) == 0) {
		if (irradianceCacheB[word + 19u] != expectedFrame) return 0.0;
		return max(unpackHalf2x16(irradianceCacheB[word]).x, 0.0);
	}
	if (irradianceCacheA[word + 19u] != expectedFrame) return 0.0;
	return max(unpackHalf2x16(irradianceCacheA[word]).x, 0.0);
}

IrcEntry IrcLoadQueryA(const in ivec3 cell, const in int expectedFrame) {
	if (!IrcInside(cell)) return IrcEmptyEntry();
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	if (irradianceCacheA[word + 19u] != IrcFrameTag(expectedFrame)) {
		return IrcEmptyEntry();
	}
	return IrcDecodeCompact(
		irradianceCacheA[word],
		uvec3(irradianceCacheA[word + 1u], irradianceCacheA[word + 2u], irradianceCacheA[word + 3u]),
		uvec3(irradianceCacheA[word + 4u], irradianceCacheA[word + 5u], irradianceCacheA[word + 6u]),
		uvec3(irradianceCacheA[word + 7u], irradianceCacheA[word + 8u], irradianceCacheA[word + 9u]),
		uvec3(irradianceCacheA[word + 10u], irradianceCacheA[word + 11u], irradianceCacheA[word + 12u]),
		uvec3(0u),
		uvec3(0u)
	);
}

IrcEntry IrcLoadQueryB(const in ivec3 cell, const in int expectedFrame) {
	if (!IrcInside(cell)) return IrcEmptyEntry();
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	if (irradianceCacheB[word + 19u] != IrcFrameTag(expectedFrame)) {
		return IrcEmptyEntry();
	}
	return IrcDecodeCompact(
		irradianceCacheB[word],
		uvec3(irradianceCacheB[word + 1u], irradianceCacheB[word + 2u], irradianceCacheB[word + 3u]),
		uvec3(irradianceCacheB[word + 4u], irradianceCacheB[word + 5u], irradianceCacheB[word + 6u]),
		uvec3(irradianceCacheB[word + 7u], irradianceCacheB[word + 8u], irradianceCacheB[word + 9u]),
		uvec3(irradianceCacheB[word + 10u], irradianceCacheB[word + 11u], irradianceCacheB[word + 12u]),
		uvec3(0u),
		uvec3(0u)
	);
}

IrcEntry IrcLoadCurrentQuery(const in ivec3 cell, const in int currentFrame) {
	return (currentFrame & 1) == 0
		? IrcLoadQueryA(cell, currentFrame)
		: IrcLoadQueryB(cell, currentFrame);
}

IrcEntry IrcLoadDirectA(const in ivec3 cell, const in int expectedFrame) {
	if (!IrcInside(cell)) return IrcEmptyEntry();
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	if (irradianceCacheA[word + 19u] != IrcFrameTag(expectedFrame)) {
		return IrcEmptyEntry();
	}
	IrcEntry entry = IrcEmptyEntry();
	entry.sampleCount = max(unpackHalf2x16(irradianceCacheA[word]).x, 0.0);
	entry.positiveDirectIrradianceX = IrcUnpackRgb9e5(irradianceCacheA[word + 13u]);
	entry.positiveDirectIrradianceY = IrcUnpackRgb9e5(irradianceCacheA[word + 14u]);
	entry.positiveDirectIrradianceZ = IrcUnpackRgb9e5(irradianceCacheA[word + 15u]);
	entry.negativeDirectIrradianceX = IrcUnpackRgb9e5(irradianceCacheA[word + 16u]);
	entry.negativeDirectIrradianceY = IrcUnpackRgb9e5(irradianceCacheA[word + 17u]);
	entry.negativeDirectIrradianceZ = IrcUnpackRgb9e5(irradianceCacheA[word + 18u]);
	return entry;
}

IrcEntry IrcLoadDirectB(const in ivec3 cell, const in int expectedFrame) {
	if (!IrcInside(cell)) return IrcEmptyEntry();
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	if (irradianceCacheB[word + 19u] != IrcFrameTag(expectedFrame)) {
		return IrcEmptyEntry();
	}
	IrcEntry entry = IrcEmptyEntry();
	entry.sampleCount = max(unpackHalf2x16(irradianceCacheB[word]).x, 0.0);
	entry.positiveDirectIrradianceX = IrcUnpackRgb9e5(irradianceCacheB[word + 13u]);
	entry.positiveDirectIrradianceY = IrcUnpackRgb9e5(irradianceCacheB[word + 14u]);
	entry.positiveDirectIrradianceZ = IrcUnpackRgb9e5(irradianceCacheB[word + 15u]);
	entry.negativeDirectIrradianceX = IrcUnpackRgb9e5(irradianceCacheB[word + 16u]);
	entry.negativeDirectIrradianceY = IrcUnpackRgb9e5(irradianceCacheB[word + 17u]);
	entry.negativeDirectIrradianceZ = IrcUnpackRgb9e5(irradianceCacheB[word + 18u]);
	return entry;
}

IrcEntry IrcLoadPreviousDirect(const in ivec3 cell, const in int currentFrame) {
	return (currentFrame & 1) == 0
		? IrcLoadDirectB(cell, currentFrame - 1)
		: IrcLoadDirectA(cell, currentFrame - 1);
}

void IrcStoreCurrent(
	const in ivec3 cell,
	const in IrcEntry entry,
	const in int currentFrame
) {
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	uint compactBaseWord;
	uvec3 compactPositiveWords;
	uvec3 compactNegativeWords;
	uvec3 compactPositiveLobes;
	uvec3 compactNegativeLobes;
	uvec3 compactPositiveDirectLobes;
	uvec3 compactNegativeDirectLobes;
	uint roundingSeed = VoxelGridHashBits(
		IrcIndex(cell) ^ (uint(currentFrame) * 0x9e3779b9u)
	);
	IrcEncodeCompact(
		entry,
		roundingSeed,
		compactBaseWord,
		compactPositiveWords,
		compactNegativeWords,
		compactPositiveLobes,
		compactNegativeLobes,
		compactPositiveDirectLobes,
		compactNegativeDirectLobes
	);
	if ((currentFrame & 1) == 0) {
		irradianceCacheA[word] = compactBaseWord;
		irradianceCacheA[word + 1u] = compactPositiveWords.x;
		irradianceCacheA[word + 2u] = compactPositiveWords.y;
		irradianceCacheA[word + 3u] = compactPositiveWords.z;
		irradianceCacheA[word + 4u] = compactNegativeWords.x;
		irradianceCacheA[word + 5u] = compactNegativeWords.y;
		irradianceCacheA[word + 6u] = compactNegativeWords.z;
		irradianceCacheA[word + 7u] = compactPositiveLobes.x;
		irradianceCacheA[word + 8u] = compactPositiveLobes.y;
		irradianceCacheA[word + 9u] = compactPositiveLobes.z;
		irradianceCacheA[word + 10u] = compactNegativeLobes.x;
		irradianceCacheA[word + 11u] = compactNegativeLobes.y;
		irradianceCacheA[word + 12u] = compactNegativeLobes.z;
		irradianceCacheA[word + 13u] = compactPositiveDirectLobes.x;
		irradianceCacheA[word + 14u] = compactPositiveDirectLobes.y;
		irradianceCacheA[word + 15u] = compactPositiveDirectLobes.z;
		irradianceCacheA[word + 16u] = compactNegativeDirectLobes.x;
		irradianceCacheA[word + 17u] = compactNegativeDirectLobes.y;
		irradianceCacheA[word + 18u] = compactNegativeDirectLobes.z;
		irradianceCacheA[word + 19u] = IrcFrameTag(currentFrame);
	} else {
		irradianceCacheB[word] = compactBaseWord;
		irradianceCacheB[word + 1u] = compactPositiveWords.x;
		irradianceCacheB[word + 2u] = compactPositiveWords.y;
		irradianceCacheB[word + 3u] = compactPositiveWords.z;
		irradianceCacheB[word + 4u] = compactNegativeWords.x;
		irradianceCacheB[word + 5u] = compactNegativeWords.y;
		irradianceCacheB[word + 6u] = compactNegativeWords.z;
		irradianceCacheB[word + 7u] = compactPositiveLobes.x;
		irradianceCacheB[word + 8u] = compactPositiveLobes.y;
		irradianceCacheB[word + 9u] = compactPositiveLobes.z;
		irradianceCacheB[word + 10u] = compactNegativeLobes.x;
		irradianceCacheB[word + 11u] = compactNegativeLobes.y;
		irradianceCacheB[word + 12u] = compactNegativeLobes.z;
		irradianceCacheB[word + 13u] = compactPositiveDirectLobes.x;
		irradianceCacheB[word + 14u] = compactPositiveDirectLobes.y;
		irradianceCacheB[word + 15u] = compactPositiveDirectLobes.z;
		irradianceCacheB[word + 16u] = compactNegativeDirectLobes.x;
		irradianceCacheB[word + 17u] = compactNegativeDirectLobes.y;
		irradianceCacheB[word + 18u] = compactNegativeDirectLobes.z;
		irradianceCacheB[word + 19u] = IrcFrameTag(currentFrame);
	}
}

void IrcInvalidateCurrent(
	const in ivec3 cell,
	const in int currentFrame
) {
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	if ((currentFrame & 1) == 0) {
		irradianceCacheA[word + 19u] = 0u;
	} else {
		irradianceCacheB[word + 19u] = 0u;
	}
}

vec3 IrcEvaluate(const in IrcEntry entry, const in vec3 surfaceNormal) {
	if (entry.sampleCount < 0.5) return vec3(0.0);
	vec3 normal = normalize(surfaceNormal);
	vec3 axisWeight = normal * normal;
	vec3 irradianceX = normal.x >= 0.0
		? entry.positiveIrradianceX
		: entry.negativeIrradianceX;
	vec3 irradianceY = normal.y >= 0.0
		? entry.positiveIrradianceY
		: entry.negativeIrradianceY;
	vec3 irradianceZ = normal.z >= 0.0
		? entry.positiveIrradianceZ
		: entry.negativeIrradianceZ;
	return max(
		irradianceX * axisWeight.x +
		irradianceY * axisWeight.y +
		irradianceZ * axisWeight.z,
		vec3(0.0)
	);
}

vec3 IrcEvaluateDirect(const in IrcEntry entry, const in vec3 surfaceNormal) {
	if (entry.sampleCount < 0.5) return vec3(0.0);
	vec3 normal = normalize(surfaceNormal);
	vec3 axisWeight = normal * normal;
	vec3 irradianceX = normal.x >= 0.0
		? entry.positiveDirectIrradianceX
		: entry.negativeDirectIrradianceX;
	vec3 irradianceY = normal.y >= 0.0
		? entry.positiveDirectIrradianceY
		: entry.negativeDirectIrradianceY;
	vec3 irradianceZ = normal.z >= 0.0
		? entry.positiveDirectIrradianceZ
		: entry.negativeDirectIrradianceZ;
	return max(
		irradianceX * axisWeight.x +
		irradianceY * axisWeight.y +
		irradianceZ * axisWeight.z,
		vec3(0.0)
	);
}

vec3 IrcEvaluateDirectPacked(
	const in uint baseWord,
	const in uvec3 positiveDirectLobes,
	const in uvec3 negativeDirectLobes,
	const in vec3 surfaceNormal
) {
	if (unpackHalf2x16(baseWord).x < 0.5) return vec3(0.0);
	vec3 normal = normalize(surfaceNormal);
	vec3 axisWeight = normal * normal;
	vec3 irradianceX = normal.x >= 0.0
		? IrcUnpackRgb9e5(positiveDirectLobes.x)
		: IrcUnpackRgb9e5(negativeDirectLobes.x);
	vec3 irradianceY = normal.y >= 0.0
		? IrcUnpackRgb9e5(positiveDirectLobes.y)
		: IrcUnpackRgb9e5(negativeDirectLobes.y);
	vec3 irradianceZ = normal.z >= 0.0
		? IrcUnpackRgb9e5(positiveDirectLobes.z)
		: IrcUnpackRgb9e5(negativeDirectLobes.z);
	return max(
		irradianceX * axisWeight.x +
		irradianceY * axisWeight.y +
		irradianceZ * axisWeight.z,
		vec3(0.0)
	);
}

vec3 IrcPreviousDirectWorld(
	const in ivec3 worldCell,
	const in vec3 surfaceNormal,
	const in int currentFrame
) {
	ivec3 cell = worldCell - IrcPreviousWorldBase(previousCameraPosition) +
		FOXY_IRC_GRID_OFFSET;
	if (!IrcInside(cell)) return vec3(0.0);
	uint word = IrcIndex(cell) * FOXY_IRC_WORDS_PER_PROBE;
	uint expectedFrame = IrcFrameTag(currentFrame - 1);
	if ((currentFrame & 1) == 0) {
		if (irradianceCacheB[word + 19u] != expectedFrame) return vec3(0.0);
		return IrcEvaluateDirectPacked(
			irradianceCacheB[word],
			uvec3(
				irradianceCacheB[word + 13u],
				irradianceCacheB[word + 14u],
				irradianceCacheB[word + 15u]
			),
			uvec3(
				irradianceCacheB[word + 16u],
				irradianceCacheB[word + 17u],
				irradianceCacheB[word + 18u]
			),
			surfaceNormal
		);
	}
	if (irradianceCacheA[word + 19u] != expectedFrame) return vec3(0.0);
	return IrcEvaluateDirectPacked(
		irradianceCacheA[word],
		uvec3(
			irradianceCacheA[word + 13u],
			irradianceCacheA[word + 14u],
			irradianceCacheA[word + 15u]
		),
		uvec3(
			irradianceCacheA[word + 16u],
			irradianceCacheA[word + 17u],
			irradianceCacheA[word + 18u]
		),
		surfaceNormal
	);
}

float IrcProbeVisibility(
	const in IrcEntry entry,
	const in vec3 probePosition,
	const in vec3 queryPosition
) {
	vec3 probeToQuery = queryPosition - probePosition;
	float queryDistance = length(probeToQuery);
	if (queryDistance <= 1.0e-5) return 1.0;
	vec3 direction = probeToQuery / queryDistance;
	vec3 axisWeight = abs(direction);
	axisWeight *= axisWeight;
	axisWeight /= max(axisWeight.x + axisWeight.y + axisWeight.z, 1.0e-6);
	vec3 meanByAxis = mix(
		entry.negativeVisibilityMean,
		entry.positiveVisibilityMean,
		step(vec3(0.0), direction)
	);
	vec3 secondByAxis = mix(
		entry.negativeVisibilitySecond,
		entry.positiveVisibilitySecond,
		step(vec3(0.0), direction)
	);
	float meanDistance = dot(meanByAxis, axisWeight);
	float secondMoment = dot(secondByAxis, axisWeight);
	float variance = max(secondMoment - meanDistance * meanDistance, 0.02);
	float biasedDistance = max(queryDistance - 0.22, 0.0);
	if (biasedDistance <= meanDistance) return 1.0;
	float difference = biasedDistance - meanDistance;
	return clamp(variance / (variance + difference * difference), 0.0, 1.0);
}

void IrcAccumulateProbe(
	const in ivec3 cell,
	const in float spatialWeight,
	const in vec3 queryPosition,
	const in vec3 surfaceNormal,
	const in int currentFrame,
	const in bool directOnly,
	inout vec3 radianceSum,
	inout float weightSum,
	inout float temporalSupport,
	inout float validSupport
) {
	if (!IrcInside(cell) || spatialWeight <= 0.0) return;
	IrcEntry entry = IrcLoadCurrent(cell, currentFrame);
	if (entry.sampleCount < 0.5) return;
	float historySupport = min(entry.sampleCount * 0.25, 1.0);
	float visibility = IrcProbeVisibility(
		entry,
		IrcProbePosition(cell),
		queryPosition
	);
	float weight = spatialWeight * historySupport * visibility;
	vec3 probeIrradiance = directOnly
		? IrcEvaluateDirect(entry, surfaceNormal)
		: IrcEvaluate(entry, surfaceNormal);
	radianceSum += probeIrradiance * weight;
	weightSum += weight;
	temporalSupport += spatialWeight * historySupport;
	validSupport += spatialWeight;
}

int IrcPartialShapeDescriptor(const in ivec3 cell) {
	if (!VoxelGridInside(cell)) return -1;
	uint payload = VoxelGridLoadUnchecked(cell);
	if (!VoxelGridTopologyOccupied(payload)) return -1;
	return VoxelShapeDescriptorForPayload(
		VoxelGridMaterial(payload),
		payload
	);
}

float IrcSurfaceTopologyWeight(
	const in ivec3 probeCell,
	const in vec3 queryPosition,
	const in vec3 surfaceNormal
) {
	vec3 normalMagnitude = abs(normalize(surfaceNormal));
	ivec3 normalStep = ivec3(0);
	if (normalMagnitude.x >= normalMagnitude.y && normalMagnitude.x >= normalMagnitude.z) {
		normalStep.x = surfaceNormal.x >= 0.0 ? 1 : -1;
	} else if (normalMagnitude.y >= normalMagnitude.z) {
		normalStep.y = surfaceNormal.y >= 0.0 ? 1 : -1;
	} else {
		normalStep.z = surfaceNormal.z >= 0.0 ? 1 : -1;
	}
	ivec3 queryAirCell = ivec3(floor(queryPosition));
	ivec3 querySurfaceCell = queryAirCell - normalStep;
	if (!VoxelGridInside(querySurfaceCell)) return 1.0;
	uint queryPayload = VoxelGridLoadUnchecked(querySurfaceCell);
	if (!VoxelGridTopologyOccupied(queryPayload)) return 1.0;
	ivec3 probeSurfaceCell = probeCell - normalStep;
	if (!VoxelGridInside(probeCell) ||
		!VoxelGridInside(probeSurfaceCell)) return 0.0;
	int queryShape = VoxelShapeDescriptorForPayload(
		VoxelGridMaterial(queryPayload),
		queryPayload
	);
	if (queryShape >= 0) {
		// Partial surfaces may share probes with the same shape identity.
		int probeShape = IrcPartialShapeDescriptor(probeSurfaceCell);
		if (probeShape < 0) probeShape = IrcPartialShapeDescriptor(probeCell);
		if (probeShape == queryShape) return 1.0;
	}
	uint probeAirPayload = VoxelGridLoadUnchecked(probeCell);
	uint probePayload = VoxelGridLoadUnchecked(probeSurfaceCell);
	return !VoxelGridTopologyOccupied(probeAirPayload) &&
		VoxelGridTopologyOccupied(probePayload) ? 1.0 : 0.0;
}

bool IrcCellHasPartialShape(const in ivec3 cell) {
	return IrcPartialShapeDescriptor(cell) >= 0;
}

vec3 IrcSampleGridModeInternal(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	const in bool directOnly,
	const in bool topologyAware,
	out float confidence
) {
	// Renormalized interpolation excludes invalid probes without adding black weight.
	vec3 probeCoordinate = gridPosition - vec3(0.5);
	ivec3 baseCell = ivec3(floor(probeCoordinate));
	vec3 fraction = fract(probeCoordinate);
	vec3 radianceSum = vec3(0.0);
	float weightSum = 0.0;
	float temporalSupport = 0.0;
	float validSupport = 0.0;
	for (int z = 0; z <= 1; ++z) {
		for (int y = 0; y <= 1; ++y) {
			for (int x = 0; x <= 1; ++x) {
				ivec3 offset = ivec3(x, y, z);
				vec3 axisWeight = mix(vec3(1.0) - fraction, fraction, vec3(offset));
				float weight = axisWeight.x * axisWeight.y * axisWeight.z;
				if (topologyAware) {
					weight *= IrcSurfaceTopologyWeight(
						baseCell + offset,
						gridPosition,
						surfaceNormal
					);
				}
				IrcAccumulateProbe(
					baseCell + offset,
					weight,
					gridPosition,
					surfaceNormal,
					currentFrame,
					directOnly,
					radianceSum,
					weightSum,
					temporalSupport,
					validSupport
				);
			}
		}
	}
	vec3 localPosition = gridPosition - vec3(FOXY_IRC_GRID_OFFSET);
	vec3 edgeDistance = min(
		localPosition,
		vec3(float(FOXY_IRC_SIZE)) - localPosition
	);
	float edgeFade = smoothstep(
		0.0,
		2.0,
		min(edgeDistance.x, min(edgeDistance.y, edgeDistance.z))
	);
	confidence = clamp(
		(temporalSupport / max(validSupport, 1.0e-6)) * edgeFade,
		0.0,
		1.0
	);
	return weightSum > 1.0e-6 ? radianceSum / weightSum : vec3(0.0);
}

vec3 IrcSampleGridMode(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	const in bool directOnly,
	out float confidence
) {
	return IrcSampleGridModeInternal(
		gridPosition,
		surfaceNormal,
		currentCameraPosition,
		currentFrame,
		directOnly,
		false,
		confidence
	);
}

vec3 IrcSampleGridTopologyMode(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	const in bool directOnly,
	out float confidence
) {
	return IrcSampleGridModeInternal(
		gridPosition,
		surfaceNormal,
		currentCameraPosition,
		currentFrame,
		directOnly,
		true,
		confidence
	);
}

float IrcSurfaceContinuationWeight(
	const in vec3 gridPosition,
	const in ivec3 normalStep
) {
	ivec3 airCell = ivec3(floor(gridPosition));
	ivec3 surfaceCell = airCell - normalStep;
	if (!VoxelGridInside(airCell) ||
		!VoxelGridInside(surfaceCell)) return 0.0;
	return !VoxelGridTopologyOccupied(VoxelGridLoadUnchecked(airCell)) &&
		VoxelGridTopologyOccupied(VoxelGridLoadUnchecked(surfaceCell))
		? 1.0
		: 0.0;
}

vec3 IrcSampleSurfaceTopologyMode(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	const in bool directOnly,
	out float confidence
) {
	vec3 normalMagnitude = abs(normalize(surfaceNormal));
	ivec3 normalStep = ivec3(0);
	ivec3 tangentA;
	ivec3 tangentB;
	if (normalMagnitude.x >= normalMagnitude.y && normalMagnitude.x >= normalMagnitude.z) {
		normalStep.x = surfaceNormal.x >= 0.0 ? 1 : -1;
		tangentA = ivec3(0, 1, 0);
		tangentB = ivec3(0, 0, 1);
	} else if (normalMagnitude.y >= normalMagnitude.z) {
		normalStep.y = surfaceNormal.y >= 0.0 ? 1 : -1;
		tangentA = ivec3(1, 0, 0);
		tangentB = ivec3(0, 0, 1);
	} else {
		normalStep.z = surfaceNormal.z >= 0.0 ? 1 : -1;
		tangentA = ivec3(1, 0, 0);
		tangentB = ivec3(0, 1, 0);
	}
	vec3 irradianceSum = vec3(0.0);
	float weightSum = 0.0;
	float availableKernelWeight = 0.0;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			vec3 tapPosition = gridPosition + vec3(tangentA * x + tangentB * y);
			float continuation = x == 0 && y == 0
				? 1.0
				: IrcSurfaceContinuationWeight(tapPosition, normalStep);
			if (x != 0 && y != 0) {
				continuation *= IrcSurfaceContinuationWeight(
					gridPosition + vec3(tangentA * x),
					normalStep
				);
				continuation *= IrcSurfaceContinuationWeight(
					gridPosition + vec3(tangentB * y),
					normalStep
				);
			}
			float kernelWeight = float((x == 0 ? 2 : 1) * (y == 0 ? 2 : 1));
			availableKernelWeight += kernelWeight * continuation;
			float tapConfidence;
			vec3 tapIrradiance = IrcSampleGridTopologyMode(
				tapPosition,
				surfaceNormal,
				currentCameraPosition,
				currentFrame,
				directOnly,
				tapConfidence
			);
			float weight = kernelWeight * continuation * tapConfidence;
			irradianceSum += tapIrradiance * weight;
			weightSum += weight;
		}
	}
	confidence = clamp(
		weightSum / max(availableKernelWeight, 1.0e-6),
		0.0,
		1.0
	);
	return weightSum > 1.0e-6 ? irradianceSum / weightSum : vec3(0.0);
}

float IrcConvolvedSurfaceAxisWeight(
	const in int offset,
	const in float fraction
) {
	if (offset == -1) return 1.0 - fraction;
	if (offset == 0) return 2.0 - fraction;
	if (offset == 1) return 1.0 + fraction;
	return fraction;
}

vec3 IrcSampleConvolvedSurfaceMode(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	const in bool directOnly,
	out float confidence
) {
	vec3 normalMagnitude = abs(normalize(surfaceNormal));
	ivec3 normalAxis;
	ivec3 tangentA;
	ivec3 tangentB;
	if (normalMagnitude.x >= normalMagnitude.y && normalMagnitude.x >= normalMagnitude.z) {
		normalAxis = ivec3(1, 0, 0);
		tangentA = ivec3(0, 1, 0);
		tangentB = ivec3(0, 0, 1);
	} else if (normalMagnitude.y >= normalMagnitude.z) {
		normalAxis = ivec3(0, 1, 0);
		tangentA = ivec3(1, 0, 0);
		tangentB = ivec3(0, 0, 1);
	} else {
		normalAxis = ivec3(0, 0, 1);
		tangentA = ivec3(1, 0, 0);
		tangentB = ivec3(0, 1, 0);
	}
	vec3 probeCoordinate = gridPosition - vec3(0.5);
	ivec3 baseCell = ivec3(floor(probeCoordinate));
	vec3 fraction = fract(probeCoordinate);
	float fractionNormal = dot(fraction, vec3(normalAxis));
	float fractionA = dot(fraction, vec3(tangentA));
	float fractionB = dot(fraction, vec3(tangentB));
	ivec3 normalStep = surfaceNormal.x * float(normalAxis.x) +
		surfaceNormal.y * float(normalAxis.y) +
		surfaceNormal.z * float(normalAxis.z) >= 0.0
		? normalAxis
		: -normalAxis;
	mat3 continuation;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			continuation[x + 1][y + 1] = x == 0 && y == 0
				? 1.0
				: IrcSurfaceContinuationWeight(
					gridPosition + vec3(tangentA * x + tangentB * y),
					normalStep
				);
		}
	}
	continuation[0][0] *= continuation[0][1] * continuation[1][0];
	continuation[0][2] *= continuation[0][1] * continuation[1][2];
	continuation[2][0] *= continuation[2][1] * continuation[1][0];
	continuation[2][2] *= continuation[2][1] * continuation[1][2];
	vec3 radianceSum = vec3(0.0);
	float weightSum = 0.0;
	float temporalSupport = 0.0;
	float validSupport = 0.0;
	for (int normalOffset = 0; normalOffset <= 1; ++normalOffset) {
		float normalWeight = normalOffset == 0
			? 1.0 - fractionNormal
			: fractionNormal;
		for (int b = -1; b <= 2; ++b) {
			for (int a = -1; a <= 2; ++a) {
				ivec3 cell = baseCell + normalAxis * normalOffset +
					tangentA * a + tangentB * b;
				float surfaceWeight = 0.0;
				for (int sourceY = -1; sourceY <= 1; ++sourceY) {
					int localY = b - sourceY;
					if (localY < 0 || localY > 1) continue;
					float bilinearB = localY == 0
						? 1.0 - fractionB
						: fractionB;
					float kernelB = sourceY == 0 ? 2.0 : 1.0;
					for (int sourceX = -1; sourceX <= 1; ++sourceX) {
						int localX = a - sourceX;
						if (localX < 0 || localX > 1) continue;
						float bilinearA = localX == 0
							? 1.0 - fractionA
							: fractionA;
						float kernelA = sourceX == 0 ? 2.0 : 1.0;
						surfaceWeight += continuation[sourceX + 1][sourceY + 1] *
							kernelA * kernelB * bilinearA * bilinearB;
					}
				}
				float spatialWeight = normalWeight * surfaceWeight;
				spatialWeight *= IrcSurfaceTopologyWeight(
					cell,
					gridPosition,
					surfaceNormal
				);
				IrcAccumulateProbe(
					cell,
					spatialWeight,
					gridPosition,
					surfaceNormal,
					currentFrame,
					directOnly,
					radianceSum,
					weightSum,
					temporalSupport,
					validSupport
				);
			}
		}
	}
	vec3 localPosition = gridPosition - vec3(FOXY_IRC_GRID_OFFSET);
	vec3 edgeDistance = min(
		localPosition,
		vec3(float(FOXY_IRC_SIZE)) - localPosition
	);
	float edgeFade = smoothstep(
		0.0,
		2.0,
		min(edgeDistance.x, min(edgeDistance.y, edgeDistance.z))
	);
	confidence = clamp(
		(temporalSupport / max(validSupport, 1.0e-6)) * edgeFade,
		0.0,
		1.0
	);
	return weightSum > 1.0e-6 ? radianceSum / weightSum : vec3(0.0);
}

vec3 IrcSampleOuterSurfaceMode(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	const in bool directOnly,
	out float domainWeight,
	out float confidence
) {
	vec3 normalMagnitude = abs(normalize(surfaceNormal));
	ivec3 normalAxis;
	ivec3 tangentA;
	ivec3 tangentB;
	if (normalMagnitude.x >= normalMagnitude.y && normalMagnitude.x >= normalMagnitude.z) {
		normalAxis = ivec3(1, 0, 0);
		tangentA = ivec3(0, 1, 0);
		tangentB = ivec3(0, 0, 1);
	} else if (normalMagnitude.y >= normalMagnitude.z) {
		normalAxis = ivec3(0, 1, 0);
		tangentA = ivec3(1, 0, 0);
		tangentB = ivec3(0, 0, 1);
	} else {
		normalAxis = ivec3(0, 0, 1);
		tangentA = ivec3(1, 0, 0);
		tangentB = ivec3(0, 1, 0);
	}
	ivec3 normalStep = surfaceNormal.x * float(normalAxis.x) +
		surfaceNormal.y * float(normalAxis.y) +
		surfaceNormal.z * float(normalAxis.z) >= 0.0
		? normalAxis
		: -normalAxis;
	// Partial receivers query the adjacent air-side probe lattice.
	vec3 sampleGridPosition = gridPosition;
	if (IrcPartialShapeDescriptor(ivec3(floor(gridPosition))) >= 0) {
		sampleGridPosition += vec3(normalStep);
	}
	vec3 localPosition = sampleGridPosition - vec3(FOXY_IRC_GRID_OFFSET);
	vec3 voxelEdge = min(
		localPosition,
		vec3(float(FOXY_IRC_SIZE)) - localPosition
	);
	float voxelBoxFade = smoothstep(
		2.0,
		10.0,
		min(voxelEdge.x, min(voxelEdge.y, voxelEdge.z))
	);
	vec3 playerPosition = localPosition - fract(currentCameraPosition) -
		vec3(float(FOXY_IRC_SIZE) * 0.5);
	float traceRange = max(FOXY_VOXEL_GI_MAX_DISTANCE, 1.0);
	float rangeFadeWidth = clamp(traceRange * 0.125, 2.0, 6.0);
	float voxelRangeFade = 1.0 - smoothstep(
		max(traceRange - rangeFadeWidth, 0.0),
		traceRange,
		length(playerPosition)
	);
	domainWeight = voxelBoxFade * voxelRangeFade;
	if (domainWeight <= 0.0) {
		confidence = 0.0;
		return vec3(0.0);
	}
	vec3 probeCoordinate = sampleGridPosition - vec3(0.5);
	ivec3 baseCell = ivec3(floor(probeCoordinate));
	vec3 fraction = fract(probeCoordinate);
	float fractionA = dot(fraction, vec3(tangentA));
	float fractionB = dot(fraction, vec3(tangentB));
	if (normalAxis.x != 0) baseCell.x = int(floor(sampleGridPosition.x));
	if (normalAxis.y != 0) baseCell.y = int(floor(sampleGridPosition.y));
	if (normalAxis.z != 0) baseCell.z = int(floor(sampleGridPosition.z));
	mat3 continuation;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			continuation[x + 1][y + 1] = x == 0 && y == 0
				? 1.0
				: IrcSurfaceContinuationWeight(
					gridPosition + vec3(tangentA * x + tangentB * y),
					normalStep
				);
		}
	}
	continuation[0][0] *= continuation[0][1] * continuation[1][0];
	continuation[0][2] *= continuation[0][1] * continuation[1][2];
	continuation[2][0] *= continuation[2][1] * continuation[1][0];
	continuation[2][2] *= continuation[2][1] * continuation[1][2];
	float inverseFractionA = 1.0 - fractionA;
	float inverseFractionB = 1.0 - fractionB;
	vec4 convolvedXNegative = vec4(
		continuation[0][0] * inverseFractionA,
		continuation[1][0] * (2.0 * inverseFractionA) + continuation[0][0] * fractionA,
		continuation[2][0] * inverseFractionA + continuation[1][0] * (2.0 * fractionA),
		continuation[2][0] * fractionA
	);
	vec4 convolvedXCenter = vec4(
		continuation[0][1] * inverseFractionA,
		continuation[1][1] * (2.0 * inverseFractionA) + continuation[0][1] * fractionA,
		continuation[2][1] * inverseFractionA + continuation[1][1] * (2.0 * fractionA),
		continuation[2][1] * fractionA
	);
	vec4 convolvedXPositive = vec4(
		continuation[0][2] * inverseFractionA,
		continuation[1][2] * (2.0 * inverseFractionA) + continuation[0][2] * fractionA,
		continuation[2][2] * inverseFractionA + continuation[1][2] * (2.0 * fractionA),
		continuation[2][2] * fractionA
	);
	mat4 surfaceWeights = mat4(
		convolvedXNegative * inverseFractionB,
		convolvedXCenter * (2.0 * inverseFractionB) + convolvedXNegative * fractionB,
		convolvedXPositive * inverseFractionB + convolvedXCenter * (2.0 * fractionB),
		convolvedXPositive * fractionB
	);
	vec3 radianceSum = vec3(0.0);
	float weightSum = 0.0;
	float temporalSupport = 0.0;
	float validSupport = 0.0;
	for (int b = -1; b <= 2; ++b) {
		for (int a = -1; a <= 2; ++a) {
			float surfaceWeight = surfaceWeights[b + 1][a + 1];
			ivec3 cell = baseCell + tangentA * a + tangentB * b;
			float spatialWeight = surfaceWeight * IrcSurfaceTopologyWeight(
				cell,
				sampleGridPosition,
				surfaceNormal
			);
			IrcAccumulateProbe(
				cell,
				spatialWeight,
				sampleGridPosition,
				surfaceNormal,
				currentFrame,
				directOnly,
				radianceSum,
				weightSum,
				temporalSupport,
				validSupport
			);
		}
	}
	confidence = clamp(
		temporalSupport / max(validSupport, 1.0e-6),
		0.0,
		1.0
	);
	vec3 strictRadiance = weightSum > 1.0e-6
		? radianceSum / weightSum
		: vec3(0.0);

	// Partial surfaces use the visibility-weighted estimator only when strict
	// air/surface topology lacks support.
	if (confidence >= 0.02) return strictRadiance;
	ivec3 queryCell = ivec3(floor(gridPosition));
	if (!IrcCellHasPartialShape(queryCell) &&
		!IrcCellHasPartialShape(queryCell - normalStep)) {
		return strictRadiance;
	}
	float nearbyConfidence;
	vec3 nearbyRadiance = IrcSampleGridMode(
		sampleGridPosition,
		surfaceNormal,
		currentCameraPosition,
		currentFrame,
		directOnly,
		nearbyConfidence
	);
	if (nearbyConfidence > confidence) {
		confidence = nearbyConfidence;
		return nearbyRadiance;
	}
	return strictRadiance;
}

vec3 IrcSampleGrid(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	out float confidence
) {
	return IrcSampleConvolvedSurfaceMode(
		gridPosition,
		surfaceNormal,
		currentCameraPosition,
		currentFrame,
		false,
		confidence
	);
}

vec3 IrcSampleGridDirect(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	out float confidence
) {
	return IrcSampleGridTopologyMode(
		gridPosition,
		surfaceNormal,
		currentCameraPosition,
		currentFrame,
		true,
		confidence
	);
}

vec3 IrcSampleNearestMode(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in int currentFrame,
	const in bool directOnly,
	out float confidence
) {
	ivec3 cell = ivec3(floor(gridPosition));
	if (!IrcInside(cell)) {
		confidence = 0.0;
		return vec3(0.0);
	}
	IrcEntry entry = IrcLoadCurrent(cell, currentFrame);
	confidence = min(entry.sampleCount * 0.25, 1.0);
	if (entry.sampleCount < 0.5) return vec3(0.0);
	return directOnly
		? IrcEvaluateDirect(entry, surfaceNormal)
		: IrcEvaluate(entry, surfaceNormal);
}

vec3 IrcSampleSurfaceGridMode(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	const in bool directOnly,
	out float confidence
) {
	vec3 normalMagnitude = abs(normalize(surfaceNormal));
	ivec3 tangentA;
	ivec3 tangentB;
	if (normalMagnitude.x >= normalMagnitude.y && normalMagnitude.x >= normalMagnitude.z) {
		tangentA = ivec3(0, 1, 0);
		tangentB = ivec3(0, 0, 1);
	} else if (normalMagnitude.y >= normalMagnitude.z) {
		tangentA = ivec3(1, 0, 0);
		tangentB = ivec3(0, 0, 1);
	} else {
		tangentA = ivec3(1, 0, 0);
		tangentB = ivec3(0, 1, 0);
	}
	vec3 irradianceSum = vec3(0.0);
	float weightSum = 0.0;
	float supportSum = 0.0;
	for (int y = -1; y <= 1; ++y) {
		for (int x = -1; x <= 1; ++x) {
			float tapConfidence;
			vec3 tapPosition = gridPosition + vec3(tangentA * x + tangentB * y);
			vec3 tapIrradiance = IrcSampleGridMode(
				tapPosition,
				surfaceNormal,
				currentCameraPosition,
				currentFrame,
				directOnly,
				tapConfidence
			);
			float kernelWeight = float((x == 0 ? 2 : 1) * (y == 0 ? 2 : 1));
			float weight = kernelWeight * tapConfidence;
			irradianceSum += tapIrradiance * weight;
			weightSum += weight;
			supportSum += kernelWeight * tapConfidence;
		}
	}
	confidence = clamp(supportSum / 16.0, 0.0, 1.0);
	return weightSum > 1.0e-6 ? irradianceSum / weightSum : vec3(0.0);
}

vec3 IrcSampleGridUnoccluded(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in int currentFrame,
	out float confidence
) {
	vec3 probeCoordinate = gridPosition - vec3(0.5);
	ivec3 baseCell = ivec3(floor(probeCoordinate));
	vec3 fraction = fract(probeCoordinate);
	vec3 radianceSum = vec3(0.0);
	float weightSum = 0.0;
	float validWeightSum = 0.0;
	for (int z = 0; z <= 1; ++z) {
		for (int y = 0; y <= 1; ++y) {
			for (int x = 0; x <= 1; ++x) {
				ivec3 offset = ivec3(x, y, z);
				ivec3 cell = baseCell + offset;
				if (!IrcInside(cell)) continue;
				IrcEntry entry = IrcLoadCurrent(cell, currentFrame);
				if (entry.sampleCount < 0.5) continue;
				vec3 axisWeight = mix(vec3(1.0) - fraction, fraction, vec3(offset));
				float spatialWeight = axisWeight.x * axisWeight.y * axisWeight.z;
				float historySupport = min(entry.sampleCount * 0.25, 1.0);
				float weight = spatialWeight * historySupport;
				radianceSum += IrcEvaluate(entry, surfaceNormal) * weight;
				weightSum += weight;
				validWeightSum += spatialWeight;
			}
		}
	}
	confidence = clamp(weightSum / max(validWeightSum, 1.0e-6), 0.0, 1.0);
	return weightSum > 1.0e-6 ? radianceSum / weightSum : vec3(0.0);
}

vec3 IrcSampleGridTopologyUnoccluded(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in int currentFrame,
	out float confidence
) {
	vec3 probeCoordinate = gridPosition - vec3(0.5);
	ivec3 baseCell = ivec3(floor(probeCoordinate));
	vec3 fraction = fract(probeCoordinate);
	vec3 radianceSum = vec3(0.0);
	float weightSum = 0.0;
	float validWeightSum = 0.0;
	for (int z = 0; z <= 1; ++z) {
		for (int y = 0; y <= 1; ++y) {
			for (int x = 0; x <= 1; ++x) {
				ivec3 offset = ivec3(x, y, z);
				ivec3 cell = baseCell + offset;
				if (!IrcInside(cell)) continue;
				vec3 axisWeight = mix(vec3(1.0) - fraction, fraction, vec3(offset));
				float spatialWeight = axisWeight.x * axisWeight.y * axisWeight.z;
				spatialWeight *= IrcSurfaceTopologyWeight(
					cell,
					gridPosition,
					surfaceNormal
				);
				if (spatialWeight <= 0.0) continue;
				validWeightSum += spatialWeight;
				IrcEntry entry = IrcLoadCurrent(cell, currentFrame);
				if (entry.sampleCount < 0.5) continue;
				float historySupport = min(entry.sampleCount * 0.25, 1.0);
				float weight = spatialWeight * historySupport;
				radianceSum += IrcEvaluate(entry, surfaceNormal) * weight;
				weightSum += weight;
			}
		}
	}
	confidence = clamp(weightSum / max(validWeightSum, 1.0e-6), 0.0, 1.0);
	return weightSum > 1.0e-6 ? radianceSum / weightSum : vec3(0.0);
}

vec3 IrcSampleGridIsotropic(
	const in vec3 gridPosition,
	const in int currentFrame,
	out float confidence
) {
	vec3 probeCoordinate = gridPosition - vec3(0.5);
	ivec3 baseCell = ivec3(floor(probeCoordinate));
	vec3 fraction = fract(probeCoordinate);
	vec3 radianceSum = vec3(0.0);
	float weightSum = 0.0;
	float validWeightSum = 0.0;
	for (int z = 0; z <= 1; ++z) {
		for (int y = 0; y <= 1; ++y) {
			for (int x = 0; x <= 1; ++x) {
				ivec3 offset = ivec3(x, y, z);
				ivec3 cell = baseCell + offset;
				if (!IrcInside(cell)) continue;
				IrcEntry entry = IrcLoadCurrent(cell, currentFrame);
				if (entry.sampleCount < 0.5) continue;
				vec3 axisWeight = mix(vec3(1.0) - fraction, fraction, vec3(offset));
				float spatialWeight = axisWeight.x * axisWeight.y * axisWeight.z;
				float historySupport = min(entry.sampleCount * 0.25, 1.0);
				float visibility = IrcProbeVisibility(
					entry,
					IrcProbePosition(cell),
					gridPosition
				);
				float weight = spatialWeight * historySupport * visibility;
				radianceSum += entry.radiance * weight;
				weightSum += weight;
				validWeightSum += spatialWeight;
			}
		}
	}
	confidence = clamp(weightSum / max(validWeightSum, 1.0e-6), 0.0, 1.0);
	return weightSum > 1.0e-6 ? radianceSum / weightSum : vec3(0.0);
}

IrcEntry IrcNearestEntryGrid(
	const in vec3 gridPosition,
	const in vec3 surfaceNormal,
	const in vec3 currentCameraPosition,
	const in int currentFrame,
	out ivec3 localCell
) {
	localCell = ivec3(floor(gridPosition));
	return IrcLoadCurrent(localCell, currentFrame);
}

vec3 IrcNearestDirectionGrid(
	const in vec3 gridPosition,
	const in int currentFrame,
	out float skyLuminance,
	out float sampleCount
) {
	ivec3 cell = ivec3(floor(gridPosition));
	IrcEntry entry = IrcLoadCurrent(cell, currentFrame);
	skyLuminance = entry.skyLuminance;
	sampleCount = entry.sampleCount;
	float directionLength = length(entry.directionMoment);
	return directionLength > 1.0e-6
		? entry.directionMoment / directionLength
		: vec3(0.0);
}

vec3 IrcNormalFromCode(const in uint code) { return vec3(0.0); }

#endif

#endif
