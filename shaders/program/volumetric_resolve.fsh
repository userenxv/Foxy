// Raster reference and fallback. The compute path calls the same composition kernel.
#include "/features/volumetric/resolve.glsl"
varying vec2 texcoord;
void main() {
	ResolveVolumeAtUv(texcoord, gl_FragData[0], gl_FragData[1]);
}
