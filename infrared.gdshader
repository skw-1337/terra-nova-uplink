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

// the planet's IR colours (viewer.gd _ir_colours): what the ground, the plants and the models drew through the game's
// IR tables is snapped to the nearest of them (kept); anything else (sky, suits, effects) takes the luma ramp
uniform sampler2D ir_pal : filter_nearest;
uniform int ir_n = 0;

vec3 ir_keep(vec3 c, vec3 other) {
	float best = 1e9;
	vec3 o = other;
	for (int i = 0; i < ir_n; i++) {
		vec3 p = texelFetch(ir_pal, ivec2(i, 0), 0).rgb;
		vec3 e = p - c;
		float d = dot(e, e);
		if (d < best) {
			best = d;
			o = p;
		}
	}
	return best < 0.004 ? o : other;
}

void fragment() {
	vec3 c = texture(screen_tex, SCREEN_UV).rgb;
	COLOR = vec4(ir_keep(c, ramp(clamp(dot(c, vec3(0.299, 0.587, 0.114)) * 1.15, 0.0, 1.0))), 1.0);
}
