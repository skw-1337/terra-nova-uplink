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

vec3 tn_haze_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, lessThan(c, vec3(0.0031308)));
}

vec3 tn_haze_linear(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, lessThan(c, vec3(0.04045)));
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
