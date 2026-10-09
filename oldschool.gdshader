// Old school mode (live mode, F12): the game's look over the 3D view. Its pixel grid (848 x 400 over the window,
// the game's HD screen), each pixel the mean of what it covers, and its palette (the planet's colours 17-255, those
// its 3D view is drawn with). Drawn under the game's HUD, which already has both.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform sampler2D pal_tex : filter_nearest;   // 256 x 1, the planet's palette
uniform vec2 grid = vec2(848.0, 400.0);
uniform float dither = 0.0;                   // ordered dither amplitude (0 = none, like the game; it crawls)
uniform int first_index = 17;

const float BAYER[16] = {0.0, 8.0, 2.0, 10.0, 12.0, 4.0, 14.0, 6.0, 3.0, 11.0, 1.0, 9.0, 15.0, 7.0, 13.0, 5.0};

void fragment() {
	// each game pixel is the mean of the window's pixels it covers (2 x 2.4): one pixel picked in it jumped from
	// texel to texel as the view moved, the ground shimmered
	vec2 cell = floor(SCREEN_UV * grid);
	vec3 c = vec3(0.0);
	for (int k = 0; k < 4; k++) {
		vec2 o = vec2(float(k & 1), float(k >> 1)) * 0.5 + 0.25;
		c += texture(screen_tex, (cell + o) / grid).rgb;
	}
	c *= 0.25;
	int b = int(mod(cell.y, 4.0)) * 4 + int(mod(cell.x, 4.0));
	c += (BAYER[b] / 16.0 - 0.47) * dither;
	// nearest palette colour in luma / chroma, the hue weighing twice (plain RGB turned the sky lavender)
	vec3 cy = vec3(dot(c, vec3(0.299, 0.587, 0.114)), 0.0, 0.0);
	cy.y = (c.b - cy.x) * 0.564;
	cy.z = (c.r - cy.x) * 0.713;
	float best = 1e9;
	vec3 out_col = c;
	for (int i = first_index; i < 256; i++) {
		vec3 p = texelFetch(pal_tex, ivec2(i, 0), 0).rgb;
		float py = dot(p, vec3(0.299, 0.587, 0.114));
		vec3 e = cy - vec3(py, (p.b - py) * 0.564, (p.r - py) * 0.713);
		float d = dot(e * e, vec3(1.0, 2.0, 2.0));
		if (d < best) {
			best = d;
			out_col = p;
		}
	}
	COLOR = vec4(out_col, 1.0);
}
