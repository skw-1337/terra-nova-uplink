// A 3D model as the game shades it (live mode): one intensity per polygon from its stored normal (op 0x31 mode 1; mode
// 2: per point, here per pixel), 0x2F8C09: I = amb + dif (N.L) + dif spec max(0, 2 (N.L)(N.V) - L.V), amb alone when
// N.L < 0, spec = dif, clamped at 0x17FFF; V once per object (its origin to the eye). Row I x 16 of the light table
// (0x41C228: rows 0-15 = RESPLNT 53 read backwards, 16-23 = its row 0), through which every texel's palette index is
// swapped: faces turned from the sun get the game's darkness, in the game's own colours.
// tn_model_light: xyz towards the sun (Godot axes), w 1 = on; tn_model_shade: x ambient, y diffuse (map res 82).
shader_type spatial;
render_mode unshaded, cull_back;

#include "res://tn_haze.gdshaderinc"

global uniform vec4 tn_model_light;
global uniform vec4 tn_model_shade;

uniform sampler2D idx_tex : filter_nearest, repeat_enable;   // the texture's palette indices (R8); flat: unused
uniform bool textured = false;                                // else the index is the vertex colour's red x 255
uniform sampler2D shade_idx : filter_nearest, repeat_disable;  // RESPLNT 53: 256 x 16 palette indices
uniform sampler2D pal_tex : filter_nearest, repeat_disable;    // the planet's palette, 256 x 1
uniform sampler2D ir_lut : filter_nearest, repeat_disable;     // 256 x 4: the colours of IR tables 59-62
uniform bool has_ir = false;
uniform int ir_table = 2;                                      // its row: 61 (the models), 62 the walker's parts (drawn
                                                               // by the soldier draw, 0x29C96E: viewer.gd _add_mech)

varying vec3 wn;

void vertex() {
	wn = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	int idx;
	if (textured) {
		ivec2 sz = textureSize(idx_tex, 0);
		vec2 uv = fract(UV);
		idx = int(texelFetch(idx_tex, clamp(ivec2(floor(uv * vec2(sz))), ivec2(0), sz - 1), 0).r * 255.0 + 0.5);
	} else {
		idx = int(COLOR.r * 255.0 + 0.5);
	}
	if (has_ir && tn_ir > 0.5) {         // infrared: unlit (0x29E4F4), through its table
		ALBEDO = tn_game_colour(texelFetch(ir_lut, ivec2(idx, ir_table), 0).rgb);
	} else {
	vec3 n = normalize(wn);
	vec3 l = normalize(tn_model_light.xyz);
	vec3 v = normalize(CAMERA_POSITION_WORLD - NODE_POSITION_WORLD);
	float dif = tn_model_shade.y;
	float amb = min(tn_model_shade.x, 1.0 - dif);
	float nl = dot(n, l);
	float i = amb;
	if (nl >= 0.0) {
		i += dif * nl + dif * dif * max(0.0, 2.0 * nl * dot(n, v) - dot(l, v));
	}
	i = min(i, float(0x17FFF) / 65536.0);
	int row = clamp(int(floor(i * 16.0)), 0, 23);
	int frow = max(0, 15 - row);
	int j = int(texelFetch(shade_idx, ivec2(idx, frow), 0).r * 255.0 + 0.5);
	ALBEDO = tn_game_colour(texelFetch(pal_tex, ivec2(j, 0), 0).rgb) * (1.0 + tn_shot_light((INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz));
	}
}
