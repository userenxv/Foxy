#ifndef FOXY_RSM_AXIS_GLSL
#define FOXY_RSM_AXIS_GLSL

//
//
//
//

const float RSM_AXIS_PACK_SCALE = 0.125;
const float RSM_AXIS_UNPACK_SCALE = 8.0;

vec3 RsmAxisNormal(const in int axisIndex) {
	if (axisIndex == 0) return vec3(1.0, 0.0, 0.0);
	if (axisIndex == 1) return vec3(-1.0, 0.0, 0.0);
	if (axisIndex == 2) return vec3(0.0, 1.0, 0.0);
	if (axisIndex == 3) return vec3(0.0, -1.0, 0.0);
	if (axisIndex == 4) return vec3(0.0, 0.0, 1.0);
	return vec3(0.0, 0.0, -1.0);
}

float RsmPackAxisNormal(const in vec3 normal) {
	vec3 magnitude = abs(normal);
	float axisIndex;
	if (magnitude.x >= magnitude.y && magnitude.x >= magnitude.z) {
		axisIndex = normal.x > 0.0 ? 0.0 : 1.0;
	} else if (magnitude.y >= magnitude.z) {
		axisIndex = normal.y > 0.0 ? 2.0 : 3.0;
	} else {
		axisIndex = normal.z > 0.0 ? 4.0 : 5.0;
	}
	return (axisIndex + 1.0) * RSM_AXIS_PACK_SCALE;
}

bool RsmUnpackAxisNormal(const in float packedAlpha, out vec3 vplNormal) {
	float axisIndex = packedAlpha * RSM_AXIS_UNPACK_SCALE - 1.0;
	if (axisIndex < -0.5 || axisIndex > 5.5) return false;
	vplNormal = RsmAxisNormal(int(floor(axisIndex + 0.5)));
	return true;
}

#endif
