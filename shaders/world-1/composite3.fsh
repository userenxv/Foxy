#version 430 compatibility
#include "/lib/settings.glsl"
#define FOXY_MATERIAL_REFLECTION_FILTER_ORDER 0
/* RENDERTARGETS: 0 */
const bool colortex0Clear = false;
#include "/features/material/reflection_filter_pass.fsh"
