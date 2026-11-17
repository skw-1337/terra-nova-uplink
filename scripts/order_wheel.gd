# The order wheel's picture (viewer.gd holds its state and its inputs): a flat-top hexagon of six glass panes in the
# cockpit's dark green metal, opposite orders facing each other, the middle left open on what is aimed at; under it
# who gets the order, in the COMM panel's green box. Drawn in the window's own pixels (smooth edges), sized for a
# 1080-row window and scaled to the others, over the game's HUD and the old school look.
extends Control

const RF := 300.0                      # the frame, the panes' outer and inner radius, the hub's opening (1080 rows)
const R := 282.0
const R_IN := 96.0
const R_HUB := 84.0
const NAVY := Color8(5, 7, 66)
const BLUE := Color8(70, 84, 255)
const GREEN := Color8(60, 255, 80)
const WHITE := Color8(245, 246, 252)
const PICKED := Color8(0, 84, 32)
const METAL := Color8(34, 70, 52)
const METAL_HI := Color8(88, 132, 104)
const METAL_LO := Color8(10, 28, 20)
const OFF_TEXT := Color8(112, 118, 160)
const OFF_LINE := Color8(34, 40, 120)
const YELLOW := Color8(255, 205, 70)
const RED := Color8(255, 70, 50)
const HINT := Color8(176, 186, 255)
# the orders, by their number (orders.py); as the wheel comes, the first six clockwise from the top, opposite orders
# facing each other: attack / retreat, go there / come to me, cover / hold
const LABELS := ["ATTACK TARGET", "MOVE THERE", "TAKE COVER", "RETREAT", "FOLLOW ME", "HOLD POSITION", "ASSUME FORMATION"]

var shown := false                     # the wheel itself
var centre := Vector2.ZERO             # its middle, window pixels
var k := 1.0                           # window rows / 1080
var panes := [0, 1, 2, 3, 4, 5]         # the order on each pane, clockwise from the top (-1: an empty pane)
var picked := -1                       # the pane under the hand (-1: none)
var off := {}                          # panes that cannot be picked: pane -> the small line under its name
var who := "ENTIRE SQUAD"
var marker := 0                        # what is aimed at: 0 nothing, 1 a point on the ground, 2 an enemy
var marker_at := Vector2.ZERO          # where it is on the screen
var marker_k := 1.0                    # its size (smaller on the game's map)
var line := ""                         # the short line after an order ("ORDER: ... > ...")
var line_bad := false
var bold: Font
var semi: Font


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	bold = _font(700)
	semi = _font(600)


# the cockpit's kind of letters: Windows' Bahnschrift (a DIN), else whatever the system has, else Godot's own
static func _font(weight: int) -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "DIN Alternate", "DejaVu Sans Condensed", "Arial"])
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	return f


# the pane under a hand that went `ptr` from the middle (the dead zone inside `dead`: none)
static func pane_at(ptr: Vector2, dead: float) -> int:
	if ptr.length() < dead:
		return -1
	return posmod(roundi((rad_to_deg(ptr.angle()) + 90.0) / 60.0), 6)


func _vert(rad: float, i: int) -> Vector2:      # a corner at the top left: the top pane sits flat
	var a := deg_to_rad(-120.0 + 60.0 * i)
	return centre + Vector2(cos(a), sin(a)) * rad * k


func _fill(pts: PackedVector2Array, col: Color) -> void:
	draw_colored_polygon(pts, col)
	var edge := pts.duplicate()
	edge.append(pts[0])
	draw_polyline(edge, col, 1.0, true)                # (its edges smooth)


func _band(r0: float, r1: float, col: Color) -> void:
	for i in 6:
		_fill(PackedVector2Array([_vert(r0, i), _vert(r0, i + 1), _vert(r1, i + 1), _vert(r1, i)]), col)


func _stroke(pts: Array, col: Color, width: float) -> void:
	draw_polyline(PackedVector2Array(pts), col, width * k, true)
	for p in pts:                                         # (round joints and ends)
		draw_circle(p, width * k * 0.5, col, true, -1.0, true)


func _text(f: Font, t: String, mid_x: float, top: float, px: float, col: Color) -> void:
	var fs := maxi(8, roundi(px * k))
	var w := f.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	draw_string(f, Vector2(roundf(mid_x - w * 0.5), roundf(top + f.get_ascent(fs))), t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _icon(i: int, at: Vector2, col: Color) -> void:
	var s := 1.45 * k
	var w := 3.0
	var p := func(x: float, y: float) -> Vector2: return at + Vector2(x, y) * s
	match i:
		0:                                               # attack: a sight
			draw_arc(at, 8.0 * s, 0.0, TAU, 40, col, w * k, true)
			for d in [Vector2(0, 1), Vector2(1, 0), Vector2(0, -1), Vector2(-1, 0)]:
				_stroke([at + d * 5.0 * s, at + d * 12.0 * s], col, w)
		1:                                               # move there: an arrow head down on a line
			_stroke([p.call(-8, -9), p.call(0, 1), p.call(8, -9)], col, w)
			_stroke([p.call(-7, 8), p.call(7, 8)], col, w)
		2:                                               # take cover: a shield
			_stroke([p.call(-8, -9), p.call(8, -9), p.call(8, 1), p.call(0, 10), p.call(-8, 1), p.call(-8, -9)], col, w)
		3:                                               # retreat: an arrow back
			_stroke([p.call(9, 0), p.call(-9, 0)], col, w)
			_stroke([p.call(-3, -6), p.call(-9, 0), p.call(-3, 6)], col, w)
		4:                                               # follow me: two chevrons
			_stroke([p.call(-8, 1), p.call(0, -7), p.call(8, 1)], col, w)
			_stroke([p.call(-8, 9), p.call(0, 1), p.call(8, 9)], col, w)
		5:                                               # hold position: a point in its corners
			draw_circle(at, 2.5 * s + w * k * 0.5, col, true, -1.0, true)
			for sx in [-1, 1]:
				for sy in [-1, 1]:
					_stroke([p.call(sx * 10, sy * 4), p.call(sx * 10, sy * 10), p.call(sx * 4, sy * 10)], col, w)
		6:                                               # assume formation: three in a wedge
			for d in [Vector2(0, -6), Vector2(-9, 7), Vector2(9, 7)]:
				draw_circle(at + d * s, 2.2 * s + w * k * 0.5, col, true, -1.0, true)


func _draw() -> void:
	if shown:
		_draw_wheel()
	if marker == 1:                                       # a yellow diamond on the point
		var q := 13.0 * k * maxf(marker_k, 0.75)
		var c := marker_at
		_stroke([c + Vector2(0, -q), c + Vector2(q, 0), c + Vector2(0, q), c + Vector2(-q, 0), c + Vector2(0, -q)], YELLOW, 3.2)
	elif marker == 2:                                     # red corners around the enemy
		var m := k * marker_k
		for sx in [-1, 1]:
			for sy in [-1, 1]:
				_stroke([marker_at + Vector2(sx * 44, sy * 16) * m, marker_at + Vector2(sx * 44, sy * 30) * m,
						marker_at + Vector2(sx * 30, sy * 30) * m], RED, 3.2)
	if line != "" and not shown:
		_draw_line()


func _draw_wheel() -> void:
	var lw := 3.2
	# the metal frame, lit from the top left like the cockpit's
	_band(RF, R + 4.0, METAL)
	_band(R + 4.0, R_IN, METAL_LO)
	for i in 6:
		_fill(PackedVector2Array([_vert(R, i), _vert(R, i + 1), _vert(R_IN, i + 1), _vert(R_IN, i)]),
				PICKED if i == picked else NAVY.lerp(METAL_LO, 0.075))
	for i in 6:                                           # the frame's metal between the panes
		_stroke([_vert(R_IN - 2.0, i), _vert(R + 2.0, i)], METAL, 9.0)
		_stroke([_vert(R_IN - 2.0, i), _vert(R + 2.0, i)], METAL_LO, 2.0)
	for i in 6:                                           # each pane's border, inside it
		var a := deg_to_rad(-90.0 + 60.0 * i)
		var t := Vector2(-sin(a), cos(a)) * 11.0 * k
		var q := [_vert(R - 8.0, i) + t, _vert(R - 8.0, i + 1) - t, _vert(R_IN + 8.0, i + 1) - t * 0.55, _vert(R_IN + 8.0, i) + t * 0.55]
		q.append(q[0])
		_stroke(q, GREEN if i == picked else (OFF_LINE if off.has(i) else BLUE), lw)
	_band(R_IN, R_HUB, METAL)                             # the hub: a metal rim, the middle open
	for i in 6:
		var v := -cos(deg_to_rad(-90.0 + 60.0 * i)) - sin(deg_to_rad(-90.0 + 60.0 * i))
		_stroke([_vert(RF, i), _vert(RF, i + 1)], METAL_HI if v > 0.3 else (METAL_LO if v < -0.3 else METAL), lw)
		_stroke([_vert(R_IN, i), _vert(R_IN, i + 1)], METAL_LO if v > 0.3 else (METAL_HI if v < -0.3 else METAL), lw)
		_stroke([_vert(R_HUB, i), _vert(R_HUB, i + 1)], METAL_LO, lw)
	for i in 6:                                           # an icon over each name (an empty pane: nothing)
		var o := int(panes[i])
		if o < 0 or o >= LABELS.size():
			continue
		var a := deg_to_rad(-90.0 + 60.0 * i)
		var at := centre + Vector2(cos(a), sin(a)) * (R + R_IN) * 0.5 * 0.90 * k
		var col: Color = GREEN if i == picked else (OFF_TEXT if off.has(i) else WHITE)
		var words: PackedStringArray = (LABELS[o] as String).split(" ")
		var top := at.y - (22.0 + 14.0 * words.size()) * k
		_icon(o, Vector2(roundf(at.x), roundf(top)), col)
		for j in words.size():
			_text(bold, words[j], at.x, top + (24.0 + 27.0 * j) * k, 25.0, col)
		if off.has(i) and str(off[i]) != "":
			_text(semi, str(off[i]), at.x, top + (24.0 + 27.0 * words.size() + 4.0) * k, 15.0, OFF_TEXT)
	# who gets it: the COMM panel's green box
	var fb := maxi(8, roundi(22.0 * k))
	var fh := maxi(8, roundi(17.0 * k))
	var w := bold.get_string_size(who, HORIZONTAL_ALIGNMENT_LEFT, -1, fb).x
	var tw := semi.get_string_size("TO", HORIZONTAL_ALIGNMENT_LEFT, -1, fh).x
	var hw := semi.get_string_size("WHEEL: CHANGE", HORIZONTAL_ALIGNMENT_LEFT, -1, fh).x
	var y0 := roundf(centre.y + (RF + 14.0) * k)
	var h := roundf(36.0 * k)
	var bw := roundf(w + 32.0 * k)
	var x0 := roundf(centre.x - bw * 0.5)
	_box(Rect2(x0 - tw - 34.0 * k, y0 - 7.0 * k, bw + tw + hw + 68.0 * k, h + 14.0 * k), METAL, METAL_LO)
	_box(Rect2(x0, y0, bw, h), NAVY, GREEN)
	_text(bold, who, x0 + bw * 0.5, y0 + 5.0 * k, 22.0, GREEN)
	_text(semi, "TO", x0 - 16.0 * k - tw * 0.5, y0 + 8.0 * k, 17.0, WHITE)
	_text(semi, "WHEEL: CHANGE", x0 + bw + 16.0 * k + hw * 0.5, y0 + 8.0 * k, 17.0, HINT)


func _box(r: Rect2, fill: Color, edge: Color) -> void:
	draw_rect(r, fill)
	draw_rect(r.grow(-1.6 * k), edge, false, 3.2 * k, true)


# after an order: what was sent and to whom, where the wheel's box was
func _draw_line() -> void:
	var fb := maxi(8, roundi(22.0 * k))
	var w := bold.get_string_size(line, HORIZONTAL_ALIGNMENT_LEFT, -1, fb).x
	var y0 := roundf(centre.y + (RF + 14.0) * k)
	var h := roundf(36.0 * k)
	var bw := roundf(w + 32.0 * k)
	var x0 := roundf(centre.x - bw * 0.5)
	_box(Rect2(x0 - 7.0 * k, y0 - 7.0 * k, bw + 14.0 * k, h + 14.0 * k), METAL, METAL_LO)
	_box(Rect2(x0, y0, bw, h), NAVY, RED if line_bad else GREEN)
	_text(bold, line, x0 + bw * 0.5, y0 + 5.0 * k, 22.0, RED if line_bad else GREEN)
