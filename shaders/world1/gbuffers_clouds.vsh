#version 120

void main() {
	// The matching fragment stage discards every vanilla-cloud fragment.
	gl_Position = vec4(-2.0, -2.0, -2.0, 1.0);
}
