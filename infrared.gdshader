// Infrared view (live mode, the game's IR on): its orange ramp over the 3D view, under the HUD. The game redraws
// the ground and the objects with the palette's orange shades, darkest to white; here the view's luma picks the
// shade on that ramp (stops read from the game's palette in IR).
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;

vec3 ramp(float l) {
	const vec3 C[6] = {vec3(0.0), vec3(155.0, 75.0, 0.0) / 255.0, vec3(255.0, 139.0, 27.0) / 255.0,
			vec3(255.0, 171.0, 87.0) / 255.0, vec3(255.0, 207.0, 155.0) / 255.0, vec3(1.0)};
	const float T[6] = {0.0, 0.22, 0.42, 0.62, 0.82, 1.0};
	for (int i = 1; i < 6; i++) {
		if (l <= T[i]) {
			return mix(C[i - 1], C[i], (l - T[i - 1]) / (T[i] - T[i - 1]));
		}
	}
	return C[5];
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	COLOR = vec4(ramp(clamp(dot(c, vec3(0.299, 0.587, 0.114)) * 1.15, 0.0, 1.0)), 1.0);
}
