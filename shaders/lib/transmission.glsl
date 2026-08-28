#ifndef FOXY_TRANSMISSION_GLSL
#define FOXY_TRANSMISSION_GLSL

// Compact material IDs shared by the shadow-color and voxel-ray paths.
// 10300..10315: full stained glass, dye order follows vanilla.
// 10316: clear glass.
// 10600..10871: pane dye * 16 + N/E/S/W connection bits.  Encoding
// connections avoids treating every pane as a full-cell cross.
float TransmissionCanonicalId(const in float materialId) {
	return floor(materialId + 0.5);
}

float TransmissionDyeIndex(const in float materialId) {
	float canonicalId = TransmissionCanonicalId(materialId);
	if (canonicalId >= 10300.0 && canonicalId <= 10315.0) {
		return canonicalId - 10300.0;
	}
	if (canonicalId >= 10600.0 && canonicalId <= 10871.0) {
		float paneDye = floor((canonicalId - 10600.0) * (1.0 / 16.0));
		return paneDye < 16.0 ? paneDye : -1.0;
	}
	return -1.0;
}

bool TransmissionIsGlass(const in float materialId) {
	float canonicalId = TransmissionCanonicalId(materialId);
	return (canonicalId >= 10300.0 && canonicalId <= 10316.0) ||
		(canonicalId >= 10600.0 && canonicalId <= 10871.0);
}

bool TransmissionIsGlassUint(const in uint materialId) {
	return (materialId >= 10300u && materialId <= 10316u) ||
		(materialId >= 10600u && materialId <= 10871u);
}

bool TransmissionIsPane(const in float materialId) {
	float canonicalId = TransmissionCanonicalId(materialId);
	return canonicalId >= 10600.0 && canonicalId <= 10871.0;
}

bool TransmissionIsPane(const in uint materialId) {
	return materialId >= 10600u && materialId <= 10871u;
}

uint TransmissionPaneConnections(const in uint materialId) {
	return (materialId - 10600u) & 15u;
}

vec3 TransmissionDye(const in float dyeIndex) {
	int dye = int(floor(dyeIndex + 0.5));
	if (dye == 0) return vec3(0.84, 0.84, 0.80); // white
	if (dye == 1) return vec3(0.94, 0.38, 0.07); // orange
	if (dye == 2) return vec3(0.76, 0.12, 0.68); // magenta
	if (dye == 3) return vec3(0.20, 0.64, 0.94); // light blue
	if (dye == 4) return vec3(0.94, 0.80, 0.09); // yellow
	if (dye == 5) return vec3(0.44, 0.87, 0.09); // lime
	if (dye == 6) return vec3(0.94, 0.40, 0.59); // pink
	if (dye == 7) return vec3(0.31, 0.33, 0.34); // gray
	if (dye == 8) return vec3(0.59, 0.61, 0.61); // light gray
	if (dye == 9) return vec3(0.08, 0.59, 0.66); // cyan
	if (dye == 10) return vec3(0.45, 0.14, 0.72); // purple
	if (dye == 11) return vec3(0.07, 0.20, 0.78); // blue
	if (dye == 12) return vec3(0.45, 0.22, 0.07); // brown
	if (dye == 13) return vec3(0.11, 0.47, 0.09); // green
	if (dye == 14) return vec3(0.78, 0.07, 0.045); // red
	if (dye == 15) return vec3(0.060, 0.065, 0.070); // black
	return vec3(0.92); // clear glass
}

vec3 TransmissionColor(const in float materialId) {
	return TransmissionDye(TransmissionDyeIndex(materialId));
}

#endif
