// Power suit limb, drawn like the game: the view of the limb picked from the camera's bearing around the bone,
// laid flat on the screen at a fixed scale, hung from its first joint and turned so that its bone (the sprite's
// two joints, one under the other) follows the bone's direction on the screen.
// Node basis: Y = joint a -> joint b (its length = world units per sprite pixel), X = the limb's front.
// Mesh: quad in sprite pixels, x across, y down the sprite (joint a at y = 0).
shader_type spatial;
render_mode unshaded, cull_disabled;

uniform sampler2DArray views : source_color, filter_linear_mipmap, repeat_disable;
uniform int view_count = 16;      // 16 views all around, or 9 from back to front (torso)
uniform float widen = 1.0;        // sprite width factor
uniform float squash = 1.0;       // sprite height factor
uniform float pixel_aspect = 1.2; // the game's pixels on the screen: 320 x 400 (848 x 400 wide) shown 4:3 / 16:9
uniform float shade = 1.0;        // live mode: the game draws its suits much darker than the raw sprites
uniform float pull = 0.25;        // drawn this much nearer the camera: the game paints its suits over the ground,
                                  // a foot reaching just under it is not cut off (a standing suit: its feet and
                                  // shins only, viewer.gd LIMB_PULL; the pieces of a burst suit lying around: all)

instance uniform float spin = -1.0;  // >= 0: a fixed angle on the screen (radians; a piece of a burst suit lying
                                     // on the ground, drawn turned like the game's) instead of following the bone

varying flat int layer;
varying flat float flip;

void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 axis = MODEL_MATRIX[1].xyz;
	float s = length(axis);
	vec3 ax = axis / s;
	// the view: the camera's bearing around the bone, from the limb's front. The views go from the back (0) to the
	// front (8) through the limb's right side, then back through its left; the 9-view torsos only hold the right
	// side, mirrored for the left
	vec3 front = MODEL_MATRIX[0].xyz;
	front = front - ax * dot(front, ax);
	front = length(front) < 1e-5 ? vec3(1.0, 0.0, 0.0) : normalize(front);
	vec3 side = cross(ax, front);
	vec3 to_cam = CAMERA_POSITION_WORLD - origin;
	vec3 c = to_cam - ax * dot(to_cam, ax);
	float ang = atan(dot(c, side), dot(c, front));      // > 0 = camera on the limb's right
	flip = 1.0;
	if (view_count >= 16) {
		layer = int(mod(round(8.0 - ang / (TAU / 16.0)), 16.0));
	} else {
		layer = clamp(int(round(8.0 - abs(ang) / (PI / 8.0))), 0, view_count - 1);
		flip = ang < 0.0 ? -1.0 : 1.0;
	}
	// on the screen: the sprite's bone (straight down in the sprite) along the bone's projection; a bone pointing
	// at the camera has no direction on the screen, its sprite then stands upright. The game does this in its own
	// picture, whose pixels are shown 1.2 x taller than wide: the sprite turns there, then stretches with it (its
	// suits are 1.2 x taller than their joints, their feet reach lower)
	vec3 av = (VIEW_MATRIX * vec4(origin, 1.0)).xyz;
	vec3 bv = av + (VIEW_MATRIX * vec4(ax, 0.0)).xyz * 0.05;
	vec2 pa = av.xy / max(-av.z, 1e-4);
	vec2 pb = bv.xy / max(-bv.z, 1e-4);
	vec2 d2 = (pb - pa) * vec2(1.0, 1.0 / pixel_aspect);
	float along = length(d2) / (0.05 / max(-av.z, 1e-4));   // 1 = bone across the view, 0 = towards the camera
	vec2 down = vec2(0.0, -1.0);
	if (length(d2) > 1e-7) {
		vec2 m = mix(down, normalize(d2), smoothstep(0.08, 0.3, along));
		down = length(m) > 1e-3 ? normalize(m) : normalize(d2);
	}
	if (spin >= 0.0) {
		down = vec2(sin(spin), -cos(spin));
	}
	vec2 right = vec2(-down.y, down.x);
	vec2 off = right * (VERTEX.x * s * widen) + down * (VERTEX.y * s * squash);
	vec3 v = av + vec3(off.x, off.y * pixel_aspect, 0.0);
	float l = length(v);
	v *= max(l - pull, 0.05) / l;                        // same place on the screen, nearer
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
}

void fragment() {
	vec2 uv = UV;
	if (flip < 0.0) {
		uv.x = 1.0 - uv.x;
	}
	vec4 col = texture(views, vec3(uv, float(layer)));
	if (col.a < 0.5) {
		discard;
	}
	ALBEDO = col.rgb * shade;
}
