#version 430 compatibility
layout(early_fragment_tests) in;
/* RENDERTARGETS: 0,2,13 */
const bool colortex13Clear = true;
#include "/entry/gbuffers/water.fsh"

