# Colour-blind mode (the launcher's Settings > Accessibility, the Esc menu's Accessibility: TN_COLOUR_VISION =
# protan / deutan / tritan; none: off, the game's colours). Only Uplink's own drawing changes, and only where a colour
# tells something: what the game marks a unit with (its brackets on the 3D view and its map's dots: the target it
# locked in green 0x84, a hostile soldier or vehicle in red 0x44), and the green / yellow / red of a level (the armour
# indicator, the squad's bars, Uplink's own status lights). The rest of the picture keeps the game's colours.
# The new colours were chosen on the Machado 2009 simulation of each deficiency (full severity) against every other
# colour the game marks units with (its squad's yellow 0x4E, blue 0x34, orange 0x7E, vehicles' grey 0x22, buildings'
# browns...), keeping them apart in normal vision too (S\a11y\search*.py, README of the captures):
# - protanopia and deuteranopia (red and green look alike): the lock and "whole" green becomes cyan; the hostile red
#   becomes raspberry (protanopia: a pure red looks almost black to it) or magenta (deuteranopia); the squad's three
#   colours stay (they are the COMM panel's, which is the game's own picture);
# - tritanopia (blue and green, yellow and pink look alike): red and green already stay apart; the lock's green goes
#   yellow-green, away from the squad's and the full-view blues.
# In every mode a hostile unit's brackets also get a shape of their own (a small triangle over them, viewer.gd and
# coop_hud.gd), so that colour alone never tells friend from foe.
extends RefCounted

const MODES := ["", "protan", "deutan", "tritan"]
const NAMES := ["Off", "Protanopia", "Deuteranopia", "Tritanopia"]
const LOCK := 0x84                  # the game's palette: its target / "whole" green ...
const FOE := 0x44                   # ... and its hostile / "lost" red
const GAME_RED := Color8(232, 0, 0)  # (0x44 in every planet's palette)

# per mode: the game's palette index -> the colour drawn instead
const TABLES := {
	"protan": {0x82: Color8(0, 255, 255), 0x84: Color8(0, 255, 255), 0x41: Color8(255, 120, 170), 0x43: Color8(240, 64, 128),
		0x44: Color8(240, 64, 128), 0x45: Color8(220, 50, 115)},
	"deutan": {0x82: Color8(0, 255, 255), 0x84: Color8(0, 255, 255), 0x41: Color8(255, 110, 255), 0x43: Color8(255, 0, 255),
		0x44: Color8(255, 0, 255), 0x45: Color8(225, 0, 225)},
	"tritan": {0x82: Color8(176, 240, 0), 0x84: Color8(160, 224, 0)},
}
# Uplink's own status lights (fine / warning / bad: the co-op link, the guest's plain armour bar), Okabe-Ito's sky blue,
# yellow and a raspberry for red-green; the usual green / amber / red are apart for a tritanope already
const LEDS := {
	"protan": [Color8(86, 180, 233), Color8(240, 228, 66), Color8(240, 64, 128)],
	"deutan": [Color8(86, 180, 233), Color8(240, 228, 66), Color8(240, 64, 128)],
}

static var mode := _env_mode()


static func _env_mode() -> String:
	var m := OS.get_environment("TN_COLOUR_VISION").to_lower()
	return m if m in MODES else ""


static func on() -> bool:
	return mode != ""


# set at once (the Esc menu): the environment follows, for what is made later (a guest's window, a new HUD)
static func set_mode(m: String) -> void:
	mode = m if m in MODES else ""
	OS.set_environment("TN_COLOUR_VISION", mode)


# the colour to draw for the game's palette index i (pal: the game's palette)
static func idx(pal: PackedColorArray, i: int) -> Color:
	if mode != "" and TABLES[mode].has(i):
		return TABLES[mode][i]
	return pal[i] if i >= 0 and i < pal.size() else Color.WHITE


# one of Uplink's own status colours (k: 0 fine, 1 warning, 2 bad; c: its usual colour)
static func led(k: int, c: Color) -> Color:
	return LEDS[mode][k] if LEDS.has(mode) else c


# the hostile units' colour in this mode (the game's red, 0x44, when the mode keeps it)
static func foe_colour() -> Color:
	return TABLES[mode].get(FOE, GAME_RED) if mode != "" else GAME_RED


# a hostile unit: its brackets get the triangle
static func is_foe(i: int) -> bool:
	return i == FOE


# the mode's table as a 256 x 1 picture for the HUD's shader (alpha 1: drawn instead of the palette's colour)
static func table_image() -> Image:
	var img := Image.create(256, 1, false, Image.FORMAT_RGBA8)
	if mode != "":
		for i in TABLES[mode]:
			var c: Color = TABLES[mode][i]
			img.set_pixel(i, 0, Color(c.r, c.g, c.b, 1.0))
	return img


# the triangle over a hostile unit's brackets (pointing down at it), in the game's screen units scaled by k: tip at
# x, y (just over the brackets' top), on a dark edge so that it reads on any ground
static func foe_cue(ci: CanvasItem, x: float, y: float, k: Vector2, col: Color) -> void:
	var tip := Vector2(x, y) * k
	var w := 3.5 * k.x
	var h := 4.0 * k.y
	var tri := PackedVector2Array([tip + Vector2(-w, -h), tip + Vector2(w, -h), tip])
	var edge := maxf(1.0, k.x * 0.45)
	ci.draw_colored_polygon(tri, col)
	ci.draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color(0, 0, 0, 0.85), edge, true)
