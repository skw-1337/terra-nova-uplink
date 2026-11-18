// Planet sky: the game's cloud texture on its flat ceiling (44 texels per unit of slope, one texel per unit the eye
// moves, shifted by the game's wind offset in live mode), drawn as a sky with depth (planet_sky below); airless worlds
// get the game's star field (SKY3 / SKY4 resource 154, a 512 x 320 wrapping map), one map pixel per screen pixel of
// the game's 320-pixel-wide view: the map repeats 4 times around the horizon.
shader_type sky;

#include "res://sky_common.gdshaderinc"
#include "res://tn_haze.gdshaderinc"

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
// sharp stars (an extra, on unless TN_FX_STARS=0): star_scale = pixels of the picture per pixel of the star map
// (viewer.gd _sky_rows; 0: off, the map's own pixels as blocks). Each lit pixel of the game's map is then a round
// point of its own colour at the pixel's place, as big on the screen whatever the picture's size (the brighter the
// bigger: 2 to 4 pixels across in a 1280 pixel wide picture, growing as the square root of the picture's width: far
// slower than the map's blocks, and never much bigger than the map's own pixel), with a smooth edge. Where a map
// pixel is under 1.5 pixels of the picture (the old school's grid of the game's own pixels) the map is drawn as it is.
uniform float star_scale = 0.0;
const float HORIZON_GLOW = 0.3;            // skies without clouds, modern look: share of the haze colour at the horizon

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

// The planet's sky, as the game draws its cloud ceiling (0x2A7222 - 0x2A7622), the same in both looks: the cloud
// texture on a flat ceiling (cloud_px texels per unit of slope), each point hazed by its distance r from overhead in
// texels (thresholds at 0x35C7BC): plain under 192, then the rows 1 to 7 of the sky's cloud haze table (SKY 151:
// levels 1-7 here, from 192, 256, 320, 416, 512, 640, 800), then plain colours, the far band: band0 from 1024,
// band1 from 1200, band2 from 3200, band3 from 6400 and under the horizon (palette 0xA5, 0xA4, 0xA3, 0xA2; rain:
// 0x23 .. 0x20). The game picks the level once per screen row, from the point its row's end ray (the view's edge)
// meets the ceiling: flat bands across the view, not rings (row_*: the main camera, viewer.gd _sky_rows).
// Nothing else: no sun or glow under the ceiling (the game shows none).
uniform sampler2DArray levels : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2DArray levels_soft : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // modern look
uniform sampler2D bands : source_color, filter_nearest;   // 5 x 1: the far band's colours, as the clouds' texels; the far ground
// infrared (live, tn_ir): the same through the planet's IR table 60, in the game's colours
uniform sampler2DArray levels_ir : source_color, filter_nearest_mipmap, repeat_enable;
uniform sampler2D bands_ir : source_color, filter_nearest;
uniform bool has_ir = false;
uniform vec3 row_right = vec3(1.0, 0.0, 0.0);
uniform vec3 row_up = vec3(0.0, 1.0, 0.0);
uniform vec3 row_fwd = vec3(0.0, 0.0, -1.0);
uniform float row_edge = 0.0;              // tangent of half the view's width; 0: per pixel

// the distance from overhead (texels) that sets the haze level of the point seen along d
float ceiling_r(vec3 d, bool per_row) {
	float f = dot(d, row_fwd);
	if (per_row && row_edge > 0.0 && f > 0.05) {
		vec3 e = row_fwd + dot(d, row_up) / f * row_up + row_edge * row_right;
		return e.y > 0.0 ? length(e.xz) / e.y * cloud_px : 1e9;
	}
	return length(d.xz) / max(d.y, 1e-6) * cloud_px * 1.12;
}

// The far band's colours as a gradient (the game steps from one to the next: a flat bar of each across the view, a
// hard grey bar on the rain skies): each colour at the middle of its span of r (in log r), blended between them, the
// last (band3) from 9000 on and under the horizon
vec3 band_at(sampler2D b, float r) {
	const float C0 = 7.0108;              // ln of the middle of 1024 .. 1200
	const float C1 = 7.5805;              // 1200 .. 3200
	const float C2 = 8.4175;              // 3200 .. 6400
	const float C3 = 9.1050;              // 9000
	float lr = log(max(r, 1.0));
	vec3 c0 = texelFetch(b, ivec2(0, 0), 0).rgb;
	vec3 c1 = texelFetch(b, ivec2(1, 0), 0).rgb;
	vec3 c2 = texelFetch(b, ivec2(2, 0), 0).rgb;
	vec3 c3 = texelFetch(b, ivec2(3, 0), 0).rgb;
	if (lr < C1) {
		return mix(c0, c1, smoothstep(C0, C1, lr));
	}
	if (lr < C2) {
		return mix(c1, c2, smoothstep(C1, C2, lr));
	}
	return mix(c2, c3, smoothstep(C2, C3, lr));
}

vec3 stars_sharp(vec2 px, float el) {
	vec2 base = floor(px);
	vec3 best = vec3(0.0);
	float across = max(cos(el), 0.2);         // (the map's columns come closer together up the sky)
	for (int j = -1; j <= 1; j++) {
		for (int i = -1; i <= 1; i++) {
			vec2 t = base + vec2(float(i), float(j));
			vec4 st = texelFetch(stars, ivec2(mod(t, vec2(512.0, 320.0))), 0);
			if (st.a > 0.5) {
				float dist = length((px - (t + 0.5)) * vec2(across, 1.0)) * star_scale;   // pixels of the picture
				float r = min(0.9 + 1.2 * max(st.r, max(st.g, st.b)), 0.62 * star_scale) * sqrt(max(star_scale / 1.9, 1.0));
				best = max(best, st.rgb * (1.0 - smoothstep(r - 0.6, r + 0.6, dist)));
			}
		}
	}
	return best;
}

// The haze level as a number: the game's step at each threshold above (a flat bar across the view, then the next row
// of the haze table: a straight line through the clouds at each of the 7 steps) spread over the span on each side of
// it, the level i whole at the middle of its own span. Both looks: the colours are still the haze table's rows.
float haze_level(float r) {
	const float T[9] = {128.0, 192.0, 256.0, 320.0, 416.0, 512.0, 640.0, 800.0, 960.0};
	if (r <= T[1]) {
		return clamp((r - T[0]) / (T[1] - T[0]) + 0.5 - 1.0, 0.0, 7.0);
	}
	for (int i = 2; i < 9; i++) {
		if (r <= T[i]) {
			return clamp(float(i) - 1.5 + (r - T[i - 1]) / (T[i] - T[i - 1]), 0.0, 7.0);
		}
	}
	return 7.0;
}

// The last clouds fade into the band (the game: a hard edge at 1024). Over 880 .. 1100 the fade took only 0.6 degrees
// of the view near the horizon (r grows as 1 / the elevation): a soft straight line under the clouds, worst under
// the dark storm and ice skies; over 640 .. 1400, in log r, it takes ~2 degrees.
const float FADE_END = 1400.0;
float cloud_fade(float r) {
	return smoothstep(6.4615, 7.2442, log(max(r, 1.0)));       // ln 640 .. ln 1400
}

vec3 planet_sky(vec3 d, vec3 eye, bool per_row) {
	vec2 t0 = vec2(d.z, d.x) / max(d.y, 1e-4) * cloud_px * 1.12 + vec2(eye.z, eye.x) * cloud_par + cloud_off;
	vec2 t = tn_ripple(t0);
	// its mip level from t0, before the ripple: the ripple's jumps from one texel row to the next picked the smallest
	// mip along each row (here, before any branch: the derivatives of the whole quad)
	vec2 gx = dFdx(t0);
	vec2 gy = dFdy(t0);
	if (d.y <= 0.0) {                     // the game: band 3 down to the ground; where no ground is drawn (beyond
		// the outer map), the hazed ground instead (bands texel 4), from the horizon down over ~2 degrees
		return mix(texelFetch(bands, ivec2(3, 0), 0).rgb, texelFetch(bands, ivec2(4, 0), 0).rgb,
				smoothstep(0.0, 0.035, -d.y));
	}
	float r = ceiling_r(d, per_row);
	if (r >= FADE_END) {
		return band_at(bands, r);
	}
	float level = haze_level(r);
	float l0 = floor(level);
	vec3 t3 = vec3(t / 256.0, l0);
	vec3 c = modern ? textureGrad(levels_soft, t3, gx / 256.0, gy / 256.0).rgb : textureGrad(levels, t3, gx / 256.0, gy / 256.0).rgb;
	if (level > l0 + 0.001) {
		t3.z = min(l0 + 1.0, 7.0);
		vec3 c1 = modern ? textureGrad(levels_soft, t3, gx / 256.0, gy / 256.0).rgb : textureGrad(levels, t3, gx / 256.0, gy / 256.0).rgb;
		c = mix(c, c1, level - l0);
	}
	return mix(c, band_at(bands, r), cloud_fade(r));
}

vec3 ir_sky(vec3 d, vec3 eye, bool per_row) {
	vec2 t0 = vec2(d.z, d.x) / max(d.y, 1e-4) * cloud_px * 1.12 + vec2(eye.z, eye.x) * cloud_par + cloud_off;
	vec2 t = tn_ripple(t0);
	vec2 gx = dFdx(t0) / 256.0;
	vec2 gy = dFdy(t0) / 256.0;
	if (d.y <= 0.0) {
		return texelFetch(bands_ir, ivec2(3, 0), 0).rgb;
	}
	float r = ceiling_r(d, per_row);
	if (r >= FADE_END) {
		return band_at(bands_ir, r);
	}
	float level = haze_level(r);
	float l0 = floor(level);
	vec3 c = textureGrad(levels_ir, vec3(t / 256.0, l0), gx, gy).rgb;
	if (level > l0 + 0.001) {
		c = mix(c, textureGrad(levels_ir, vec3(t / 256.0, min(l0 + 1.0, 7.0)), gx, gy).rgb, level - l0);
	}
	return mix(c, band_at(bands_ir, r), cloud_fade(r));
}

void sky() {
	vec3 d = EYEDIR;
	vec3 col = has_clouds ? planet_sky(d, POSITION, !AT_CUBEMAP_PASS) : haze;
	float glow = modern ? HORIZON_GLOW : 0.0;
	if (!has_clouds && d.y > 0.0) {
		vec3 top = vec3(0.0);
		if (has_stars) {
			float az = atan(d.z, d.x) + PI;
			float el = asin(clamp(d.y, 0.0, 1.0));
			vec2 px = vec2(az / star_pixel, 320.0 - el / star_pixel);
			if (star_scale > 1.5) {            // (a map pixel no bigger than 1.5 of the picture's: sharp as it is)
				top = stars_sharp(px, el);
			} else {
				vec4 st = texelFetch(stars, ivec2(mod(floor(px), vec2(512.0, 320.0))), 0);
				top = st.a > 0.5 ? st.rgb : vec3(0.0);
			}
		} else {
			float s2 = hash(floor(d * 420.0));
			top = s2 > 0.9975 ? vec3(0.55 + 0.45 * fract(s2 * 97.0)) : vec3(0.0);
		}
		// the game fills a sky without clouds with one flat colour (0x2A82D0) down to the ground: no glow at the
		// horizon (the old school look). The modern look keeps a faint one, wide and soft (the full haze colour over
		// 0.08 rad drew a hard grey bar across the night skies, over the far relief, worse once snapped to the palette)
		col = mix(haze * glow, top, smoothstep(0.0, 0.18, d.y));
	} else if (!has_clouds) {
		col = haze * glow;                 // under the horizon, where no ground is drawn: the same
	}
	col = mix(vec3(dot(col, vec3(0.299, 0.587, 0.114))), col, desat);
	COLOR = col * gain;
	if (has_ir && has_clouds && tn_ir > 0.5) {
		COLOR = tn_game_colour(tn_haze_srgb(ir_sky(d, POSITION, !AT_CUBEMAP_PASS)));
	}
}
