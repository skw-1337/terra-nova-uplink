// Water, as the game draws it (0x2B219C, 0x2A84A4, span loop 0x32E145): over the ground mesh itself (it follows its
// slopes: no water level), on the water tiles of the planet (RESPLNT 40 / 43 / 67 / 69 / 72) and there only on their
// water texels (palette 162-175: the shore is the tile's own picture). Such a texel takes no ground light: the screen
// mirrored about a row just above the horizon, each colour index jittered by a pixel, faded by its screen row
// towards the planet's water tint.
// Modern look (old school off): the sky mirrored on moving waves instead (sky_common), on the same texels.
// One material per ground grid (its tile map), drawn over the water cells of that grid (Terrain.build: only).
shader_type spatial;
render_mode unshaded, cull_back, depth_draw_never, shadows_disabled, fog_disabled;

#include "res://sky_common.gdshaderinc"
#include "res://tn_haze.gdshaderinc"

uniform sampler2DArray tiles : source_color, filter_nearest, repeat_disable;
uniform sampler2DArray water_mask : filter_nearest, repeat_disable;   // palette index - 161 on water texels, else 0
uniform sampler2D tilemap : filter_nearest, repeat_disable;
uniform sampler2D screen : hint_screen_texture, filter_nearest;
uniform vec2 origin;
uniform float step_size;
uniform float grid_n;
uniform vec3 tint = vec3(0.314, 0.502, 0.627);   // the game's 0..255 / 255 (sRGB): (80, 128, 160) for RESPLNT 40 byte 1 = 0
uniform bool plain = false;                // infrared: the water tiles drawn as plain ground (the ground under it)
uniform float view_rows = 200.0;           // the game's screen height, for its 1-pixel steps (400 under the HUD)
// the game's 3D window in the window (shares of its height; --hud: rows of the 320 x 400 screen): a mirrored row
// above its top takes the texel's own colour, and the fade ends at its bottom (the game's canvas)
uniform float view_top = 0.0;
uniform float view_bottom = 1.0;
// modern look
uniform bool modern = false;
uniform sampler2D clouds : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D clouds_soft : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_clouds = true;
uniform vec3 haze : source_color = vec3(0.7, 0.76, 0.84);
uniform vec3 light : source_color = vec3(0.91, 0.94, 0.97);
uniform float cloud_px = 44.0;
uniform float cloud_par = 1.0;
uniform vec2 cloud_off = vec2(0.0);
uniform vec3 sun_dir = vec3(0.0, 0.7, 0.7);
uniform float desat = 1.0;
uniform vec3 water_far : source_color = vec3(0.41, 0.54, 0.5);   // the mean colour of the water texels
// live, old school: the fade's result snapped to a palette colour as the game's fade tables are (0x2F1C64 builds them
// through the 2D library's inverse palette: the nearest colour in RGB, 5 bits a channel), and not hazed again
uniform sampler2D pal_tex : filter_nearest;   // 256 x 1, the planet's palette
uniform bool has_pal = false;
global uniform float tn_time;              // seconds, the viewer's clock (it stops in the photo mode)

varying vec3 wpos;
varying vec2 g;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	g = (wpos.xz - origin) / step_size;
	// a hair nearer the eye than the ground it lies on (the same triangles)
	vec3 to_cam = (inverse(MODEL_MATRIX) * vec4(CAMERA_POSITION_WORLD, 1.0)).xyz - VERTEX;
	VERTEX += normalize(to_cam) * min(0.02, length(to_cam) * 0.001);
}

vec3 to_srgb(vec3 c) {
	c = max(c, vec3(0.0));
	return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(vec3(0.0031308), c));
}

vec3 to_linear(vec3 c) {
	return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(vec3(0.04045), c));
}

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 cell = clamp(floor(g), vec2(0.0), vec2(grid_n - 2.0));
	vec2 f = clamp(g - cell, 0.0, 0.9999);
	vec4 t = texture(tilemap, (cell + 0.5) / grid_n);
	float tile = floor(t.r * 255.0 + 0.5);
	int rot = int(floor(t.g * 255.0 + 0.5));
	vec2 uv = f;
	if (rot == 1) {
		uv = vec2(f.y, 1.0 - f.x);
	} else if (rot == 2) {
		uv = 1.0 - f;
	} else if (rot == 3) {
		uv = vec2(1.0 - f.y, f.x);
	}
	float idx = floor(texture(water_mask, vec3(uv, tile)).r * 255.0 + 0.5);
	if (idx < 0.5 || plain) {
		discard;
	}
	vec3 own = texture(tiles, vec3(uv, tile)).rgb;
	if (modern) {
		vec3 v = normalize(wpos - CAMERA_POSITION_WORLD);
		float dist = length(wpos - CAMERA_POSITION_WORLD);
		vec2 sm = tn_waves(wpos.xz, tn_time, dist);
		vec3 nm = normalize(vec3(-sm.x, 1.0, -sm.y));
		vec3 rm = reflect(v, nm);
		rm.y = max(rm.y, 0.07);
		vec3 skym = tn_sky(rm, wpos, clouds_soft, has_clouds, light, haze, cloud_px, cloud_par, cloud_off, vec3(0.0, -1.0, 0.0));
		skym = mix(vec3(dot(skym, vec3(0.299, 0.587, 0.114))), skym, desat);
		float fm = 0.04 + 0.96 * pow(1.0 - clamp(dot(-v, nm), 0.0, 1.0), 5.0);
		float km = clamp(0.2 + 0.55 * fm, 0.0, 0.75);
		ALBEDO = water_far * 0.5 * (1.0 - km) + skym * mix(vec3(1.0), water_far * 1.6, 0.35) * km +
				vec3(1.0, 0.95, 0.85) * pow(max(dot(rm, sun_dir), 0.0), 900.0) * 1.2;
	} else {
		// the mirror row H: the horizon's row (the camera has no roll) less one row of the game's window
		vec3 fwd = -INV_VIEW_MATRIX[2].xyz;
		vec3 hd = normalize(vec3(fwd.x, 0.0, fwd.z) + vec3(1e-6, 0.0, 0.0));
		vec4 hp = PROJECTION_MATRIX * (VIEW_MATRIX * vec4(hd, 0.0));
		float px = VIEWPORT_SIZE.y / view_rows;                   // screen pixels per pixel of the game's window
		float h = (0.5 + 0.5 * hp.y / hp.w) * VIEWPORT_SIZE.y - px;     // (FRAGCOORD: rows down from the top)
		vec2 fc = FRAGCOORD.xy;
		// each of the 14 colour indices gets its own pixel of jitter (-1, 0, 1 on both axes), drawn again each frame
		float frame = floor(tn_time * 30.0);
		vec2 jit = floor(vec2(hash(vec2(idx, frame)), hash(vec2(idx + 17.0, frame))) * 3.0) - 1.0;
		vec2 src = vec2(fc.x, 2.0 * h - fc.y) + jit * px;
		vec3 ps = to_srgb(own);              // (the texel's own colour: the game's value as is)
		float top = view_top * VIEWPORT_SIZE.y;
		float bot = view_bottom * VIEWPORT_SIZE.y;
		if (src.y >= top) {
			ps = clamp(tn_view_srgb(texture(screen, clamp(src, vec2(0.5), VIEWPORT_SIZE - 0.5) / VIEWPORT_SIZE).rgb), 0.0, 1.0);
		}
		float lo = h - top < (bot - top) * 0.5 ? 2.0 * h - top - px : bot;
		float k = fc.y < h ? 0.0 : clamp(floor((fc.y - h) * 16.0 / max(lo - h, 1.0)), 0.0, 15.0);
		float fk = 0.25 + 0.046875 * k;
		// out = f C + (1 - f) P (2/3 + C / 768), C and P on 0..255 (0x2F1C64), in the game's (sRGB) values: P as
		// the screen shows it (the screen texture holds it before the view's adjustments), and the result shown
		// as is (tn_game_colour; the adjustments lifted and saturated the water)
		vec3 o = fk * tint + (1.0 - fk) * ps * (2.0 / 3.0 + tint * (255.0 / 768.0));
		if (has_pal && tn_view_bcs.w > 0.5) {
			vec3 q = (floor(clamp(o, 0.0, 0.9999) * 32.0) * 8.0 + 4.0) / 255.0;   // the inverse palette's cell
			float best = 1e9;
			vec3 bc = o;
			for (int i = 0; i < 256; i++) {
				vec3 pc = texelFetch(pal_tex, ivec2(i, 0), 0).rgb;
				vec3 e = pc - q;
				float d = dot(e, e);
				if (d < best) {
					best = d;
					bc = pc;
				}
			}
			o = bc;
		}
		ALBEDO = tn_game_colour(o);
	}
	if (modern || !has_pal || tn_view_bcs.w < 0.5) {
		ALBEDO = tn_haze(ALBEDO, wpos, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
	}
}
