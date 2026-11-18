# A small notice when the player switches a look or a view with a key ("Old school look: on", "Pixels: 2×",
# "Infrared: off"...): a dark pill at the top of the game's 3D window (under its top edge, far over the crosshair),
# for 1.5 s, then it fades. A new one takes the place of the one shown. Not in photo mode, and taken out of a
# screenshot (viewer.gd _shot_key hides it for that frame).
# - show_mode(text): a switch the window knows itself (the old school look, its pixels, the frame counter, a guest's
#   views: coop_views.gd);
# - watch(id, on, text): a mode seen in what the game says (infrared, the host's full view and 360 view): told when it
#   changes (first seen: against off, as each comes); stale (a 360 view: no news for STALE_S): off.
extends CanvasLayer

const ORANGE := Color8(232, 134, 42)
const BLUE := Color8(61, 139, 240)
const SHOW_S := 1.5
const FADE_S := 0.4
const STALE_S := 1.0

var v: Node
var pill: PanelContainer
var label: Label
var sb: StyleBoxFlat
var t := -1.0
var states := {}                         # watch id -> [on, text, last seen (s), goes stale]
var clock := 0.0
var last_text := ""                      # (tests)


func _ready() -> void:
	v = get_parent()
	layer = 20                                         # over the game's HUD and the old school look
	pill = PanelContainer.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.visible = false
	sb = StyleBoxFlat.new()
	sb.bg_color = Color(0.03, 0.07, 0.07, 0.72)
	sb.set_corner_radius_all(64)
	pill.add_theme_stylebox_override("panel", sb)
	add_child(pill)
	label = Label.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Arial"])
	f.font_weight = 600
	label.add_theme_font_override("font", f)
	label.add_theme_color_override("font_color", Color(0.93, 0.95, 0.93))
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(label)


func show_mode(text: String) -> void:
	if pill == null or (v and v.get("photo_on")):
		return
	last_text = text
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var k := clampf(vs.y / 1080.0, 0.75, 2.2)
	var accent := BLUE if v and v.get("guest_win") else ORANGE
	sb.border_color = Color(accent, 0.85)
	sb.set_border_width_all(0)
	sb.border_width_left = maxi(2, roundi(3 * k))
	sb.border_width_right = sb.border_width_left
	sb.content_margin_left = 16 * k
	sb.content_margin_right = 16 * k
	sb.content_margin_top = 5 * k
	sb.content_margin_bottom = 6 * k
	label.add_theme_font_size_override("font_size", maxi(12, roundi(18 * k)))
	label.text = text
	pill.visible = true
	pill.modulate.a = 1.0
	pill.reset_size()
	pill.size = pill.get_combined_minimum_size()
	# the game's 3D window (its 320 x 400 screen, as the subtitles place themselves), else the window's top
	var win := Rect2(0, 0, 320, 400)
	if v and v.get("live"):
		var hw = v.get("hud_win")
		win = Rect2(hw) if hw is Rect2i and (hw as Rect2i).size.y > 0 else Rect2(11, 42, 298, 199)
	var top := (win.position.y + win.size.y * 0.07) / 400.0 * vs.y
	var cx := (win.position.x + win.size.x * 0.5) / 320.0 * vs.x
	pill.position = Vector2(roundf(cx - pill.size.x * 0.5), roundf(maxf(top, 6.0 * k)))
	t = 0.0


func watch(id: String, on: bool, text: String, stale := false) -> void:
	var was = states.get(id)
	states[id] = [on, text, clock, stale]
	if bool(was[0] if was != null else false) != on:
		show_mode(text + (": on" if on else ": off"))


# for a screenshot: out of the picture now (true if it was shown)
func hide_now() -> bool:
	var was := pill != null and pill.visible
	if was:
		pill.visible = false
		t = -1.0
	return was


func _process(delta: float) -> void:
	clock += delta
	for id in states:
		var s: Array = states[id]
		if bool(s[0]) and bool(s[3]) and clock - float(s[2]) > STALE_S:
			watch(id, false, str(s[1]), true)
	if t < 0.0:
		return
	if v and v.get("photo_on"):
		hide_now()
		return
	t += delta
	pill.modulate.a = clampf((SHOW_S + FADE_S - t) / FADE_S, 0.0, 1.0)
	if t >= SHOW_S + FADE_S:
		hide_now()
