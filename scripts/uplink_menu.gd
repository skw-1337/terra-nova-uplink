# Uplink's own menu in a live window, drawn over the view (the game goes on: it runs on the host's PC, or behind).
# Esc opens it: a co-op guest's always (his window had none: to quit he had to switch to the launcher); solo and the
# host's in a mission, unless Options says Esc is the game's (viewer.cfg [launcher] esc_menu = 0). Uplink's menu key
# opens it too (F5 unless changed). Esc stays the game's wherever the game shows one of its screens (its menus,
# briefings, the pause...), with Ctrl+Esc (abort), in the photo mode, in a field being typed in (see _esc_ours). (In a
# mission's 3D view the game itself does nothing with Esc alone: its own menu is its Options screen, on O.)
# Resume; Game menu (solo / host: the game's own menu, its Options screen: sound, detail, abort, exit...); Controls (every
# key: controls.gd, the same list as the launcher's Controls page); Graphics (the launcher's display settings, at once
# where Uplink can, else at the next start); Options (the music device or the guest's sound, the order wheel, the mouse,
# the gamepad, Esc...: the launcher's other settings, as Graphics); Accessibility (the subtitles, their size, the
# colour-blind mode: the launcher's Settings > Accessibility, at once); Quit (solo / host: the game,
# the bridge and Uplink closed, the launcher then as after STOP; a guest of the host is told the host left) or, for the
# guest, Leave the game (his teammate back to the game's AI on the host, his window closed: his launcher is then as
# after STOP). Closing the guest's window leaves the same way.
# Also, once a session, when the player first takes the mouse in a mission: a line with the few keys to know (Esc,
# the free look, the orders), fading out.
# Settings are kept: the sound in viewer.cfg [sound], the pixel size in [look] (as the launcher has it), the others
# in viewer.cfg [launcher] for the launcher to take over (as the Controls page's keys: see controls.gd).
extends Node

const Controls = preload("res://scripts/controls.gd")
const CFG := "user://viewer.cfg"
const ORANGE := Color8(232, 134, 42)
const BLUE := Color8(61, 139, 240)
const PANEL := Color(0.05, 0.10, 0.094, 0.94)
const LINE := Color8(29, 53, 49)
const TEXT := Color8(214, 226, 220)
const DIM := Color8(122, 150, 142)
const RED := Color8(236, 72, 60)
const GROUPS := ["Move", "Fight", "View", "Squad", "Map", "Drone", "System", "Tools", "Gamepad", "Uplink"]
const FX := [["cloud_shadows", "Cloud shadows", true], ["cliffs", "Unstretched cliffs", true], ["stars", "Sharp stars", true],
		["marks", "Impact marks", true], ["lights", "Light from shots", true], ["look_down", "Look further down", false],
		["tracks", "Footprints and tracks", true], ["own_body", "Own body (legs, feet)", true]]
# The graphics presets, as the launcher has them (TerraNovaUplink.cs PRESETS, same order and values): each sets the old
# school look, Uplink's HUD colours and every extra; any switch changed afterwards makes it "custom". Kept in
# viewer.cfg [launcher] gfx_preset (the launcher takes it over), told by the launcher at the start (TN_GFX_PRESET).
const PRESET_IDS := ["original", "classic", "modern", "light", "custom"]
const PRESET_NAMES := ["Original", "Classic+", "Modern", "Light", "Custom"]
const PRESET_KEYS := ["old_school", "hud_colours", "marks", "lights", "cloud_shadows", "look_down", "cliffs", "stars", "tracks", "own_body"]
const PRESETS := {
	"original": [1, 0, 0, 0, 0, 1, 0, 0, 0, 0],
	"classic": [1, 0, 1, 1, 0, 1, 0, 0, 1, 1],
	"modern": [0, 1, 1, 1, 1, 1, 1, 1, 1, 1],
	"light": [0, 1, 1, 1, 0, 1, 0, 1, 0, 1],
}
const FX_NODES := {"marks": "fx_marks.gd", "lights": "fx_lights.gd", "tracks": "fx_tracks.gd"}
# the launcher's lists (TerraNovaUplink.cs SIZES, CROSSHAIRS, FillCap), kept with the same values
const SHARP := [[1, "1×"], [2, "2×"], [3, "3×"], [0, "Max"]]
const CROSS := [["", "The game's"], ["dot", "A dot"], ["none", "None"]]
const CAPS := [0, 60, 120, 144, 240]
const SIZES := [["1280x720", "1280 × 720"], ["1696x960", "1696 × 960"], ["1920x1080", "1920 × 1080"], ["native", "Fullscreen"]]

var v: Node                        # the viewer
var guest := false
var layer: CanvasLayer
var root: Control
var box: PanelContainer
var page := ""
var was_captured := false
var menu_key := [KEY_F5, 0]        # the host's (TN_KEY_MENU, as Uplink's other keys); a guest's is Esc
var model: Controls
var pad_frame := -1                # the frame a gamepad binding was taken (pad_map.gd ignores that input)
var capture := {}                  # a key being asked for: {id, column ("key" / "mouse"), button}
var search: LineEdit
var rows_box: VBoxContainer
var note_label: Label
var leaving := false
var esc_menu := true               # solo / host: Esc opens this menu in a mission (viewer.cfg [launcher] esc_menu = 0: the game's)
var esc_eat := false               # the Esc that opened or closed the menu: its release is not the game's
var hint: Label
var hint_t := -1.0
var hint_done := false
var font_r: SystemFont
var font_b: SystemFont
var k := 1.0


func _ready() -> void:
	v = get_parent()
	guest = bool(v.get("guest_win"))
	var mk: Array = v._own_key(OS.get_environment("TN_KEY_MENU"))
	if not mk.is_empty():
		menu_key = mk
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	var mk2: Array = Controls.parse(str(cfg.get_value("launcher", "key_menu", "")))
	if int(mk2[0]) > 0:
		menu_key = _godot_key(mk2)
	esc_menu = str(cfg.get_value("launcher", "esc_menu", "0" if OS.get_environment("TN_ESC_MENU") == "0" else "1")) != "0"
	layer = CanvasLayer.new()
	layer.layer = 40                                    # over the HUD, the game's screens and the lobby
	add_child(layer)
	font_r = _font(400)
	font_b = _font(600)
	if guest:
		get_tree().auto_accept_quit = false              # (closing his window leaves the game first: _notification)
		model = Controls.new()
		if model.ini_path != "":                         # his keys as the Controls page has them (Centre view without
			v.key_map = model.key_map()                  # a key since the keys' version 4: the launcher's TN_KEYS did not know)
		var db := float(cfg.get_value("sound", "guest_volume_db", 0.0))
		AudioServer.set_bus_volume_db(0, db)


static func _font(weight: int) -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Arial"])
	f.font_weight = weight
	return f


func is_open() -> bool:
	return root != null and root.visible


# the viewer's input, before its own (viewer.gd _input): true when the menu takes it (the viewer then leaves it
# alone, the menu's buttons and fields get it as usual)
func menu_input(event: InputEvent) -> bool:
	if leaving:
		return true
	if not capture.is_empty():
		return _capture_input(event)
	if event is InputEventKey and event.physical_keycode == KEY_ESCAPE and not event.pressed and esc_eat:
		esc_eat = false                                  # (the Esc that opened or closed the menu: not the game's)
		get_viewport().set_input_as_handled()
		return true
	if event is InputEventKey and event.pressed and not event.echo:
		var esc: bool = event.physical_keycode == KEY_ESCAPE
		var opens: bool = esc if guest else (_is_key(event, menu_key) or (esc and _esc_ours(event)))
		if opens and not is_open():
			if guest and _typing():
				return false
			open()
			esc_eat = esc
			get_viewport().set_input_as_handled()
			return true
		if is_open() and (esc or (not guest and _is_key(event, menu_key))):
			if page == "main":
				close()
			elif page != "closing":
				_show("main")
			esc_eat = esc
			get_viewport().set_input_as_handled()
			return true
	return is_open()


func _typing() -> bool:
	for n in v.get_children():                          # coop_net.gd's search or chat has the keys
		if n.has_method("wants_keys") and n.wants_keys():
			return true
	return false


# Esc alone, solo or host: this menu's in a mission's 3D view, the game's everywhere the game itself takes it (its
# menus and screens: its Options menu, briefings, the debriefing, the pause, a save's name being typed; a mission still loading),
# and where Uplink has its own use for it (the photo mode leaves; a field of the co-op lobby being typed in). With
# a modifier (Ctrl+Esc: the game's Abort mission) it stays the game's. Options can give Esc back to the game.
func _esc_ours(e: InputEventKey) -> bool:
	if not esc_menu or e.shift_pressed or e.ctrl_pressed or e.alt_pressed or e.meta_pressed:
		return false
	if v.get("menu_mode") or v.get("start_hold") or v.get("photo_on") or v.current.is_empty():
		return false
	if int(v.get("live_units_seen")) < 2 or _typing():
		return false
	return true


func _is_key(e: InputEventKey, key: Array) -> bool:
	var mods := (KEY_MASK_SHIFT if e.shift_pressed else 0) | (KEY_MASK_CTRL if e.ctrl_pressed else 0) | (KEY_MASK_ALT if e.alt_pressed else 0)
	return int(key[0]) != KEY_NONE and e.physical_keycode == int(key[0]) and mods == int(key[1])


func open() -> void:
	was_captured = Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if v.has_method("_play_release_all"):
		v._play_release_all()                            # nothing held into the menu (and the mouse freed)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_build()
	_show("main")


func close() -> void:
	capture = {}
	if root:
		root.visible = false
	if was_captured and v.get("play"):
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		v.play_started = true


# ---------------------------------------------------------------- the pieces
func _build() -> void:
	var vs: Vector2 = get_viewport().get_visible_rect().size
	k = clampf(vs.y / 1080.0, 0.7, 2.2)
	if root:
		root.queue_free()
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	layer.add_child(root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var th := Theme.new()
	th.default_font = font_r
	th.default_font_size = _px(19)
	for t in ["Label", "Button", "LineEdit", "CheckButton"]:
		th.set_color("font_color", t, TEXT)
	th.set_color("font_hover_color", "Button", Color.WHITE)
	th.set_color("font_focus_color", "Button", Color.WHITE)
	th.set_color("font_pressed_color", "Button", Color.WHITE)
	th.set_stylebox("normal", "Button", _sb(Color8(17, 34, 31), Color8(42, 74, 68), 1))
	th.set_stylebox("hover", "Button", _sb(Color8(24, 46, 42), Color8(80, 120, 110), 1))
	th.set_stylebox("pressed", "Button", _sb(Color8(30, 62, 56), ORANGE, 1))
	th.set_stylebox("focus", "Button", _sb(Color(0, 0, 0, 0), Color(1, 1, 1, 0.7), 1))
	th.set_stylebox("normal", "LineEdit", _sb(Color8(17, 34, 31), Color8(42, 74, 68), 1))
	th.set_stylebox("focus", "LineEdit", _sb(Color8(17, 34, 31), BLUE, 1))
	th.set_stylebox("panel", "PanelContainer", _sb(PANEL, LINE, 1, 8))
	th.set_constant("separation", "VBoxContainer", _px(8))
	th.set_constant("separation", "HBoxContainer", _px(10))
	root.theme = th
	box = PanelContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	root.add_child(box)


func _px(x: float) -> int:
	return maxi(9, roundi(x * k))


func _sb(bg: Color, edge: Color, w: int, r := 5) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = edge
	s.set_border_width_all(w)
	s.set_corner_radius_all(roundi(r * k))
	s.content_margin_left = 14 * k
	s.content_margin_right = 14 * k
	s.content_margin_top = 7 * k
	s.content_margin_bottom = 7 * k
	return s


func _title(parent: Control, text: String, col: Color) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", font_b)
	l.add_theme_font_size_override("font_size", _px(26))
	l.add_theme_color_override("font_color", col)
	parent.add_child(l)


func _button(parent: Control, text: String, fn: Callable, accent := Color(0, 0, 0, 0)) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(320 * k, 46 * k)
	b.add_theme_font_override("font", font_b)
	if accent.a > 0:
		b.add_theme_stylebox_override("normal", _sb(Color8(17, 34, 31), accent, 2))
	b.pressed.connect(fn)
	parent.add_child(b)
	return b


# the page's own size, centred: held by the anchors (the middle of the window) and offsets, not by a position, so the
# panel stays centred if the window changes, and grows on both sides alike if a page's content ever needs more (it
# then comes back to the page's size by itself once that content is gone: a Control's size follows its offsets and
# its minimum, a position set once would not shrink back nor stay centred)
func _place(w: float, h: float) -> void:
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var sz := Vector2(minf(w * k, vs.x - 40), minf(h * k, vs.y - 40)).round()
	box.custom_minimum_size = Vector2.ZERO
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.anchor_top = 0.5
	box.anchor_bottom = 0.5
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.offset_left = -floorf(sz.x * 0.5)
	box.offset_right = sz.x - floorf(sz.x * 0.5)
	box.offset_top = -floorf(sz.y * 0.5)
	box.offset_bottom = sz.y - floorf(sz.y * 0.5)


func _show(p: String) -> void:
	page = p
	capture = {}
	for c in box.get_children():
		box.remove_child(c)                              # (out at once: a page queued for freeing still counts in the
		c.queue_free()                                   # panel's minimum size until the frame ends: the next page grew to it)
	var col := VBoxContainer.new()
	box.add_child(col)
	match p:
		"main":
			_place(400, 424 if guest else 474)
			_title(col, "UPLINK", ORANGE if not guest else BLUE)
			var sub := Label.new()
			sub.text = "The game goes on meanwhile." if guest else "The game is not paused by this menu."
			sub.add_theme_color_override("font_color", DIM)
			sub.add_theme_font_size_override("font_size", _px(16))
			col.add_child(sub)
			var first := _button(col, "Resume", close)
			if not guest:
				_button(col, "Game menu", _game_menu).tooltip_text = "The game's own menu (O in the game): sound, detail, abort the mission, exit Terra Nova"
			_button(col, "Controls", func(): _show("controls"))
			_button(col, "Graphics", func(): _show("graphics"))
			_button(col, "Options", func(): _show("options"))
			_button(col, "Accessibility", func(): _show("access"))
			if guest:
				_button(col, "Leave the game", func(): _show("leave"), RED)
			else:
				_button(col, "Quit", func(): _show("quit"), RED)
			first.grab_focus()
		"quit":
			_place(560, 170)
			_title(col, "QUIT TERRA NOVA?", RED)
			var t := Label.new()
			t.text = "Unsaved mission progress is lost." + ("\nYour co-op guest is told you left." if _hosting() else "")
			t.autowrap_mode = TextServer.AUTOWRAP_WORD
			col.add_child(t)
			var row := HBoxContainer.new()
			col.add_child(row)
			var yes := _button(row, "Quit", quit_game, RED)
			yes.custom_minimum_size.x = 240 * k
			var no := _button(row, "Cancel", func(): _show("main"))
			no.custom_minimum_size.x = 240 * k
			no.grab_focus()
		"closing":
			_place(420, 110)
			_title(col, "CLOSING TERRA NOVA...", ORANGE)
		"graphics":
			_graphics(col)
		"leave":
			_place(520, 260)
			_title(col, "LEAVE THE GAME?", RED)
			var t := Label.new()
			t.text = "The host goes on: your squadmate goes back to the game's AI.\nYour window closes."
			t.autowrap_mode = TextServer.AUTOWRAP_WORD
			col.add_child(t)
			var row := HBoxContainer.new()
			col.add_child(row)
			var yes := _button(row, "Leave", leave, RED)
			yes.custom_minimum_size.x = 220 * k
			var no := _button(row, "Stay", func(): _show("main"))
			no.custom_minimum_size.x = 220 * k
			no.grab_focus()
		"options":
			_options(col)
		"access":
			_access(col)
		"controls":
			_controls(col)


# ---------------------------------------------------------------- options
# The launcher's player settings that are not Graphics (its In game > Controls and Squad, its Settings > Music, its
# Co-op > Gamepad), on two columns: SOUND and SQUAD, CONTROLS and START. Each saved where the launcher reads it
# (viewer.cfg [launcher], with the stamp it takes over; a guest's sound in [sound]); applied at once where Uplink can,
# else marked for the next start. What the launcher said at this start is in the environment (TN_...), which follows
# each change here, so the page shows the same when it is opened again.
const MUSIC := [["ROLAND", "Roland / GS"], ["FM", "FM"], ["GAME'S OWN", "Game's own"], ["AWE32", "AWE32"]]

func _options(col: VBoxContainer) -> void:
	_place(1120, 640 if guest else 680)
	_title(col, "OPTIONS", ORANGE)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", _px(36))
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(cols)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 520 * k
	cols.add_child(left)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	_head(left, "SOUND")
	if guest:
		var db := AudioServer.get_bus_volume_db(0)
		_slider(left, "Game sound", 0.0, 100.0, roundf(db_to_linear(db) * 100.0), func(x: float):
			AudioServer.set_bus_volume_db(0, linear_to_db(maxf(x, 0.1) / 100.0) if x > 0.5 else -80.0)
			_keep("sound", "guest_volume_db", AudioServer.get_bus_volume_db(0)), "%d %%")
		var mus := preload("res://scripts/coop_music.gd")    # the game's music (g5: coop_music.gd; 100 by default, 0 = off)
		_slider(left, "Music", 0.0, 100.0, mus.user_volume(), func(x: float): mus.set_user_volume(get_tree(), x), "%d %%")
		_head(left, "CO-OP")
		_movie_switch(left)
	else:
		_music(left)
		_head(left, "SQUAD")
		_switch(left, "Order wheel  (next start)", OS.get_environment("TN_ORDER_WHEEL") == "1", func(on: bool):
			_later("TN_ORDER_WHEEL", "order_wheel", on))
	_head(right, "CONTROLS")
	_slider(right, "Mouse speed", 0.2, 3.0, float(v.mouse_sens), func(x: float):
		v.mouse_sens = x
		_keep("launcher", "mouse", "%.1f" % x), "x %.1f", 0.1)
	_switch(right, "Invert mouse", bool(v.get("invert_y")), func(on: bool):
		v.invert_y = on
		_keep("launcher", "invert_y", "1" if on else "0"))
	_switch(right, "Gamepad", OS.get_environment("TN_NO_PAD") != "1", func(on: bool):
		OS.set_environment("TN_NO_PAD", "0" if on else "1")  # (pad_map.gd, coop_net.gd: read at each input)
		_keep("launcher", "gamepad", "1" if on else "0"))
	if not guest:
		_switch(right, "Run instead of Bound  (next start)", OS.get_environment("TN_RUN") == "1", func(on: bool):
			_later("TN_RUN", "shift_run", on))
		_switch(right, "Esc opens this menu", esc_menu, func(on: bool):
			esc_menu = on
			_keep("launcher", "esc_menu", "1" if on else "0"))
		_note(right, "In a mission. Off: Esc goes to the game as before; %s opens this menu. The game's own menu: O (or Game menu here)." % _menu_key_name())
		_head(right, "START")
		_switch(right, "Skip the intro videos  (next start)", OS.get_environment("TN_SKIP_INTRO") == "1", func(on: bool):
			_later("TN_SKIP_INTRO", "skip_intro", on))
	_note(right, "Each setting is kept for the next games, and the launcher shows it the same. The old school look and Uplink's extras: Graphics. The subtitles: Accessibility.")
	var back := _button(col, "Back", func(): _show("main"))
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


# the game's music device: Terra Nova Plus's, set in DOSBox when the game starts (the launcher writes it to the
# TNPlus.ini files when it takes this over: Uplink never writes into TN+'s files), so for the next start; the AWE32
# ROM as the launcher found it (its Settings page picks it: no Browse here)
func _music(col: Control) -> void:
	var now := OS.get_environment("TN_MUSIC").to_upper()
	var at := -1
	for i in MUSIC.size():
		if MUSIC[i][0] == now:
			at = i
	var line := Label.new()
	_seg(col, "Music", MUSIC.map(func(m): return m[1]), at, func(i: int):
		OS.set_environment("TN_MUSIC", MUSIC[i][0])
		_keep("launcher", "music", MUSIC[i][0])
		_rom_line(line, i))
	line.autowrap_mode = TextServer.AUTOWRAP_WORD
	line.add_theme_font_size_override("font_size", _px(15))
	col.add_child(line)
	_rom_line(line, at)


func _rom_line(l: Label, i: int) -> void:
	var rom := OS.get_environment("TN_AWE32")
	var t := "At the game's next start."
	if rom == "1":
		t += "  AWE32 ROM: found."
	elif rom == "0":
		t += "  AWE32 ROM: not found" + (" - Roland / GS plays instead (the launcher's Settings page picks your own dump)." if i == 3 else ".")
	l.text = t
	l.add_theme_color_override("font_color", Color8(240, 180, 60) if rom == "0" and i == 3 else DIM)


# a setting the launcher gives at the start only (the bridge's): kept, and shown so when the page opens again
func _later(env: String, key: String, on: bool) -> void:
	OS.set_environment(env, "1" if on else "0")
	_keep("launcher", key, "1" if on else "0")


# ---------------------------------------------------------------- accessibility
# The launcher's Settings > Accessibility: the squadmates' subtitles (each player his own: a co-op guest too),
# their size, the colour-blind mode (colour_vision.gd). All at once; kept in viewer.cfg [launcher] as the others.
const SUB_SIZES := ["Normal", "Large", "Larger"]
const CV_NOTES := ["The game's colours.",
	"Red and green look alike: the target's green turns cyan, hostile red turns raspberry.",
	"Red and green look alike: the target's green turns cyan, hostile red turns magenta.",
	"Blue and green look alike: the target's green turns yellow-green.",
]

func _access(col: VBoxContainer) -> void:
	_place(860, 470)
	_title(col, "ACCESSIBILITY", ORANGE)
	_head(col, "SUBTITLES")
	_switch(col, "Squadmates' subtitles  (their radio lines)", bool(v.get("subs_on")), func(on: bool):
		_set_subs(on)
		_keep("launcher", "subtitles", "1" if on else "0"))
	_seg(col, "Size", SUB_SIZES, clampi(int(v.get("subs_size")), 0, 2), func(i: int):
		v.subs_size = i
		OS.set_environment("TN_SUBTITLE_SIZE", str(i))
		if v.subs_view != null:
			v.subs_view.big = v.SUBS_SIZES[i]
			v.subs_view.queue_redraw()
		_keep("launcher", "subtitle_size", str(i)))
	_head(col, "COLOUR-BLIND MODE")
	var cv := preload("res://scripts/colour_vision.gd")
	var line := Label.new()
	_seg(col, "Colours", cv.NAMES, maxi(0, cv.MODES.find(cv.mode)), func(i: int):
		cv.set_mode(cv.MODES[i])
		if v.has_method("cv_apply"):
			v.cv_apply()
		for n in v.get_children():                       # (a guest's HUD: drawn again in the new colours)
			if n.has_method("cv_changed"):
				n.cv_changed()
		line.text = CV_NOTES[i]
		_keep("launcher", "colour_vision", cv.MODES[i]))
	line.text = CV_NOTES[maxi(0, cv.MODES.find(cv.mode))]
	line.autowrap_mode = TextServer.AUTOWRAP_WORD
	line.add_theme_color_override("font_color", DIM)
	line.add_theme_font_size_override("font_size", _px(15))
	col.add_child(line)
	_note(col, "Only Uplink's marks change: the target, hostile units (also a small triangle over their brackets), the armour and squad levels. Each setting is kept for the next games, and the launcher shows it the same.")
	var back := _button(col, "Back", func(): _show("main"))
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


# the squadmates' subtitles at once: the viewer shows them or not, the bridge reads them or stops (its 'SUBS')
func _set_subs(on: bool) -> void:
	v.subs_on = on
	OS.set_environment("TN_SUBTITLES", "1" if on else "0")
	if not on:
		v.subs.clear()
		if v.subs_view != null:
			v.subs_view.visible = false
	if v.get("play_udp") != null and not guest:          # (a co-op guest's: his window only, the host's bridge
		v._play_send(("SUBS" + ("1" if on else "0")).to_ascii_buffer())   # always sends them)


func _note(col: Control, text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD
	l.add_theme_color_override("font_color", DIM)
	l.add_theme_font_size_override("font_size", _px(15))
	col.add_child(l)
	return l


func _head(col: Control, text: String) -> void:
	var h := Label.new()
	h.text = text
	h.add_theme_font_override("font", font_b)
	h.add_theme_color_override("font_color", ORANGE)
	h.add_theme_font_size_override("font_size", _px(15))
	col.add_child(h)


func _menu_key_name() -> String:
	if model == null:
		model = Controls.new()
	var n: String = model.name_of(model.find("menu")["key"])
	return n if n != "" else "Uplink's menu key"


func _hosting() -> bool:
	for n in v.get_children():
		if n.get("steam") and n.get("lobby_id") and n.get("peer"):
			return true
	return false


# ---------------------------------------------------------------- graphics
# The launcher's In game > Display and Extras, and its window mode, as one page: each saved where the launcher reads
# it (viewer.cfg [launcher], with the stamp it takes over; the pixel size in [look] as it already was), so the
# launcher shows the same. Applied at once where Uplink can; the rest is marked for the next start.
func _graphics(col: VBoxContainer) -> void:
	_place(1120, 800)
	_title(col, "GRAPHICS", ORANGE)
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	_preset_row(col)
	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", _px(36))
	cols.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(cols)
	var left := VBoxContainer.new()
	left.custom_minimum_size.x = 560 * k
	cols.add_child(left)
	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols.add_child(right)
	_head(left, "DISPLAY")
	_switch(left, "Old school look", bool(v.oldschool_rect != null and v.oldschool_rect.visible), func(on: bool):
		_set_old(on)
		_keep("launcher", "old_school", "1" if on else "0")
		_gfx_touched())
	var sharp_at := 0
	for i in SHARP.size():
		if int(SHARP[i][0]) == int(v.get("old_sharp")):
			sharp_at = i
	_seg(left, "Pixels", SHARP.map(func(s): return s[1]), sharp_at, func(i: int): _set_sharp(int(SHARP[i][0])))
	if not guest:
		_switch(left, "Uplink HUD colours", bool(v.get("hud_colours")), func(on: bool):
			_set_hud_colours(on)
			_keep("launcher", "hud_colours", "1" if on else "0")
			_gfx_touched())
		var ci := 0
		for i in CROSS.size():
			if CROSS[i][0] == str(v.get("crosshair")):
				ci = i
		_seg(left, "Crosshair", CROSS.map(func(c): return c[1]), ci, func(i: int):
			v.crosshair = CROSS[i][0]
			_keep("launcher", "crosshair", CROSS[i][0]))
	var caps := CAPS.duplicate()
	if Engine.max_fps > 0 and not caps.has(Engine.max_fps):
		caps.append(Engine.max_fps)                      # (another chosen in the launcher: "Other...")
	_seg(left, "Frame limit", caps.map(func(c): return "Unlimited" if c == 0 else str(c)), caps.find(Engine.max_fps), func(i: int):
		Engine.max_fps = caps[i]
		_keep("launcher", "fps_cap", str(caps[i])))
	var fl = v.get("fps_label")
	_switch(left, "Frame counter", fl != null and fl.visible, func(on: bool):
		if v.get("fps_label") != null:
			v.fps_label.visible = on
		_keep("launcher", "fps_counter", "1" if on else "0"))
	_head(left, "WINDOW  (at the next start)")
	var win: String = str(cfg.get_value("launcher", "window", ""))
	if get_window().mode == Window.MODE_FULLSCREEN or get_window().mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		win = "native" if win == "" else win
	elif win == "":
		win = "%dx%d" % [get_window().size.x, get_window().size.y]
	var wi := -1
	for i in SIZES.size():
		if SIZES[i][0] == win:
			wi = i
	_seg(left, "Mode", SIZES.map(func(s): return s[1]), wi, func(i: int): _keep("launcher", "window", SIZES[i][0]))
	_head(right, "EXTRAS  (Uplink's own, not in the game)")
	for fx in FX:
		if guest and not fx[2]:
			continue                                     # (the host's only: his shots, his own legs)
		var id: String = fx[0]
		var later: bool = id == "look_down"
		_switch(right, str(fx[1]) + ("  (next start)" if later else ""), _fx_on(id), func(x: bool):
			_set_fx(id, x)
			_keep("launcher", "fx_" + id, "1" if x else "0")
			_gfx_touched())
	_note(right, "Each setting is kept for the next games, and the launcher shows it the same.")
	var back := _button(col, "Back", func(): _show("main"))
	back.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


# a choice among a few: a row of buttons, the chosen one lit (no drop-down: its list would be a window of its own)
func _seg(col: Control, text: String, items: Array, sel: int, fn: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", _px(4))
	col.add_child(row)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 140 * k
	row.add_child(l)
	var grp := ButtonGroup.new()
	for i in items.size():
		var b := Button.new()
		b.text = str(items[i])
		b.toggle_mode = true
		b.button_group = grp
		b.button_pressed = i == sel
		b.custom_minimum_size = Vector2(0, 34 * k)
		b.add_theme_font_size_override("font_size", _px(16))
		b.add_theme_stylebox_override("pressed", _sb(Color8(30, 62, 56), ORANGE, 2))
		b.toggled.connect(func(on: bool):
			if on:
				fn.call(i))
		row.add_child(b)


func _set_sharp(s: int) -> void:
	v.old_sharp = s
	v._oldschool_grid()
	var cfg := ConfigFile.new()                          # (where Shift+the old school key keeps it, and the launcher reads it)
	cfg.load(CFG)
	cfg.set_value("look", "old_sharp", s)
	cfg.save(CFG)


func _set_hud_colours(on: bool) -> void:
	v.hud_colours = on
	v.hud_places = PackedByteArray()                     # (on: set again from the bridge's next picture)
	if not on and v.get("hud_rect") != null and v.hud_rect.material is ShaderMaterial:
		(v.hud_rect.material as ShaderMaterial).set_shader_parameter("energy", Vector4.ZERO)
		(v.hud_rect.material as ShaderMaterial).set_shader_parameter("armour", Vector4.ZERO)


const PRESET_LINES := ["As in 1996: old school look, no extras", "Old look, small extras", "Everything on",
	"For older PCs: the costliest extras off", "Your own mix"]
var preset_btns: Array = []
var preset_line: Label
var preset_quiet := false            # (the buttons set from here: not a choice of the player's)


func _preset_now() -> String:
	var p := OS.get_environment("TN_GFX_PRESET")
	return p if PRESET_IDS.has(p) else "custom"


# the preset's row over the page's two columns: picked, it sets every switch below (at once where Uplink can) and the
# page is drawn again with them
func _preset_row(col: Control) -> void:
	_head(col, "PRESET")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", _px(4))
	col.add_child(row)
	var grp := ButtonGroup.new()
	preset_btns = []
	var at := PRESET_IDS.find(_preset_now())
	for i in PRESET_IDS.size():
		var b := Button.new()
		b.text = PRESET_NAMES[i]
		b.toggle_mode = true
		b.button_group = grp
		b.button_pressed = i == at
		b.custom_minimum_size = Vector2(118 * k, 34 * k)
		b.add_theme_font_size_override("font_size", _px(16))
		b.add_theme_stylebox_override("pressed", _sb(Color8(30, 62, 56), ORANGE, 2))
		b.toggled.connect(func(on: bool):
			if on and not preset_quiet:
				_pick_preset(PRESET_IDS[i]))
		row.add_child(b)
		preset_btns.append(b)
	var gap := Control.new()
	gap.custom_minimum_size.x = 12 * k
	row.add_child(gap)
	preset_line = Label.new()
	preset_line.text = PRESET_LINES[at]
	preset_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # (in its own cell: a long line wraps, never widens the panel)
	preset_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	preset_line.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preset_line.add_theme_color_override("font_color", DIM)
	preset_line.add_theme_font_size_override("font_size", _px(15))
	row.add_child(preset_line)


func _pick_preset(id: String) -> void:
	OS.set_environment("TN_GFX_PRESET", id)
	_keep("launcher", "gfx_preset", id)
	if PRESETS.has(id):
		apply_preset(id)
	_show("graphics")                                    # (every switch drawn again as the preset left it)


# a preset's values applied (live where Uplink can, the rest at the next start) and kept for the launcher
func apply_preset(id: String) -> void:
	var vals: Array = PRESETS[id]
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	for i in PRESET_KEYS.size():
		var key: String = PRESET_KEYS[i]
		var on: bool = int(vals[i]) == 1
		if key == "old_school":
			_set_old(on)
			cfg.set_value("launcher", "old_school", "1" if on else "0")
		elif key == "hud_colours":
			if not guest:
				_set_hud_colours(on)
			cfg.set_value("launcher", "hud_colours", "1" if on else "0")
		else:
			_set_fx(key, on)
			cfg.set_value("launcher", "fx_" + key, "1" if on else "0")
	cfg.set_value("launcher", "gfx_preset", id)
	cfg.set_value("launcher", "stamp", int(Time.get_unix_time_from_system()))
	cfg.save(CFG)


# a switch of the page changed by hand: the preset becomes "custom" (the values stay as they are)
func _gfx_touched() -> void:
	if _preset_now() == "custom":
		return
	OS.set_environment("TN_GFX_PRESET", "custom")
	_keep("launcher", "gfx_preset", "custom")
	preset_quiet = true
	if preset_btns.size() == PRESET_IDS.size() and is_instance_valid(preset_btns[4]):
		(preset_btns[4] as Button).button_pressed = true
	preset_quiet = false
	if preset_line != null and is_instance_valid(preset_line):
		preset_line.text = PRESET_LINES[4]


func _set_old(on: bool) -> void:
	if v.oldschool_rect != null and v.oldschool_rect.visible != on:
		v._oldschool_toggle()
	elif v.oldschool_rect == null:
		OS.set_environment("TN_OLDSCHOOL", "1" if on else "0")


func _fx_on(id: String) -> bool:
	return OS.get_environment("TN_FX_" + id.to_upper()) != "0"


# an extra on or off at once: its own node made or freed (as viewer.gd _extras makes them), its shader switch set;
# the environment follows, for what the viewer makes again later (a new map's ground, a guest's window)
func _set_fx(id: String, on: bool) -> void:
	OS.set_environment("TN_FX_" + id.to_upper(), "1" if on else "0")
	if FX_NODES.has(id):
		var have: Node = null
		for n in v.get_children():
			if n.get_script() != null and (n.get_script() as Script).resource_path.get_file() == FX_NODES[id]:
				have = n
		if on and have == null:
			var x: Node = load("res://scripts/" + FX_NODES[id]).new()
			x.v = v
			if id != "tracks":
				x.shots = v._fx_shots()
			v.add_child(x)
		elif not on and have != null:
			have.queue_free()
	elif id == "cloud_shadows":
		v.fx_cloud_shadows = on
		v.cloud_cover = v._cloud_cover(v.sky_clouds) if on and v.sky_clouds != null and int(v.mis_params.get("weather_kind", 0)) == 0 else null
		var gm: Array = v.ground_mats + ([v.mats["water"]] if v.mats.has("water") else [])
		for sm in gm:
			sm.set_shader_parameter("cloud_shadows", false)
			if on:
				v._sky_to(sm)                                # (its shadows set again as a new mission sets them)
	elif id == "stars":
		v.fx_stars = on
		if not on and v.env != null and v.env.sky != null and v.env.sky.sky_material is ShaderMaterial:
			(v.env.sky.sky_material as ShaderMaterial).set_shader_parameter("star_scale", 0.0)
	elif id == "cliffs":
		for sm in v.ground_mats:
			sm.set_shader_parameter("cliffs", on)
	elif id == "own_body":
		if v.get("look_dn") != null:
			v.look_dn.body_on = on                       # (the legs hidden at the next frame; the look down stays)


# the host's briefings and other videos played in the guest's window (coop_movie.gd), or the text briefing only
func _movie_switch(col: Control) -> void:
	for n in v.get_children():
		var m = n.get("movie_node")
		if m is Node:
			_switch(col, "Briefing videos", bool(m.on), func(x: bool):
				m.set_on(x)
				_keep("launcher", "coop_videos", "1" if x else "0"))
			return


func _keep(section: String, key: String, value) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	cfg.set_value(section, key, value)
	if section == "launcher":
		cfg.set_value("launcher", "stamp", int(Time.get_unix_time_from_system()))
	cfg.save(CFG)


func _slider(col: Control, text: String, lo: float, hi: float, val: float, fn: Callable, fmt: String, step := 1.0) -> void:
	var row := HBoxContainer.new()
	col.add_child(row)
	var l := Label.new()
	l.text = text
	l.custom_minimum_size.x = 200 * k
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = clampf(val, lo, hi)
	s.custom_minimum_size = Vector2(220 * k, 30 * k)
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(s)
	var n := Label.new()
	n.text = fmt % s.value
	n.add_theme_color_override("font_color", DIM)
	row.add_child(n)
	s.value_changed.connect(func(x: float):
		n.text = fmt % x
		fn.call(x))


func _switch(col: Control, text: String, on: bool, fn: Callable) -> void:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(fn)
	col.add_child(c)


# ---------------------------------------------------------------- controls
func _controls(col: VBoxContainer) -> void:
	_place(1180, 900)
	if model == null:
		model = Controls.new()
	var top := HBoxContainer.new()
	col.add_child(top)
	_title(top, "CONTROLS", ORANGE)
	search = LineEdit.new()
	search.placeholder_text = "Search"
	search.custom_minimum_size = Vector2(260 * k, 36 * k)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(func(_t): _fill_rows())
	top.add_child(search)
	var heads := HBoxContainer.new()
	col.add_child(heads)
	for h in [["", 470], ["KEY", 190], ["MOUSE", 170], ["GAMEPAD", 200]]:
		var l := Label.new()
		l.text = h[0]
		l.custom_minimum_size.x = h[1] * k
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if h[0] != "" else HORIZONTAL_ALIGNMENT_LEFT
		l.add_theme_color_override("font_color", DIM)
		l.add_theme_font_size_override("font_size", _px(14))
		heads.add_child(l)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	col.add_child(sc)
	rows_box = VBoxContainer.new()
	rows_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows_box.add_theme_constant_override("separation", _px(3))
	sc.add_child(rows_box)
	note_label = Label.new()
	note_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	note_label.add_theme_color_override("font_color", DIM)
	note_label.add_theme_font_size_override("font_size", _px(15))
	note_label.text = ("Your keys change at once (they are kept for the next game too)." if guest else
			("Esc opens this menu in a mission (Options), %s too; its Game menu is the game's own menu (O). " % _menu_key_name() if esc_menu else "") +
			"Uplink's keys change at once. The game's keys change at the next start of the game (Terra Nova Plus reads them when it starts).") + \
			"  Keys are places on the keyboard: the name shown is yours."
	col.add_child(note_label)
	var bottom := HBoxContainer.new()
	col.add_child(bottom)
	var rs := _button(bottom, "Reset all to defaults", _reset)
	rs.custom_minimum_size.x = 300 * k
	var bk := _button(bottom, "Back", func(): _show("main"))
	bk.custom_minimum_size.x = 200 * k
	_fill_rows()
	search.grab_focus()


func _fill_rows() -> void:
	if rows_box == null:
		return
	for c in rows_box.get_children():
		c.queue_free()
	var q := search.text.strip_edges().to_lower() if search else ""
	var clash: Dictionary = model.conflicts()
	for g in GROUPS:
		var any := false
		for c in model.cmds:
			if c["group"] != g or (guest and c["kind"] == "tnplus" and c["id"] != "freelook") or (guest and c["id"] in ["order", "photo"]):
				continue
			if q != "" and not str(c["name"]).to_lower().contains(q) and not g.to_lower().contains(q):
				continue
			if not any:
				var h := Label.new()
				h.text = g.to_upper()
				h.add_theme_font_override("font", font_b)
				h.add_theme_color_override("font_color", BLUE if g == "Uplink" else ORANGE)
				h.add_theme_font_size_override("font_size", _px(15))
				rows_box.add_child(h)
				any = true
			_row(c, clash.get(c["id"], "") if c["kind"] != "pad" else "")
	if q == "":
		_sticks()


func _row(c: Dictionary, clash: String) -> void:
	var row := HBoxContainer.new()
	rows_box.add_child(row)
	var l := Label.new()
	l.text = str(c["name"]) + ("   (also " + clash + ")" if clash != "" else "")
	l.custom_minimum_size.x = 470 * k
	l.clip_text = true
	if clash != "":
		l.add_theme_color_override("font_color", RED)
	row.add_child(l)
	var kb := Button.new()
	kb.text = model.name_of(c["key"])
	kb.custom_minimum_size = Vector2(180 * k, 32 * k)
	kb.disabled = c["kind"] == "fixed"
	if c["key"] != c["def"]:
		kb.add_theme_color_override("font_color", ORANGE)
	kb.pressed.connect(func(): _ask(c, "key", kb))
	row.add_child(kb)
	if c["kind"] == "pad" or (guest and c["id"] == "menu"):
		kb.text = "Esc" if c["id"] == "menu" else ""      # (a guest's menu is on Esc; the pad's own: no key)
		kb.disabled = true
	if c["kind"] == "game" or c["kind"] == "tnplus":
		var mb := Button.new()
		mb.text = Controls.MOUSE_SHORT[int(c["mouse"])] if int(c["mouse"]) > 0 else "+"
		mb.custom_minimum_size = Vector2(160 * k, 32 * k)
		mb.pressed.connect(func(): _ask(c, "mouse", mb))
		row.add_child(mb)
	_pad_cell(row, c)


func _ask(c: Dictionary, column: String, b: Button) -> void:
	capture = {"id": c["id"], "column": column, "button": b}
	if column == "pad":
		b.text = "Press..."
		note_label.text = "Press a button on the gamepad (or a trigger, or push a stick).  Esc: as it was.  Backspace: none."
		return
	b.text = "Press..." if column == "key" else "Click / wheel..."
	note_label.text = ("Press the new key, alone or with Shift, Ctrl or Alt." if column == "key" else
			"The middle or a side mouse button, the wheel, or PgUp / PgDn, Home / End, Ins / Del.") + "  Esc: as it was.  Backspace: none."


func _capture_input(event: InputEvent) -> bool:
	var id: String = capture["id"]
	var column: String = capture["column"]
	var c: Dictionary = model.find(id)
	if column == "pad":
		return _capture_pad(event, c)
	if event is InputEventKey and event.pressed and not event.echo:
		var pk: Key = event.physical_keycode
		get_viewport().set_input_as_handled()
		if pk in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
			return true
		if pk == KEY_ESCAPE:
			capture = {}
			_fill_rows()
			return true
		if pk == KEY_BACKSPACE:
			if column == "key":
				model.set_key(id, [0, 0])
			else:
				model.set_mouse(id, 0)
			_apply(c)
			return true
		if column == "mouse":
			var mi: int = {KEY_PAGEUP: 6, KEY_PAGEDOWN: 7, KEY_HOME: 8, KEY_END: 9, KEY_INSERT: 10, KEY_DELETE: 11}.get(pk, 0)
			if mi > 0:
				model.set_mouse(id, mi)
				_apply(c)
			return true
		var sc: int = model.scancodes.get(pk, 0)
		if sc == 0:
			note_label.text = "Uplink can't use that key: another one."
			return true
		var mods := (1 if event.shift_pressed else 0) | (2 if event.ctrl_pressed else 0) | (4 if event.alt_pressed else 0)
		if c["kind"] != "uplink" and (mods & 3) and (mods & 4):
			mods = 4                                     # (the game takes one modifier)
		model.set_key(id, [sc, mods if c["kind"] != "tnplus" else 0])
		_apply(c)
		return true
	if event is InputEventMouseButton and event.pressed:
		var bi: int = event.button_index
		var mi := 0
		if bi == MOUSE_BUTTON_MIDDLE:
			mi = 1
		elif bi == MOUSE_BUTTON_XBUTTON1:
			mi = 2
		elif bi == MOUSE_BUTTON_XBUTTON2:
			mi = 3
		elif bi == MOUSE_BUTTON_WHEEL_UP:
			mi = 4
		elif bi == MOUSE_BUTTON_WHEEL_DOWN:
			mi = 5
		if mi == 0:
			return false                                 # (a click elsewhere: the menu's own buttons)
		get_viewport().set_input_as_handled()
		if column == "mouse":
			model.set_mouse(id, mi)
			_apply(c)
		elif id == "order" and mi <= 3:
			model.set_key(id, [[0, Controls.MID, Controls.M4, Controls.M5][mi], 0])
			_apply(c)
		return true
	return true


func _reset() -> void:
	if model == null:
		return
	model.reset()
	for c in model.cmds:
		_apply(c, false)
	_saved()
	_fill_rows()


func _apply(c: Dictionary, save := true) -> void:
	capture = {}
	if save:
		_saved()
	_to_viewer()
	_fill_rows()


func _saved() -> void:
	model.save_tnplus()
	model.save_uplink()
	model.save_pad()


# what can change at once in this window: Uplink's keys, the free look's, a guest's game keys (his own Uplink turns
# them before sending), the second binds (Uplink presses their key)
func _to_viewer() -> void:
	var o: Dictionary = model.find("oldschool")
	var arr := []
	for id in ["oldschool", "sharp", "shot", "fps"]:
		arr.append(_godot_key(model.find(id)["key"]))
	v.own_keys = arr
	v.photo_key = _godot_key(model.find("photo")["key"])
	var ok: Array = model.find("order")["key"]
	if int(ok[0]) < 0:
		v.order_key = [{-1: MOUSE_BUTTON_MIDDLE, -2: MOUSE_BUTTON_XBUTTON1, -3: MOUSE_BUTTON_XBUTTON2}[int(ok[0])], KEY_NONE, 0]
	elif int(ok[0]) > 0:
		var gk := _godot_key(ok)
		v.order_key = [0, gk[0], gk[1]]
	menu_key = _godot_key(model.find("menu")["key"])
	var fl: Array = model.find("freelook")["key"]
	var pk: Key = model.physical(int(fl[0]))
	if pk != KEY_NONE:
		v.look_key = pk
	if guest:
		v.key_map = model.key_map()
	else:
		v.binds = _binds()
	if v.get("pad_map"):
		v.pad_map.reload(model)                          # (the gamepad: at once)


func _godot_key(key: Array) -> Array:
	if model == null:
		model = Controls.new()
	var pk: Key = model.physical(int(key[0]))
	var m := (KEY_MASK_SHIFT if int(key[1]) & 1 else 0) | (KEY_MASK_CTRL if int(key[1]) & 2 else 0) | (KEY_MASK_ALT if int(key[1]) & 4 else 0)
	return [pk, m]


# the second binds, as the launcher's TN_BINDS: an input -> the player's key for that command ([] the look swap)
func _binds() -> Dictionary:
	var d := {}
	for c in model.cmds:
		var mi := int(c["mouse"])
		if mi <= 0:
			continue
		var name: String = Controls.MOUSE_INI[mi]
		if c["id"] == "freelook":
			d[name] = []
		elif c["kind"] == "game" and int(c["key"][0]) > 0:
			var m := int(c["key"][1])
			d[name] = [int(c["key"][0]), 0x38 if m & 4 else 0x1D if m & 2 else 0x2A if m & 1 else 0]
	return d


# ---------------------------------------------------------------- leaving (the guest)
func leave() -> void:
	if leaving:
		return
	leaving = true
	if root:
		root.visible = false
	if v.has_method("_play_release_all"):
		v._play_release_all()
	if v.has_method("_play_send"):
		v._play_send("X".to_ascii_buffer())              # the host's bridge: his teammate back to the game's AI
	v.play = false                                       # (nothing more from this window: a packet after 'X' takes the
	var t := get_tree().create_timer(0.7)                 # teammate again) (coop_net.gd sends it on: then out of the lobby)
	t.timeout.connect(func():
		v._play_send("X".to_ascii_buffer())              # (once more, last)
		leave_steam(v)
		get_tree().quit())


# out of the co-op lobby (coop_net.gd): the other side is told at once (a guest who leaves: the host gives his
# teammate back to the game's AI; a host who quits: his guest gets "the host left - waiting for an invite")
static func leave_steam(viewer: Node) -> void:
	for n in viewer.get_children():
		if n.get("steam") and n.get("lobby_id"):
			if n.peer:
				n.steam.closeP2PSessionWithUser(n.peer)
			n.steam.leaveLobby(n.lobby_id)
			n.lobby_id = 0


# ---------------------------------------------------------------- the game's own menu, quitting (solo / host)
# "Game menu": the game's own menu in a mission, its Options key (O: fixed in the game, controls.txt "options";
# Esc alone does nothing in a mission's 3D view, measured: Ctrl+Esc is its Abort mission). Sent as the key would be:
# its screen comes, Uplink shows it, and Esc is the game's there.
const GAME_MENU_SC := 0x18

func _game_menu() -> void:
	close()
	v._key_hold(GAME_MENU_SC, "umenu", true)
	get_tree().create_timer(0.12).timeout.connect(func(): v._key_hold(GAME_MENU_SC, "umenu", false))


# "Quit": the bridge closes the game (as the launcher's STOP: its window asked to close, ended after 3 s) and stops;
# Uplink closes itself meanwhile. The launcher then finds its bridge gone and closes what is left of what it started
# (Terra Nova Plus): as after STOP. A host's guest is told he left (leave_steam).
func quit_game() -> void:
	if leaving:
		return
	leaving = true
	_show("closing")
	if v.has_method("_play_release_all"):
		v._play_release_all()
	leave_steam(v)
	v._play_send("QUIT".to_ascii_buffer())
	get_tree().create_timer(0.3).timeout.connect(func(): v._play_send("QUIT".to_ascii_buffer()))
	get_tree().create_timer(1.5).timeout.connect(func(): get_tree().quit())


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and guest:
		leave()


# ---------------------------------------------------------------- the first mission's line
func _process(delta: float) -> void:
	if hint_done or not v.get("play") or not v.get("play_started") or v.get("menu_mode") or v.current.is_empty() or int(v.get("live_units_seen")) < 2:
		if hint_t >= 0.0:
			_hint_fade(delta)
		return
	if hint_t < 0.0:
		_hint_show()
	_hint_fade(delta)


func _hint_show() -> void:
	if model == null:
		model = Controls.new()
	var parts := []
	parts.append(("Esc" if guest or esc_menu else model.name_of(model.find("menu")["key"])) + ": menu")
	parts.append(model.name_of(model.find("freelook")["key"]) + ": free look")
	if v.get("order_on") and not guest:
		parts.append(model.name_of(model.find("order")["key"]) + ": orders")
	if guest:
		parts.append("M: map")
	hint = Label.new()
	hint.text = "  ·  ".join(parts)
	hint.add_theme_font_override("font", font_b)
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var kk := clampf(vs.y / 1080.0, 0.7, 2.2)
	hint.add_theme_font_size_override("font_size", maxi(12, roundi(24 * kk)))
	hint.add_theme_color_override("font_color", Color.WHITE)
	hint.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hint.add_theme_constant_override("outline_size", maxi(2, roundi(6 * kk)))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.10, 0.094, 0.75)
	sb.border_color = BLUE if guest else ORANGE
	sb.border_width_left = roundi(4 * kk)
	sb.set_content_margin_all(10 * kk)
	hint.add_theme_stylebox_override("normal", sb)
	layer.add_child(hint)
	hint.reset_size()
	hint.position = Vector2(roundf((vs.x - hint.size.x) * 0.5), roundf(vs.y * 0.18))
	hint_t = 0.0


func _hint_fade(delta: float) -> void:
	if hint == null:
		return
	hint_t += delta
	hint.modulate.a = clampf((7.0 - hint_t) / 1.5, 0.0, 1.0)
	if hint_t > 7.0:
		hint.queue_free()
		hint = null
		hint_done = true


# ---------------------------------------------------------------- the guest's gamepad (pad_map.gd, controls.gd)
func _ps() -> bool:
	var pads := Input.get_connected_joypads()
	return pads.size() > 0 and Controls.playstation(Input.get_joy_name(pads[0]))


func _pad_cell(row: HBoxContainer, c: Dictionary) -> void:
	if c["kind"] != "game" and c["kind"] != "tnplus" and c["kind"] != "fixed":
		var gap := Control.new()                         # (no mouse column on this row: the pad's stays in its place)
		gap.custom_minimum_size.x = 160 * k
		row.add_child(gap)
	if not model.pad_ok(c):
		return
	var pb := Button.new()
	var clash: String = model.pad_conflicts().get(c["id"], "")
	pb.text = Controls.pad_name(str(c["pad"]), _ps())
	pb.custom_minimum_size = Vector2(190 * k, 32 * k)
	pb.tooltip_text = ("Also " + clash) if clash != "" else ""
	if clash != "":
		pb.add_theme_color_override("font_color", RED)
	elif str(c["pad"]) != str(c["pad_def"]):
		pb.add_theme_color_override("font_color", ORANGE)
	pb.pressed.connect(func(): _ask(c, "pad", pb))
	row.add_child(pb)
	if clash != "" and row.get_child(0) is Label:
		(row.get_child(0) as Label).text += "   (pad: also " + clash + ")"
		(row.get_child(0) as Label).add_theme_color_override("font_color", RED)


func _capture_pad(event: InputEvent, c: Dictionary) -> bool:
	var got := ""
	if event is InputEventKey and event.pressed and not event.echo:
		get_viewport().set_input_as_handled()
		if event.physical_keycode == KEY_ESCAPE:
			capture = {}
			_fill_rows()
		elif event.physical_keycode == KEY_BACKSPACE:
			model.set_pad(c["id"], "")
			_apply(c)
		return true
	if event is InputEventJoypadButton and event.pressed:
		got = "B%d" % event.button_index
	elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.6:
		got = "A%d%s" % [event.axis, "+" if event.axis_value > 0 or event.axis >= 4 else "-"]
	if got == "":
		return not (event is InputEventMouseButton)      # (a click: the menu's own buttons)
	get_viewport().set_input_as_handled()
	pad_frame = Engine.get_process_frames()             # (pad_map.gd leaves this press alone)
	model.set_pad(c["id"], got)
	_apply(c)
	var clash: String = model.pad_conflicts().get(c["id"], "")
	note_label.text = "%s: %s.%s" % [c["name"], Controls.pad_name(got, _ps()),
			("  Also on " + clash + ": change one of them.") if clash != "" else ""]
	return true


# the sticks: which one moves, how fast the other looks, up / down, the dead zone, the triggers' threshold
func _sticks() -> void:
	var h := Label.new()
	h.text = "GAMEPAD STICKS"
	h.add_theme_font_override("font", font_b)
	h.add_theme_color_override("font_color", ORANGE)
	h.add_theme_font_size_override("font_size", _px(15))
	rows_box.add_child(h)
	var s: Dictionary = model.sticks
	var pads := Input.get_connected_joypads()
	var info := Label.new()
	info.text = ("Gamepad: " + Input.get_joy_name(pads[0])) if pads.size() > 0 else "No gamepad seen (the settings are kept for when one is plugged in)."
	info.add_theme_color_override("font_color", DIM)
	rows_box.add_child(info)
	_slider(rows_box, "Look speed, left / right", 0.25, 2.0, float(s["sens_x"]), func(x): _stick("sens_x", x), "%.2f", 0.05)
	_slider(rows_box, "Look speed, up / down", 0.25, 2.0, float(s["sens_y"]), func(x): _stick("sens_y", x), "%.2f", 0.05)
	_slider(rows_box, "Dead zone", 0.0, 0.6, float(s["dead"]), func(x): _stick("dead", x), "%.2f", 0.01)
	_slider(rows_box, "Trigger threshold", 0.05, 0.95, float(s["trigger"]), func(x): _stick("trigger", x), "%.2f", 0.05)
	_switch(rows_box, "Look up / down inverted", bool(s["invert_y"]), func(x: bool): _stick("invert_y", x))
	_switch(rows_box, "Swap the sticks (right stick moves, left stick looks)", bool(s["swap"]), func(x: bool): _stick("swap", x))


func _stick(key: String, x) -> void:
	model.sticks[key] = x
	model.save_pad()
