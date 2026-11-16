// The planet's sky for the modern look (old school off), shared by the sky, the water and the water tiles of the
// ground so that what the water mirrors is the sky above it: the game's cloud texture filtered smoothly on a curved
// ceiling (it no longer stretches into endless streaks towards the horizon), a second, larger layer of the same
// texture against its tiling, fading into the haze low on the horizon, and the sun's glow.
// The desert missions' rippling clouds (0x2A6F38, span loop 0x2B2810): each texel row shifts its columns by a table
// entry (0x425200: row 0 of ripple) and each column its rows (0x425300: row 1), 0..28 texels, rebuilt every frame
// (viewer.gd _clouds_update); the lookups use the coordinates before the shift.
uniform sampler2D ripple : filter_nearest, repeat_enable;
uniform bool has_ripple = false;

vec2 tn_ripple(vec2 t) {
	if (!has_ripple) {
		return t;
	}
	float ta = texelFetch(ripple, ivec2(int(mod(floor(t.y), 256.0)), 0), 0).r * 255.0;
	float tb = texelFetch(ripple, ivec2(int(mod(floor(t.x), 256.0)), 1), 0).r * 255.0;
	return t + vec2(ta, tb);
}

vec3 tn_sky(vec3 d, vec3 eye, sampler2D tex, bool has_clouds, vec3 light, vec3 haze, float cloud_px, float cloud_par,
		vec2 cloud_off, vec3 sun) {
	vec3 horizon = mix(light, haze, 0.35);
	vec3 col = horizon;
	if (has_clouds) {
		float y = max(d.y, 0.0);
		vec2 t = tn_ripple(vec2(d.z, d.x) / (y + 0.12) * cloud_px * 1.12 + vec2(eye.z, eye.x) * cloud_par + cloud_off);
		vec3 c = texture(tex, t / 256.0).rgb;
		float big = dot(texture(tex, t / 704.0 + vec2(0.37, 0.61)).rgb, vec3(0.3, 0.59, 0.11));
		c *= 0.82 + 0.36 * big;                                   // the larger layer only shades it: no tiling
		float l = dot(c, vec3(0.3, 0.59, 0.11));
		c = clamp(mix(vec3(l), c, 1.25), 0.0, 1.5);           // a little more colour: deeper blue between
		col = mix(horizon, c, smoothstep(0.0, 0.3, y));
	} else {                                                      // no clouds (night, airless): black above the
		col = mix(horizon, vec3(0.0), smoothstep(0.0, 0.08, max(d.y, 0.0)));   // horizon, as the sky shows it
	}
	float s = max(dot(d, sun), 0.0);
	col += vec3(1.0, 0.95, 0.85) * (0.1 * pow(s, 8.0) + 0.25 * pow(s, 90.0));
	return col;
}

// Slope of the water's surface for the modern look: seven waves of different directions, lengths and speeds (two
// crossing waves made regular stripes), calmer far away where they would be finer than a pixel.
vec2 tn_waves(vec2 p, float t, float dist) {
	vec2 s = vec2(0.0);
	float a = 0.37;
	for (int i = 0; i < 7; i++) {
		float fi = float(i);
		vec2 dir = vec2(cos(a), sin(a));
		float f = 1.1 + fi * 0.73 + fract(fi * 0.618) * 0.9;     // cycles per unit
		float w = 0.9 / (1.0 + fi * 0.55);                       // longer waves are higher
		s += dir * w * cos(dot(p, dir) * f + t * (0.8 + 0.35 * fi) + fi * 1.7);
		a += 2.39996;                                            // golden angle: no two alike
	}
	return s * 0.045 / (1.0 + dist * 0.02);
}
