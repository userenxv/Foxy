#version 430 compatibility
#include "/lib/settings.glsl"
#define FOXY_MATERIAL_REFLECTION_FILTER_ORDER 3
/* RENDERTARGETS: 14,15 */
const bool colortex14Clear = false;
const bool colortex15Clear = false;
#include "/features/material/reflection_filter_pass.fsh"
