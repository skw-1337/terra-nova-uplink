// A particle of a shot's trail, as the game plots it: a dot of its picture for a shot's dust, a flat see-through
// disc that grows as it comes near for its smokes (a railgun's, a shell's, a missile's). The instance's colour is
// the game's (its alpha: how much of what is behind it the game's table hides); the instance's scale is the disc's
// width in world units (0: a dot) along x and, along y, the depth beyond which the game plots it as one pixel.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, depth_draw_never;
#include "res://tn_haze.gdshaderinc"

uniform float px = 0.0019;             // a dot's half size per unit of distance (about a pixel of the game's 848 x 400)
uniform float widest = 0.0775;         // a disc's greatest half size per unit of distance (64 pixels of that picture)
// infrared: the instances' colours are then the game's IR colours (viewer.gd _live_parts), shown as they are
uniform bool ir_exact = false;
varying vec4 col;

void vertex() {
	vec3 o = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = length(o);
	float half_size = -o.z > length(MODEL_MATRIX[1].xyz) ? px * d : clamp(length(MODEL_MATRIX[0].xyz) * 0.5, px * d, widest * d);
	vec3 v = o + vec3(VERTEX.xy * 2.0 * half_size, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
	col = COLOR;
}

void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	ALBEDO = ir_exact && tn_ir > 0.5 ? tn_game_colour(tn_haze_srgb(col.rgb)) : col.rgb;
	ALPHA = col.a * (1.0 - smoothstep(0.85, 1.0, r));
}
