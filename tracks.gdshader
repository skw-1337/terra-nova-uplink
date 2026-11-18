// Footprints and vehicle tracks (an extra, on unless TN_FX_TRACKS=0: fx_tracks.gd). Each mark is a flat box laid on
// the ground; whatever the view shows inside it (the ground, read back from the depth of the picture) is darkened by
// the mark's shape (a layer of the "shapes" atlas: the unit's sole seen from below), its edge a little lighter where
// the ground was pushed up around the print. INSTANCE_CUSTOM: x the atlas layer, y when it was made (s), z a number
// of its own, w its strength (the ground's: clear on snow and sand, faint on rock).
// A stretch of a vehicle's ruts is one long box (COLOR.a > 0: the length of its tread on the ground): the layer holds
// the ruts across and one length of their tread along, repeated all the way (INSTANCE_CUSTOM.z: how far into a
// length the stretch begins); the box is half its width longer at each end and the ruts are cut there on a slanted
// line (COLOR.g its start, COLOR.b its end: the bisector of the bend to the next stretch, so two stretches meet with
// no gap and nothing twice); its start is COLOR.r seconds older than its end (INSTANCE_CUSTOM.y).
shader_type spatial;
render_mode unshaded, blend_mul, cull_front, depth_test_disabled, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://tn_haze.gdshaderinc"

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest, repeat_disable;
uniform sampler2DArray shapes : filter_linear, repeat_disable;
uniform sampler2DArray shapes_rep : filter_linear_mipmap_anisotropic, repeat_enable;   // (the same atlas)
uniform float now = 0.0;
uniform float hold = 40.0;
uniform float fade = 20.0;

varying flat vec4 mark;
varying flat vec4 run;
varying flat vec4 lie;                             // a stretch on the map: its direction (xy), half its length, its width
varying flat vec2 middle;
varying flat mat4 to_box;

void vertex() {
	mark = INSTANCE_CUSTOM;
	run = COLOR;
	vec3 ax = MODEL_MATRIX[0].xyz;
	float wide = length(MODEL_MATRIX[2].xyz);
	// (the ruts are placed as seen from above, whatever the tilt of the box: two stretches tilted differently on
	// a crease of the ground still meet)
	lie = vec4(normalize(ax.xz), (length(ax) - wide) * 0.5 * length(ax.xz) / length(ax), wide);
	middle = MODEL_MATRIX[3].xz;
	to_box = inverse(MODEL_MATRIX);
}

void fragment() {
	float depth = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth, 1.0);
	vec3 wp = (INV_VIEW_MATRIX * vec4(vp.xyz / vp.w, 1.0)).xyz;
	vec3 b = (to_box * vec4(wp, 1.0)).xyz;             // in the box: -0.5 .. 0.5
	if (tn_ir > 0.5 || abs(b.x) > 0.5 || abs(b.y) > 0.5 || abs(b.z) > 0.5) {
		discard;
	}
	float age = now - mark.y;
	float layer = mark.x;
	float d = 1.5 / 64.0;
	float a;
	float around;
	if (run.a > 0.0) {                                 // a stretch of ruts
		float half_run = lie.z;
		float px = dot(wp.xz - middle, lie.xy);
		float pz = dot(wp.xz - middle, vec2(-lie.y, lie.x));
		if (px < pz * run.g - half_run || px > pz * run.b + half_run) {
			discard;
		}
		float along = px + half_run;
		age += run.r * (1.0 - clamp(along / max(2.0 * half_run, 0.001), 0.0, 1.0));
		vec3 at = vec3((along + mark.z) / run.a, pz / lie.w + 0.5, layer);
		a = texture(shapes_rep, at).r;
		around = max(texture(shapes_rep, at + vec3(0.0, d, 0.0)).r, texture(shapes_rep, at - vec3(0.0, d, 0.0)).r);
	} else {
		vec2 uv = vec2(b.x + 0.5, b.z + 0.5);
		a = texture(shapes, vec3(uv, layer)).r;
		around = max(max(texture(shapes, vec3(uv + vec2(d, 0.0), layer)).r, texture(shapes, vec3(uv - vec2(d, 0.0), layer)).r),
				max(texture(shapes, vec3(uv + vec2(0.0, d), layer)).r, texture(shapes, vec3(uv - vec2(0.0, d), layer)).r));
	}
	float left = mark.w * (1.0 - smoothstep(hold, hold + fade, age));
	if (left <= 0.003) {
		discard;
	}
	// the rim: a little outside the shape, the pushed-up ground (lighter)
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
