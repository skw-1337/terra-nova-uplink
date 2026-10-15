// Terra Nova ground: one 64x64 atlas tile per grid cell, turned by a quarter-turn count.
// tilemap: R = tile index, G = clockwise quarter turns (0-3), one texel per grid vertex.
shader_type spatial;
render_mode diffuse_burley, specular_disabled;

// nearest up close: the game's texels, crisp like the original; mipmapped further away: no shimmering
uniform sampler2DArray tiles : source_color, filter_nearest_mipmap_anisotropic, repeat_disable;
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
const vec3 WATER_FAR = vec3(0.14, 0.25, 0.21);    // the game's far water (before this viewer's light)
const float GRAIN = 0.55;
// relief: the hollows of the height map darker, its crests lighter (one texel per grid vertex, 0.5 = unchanged),
// and the tile's own picture as a bump map (its light parts stand out, lit by the sun)
uniform sampler2D relief : filter_linear, repeat_disable;
uniform bool has_relief = false;
uniform float bump = 0.035;   // world units of height per unit of brightness

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
	// grain: the same tile 4 times finer modulates the brightness up close (grass blades, dirt streaks); its mips
	// fade it to nothing further away, so it does not shimmer
	vec3 fine = textureGrad(tiles, vec3(fract(uv * 4.0), tile), du * 4.0, dv * 4.0).rgb;
	vec3 avg = textureLod(tiles, vec3(0.5, 0.5, tile), 6.0).rgb;
	float gain = dot(fine, vec3(0.3, 0.59, 0.11)) / max(dot(avg, vec3(0.3, 0.59, 0.11)), 0.02);
	col *= mix(1.0, clamp(gain, 0.4, 1.8), GRAIN * (1.0 - smoothstep(0.06, 0.12, tpp)));
	if (has_relief) {
		col *= texture(relief, (g + 0.5) / grid_n).r + 0.5;
	}
	ALBEDO = col;
	ROUGHNESS = 1.0;
	float bump_k = bump * (1.0 - smoothstep(0.25, 0.5, tpp));
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
		float fres = 0.08 + 0.92 * pow(1.0 - clamp(dot(-v, n), 0.0, 1.0), 4.0);
		float k = clamp(0.12 + 0.35 * fres, 0.0, 0.45);  // a hint of sky, a little more at grazing angles
		// the game reflects the sky only near the eye (~3.5 units): beyond, its water is a flat
		// grey teal (measured on the running game: ~(75, 100, 94) from ~3.5 units on, a sharp change)
		float far_k = smoothstep(2.5, 4.0, length(wpos - CAMERA_POSITION_WORLD));
		k *= 1.0 - far_k;
		ALBEDO = mix(ALBEDO * (1.0 - k), WATER_FAR, far_k);
		EMISSION = sky * k * reflect_gain;
	}
}
