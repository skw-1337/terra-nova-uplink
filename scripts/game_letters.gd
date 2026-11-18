# The game's HUD letters for the co-op guest's cockpit (coop_hud.gd, coop_panels.gd, guest_equipment.gd): the font
# every panel text of the game's cockpit is written in (RESHLMHI.RES 503, read from the player's own game files; the
# game's calls 0x2e4304 / 0x2dbcf8 with font 0x1F7). Its header: first and last letter at +36, +38, the bits at the
# offset of +76 in rows of +80 bytes, +82 rows high, each letter's first column from +84 (the next one's ends it). A
# text is the game's bytes (DOS code page 850, so the French files' accents too), written as they are: the game does
# not change their case ("Rossi", "Weapons" in its small capitals, "FULLY OPERATIONAL" in capitals).
# A text in a colour is made once into a picture and kept (the panel redraws every frame).
extends RefCounted

const ResFile = preload("res://scripts/res_file.gd")

# The compass strip's letters (the game's strip, read on its screen: 5 x 5, its white 0x1D, rows 12-16), N E S W
const COMPASS := {
	"N": ["1...1", "11..1", "1.1.1", "1..11", "1...1"],
	"E": ["11111", "1....", "111..", "1....", "11111"],
	"S": [".1111", "1....", ".111.", "....1", "1111."],
	"W": ["1...1", "1...1", "1.1.1", "11.11", "1...1"],
}

var f := PackedByteArray()
var pics := {}


func ok() -> bool:
	return f.size() >= 88


func height() -> int:
	return f.decode_s16(82) if ok() else 12


static func bytes_of(t: String) -> PackedByteArray:
	var b := ResFile.cp850(t)
	return b.slice(0, b.size() - 1) if b.size() > 0 and b[b.size() - 1] == 0 else b


func width(t: String) -> int:
	if not ok():
		return 4 * t.length()
	var first := f.decode_s16(36)
	var last := f.decode_s16(38)
	var w := 0
	for ch in bytes_of(t):
		if ch >= first and ch <= last and 88 + 2 * (ch - first) <= f.size():
			w += f.decode_s16(86 + 2 * (ch - first)) - f.decode_s16(84 + 2 * (ch - first))
	return w


# the text in colour col: a picture of width(t) x height() (null: no font, or nothing to draw)
func pic(t: String, col: Color) -> Texture2D:
	if not ok() or t == "":
		return null
	var key := t + "|" + col.to_html()
	if pics.has(key):
		return pics[key]
	if pics.size() > 200:
		pics.clear()
	var w := width(t)
	var h := height()
	var tex: Texture2D = null
	if w > 0:
		var first := f.decode_s16(36)
		var last := f.decode_s16(38)
		var bits := f.decode_s32(76)
		var row := f.decode_s16(80)
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		var x := 0
		for ch in bytes_of(t):
			if ch < first or ch > last or 88 + 2 * (ch - first) > f.size():
				continue
			var a := f.decode_s16(84 + 2 * (ch - first))
			var b := f.decode_s16(86 + 2 * (ch - first))
			for yy in h:
				for xx in range(a, b):
					var at := bits + yy * row + (xx >> 3)
					if at < f.size() and f[at] & (0x80 >> (xx & 7)):
						img.set_pixel(x + xx - a, yy, col)
			x += b - a
		tex = ImageTexture.create_from_image(img)
	pics[key] = tex
	return tex
