// Planet sky: the game's cloud texture on a ceiling, as the game draws it (fitted on its picture, 60-80 % of the sky
// pixels exactly the texture's): 44 texels per unit of slope (a plane 44 units above the eye), columns along the
// world's y axis (Godot z), rows along x, one texel per unit the eye moves, shifted by the game's wind offset (live);
// lightening towards the horizon into the lightest cloud colour (measured: the game moves the texture's colours
// up its ramp there); airless worlds get the game's star field (SKY3 / SKY4 resource 154, a 512 x 320
// wrapping map), one map pixel per screen pixel of the game's 320-pixel-wide view: the map
// repeats 4 times around the horizon.
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

void sky() {
	vec3 d = EYEDIR;
	vec3 col = has_clouds ? light : haze;
	if (modern && has_clouds) {
		col = tn_sky(d, POSITION, clouds_soft, true, light, haze, cloud_px, cloud_par, cloud_off,
				LIGHT0_ENABLED ? LIGHT0_DIRECTION : vec3(0.0, 1.0, 0.0));
	} else if (d.y > 0.0) {
		if (has_clouds) {
			vec2 t = vec2(d.z, d.x) / max(d.y, 0.004) * cloud_px + vec2(POSITION.z, POSITION.x) * cloud_par + cloud_off;
			// share of the cloud's own colour, measured on the game's sky: 0.39 at 1.5 deg, 0.70 at 4, 0.85 at 6.5
			col = mix(light, texture(clouds, t / 256.0).rgb, 1.0 - exp(-(d.y + 0.005) / 0.062));
		} else {
			vec3 top = vec3(0.0);
			if (has_stars) {
				float az = atan(d.z, d.x) + PI;
				float el = asin(clamp(d.y, 0.0, 1.0));
				vec2 px = vec2(az / star_pixel, 320.0 - el / star_pixel);
				vec4 s = texelFetch(stars, ivec2(mod(floor(px), vec2(512.0, 320.0))), 0);
				top = s.a > 0.5 ? s.rgb : vec3(0.0);
			} else {
				float s2 = hash(floor(d * 420.0));
				top = s2 > 0.9975 ? vec3(0.55 + 0.45 * fract(s2 * 97.0)) : vec3(0.0);
			}
			col = mix(haze, top, smoothstep(0.0, 0.08, d.y));
		}
	}
	col = mix(vec3(dot(col, vec3(0.299, 0.587, 0.114))), col, desat);
	COLOR = col * gain;
}
