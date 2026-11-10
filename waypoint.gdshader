// A line of the player's waypoint (viewer.gd _live_waypoint): a rod, 1 long and 1 thick as a mesh, drawn `width`
// pixels thick whatever its distance and the view that shows it (the main one, the HUD's side views), over
// everything: the game draws the waypoint's lines one pixel of its picture wide, through the hills.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled, fog_disabled, shadows_disabled;

uniform vec3 colour : source_color = vec3(0.47, 0.0, 0.72);
uniform float width = 3.0;

void vertex() {
	vec3 on_axis = vec3(0.0, VERTEX.y, 0.0);
	float depth = max(-(MODELVIEW_MATRIX * vec4(on_axis, 1.0)).z, 0.05);
	float px = 2.0 * depth / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y);   // what a pixel is worth at that depth
	VERTEX = on_axis + vec3(VERTEX.x, 0.0, VERTEX.z) * 0.5 * width * px;
}

void fragment() {
	ALBEDO = colour;
}
