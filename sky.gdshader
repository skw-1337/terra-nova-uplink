// Planet sky: the game's cloud texture on a curved ceiling (44 texels per unit of slope, one texel per unit the eye
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
uniform float cloud_px = 44.0;             // texels per unit of slope
uniform float cloud_par = 1.0;             // texels per world unit the camera moves
uniform vec2 cloud_off = vec2(0.0);        // texels (column, row): the game's wind offset
uniform float desat = 1.0;                 // live mode: undoes the view's saturation boost (the game's own colours)
uniform float gain = 1.0;                  // live mode: the game's sky is brighter than this viewer's
uniform float star_pixel = 0.00307;        // radians per star map pixel (TAU / 4 / 512)

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

// The planet's sky, the same in both looks: an atmosphere from deep at the zenith to pale at the horizon (from the
// planet's own colours), clouds told from the blue (the white part of the game's texture), lit on the sun's side and
// darker underneath, clear gaps at a large scale, a veil of haze low on the horizon, the sun with its halo.
uniform float cloud_cover = 0.8;           // more: more clouds
uniform vec3 zenith_tint : source_color = vec3(0.16, 0.34, 0.74);

vec3 planet_sky(vec3 d, vec3 eye, vec3 sun) {
	vec3 avg = textureLod(clouds_soft, vec2(0.5), 10.0).rgb;            // the planet's sky, on average
	vec3 horizon = mix(light, haze, 0.35);
	float y = max(d.y, 0.0);
	vec3 zenith = mix(avg, zenith_tint, 0.75);
	vec3 atmos = mix(horizon, zenith, pow(y, 0.5));
	float s = max(dot(d, sun), 0.0);
	atmos += vec3(1.0, 0.85, 0.65) * 0.12 * pow(s, 3.0) * (1.0 - y);     // the air lighter and warmer towards the sun
	vec2 t = vec2(d.z, d.x) / (y + 0.12) * cloud_px * 1.12 + vec2(eye.z, eye.x) * cloud_par + cloud_off;
	vec3 c = texture(clouds_soft, t / 256.0).rgb;
	float l = dot(c, vec3(0.3, 0.59, 0.11));
	float la = dot(avg, vec3(0.3, 0.59, 0.11));
	float big = dot(texture(clouds_soft, t / 1100.0 + vec2(0.37, 0.61)).rgb, vec3(0.3, 0.59, 0.11));
	float cover = smoothstep(la - 0.04, la + 0.22, l);                   // the texture's white: the clouds
	cover *= smoothstep(0.15, 0.75, (big - la) * 2.5 + 0.55 * cloud_cover);   // clear gaps at a large scale
	cover *= smoothstep(0.0, 0.12, y);
	float thick = smoothstep(la, la + 0.35, l);
	vec3 lit = light * 1.08 + vec3(1.0, 0.92, 0.8) * 0.35 * pow(s, 5.0);    // on the sun's side: lighter, a warm rim
	vec3 under = mix(light, avg, 0.55) * 0.72;                           // underneath: bluish grey
	vec3 cloud = mix(under, lit, 0.35 + 0.65 * (1.0 - thick) * 0.6 + 0.4 * pow(s, 2.0));
	vec3 col = mix(atmos, cloud, cover);
	col = mix(col, horizon, exp(-y * 14.0) * 0.75);                      // haze low on the horizon
	col += vec3(1.0, 0.93, 0.8) * (0.25 * pow(s, 60.0) + 1.6 * smoothstep(0.9993, 0.9997, s)) * (1.0 - 0.8 * cover);
	return col;
}

void sky() {
	vec3 d = EYEDIR;
	vec3 sun = LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.0, 1.0, 0.0);
	vec3 col = has_clouds ? planet_sky(d, POSITION, sun) : haze;
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
