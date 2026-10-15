// Water: the planet's sky (the game's cloud texture, as in sky.gdshader) mirrored on small moving ripples, more
// of it at grazing angles (Fresnel), over a deep blue, a grey teal far off; unlit like the sky it reflects.
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform sampler2D clouds : source_color, filter_linear_mipmap, repeat_enable;
uniform bool has_clouds = true;
uniform vec3 haze : source_color = vec3(0.7, 0.76, 0.84);
uniform float cloud_scale = 0.22;
uniform vec3 deep : source_color = vec3(0.08, 0.2, 0.4);
uniform vec3 far_tint : source_color = vec3(0.29, 0.38, 0.35);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 v = normalize(wpos - CAMERA_POSITION_WORLD);
	vec2 p = wpos.xz;
	float t = TIME;
	// slope of a few crossing waves
	vec2 g = 0.03 * vec2(cos(p.x * 1.7 + t * 1.3) + 0.6 * cos((p.x + p.y) * 2.9 - t * 1.9),
			cos(p.y * 2.1 - t * 1.1) + 0.5 * cos((p.x - p.y) * 3.7 + t * 2.3));
	vec3 n = normalize(vec3(-g.x, 1.0, -g.y));
	vec3 r = reflect(v, n);
	r.y = max(r.y, 0.02);
	vec3 sky = haze;
	if (has_clouds) {
		vec2 uv = r.xz / max(r.y, 0.05) * cloud_scale;
		sky = mix(haze, texture(clouds, uv).rgb, smoothstep(0.0, 0.28, r.y));
	}
	float cosv = clamp(dot(-v, n), 0.0, 1.0);
	float fres = 0.08 + 0.92 * pow(1.0 - cosv, 4.0);
	float k = clamp(0.15 + 0.3 * fres, 0.0, 0.42);  // a hint of sky, a little more at grazing angles
	vec3 col = mix(deep, sky, k);
	// the game reflects the sky only near the eye (~3.5 units): beyond, a flat grey teal (measured on the running game:
	// ~(75, 100, 94), a sharp change)
	float far_k = smoothstep(2.5, 4.0, length(wpos - CAMERA_POSITION_WORLD));
	ALBEDO = mix(col, far_tint, far_k);
	ALPHA = mix(0.82, 0.96, fres);
}
