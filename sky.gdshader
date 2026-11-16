// Planet sky: the game's cloud texture on its flat ceiling (44 texels per unit of slope, one texel per unit the eye
// moves, shifted by the game's wind offset in live mode), drawn as a sky with depth (planet_sky below); airless worlds
// get the game's star field (SKY3 / SKY4 resource 154, a 512 x 320 wrapping map), one map pixel per screen pixel of
// the game's 320-pixel-wide view: the map repeats 4 times around the horizon.
shader_type sky;

#include "res://sky_common.gdshaderinc"

uniform sampler2D clouds : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D clouds_soft : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // modern look
uniform bool modern = false;               // old school off: a smoother, more natural sky (sky_common)
uniform bool has_clouds = true;
uniform sampler2D stars : source_color, filter_nearest, repeat_enable;
uniform bool has_stars = false;
uniform vec3 haze : source_color = vec3(0.7, 0.76, 0.84);
uniform vec3 light : source_color = vec3(0.91, 0.94, 0.97);   // the lightest cloud colour (the horizon)
uniform float cloud_px = 44.0;             // texels per unit of slope (the ceiling's height over the eye: viewer.gd)
uniform float cloud_par = 1.0;             // texels per world unit the camera moves
uniform vec2 cloud_off = vec2(0.0);        // texels (column, row): the game's wind offset
uniform float desat = 1.0;                 // live mode: undoes the view's saturation boost (the game's own colours)
uniform float gain = 1.0;                  // live mode: the game's sky is brighter than this viewer's
uniform float star_pixel = 0.00307;        // radians per star map pixel (TAU / 4 / 512)

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

// The planet's sky, as the game draws its cloud ceiling (0x2A7222 - 0x2A7622), the same in both looks: the cloud
// texture on a flat ceiling (cloud_px texels per unit of slope), each point hazed by its distance r from overhead in
// texels (thresholds at 0x35C7BC): plain under 192, then the rows 1 to 7 of the sky's cloud haze table (SKY 151:
// levels 1-7 here, from 192, 256, 320, 416, 512, 640, 800), then plain colours, the far band: band0 from 1024,
// band1 from 1200, band2 from 3200, and band3 at the horizon (palette 0xA5, 0xA4, 0xA3, 0xA2; rain: 0x23 .. 0x20).
// Nothing else: no sun or glow under the ceiling (the game shows none).
uniform sampler2DArray levels : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2DArray levels_soft : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // modern look
uniform vec3 band0 : source_color = vec3(0.86, 0.92, 0.85);
uniform vec3 band1 : source_color = vec3(0.9, 0.95, 0.88);
uniform vec3 band2 : source_color = vec3(0.95, 0.97, 0.9);
uniform vec3 band3 : source_color = vec3(0.99, 0.99, 0.93);

vec3 planet_sky(vec3 d, vec3 eye) {
	if (d.y <= 0.0) {
		return band3;
	}
	vec2 rel = vec2(d.z, d.x) / d.y * cloud_px * 1.12;
	float r = length(rel);
	if (r >= 1024.0) {
		return r >= 3200.0 ? band2 : (r >= 1200.0 ? band1 : band0);
	}
	float level = 0.0;
	level += step(192.0, r) + step(256.0, r) + step(320.0, r) + step(416.0, r);
	level += step(512.0, r) + step(640.0, r) + step(800.0, r);
	vec2 t = tn_ripple(rel + vec2(eye.z, eye.x) * cloud_par + cloud_off) / 256.0;
	return modern ? texture(levels_soft, vec3(t, level)).rgb : texture(levels, vec3(t, level)).rgb;
}

void sky() {
	vec3 d = EYEDIR;
	vec3 col = has_clouds ? planet_sky(d, POSITION) : haze;
	if (!has_clouds && d.y > 0.0) {
		vec3 top = vec3(0.0);
		if (has_stars) {
			float az = atan(d.z, d.x) + PI;
			float el = asin(clamp(d.y, 0.0, 1.0));
			vec2 px = vec2(az / star_pixel, 320.0 - el / star_pixel);
			vec4 st = texelFetch(stars, ivec2(mod(floor(px), vec2(512.0, 320.0))), 0);
			top = st.a > 0.5 ? st.rgb : vec3(0.0);
		} else {
			float s2 = hash(floor(d * 420.0));
			top = s2 > 0.9975 ? vec3(0.55 + 0.45 * fract(s2 * 97.0)) : vec3(0.0);
		}
		col = mix(haze, top, smoothstep(0.0, 0.08, d.y));
	}
	col = mix(vec3(dot(col, vec3(0.299, 0.587, 0.114))), col, desat);
	COLOR = col * gain;
}
