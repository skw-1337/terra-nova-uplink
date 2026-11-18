// The player's own suit as a solid (body_model.gd): each face dressed in the limb's picture taken from its side (the
// game's front, back, right and left views of the limb), lit by the scene's sun like the ground under it.
shader_type spatial;
render_mode cull_disabled;

uniform sampler2DArray views : source_color, filter_linear_mipmap, repeat_disable;   // (smoothed: seen this close)
uniform float view_count = 16.0;
uniform vec2 size = vec2(32.0, 32.0);        // the pictures' canvas (pixels)
uniform float a1 = 0.0;                      // joint a's row in it
instance uniform float mirror = 0.0;         // a left limb: the right one's pictures, its sides the other way
instance uniform vec2 fade_rows = vec2(0.0); // y > x: dissolved upwards from row y to row x of the canvas (the torso's top edge)
instance uniform float gain = 1.0;
instance uniform vec2 near_fade = vec2(0.0); // y > x: what is nearer the eye than y dissolves, gone at x (a piece swinging up under it)
instance uniform float back_dark = 0.0;     // > 0: the back picture darkened that much towards the armour's grey (the thighs')

varying vec3 lp;
varying vec3 ln;

void vertex() {
	lp = VERTEX;
	ln = NORMAL;
}

vec4 view_at(float layer, float col, float row) {
	return texture(views, vec3(clamp(col / size.x, 0.0, 0.999), clamp(row / size.y, 0.0, 0.999), layer));
}

void fragment() {
	vec3 p = lp;
	vec3 n = normalize(ln);
	if (mirror > 0.5) {
		p.z = -p.z;
		n.z = -n.z;
	}
	float row = p.y + a1;
	float half_w = size.x * 0.5;
	float front = min(8.0, view_count - 1.0);
	bool nine = view_count < 16.0;               // (a torso: its 9 views hold the right side only, mirrored for the left)
	vec4 cf = view_at(front, half_w - p.z, row);
	vec4 cb = view_at(0.0, half_w + p.z, row);
	vec4 cr = view_at(4.0, half_w + p.x, row);
	vec4 cl = nine ? view_at(4.0, half_w + p.x, row) : view_at(12.0, half_w - p.x, row);
	// (the thighs: their back and side pictures, light grey, read as padded shorts from above: towards the armour's grey)
	cb.rgb *= 1.0 - 0.5 * back_dark;
	cr.rgb *= 1.0 - 0.5 * back_dark;
	cl.rgb *= 1.0 - 0.5 * back_dark;
	float wf = pow(max(n.x, 0.0), 2.0) * step(0.5, cf.a);
	float wb = pow(max(-n.x, 0.0), 2.0) * step(0.5, cb.a);
	float wr = pow(max(n.z, 0.0), 2.0) * step(0.5, cr.a);
	float wl = pow(max(-n.z, 0.0), 2.0) * step(0.5, cl.a);
	float sum = wf + wb + wr + wl;
	vec3 c;
	if (sum < 1e-3) {                            // (an end, or between the pictures' outlines: the armour's dark edge colour)
		vec4 m = view_at(front, half_w - p.z, row);
		c = m.a > 0.5 ? m.rgb * 0.45 : vec3(0.06, 0.065, 0.07);
	} else {
		c = (cf.rgb * wf + cb.rgb * wb + cr.rgb * wr + cl.rgb * wl) / sum;
	}
	if (fade_rows.y > fade_rows.x) {
		float keep = smoothstep(fade_rows.x, fade_rows.y, row);
		vec2 q = floor(FRAGCOORD.xy);
		float d = fract(52.9829189 * fract(0.06711056 * q.x + 0.00583715 * q.y));
		if (d > keep) {
			discard;
		}
	}
	if (near_fade.y > near_fade.x) {
		float keep2 = smoothstep(near_fade.x, near_fade.y, length(VERTEX));
		vec2 q2 = floor(FRAGCOORD.xy);
		float d2 = fract(52.9829189 * fract(0.06711056 * q2.x + 0.00583715 * q2.y));
		if (d2 > keep2) {
			discard;
		}
	}
	ALBEDO = c * gain;
	ROUGHNESS = 0.8;
	SPECULAR = 0.25;
}
