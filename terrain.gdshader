// Terra Nova ground: one 64x64 atlas tile per grid cell, turned by a quarter-turn count.
// tilemap: R = tile index, G = clockwise quarter turns (0-3), one texel per grid vertex.
// Its light is the map's own, as the game draws it: each vertex carries 15.5 - 2 x its stored light level (UV2.x),
// interpolated over the triangle, and the floor of it picks a row of the planet's light table (light_rows: their
// brightness, RESPLNT 53). No sun on the ground (its slopes and the hills' shadows are in the levels): the colour is
// given as emission, and the light only takes away where an object's shadow falls (light()).
shader_type spatial;
render_mode ambient_light_disabled, specular_disabled, fog_disabled;

#include "res://tn_haze.gdshaderinc"

uniform float light_rows[16];                  // brightness of the light table's rows, row 0 = full light
uniform vec3 ground_light = vec3(1.0);         // the ground at full light (the map viewer's look)
// per_index: the tiles as the game lights them, each texel's palette index swapped through the row (layer
// row x tile_count + tile, file row 0 = full light): no brightness factor then. game_colours (live): their colours
// shown as the game's, through the view's adjustments (tn_game_colour), without the viewer's look
uniform bool per_index = false;
uniform float tile_count = 64.0;
uniform bool game_colours = false;
uniform sampler2DArray tiles_lit : source_color, filter_nearest_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray tiles_lit_soft : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
// the game's own pixels (live, old school): each texel's palette index (tiles_idx, its smaller levels picked texels)
// swapped through the light row (shade_idx: RESPLNT 53, 256 x 16), then through the sky's haze row at that distance
// (haze_lut: SKY 150 as colours, 256 x 16), as the game draws its ground: no mixing, every pixel a colour of the palette
// (the old school pass keeps it; a mix in sRGB fell between the palette's colours and was snapped to others)
uniform sampler2DArray tiles_idx : filter_nearest, repeat_disable;
uniform sampler2D shade_idx : filter_nearest, repeat_disable;
uniform sampler2D haze_lut : filter_nearest, repeat_disable;
uniform bool has_haze_lut = false;
uniform float shadow_dark = 0.6;               // an object's shadow takes this much away


// nearest up close: the game's texels, crisp like the original; mipmapped further away: no shimmering
uniform sampler2DArray tiles : source_color, filter_nearest_mipmap_anisotropic, repeat_disable;
// modern look (old school off): the same tiles filtered smoothly, the game's big texels no longer blocks up close
uniform sampler2DArray tiles_soft : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray tiles_wrap : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // its grain
uniform sampler2D tilemap : filter_nearest, repeat_disable;
uniform vec2 origin;          // world XZ of grid vertex (0, 0)
uniform float step_size;      // world units between grid vertices
uniform float grid_n;         // vertices per side
// (water: drawn over the ground by water.gdshader, on the water texels of the water tiles)
uniform vec3 sun_dir = vec3(0.0, 0.7, 0.7);
uniform bool modern = false;            // modern look (old school off): the extras below
const float GRAIN = 0.55;
// relief: the hollows of the height map darker, its crests lighter (one texel per grid vertex, 0.5 = unchanged),
// and the tile's own picture as a bump map (its light parts stand out, lit by the sun)
uniform sampler2D relief : filter_linear, repeat_disable;
uniform bool has_relief = false;
uniform float bump = 0.035;   // world units of height per unit of brightness


// detail relief: procedural bumps, clods and hollows in world space, several scales, faded where they would
// shimmer. detail = height of the biggest bumps (world units), detail_freq = how many per unit
uniform float detail = 0.12;
uniform float detail_freq = 0.25;
uniform float cavity = 0.35;           // hollows darker, bumps lighter (seen even out of the sun)

float detail_hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

// gradient noise and its slope (x: value around 0.5, yz: slope): no edges along its grid, unlike value noise
vec2 detail_grad(vec2 p) {
	float a = detail_hash(p) * 6.2831853;
	return vec2(cos(a), sin(a));
}

vec3 detail_noised(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	vec2 ga = detail_grad(i);
	vec2 gb = detail_grad(i + vec2(1.0, 0.0));
	vec2 gc = detail_grad(i + vec2(0.0, 1.0));
	vec2 gd = detail_grad(i + vec2(1.0, 1.0));
	float va = dot(ga, f);
	float vb = dot(gb, f - vec2(1.0, 0.0));
	float vc = dot(gc, f - vec2(0.0, 1.0));
	float vd = dot(gd, f - vec2(1.0, 1.0));
	float k = va - vb - vc + vd;
	float v = va + u.x * (vb - va) + u.y * (vc - va) + u.x * u.y * k;
	vec2 d = ga + u.x * (gb - ga) + u.y * (gc - ga) + u.x * u.y * (ga - gb - gc + gd) +
			du * (u.yx * k + vec2(vb, vc) - va);
	return vec3(v + 0.5, d);
}


// a ground cell's tile at a position beyond its edges (mirrored)
vec3 cell_tile(vec2 cell, vec2 q, vec2 dx, vec2 dy, float loff) {
	cell = clamp(cell, vec2(0.0), vec2(grid_n - 2.0));
	vec4 t = texture(tilemap, (cell + 0.5) / grid_n);
	float tile = floor(t.r * 255.0 + 0.5);
	int rot = int(floor(t.g * 255.0 + 0.5));
	vec2 f = q - cell;
	f = 1.0 - abs(1.0 - abs(f));             // beyond the cell: mirrored (continuous at its edge; wrapped, the tile's other side drew lines)
	vec2 uv = f;
	if (rot == 1) {
		uv = vec2(f.y, 1.0 - f.x);
		dx = vec2(dx.y, -dx.x);
		dy = vec2(dy.y, -dy.x);
	} else if (rot == 2) {
		uv = 1.0 - f;
		dx = -dx;
		dy = -dy;
	} else if (rot == 3) {
		uv = vec2(1.0 - f.y, f.x);
		dx = vec2(-dx.y, dx.x);
		dy = vec2(-dy.y, dy.x);
	}
	// clamped, not wrapped: uv stays in 0..1 (mirrored above), and a wrapping filter mixed the tile's opposite edge
	// into its border texels (a thin light line along the cells of two-material tiles)
	if (per_index) {
		return textureGrad(tiles_lit_soft, vec3(uv, tile + loff), dx, dy).rgb;
	}
	return textureGrad(tiles_soft, vec3(uv, tile), dx, dy).rgb;
}

uniform float blend_width = 0.3;      // blend between two cells (share of a cell each side)

// the four cells around the point blended into each other along an uneven edge (no more square tiles)
vec3 cells_blend(vec2 q, vec2 dx, vec2 dy, vec3 wp, float loff) {
	vec2 qc = q - 0.5;
	vec2 c0 = floor(qc);
	vec2 fb = fract(qc);
	vec2 jit = vec2(detail_noised(wp.xz * 0.7).x, detail_noised(wp.xz * 0.7 + 31.7).x) - 0.5;
	vec2 fw = smoothstep(0.5 - blend_width, 0.5 + blend_width, clamp(fb + jit * 0.5, 0.0, 1.0));
	vec3 a = cell_tile(c0, q, dx, dy, loff);
	vec3 b = cell_tile(c0 + vec2(1.0, 0.0), q, dx, dy, loff);
	vec3 c = cell_tile(c0 + vec2(0.0, 1.0), q, dx, dy, loff);
	vec3 d = cell_tile(c0 + vec2(1.0, 1.0), q, dx, dy, loff);
	return mix(mix(a, b, fw.x), mix(c, d, fw.x), fw.y);
}

// the ground more credible without tessellation: wide patches lighter / darker, warmer / cooler (the tiles' pattern
// no longer repeats), a fine detail chosen by the ground's colour (near the eye only), rock on the steep slopes
uniform float macro_amount = 0.16;
uniform float fine_amount = 0.24;
uniform float slope_rock = 0.35;
uniform float sparkle = 0.0;           // snow: crystals catching the light up close (the ice planet)

// fine details, around 0 (-0.5 .. 0.5): grass (tufts, blades each tuft its own way), sand (wind ripples), rock
// (grain, dark veins), snow (soft drifts)
float grass_fine(vec2 p) {
	float clump = detail_noised(p * 2.3).x;
	float a = clump * 6.2832;
	vec2 q = mat2(vec2(cos(a), sin(a)), vec2(-sin(a), cos(a))) * p;
	return (clump - 0.5) * 0.6 + (detail_noised(q * vec2(28.0, 5.0)).x - 0.5) * 0.7;
}

float sand_fine(vec2 p) {
	float w = detail_noised(p * 0.35).x * 6.0;
	return sin(dot(p, vec2(0.8, 0.6)) * 9.0 + w) * 0.35 + (detail_noised(p * 14.0).x - 0.5) * 0.4;
}

float rock_fine(vec2 p) {
	float cr = abs(detail_noised(p * 3.0).x - 0.5) * 2.0;
	return (detail_noised(p * 6.0).x - 0.5) * 0.5 + (detail_noised(p * 22.0).x - 0.5) * 0.35 - (1.0 - smoothstep(0.0, 0.12, cr)) * 0.4;
}

float snow_fine(vec2 p) {
	return (detail_noised(p * 1.2).x - 0.5) * 0.5 + (detail_noised(p * 9.0).x - 0.5) * 0.2;
}

// by the colour there: green = grass, yellow / orange = sand, white = snow, the rest (grey) = rock
float ground_fine(vec2 p, vec3 c) {
	float l = dot(c, vec3(0.3, 0.59, 0.11));
	float green = clamp((c.g - max(c.r, c.b)) * 6.0, 0.0, 1.0);
	float warm = clamp((c.r - c.b) * 3.0 - green, 0.0, 1.0);
	float white = smoothstep(0.62, 0.8, l) * (1.0 - warm);
	float grey = clamp(1.0 - green - warm - white, 0.0, 1.0);
	float f = 0.0;
	if (green > 0.0) f += grass_fine(p) * green;
	if (warm > 0.0) f += sand_fine(p) * warm;
	if (white > 0.0) f += snow_fine(p) * white;
	if (grey > 0.0) f += rock_fine(p) * grey;
	return f;
}

varying vec2 g;
varying vec3 wpos;
varying float vlight;

// the ground's texel at grid position q (tile of its cell, turned), sharpened mip choice
vec3 ground_at(vec2 q, vec2 dx, vec2 dy, float loff, out vec2 uv, out float tile, out vec2 du, out vec2 dv) {
	vec2 cell = clamp(floor(q), vec2(0.0), vec2(grid_n - 2.0));
	vec2 f = clamp(q - cell, 0.0, 1.0);
	vec4 t = texture(tilemap, (cell + 0.5) / grid_n);
	tile = floor(t.r * 255.0 + 0.5);
	int rot = int(floor(t.g * 255.0 + 0.5));
	uv = f;
	if (rot == 1) {
		uv = vec2(f.y, 1.0 - f.x);
		dx = vec2(dx.y, -dx.x);
		dy = vec2(dy.y, -dy.x);
	} else if (rot == 2) {
		uv = 1.0 - f;
		dx = -dx;
		dy = -dy;
	} else if (rot == 3) {
		uv = vec2(1.0 - f.y, f.x);
		dx = vec2(-dx.y, dx.x);
		dy = vec2(-dy.y, dy.x);
	}
	du = dx;
	dv = dy;
	if (per_index) {
		if (modern) {
			return textureGrad(tiles_lit_soft, vec3(uv * (63.0 / 64.0) + 0.5 / 64.0, tile + loff), dx, dy).rgb;
		}
		return textureGrad(tiles_lit, vec3(uv, tile + loff), dx, dy).rgb;
	}
	if (modern) {        // texel centres to the cell's edges: no half-texel strip of the edge texel along each border
		return textureGrad(tiles_soft, vec3(uv * (63.0 / 64.0) + 0.5 / 64.0, tile), dx, dy).rgb;
	}
	return textureGrad(tiles, vec3(uv, tile), dx, dy).rgb;
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wpos = w;
	g = (w.xz - origin) / step_size;
	vlight = UV2.x;
}

void light() {
	if (LIGHT_IS_DIRECTIONAL) {
		DIFFUSE_LIGHT += vec3(ATTENUATION - 1.0);
	}
}

void fragment() {
	// gradients from the continuous grid position: no mip seams at cell borders; the plain mip choice (sharper, the
	// ground shimmered as the view turned, worse through the game's palette)
	vec2 dx = dFdx(g);
	vec2 dy = dFdy(g);
	vec3 n_geo = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	int frow = 15 - clamp(int(floor(vlight)), 0, 15);       // the row's file row (0 = full light)
	float row_light = per_index ? 1.0 : light_rows[frow];
	float loff = float(frow) * tile_count;
	if (game_colours && per_index && has_haze_lut && !modern) {
		vec2 cell = clamp(floor(g), vec2(0.0), vec2(grid_n - 2.0));
		vec2 f = clamp(g - cell, 0.0, 0.99999);
		vec4 t = texture(tilemap, (cell + 0.5) / grid_n);
		int tile = int(floor(t.r * 255.0 + 0.5));
		int rot = int(floor(t.g * 255.0 + 0.5));
		vec2 uv = f;
		if (rot == 1) {
			uv = vec2(f.y, 1.0 - f.x);
		} else if (rot == 2) {
			uv = 1.0 - f;
		} else if (rot == 3) {
			uv = vec2(1.0 - f.y, f.x);
		}
		// a level per texel per game pixel (the old school grid: about 2 window pixels a game pixel)
		float tpp = max(length(dFdx(g)), length(dFdy(g))) * 64.0;
		int lod = clamp(int(floor(log2(max(tpp * 2.0, 1.0)))), 0, 6);
		int sz = 64 >> lod;
		ivec2 tx = clamp(ivec2(floor(uv * float(sz))), ivec2(0), ivec2(sz - 1));
		int i0 = int(texelFetch(tiles_idx, ivec3(tx, tile), lod).r * 255.0 + 0.5);
		int i1 = int(texelFetch(shade_idx, ivec2(i0, frow), 0).r * 255.0 + 0.5);
		int lv = 0;                       // the game's haze level (tn_haze.gdshaderinc), whole
		if (tn_haze_range.w > 0.5 && tn_haze_range.w < 1.5 && (CAMERA_VISIBLE_LAYERS & (1u << 16u)) != 0u) {
			vec2 dd = abs(wpos.xz - CAMERA_POSITION_WORLD.xz);
			lv = clamp(int(floor(16.0 * (1.0 - exp(-max(max(dd.x, dd.y) - 20.0, 0.0) / tn_haze_range.x)))), 0, 15);
		}
		vec3 c = tn_game_colour(texelFetch(haze_lut, ivec2(i1, lv), 0).rgb);
		ROUGHNESS = 1.0;
		EMISSION = c;
		ALBEDO = c * shadow_dark;         // what an object's shadow takes away (light())
	} else {
		vec2 uv;
		float tile;
		vec2 du;
		vec2 dv;
		vec3 col = ground_at(g, dx, dy, loff, uv, tile, du, dv);
		float l0 = dot(col, vec3(0.3, 0.59, 0.11));
		// texels per screen pixel: the grain and the bump only where a texel covers more than a pixel (finer, they
		// only added noise that shimmered as the view moved)
		float tpp = max(length(dFdx(g)), length(dFdy(g))) * 64.0;
		col = cells_blend(g, dx, dy, wpos, loff);       // cells blended
		// grain: the same tile 4 times finer modulates the brightness up close (grass blades, dirt streaks); its mips
		// fade it to nothing further away, so it does not shimmer
		vec3 fine = modern ? textureGrad(tiles_wrap, vec3(uv * 4.0, tile), du * 4.0, dv * 4.0).rgb   // wrapped: no seams
				: textureGrad(tiles, vec3(fract(uv * 4.0), tile), du * 4.0, dv * 4.0).rgb;
		vec3 avg = textureLod(tiles, vec3(0.5, 0.5, tile), 6.0).rgb;
		float gain = dot(fine, vec3(0.3, 0.59, 0.11)) / max(dot(avg, vec3(0.3, 0.59, 0.11)), 0.02);
		col *= mix(1.0, clamp(gain, 0.4, 1.8), GRAIN * (1.0 - smoothstep(0.06, 0.12, tpp)));
		if (has_relief && modern) {          // (modern look only: the game's ground has no light but its levels)
			col *= texture(relief, (g + 0.5) / grid_n).r + 0.5;
		}
		{                                    // wide patches, the fine detail up close, rock on the slopes
			float mac = detail_noised(wpos.xz * 0.018 + 3.1).x * 0.65 + detail_noised(wpos.xz * 0.006 + 7.7).x * 0.35;
			float mv = clamp((mac - 0.5) * 2.0, -1.0, 1.0);
			col *= 1.0 + mv * macro_amount;
			col *= mix(vec3(1.0), vec3(1.05, 1.0, 0.93), clamp(mv, 0.0, 1.0) * macro_amount * 2.0);
			float near = 1.0 - smoothstep(4.0, 40.0, length(CAMERA_POSITION_WORLD - wpos));
			if (near > 0.0) {
				col *= 1.0 + ground_fine(wpos.xz, col) * fine_amount * 2.0 * near;
			}
			vec3 nwg = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			float steep = 1.0 - smoothstep(0.55, 0.85, nwg.y);
			float lc = dot(col, vec3(0.3, 0.59, 0.11));
			col = mix(col, vec3(lc) * vec3(0.95, 0.93, 0.9) * 0.78, steep * slope_rock * float(modern));
			if (sparkle > 0.0 && near > 0.0) {
				float h = detail_hash(floor(wpos.xz * 40.0) + 0.37);
				EMISSION += vec3(1.0, 0.98, 0.95) * step(0.996, h) * sparkle * near * near;
			}
		}
		ALBEDO = col;
		ROUGHNESS = 1.0;
		float bump_k = modern ? bump * (1.0 - smoothstep(0.25, 0.5, tpp)) : 0.0;
		if (modern) {        // across a cell border the next tile's texels made a step: a line along every border
			vec2 fe = fract(g);
			bump_k *= smoothstep(0.0, 0.06, min(min(fe.x, 1.0 - fe.x), min(fe.y, 1.0 - fe.y)));
		}
		if (bump_k > 0.0) {
			// one texel further along x and along z: the brightness slope tilts the normal (faded by the mips far away)
			const float TEXEL = 1.0 / 64.0;
			vec2 uv2;
			float t2;
			vec2 du2;
			vec2 dv2;
			float l1 = dot(ground_at(g + vec2(TEXEL, 0.0), dx, dy, loff, uv2, t2, du2, dv2), vec3(0.3, 0.59, 0.11));
			float l2 = dot(ground_at(g + vec2(0.0, TEXEL), dx, dy, loff, uv2, t2, du2, dv2), vec3(0.3, 0.59, 0.11));
			vec2 slope = vec2(l1 - l0, l2 - l0) / (TEXEL * step_size) * bump_k;
			vec3 nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			nw = normalize(nw - vec3(slope.x, 0.0, slope.y));
			NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
		}
		if (detail > 0.0 && modern) {      // detail relief
			// world units per pixel from the distance and the smooth normal (continuous across triangles: wpos's
			// derivatives change at each one, they drew straight lines); at a grazing angle squashed along one screen
			// axis only: the factor's square root
			vec3 tocam = CAMERA_POSITION_WORLD - wpos;
			float dist = length(tocam);
			vec3 nsm = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			float graze = max(abs(dot(nsm, tocam / dist)), 0.12);
			float px = dist * 2.0 / (PROJECTION_MATRIX[1][1] * VIEWPORT_SIZE.y) / sqrt(graze);
			vec2 grad = vec2(0.0);
			float cav = 0.0;
			float amp = 1.0;
			float fq = detail_freq;
			mat2 rot = mat2(1.0);                  // each scale turned: no direction stands out
			for (int i = 0; i < 6; i++) {          // from 4-unit swells down to 10 cm clods
				float fade = 1.0 - smoothstep(0.2, 0.45, px * fq);   // a bump under ~3 pixels: none
				vec3 n = detail_noised((rot * wpos.xz) * fq + float(i) * 17.3);
				grad += (n.yz * rot) * amp * fq * fade;
				rot = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * rot;
				cav += (n.x - 0.5) * amp * fade;
				amp *= 0.5;
				fq *= 2.1;
			}
			vec3 nwd = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			nwd = normalize(nwd - vec3(grad.x, 0.0, grad.y) * detail);
			NORMAL = normalize((VIEW_MATRIX * vec4(nwd, 0.0)).xyz);
			ALBEDO *= clamp(1.0 + cav * cavity, 0.5, 1.5);
		}
		// the modern look's bumps and detail relief: only what they change against the cell's own slope (its light is the
		// level's), towards the sun
		float bump_light = 1.0;
		if (modern) {
			vec3 nwb = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			bump_light = clamp(1.0 + max(dot(nwb, sun_dir), 0.0) - max(dot(n_geo, sun_dir), 0.0), 0.6, 1.4);
		}
		vec3 lit = ALBEDO * row_light * bump_light * ground_light;
		if (game_colours) {                  // the game's colours on the screen (its texels in sRGB, through the view)
			lit = tn_game_colour(tn_haze_srgb(ALBEDO * row_light)) * bump_light;
		}
		vec3 glow = EMISSION;
		// hazed as the game does (tn_haze.gdshaderinc). ALBEDO only serves the shadows (light()): what a full shadow
		// takes away, down to the hazed colour of the shaded ground
		vec3 hz = tn_haze(lit, wpos, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
		EMISSION = hz + glow;
		ALBEDO = hz - tn_haze(lit * (1.0 - shadow_dark), wpos, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
	}
}
