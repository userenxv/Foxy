#define FOXY_VOLUME_RESOLVE_COMPUTE
#include "/features/volumetric/resolve.glsl"

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
const vec2 workGroupsRender = vec2(1.0, 1.0);
layout(rgba16f) writeonly uniform image2D colorimg0;
layout(rgba16f) writeonly uniform image2D colorimg6;

void main() {
	ResolvePrepareTile(MakeResolveContext());
	ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
	if (any(greaterThanEqual(pixel, ivec2(SrRenderSize())))) return;
	vec2 uv = (vec2(pixel) + vec2(0.5)) / SrRenderSize();
	vec4 volume;
	vec4 scene;
	ResolveVolumeAtUv(uv, volume, scene);
	imageStore(colorimg6, pixel, volume);
	imageStore(colorimg0, pixel, scene);
}
