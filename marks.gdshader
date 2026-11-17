// Impact marks (an extra, off unless TN_FX_MARKS=1: fx_marks.gd): what the shots leave where they hit the ground.
// Each mark is a flat box laid on the ground; whatever the view shows inside it (the ground, read back from the depth
// of the picture) is darkened by the mark's pattern: no mesh to fit to the slopes, nothing drawn on what stands in
// front. INSTANCE_CUSTOM: x the kind (0 a bullet's pock, 1 a laser's burnt line, 2 an energy bolt's scorched spot,
// 3 a blast's burn), y when it was made (s), z a number of its own (its pattern), w its strength.
shader_type spatial;
render_mode unshaded, blend_mul, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://tn_haze.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform float now = 0.0;            // the clock the marks are dated with (s)
uniform float hold = 45.0;          // a mark stays whole this long, then fades over "fade" seconds
uniform float fade = 20.0;

varying flat vec4 mark;
varying flat mat4 to_box;
varying flat float widen;

float mk_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float mk_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(mk_hash(i), mk_hash(i + vec2(1.0, 0.0)), f.x), mix(mk_hash(i + vec2(0.0, 1.0)), mk_hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

void vertex() {
	mark = INSTANCE_CUSTOM;
	to_box = inverse(MODEL_MATRIX);
	widen = 1.0;
	if (int(INSTANCE_CUSTOM.x + 0.5) == 1) {
		// a laser's line is thin: far away, or seen at a grazing angle, thinner than a pixel of the picture (it broke
		// into dashes). Its box is then widened to about 2 pixels, and the line drawn fainter (fragment)
		vec3 c = MODEL_MATRIX[3].xyz;
		vec3 up = normalize(MODEL_MATRIX[1].xyz);
		vec3 tc = CAMERA_POSITION_WORLD - c;
		float d = length(tc);
		float graze = max(abs(dot(up, tc / max(d, 1e-4))), 0.05);
		float px = d * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);       // a pixel's width there
		widen = max(1.0, 2.0 * px / (graze * length(MODEL_MATRIX[2].xyz)));
		VERTEX.z *= widen;
	}
}

void fragment() {
	float age = now - mark.y;
	float left = mark.w * (1.0 - smoothstep(hold, hold + fade, age));
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 wp = (INV_VIEW_MATRIX * vec4(vp.xyz / vp.w, 1.0)).xyz;
	vec3 b = (to_box * vec4(wp, 1.0)).xyz;             // in the box: -0.5 .. 0.5
	vec2 q = b.xz * 2.0;                               // -1 .. 1 across the mark
	float fw = fwidth(q.y);                            // (before any discard: a pixel's width across the mark)
	if (left <= 0.003 || tn_ir > 0.5 || abs(b.x) > 0.5 || abs(b.y) > 0.5 || abs(b.z) > 0.5 * widen) {
		discard;
	}
	int kind = int(mark.x + 0.5);
	float seed = mark.z;
	float r = length(q);
	float a = 0.0;
	vec3 tint = vec3(0.1, 0.085, 0.07);                // charred
	if (kind == 1) {
		// a laser's line: a thin black core, a browner edge, uneven along its length (the same on the next stretch:
		// from the place on the map); thinner than a pixel: its share of the pixel
		float n = mk_noise(wp.xz * 26.0 + seed);
		float core = 0.45 + 0.4 * n;
		fw = clamp(fw, 1e-4, 4.0 * widen);
		float cov = clamp((core - abs(q.y)) / fw + 0.5, 0.0, 1.0) * min(1.0, 2.0 * core / fw);
		float halo = (1.0 - smoothstep(0.3, 1.0, abs(q.y))) * 0.45 * (1.0 - smoothstep(0.3, 0.8, fw));
		a = max(cov * (0.8 + 0.2 * mk_noise(wp.xz * 9.0)), halo);
		tint = mix(vec3(0.24, 0.17, 0.12), vec3(0.05, 0.04, 0.04), cov);
	} else if (kind == 0) {
		// a bullet's pock: a small dark hole, its edge chipped
		float n = mk_noise(q * 3.0 + seed * 7.0);
		a = 1.0 - smoothstep(0.45, 0.95, r + (n - 0.5) * 0.5);
		tint = vec3(0.16, 0.14, 0.13);
	} else if (kind == 2) {
		// an energy bolt's spot: scorched black in the middle, fading out unevenly
		float n = mk_noise(q * 2.5 + seed * 5.0);
		a = 1.0 - smoothstep(0.15, 0.95, r + (n - 0.5) * 0.45);
		tint = mix(vec3(0.2, 0.15, 0.11), vec3(0.05, 0.04, 0.04), 1.0 - smoothstep(0.0, 0.6, r));
	} else {
		// a blast: a wide burn, black in its middle, thrown out in streaks
		float ang = atan(q.y, q.x);
		float streak = mk_noise(vec2(ang * 3.5 + seed * 11.0, r * 1.5)) * 0.6 + mk_noise(vec2(ang * 9.0 + seed, 3.0)) * 0.4;
		float edge = 0.6 + 0.4 * streak;
		float n = mk_noise(q * 6.0 + seed * 3.0);
		a = (1.0 - smoothstep(0.45 * edge, edge, r)) * (0.85 + 0.15 * n);
		tint = mix(vec3(0.26, 0.2, 0.15), vec3(0.1, 0.085, 0.075), 1.0 - smoothstep(0.1, 0.7, r / edge));
	}
	a *= 1.0 - smoothstep(0.6, 1.0, abs(b.y) * 2.0);    // (what stands in the box, off the ground: less and less)
	// in the haze the ground goes to the haze's colour: the mark goes with it
	if (tn_haze_range.w > 0.5 && tn_haze_range.w < 1.5) {
		vec2 dd = abs(wp.xz - CAMERA_POSITION_WORLD.xz);
		float l = clamp(16.0 * (1.0 - exp(-max(max(dd.x, dd.y) - 20.0, 0.0) / tn_haze_range.x)) - 0.5, 0.0, 15.0);
		a *= 1.0 - clamp((tn_haze_range.y + tn_haze_range.z * l) * l / 0.7, 0.0, 1.0);
	}
	ALBEDO = mix(vec3(1.0), tint, clamp(a * left, 0.0, 1.0));
}
