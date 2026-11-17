# Co-op guest: where the host's game is, in a line at the top of his window (the host's bridge sends it,
# live/host_state.py: 'HST' + version, state, mission number, the video playing, flags). Plain and short: what the
# host is doing and what the guest is waiting for. Nothing while the mission is being played.
# While the host watches the briefing (a Smacker video Godot cannot play), the guest reads it: the game's own text
# briefing of that mission (its options' "Briefings: Text"), from his own game files: RESPTERM.RES 1455, the string of
# the mission's number (MISSn.RES -> [n]).
extends Node

const LGRes = preload("res://scripts/lgres.gd")
const PORT := 47836
const BLUE := Color8(61, 139, 240)
const ORANGE := Color8(232, 134, 42)
# campaign order (mission 1..37) -> MISSn.RES (as the launcher's CAMPAIGN, tn_data.gd)
const CAMPAIGN := [37, 38, 1, 2, 3, 4, 5, 6, 7, 8, 9, 32, 33, 10, 11, 12, 13, 34, 29, 15, 17, 16, 36,
		14, 20, 39, 21, 35, 22, 23, 19, 24, 27, 25, 26, 30, 31]
enum {NONE, INTRO, MENU, SAVES, LOADING, BASE, BRIEFING, OUTFIT, LAUNCH, MISSION_ON, PAUSED, AFTER}

var udp := PacketPeerUDP.new()
var v: Node
var layer: CanvasLayer
var label: Label
var state := -1
var mission := 0
var movie := ""
var custom := false
var last := -100.0
var clock := 0.0
var names := PackedStringArray()
var names_read := false
var briefs := PackedStringArray()
var briefs_read := false
var panel: PanelContainer
var panel_text: Label
var panel_of := -1


func _ready() -> void:
	v = get_parent()
	udp.bind(PORT, "127.0.0.1")
	layer = CanvasLayer.new()
	layer.layer = 26                                    # over the HUD and the waiting panel, under Uplink's menu
	add_child(layer)
	label = Label.new()
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Arial"])
	f.font_weight = 600
	label.add_theme_font_override("font", f)
	label.add_theme_color_override("font_color", Color.WHITE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.visible = false
	layer.add_child(label)


func _process(delta: float) -> void:
	clock += delta
	while udp.get_available_packet_count() > 0:
		var pk := udp.get_packet()
		if pk.size() >= 16 and pk.slice(0, 3).get_string_from_ascii() == "HST" and pk[3] >= 1:
			state = pk[4]
			mission = pk.decode_u16(5)
			movie = pk.slice(7, 15).get_string_from_ascii().strip_edges()
			custom = pk[15] & 2 != 0
			last = clock
	_briefing_text()
	var t := _text()
	label.visible = t != ""
	if t == "":
		return
	label.text = t
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var k := clampf(vs.y / 1080.0, 0.7, 2.2)
	label.add_theme_font_size_override("font_size", maxi(12, roundi(22 * k)))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.10, 0.094, 0.88)
	sb.border_color = BLUE
	sb.border_width_bottom = maxi(2, roundi(3 * k))
	sb.content_margin_left = 18 * k
	sb.content_margin_right = 18 * k
	sb.content_margin_top = 8 * k
	sb.content_margin_bottom = 8 * k
	label.add_theme_stylebox_override("normal", sb)
	label.reset_size()
	label.position = Vector2(roundf((vs.x - label.size.x) * 0.5), roundf(vs.y * 0.06))


func _text() -> String:
	if state < 0:
		return ""
	if clock - last > 6.0:
		return "No news from the host's game (closed, or his Uplink stopped)."
	var m := _mission_name()
	match state:
		INTRO:
			return "The host's game is starting."
		MENU:
			return "The host is on the game's main menu."
		SAVES:
			return "The host is picking a saved game."
		LOADING:
			return "The host's game is loading."
		BASE:
			return "The host is in the base, on the way to the briefing" + (" of " + m if m != "" else "") + "."
		BRIEFING:
			return "The host is watching the briefing" + (" of " + m if m != "" else "") + ". You join when he picks the squad."
		OUTFIT:
			return "The host is picking the squad" + (" for " + m if m != "" else "") + ": take a column below."
		LAUNCH:
			return "Loading " + (m if m != "" else "the mission") + "..."
		PAUSED:
			return "The host's game is paused (a game screen: options, map, help)."
		AFTER:
			return "Mission over: the host is on the debriefing."
	return ""                                            # (in the mission: nothing in the way)


func _mission_name() -> String:
	if mission <= 0 or custom:
		return "a custom mission" if custom else ""
	if not names_read:
		names_read = true
		if v.get("data") and v.data.has_method("data_dir"):
			var res = LGRes.open(v.data.data_dir().path_join("RESMISS.RES"))
			if res and res.has(1706):
				names = res.strings(1706)
	var nm := names[mission - 1].strip_edges().capitalize() if mission - 1 < names.size() else ""
	var pos := CAMPAIGN.find(mission)
	var num := "Mission %d" % (pos + 1) if pos >= 0 else "MISS%d" % mission
	return num + (" (" + nm + ")" if nm != "" else "")


# the text briefing, over the guest's view, while the host's game plays the briefing's video
func _briefing_text() -> void:
	var want := state == BRIEFING and clock - last < 6.0 and mission > 0 and not custom
	if not want:
		if panel:
			panel.visible = false
		return
	if not briefs_read:
		briefs_read = true
		if v.get("data") and v.data.has_method("data_dir"):
			var res = LGRes.open(v.data.data_dir().path_join("RESPTERM.RES"))
			if res and res.has(1455):
				briefs = res.strings(1455)
	if mission >= briefs.size() or briefs[mission].strip_edges().length() < 40:
		return
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var k := clampf(vs.y / 1080.0, 0.7, 2.2)
	if panel == null:
		panel = PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.05, 0.10, 0.094, 0.93)
		sb.border_color = BLUE
		sb.border_width_left = 4
		sb.set_corner_radius_all(6)
		sb.set_content_margin_all(22 * k)
		panel.add_theme_stylebox_override("panel", sb)
		var col := VBoxContainer.new()
		panel.add_child(col)
		var head := Label.new()
		head.name = "head"
		head.add_theme_font_override("font", label.get_theme_font("font"))
		head.add_theme_color_override("font_color", ORANGE)
		head.add_theme_font_size_override("font_size", maxi(12, roundi(24 * k)))
		col.add_child(head)
		panel_text = Label.new()
		panel_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Arial"])
		panel_text.add_theme_font_override("font", f)
		panel_text.add_theme_font_size_override("font_size", maxi(11, roundi(21 * k)))
		panel_text.add_theme_color_override("font_color", Color8(214, 226, 220))
		col.add_child(panel_text)
		layer.add_child(panel)
	if panel_of != mission:
		panel_of = mission
		(panel.get_child(0).get_node("head") as Label).text = "BRIEFING  ·  " + _mission_name()
		panel_text.text = briefs[mission].strip_edges()
	var w := minf(vs.x * 0.62, 1100.0 * k)
	panel_text.custom_minimum_size.x = w - 44 * k
	panel.reset_size()
	panel.position = Vector2(roundf((vs.x - panel.size.x) * 0.5), roundf(vs.y * 0.13))
	panel.visible = true
