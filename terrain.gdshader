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
uniform sampler2D haze_lut_idx : filter_nearest, repeat_disable;  // the same rows as palette indices (R8)
uniform bool has_haze_lut = false;
uniform sampler2D ir_lut : filter_nearest, repeat_disable;     // 256 x 4: the colours of tables 59, 60, 61, 62
uniform bool has_ir = false;
uniform float shadow_dark = 0.6;               // an object's shadow takes this much away
// cloud shadows (an extra, on unless TN_FX_CLOUD_SHADOWS=0: viewer.gd _cloud_cover): the sky's cloud layer seen from
// the ground along the sun's direction, where it stands over the map (its texels are a world unit, shifted by the
// same wind offset as the sky's: cloud_off), takes up to cloud_rows rows of the planet's light table away
uniform bool cloud_shadows = false;
uniform sampler2D cloud_cover : filter_linear, repeat_enable;   // 256 x 256: the cloud's rank (1: the sky's thickest)
uniform vec2 cloud_off = vec2(0.0);            // texels (column, row), as the sky's
uniform vec4 cloud_sun = vec4(0.0, 1.0, 0.0, 50.0);   // xyz towards the sun, w the ceiling's height
uniform float cloud_rows = 2.0;                // at most
// burnt ground (live: a tree destroyed, a blast): the game stamps one of its 4 burn pictures over the whole square of a
// burnt point, as part of the ground (lit and hazed with it). burn_map: one texel per point, 0 or 1 + its picture;
// burn_idx: the pictures' palette indices (0 = the ground shows through); burn_pal: the planet's palette (viewer.gd
// _live_scorch)
uniform bool has_burn = false;
uniform sampler2D burn_map : filter_nearest, repeat_disable;
uniform sampler2DArray burn_idx : filter_nearest, repeat_disable;
uniform sampler2D burn_pal : filter_nearest, repeat_disable;
// the share of haze in each row of the skies' haze tables (SKY 150) on the planets' ground colours, sRGB, towards
// row 15 (the mean of SKY0-4 on their planets: live10 rows.py)
const float ROW_SHARE[16] = {0.0, 0.0, 0.03, 0.09, 0.14, 0.19, 0.24, 0.30, 0.36, 0.45, 0.51, 0.58, 0.68, 0.78, 0.87, 1.0};


// nearest up close: the game's texels, crisp like the original; mipmapped further away: no shimmering
uniform sampler2DArray tiles : source_color, filter_nearest_mipmap_anisotropic, repeat_disable;
// modern look (old school off): the same tiles filtered smoothly, the game's big texels no longer blocks up close
uniform sampler2DArray tiles_soft : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray tiles_wrap : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // its grain
uniform sampler2D tilemap : filter_nearest, repeat_disable;
// 64 x 1: 1 for the built ground's tiles (concrete pads, base floors, hazard stripes: tn_data _built_tiles), 0 natural
uniform sampler2D tile_built : hint_default_black, filter_nearest, repeat_disable;
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

// gradient noise and its slope (x: value around 0.5, yz: slope): no edges along its grid, unlike value noise.
// The grid point's direction from an integer hash of its whole coordinates. (detail_hash of the point as a float, far
// from the map's origin, came out different for the same point seen from the two cells beside it, the products there
// above 100000 and rounded differently at each call: the noise jumped along some of its grid lines, straight lines
// across the ground wherever it moved the cells' uneven edge, owner 18/11.)
vec2 detail_grad(ivec2 i) {
	uint h = uint(i.x) * 1597334677u ^ uint(i.y) * 3812015801u;
	h ^= h >> 16u;
	h *= 2246822519u;
	h ^= h >> 13u;
	float a = float(h >> 8u) * (6.2831853 / 16777216.0);
	return vec2(cos(a), sin(a));
}

vec3 detail_noised(vec2 p) {
	vec2 pf = floor(p);
	ivec2 i = ivec2(pf);
	vec2 f = p - pf;
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	vec2 du = 30.0 * f * f * (f * (f - 2.0) + 1.0);
	vec2 ga = detail_grad(i);
	vec2 gb = detail_grad(i + ivec2(1, 0));
	vec2 gc = detail_grad(i + ivec2(0, 1));
	vec2 gd = detail_grad(i + ivec2(1, 1));
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


// Live, modern look: the game's ground is strongly contrasted texels (light and dark grains side by side); smoothed
// between texels where each covers many pixels, next to the eye, they ran into marbled blotches (in the game's own
// colours: under the viewer's warm light and saturation of before they showed far less). Up close each texel keeps
// its colour, blended into the next over texel_soft of a texel only; where a texel is smaller than that on the
// screen it is the plain smooth filter (1: always).
uniform float texel_soft = 0.35;
// and the cells blended over a narrow band only (blend_width: half the ground was two or four tiles laid over each
// other, their grains doubled)
uniform float blend_live = 0.08;

vec3 tile_px(vec2 uv, float layer, vec2 dx, vec2 dy) {
	vec2 p = uv * 64.0 - 0.5;
	vec2 i = floor(p);
	vec2 w = max(vec2(game_colours ? texel_soft : 1.0), (abs(dx) + abs(dy)) * 64.0);
	vec2 fr = clamp((p - i - 0.5) / w + 0.5, 0.0, 1.0);
	return textureGrad(tiles_lit_soft, vec3((i + 0.5 + fr) / 64.0, layer), dx, dy).rgb;
}

// a ground cell's tile and its texture coordinates at a position beyond its edges (mirrored), turned as the cell's
vec2 cell_uv(vec2 cell, vec2 q, inout vec2 dx, inout vec2 dy, out float tile) {
	cell = clamp(cell, vec2(0.0), vec2(grid_n - 2.0));
	vec4 t = texture(tilemap, (cell + 0.5) / grid_n);
	tile = floor(t.r * 255.0 + 0.5);
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
	return uv;
}

// a ground cell's tile at a position beyond its edges (mirrored)
vec3 cell_tile(vec2 cell, vec2 q, vec2 dx, vec2 dy, float loff) {
	float tile;
	vec2 uv = cell_uv(cell, q, dx, dy, tile);
	// clamped, not wrapped: uv stays in 0..1 (mirrored above), and a wrapping filter mixed the tile's opposite edge
	// into its border texels (a thin light line along the cells of two-material tiles)
	if (per_index) {
		return tile_px(uv, tile + loff, dx, dy);
	}
	return textureGrad(tiles_soft, vec3(uv, tile), dx, dy).rgb;
}

// The modern look's light: the row (0 = full light, 15 = darkest; with a fraction) of the map's light vl as a smooth
// slope from one point of the grid to the next, each point exact at its own level's row (light x.5). The game takes
// floor(vl): its row changes along straight lines across the triangles, a step of brightness at each (old school keeps
// it); in the modern look they were straight lines over the ground, owner 18/11.
float light_smooth(float vl) {
	return clamp(15.0 - (vl - 0.5), 0.0, 15.0);
}

// a row's brightness, between two rows
float row_mix(float r) {
	r = clamp(r, 0.0, 15.0);
	int r0 = min(int(floor(r)), 15);
	return mix(light_rows[r0], light_rows[min(r0 + 1, 15)], r - float(r0));
}

// cliffs (an extra, on unless TN_FX_CLIFFS=0): the tiles are laid on the map from above, one a cell: on a steep
// face a cell's 64 texels run down the whole height of the cliff, stretched into streaks. With this on, the faces
// steeper than CLIFF_FROM are textured from the side instead, along the slope (the same tile of the cell, a texel as
// big as on flat ground, across the face and up it, from the side the face looks to: both sides weighed by the
// normal), blended in up to CLIFF_FULL; flat ground and gentle slopes are untouched. The light row, the burn, the
// haze: the same as the ground's.
uniform bool cliffs = false;
const float CLIFF_FROM = 0.74;        // the normal's height where it begins (a 42 degree slope)
const float CLIFF_FULL = 0.56;        // and where the face is all side-textured (56 degrees)

// a coordinate folded into 0..1 and back (no seam where a tile meets itself)
vec2 cliff_fold(vec2 q) {
	return 1.0 - abs(1.0 - mod(q, 2.0));
}

// the tile of a cell seen from the side: q = (along the face, up it) in cells, dq its derivatives
vec3 cliff_tile(vec2 cell, vec2 q, vec2 dqx, vec2 dqy, float loff) {
	cell = clamp(cell, vec2(0.0), vec2(grid_n - 2.0));
	float tile = floor(texture(tilemap, (cell + 0.5) / grid_n).r * 255.0 + 0.5);
	vec2 uv = cliff_fold(q) * (63.0 / 64.0) + 0.5 / 64.0;
	if (per_index) {
		return textureGrad(tiles_lit_soft, vec3(uv, tile + loff), dqx, dqy).rgb;
	}
	return textureGrad(tiles_soft, vec3(uv, tile), dqx, dqy).rgb;
}

uniform float blend_width = 0.3;      // blend between two cells (share of a cell each side)

// a cell's tile, its mean colour (its smallest level); built: 1 for built ground (tile_built)
vec3 cell_mean(vec2 cell, out float built) {
	cell = clamp(cell, vec2(0.0), vec2(grid_n - 2.0));
	float tile = floor(texture(tilemap, (cell + 0.5) / grid_n).r * 255.0 + 0.5);
	built = texelFetch(tile_built, ivec2(int(tile), 0), 0).r;
	return textureLod(tiles, vec3(0.5, 0.5, tile), 6.0).rgb;
}

// two tiles of the same kind of ground (their mean colours close: the snow's, the sand's, the grass's variants, 0.002
// to 0.044 apart; sand against concrete, a road or a stripe: 0.09 and more): 1, else 0
float same_kind(vec3 m1, vec3 m2) {
	return 1.0 - smoothstep(0.06, 0.12, distance(m1, m2));
}

// the four cells around the point blended into each other along an uneven edge (no more square tiles), each pair of
// neighbours on its own: tiles of the same kind of ground blend, different ones (sand against a concrete pad, a road, a
// striped line) meet on the cell's own straight edge as the game draws it (the uneven edge ran a third of a cell into
// the next one: the sand spilled over the concrete pads, training 2). (One different tile among the four made all four
// meet on square edges: straight seams between snow and snow wherever a rock tile was near, owner 18/11.) Built ground
// (concrete, base floors) never blends, even with itself: each slab on its own square, its drawn joint as the game's
// (blended, the joint was drawn again along the uneven edge, mirrored: doubled, thicker, owner 18/11).
// w: the four cells' shares (for the grain); built: the share of built ground here.
vec3 cells_blend(vec2 q, vec2 dx, vec2 dy, vec3 wp, float loff, out vec4 w, out float built) {
	vec2 qc = q - 0.5;
	vec2 c0 = floor(qc);
	vec2 fb = fract(qc);
	vec4 bt;
	vec3 ma = cell_mean(c0, bt.x);
	vec3 mb = cell_mean(c0 + vec2(1.0, 0.0), bt.y);
	vec3 mc = cell_mean(c0 + vec2(0.0, 1.0), bt.z);
	vec3 md = cell_mean(c0 + vec2(1.0, 1.0), bt.w);
	vec4 nat = 1.0 - bt;
	float sab = same_kind(ma, mb) * nat.x * nat.y;
	float scd = same_kind(mc, md) * nat.z * nat.w;
	float sac = same_kind(ma, mc) * nat.x * nat.z;
	float sbd = same_kind(mb, md) * nat.y * nat.w;
	float bw = game_colours ? blend_live : blend_width;
	// the uneven edge's reach stops short of the cells' centres (where the next four take over: a share left there was
	// a faint step)
	vec2 jit = (vec2(detail_noised(wp.xz * 0.7).x, detail_noised(wp.xz * 0.7 + 31.7).x) - 0.5) * 2.0 * clamp(0.5 - bw, 0.0, 0.25);
	float bab = max(bw * sab, 0.002);
	float bcd = max(bw * scd, 0.002);
	float wab = smoothstep(0.5 - bab, 0.5 + bab, fb.x + jit.x * sab);
	float wcd = smoothstep(0.5 - bcd, 0.5 + bcd, fb.x + jit.x * scd);
	float sv = mix(sac, sbd, 0.5 * (wab + wcd));
	float bv = max(bw * sv, 0.002);
	float wy = smoothstep(0.5 - bv, 0.5 + bv, fb.y + jit.y * sv);
	w = vec4((1.0 - wab) * (1.0 - wy), wab * (1.0 - wy), (1.0 - wcd) * wy, wcd * wy);
	built = dot(w, bt);
	vec3 a = cell_tile(c0, q, dx, dy, loff);
	vec3 b = cell_tile(c0 + vec2(1.0, 0.0), q, dx, dy, loff);
	vec3 c = cell_tile(c0 + vec2(0.0, 1.0), q, dx, dy, loff);
	vec3 d = cell_tile(c0 + vec2(1.0, 1.0), q, dx, dy, loff);
	return mix(mix(a, b, wab), mix(c, d, wcd), wy);
}

// the grain (the same tile 4 times finer) of the four cells around the point, by their shares: its brightness against
// the tile's mean (the cell's own only, it changed at every cell edge: a straight line along each up close)
float cells_grain(vec2 q, vec2 dx, vec2 dy, vec4 w) {
	vec2 c0 = floor(q - 0.5);
	float gsum = 0.0;
	for (int k = 0; k < 4; k++) {
		float wk = k == 0 ? w.x : (k == 1 ? w.y : (k == 2 ? w.z : w.w));
		if (wk > 0.001) {
			vec2 cell = c0 + vec2(float(k & 1), float(k >> 1));
			vec2 kdx = dx;
			vec2 kdy = dy;
			float tile;
			vec2 uv = cell_uv(cell, q, kdx, kdy, tile);
			vec3 fine = textureGrad(tiles_wrap, vec3(uv * 4.0, tile), kdx * 4.0, kdy * 4.0).rgb;
			vec3 avg = textureLod(tiles, vec3(0.5, 0.5, tile), 6.0).rgb;
			gsum += wk * clamp(dot(fine, vec3(0.3, 0.59, 0.11)) / max(dot(avg, vec3(0.3, 0.59, 0.11)), 0.02), 0.4, 1.8);
		}
	}
	return gsum;
}

// the ground more credible without tessellation: wide patches lighter / darker, warmer / cooler (the tiles' pattern
// no longer repeats), a fine detail chosen by the ground's colour (near the eye only), rock on the steep slopes
uniform float macro_amount = 0.16;
uniform float fine_amount = 0.24;
uniform float slope_rock = 0.35;
uniform float sparkle = 0.0;           // snow: crystals catching the light up close (the ice planet)

// fine details, around 0 (-0.5 .. 0.5): grass (tufts, blades each tuft its own way), sand (wind ripples), rock
// (grain), snow (soft drifts)
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

// (no dark veins any more: thin dark curves wherever the ground is grey, roads and pads too, that the game has
// nowhere, owner 18/11)
float rock_fine(vec2 p) {
	return (detail_noised(p * 6.0).x - 0.5) * 0.5 + (detail_noised(p * 22.0).x - 0.5) * 0.35;
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

// the burn picture's palette index at grid position q (0: none there)
int burn_at(vec2 q) {
	if (!has_burn) {
		return 0;
	}
	vec2 cell = floor(q);
	if (cell.x < 0.0 || cell.y < 0.0 || cell.x > grid_n - 2.0 || cell.y > grid_n - 2.0) {
		return 0;
	}
	int k = int(texelFetch(burn_map, ivec2(cell), 0).r * 255.0 + 0.5);
	if (k == 0) {
		return 0;
	}
	ivec2 tx = clamp(ivec2(floor(fract(q) * 64.0)), ivec2(0), ivec2(63));
	return int(texelFetch(burn_idx, ivec3(tx, k - 1), 0).r * 255.0 + 0.5);
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
			return tile_px(uv * (63.0 / 64.0) + 0.5 / 64.0, tile + loff, dx, dy);
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
	} else if (tn_ir < 0.5) {
		// the lights of the shots (an extra, fx_lights.gd: no other light stands on a map), on the ground's own colour
		// (ALBEDO holds shadow_dark of it)
		DIFFUSE_LIGHT += LIGHT_COLOR * ATTENUATION * max(dot(NORMAL, LIGHT), 0.0) / (PI * shadow_dark);
	}
}

void fragment() {
	// gradients from the continuous grid position: no mip seams at cell borders; the plain mip choice (sharper, the
	// ground shimmered as the view turned, worse through the game's palette)
	vec2 dx = dFdx(g);
	vec2 dy = dFdy(g);
	vec3 n_geo = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float vl = vlight;
	float cloud_cs = 0.0;          // modern look: the rows a cloud's shadow takes, as a smooth share (see below)
	if (cloud_shadows) {
		vec3 up = wpos + cloud_sun.xyz * max(cloud_sun.w - wpos.y, 0.0) / cloud_sun.y;   // where the sun's ray meets the ceiling
		// whole rows, under the thickest 45 % of the sky one, under its thickest 20 % two: the steps of the ground's own
		// light stay where they are. (A share of a row, taken smoothly, moved every one of those steps as the clouds
		// drifted: waves running over the ground and the cliffs while the player stood still.)
		// The modern look: the same up to two rows, but taken smoothly over a wide band of the cover (soft patches with
		// gradual edges; whole rows there drew large dark zones with hard straight edges over the hills, owner 18/11).
		// The shadows now creep as slowly as the clouds seem to (viewer.gd _cloud_shadows_drift): no waves.
		float cover = texture(cloud_cover, (up.zx + cloud_off) / 256.0).r;
		if (modern) {
			cloud_cs = min(cloud_rows, smoothstep(0.35, 0.75, cover) + smoothstep(0.65, 0.95, cover));
		} else {
			vl -= min(cloud_rows, step(0.55, cover) + step(0.8, cover));
		}
	}
	int frow = 15 - clamp(int(floor(vl)), 0, 15);           // the row's file row (0 = full light)
	float row_light = per_index ? 1.0 : light_rows[frow];
	float loff = float(frow) * tile_count;
	bool ir = tn_ir > 0.5 && has_ir;
	if (game_colours && per_index && has_haze_lut && (!modern || ir)) {
		// the haze row: the one whose share of haze is the modern look's at this distance (tn_haze: 0.70 at the far
		// end), not the game's own level (its row 15 is all haze from 295 units on: the far hills a flat wall)
		int lv = 0;
		if (tn_haze_range.w > 0.5 && tn_haze_range.w < 1.5 && (CAMERA_VISIBLE_LAYERS & (1u << 16u)) != 0u) {
			vec2 dd = abs(wpos.xz - CAMERA_POSITION_WORLD.xz);
			float l = clamp(16.0 * (1.0 - exp(-max(max(dd.x, dd.y) - 20.0, 0.0) / tn_haze_range.x)) - 0.5, 0.0, 15.0);
			float a = (tn_haze_range.y + tn_haze_range.z * l) * l;
			for (int k = 1; k < 16; k++) {
				if (ROW_SHARE[k] - 0.5 * (ROW_SHARE[k] - ROW_SHARE[k - 1]) <= a) {
					lv = k;
				}
			}
		}
		// the texels this pixel covers (an old school pixel: about 2 window pixels): its level from the footprint's
		// narrow side, up to 4 texels along its long side, their palette colours averaged (one level from its long side,
		// as before, made the far ground one flat colour per cell at a grazing angle: the far hills simplified)
		// (cliffs, an extra: a steep face takes its texels from the side, see cliff_tile; one or the other here, every
		// pixel a colour of the palette)
		bool side = cliffs && n_geo.y < 0.5 * (CLIFF_FROM + CLIFF_FULL);
		vec2 pq = g;
		if (side) {
			pq = vec2(abs(n_geo.x) > abs(n_geo.z) ? g.y : g.x, wpos.y / step_size);
		}
		vec2 pdx = dFdx(pq);
		vec2 pdy = dFdy(pq);
		vec2 ex = pdx * 128.0;
		vec2 ey = pdy * 128.0;
		float lx = length(ex);
		float ly = length(ey);
		vec2 major = lx > ly ? pdx : pdy;
		float n = clamp(ceil(max(lx, ly) / max(min(lx, ly), 1e-6)), 1.0, 4.0);
		int lod = clamp(int(floor(log2(max(max(lx, ly) / n, 1.0)))), 0, 6);
		int sz = 64 >> lod;
		vec3 acc = vec3(0.0);
		for (int s = 0; s < 4; s++) {
			if (float(s) >= n) {
				break;
			}
			vec2 q = pq + major * ((float(s) + 0.5) / n - 0.5);
			vec2 cell = clamp(floor(side ? g : q), vec2(0.0), vec2(grid_n - 2.0));
			vec2 f = clamp(side ? cliff_fold(q) : q - cell, 0.0, 0.99999);
			vec4 t = texture(tilemap, (cell + 0.5) / grid_n);
			int tile = int(floor(t.r * 255.0 + 0.5));
			int rot = side ? 0 : int(floor(t.g * 255.0 + 0.5));
			vec2 uv = f;
			if (rot == 1) {
				uv = vec2(f.y, 1.0 - f.x);
			} else if (rot == 2) {
				uv = 1.0 - f;
			} else if (rot == 3) {
				uv = vec2(1.0 - f.y, f.x);
			}
			ivec2 tx = clamp(ivec2(floor(uv * float(sz))), ivec2(0), ivec2(sz - 1));
			int i0 = int(texelFetch(tiles_idx, ivec3(tx, tile), lod).r * 255.0 + 0.5);
			int bi = burn_at(side ? g : q);
			if (bi != 0) {
				i0 = bi;                  // (a burnt square: the burn picture's texel, through the same rows)
			}
			if (ir) {                     // infrared: table 59 of the hazed texel, no light row (0x2B5643, remap loop)
				int ih = int(texelFetch(haze_lut_idx, ivec2(i0, lv), 0).r * 255.0 + 0.5);
				acc += texelFetch(ir_lut, ivec2(ih, 0), 0).rgb;
			} else {
				int i1 = int(texelFetch(shade_idx, ivec2(i0, frow), 0).r * 255.0 + 0.5);
				acc += texelFetch(haze_lut, ivec2(i1, lv), 0).rgb;
			}
		}
		vec3 c = tn_game_colour(acc / n);
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
		vec4 cw;                             // the four cells' shares
		float cbuilt;                        // and the share of built ground among them
		float rsm = light_smooth(vl);
		if (modern && per_index) {
			// the modern look, tiles lit through the palette's rows: between the rows of the two light levels around
			// (light_smooth), each texel's colour in both rows mixed (the rows change the hue too: from one row only, the
			// step stayed as a line of colour)
			// (the second row only where the light is between two rows: none where the points around share a level)
			float ra = floor(rsm + 0.001);
			float rf = max(rsm - ra, 0.0);
			col = cells_blend(g, dx, dy, wpos, ra * tile_count, cw, cbuilt);
			if (rf > 0.001) {
				col = mix(col, cells_blend(g, dx, dy, wpos, min(ra + 1.0, 15.0) * tile_count, cw, cbuilt), rf);
			}
		} else {
			col = cells_blend(g, dx, dy, wpos, loff, cw, cbuilt);   // cells blended
		}
		float cliff = 0.0;                   // how much of this pixel is a cliff textured from the side
		if (cliffs) {
			float steep = 1.0 - smoothstep(CLIFF_FULL, CLIFF_FROM, n_geo.y);
			cliff = steep;
			if (steep > 0.0) {
				float up = wpos.y / step_size;
				vec2 qx = vec2(g.y, up);                // a face looking along x: across it runs the map's y
				vec2 qz = vec2(g.x, up);
				float wz = n_geo.z * n_geo.z / max(n_geo.x * n_geo.x + n_geo.z * n_geo.z, 1e-6);
				// the four cells around, blended as on the flat (cells_blend), each seen from both sides
				vec2 qc = g - 0.5;
				vec2 c0 = floor(qc);
				vec2 jit = vec2(detail_noised(wpos.xz * 0.7).x, detail_noised(wpos.xz * 0.7 + 31.7).x) - 0.5;
				vec2 fw = smoothstep(0.5 - blend_width, 0.5 + blend_width, clamp(fract(qc) + jit * 0.5, 0.0, 1.0));
				vec3 side = vec3(0.0);
				for (int k = 0; k < 4; k++) {
					vec2 o = vec2(float(k & 1), float(k >> 1));
					float wk = (o.x > 0.5 ? fw.x : 1.0 - fw.x) * (o.y > 0.5 ? fw.y : 1.0 - fw.y);
					if (wk > 0.003) {
						side += wk * mix(cliff_tile(c0 + o, qx, dFdx(qx), dFdy(qx), loff),
								cliff_tile(c0 + o, qz, dFdx(qz), dFdy(qz), loff), wz);
					}
				}
				col = mix(col, side, steep);
			}
		}
		int bi = burn_at(g);
		if (bi != 0) {                       // a burnt square: the burn picture's colour, lit by the same row
			int bl = per_index ? int(texelFetch(shade_idx, ivec2(bi, frow), 0).r * 255.0 + 0.5) : bi;
			col = tn_haze_linear(texelFetch(burn_pal, ivec2(bl, 0), 0).rgb);
		}
		// grain: the same tile 4 times finer modulates the brightness up close (grass blades, dirt streaks); its mips
		// fade it to nothing further away, so it does not shimmer
		// (modern look: the four cells' grains by their shares, as their colours, cells_grain; wrapped: no seams)
		float grain_k = GRAIN * (1.0 - smoothstep(0.06, 0.12, tpp)) * (1.0 - cliff);   // (the grain is laid from above too)
		if (grain_k > 0.0) {
			float gain;
			if (modern) {
				gain = cells_grain(g, dx, dy, cw);
			} else {
				vec3 fine = textureGrad(tiles, vec3(fract(uv * 4.0), tile), du * 4.0, dv * 4.0).rgb;
				vec3 avg = textureLod(tiles, vec3(0.5, 0.5, tile), 6.0).rgb;
				gain = clamp(dot(fine, vec3(0.3, 0.59, 0.11)) / max(dot(avg, vec3(0.3, 0.59, 0.11)), 0.02), 0.4, 1.8);
			}
			col *= mix(1.0, gain, grain_k);
		}
		if (has_relief && modern) {          // (modern look only: the game's ground has no light but its levels)
			col *= texture(relief, (g + 0.5) / grid_n).r + 0.5;
		}
		{                                    // wide patches, the fine detail up close, rock on the slopes
			float mac = detail_noised(wpos.xz * 0.018 + 3.1).x * 0.65 + detail_noised(wpos.xz * 0.006 + 7.7).x * 0.35;
			float mv = clamp((mac - 0.5) * 2.0, -1.0, 1.0);
			col *= 1.0 + mv * macro_amount;
			col *= mix(vec3(1.0), vec3(1.05, 1.0, 0.93), clamp(mv, 0.0, 1.0) * macro_amount * 2.0);
			float near = 1.0 - smoothstep(4.0, 40.0, length(CAMERA_POSITION_WORLD - wpos));
			// (not on built ground: the slabs keep the game's own picture, no rock grain over them)
			if (near > 0.0 && cbuilt < 0.999) {
				col *= 1.0 + ground_fine(wpos.xz, col) * fine_amount * 2.0 * near * (1.0 - cbuilt);
			}
			vec3 nwg = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
			float steep = 1.0 - smoothstep(0.55, 0.85, nwg.y);
			float lc = dot(col, vec3(0.3, 0.59, 0.11));
			col = mix(col, vec3(lc) * vec3(0.95, 0.93, 0.9) * 0.78, steep * slope_rock * float(modern));
			if (sparkle > 0.0 && near > 0.0) {
				// only the crystals the picture resolves (more than 1.5 to 3 pixels each): smaller, at a grazing angle or far
				// off, they came and went with the least move of the view, rows of white dashes flickering over the ground
				vec2 cell = wpos.xz * 40.0;
				float seen = 1.0 - smoothstep(0.35, 0.7, max(length(dFdx(cell)), length(dFdy(cell))));
				// on the snow and the ice only (pale ground): on the planet's bare rock they were white dashes with no cause.
				// (The cells counted from 0 every 1024: far from the map's origin the hash of three cells in a row came out
				// the same, dashes by threes.)
				float h = detail_hash(mod(floor(cell), 1024.0) + 0.37);
				EMISSION += vec3(1.0, 0.98, 0.95) * step(0.996, h) * sparkle * near * near * seen * smoothstep(0.5, 0.7, lc);
			}
		}
		ALBEDO = col;
		ROUGHNESS = 1.0;
		float bump_k = modern ? bump * (1.0 - smoothstep(0.25, 0.5, tpp)) * (1.0 - cliff) : 0.0;
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
		if (modern) {
			// the modern look: the map's light as a smooth slope between its rows (light_smooth), plus a cloud's soft
			// shadow, cloud_cs more rows: against the row the colour above has (tiles through the palette: already the
			// smooth one; else the row frow, row_light)
			float l0 = per_index ? row_mix(rsm) : light_rows[frow];
			float l1 = row_mix(rsm + cloud_cs);
			lit *= l0 > 0.001 ? clamp(l1 / l0, 0.0, 2.0) : 1.0 - 0.12 * cloud_cs;
		} else if (cloud_cs > 0.0) {         // a cloud's soft shadow: the light of cloud_cs more rows, between two rows
			float fr = float(frow) + cloud_cs;
			int r0 = min(int(floor(fr)), 15);
			float l1 = mix(light_rows[r0], light_rows[min(r0 + 1, 15)], fract(fr));
			lit *= light_rows[frow] > 0.001 ? clamp(l1 / light_rows[frow], 0.0, 1.0) : 1.0 - 0.12 * cloud_cs;
		}
		vec3 glow = EMISSION;
		// hazed as the game does (tn_haze.gdshaderinc). ALBEDO only serves the shadows (light()): what a full shadow
		// takes away, down to the hazed colour of the shaded ground
		vec3 hz = tn_haze(lit, wpos, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
		EMISSION = hz + glow;
		ALBEDO = hz - tn_haze(lit * (1.0 - shadow_dark), wpos, CAMERA_POSITION_WORLD, CAMERA_VISIBLE_LAYERS);
	}
}
