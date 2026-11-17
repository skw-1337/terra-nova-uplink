// The haze, as the game draws it (live mode). The game hazes each ring of ground around the eye's cell (0x2B580A:
// a square, the horizontal distance d = max(|dx|, |dz|)) with level L(d) = min(15, 16 (1 - exp(-(d - 20) / k))) of
// the sky's haze table (SKY 150, built by 0x2B4E8C), whose rows swap each palette colour for a hazier one: on the
// ground's colours a mix towards the sky's haze colour in the palette's own values (sRGB), the same share per level
// on the skies (measured on the running game: 0.11 at level 4, 0.27 at 8, 0.49 at 12, 0.70 at 15, never all haze).
// Godot's fog mixes in linear light, where the same share lifts a dark colour far more (the temperate planet's dark
// greens went grey 60 units away, where the game hardly hazes them; the bright ice hardly changed), and before the
// view's saturation and contrast: these shaders haze themselves with this instead (render_mode fog_disabled); the
// models keep Godot's fog.
// tn_haze_range: x the haze radius k, y, z the share per level: (y + z L) L, w the mode: 0 none, 1 the game's
// (above), 2 the map viewer's (Godot's exponential fog, density x, mixed in linear light like Godot's own)
// tn_haze_color: rgb the haze colour (sRGB) taken back through the view's contrast and saturation (they bring it to
// the sky's), a the view's brightness (viewer.gd _haze_globals)
// Cameras that leave out the layer bit 16 (NO_HAZE_LAYER: the co-op maps high above the ground) see no haze.
global uniform vec4 tn_haze_color;
global uniform vec4 tn_haze_range;
// tn_view_bcs: the view's brightness, contrast and saturation (Godot applies the brightness in linear light, then the
// contrast and the saturation in sRGB), w 1 when they are on (live)
global uniform vec4 tn_view_bcs;
// tn_ir: 1 while the game's infrared view is on (live): the ground, the plants and the models drawn through the
// planet's IR remap tables (RESPLNT 59-62, colours of RESPLNT 66), unlit, as the game draws them in it
global uniform float tn_ir;

vec3 tn_haze_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThan(c, vec3(0.0031308)));
}

vec3 tn_haze_linear(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
}

// A colour the game draws (its palette's values, sRGB 0-1): the linear colour that shows it on the screen once the
// view's adjustments are applied (they are the models' look; the ground and its sprites are drawn in the game's own
// colours)
vec3 tn_game_colour(vec3 srgb) {
	if (tn_view_bcs.w < 0.5) {
		return tn_haze_linear(srgb);
	}
	vec3 v = srgb;
	float m = (v.x + v.y + v.z) / 3.0;
	v = vec3(m) + (v - vec3(m)) / max(tn_view_bcs.z, 0.01);
	v = vec3(0.5) + (v - vec3(0.5)) / max(tn_view_bcs.y, 0.01);
	return tn_haze_linear(v) / max(tn_view_bcs.x, 0.01);
}

// The other way: what the screen shows (sRGB) for a linear colour drawn in this view (e.g. read back from the screen
// texture, which holds the picture before the view's adjustments)
vec3 tn_view_srgb(vec3 lin) {
	if (tn_view_bcs.w < 0.5) {
		return tn_haze_srgb(lin);
	}
	vec3 v = tn_haze_srgb(lin * tn_view_bcs.x);
	v = mix(vec3(0.5), v, tn_view_bcs.y);
	return mix(vec3((v.x + v.y + v.z) / 3.0), v, tn_view_bcs.z);
}

// col: the colour in linear light, wpos: the point's world position, cam: the camera's, layers: CAMERA_VISIBLE_LAYERS
vec3 tn_haze(vec3 col, vec3 wpos, vec3 cam, uint layers) {
	if (tn_haze_range.w < 0.5 || (layers & (1u << 16u)) == 0u) {
		return col;
	}
	if (tn_haze_range.w < 1.5) {
		vec2 dd = abs(wpos.xz - cam.xz);
		// the level, continuous: the game's step value in the middle of each ring band
		float l = clamp(16.0 * (1.0 - exp(-max(max(dd.x, dd.y) - 20.0, 0.0) / tn_haze_range.x)) - 0.5, 0.0, 15.0);
		float a = (tn_haze_range.y + tn_haze_range.z * l) * l;
		float b = tn_haze_color.a;
		return tn_haze_linear(mix(tn_haze_srgb(col * b), tn_haze_color.rgb, a)) / b;
	}
	float e = 1.0 - exp(-length(wpos - cam) * tn_haze_range.x);
	return mix(col, tn_haze_linear(tn_haze_color.rgb), e);
}

// The light of the shots (an extra, off unless TN_FX_LIGHTS=1: fx_lights.gd), for what is drawn unlit (the suits,
// the models, the plants): up to four lights, tn_shot_p*: xyz the place, w the range; tn_shot_c*: rgb the colour x
// its strength, c0's alpha how many are on (0: none, nothing computed). What it adds to a surface's own colour at wpos.
global uniform vec4 tn_shot_p0;
global uniform vec4 tn_shot_p1;
global uniform vec4 tn_shot_p2;
global uniform vec4 tn_shot_p3;
global uniform vec4 tn_shot_c0;
global uniform vec4 tn_shot_c1;
global uniform vec4 tn_shot_c2;
global uniform vec4 tn_shot_c3;

vec3 tn_shot_one(vec4 p, vec4 c, vec3 wpos) {
	vec3 d = p.xyz - wpos;
	float r2 = dot(d, d) / max(p.w * p.w, 1e-6);
	if (r2 >= 1.0) {
		return vec3(0.0);
	}
	float f = 1.0 - r2;
	return c.rgb * f * f / (1.0 + 6.0 * r2);
}

vec3 tn_shot_light(vec3 wpos) {
	if (tn_shot_c0.a < 0.5 || tn_ir > 0.5) {
		return vec3(0.0);
	}
	vec3 l = tn_shot_one(tn_shot_p0, tn_shot_c0, wpos);
	if (tn_shot_c0.a > 1.5) {
		l += tn_shot_one(tn_shot_p1, tn_shot_c1, wpos);
	}
	if (tn_shot_c0.a > 2.5) {
		l += tn_shot_one(tn_shot_p2, tn_shot_c2, wpos) + tn_shot_one(tn_shot_p3, tn_shot_c3, wpos);
	}
	return l;
}
