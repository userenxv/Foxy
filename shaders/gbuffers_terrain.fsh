#version 120
#extension GL_ARB_shader_texture_lod : enable
#define TERRAIN
#define ALPHA_TEST
const bool colortex2Clear = true;
const vec4 colortex2ClearColor = vec4(0.0, 0.0, 0.0, 0.0);
#include "/entry/gbuffers/lit.fsh"

