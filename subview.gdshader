// A HUD side view (live mode): Godot's render of the squadmate's / probe's camera, with the game's infrared ramp when
// its IR view is on (as infrared.gdshader).
shader_type canvas_item;

uniform bool ir = false;
// the game's HUD (palette index in red, as sent by the bridge) and this view's frame in its 320 x 400 screen: where
// the game draws over its small view (a tooltip: black, index 0, with green letters) this view lets the HUD through
uniform sampler2D hud : filter_nearest;
uniform vec4 frame = vec4(0.0, 0.0, 320.0, 400.0);

bool over(vec2 p) {
	return texture(hud, p / vec2(320.0, 400.0)).r < 0.5 / 255.0;
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

void fragment() {
	vec2 p = frame.xy + UV * frame.zw;
	if (over(p) || over(p + vec2(1.0, 0.0)) || over(p - vec2(1.0, 0.0)) || over(p + vec2(0.0, 1.0)) || over(p - vec2(0.0, 1.0))) {
		discard;
	}
	vec3 c = texture(TEXTURE, UV).rgb;
	if (ir) {
		c = ramp(clamp(dot(c, vec3(0.299, 0.587, 0.114)) * 1.15, 0.0, 1.0));
	}
	COLOR = vec4(c, 1.0);
}
