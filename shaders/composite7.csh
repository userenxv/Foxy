#version 430
// Water/cloud producers write custom images. Iris' post-dispatch barrier
// exposes those writes to the read-only samplers used by volume generation.
layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
const ivec3 workGroups = ivec3(1, 1, 1);
void main() {}
