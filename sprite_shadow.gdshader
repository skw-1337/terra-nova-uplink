// A sprite's shadow (viewer.gd _sprite_shadow_mat). The sprite turns to face the camera, and its shadow turned with it:
// it swung round as the player looked around and thinned to a line when he looked across the light. The sprite casts
// none now; this twin of its quad is drawn in the shadow passes only, upright and facing the light whatever the view
// (a shadow pass's camera is the light's own): the shadow keeps the sprite's whole width.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2D tex : filter_linear_mipmap, repeat_disable;
// A low sun (the maps' light is 11 to 24 deg high on 5 of them) cast each tree's shadow 3 to 5 times its height down
// the slopes: dark parallel stripes over every wooded hill, which the game does not have (it draws no shadows). The
// twin is drawn shorter so: its shadow never longer than the sun at this height would make it (1.2 x the plant's height)
const float MIN_SUN = 0.6981317;      // 40 deg

void vertex() {
	vec3 right = cross(vec3(0.0, 1.0, 0.0), INV_VIEW_MATRIX[2].xyz);
	right = dot(right, right) < 1e-6 ? vec3(1.0, 0.0, 0.0) : normalize(right);   // (a light straight overhead)
	// (a shadow pass's camera looks along the light: its z axis points towards the light)
	float sun_el = asin(clamp(normalize(INV_VIEW_MATRIX[2].xyz).y, -1.0, 1.0));
	float shorter = sun_el > 0.01 ? clamp(tan(sun_el) / tan(MIN_SUN), 0.0, 1.0) : 1.0;
	// its size kept, as the sprite's own material does (a plant hidden by a zero scale casts nothing)
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(right * length(MODEL_MATRIX[0].xyz), 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz) * shorter, 0.0, 0.0),
			vec4(cross(right, vec3(0.0, 1.0, 0.0)) * length(MODEL_MATRIX[2].xyz), 0.0),
			MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	ALPHA = texture(tex, UV).a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
