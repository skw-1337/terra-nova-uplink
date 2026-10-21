// Terra Nova ground: one 64x64 atlas tile per grid cell, turned by a quarter-turn count.
// tilemap: R = tile index, G = clockwise quarter turns (0-3), one texel per grid vertex.
shader_type spatial;
render_mode diffuse_burley, specular_disabled;

#include "res://sky_common.gdshaderinc"

// nearest up close: the game's texels, crisp like the original; mipmapped further away: no shimmering
uniform sampler2DArray tiles : source_color, filter_nearest_mipmap_anisotropic, repeat_disable;
// modern look (old school off): the same tiles filtered smoothly, the game's big texels no longer blocks up close
uniform sampler2DArray tiles_soft : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2DArray tiles_wrap : source_color, filter_linear_mipmap_anisotropic, repeat_enable;   // its grain
uniform sampler2D tilemap : filter_nearest, repeat_disable;
uniform vec2 origin;          // world XZ of grid vertex (0, 0)
uniform float step_size;      // world units between grid vertices
uniform float grid_n;         // vertices per side
// lakes and sea drawn by water tiles: the planet's sky (the game's clouds, as in sky.gdshader) mirrored on moving
// ripples, added as light of its own (the ground's lighting does not dim a reflection)
uniform sampler2D water_tiles : filter_nearest;   // 64 x 1, red = 1 for a water tile
uniform sampler2D clouds : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_clouds = false;
uniform vec3 haze : source_color = vec3(0.7, 0.76, 0.84);
uniform float cloud_scale = 0.22;
uniform float reflect_gain = 1.0;
// modern look (old school off): the water tiles mirror the whole sky (sky_common), as the water plane does
uniform bool modern = false;
uniform sampler2D clouds_soft : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform vec3 light : source_color = vec3(0.91, 0.94, 0.97);
uniform float cloud_px = 44.0;
uniform float cloud_par = 1.0;
uniform vec2 cloud_off = vec2(0.0);
uniform vec3 sun_dir = vec3(0.0, 0.7, 0.7);
uniform float desat = 1.0;
// the game's far water: a flat colour, the mean of the planet's water tiles (blue on Panama, grey teal elsewhere)
uniform vec3 water_far : source_color = vec3(0.41, 0.54, 0.5);
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


// a ground cell's tile at a position beyond its edges (mirrored), and whether it is water
vec3 cell_tile(vec2 cell, vec2 q, vec2 dx, vec2 dy, out float wat) {
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
	wat = texture(water_tiles, vec2((tile + 0.5) / 64.0, 0.5)).r;
	return textureGrad(tiles_wrap, vec3(uv, tile), dx, dy).rgb;
}

uniform float blend_width = 0.3;      // blend between two cells (share of a cell each side)
uniform float shore_wobble = 0.35;    // shore: its wobble

// the four cells around the point blended into each other along an uneven edge (no more square tiles); wl = share
// of water, a rounded shore
vec3 cells_blend(vec2 q, vec2 dx, vec2 dy, vec3 wp, out float wl) {
	vec2 qc = q - 0.5;
	vec2 c0 = floor(qc);
	vec2 fb = fract(qc);
	vec2 jit = vec2(detail_noised(wp.xz * 0.7).x, detail_noised(wp.xz * 0.7 + 31.7).x) - 0.5;
	vec2 fw = smoothstep(0.5 - blend_width, 0.5 + blend_width, clamp(fb + jit * 0.5, 0.0, 1.0));
	float w00, w10, w01, w11;
	vec3 a = cell_tile(c0, q, dx, dy, w00);
	vec3 b = cell_tile(c0 + vec2(1.0, 0.0), q, dx, dy, w10);
	vec3 c = cell_tile(c0 + vec2(0.0, 1.0), q, dx, dy, w01);
	vec3 d = cell_tile(c0 + vec2(1.0, 1.0), q, dx, dy, w11);
	float wlin = mix(mix(w00, w10, fb.x), mix(w01, w11, fb.x), fb.y);   // water smoothed between the cells' centres
	float wob = (detail_noised(wp.xz * 0.45 + 7.1).x - 0.5) * shore_wobble + (detail_noised(wp.xz * 1.6 + 3.3).x - 0.5) * shore_wobble * 0.4;
	wl = smoothstep(0.4, 0.6, wlin + wob);
	return mix(mix(a, b, fw.x), mix(c, d, fw.x), fw.y);
}

varying vec2 g;
varying vec3 wpos;

// the ground's texel at grid position q (tile of its cell, turned), sharpened mip choice
vec3 ground_at(vec2 q, vec2 dx, vec2 dy, out vec2 uv, out float tile, out vec2 du, out vec2 dv) {
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
	if (modern) {        // texel centres to the cell's edges: no half-texel strip of the edge texel along each border
		return textureGrad(tiles_soft, vec3(uv * (63.0 / 64.0) + 0.5 / 64.0, tile), dx, dy).rgb;
	}
	return textureGrad(tiles, vec3(uv, tile), dx, dy).rgb;
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wpos = w;
	g = (w.xz - origin) / step_size;
}

void fragment() {
	// gradients from the continuous grid position: no mip seams at cell borders; the plain mip choice (sharper, the
	// ground shimmered as the view turned, worse through the game's palette)
	vec2 dx = dFdx(g);
	vec2 dy = dFdy(g);
	vec2 uv;
	float tile;
	vec2 du;
	vec2 dv;
	vec3 col = ground_at(g, dx, dy, uv, tile, du, dv);
	float l0 = dot(col, vec3(0.3, 0.59, 0.11));
	// texels per screen pixel: the grain and the bump only where a texel covers more than a pixel (finer, they
	// only added noise that shimmered as the view moved)
	float tpp = max(length(dFdx(g)), length(dFdy(g))) * 64.0;
	bool water = texture(water_tiles, vec2((tile + 0.5) / 64.0, 0.5)).r > 0.5;
	float wl = 0.0;
	col = cells_blend(g, dx, dy, wpos, wl);   // cells blended, rounded shore
	water = false;
	// grain: the same tile 4 times finer modulates the brightness up close (grass blades, dirt streaks); its mips
	// fade it to nothing further away, so it does not shimmer
	vec3 fine = modern ? textureGrad(tiles_wrap, vec3(uv * 4.0, tile), du * 4.0, dv * 4.0).rgb   // wrapped: no seams
			: textureGrad(tiles, vec3(fract(uv * 4.0), tile), du * 4.0, dv * 4.0).rgb;
	vec3 avg = textureLod(tiles, vec3(0.5, 0.5, tile), 6.0).rgb;
	float gain = dot(fine, vec3(0.3, 0.59, 0.11)) / max(dot(avg, vec3(0.3, 0.59, 0.11)), 0.02);
	col *= mix(1.0, clamp(gain, 0.4, 1.8), GRAIN * (1.0 - smoothstep(0.06, 0.12, tpp)));
	if (has_relief) {
		col *= texture(relief, (g + 0.5) / grid_n).r + 0.5;
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
	float bump_k = bump * (1.0 - smoothstep(0.25, 0.5, tpp)) * (1.0 - wl);
	if (modern) {        // across a cell border the next tile's texels made a step: a line along every border
		vec2 fe = fract(g);
		bump_k *= smoothstep(0.0, 0.06, min(min(fe.x, 1.0 - fe.x), min(fe.y, 1.0 - fe.y)));
	}
	if (!water && bump_k > 0.0) {
		// one texel further along x and along z: the brightness slope tilts the normal (faded by the mips far away)
		const float TEXEL = 1.0 / 64.0;
		vec2 uv2;
		float t2;
		vec2 du2;
		vec2 dv2;
		float l1 = dot(ground_at(g + vec2(TEXEL, 0.0), dx, dy, uv2, t2, du2, dv2), vec3(0.3, 0.59, 0.11));
		float l2 = dot(ground_at(g + vec2(0.0, TEXEL), dx, dy, uv2, t2, du2, dv2), vec3(0.3, 0.59, 0.11));
		vec2 slope = vec2(l1 - l0, l2 - l0) / (TEXEL * step_size) * bump_k;
		vec3 nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
		nw = normalize(nw - vec3(slope.x, 0.0, slope.y));
		NORMAL = normalize((VIEW_MATRIX * vec4(nw, 0.0)).xyz);
	}
	if (!water && detail > 0.0) {      // detail relief
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
		nwd = normalize(nwd - vec3(grad.x, 0.0, grad.y) * detail * (1.0 - wl));
		NORMAL = normalize((VIEW_MATRIX * vec4(nwd, 0.0)).xyz);
		ALBEDO *= clamp(1.0 + cav * cavity * (1.0 - wl), 0.5, 1.5);
	}
	if (wl > 0.001) {                   // water: waves, the sky mirrored (more at a grazing angle), the sun's glint; old school too
		vec3 v = normalize(wpos - CAMERA_POSITION_WORLD);
		float dist = length(wpos - CAMERA_POSITION_WORLD);
		vec2 sm = tn_waves(wpos.xz, TIME, dist);
		vec3 nm = normalize(vec3(-sm.x, 1.0, -sm.y));
		vec3 rm = reflect(v, nm);
		rm.y = max(rm.y, 0.07);
		vec3 skym = tn_sky(rm, wpos, clouds_soft, has_clouds, light, haze, cloud_px, cloud_par, cloud_off, vec3(0.0, -1.0, 0.0));
		skym = mix(vec3(dot(skym, vec3(0.299, 0.587, 0.114))), skym, desat);
		float fm = 0.04 + 0.96 * pow(1.0 - clamp(dot(-v, nm), 0.0, 1.0), 5.0);
		float km = clamp(0.25 + 0.6 * fm, 0.0, 0.85);
		vec3 deep = water_far * 0.55;
		ALBEDO = mix(ALBEDO, deep * (1.0 - km), wl);
		EMISSION = (skym * mix(vec3(1.0), water_far * 1.5, 0.3) * km +
				vec3(1.0, 0.95, 0.85) * pow(max(dot(rm, sun_dir), 0.0), 600.0) * 1.5) * wl;
		ROUGHNESS = mix(1.0, 0.2, wl);
	}
	if (water) {
		vec3 v = normalize(wpos - CAMERA_POSITION_WORLD);
		vec2 p = wpos.xz;
		float t = TIME;
		vec2 sl = 0.05 * vec2(cos(p.x * 1.7 + t * 1.3) + 0.6 * cos((p.x + p.y) * 2.9 - t * 1.9),
				cos(p.y * 2.1 - t * 1.1) + 0.5 * cos((p.x - p.y) * 3.7 + t * 2.3));
		vec3 n = normalize(vec3(-sl.x, 1.0, -sl.y));
		vec3 r = reflect(v, n);
		r.y = max(r.y, 0.02);
		vec3 sky = haze;
		if (has_clouds) {
			sky = mix(haze, texture(clouds, r.xz / max(r.y, 0.05) * cloud_scale).rgb, smoothstep(0.0, 0.28, r.y));
		}
		if (modern) {
			float dist = length(wpos - CAMERA_POSITION_WORLD);
			vec2 sm = tn_waves(p, t, dist);
			vec3 nm = normalize(vec3(-sm.x, 1.0, -sm.y));
			vec3 rm = reflect(v, nm);
			rm.y = max(rm.y, 0.07);              // not only the white horizon: the clouds above it
			vec3 skym = tn_sky(rm, wpos, clouds_soft, has_clouds, light, haze, cloud_px, cloud_par, cloud_off, vec3(0.0, -1.0, 0.0));
			skym = mix(vec3(dot(skym, vec3(0.299, 0.587, 0.114))), skym, desat);
			float fm = 0.04 + 0.96 * pow(1.0 - clamp(dot(-v, nm), 0.0, 1.0), 5.0);
			float km = clamp(0.2 + 0.55 * fm, 0.0, 0.75);
			ALBEDO = water_far * 0.5 * (1.0 - km);
			EMISSION = skym * mix(vec3(1.0), water_far * 1.6, 0.35) * km + vec3(1.0, 0.95, 0.85) * pow(max(dot(rm, sun_dir), 0.0), 900.0) * 1.2;
		} else {
		float fres = 0.08 + 0.92 * pow(1.0 - clamp(dot(-v, n), 0.0, 1.0), 4.0);
		float k = clamp(0.12 + 0.35 * fres, 0.0, 0.45);  // a hint of sky, a little more at grazing angles
		// the game reflects the sky only near the eye (~3.5 units): beyond, its water is a flat colour, the mean of
		// the planet's water tiles, unlit (Panama: its blue (117, 154, 202) and teal (100, 134, 131) texels)
		float far_k = smoothstep(2.5, 4.0, length(wpos - CAMERA_POSITION_WORLD));
		k *= 1.0 - far_k;
		ALBEDO = ALBEDO * (1.0 - k) * (1.0 - far_k);
		EMISSION = sky * k * reflect_gain + water_far * far_k;
		}
	}
}
