// An effect animation of the game (explosion, fire) played once: a sprite standing upright on the screen like the
// game's (its pixels shown 1.2 x taller than wide, see limb.gdshader), anchored on the effect's position.
// Mesh: quad in world units, anchor at the origin.
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2DArray frames : source_color, filter_linear_mipmap, repeat_disable;
uniform int frame_count = 1;
uniform float fps = 16.0;
uniform float pixel_aspect = 1.2;
uniform float pull = 0.3;              // drawn a little nearer: the game paints it over the ground
instance uniform float age = 0.0;      // seconds since it started

void vertex() {
	vec3 o = (VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz;
	vec3 v = o + vec3(VERTEX.x, VERTEX.y * pixel_aspect, 0.0);
	float l = length(v);
	v *= max(l - pull, 0.05) / l;
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
}

void fragment() {
	float f = min(floor(age * fps), float(frame_count - 1));
	vec4 c = texture(frames, vec3(UV, f));
	if (c.a < 0.5) {
		discard;
	}
	ALBEDO = c.rgb;
}
