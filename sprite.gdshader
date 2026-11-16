// A sprite of the map (plants, rocks, probes): upright, turned to face the camera about the vertical (the
// StandardMaterial3D it replaces: billboard fixed Y, its scale kept, alpha cut at 0.5, unshaded), lit by the ground's
// light at its foot (viewer.gd _foot_light: albedo, or the instance colour of the vegetation's MultiMesh) and hazed
// as the game does (tn_haze.gdshaderinc).
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

#include "res://tn_haze.gdshaderinc"

uniform sampler2D tex : source_color, filter_linear_mipmap, repeat_enable;
uniform vec4 albedo : source_color = vec4(1.0);
uniform bool use_vcol = false;          // the instance colour (MultiMesh) as the light

void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
			vec4(normalize(cross(vec3(0.0, 1.0, 0.0), MAIN_CAM_INV_VIEW_MATRIX[2].xyz)), 0.0),
			vec4(0.0, 1.0, 0.0, 0.0),
			vec4(normalize(cross(MAIN_CAM_INV_VIEW_MATRIX[0].xyz, vec3(0.0, 1.0, 0.0))), 0.0),
			MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	vec4 c = texture(tex, UV) * albedo;
	if (use_vcol) {
		c *= COLOR;
	}
	ALBEDO = tn_haze(c.rgb, (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.5;
}
