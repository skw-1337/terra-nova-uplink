// An effect animation of the game whose pictures are see-through (its smoke, the white flash of a blast): as
// anim.gdshader, blended with what is behind it.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, fog_disabled;

#include "res://tn_haze.gdshaderinc"

uniform sampler2DArray frames : source_color, filter_linear_mipmap, repeat_disable;
uniform int frame_count = 1;
uniform float fps = 16.0;
uniform bool loop = false;
uniform float pixel_aspect = 1.2;
// the game's infrared view (live, tn_ir): the same frames through the planet's IR table 60, or 62 for a "hot" effect
// (flag 0x40 of its record, set where it is born: the sprite draw 0x29BE78 swaps the view's remap for it), unlit
uniform sampler2DArray frames_ir : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2DArray frames_hot : source_color, filter_linear_mipmap, repeat_disable;
uniform bool has_ir = false;
uniform float pull = 0.3;              // drawn a little nearer: the game paints it over the ground
// a blast next to the camera fills the view, in the game too (a fireball 0.8 unit away: a third of its width), where
// each of its texels shows as a block; smoothed between texels as it is far away, it was a flat blur. Up close each
// texel keeps its colour, blended into the next over this share of a texel only (1: the plain smooth filter)
uniform float texel_soft = 0.35;
instance uniform float age = 0.0;      // seconds since it started
instance uniform float frame = -1.0;   // the frame the game shows (none: by its age)
instance uniform float hot = 0.0;      // 1: a hot effect (infrared)

void vertex() {
	vec3 o = (VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz;
	vec3 v = o + vec3(VERTEX.x, VERTEX.y * pixel_aspect, 0.0);
	// the whole picture nearer along the eye's ray by one factor: its place and size on the screen unchanged, flat, and
	// never against the near plane (each corner pulled by itself, a blast at the camera was bent round the eye and the
	// near plane cut pieces out of it)
	float lo = max(length(o), 0.001);
	v *= max((lo - pull) / lo, 0.07 / max(-o.z, 0.001));
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
}

// where to read the frame's texel at uv: the smooth filter far away, the game's own texels up close (texel_soft); dx, dy: uv's
// change from one pixel of the screen to the next
vec2 frame_texel(vec2 uv, vec2 dx, vec2 dy) {
	vec2 ts = vec2(textureSize(frames, 0).xy);
	vec2 p = uv * ts - 0.5;
	vec2 i = floor(p);
	vec2 w = max(vec2(texel_soft), (abs(dx) + abs(dy)) * ts);
	vec2 fr = clamp((p - i - 0.5) / w + 0.5, 0.0, 1.0);
	return (i + 0.5 + fr) / ts;
}

void fragment() {
	float f = loop ? mod(floor(age * fps), float(frame_count)) : min(floor(age * fps), float(frame_count - 1));
	if (frame >= 0.0) {
		f = min(frame, float(frame_count - 1));
	}
	vec2 dx = dFdx(UV);
	vec2 dy = dFdy(UV);
	vec3 at = vec3(frame_texel(UV, dx, dy), f);
	vec4 c = textureGrad(frames, at, dx, dy);
	if (has_ir && tn_ir > 0.5) {
		vec4 ci = hot > 0.5 ? textureGrad(frames_hot, at, dx, dy) : textureGrad(frames_ir, at, dx, dy);
		ALBEDO = tn_game_colour(tn_haze_srgb(ci.rgb));
		ALPHA = ci.a;
	} else {
	// in the game's own colours (live: the view's saturation and contrast are the models' look, they made a blast
	// a brighter orange than the game's)
	ALBEDO = tn_haze(tn_game_colour(tn_haze_srgb(c.rgb)), (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
	ALPHA = c.a;
	}
}
