#version 430

layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
// Retain the pass and its Iris memory barrier; there is no per-pixel work.
const ivec3 workGroups = ivec3(1, 1, 1);

void main() {
}
