#version 120
#define ALPHA_TEST
#define WEATHER
/* DRAWBUFFERS:3 */
const bool colortex3Clear = true;
#include "/program/gbuffer_weather.fsh"
