// Smoke puff (jetpack exhaust, laser trail): a quad facing the camera playing the game's translucent smoke
// animation (RESTNOBJ 1186) once, growing and fading out over its life.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;
#include "res://tn_haze.gdshaderinc"

uniform sampler2DArray frames : source_color, filter_linear_mipmap, repeat_disable;
uniform int frame_count = 13;
uniform float life = 1.2;
// infrared (live, tn_ir): the game's smoke is no veil there, each of its discs lifts what is behind it towards one
// warm colour (viewer.gd ir_smoke, _ir_colours): rgb that colour (sRGB), a 1 when known
uniform vec4 ir_veil = vec4(0.0);
instance uniform float age = 0.0;      // seconds since the puff appeared
instance uniform float size = 1.0;     // jetpack 1, missile trail smaller, explosion bigger
instance uniform float tint = 1.0;     // 1 = the game's grey smoke, lower = darker (a burning tree's black smoke)
instance uniform float dense = 1.0;    // opacity factor (a burning tree's smoke is thick)
instance uniform float near_fade = 0.0;   // 1: a trail's puff, which fades out as the camera comes near (no veil over the view)
varying float cam_dist;

void vertex() {
	float s = (0.35 + age * 0.9) * size;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	VERTEX *= s;
	// how near: in puff widths (a puff as wide as its distance covers half the view)
	cam_dist = length((VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz) / max(s, 0.01);
}

void fragment() {
	// frames blended into each other: the 13 frames over a second stepped like an old sprite
	float x = clamp(age / life * float(frame_count - 1), 0.0, float(frame_count - 1));
	float f = floor(x);
	vec4 c = mix(texture(frames, vec3(UV, f)), texture(frames, vec3(UV, min(f + 1.0, float(frame_count - 1)))), x - f);
	ALBEDO = c.rgb * tint;
	ALPHA = min(1.0, c.a * clamp(1.0 - age / life, 0.0, 1.0) * 0.85 * dense);
	ALPHA *= mix(1.0, smoothstep(1.0, 4.0, cam_dist), near_fade);
	if (ir_veil.a > 0.5 && tn_ir > 0.5) {
		ALBEDO = tn_game_colour(ir_veil.rgb);
		ALPHA = 1.0 - pow(1.0 - ALPHA, 0.56);       // (as many discs as the veil stands for, each 0.26 strong against 0.41)
	}
}
