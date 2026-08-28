#version 430

#define FOXY_SSPT_ATROUS_PASS 6
#define FOXY_SSPT_ATROUS_STEP 2
#define FOXY_SSPT_ATROUS_SHARED 0
#define FOXY_SSPT_ATROUS_CROSS_KERNEL
#define FOXY_SSPT_ATROUS_BOOTSTRAP_INPUT
#include "/entry/deferred/sspt_atrous.csh"
