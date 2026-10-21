// Snow / rain around the camera (live mode, 'WTHR' from live_bridge.py). The game's weather is screen-space dots
// with a fake depth; here a MultiMesh of quads, one per flake: each flake has a fixed place in a box that moves with
// the camera (mod box), drifts with the wind and falls, so walking and turning give the real parallax. All in the
// vertex shader: no CPU work per frame. INSTANCE_CUSTOM = (seed x, y, z in 0-1, phase 0-1).
shader_type spatial;
render_mode unshaded, cull_disabled, shadows_disabled, fog_disabled, depth_draw_never, blend_mix;

uniform vec3 box = vec3(7.0, 5.0, 7.0);        // the volume around the camera (Godot axes, y up)
uniform vec3 drift = vec3(0.0, -1.0, 0.0);      // units per second: wind (x, z), fall (y < 0)
uniform float sway = 0.06;                      // flutter amplitude (the game's random sideways steps)
uniform float size = 0.03;                      // flake size (units)
uniform float stretch = 1.0;                    // rain: streaks along the fall
uniform vec4 color : source_color = vec4(0.92, 0.95, 1.0, 0.9);

varying vec2 uv;
varying float fade;

void vertex() {
	vec4 c = INSTANCE_CUSTOM;
	float ph = c.w;
	float spd = 0.6 + 0.8 * fract(ph * 7.31);    // the game: fall 1-4 at random per step
	vec3 p = c.xyz * box + drift * spd * TIME;
	p.x += sway * sin(TIME * (1.3 + ph) + ph * 6.2832);
	p.z += sway * cos(TIME * (1.1 + ph) + ph * 4.0);
	vec3 cam = CAMERA_POSITION_WORLD;
	vec3 rel = mod(p - cam, box) - box * 0.5;
	// fade at the box's walls (no popping where flakes wrap) and right in front of the lens
	fade = (1.0 - smoothstep(box.x * 0.5 - 1.2, box.x * 0.5, length(rel.xz)))
			* (1.0 - smoothstep(box.y * 0.5 - 0.8, box.y * 0.5, abs(rel.y)))
			* smoothstep(0.3, 0.9, length(rel));
	vec4 v = VIEW_MATRIX * vec4(cam + rel, 1.0);
	vec2 dir = (VIEW_MATRIX * vec4(normalize(drift + vec3(0.0, -0.001, 0.0)), 0.0)).xy;
	dir = length(dir) > 0.001 ? normalize(dir) : vec2(0.0, -1.0);
	vec2 side = vec2(-dir.y, dir.x);
	// no bigger than the game's nearest flakes (3 pixels of its 320: ~0.024 rad), however close
	float s = min(size * (0.7 + 0.6 * fract(ph * 3.7)), 0.024 * max(-v.z, 0.0));
	v.xy += side * VERTEX.x * s + dir * VERTEX.y * s * stretch;
	POSITION = PROJECTION_MATRIX * v;
	uv = VERTEX.xy * 2.0;
}

void fragment() {
	float r = stretch > 1.5 ? abs(uv.x) : length(uv);
	ALBEDO = color.rgb;
	ALPHA = color.a * fade * (1.0 - smoothstep(0.35, 1.0, r));
}
