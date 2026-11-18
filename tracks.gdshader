// Footprints and vehicle tracks (an extra, on unless TN_FX_TRACKS=0: fx_tracks.gd). Each mark is a flat box laid on
// the ground; whatever the view shows inside it (the ground, read back from the depth of the picture) is darkened by
// the mark's shape (a layer of the "shapes" atlas: the unit's sole or contact seen from below), its edge a little
// lighter where the ground was pushed up around the print. INSTANCE_CUSTOM: x the atlas layer, y when it was made
// (s), z a number of its own, w its strength (the ground's: clear on snow and sand, faint on rock).
shader_type spatial;
render_mode unshaded, blend_mul, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://tn_haze.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2DArray shapes : filter_linear, repeat_disable;
uniform float now = 0.0;
uniform float hold = 40.0;
uniform float fade = 20.0;

varying flat vec4 mark;
varying flat mat4 to_box;

void vertex() {
	mark = INSTANCE_CUSTOM;
	to_box = inverse(MODEL_MATRIX);
}

void fragment() {
	float age = now - mark.y;
	float left = mark.w * (1.0 - smoothstep(hold, hold + fade, age));
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 wp = (INV_VIEW_MATRIX * vec4(vp.xyz / vp.w, 1.0)).xyz;
	vec3 b = (to_box * vec4(wp, 1.0)).xyz;             // in the box: -0.5 .. 0.5
	if (left <= 0.003 || tn_ir > 0.5 || abs(b.x) > 0.5 || abs(b.y) > 0.5 || abs(b.z) > 0.5) {
		discard;
	}
	vec2 uv = vec2(b.x + 0.5, b.z + 0.5);
	float layer = mark.x;
	float a = texture(shapes, vec3(uv, layer)).r;
	// the rim: a little outside the shape, the pushed-up ground (lighter)
	float d = 1.5 / 64.0;
	float around = max(max(texture(shapes, vec3(uv + vec2(d, 0.0), layer)).r, texture(shapes, vec3(uv - vec2(d, 0.0), layer)).r),
			max(texture(shapes, vec3(uv + vec2(0.0, d), layer)).r, texture(shapes, vec3(uv - vec2(0.0, d), layer)).r));
	float rim = clamp(around - a, 0.0, 1.0);
	a *= 1.0 - smoothstep(0.6, 1.0, abs(b.y) * 2.0);  // (what stands in the box, off the ground: less and less)
	if (tn_haze_range.w > 0.5 && tn_haze_range.w < 1.5) {
		vec2 dd = abs(wp.xz - CAMERA_POSITION_WORLD.xz);
		float l = clamp(16.0 * (1.0 - exp(-max(max(dd.x, dd.y) - 20.0, 0.0) / tn_haze_range.x)) - 0.5, 0.0, 15.0);
		a *= 1.0 - clamp((tn_haze_range.y + tn_haze_range.z * l) * l / 0.7, 0.0, 1.0);
		rim *= 1.0 - clamp((tn_haze_range.y + tn_haze_range.z * l) * l / 0.7, 0.0, 1.0);
	}
	// pressed in: the ground inside darker (a shade of its own colour, multiplied), its rim slightly lighter
	vec3 col = mix(vec3(1.0), vec3(0.42, 0.44, 0.5), clamp(a * left, 0.0, 1.0));
	col *= 1.0 + 0.18 * rim * left;
	ALBEDO = col;
}
