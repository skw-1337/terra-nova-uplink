// A laser beam like the game draws it: a flat ribbon facing the camera, a bright core a third of its width between
// two dark bands (the game's palette: 252,0,0 inside 96,2,2 for the red laser). UV.y runs across the ribbon.
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled;

uniform vec3 core : source_color = vec3(0.988, 0.0, 0.0);
uniform vec3 edge : source_color = vec3(0.376, 0.008, 0.008);
uniform float core_frac = 0.36;     // share of the width taken by the bright core
uniform float core_frac_x = 2.0;    // and of the length (bars with an outline all round: below 1)

void fragment() {
	float d = abs(UV.y - 0.5) * 2.0;
	float dx = abs(UV.x - 0.5) * 2.0;
	ALBEDO = d < core_frac && dx < core_frac_x ? core : edge;
}
