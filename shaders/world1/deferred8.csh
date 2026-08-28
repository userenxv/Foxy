#version 430

#include "/lib/settings.glsl"

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
const vec2 workGroupsRender = vec2(
	FOXY_RAY_RESOLUTION,
	FOXY_RAY_RESOLUTION
);

void main() {
}
