// A particle of a thermal disruptor's haze: the game draws it as a disc that shifts what is behind it (the ground
// seen through it is warped), bigger as it comes near. Here: a disc facing the camera that shows the picture behind
// it shifted by a ripple. The instance's scale is the disc's width in world units.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, depth_draw_never;

uniform sampler2D screen_tex : hint_screen_texture, repeat_disable, filter_linear;
uniform float shift = 0.03;            // how far the picture is shifted, in screen heights (the game: a strong lens)
uniform float widest = 0.0775;         // the disc's greatest half size per unit of distance (64 pixels of the game's picture)
varying float seed;

void vertex() {
	vec3 o = (MODELVIEW_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float d = length(o);
	float half_size = min(length(MODEL_MATRIX[0].xyz) * 0.5, widest * d);
	vec3 v = o + vec3(VERTEX.xy * 2.0 * half_size, 0.0);
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
	seed = fract(MODEL_MATRIX[3].x * 7.31 + MODEL_MATRIX[3].z * 3.17);
}

void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	float k = 1.0 - smoothstep(0.7, 1.0, r);
	vec2 wave = vec2(sin(UV.y * 9.0 + seed * 40.0 + TIME * 19.0), cos(UV.x * 7.0 + seed * 31.0 + TIME * 23.0));
	ALBEDO = texture(screen_tex, SCREEN_UV + wave * shift * k).rgb;
	ALPHA = k > 0.01 ? 1.0 : 0.0;
}
