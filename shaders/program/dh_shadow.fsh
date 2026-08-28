uniform float far;

flat in float dhShadowOpaqueCaster;
in vec3 dhShadowPlayerPos;

void main() {
	if (dhShadowOpaqueCaster < 0.5 || length(dhShadowPlayerPos.xz) < max(far, 1.0)) {
		discard;
	}
	gl_FragColor = vec4(1.0);
}
