// A HUD side view (live mode): Godot's render of the squadmate's / probe's camera, with the game's infrared ramp when
// its IR view is on (as infrared.gdshader), and the old school look when it is on (as oldschool.gdshader).
shader_type canvas_item;

uniform bool ir = false;
// the game's HUD (palette index in red, as sent by the bridge) and this view's frame in its 320 x 400 screen: where
// the game draws over its small view this view lets the HUD through: a tooltip (black, index 0, with green letters
// next to it) and, in the top label_rows rows, the game's labels (indices label_a / label_b: the probe's compass,
// lavender letters with a dark blue outline; the target camera's red name)
uniform sampler2D hud : filter_nearest;
uniform vec4 frame = vec4(0.0, 0.0, 320.0, 400.0);
uniform float label_rows = 0.0;
uniform float label_a = 47.0;
uniform float label_b = 59.0;
// old school (F12): the game's pixel grid of this small view (one cell per pixel of its 320 x 400 screen) and the
// planet's palette
uniform bool old = false;
uniform sampler2D pal_tex : filter_nearest;
uniform int first_index = 17;

float idx(vec2 p) {
	return floor(texture(hud, p / vec2(320.0, 400.0)).r * 255.0 + 0.5);
}

bool over(vec2 p) {
	return idx(p) == 0.0;
}

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

vec3 nearest(vec3 c) {
	// nearest palette colour in luma / chroma, the hue weighing twice (as oldschool.gdshader)
	vec3 cy = vec3(dot(c, vec3(0.299, 0.587, 0.114)), 0.0, 0.0);
	cy.y = (c.b - cy.x) * 0.564;
	cy.z = (c.r - cy.x) * 0.713;
	float best = 1e9;
	vec3 out_col = c;
	for (int i = first_index; i < 256; i++) {
		vec3 p = texelFetch(pal_tex, ivec2(i, 0), 0).rgb;
		float py = dot(p, vec3(0.299, 0.587, 0.114));
		vec3 e = cy - vec3(py, (p.b - py) * 0.564, (p.r - py) * 0.713);
		float d = dot(e * e, vec3(1.0, 2.0, 2.0));
		if (d < best) {
			best = d;
			out_col = p;
		}
	}
	return out_col;
}

void fragment() {
	vec2 p = frame.xy + UV * frame.zw;
	if (over(p) || over(p + vec2(1.0, 0.0)) || over(p - vec2(1.0, 0.0)) || over(p + vec2(0.0, 1.0)) || over(p - vec2(0.0, 1.0))) {
		discard;
	}
	if (p.y < frame.y + label_rows) {
		float k = idx(p);
		if (k == label_a || k == label_b) {
			discard;
		}
	}
	vec3 c;
	if (old) {
		// each cell the mean of what it covers, then the nearest colour of the planet's palette
		vec2 cell = floor(UV * frame.zw);
		c = vec3(0.0);
		for (int k = 0; k < 4; k++) {
			vec2 o = vec2(float(k & 1), float(k >> 1)) * 0.5 + 0.25;
			c += texture(TEXTURE, (cell + o) / frame.zw).rgb;
		}
		c = nearest(c * 0.25);
	} else {
		c = texture(TEXTURE, UV).rgb;
	}
	if (ir) {
		c = ramp(clamp(dot(c, vec3(0.299, 0.587, 0.114)) * 1.15, 0.0, 1.0));
	}
	COLOR = vec4(c, 1.0);
}
