# The squadmates' subtitles' picture (viewer.gd holds what is said: the bridge's 'SUBT'): one line a speaker, his name
# in the colour the COMM panel gives him, then what he says, on the cockpit's navy with the letters of the order
# wheel. At the bottom of the game's 3D window, the newest line lowest, under the crosshair. Drawn in the window's own
# pixels, sized for a 1080-row window and scaled to the others, over the game's HUD and the old school look.
extends Control

const OrderWheel = preload("res://scripts/order_wheel.gd")
const NAVY := Color8(5, 7, 66)
const WHITE := Color8(245, 246, 252)
const CAPTION := Color8(176, 186, 255)
const EDGE := Color8(10, 28, 20)
# the COMM panel's colour of the first, second and third squadmate (the game's own, read on its screen)
const COMM := [Color8(239, 203, 43), Color8(66, 66, 231), Color8(255, 127, 0)]
const SIZE := 28.0                     # the letters (1080 rows)
const ROW := 46.0                      # a line's plate, and the gap to the next
const GAP := 6.0

var lines := []                        # [the speaker's name, his place in the squad (1-3), what he says, a caption of ours]
var k := 1.0                           # window rows / 1080
var foot := Vector2.ZERO               # the middle of the lowest line's bottom edge, window pixels
var bold: Font
var semi: Font


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	bold = OrderWheel._font(700)
	semi = OrderWheel._font(600)


static func colour(mate: int) -> Color:
	return COMM[clampi(mate, 1, 3) - 1]


func _draw() -> void:
	var fs := maxi(10, roundi(SIZE * k))
	var h := roundf(ROW * k)
	var pad := roundf(16.0 * k)
	var bar := maxf(3.0, roundf(6.0 * k))
	var y := foot.y - h
	for i in range(lines.size() - 1, -1, -1):
		var l: Array = lines[i]
		var who := str(l[0]) + ":"
		var said := str(l[2])
		var nw := bold.get_string_size(who, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var gap := roundf(10.0 * k)
		var tw := semi.get_string_size(said, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var w := bar + pad + nw + gap + tw + pad
		var x := roundf(foot.x - w * 0.5)
		var col := colour(int(l[1]))
		draw_rect(Rect2(x, y, w, h), Color(NAVY, 0.9))
		draw_rect(Rect2(x, y, w, h).grow(-0.5), EDGE, false, 1.0)
		draw_rect(Rect2(x, y, bar, h), col)
		var base := roundf(y + (h - bold.get_height(fs)) * 0.5 + bold.get_ascent(fs))
		draw_string(bold, Vector2(x + bar + pad, base), who, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		draw_string(semi, Vector2(x + bar + pad + nw + gap, base), said, HORIZONTAL_ALIGNMENT_LEFT, -1, fs,
				CAPTION if bool(l[3]) else WHITE)
		y -= h + roundf(GAP * k)
