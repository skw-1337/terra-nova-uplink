# Uplink's own menu in a live window, drawn over the view (the game goes on: it runs on the host's PC, or behind).
# A co-op guest opens it with Esc (his window had none: to quit he had to switch to the launcher); the host with
# Uplink's menu key (F5 unless changed: Esc is the game's own menu). Resume; Controls (every key: controls.gd, the
# same list as the launcher's Controls page); Options (the guest's sound, the mouse, the old school look, Uplink's
# extras); for the guest, Leave the game (his teammate back to the game's AI on the host, his window closed: his
# launcher is then as after STOP). Closing the guest's window leaves the same way.
# Also, once a session, when the player first takes the mouse in a mission: a line with the few keys to know (Esc,
# the free look, the orders), fading out.
# Options are kept: the sound in viewer.cfg [sound], the others in viewer.cfg [launcher] for the launcher to take
# over (as the Controls page's keys: see controls.gd).
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
const GROUPS := ["Move", "Fight", "View", "Squad", "Map", "Drone", "System", "Tools", "Uplink"]
const FX := [["cloud_shadows", "Cloud shadows", true], ["cliffs", "Unstretched cliffs", true], ["stars", "Sharp stars", true],
		["marks", "Impact marks", false], ["lights", "Light from shots", false], ["look_down", "Look further down", false]]

var v: Node                        # the viewer
var guest := false
var layer: CanvasLayer
var root: Control
var box: PanelContainer
var page := ""
var was_captured := false
var menu_key := [KEY_F5, 0]        # the host's (TN_KEY_MENU, as Uplink's other keys); a guest's is Esc
var model: Controls
var capture := {}                  # a key being asked for: {id, column ("key" / "mouse"), button}
var search: LineEdit
var rows_box: VBoxContainer
var note_label: Label
var leaving := false
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
	if event is InputEventKey and event.pressed and not event.echo:
		var opens: bool = event.physical_keycode == KEY_ESCAPE if guest else _is_key(event, menu_key)
		if opens and not is_open():
			if guest and _typing():
				return false
			open()
			get_viewport().set_input_as_handled()
			return true
		if is_open() and (event.physical_keycode == KEY_ESCAPE or (not guest and _is_key(event, menu_key))):
			if page == "main":
				close()
			else:
				_show("main")
			get_viewport().set_input_as_handled()
			return true
	return is_open()


func _typing() -> bool:
	for n in v.get_children():                          # coop_net.gd's search or chat has the keys
		if n.has_method("wants_keys") and n.wants_keys():
			return true
	return false


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


func _place(w: float, h: float) -> void:
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var sz := Vector2(minf(w * k, vs.x - 40), minf(h * k, vs.y - 40))
	box.custom_minimum_size = sz
	box.size = sz
	box.position = ((vs - sz) * 0.5).round()


func _show(p: String) -> void:
	page = p
	capture = {}
	for c in box.get_children():
		c.queue_free()
	var col := VBoxContainer.new()
	box.add_child(col)
	match p:
		"main":
			_place(400, 360 if guest else 300)
			_title(col, "UPLINK", ORANGE if not guest else BLUE)
			var sub := Label.new()
			sub.text = "The game goes on meanwhile." if guest else "The game is not paused by this menu."
			sub.add_theme_color_override("font_color", DIM)
			sub.add_theme_font_size_override("font_size", _px(16))
			col.add_child(sub)
			var first := _button(col, "Resume", close)
			_button(col, "Controls", func(): _show("controls"))
			_button(col, "Options", func(): _show("options"))
			if guest:
				_button(col, "Leave the game", func(): _show("leave"), RED)
			first.grab_focus()
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
		"controls":
			_controls(col)


# ---------------------------------------------------------------- options
func _options(col: VBoxContainer) -> void:
	_place(560, 560 if guest else 600)
	_title(col, "OPTIONS", ORANGE)
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	if guest:
		var db := AudioServer.get_bus_volume_db(0)
		_slider(col, "Game sound", 0.0, 100.0, roundf(db_to_linear(db) * 100.0), func(x: float):
			AudioServer.set_bus_volume_db(0, linear_to_db(maxf(x, 0.1) / 100.0) if x > 0.5 else -80.0)
			_keep("sound", "guest_volume_db", AudioServer.get_bus_volume_db(0)), "%d %%")
	_slider(col, "Mouse speed", 0.2, 3.0, float(v.mouse_sens), func(x: float):
		v.mouse_sens = x
		_keep("launcher", "mouse", "%.1f" % x), "x %.1f", 0.1)
	var old_on := bool(v.oldschool_rect != null and v.oldschool_rect.visible)
	_switch(col, "Old school look", old_on, func(on: bool):
		if v.oldschool_rect != null and v.oldschool_rect.visible != on:
			v._oldschool_toggle()
		_keep("launcher", "old_school", "1" if on else "0"))
	var head := Label.new()
	head.text = "EXTRAS  (Uplink's own: from the next mission)"
	head.add_theme_color_override("font_color", ORANGE)
	head.add_theme_font_size_override("font_size", _px(15))
	col.add_child(head)
	for fx in FX:
		if guest and not fx[2]:
			continue                                     # (the host's only: his shots, his own legs)
		var env := "TN_FX_" + str(fx[0]).to_upper()
		var on := str(cfg.get_value("launcher", "fx_" + str(fx[0]), "0" if OS.get_environment(env) == "0" else "1")) != "0"
		var id: String = fx[0]
		_switch(col, fx[1], on, func(x: bool):
			if id == "cloud_shadows":
				v.fx_cloud_shadows = x
			elif id == "stars":
				v.fx_stars = x
			_keep("launcher", "fx_" + id, "1" if x else "0"))
	_button(col, "Back", func(): _show("main"))


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
	_place(980, 900)
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
	for h in [["", 470], ["KEY", 190], ["MOUSE", 170]]:
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
			if c["group"] != g or (guest and c["kind"] == "tnplus" and c["id"] != "freelook") or (guest and c["id"] in ["menu", "order", "photo"]):
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
			_row(c, clash.get(c["id"], ""))


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
	if c["kind"] == "game" or c["kind"] == "tnplus":
		var mb := Button.new()
		mb.text = Controls.MOUSE_SHORT[int(c["mouse"])] if int(c["mouse"]) > 0 else "+"
		mb.custom_minimum_size = Vector2(160 * k, 32 * k)
		mb.pressed.connect(func(): _ask(c, "mouse", mb))
		row.add_child(mb)


func _ask(c: Dictionary, column: String, b: Button) -> void:
	capture = {"id": c["id"], "column": column, "button": b}
	b.text = "Press..." if column == "key" else "Click / wheel..."
	note_label.text = ("Press the new key, alone or with Shift, Ctrl or Alt." if column == "key" else
			"The middle or a side mouse button, the wheel, or PgUp / PgDn, Home / End, Ins / Del.") + "  Esc: as it was.  Backspace: none."


func _capture_input(event: InputEvent) -> bool:
	var id: String = capture["id"]
	var column: String = capture["column"]
	var c: Dictionary = model.find(id)
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
		for n in v.get_children():
			if n.get("steam") and n.get("lobby_id"):
				if n.peer:
					n.steam.closeP2PSessionWithUser(n.peer)
				n.steam.leaveLobby(n.lobby_id)
				n.lobby_id = 0
		get_tree().quit())


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
	parts.append(("Esc" if guest else model.name_of(model.find("menu")["key"])) + ": menu")
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
