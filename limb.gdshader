// Power suit limb, drawn like the game: the view of the limb picked from the camera's bearing around the bone,
// laid flat on the screen at a fixed scale, hung from its first joint and turned so that its bone (the sprite's
// two joints, one under the other) follows the bone's direction on the screen.
// Node basis: Y = joint a -> joint b (its length = world units per sprite pixel along the bone), X = the limb's front
// (its length = world units per sprite pixel across the bone: the game's 1/256, whatever the bone's length).
// Mesh: quad in sprite pixels, x across, y down the sprite (joint a at y = 0).
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled;

#include "res://tn_haze.gdshaderinc"

uniform sampler2DArray views : source_color, filter_linear_mipmap, repeat_disable;
uniform int view_count = 16;      // 16 views all around, or 9 from back to front (torso)
// the game's infrared view (live, tn_ir): the same views through the planet's IR table 62, unlit, no haze (the soldier
// draw 0x29C96E and the burst suit's 0x29CB08 swap the view's remap for it around the whole suit)
uniform sampler2DArray views_ir : source_color, filter_linear_mipmap, repeat_disable;
uniform bool has_ir = false;
uniform float widen = 1.0;        // sprite width factor
uniform float squash = 1.0;       // sprite height factor
uniform float pixel_aspect = 1.2; // the game's pixels on the screen: 320 x 400 (848 x 400 wide) shown 4:3 / 16:9
uniform float shade = 1.0;        // a flat factor (the pieces of a burst suit; the standing suits are lit, below)
// the game's light on a standing suit (0x29E564 then the limb drawer 0x2F6C50): each limb gets one shade from its
// normal = from the bone towards the camera, I = amb + dif * max(0, N.L) (capped at 1.5), then row floor(16 I) of the
// planet's shade table (viewer.gd _limb_light: the row's colour gains, rows >= 15 as they are)
uniform bool lit = false;
uniform vec3 light_dir = vec3(0.0, 1.0, 0.0);   // towards the light (the map's, without the sky's azimuth offset)
uniform float light_amb = 1.0;                  // (map ambient + 1) / 2
uniform float light_dif = 0.0;                  // map diffuse
uniform vec3 light_rows[16];
uniform float pull = 0.25;        // drawn this much nearer the camera: the game paints its suits over the ground,
                                  // a foot reaching just under it is not cut off (a standing suit: its feet and
                                  // shins only, viewer.gd LIMB_PULL; the pieces of a burst suit lying around: all)

instance uniform float deep = 0.0;   // 1: on the map's darkest light level (viewer.gd _apply_deep): the game lights the suit
                                     // with the map's own ambient, not (amb + 1) / 2, and half the diffuse (0x29C9B3 -> 0x29E544)
instance uniform float spin = -1.0;  // >= 0: a fixed angle on the screen (radians; a piece of a burst suit lying
                                     // on the ground, drawn turned like the game's) instead of following the bone
// live: the view the game picks for this limb (viewer.gd _game_views: x the view, y -1 when drawn mirrored), x < 0: none
instance uniform vec2 game_view = vec2(-1.0, 1.0);
instance uniform float mirror = 0.0; // 1: segment flag bit 0, a left limb drawn from the right one's sprites: the game
                                     // takes the view (16 - v) & 15 and mirrors it (no change on the 9-view torsos)
instance uniform float foot = 0.0;      // 1: a foot (lifted onto the ground where it reaches under it, see vertex)
instance uniform float bone_px = 0.0;   // > 0: the sprite pixels between its two joints (a standing suit): its depth
                                     // is the middle of its bone, not its first joint (see vertex)
// a standing suit seen from high above (viewer.gd _steep_suits: w > 0, xyz the middle of the suit): the game never
// looks at its suits from more than about 60 degrees up (its head stops 45 down) and its pictures hold no view from
// above: from straight over them their bones point at the eye, each limb a stub laid out from the middle of the
// screen, the suit drawn lying down. Past STEEP.x the suit is laid out as seen from an eye that rises no higher than
// STEEP.y, at the same distance and bearing, then put where it is on the screen, its up along its own up there
instance uniform vec4 pivot = vec4(0.0);
const vec2 STEEP = vec2(0.87, 1.05);      // radians: from 50 degrees up, at most 60

varying flat int layer;
varying flat float flip;
varying flat vec3 factor;

// a limb laid out on the screen of the view VM (its view space: x right, y up, -z ahead), the sprite's corner vtx
vec3 lay(mat4 VM, vec3 origin, vec3 ax, float s, float wx, vec2 vtx) {
	// on the screen: the sprite's bone (straight down in the sprite) along the bone's projection; a bone pointing
	// at the camera has no direction on the screen, its sprite then stands upright. The game does this in its own
	// picture, whose pixels are shown 1.2 x taller than wide: the sprite turns there, then stretches with it (its
	// suits are 1.2 x taller than their joints, their feet reach lower)
	vec3 av = (VM * vec4(origin, 1.0)).xyz;
	vec3 axv = (VM * vec4(ax, 0.0)).xyz;
	vec3 bv = av + axv * 0.05;
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
	vec3 v;
	if (spin >= 0.0) {                                   // a burst suit's piece: as before (its routine not checked)
		vec2 off = right * (vtx.x * s * widen) + down * (vtx.y * s * squash);
		v = av + vec3(off.x, off.y * pixel_aspect, 0.0);
	} else if (bone_px > 0.0 && -(av.z + axv.z * (s * bone_px)) > 0.02 && -av.z > 0.02) {
		// a standing suit's limb, as the game's limb drawer lays it (0x2F6C50, from 0x2F6EFF): its two joints are
		// projected on the screen and the sprite is stretched between them, its row 0 on the first joint, its row
		// 'bone length' on the second, the rows before and after carried on in proportion (sprite header +0x14,
		// +0x18): a bone leaning towards the camera is drawn that much shorter, a foot pointing at it is a stub (drawn at
		// its full length down the screen, feet, shins and forearms reached past their next joint and crossed each
		// other). Across the bone the width is the same in every direction (0x2F6FC3: (dy k, -dx k / 1.2) in its
		// picture, shown 1.2 x taller), set by the depth alone
		vec3 bf = av + axv * (s * bone_px);
		vec2 pbf = bf.xy / -bf.z;
		vec2 dd = pbf - pa;
		vec2 dn = dd * vec2(1.0, 1.0 / pixel_aspect);
		vec2 rt = length(dn) > 1e-7 ? vec2(-dn.y, dn.x) / length(dn) : vec2(1.0, 0.0);
		vec2 on = (pa + dd * (vtx.y * squash / bone_px)) * -av.z;
		v = vec3(on + rt * (vtx.x * wx * widen), av.z);
	} else {
		// (no bone length given, or a joint behind the eye: the sprite at its full length along the bone's direction)
		vec2 along_v = down * (vtx.y * s * squash);
		vec2 across = right * (vtx.x * wx * widen);
		v = av + vec3(along_v.x, along_v.y * pixel_aspect, 0.0) + vec3(across, 0.0);
	}
	// which limb covers which: the game sorts a suit's limbs by the sum of their two joints' depths (0x315E60, an
	// insertion sort, far to near) and paints them in that order, each whole over the ones before. The same here: each
	// limb flat at the depth of the middle of its bone (all at their first joint's depth, the hip, the knee and the neck
	// stood a few thousandths of a unit apart in the wrong order), same place on the screen
	if (spin < 0.0 && bone_px > 0.0) {
		float mz = av.z + axv.z * (0.5 * bone_px * s);
		if (mz < -0.02 && av.z < -0.02) {
			v *= mz / av.z;
		}
	}
	return v;
}


void vertex() {
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec3 axis = MODEL_MATRIX[1].xyz;
	float s = length(axis);
	vec3 ax = axis / s;
	float wx = length(MODEL_MATRIX[0].xyz);
	// seen from high above (pivot): a lower eye (cv, its view VM), the share of its layout taken (w_steep: from none
	// at STEEP.x to all a little higher, the same layout at the start)
	mat4 VM = VIEW_MATRIX;
	vec3 eye = CAMERA_POSITION_WORLD;
	float w_steep = 0.0;
	vec3 pv_real = vec3(0.0);
	vec3 pv_virt = vec3(0.0);
	vec2 up2 = vec2(0.0, 1.0);
	float to_real = 1.0;
	if (pivot.w > 0.5 && spin < 0.0 && bone_px > 0.0) {
		vec3 e = eye - pivot.xyz;
		float d = length(e);
		float el = asin(clamp(e.y / max(d, 1e-5), -1.0, 1.0));
		pv_real = (VIEW_MATRIX * vec4(pivot.xyz, 1.0)).xyz;
		if (el > STEEP.x && d > 0.05 && pv_real.z < -0.02) {
			float elv = STEEP.x + (STEEP.y - STEEP.x) * tanh((el - STEEP.x) / (STEEP.y - STEEP.x));
			vec3 fw = -INV_VIEW_MATRIX[2].xyz;
			vec2 fh = length(fw.xz) > 1e-4 ? normalize(fw.xz) : vec2(0.0, -1.0);
			vec2 hd = normalize(e.xz - fh * 0.05 * d);     // (straight over it: from behind, as the eye looks)
			vec3 cv = pivot.xyz + vec3(hd.x * cos(elv), sin(elv), hd.y * cos(elv)) * d;
			vec3 f = normalize(pivot.xyz - cv);
			vec3 r = normalize(cross(f, vec3(0.0, 1.0, 0.0)));
			vec3 u = cross(r, f);
			VM = mat4(vec4(r.x, u.x, -f.x, 0.0), vec4(r.y, u.y, -f.y, 0.0), vec4(r.z, u.z, -f.z, 0.0),
					vec4(-dot(r, cv), -dot(u, cv), dot(f, cv), 1.0));
			pv_virt = (VM * vec4(pivot.xyz, 1.0)).xyz;
			// the suit's up on the real screen at its middle; near the point straight under the eye (where it has no
			// direction) the eye's way forward instead
			vec3 q = (VIEW_MATRIX * vec4(pivot.xyz + vec3(0.0, 0.05, 0.0), 1.0)).xyz;
			vec3 q2 = (VIEW_MATRIX * vec4(pivot.xyz + vec3(fh.x, 0.0, fh.y) * 0.05, 1.0)).xyz;
			vec2 p0 = pv_real.xy / -pv_real.z;
			vec2 du = q.xy / max(-q.z, 1e-4) - p0;
			vec2 df = q2.xy / max(-q2.z, 1e-4) - p0;
			float k_up = smoothstep(0.05, 0.25, length(du) / (0.05 / -pv_real.z));
			vec2 m = (length(du) > 1e-6 ? normalize(du) : vec2(0.0, 1.0)) * k_up
					+ (length(df) > 1e-6 ? normalize(df) : vec2(0.0, 1.0)) * (1.0 - k_up);
			up2 = length(m) > 1e-4 ? normalize(m) : vec2(0.0, 1.0);
			to_real = -pv_real.z / max(-pv_virt.z, 1e-4);
			w_steep = smoothstep(STEEP.x, STEEP.x + 0.12, el);
			if (w_steep > 0.5) {
				eye = cv;                                    // (its views picked from there too)
			}
		}
	}
	// the view: the camera's bearing around the bone, from the limb's front. The views go from the back (0) to the
	// front (8) through the limb's right side, then back through its left; the 9-view torsos only hold the right
	// side, mirrored for the left
	vec3 front = MODEL_MATRIX[0].xyz;
	front = front - ax * dot(front, ax);
	front = length(front) < 1e-5 ? vec3(1.0, 0.0, 0.0) : normalize(front);
	vec3 side = cross(ax, front);
	vec3 to_cam = eye - origin;
	vec3 c = to_cam - ax * dot(to_cam, ax);
	float ang = atan(dot(c, side), dot(c, front));      // > 0 = camera on the limb's right
	factor = vec3(shade);
	if (lit) {
		vec3 n = length(c) < 1e-5 ? vec3(0.0, 0.0, 1.0) : normalize(c);
		float amb = deep > 0.5 ? 2.0 * light_amb - 1.0 : light_amb;
		float dif = deep > 0.5 ? 0.5 * light_dif : light_dif;
		float li = min(amb + dif * max(0.0, dot(n, light_dir)), 1.5);
		int row = clamp(int(floor(16.0 * li)), 0, 15);
		factor = row >= 15 ? vec3(1.0) : light_rows[row];
	}
	if (mirror > 0.5) {
		ang = -ang;
	}
	flip = 1.0;
	if (game_view.x >= 0.0) {
		layer = min(int(game_view.x), view_count - 1);
		flip = game_view.y;
	} else if (view_count >= 16) {
		layer = int(mod(round(8.0 - ang / (TAU / 16.0)), 16.0));
	} else {
		layer = clamp(int(round(8.0 - abs(ang) / (PI / 8.0))), 0, view_count - 1);
		flip = ang < 0.0 ? -1.0 : 1.0;
	}
	if (mirror > 0.5) {
		flip = -flip;
	}
	vec3 v = lay(VIEW_MATRIX, origin, ax, s, wx, VERTEX.xy);
	if (w_steep > 0.0) {
		// laid out from the lower eye, then put back where the suit is on the real screen, its up along its up there
		vec3 o = (lay(VM, origin, ax, s, wx, VERTEX.xy) - pv_virt) * to_real;
		v = mix(v, pv_real + vec3(o.x * up2.y + o.y * up2.x, -o.x * up2.x + o.y * up2.y, o.z), w_steep);
	}
	// a foot (pull > 0): the game lays its sprite down the screen from the ankle, as long as ever when the toes point at
	// the camera, and paints it over the ground: the toe caps show under the suit. Here the ground hid what reached
	// under it: those points come up the camera's ray to the height of the toe joint
	if (spin < 0.0 && bone_px > 0.0 && foot > 0.5 && w_steep < 0.5) {
		float g = min(origin.y, origin.y + ax.y * s * bone_px) + 0.012;
		float wy = (INV_VIEW_MATRIX * vec4(v, 1.0)).y;
		if (wy < g && CAMERA_POSITION_WORLD.y > g + 0.02) {
			v *= (CAMERA_POSITION_WORLD.y - g) / (CAMERA_POSITION_WORLD.y - wy);
		}
	}
	float l = length(v);
	v *= max(l - pull, 0.05) / l;                        // same place on the screen, nearer
	POSITION = PROJECTION_MATRIX * vec4(v, 1.0);
	// the game's limb drawer leaves out a limb with a joint behind its eye or 2 x further to a side than ahead
	// (0x2F6C90: |x / z| or |y / z| of either joint over 1, in whole numbers): one right beside the eye, stretched
	// from one joint far off the screen to the other, filled the view with a dark slab
	if (spin < 0.0 && bone_px > 0.0) {
		vec3 ra = (VIEW_MATRIX * vec4(origin, 1.0)).xyz;
		vec3 rb = (VIEW_MATRIX * vec4(origin + axis * bone_px, 1.0)).xyz;
		if (ra.z > -1e-3 || rb.z > -1e-3 || max(abs(ra.x), abs(ra.y)) >= -2.0 * ra.z || max(abs(rb.x), abs(rb.y)) >= -2.0 * rb.z) {
			POSITION = vec4(0.0, 0.0, 2.0, 1.0);          // (all its corners at one point out of the view: not drawn)
		}
	}
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
	if (has_ir && tn_ir > 0.5) {
		ALBEDO = tn_game_colour(tn_haze_srgb(texture(views_ir, vec3(uv, float(layer))).rgb));
	} else {
		vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
		ALBEDO = tn_haze(col.rgb * factor * (1.0 + tn_shot_light(wp)), wp, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
	}
}
