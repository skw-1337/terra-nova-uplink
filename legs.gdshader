// The player's own legs and feet seen from his eyes when he looks down past the game's limit (an extra, off unless
// TN_FX_LOOK_DOWN=1: look_down.gd). The game's suits are flat pictures taken all around each limb, none from above:
// seen along the bone they have no picture to show. Here each leg piece is a round solid around its bone (as thick
// as the limb's picture), dressed in the limb's own front picture and shaded as the game shades a suit's limb (the
// rows of the planet's light table, limb.gdshader lit), per pixel of the solid.
shader_type spatial;
render_mode unshaded, cull_back, fog_disabled;

#include "res://tn_haze.gdshaderinc"

uniform sampler2DArray views : source_color, filter_linear_mipmap, repeat_disable;
uniform float front = 8.0;        // the limb's front picture
uniform bool lit = false;
uniform vec3 light_dir = vec3(0.0, 1.0, 0.0);
uniform float light_amb = 1.0;
uniform float light_dif = 0.0;
uniform vec3 light_rows[16];
instance uniform float mirror = 0.0;   // a left limb: the right one's picture, mirrored

varying vec3 wn;

void vertex() {
	wn = normalize(MODEL_NORMAL_MATRIX * NORMAL);
}

void fragment() {
	vec2 uv = UV;
	if (mirror > 0.5) {
		uv.x = 1.0 - uv.x;
	}
	vec4 c = texture(views, vec3(uv, front));
	if (c.a < 0.5) {                       // (a see-through texel at the picture's edge: the limb's middle there)
		c = texture(views, vec3(0.5, uv.y, front));
	}
	vec3 f = vec3(1.0);
	if (lit) {
		float li = min(light_amb + light_dif * max(0.0, dot(normalize(wn), light_dir)), 1.5);
		int row = clamp(int(floor(16.0 * li)), 0, 15);
		f = row >= 15 ? vec3(1.0) : light_rows[row];
	}
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	ALBEDO = tn_haze(c.rgb * f * (1.0 + tn_shot_light(wp)), wp, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
}
