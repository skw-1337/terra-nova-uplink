// Water: the planet's sky (the game's cloud texture, as in sky.gdshader) mirrored on small moving ripples, more
// of it at grazing angles (Fresnel), over a deep blue; unlit like the sky it reflects.
// Old school (as the game): the sky only near the eye, beyond a flat colour (the mean of the planet's water tiles).
// Modern: the sky mirrored all over (sky_common: the same sky as above), the sun's glint, the water's own colour deep.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

#include "res://sky_common.gdshaderinc"

uniform sampler2D clouds : source_color, filter_linear_mipmap, repeat_enable;
uniform sampler2D clouds_soft : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool has_clouds = true;
uniform vec3 haze : source_color = vec3(0.7, 0.76, 0.84);
uniform vec3 light : source_color = vec3(0.91, 0.94, 0.97);
uniform float cloud_scale = 0.22;
uniform float cloud_px = 44.0;
uniform float cloud_par = 1.0;
uniform vec2 cloud_off = vec2(0.0);
uniform vec3 sun_dir = vec3(0.0, 0.7, 0.7);    // towards the sun
uniform float desat = 1.0;                     // live mode: undoes the view's saturation boost, like the sky
uniform bool modern = false;
uniform vec3 deep : source_color = vec3(0.08, 0.2, 0.4);
uniform vec3 far_tint : source_color = vec3(0.29, 0.38, 0.35);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 v = normalize(wpos - CAMERA_POSITION_WORLD);
	float dist = length(wpos - CAMERA_POSITION_WORLD);
	vec2 p = wpos.xz;
	float t = TIME;
	// slope of a few crossing waves (calmer far away: finer than a pixel they only shimmered)
	float amp = modern ? 0.06 / (1.0 + dist * 0.02) : 0.03;
	vec2 g = amp * vec2(cos(p.x * 1.7 + t * 1.3) + 0.6 * cos((p.x + p.y) * 2.9 - t * 1.9),
			cos(p.y * 2.1 - t * 1.1) + 0.5 * cos((p.x - p.y) * 3.7 + t * 2.3));
	if (modern) {
		g = tn_waves(p, t, dist);
	}
	vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
	vec3 r = reflect(v, n);
	r.y = max(r.y, modern ? 0.07 : 0.02);
	float cosv = clamp(dot(-v, n), 0.0, 1.0);
	if (modern) {
		vec3 sky = tn_sky(r, wpos, clouds_soft, has_clouds, light, haze, cloud_px, cloud_par, cloud_off, vec3(0.0, -1.0, 0.0));
		sky = mix(vec3(dot(sky, vec3(0.299, 0.587, 0.114))), sky, desat);
		float fres = 0.04 + 0.96 * pow(1.0 - cosv, 5.0);
		vec3 col = mix(far_tint * 0.5, sky * mix(vec3(1.0), far_tint * 1.6, 0.35), clamp(0.2 + 0.55 * fres, 0.0, 0.75));
		col += vec3(1.0, 0.95, 0.85) * pow(max(dot(r, sun_dir), 0.0), 900.0) * 1.2;
		ALBEDO = col;
		ALPHA = mix(0.9, 1.0, fres);
	} else {
		vec3 sky = haze;
		if (has_clouds) {
			vec2 uv = r.xz / max(r.y, 0.05) * cloud_scale;
			sky = mix(haze, texture(clouds, uv).rgb, smoothstep(0.0, 0.28, r.y));
		}
		float fres = 0.08 + 0.92 * pow(1.0 - cosv, 4.0);
		float k = clamp(0.15 + 0.3 * fres, 0.0, 0.42);  // a hint of sky, a little more at grazing angles
		vec3 col = mix(deep, sky, k);
		// the game reflects the sky only near the eye (~3.5 units): beyond, a flat colour (the mean of the planet's water
		// tiles, set by the viewer), a sharp change
		float far_k = smoothstep(2.5, 4.0, dist);
		ALBEDO = mix(col, far_tint, far_k);
		ALPHA = mix(0.82, 0.96, fres);
	}
}
