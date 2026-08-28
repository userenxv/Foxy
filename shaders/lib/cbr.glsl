#ifndef FOXY_CBR_GLSL
#define FOXY_CBR_GLSL

const int CBR_BLOCK_SIZE = 4;
const int CBR_PHASE_COUNT = 16;

int CbrPhaseIndex(const in int frameIndex) {
	int phase = frameIndex % CBR_PHASE_COUNT;
	return phase < 0 ? phase + CBR_PHASE_COUNT : phase;
}

int CbrTemporalSampleIndex(const in int frameIndex) {
	return max(frameIndex, 0) / CBR_PHASE_COUNT;
}

ivec2 CbrPhaseOffset(const in int frameIndex) {
	int phase = CbrPhaseIndex(frameIndex);
	if (phase == 0) return ivec2(0, 0);
	if (phase == 1) return ivec2(2, 0);
	if (phase == 2) return ivec2(0, 2);
	if (phase == 3) return ivec2(2, 2);
	if (phase == 4) return ivec2(1, 1);
	if (phase == 5) return ivec2(3, 1);
	if (phase == 6) return ivec2(1, 3);
	if (phase == 7) return ivec2(3, 3);
	if (phase == 8) return ivec2(1, 0);
	if (phase == 9) return ivec2(3, 0);
	if (phase == 10) return ivec2(1, 2);
	if (phase == 11) return ivec2(3, 2);
	if (phase == 12) return ivec2(0, 1);
	if (phase == 13) return ivec2(2, 1);
	if (phase == 14) return ivec2(0, 3);
	return ivec2(2, 3);
}

ivec2 CbrCompactPixel(const in ivec2 fullPixel) {
	return fullPixel / CBR_BLOCK_SIZE;
}

ivec2 CbrFullPixel(
	const in ivec2 compactPixel,
	const in ivec2 renderSize,
	const in int frameIndex
) {
	return clamp(
		compactPixel * CBR_BLOCK_SIZE + CbrPhaseOffset(frameIndex),
		ivec2(0),
		max(renderSize - ivec2(1), ivec2(0))
	);
}

float CbrPixelActive(
	const in ivec2 fullPixel,
	const in ivec2 renderSize,
	const in int frameIndex
) {
	ivec2 sampledPixel = CbrFullPixel(CbrCompactPixel(fullPixel), renderSize, frameIndex);
	return fullPixel.x == sampledPixel.x && fullPixel.y == sampledPixel.y ? 1.0 : 0.0;
}

#endif
