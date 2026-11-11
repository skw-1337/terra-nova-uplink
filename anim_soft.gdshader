// An effect animation of the game whose pictures are see-through (its smoke, the white flash of a blast): as
// anim.gdshader, blended with what is behind it.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never;

uniform sampler2DArray frames : source_color, filter_linear_mipmap, repeat_disable;
uniform int frame_count = 1;
uniform float fps = 16.0;
uniform bool loop = false;
uniform float pixel_aspect = 1.2;
uniform float pull = 0.3;              // drawn a little nearer: the game paints it over the ground
instance uniform float age = 0.0;      // seconds since it started
instance uniform float frame = -1.0;   // the frame the game shows (none: by its age)

void vertex() {
	vec3 o = (VIEW_MATRIX * vec4(MODEL_MATRIX[3].xyz, 1.0)).xyz;
	vec3 v = o + vec3(VERTEX.x, VERTEX.y * pixel_aspect, 0.0);
	float l = length(v);
	v *= max(l - pull, 0.05) / l;
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
}

void fragment() {
	float f = loop ? mod(floor(age * fps), float(frame_count)) : min(floor(age * fps), float(frame_count - 1));
	if (frame >= 0.0) {
		f = min(frame, float(frame_count - 1));
	}
	vec4 c = texture(frames, vec3(UV, f));
	ALBEDO = c.rgb;
	ALPHA = c.a;
}
