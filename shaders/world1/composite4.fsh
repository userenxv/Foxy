#version 430 compatibility
#include "/lib/settings.glsl"
#define FOXY_MATERIAL_REFLECTION_FILTER_ORDER 1
/* RENDERTARGETS: 14 */
const bool colortex14Clear = false;
#include "/features/material/reflection_filter_pass.fsh"
