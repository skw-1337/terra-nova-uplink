# The mission editor's properties panel: the unit record's fields the game's loader reads (0x2C9898 and the
# routines it calls for each class), edited in place. The editor (mission_editor.gd) fills it and listens.
#   +7  group (its side comes from the group: resource 174)       +26 label: what the mission's script knows the
#   +8 / +12 / +16 x, y, height above the ground (16.16)              unit by (objectives count labels)
#   +20 heading, +22 pitch (1/65536 turn)
#   soldier (0x27D818): +27 pilot's health, +28 armour (its 4 parts), +32 jump jet fuel, +33 jump jet rating, in %
#     of the suit's own values (over 100: a tougher one); +34..+37 the 4 weapon slots
#   vehicle (0x27DD64): +27 armour %
# Only what was checked in the running game is edited here (a mission made by the editor, read back in the game's
# memory: entity +0x23 = the label, AI record +6 = the group, the suit's health +0x34 / +0x32, armour +0x15 + 7k,
# jets +0xA6 / +0xAA, weapon slots +0x45 + 15k, the vehicle's armour +6). The rest is shown as the file has it:
# a soldier's +29 / +30 (energy: it recharges at once, not told apart in game), +31, +38, +39 (ASF); a vehicle's
# +28 / +29 and its weapons (+30, +31); a probe's, craft's or building's +27..+29 (the same routines read them:
# armour, energy) and weapons (+30, +31).
# A weapon slot only offers what the game's own soldiers carry in that slot (its missions' records): the game's
# player weapons (1 to 17) have names, the others are told by who carries them.
extends PanelContainer

signal changed(rec: PackedByteArray, tag: String)     # the record with one field changed (tag: which one)
signal closed
signal remove_pressed

const Menu = preload("res://scripts/editor_menu.gd")
const REC := 50
const PCT := {1: [[27, "Pilot's health"], [28, "Armour"], [32, "Jump jet fuel"], [33, "Jump jet rating"]], 2: [[27, "Armour"]]}
const WEAPON_AT := {1: [34, 35, 36, 37], 2: [30, 31], 3: [30], 4: [30, 31]}   # where each class keeps its weapons
const WEAPON_EDIT := {1: [34, 35, 36, 37]}                                      # the slots edited here

var rec := PackedByteArray()
var busy := false
var title: Label
var sub: Label
var body: VBoxContainer
var raw: Label
var note: Label
var group_opt: OptionButton
var weapon_names := {}           # id -> text
var slot_ids := {}               # record offset -> the weapon ids offered there
var fields := {}                 # tag -> its control


func _ready() -> void:
	anchor_left = 1.0
	anchor_right = 1.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_left = -372
	offset_right = -12
	offset_top = 60
	offset_bottom = -80
	add_theme_stylebox_override("panel", Menu._box(Menu.BG, Menu.ACCENT, 2, 10, 10))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	title = Label.new()
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top.add_child(title)
	var x := Button.new()
	x.text = "✕"
	x.focus_mode = Control.FOCUS_NONE
	x.pressed.connect(func(): closed.emit())
	top.add_child(x)
	sub = Label.new()
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", Color(0.65, 0.7, 0.75))
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 4)
	sc.add_child(body)
	note = Label.new()
	note.add_theme_font_size_override("font_size", 13)
	note.add_theme_color_override("font_color", Color(1.0, 0.78, 0.3))
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(note)
	raw = Label.new()
	raw.add_theme_font_size_override("font_size", 12)
	raw.add_theme_color_override("font_color", Color(0.55, 0.6, 0.65))
	raw.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(raw)
	var rm := Button.new()
	rm.text = "Remove this unit"
	rm.focus_mode = Control.FOCUS_NONE
	rm.pressed.connect(func(): remove_pressed.emit())
	v.add_child(rm)


# info: {"name", "kind": "mission's own" / "added", "groups": [[g, text]], "weapons": {id: text},
# "slots": {record offset: [weapon ids offered]}, "note": String}
func show_unit(r: PackedByteArray, info: Dictionary) -> void:
	busy = true
	rec = PackedByteArray(r).duplicate()
	weapon_names = info.get("weapons", {})
	slot_ids = info.get("slots", {})
	title.text = str(info.get("name", ""))
	sub.text = "%s  ·  class %d, type %d  ·  entity %d" % [info.get("kind", ""), rec[0], rec[1], rec.decode_u16(2)]
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	fields.clear()
	_section("SCRIPT")
	group_opt = OptionButton.new()
	group_opt.focus_mode = Control.FOCUS_NONE
	group_opt.fit_to_longest_item = false
	group_opt.clip_text = true
	group_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for g in info.get("groups", []):
		group_opt.add_item(str(g[1]))
		group_opt.set_item_metadata(group_opt.item_count - 1, int(g[0]))
	group_opt.item_selected.connect(func(i): _set_byte(7, int(group_opt.get_item_metadata(i)), "group"))
	_row("Group", group_opt)
	fields["group"] = group_opt
	_spin("label", "Label", 0, 255, 1, func(val): _set_byte(26, int(val), "label"),
		"What the mission's script knows this unit by: its objectives count the units of a label")
	_section("PLACE")
	_spin("x", "X", 2, 510, 0.01, func(val): _set_s32(8, val, "x"))
	_spin("y", "Y", 2, 510, 0.01, func(val): _set_s32(12, val, "y"))
	_spin("z", "Height", -64, 256, 0.01, func(val): _set_s32(16, val, "z"), "Above the ground")
	_spin("h", "Heading °", 0, 359.99, 0.01, func(val): _set_u16(20, val, "h"))
	if rec[0] != 1 and rec[0] != 2:
		_spin("p", "Pitch °", -180, 180, 0.01, func(val): _set_u16(22, val, "p"), "Nose up or down (models only)")
	var pcts: Array = PCT.get(rec[0], [])
	if not pcts.is_empty():
		_section("STATE  (% of this type's own values)")
		for p in pcts:
			_slider("b%d" % p[0], str(p[1]), int(p[0]))
	var slots: Array = WEAPON_EDIT.get(rec[0], [])
	if not slots.is_empty():
		_section("WEAPONS  (by number; the others: who carries them)")
		for k in slots.size():
			_weapon("w%d" % slots[k], "Slot %d" % (k + 1), int(slots[k]))
	refresh(rec, str(info.get("note", "")))
	busy = false


# the same unit, its record changed elsewhere (dragged, turned, undone)
func refresh(r: PackedByteArray, script_note: String = "") -> void:
	busy = true
	rec = PackedByteArray(r).duplicate()
	if group_opt:
		for i in group_opt.item_count:
			if int(group_opt.get_item_metadata(i)) == rec[7]:
				group_opt.select(i)
	_show("label", rec[26])
	_show("x", rec.decode_s32(8) / 65536.0)
	_show("y", rec.decode_s32(12) / 65536.0)
	_show("z", rec.decode_s32(16) / 65536.0)
	_show("h", rec.decode_u16(20) / 65536.0 * 360.0)
	_show("p", rec.decode_s16(22) / 65536.0 * 360.0)
	for tag in fields:
		var t: String = tag
		if t.begins_with("b"):
			var s: HSlider = fields[t]
			s.value = rec[int(t.substr(1))]
			s.get_meta("num").text = "%d %%" % rec[int(t.substr(1))]
		elif t.begins_with("w"):
			var o: OptionButton = fields[t]
			var id: int = rec[int(t.substr(1))]
			var found := false
			for i in o.item_count:
				if int(o.get_item_metadata(i)) == id:
					o.select(i)
					found = true
			if not found:
				o.add_item(_weapon_text(id))
				o.set_item_metadata(o.item_count - 1, id)
				o.select(o.item_count - 1)
	note.text = script_note
	note.visible = script_note != ""
	raw.text = _raw_text()
	busy = false


# the bytes this panel does not edit, as the file has them
func _raw_text() -> String:
	var known := {7: 1, 26: 1}
	for o in range(8, 24):
		known[o] = 1
	for p in PCT.get(rec[0], []):
		known[int(p[0])] = 1
	for o in WEAPON_EDIT.get(rec[0], []):
		known[int(o)] = 1
	var parts := []
	for o in range(6, REC):
		if not known.has(o) and rec[o] != 0:
			parts.append("+%d: %02X" % [o, rec[o]])
	return "Not edited here, kept as in the file:  " + ("  ".join(parts) if not parts.is_empty() else "nothing (all 0)")


func _weapon_text(id: int) -> String:
	if id == 0:
		return "0  ·  none"
	return str(weapon_names.get(id, "%d  ·  weapon %d" % [id, id]))


# ---- the rows
func _section(t: String) -> void:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Menu.ACCENT.lightened(0.2))
	body.add_child(l)


func _row(t: String, c: Control, tip: String = "") -> void:
	var h := HBoxContainer.new()
	var l := Label.new()
	l.text = t
	l.custom_minimum_size = Vector2(118, 0)
	l.add_theme_font_size_override("font_size", 14)
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_STOP if tip != "" else Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(c)
	body.add_child(h)


func _spin(tag: String, t: String, lo: float, hi: float, step: float, on: Callable, tip: String = "") -> void:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.allow_greater = false
	s.select_all_on_focus = true
	s.value_changed.connect(func(val): if not busy: on.call(val))
	s.get_line_edit().text_submitted.connect(func(_t): s.get_line_edit().release_focus())
	_row(t, s, tip)
	fields[tag] = s


func _slider(tag: String, t: String, off: int) -> void:
	var h := HBoxContainer.new()
	var s := HSlider.new()
	s.min_value = 0
	s.max_value = 200
	s.step = 1
	s.allow_greater = true                           # (a value over 200 in a file stays what it is)
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.custom_minimum_size = Vector2(120, 0)
	var num := Label.new()
	num.custom_minimum_size = Vector2(52, 0)
	num.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.set_meta("num", num)
	s.value_changed.connect(func(val): if not busy: _set_byte(off, int(val), tag))
	h.add_child(s)
	h.add_child(num)
	_row(t, h)
	fields[tag] = s


func _weapon(tag: String, t: String, off: int) -> void:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.fit_to_longest_item = false
	o.clip_text = true
	for id in [0] + slot_ids.get(off, []):           # (what the game's own units carry in this slot; none: 0)
		o.add_item(_weapon_text(int(id)))
		o.set_item_metadata(o.item_count - 1, int(id))
	o.item_selected.connect(func(i): if not busy: _set_byte(off, int(o.get_item_metadata(i)), tag))
	_row(t, o)
	fields[tag] = o


func _show(tag: String, v: float) -> void:
	if fields.has(tag):
		fields[tag].value = v                        # (busy: its signal changes nothing)


# ---- a field changed here
func _emit(tag: String) -> void:
	if busy:
		return
	changed.emit(PackedByteArray(rec).duplicate(), tag)


func _set_byte(off: int, v: int, tag: String) -> void:
	if busy or rec[off] == (v & 0xFF):
		return
	rec[off] = v & 0xFF
	_emit(tag)


func _set_s32(off: int, v: float, tag: String) -> void:
	var raw_v := int(round(v * 65536.0))
	if busy or rec.decode_s32(off) == raw_v:
		return
	rec.encode_s32(off, raw_v)
	_emit(tag)


func _set_u16(off: int, deg: float, tag: String) -> void:
	var raw_v := int(round(deg / 360.0 * 65536.0)) & 0xFFFF
	if busy or rec.decode_u16(off) == raw_v:
		return
	rec.encode_u16(off, raw_v)
	_emit(tag)


func typing() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit and is_ancestor_of(f)
