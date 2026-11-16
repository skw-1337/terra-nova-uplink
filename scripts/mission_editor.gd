# Mission editor, in the map viewer: a build mode in the spirit of Garry's Mod. The EDIT MISSION button (or F6)
# enters it: the mouse looks around with no button held, the camera keys fly, a crosshair aims. Keys are by
# position, as the camera's (the hints show the player's own labels: on AZERTY the spawn menu is A, undo W).
#   Q held (tapped: stays open)  spawn menu: the game's unit types as pictures, by kind, a search field, the tools,
#                 the group new units go to, the mission file; a picture clicked spawns that type where the
#                 crosshair meets the ground, facing you
#   1 physgun     left button held on a unit or a zone post grabs it: it follows the aim on the ground, the wheel
#                 pushes it away or pulls it in, E held + the mouse turns it (Shift: 15 degree steps)
#   2 remover     left click removes the unit aimed at, the mission's own too (the game's loader never reads the
#                 units' numbers: a record can go; what the mission's script does with its label or its group is
#                 said when it matters)
#   3 duplicator  right click copies the unit aimed at, left click places the copy at the crosshair
#   4 team        left click puts the unit aimed at in the chosen group (the group gives its side), right click
#                 takes the group of the unit aimed at
#   C held        the cursor: drag units with the left button, right click a unit for its menu
#   P             the properties of the unit aimed at (editor_props.gd): group, label, place, state, weapons
#   Z undo (spawn, move, turn, group, removal, a property, an import), R / Shift+R turn 15 degrees, Delete
#   removes, F2 every unit's name, Ctrl+S saves, Esc closes a menu, then leaves the build mode
# Sharing (the spawn menu, SHARE): a creation is only the changes against the original mission, as a small file
# or as a code to copy and paste (mission_mod.gd); importing one puts it on the original mission in the editor
# and writes nothing: the player saves.
# Held keys and buttons are read from their real state each frame: a release lost to another window or to a
# popup ends what it started all the same.
# The file: resource 173, one 50-byte record per unit: class, type, entity number (u16 +2), number in its class
# (u16 +4), group (+7; the group's side in 174: 1 Strike Force, 2 enemy), x, y, height (16.16 at +8 / +12 /
# +16), heading (u16 +20, 1/65536 turn, forward = (cos, sin) on the map), label (+26: what the mission's script
# knows the unit by), state in % (+27..: see editor_props.gd), weapons. The game numbers its entities itself, in
# the order of the records: the numbers at +2 / +4 are only kept tidy. A new unit is a copy of a record of the
# same type from one of the game's missions (its weapons), whole, with the next numbers, after the mission's own.
# Zones: 176, x, y (16.16) by zone number, names in 177.
# Saved in the file itself (written beside it first and checked), the original kept once as
# <file>.uplink-original (Revert puts it back), and the changes as a creation in <file>.uplink-edit: that is how a
# later session knows the mission's own units from the added ones, and what was removed. Unsaved changes are
# asked about before another mission loads or the window closes.
extends CanvasLayer

const LGRes = preload("res://scripts/lgres.gd")
const TNData = preload("res://scripts/tn_data.gd")
const Menu = preload("res://scripts/editor_menu.gd")
const Thumbs = preload("res://scripts/editor_thumbs.gd")
const Mod = preload("res://scripts/mission_mod.gd")
const Props = preload("res://scripts/editor_props.gd")
const CoopHud = preload("res://scripts/coop_hud.gd")           # (the game's weapon names)
const REC := 50
const BACKUP := ".uplink-original"
const EDIT := ".uplink-edit"
# the game's tables (its loader and the routines it calls): 300 entities, shots and wrecks included; 60 AI records
# for the soldiers, vehicles, probes and craft and armed buildings, the player's squad (4) and the units the
# script brings in later (resource 181) included; a group number over 31 overruns its group table
const MAX_ENTITIES := 300
const MAX_AI := 60
const SQUAD := 4
const MAX_GROUP := 31
const KINDS := {1: "Soldier", 2: "Vehicle", 3: "Probe / craft", 4: "Building", 0: "Decor"}
const KIND_ORDER := [1, 2, 3, 4, 0]
const SIDES := {1: "Strike Force", 2: "enemy"}
const PICK_PX := 36.0
const PHYSGUN := 0
const REMOVER := 1
const DUPLICATOR := 2
const TEAM := 3
const TOOL_NAMES := ["Physgun", "Remover", "Duplicator", "Team"]
const TOOL_KEYS := [KEY_1, KEY_2, KEY_3, KEY_4]
const BEAM := Color(0.35, 0.75, 1.0)
const HOT := Color(1.0, 0.78, 0.3)
const BAD := Color(1.0, 0.45, 0.4)
const GOOD := Color(0.6, 0.9, 0.6)
const HOLD_MIN := 2.0
const HOLD_MAX := 600.0
const TAP_MS := 300
const UNDO_MAX := 200
const NOTE_MS := 3500
const ARMOUR := 27                   # first state byte (%)
const PROP_NAMES := {"group": "the group", "label": "the label", "x": "the place", "y": "the place", "z": "the height",
	"h": "the heading", "p": "the pitch"}

var viewer: Node
var seen = null                      # the viewer's current mission (a new load resets the editor)
# the mission
var lg = null
var path := ""
var recs := []                       # unit records (PackedByteArray), the file's order, then the added ones
var uids := []                       # a stable id per record (undo, held unit)
var nodes := []                      # their nodes in the viewer's world
var origin := []                     # per record: its place among the ORIGINAL mission's units, -1: added in the editor
var src := []                        # per added record: {"f": mission file, "i": record} it is a copy of ({}: not known)
var orig_recs := []                  # the original mission's units and zones (<file>.uplink-original once saved)
var orig_zones := PackedByteArray()
var adopted := false                 # <file>.uplink-original is there and is this file's original
var src_cache := {}                  # mission file (upper case) -> its original units
var mission_files := {}              # mission file (upper case) -> its path
var refs := {}                       # what this mission's script does with labels and groups (data/mission_refs.json)
var all_refs = null
var weapon_names := {}               # weapon id -> text (the properties panel)
var next_uid := 1
var zones := PackedByteArray()       # resource 176
var groups := PackedStringArray()
var sides := PackedByteArray()
var catalog := []                    # [{cls, sub, name, kind, rec}]: one record of each type found in the missions
var class_max := {}                  # class -> most units of that class in one of the game's missions
var dirty := false
var undo := []
var pending := Callable()            # what waits for the unsaved changes' answer (another mission, quitting)
# the build mode
var active := false
var tool := PHYSGUN
var aim := {}                        # what the crosshair (or the cursor) is on: {"kind": "unit", "uid"} / {"kind": "zone", "i"}
var held := {}                       # the physgun's: target + dist, off, from_raw, from_h, crosshair, wheel
var rotating := false
var rot_acc := 0.0
var menu_open := false
var menu_sticky := false
var menu_t := 0
var menu_used := false               # something spawned while it was open: letting go of the key closes it
var cursor := false                  # C held
var refocus := false                 # the window came back: the click that brought it only takes the mouse again
var focused := true                  # (the mouse is never taken while another window has the focus)
var focus_in_t := 0
var names_all := false               # F2 in the build mode
var ctrl_down := false               # Ctrl: the viewer's "down", and the editor's Ctrl+S / Ctrl+Z
var ctrl_chord := false              # a Ctrl shortcut fired: no flying until Ctrl is up (the viewer reads it)
var free_cam := Vector3.ZERO         # the camera before Ctrl went down: put back by a shortcut
var team_group := 0
var new_group := -1                  # -1: like the units of that type in this mission
var dup := PackedByteArray()
var dup_src := {}
var was_panel := true
var was_status := true
# what is drawn
var ring: MeshInstance3D
var ring_mat: StandardMaterial3D
var hover: Label3D
var beam_pivot: Node3D
var beam: MeshInstance3D
var hud: Control
var crosshair: Crosshair
var toolbar: HBoxContainer
var tool_labels := []
var hint: Label
var notes: VBoxContainer
var open_btn: Button
var menu
var thumbs
var unit_menu: PopupMenu
var confirm: ConfirmationDialog
var unsaved: ConfirmationDialog
var menu_target := {}
var props
var props_uid := -1
var file_dlg: FileDialog
var dlg_import := false


class Crosshair extends Control:
	var hot := false

	func _draw() -> void:
		var c := size * 0.5
		var col := Color(1.0, 0.78, 0.3) if hot else Color(1.0, 1.0, 1.0, 0.9)
		draw_circle(c, 2.5, col)
		draw_arc(c, 10.0 if hot else 8.0, 0.0, TAU, 32, Color(col, 0.7), 1.5)


func _ready() -> void:
	layer = 5
	viewer = get_parent()
	get_tree().auto_accept_quit = false              # (the window's close button asks about unsaved changes)
	hud = Control.new()
	hud.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.visible = false
	add_child(hud)
	crosshair = Crosshair.new()
	crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(crosshair)
	# top left: the tools, the current one lit (clickable while the cursor is free)
	toolbar = HBoxContainer.new()
	toolbar.position = Vector2(12, 12)
	toolbar.add_theme_constant_override("separation", 4)
	hud.add_child(toolbar)
	toolbar.add_child(_chip("BUILD MODE", Color(0.3, 0.62, 0.95), 15))
	for i in TOOL_NAMES.size():
		var b := Button.new()
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 15)
		b.pressed.connect(_set_tool.bind(i))
		toolbar.add_child(b)
		tool_labels.append(b)
	# bottom: what the buttons do now
	var hb := PanelContainer.new()
	hb.anchor_left = 0.5
	hb.anchor_right = 0.5
	hb.anchor_top = 1.0
	hb.anchor_bottom = 1.0
	hb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	hb.grow_vertical = Control.GROW_DIRECTION_BEGIN
	hb.offset_bottom = -14
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_theme_stylebox_override("panel", Menu._box(Color(0.05, 0.06, 0.08, 0.78), Color(0, 0, 0, 0), 0, 8, 8))
	hud.add_child(hb)
	hint = Label.new()
	hint.add_theme_font_size_override("font_size", 16)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hb.add_child(hint)
	# bottom right: what just happened (Garry's Mod's undo notices)
	notes = VBoxContainer.new()
	notes.anchor_left = 1.0
	notes.anchor_right = 1.0
	notes.anchor_top = 1.0
	notes.anchor_bottom = 1.0
	notes.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	notes.grow_vertical = Control.GROW_DIRECTION_BEGIN
	notes.offset_right = -14
	notes.offset_bottom = -70
	notes.alignment = BoxContainer.ALIGNMENT_END
	notes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(notes)
	# the way in, while the build mode is off
	open_btn = Button.new()
	open_btn.text = "✎  EDIT MISSION  (F6)"
	open_btn.focus_mode = Control.FOCUS_NONE
	open_btn.anchor_left = 1.0
	open_btn.anchor_right = 1.0
	open_btn.offset_left = -240
	open_btn.offset_right = -12
	open_btn.offset_top = 12
	open_btn.offset_bottom = 50
	open_btn.add_theme_font_size_override("font_size", 17)
	open_btn.add_theme_stylebox_override("normal", Menu._box(Color(0.12, 0.3, 0.55, 0.92), Color(0.4, 0.7, 1.0), 2, 8, 6))
	open_btn.add_theme_stylebox_override("hover", Menu._box(Color(0.16, 0.38, 0.68, 0.95), Color(0.6, 0.85, 1.0), 2, 8, 6))
	open_btn.pressed.connect(toggle)
	open_btn.visible = false
	add_child(open_btn)
	# the spawn menu, the unit menu, the questions
	menu = Menu.new()
	menu.visible = false
	add_child(menu)
	menu.spawn.connect(_on_menu_spawn)
	menu.tool_picked.connect(_set_tool)
	menu.group_picked.connect(func(g): new_group = g)
	menu.save_pressed.connect(save)
	menu.revert_pressed.connect(_ask_revert)
	menu.leave_pressed.connect(leave)
	menu.export_file_pressed.connect(_on_export_file)
	menu.copy_code_pressed.connect(_on_copy_code)
	menu.import_file_pressed.connect(_on_import_file)
	menu.paste_code_pressed.connect(_on_paste_code)
	menu.search.text_submitted.connect(func(_t): menu_sticky = true)   # (Enter after a search: the menu stays open)
	unit_menu = PopupMenu.new()
	unit_menu.id_pressed.connect(_on_unit_menu)
	add_child(unit_menu)
	confirm = ConfirmationDialog.new()
	confirm.title = "Revert"
	confirm.dialog_text = "Put the original mission back? Every change saved by the editor is lost."
	confirm.confirmed.connect(_revert)
	add_child(confirm)
	unsaved = ConfirmationDialog.new()
	unsaved.title = "Unsaved changes"
	unsaved.ok_button_text = "Save"
	unsaved.add_button("Don't save", true, "discard")
	unsaved.confirmed.connect(_unsaved_save)
	unsaved.custom_action.connect(_unsaved_discard)
	unsaved.canceled.connect(_unsaved_cancel)
	add_child(unsaved)
	props = Props.new()
	props.visible = false
	add_child(props)
	props.changed.connect(func(r, tag): _edit_rec(props_uid, r, tag))
	props.closed.connect(_close_props)
	props.remove_pressed.connect(func(): _remove(props_uid))
	file_dlg = FileDialog.new()
	file_dlg.access = FileDialog.ACCESS_FILESYSTEM
	file_dlg.use_native_dialog = false
	file_dlg.filters = PackedStringArray(["*.%s ; Terra Nova Uplink creation" % Mod.EXT])
	file_dlg.size = Vector2i(900, 560)
	file_dlg.file_selected.connect(_on_file_picked)
	file_dlg.canceled.connect(func(): _recapture.call_deferred())
	add_child(file_dlg)
	thumbs = Thumbs.new()
	thumbs.viewer = viewer
	thumbs.made.connect(func(k, tex): menu.set_thumb(k, tex))
	add_child(thumbs)


func _chip(t: String, col: Color, size: int) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", Menu._box(col.darkened(0.45), col, 1, 6, 6))
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	p.add_child(l)
	return p


# the key at that position on the player's keyboard (Q is A on AZERTY)
static func _k(phys: Key) -> String:
	if DisplayServer.get_name() == "headless":       # (no keyboard to ask: the tests)
		return OS.get_keycode_string(phys)
	var s := OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(phys))
	return s if s != "" else OS.get_keycode_string(phys)


func _fly_keys() -> String:
	return _k(KEY_W) + _k(KEY_A) + _k(KEY_S) + _k(KEY_D)


# ---- in and out
func toggle() -> void:
	if active:
		leave()
	else:
		enter()


func _can_edit() -> bool:
	return not viewer.live and not viewer.current.is_empty() and not viewer.current["entry"].get("gallery", false)


func enter() -> void:
	if not _can_edit() or lg == null:
		return
	active = true
	if catalog.is_empty():
		_build_catalog()
		var items := []
		for c in catalog:
			items.append({"cls": c["cls"], "sub": c["sub"], "name": c["name"], "kind": c["kind"]})
		menu.set_catalog(items)
	menu.set_tools(_tool_list(), tool)
	menu.set_help(_help())
	_fill_groups()
	was_panel = viewer.panel.visible
	was_status = viewer.status.visible
	viewer.panel.visible = false
	viewer.status.visible = false
	hud.visible = true
	refocus = false
	names_all = false
	_capture(true)
	_paint_tools()
	_names(true)
	notify("Build mode.  %s: spawn menu   ·   Esc: leave" % _k(KEY_Q), Color(0.6, 0.85, 1.0))


func leave() -> void:
	if not active:
		return
	_drop()
	active = false                                   # (first: closing the menu must not take the mouse again)
	_close_menu()
	cursor = false
	rotating = false
	_close_props()
	hud.visible = false
	_capture(false)
	viewer.panel.visible = was_panel
	viewer.status.visible = was_status
	_show_aim({})
	_names(false)
	if dirty:
		notify("Unsaved changes: Save in the spawn menu, or Ctrl+S in the build mode", HOT)


# the mouse looks around (no button held), or is free for the menus
func _capture(on: bool) -> void:
	viewer.look = on
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if on else Input.MOUSE_MODE_VISIBLE


func _free_mouse() -> bool:
	return menu_open or cursor or props.visible or unit_menu.visible or confirm.visible or unsaved.visible or file_dlg.visible


func _recapture() -> void:
	if active and focused and not _free_mouse():
		_capture(true)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		focused = false
		if active:
			_drop()                                  # (no release will come from another window)
			rotating = false
			refocus = true
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		focused = true
		focus_in_t = Time.get_ticks_msec()
		if active:
			_recapture()
	elif what == NOTIFICATION_WM_CLOSE_REQUEST:
		if dirty and lg != null:
			pending = func(): get_tree().quit()
			_ask_unsaved()
		else:
			get_tree().quit()


# ---- unsaved changes: another mission or quitting waits for the answer
# (viewer._load asks this first; false = it asks the player and loads it afterwards)
func allow_load(index: int) -> bool:
	if not dirty or lg == null:
		return true
	pending = func(): viewer._load(index)
	_ask_unsaved()
	return false


func _ask_unsaved() -> void:
	unsaved.dialog_text = "%s has unsaved changes." % path.get_file()
	if active:
		_capture(false)
	unsaved.popup_centered()


func _unsaved_save() -> void:
	save()
	if not dirty:
		_go_on()
	else:
		_unsaved_cancel()                            # (not saved: stay on this mission, the list back on it)


func _unsaved_discard(action: StringName) -> void:
	if action != &"discard":
		return
	unsaved.hide()
	dirty = false
	_go_on()


func _unsaved_cancel() -> void:
	pending = Callable()
	for i in viewer.missions.size():                 # the list back on the mission being edited
		if not viewer.current.is_empty() and viewer.missions[i]["file"] == viewer.current["entry"]["file"]:
			viewer.list.select(i)
	_recapture.call_deferred()                       # (the dialog hides itself a moment later)


func _go_on() -> void:
	var p := pending
	pending = Callable()
	if active:
		leave()
	if p.is_valid():
		p.call()


# ---- names over the units
# World-sized, they are huge up close and pile up over a group, hiding what is built: in the build mode only the
# unit aimed at is named (above the crosshair), F2 shows them all again, small and the same size at any
# distance, the far ones fading out; the zone posts' names too.
func _names(build: bool) -> void:
	for l in get_tree().get_nodes_in_group("labels"):
		if l is Label3D:
			_label_look(l, build, 0.0009, 24, 120.0)
			l.visible = names_all if build else viewer.labels_on
	for zn in viewer.zone_nodes.values():
		if zn == null or not is_instance_valid(zn):
			continue
		for c in zn.get_children():
			if c is Label3D:
				_label_look(c, build, 0.0011, 26, 115.0)
				if not build:
					c.visible = true                 # (in the build mode only the near ones were shown)


func _label_look(l: Label3D, build: bool, px: float, font: int, far: float) -> void:
	if not l.has_meta("look"):
		l.set_meta("look", [l.fixed_size, l.pixel_size, l.font_size, l.outline_size, l.visibility_range_end,
			l.visibility_range_end_margin, l.visibility_range_fade_mode])
	var o: Array = l.get_meta("look")
	l.fixed_size = true if build else o[0]
	l.pixel_size = px if build else o[1]
	l.font_size = font if build else o[2]
	l.outline_size = 6 if build else o[3]
	l.visibility_range_end = far if build else o[4]
	l.visibility_range_end_margin = 8.0 if build else o[5]
	l.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF if build else o[6]


func _new_names(n: Node) -> void:
	if active and n != null:
		for c in n.get_children():
			if c is Label3D and c.is_in_group("labels"):
				_label_look(c, true, 0.0009, 24, 120.0)
				c.visible = names_all


# ---- the mission
func _process(_dt: float) -> void:
	if not is_same(seen, viewer.current):
		seen = viewer.current
		_load_mission()
	open_btn.visible = not active and _can_edit() and lg != null
	_fade_notes()
	if not active:
		return
	_poll()
	if focused and not _free_mouse() and not viewer.look:
		_capture(true)                               # (a dialog closed without saying so: the view is the mouse's again)
	if not held.is_empty():
		if not unit_menu.visible:                    # (a unit dragged when the menu opened stays where it was)
			_hold_update()
	elif not menu_open and not unit_menu.visible:
		aim = _pick_at(_aim_point())
	_show_aim(held if not held.is_empty() else aim)
	_props_sync()
	_zone_names()
	_beam_update()
	crosshair.visible = not _free_mouse()
	var hot := not aim.is_empty() or not held.is_empty()
	if crosshair.hot != hot:
		crosshair.hot = hot
		crosshair.queue_redraw()
	hint.text = _hint()


# the held keys and buttons as they really are (their release may never have come: another window, a popup)
func _poll() -> void:
	if menu_open and not menu_sticky and not Input.is_physical_key_pressed(KEY_Q):
		if Time.get_ticks_msec() - menu_t < TAP_MS and not menu_used:
			menu_sticky = true                       # tapped: it stays open
		elif not menu.search_focused() and not menu.popup_open() and not confirm.visible and not unsaved.visible \
				and not file_dlg.visible:
			_close_menu()
	if cursor and not Input.is_physical_key_pressed(KEY_C) and not unit_menu.visible:
		_end_cursor()
	if rotating and not Input.is_physical_key_pressed(KEY_E):
		rotating = false
	if not held.is_empty() and not unit_menu.visible and not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_drop()
	var c := Input.is_key_pressed(KEY_CTRL)          # (the viewer has moved this frame already: before it, the
	if not c:                                        # camera was where it was at the end of the last one)
		ctrl_chord = false
		free_cam = viewer.camera.position
	ctrl_down = c


func _load_mission() -> void:
	recs.clear()
	uids.clear()
	nodes.clear()
	origin.clear()
	src.clear()
	orig_recs.clear()
	orig_zones = PackedByteArray()
	adopted = false
	src_cache.clear()
	undo.clear()
	aim = {}
	held = {}
	dirty = false
	new_group = -1                                   # (group numbers mean other groups in another mission)
	team_group = 0
	dup = PackedByteArray()
	dup_src = {}
	lg = null
	if props != null and props.visible:
		_close_props()
	if viewer.current.is_empty() or viewer.current["entry"].get("gallery", false):
		if active:
			leave()
		return
	path = viewer.current["entry"]["file"]
	lg = LGRes.open(path)
	if lg == null:
		if active:
			leave()
		return
	for f in LGRes.frames(lg.data(173)):
		recs.append(PackedByteArray(f).duplicate())
	zones = lg.data(176).duplicate()
	for i in recs.size():
		uids.append(i + 1)
		origin.append(i)
		src.append({})
		orig_recs.append(recs[i].duplicate())
	orig_zones = zones.duplicate()
	next_uid = recs.size() + 1
	_adopt_backup()
	nodes = viewer.live_nodes.duplicate()
	groups = LGRes.names16(lg.data(172))
	sides = lg.data(174)
	refs = _mission_refs(path.get_file())
	_make_markers()
	if active:
		_fill_groups()
		_names(true)


# The original kept beside the file (the editor saved this mission before): the mission's own units and zones are
# its, and each unit of the file is one of them or an added one. Told by the editor's note beside it
# (<file>.uplink-edit: the changes as a creation, and the checksum of what was saved); a file saved by an older
# editor has none: its first units are the original's. An original that is not this file's (the file was made anew
# since) is left alone: the file is then its own original.
func _adopt_backup() -> void:
	var bak := path + BACKUP
	if not FileAccess.file_exists(bak):
		return
	var b = LGRes.open(bak)
	if not _whole(b) or not _same_but_units(b, lg):
		return
	var own := orig_recs
	var borig := []
	for f in LGRes.frames(b.data(173)):
		borig.append(PackedByteArray(f).duplicate())
	var bz: PackedByteArray = b.data(176).duplicate()
	orig_recs = borig                                # (a unit added as a copy of one of this mission's: _source)
	var note := _read_note()
	if not note.is_empty() and str(note.get("saved", "")) == Mod.base_sum(recs, zones):
		var st := Mod.apply(note, path, borig, bz, _source)
		if not st.has("error") and st["recs"] == recs and st["zones"] == zones:
			orig_zones = bz
			origin = st["origin"]
			src = st["src"]
			adopted = true
			return
	var k := _matches(b, lg, recs)
	if k < 0:
		orig_recs = own
		return
	orig_zones = bz
	for i in recs.size():
		origin[i] = i if i < k else -1
	adopted = true


func _read_note() -> Dictionary:
	var t := FileAccess.get_file_as_string(path + EDIT) if FileAccess.file_exists(path + EDIT) else ""
	if t == "" or t.length() > Mod.MAX_TEXT:
		return {}
	var j := JSON.new()
	if j.parse(t) != OK or not (j.data is Dictionary) or Mod.check(j.data) != "":
		return {}
	return j.data


# record `index` of the game's mission `file` as the game shipped it (the kept original when the editor changed
# that mission); empty: no such record
func _source(file: String, index: int) -> PackedByteArray:
	var f := file.to_upper()
	var list: Array = orig_recs
	if f != path.get_file().to_upper():
		if not src_cache.has(f):
			src_cache[f] = _original_units(_mission_path(f))
		list = src_cache[f]
	return list[index] if index >= 0 and index < list.size() else PackedByteArray()


func _mission_path(f: String) -> String:
	if mission_files.is_empty():
		var dir: String = viewer.data.data_dir()
		for n in DirAccess.get_files_at(dir):
			var u := n.to_upper()
			if u.begins_with("MISS") and u.ends_with(".RES"):
				mission_files[u] = dir.path_join(n)
	return mission_files.get(f.to_upper(), "")


static func _original_units(p: String) -> Array:
	var out := []
	if p == "":
		return out
	var r = LGRes.open(p + BACKUP) if FileAccess.file_exists(p + BACKUP) else null
	if not _whole(r):
		r = LGRes.open(p)
	if r != null and r.has(173):
		for f in LGRes.frames(r.data(173)):
			out.append(PackedByteArray(f).duplicate())
	return out


# an added unit whose record of the game is not known (saved by an older editor): the game's record of its type
# that differs least from it
func _guess_source(r: PackedByteArray) -> Dictionary:
	var best := {}
	var best_n := 999
	_mission_path("")
	var names := mission_files.keys()
	names.sort()
	for f in names:
		for i in 400:
			var b := _source(f, i)
			if b.is_empty():
				break
			if b[0] != r[0] or b[1] != r[1]:
				continue
			var n := 0
			for o in range(24, REC):
				if b[o] != r[o]:
					n += 1
			if n < best_n:
				best_n = n
				best = {"f": f, "i": i}
	return best


# what the mission's script does with labels and groups (scanned from the game's scripts): {} when not known
func _mission_refs(file: String) -> Dictionary:
	if all_refs == null:
		all_refs = {}
		var j = JSON.parse_string(FileAccess.get_file_as_string("res://data/mission_refs.json"))
		if j is Dictionary and j.get("missions") is Dictionary:
			all_refs = j["missions"]
	var e = all_refs.get(file.to_upper())
	return e if e is Dictionary else {}


# a mission file that can be read whole, with its units and zones
static func _whole(r) -> bool:
	return r != null and r.has(173) and r.has(176) and r.has(170)


# the same resources in the same order, all but the units and zones (173 / 176, the only ones a save writes) byte
# for byte (else another file: one made anew since, or another generator mission)
static func _same_but_units(b, cur) -> bool:
	if b.order != cur.order:
		return false
	for rid in b.order:
		if rid != 173 and rid != 176 and b.data(rid) != cur.data(rid):
			return false
	return true


# b is the original of the file cur (with these units) as an older editor saved it: cur's first units are b's units
# (same class, type and numbers); b's number of units, else -1
static func _matches(b, cur, cur_recs: Array) -> int:
	if not _same_but_units(b, cur):
		return -1
	var fr: Array = LGRes.frames(b.data(173))
	if fr.size() > cur_recs.size():
		return -1
	for i in fr.size():
		var a: PackedByteArray = fr[i]
		var c: PackedByteArray = cur_recs[i]
		if a.size() != REC or a.slice(0, 7) != c.slice(0, 7):
			return -1
	return fr.size()


func _is_added(i: int) -> bool:
	return int(origin[i]) < 0


# where a copy of unit i starts from: the game's record it is (the mission's own) or was made from
func _source_of(i: int) -> Dictionary:
	if int(origin[i]) >= 0:
		return {"f": path.get_file().to_upper(), "i": int(origin[i])}
	return (src[i] as Dictionary).duplicate()


func _make_markers() -> void:
	ring = MeshInstance3D.new()
	var t := TorusMesh.new()
	t.inner_radius = 0.75
	t.outer_radius = 0.95
	ring.mesh = t
	ring_mat = StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.no_depth_test = true
	ring_mat.albedo_color = HOT
	ring.material_override = ring_mat
	ring.visible = false
	viewer.world.add_child(ring)
	hover = Label3D.new()                            # just above the crosshair, drawn after every other name
	hover.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	hover.no_depth_test = true
	hover.fixed_size = true
	hover.pixel_size = 0.001
	hover.font_size = 30
	hover.outline_size = 10
	hover.render_priority = 10
	hover.outline_render_priority = 9
	hover.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	hover.offset = Vector2(0, 30)
	hover.visible = false
	viewer.world.add_child(hover)
	beam_pivot = Node3D.new()
	beam = MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = 0.025
	c.bottom_radius = 0.045
	c.height = 1.0
	c.radial_segments = 8
	beam.mesh = c
	var bm := StandardMaterial3D.new()
	bm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	bm.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	bm.albedo_color = BEAM
	bm.no_depth_test = true
	beam.material_override = bm
	beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	beam.rotation = Vector3(PI / 2.0, 0.0, 0.0)
	beam_pivot.add_child(beam)
	beam_pivot.visible = false
	viewer.world.add_child(beam_pivot)


func _fill_groups() -> void:
	var count := {}
	for r in recs:
		count[r[7]] = count.get(r[7], 0) + 1
	var items := [[-1, "Auto (like that type's units here)"]]
	var listed := false
	for g in groups.size():
		if count.has(g) or not _group_unnamed(g):
			items.append([g, _group_text(g, count.get(g, 0))])
			listed = listed or g == new_group
	if not listed:
		new_group = -1
	menu.set_groups(items, new_group)


func _group_unnamed(g: int) -> bool:
	var n := groups[g].strip_edges() if g < groups.size() else ""
	return n == "" or n.begins_with("(NULL") or n.begins_with("**")   # (the empty slots: "** UNUSED **")


func _group_text(g: int, n: int = -1) -> String:
	var gname := "group %d" % g if _group_unnamed(g) else groups[g].strip_edges()
	var side: int = sides[g] if g < sides.size() else 0
	return "%d  %s  ·  %s%s" % [g, gname, SIDES.get(side, "side %d" % side), "" if n < 0 else "  (%d)" % n]


# one record of each unit type in the game's own missions (the originals when the editor changed one), the one
# with its armour full when there is one; the most units of each class in one mission
func _build_catalog() -> void:
	var have := {}
	var carried := {}                                # weapon id -> {type name: true}
	_mission_path("")
	var names := mission_files.keys()
	names.sort()
	for f in names:
		if not src_cache.has(f) and f != path.get_file().to_upper():
			src_cache[f] = _original_units(mission_files[f])
		var per := {}
		for i in 4000:
			var rec := _source(f, i)
			if rec.is_empty():
				break
			if rec.size() != REC:
				continue
			per[rec[0]] = per.get(rec[0], 0) + 1
			var key := rec[0] * 256 + rec[1]
			var tn: String = viewer.data.type_name(rec[0], rec[1])
			for o in Props.WEAPON_AT.get(rec[0], []):
				if rec[o] != 0:
					if not carried.has(rec[o]):
						carried[rec[o]] = {}
					carried[rec[o]][tn] = true
			if not have.has(key):
				have[key] = catalog.size()
				catalog.append({"cls": rec[0], "sub": rec[1], "name": tn, "kind": KINDS.get(rec[0], "Other"), "rec": rec,
					"f": f, "i": i})
			elif not _full_armour(catalog[have[key]]["rec"]) and _full_armour(rec):
				catalog[have[key]]["rec"] = rec
				catalog[have[key]]["f"] = f
				catalog[have[key]]["i"] = i
		for c in per:
			class_max[c] = maxi(class_max.get(c, 0), per[c])
	catalog.sort_custom(func(a, b): return _rank(a["cls"]) * 256 + a["sub"] < _rank(b["cls"]) * 256 + b["sub"])
	# the weapons: the game names the player's (1 to 17, its weapon panel); the others are told by who carries them
	weapon_names.clear()
	for id in carried:
		var who: Array = carried[id].keys()
		who.sort()
		var t := ", ".join(who.slice(0, 3)) + ("..." if who.size() > 3 else "")
		if int(id) < CoopHud.WEAPONS.size() and CoopHud.WEAPONS[int(id)] != "":
			weapon_names[int(id)] = "%d  ·  %s" % [id, CoopHud.WEAPONS[int(id)]]
		else:
			weapon_names[int(id)] = "%d  ·  as carried by %s" % [id, t]
	for id in range(1, CoopHud.WEAPONS.size()):
		if not weapon_names.has(id):
			weapon_names[id] = "%d  ·  %s" % [id, CoopHud.WEAPONS[id]]


static func _rank(cls: int) -> int:
	var i := KIND_ORDER.find(cls)
	return i if i >= 0 else KIND_ORDER.size() + cls


static func _armour_parts(cls: int) -> int:
	return 7 if cls == 1 else 3 if cls in [2, 3, 4] else 0


static func _full_armour(r: PackedByteArray) -> bool:
	for k in _armour_parts(r[0]):
		if r[ARMOUR + k] < 100:
			return false
	return true


# ---- aiming
func _aim_point() -> Vector2:
	return get_viewport().get_mouse_position() if _free_mouse() else get_viewport().get_visible_rect().size * 0.5


func _index(uid: int) -> int:
	return uids.find(uid)


func _node_of(t: Dictionary) -> Node3D:
	if t.get("kind", "") == "unit":
		var i := _index(int(t["uid"]))
		return nodes[i] if i >= 0 and is_instance_valid(nodes[i]) else null
	if t.get("kind", "") == "zone":
		var z = viewer.zone_nodes.get(int(t["i"]))
		return z if z != null and is_instance_valid(z) else null
	return null


func _pick_at(screen: Vector2) -> Dictionary:
	var cam: Camera3D = viewer.camera
	var best := PICK_PX
	var best_d := INF
	var out := {}
	for i in nodes.size():
		var n = nodes[i]
		if n == null or not is_instance_valid(n):
			continue
		var p: Vector3 = n.global_position + Vector3(0, 0.4, 0)
		if cam.is_position_behind(p):
			continue
		var dd := cam.unproject_position(p).distance_to(screen)
		var depth := cam.global_position.distance_to(p)
		if dd < best - 4.0 or (dd < best + 4.0 and depth < best_d):
			best = minf(best, dd)
			best_d = depth
			out = {"kind": "unit", "uid": uids[i]}
	for zi in viewer.zone_nodes:
		var zn = viewer.zone_nodes[zi]
		if zn == null or not is_instance_valid(zn) or not zn.visible:
			continue
		for hh in [-2.5, 0.0, 2.5]:                # anywhere along its post
			var p: Vector3 = zn.global_position + Vector3(0, hh, 0)
			if cam.is_position_behind(p):
				continue
			var dd := cam.unproject_position(p).distance_to(screen)
			if dd < best:
				best = dd
				best_d = cam.global_position.distance_to(p)
				out = {"kind": "zone", "i": int(zi)}
	return out


# the ground under the screen point: map x, y, or null (the sky, or off the map)
func _ground_at(screen: Vector2):
	var cam: Camera3D = viewer.camera
	var o := cam.project_ray_origin(screen)
	var d := cam.project_ray_normal(screen)
	var t := _ray_ground(o, d)
	if t < 0.0:
		return null
	var hit := o + d * t
	if hit.x < 2.0 or hit.x > 510.0 or hit.z < 2.0 or hit.z > 510.0:
		return null
	return Vector2(hit.x, hit.z)


# distance along the ray to the terrain, -1 if it never meets it
func _ray_ground(o: Vector3, d: Vector3) -> float:
	var m: Dictionary = viewer.current["map"]
	var t := 0.0
	var prev := 0.0
	while t < 1500.0:
		var p := o + d * t
		if p.y < TNData.height_at(m, p.x, p.z):
			var a := prev
			var b := t
			for k in 14:
				var mid := (a + b) * 0.5
				var q := o + d * mid
				if q.y < TNData.height_at(m, q.x, q.z):
					b = mid
				else:
					a = mid
			return b
		prev = t
		t += 0.25 if t < 60.0 else 1.0
	return -1.0


# where a new unit goes: the crosshair on the ground, else the ground lower in the view (aiming at the horizon),
# else null (nothing in view to put it on); off a unit already there, so that clicks in a row don't pile them up
func _spawn_point():
	var size := get_viewport().get_visible_rect().size
	for k in [0.5, 0.65, 0.8, 0.95]:
		var g = _ground_at(Vector2(size.x * 0.5, size.y * k))
		if g != null:
			return _free_spot(g)
	return null


func _free_spot(g: Vector2) -> Vector2:
	for k in 24:
		var p := g if k == 0 else g + Vector2.from_angle(k * 2.4) * (0.8 + 0.35 * sqrt(float(k)))
		p = Vector2(clampf(p.x, 2.0, 510.0), clampf(p.y, 2.0, 510.0))
		var taken := false
		for r in recs:
			if Vector2(r.decode_s32(8), r.decode_s32(12)).distance_to(p * 65536.0) < 0.7 * 65536.0:
				taken = true
				break
		if not taken:
			return p
	return g


func _facing_camera(g: Vector2) -> int:
	var c: Vector3 = viewer.camera.global_position
	return int(round(atan2(c.z - g.y, c.x - g.x) / TAU * 65536.0)) & 0xFFFF


func _show_aim(t: Dictionary) -> void:
	if ring == null or not is_instance_valid(ring):
		return
	var n := _node_of(t) if active else null
	ring.visible = n != null
	hover.visible = n != null
	beam_pivot.visible = n != null and not held.is_empty() and held.get("crosshair", false)
	if n == null:
		return
	var m: Dictionary = viewer.current["map"]
	var g := Vector2(n.position.x, n.position.z)
	var ground := TNData.height_at(m, g.x, g.y)
	ring.position = Vector3(g.x, ground + 0.05, g.y)
	ring_mat.albedo_color = BEAM if not held.is_empty() else HOT
	hover.position = n.global_position + Vector3(0, _top_of(t, n) + 0.1, 0)   # (above it: the text goes up from there)
	hover.modulate = BEAM.lightened(0.3) if not held.is_empty() else Color(1, 1, 1)
	hover.text = _describe(t)


# the top of what is aimed at, above its node: a zone post's top, a unit's highest part (its model or limbs,
# measured once); never under where it is picked (0.4)
func _top_of(t: Dictionary, n: Node3D) -> float:
	if t["kind"] == "zone":
		return 3.0
	if not n.has_meta("edit_top"):
		var top := 0.4
		var vis: Array = n.find_children("*", "GeometryInstance3D", true, false)
		vis.append(n)
		for v in vis:
			var g := v as GeometryInstance3D
			if g == null or g is Label3D:
				continue
			var b: AABB = g.global_transform * g.get_aabb()
			if b.size != Vector3.ZERO:
				top = maxf(top, b.end.y - n.global_position.y)
		n.set_meta("edit_top", top)
	return float(n.get_meta("edit_top"))


# the zone posts' names in the build mode: only those near the crosshair (or all with F2), so that far ones do
# not pile up
func _zone_names() -> void:
	var cam: Camera3D = viewer.camera
	var at := _aim_point()
	for zi in viewer.zone_nodes:
		var zn = viewer.zone_nodes[zi]
		if zn == null or not is_instance_valid(zn):
			continue
		var near: bool = names_all or aim.get("i", -1) == zi or held.get("i", -1) == zi
		if not near:
			var p: Vector3 = zn.global_position + Vector3(0, 3.6, 0)
			near = not cam.is_position_behind(p) and cam.unproject_position(p).distance_to(at) < 220.0
		for c in zn.get_children():
			if c is Label3D:
				c.visible = near


func _describe(t: Dictionary) -> String:
	if t["kind"] == "zone":
		return "Zone %d  %s" % [t["i"], _zone_name(int(t["i"]))]
	var i := _index(int(t["uid"]))
	var r: PackedByteArray = recs[i]
	return "%s\n%s%s  ·  %s" % [viewer.data.type_name(r[0], r[1]), _group_text(r[7]),
		"  ·  label %d" % r[26] if r[26] != 0 else "", "added" if _is_added(i) else "mission"]


func _zone_name(i: int) -> String:
	var names := LGRes.names16(lg.data(177))
	var n := names[i] if i < names.size() else ""
	return n.substr(n.find(": ") + 2) if n.contains(": ") else n


func _beam_update() -> void:
	if beam_pivot == null or not is_instance_valid(beam_pivot) or not beam_pivot.visible:
		return
	var n := _node_of(held)
	if n == null:
		beam_pivot.visible = false
		return
	var cam: Camera3D = viewer.camera
	var b := cam.global_transform.basis
	var a := cam.global_position + b.x * 0.32 - b.y * 0.26 - b.z * 0.7     # the gun, bottom right
	var e := n.global_position + Vector3(0, 0.4, 0)
	var len := a.distance_to(e)
	if len < 0.05:
		return
	beam_pivot.global_position = a
	if absf((e - a).normalized().dot(Vector3.UP)) < 0.999:
		beam_pivot.look_at(e, Vector3.UP)
	else:
		beam_pivot.look_at(e, Vector3.FORWARD)
	beam.position = Vector3(0, 0, -len * 0.5)
	beam.scale = Vector3(1.0, len, 1.0)


# ---- input
func _unhandled_input(event: InputEvent) -> void:
	if not active or lg == null:
		return
	if event is InputEventKey:
		if _key(event):
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		_button(event)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if rotating and not held.is_empty() and held["kind"] == "unit":
			_rotate_by(event.relative.x)
			get_viewport().set_input_as_handled()


func _key(e: InputEventKey) -> bool:
	var pk := e.physical_keycode
	if pk == KEY_Q:
		if e.pressed and not e.echo:
			if menu_open and menu_sticky:
				_close_menu()
			elif not menu_open:
				_open_menu()
		return true                                  # (its release: _poll)
	if pk == KEY_C:
		if e.pressed and not e.echo and not menu_open:
			_drop()
			cursor = true
			_capture(false)
		return true
	if pk == KEY_E:
		if e.pressed and not e.echo and not held.is_empty() and held["kind"] == "unit":
			rotating = true
			rot_acc = 0.0
			held["rot_base"] = recs[_index(int(held["uid"]))].decode_u16(20)
		return true
	if not e.pressed or e.echo:
		return false
	if pk == KEY_ESCAPE:
		if menu_open:
			_close_menu()
		elif props.visible:
			_close_props()
		elif cursor:
			_end_cursor()
		else:
			leave()
		return true
	if pk == KEY_F2:
		names_all = not names_all
		_names(true)
		notify("Every unit's name" if names_all else "Only the name of the unit aimed at")
		return true
	if pk in TOOL_KEYS:
		_set_tool(TOOL_KEYS.find(pk))
		return true
	if pk == KEY_Z or (e.keycode == KEY_Z and e.ctrl_pressed):
		_ctrl_shortcut(e)
		_undo()
		return true
	if e.keycode == KEY_S and e.ctrl_pressed:
		_ctrl_shortcut(e)
		save()
		return true
	if menu_open:
		return pk in [KEY_R, KEY_DELETE, KEY_TAB]   # (nothing under the crosshair is seen behind the menu)
	if pk == KEY_R:
		var t := held if not held.is_empty() else aim
		if t.get("kind", "") == "unit":
			_turn(int(t["uid"]), -15.0 if e.shift_pressed else 15.0)
		return true
	if pk == KEY_DELETE:
		if aim.get("kind", "") == "unit":
			_remove(int(aim["uid"]))
		return true
	if pk == KEY_P:
		var t := held if not held.is_empty() else aim
		if props.visible and (t.get("kind", "") != "unit" or int(t["uid"]) == props_uid):
			_close_props()
		elif t.get("kind", "") == "unit":
			_drop()
			_open_props(int(t["uid"]))
		else:
			notify("Aim at a unit to see its properties", HOT)
		return true
	if pk == KEY_TAB:
		return true                                  # (the viewer's panel stays hidden in the build mode)
	return false


# Ctrl is also the viewer's "down": what it did before the letter is undone, and the camera stays until Ctrl is up
func _ctrl_shortcut(e: InputEventKey) -> void:
	if e.ctrl_pressed:
		viewer.camera.position = free_cam
		ctrl_chord = true


func _button(e: InputEventMouseButton) -> void:
	if menu_open or confirm.visible or unsaved.visible or file_dlg.visible:
		return
	var typed := get_viewport().gui_get_focus_owner()
	if typed != null and props.is_ancestor_of(typed):    # (a click in the view: the panel's field is done)
		typed.release_focus()
	if refocus and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		refocus = false
		if Time.get_ticks_msec() - focus_in_t < 300:  # the click that brought the window back: no tool
			_recapture()
			return
	if e.button_index == MOUSE_BUTTON_WHEEL_UP or e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		if not held.is_empty() and held.get("crosshair", false):
			if e.pressed:
				if not held.get("wheel", false):     # from now on along the aim, past the ground it meets: from the
					var cam: Camera3D = viewer.camera     # point it is held at now (no jump)
					var hit := _ray_ground(cam.global_position, -cam.global_transform.basis.z)
					if hit >= 0.0 and hit < float(held["dist"]):
						held["dist"] = maxf(hit, HOLD_MIN)
					held["wheel"] = true
				var f := 1.12 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12
				held["dist"] = clampf(float(held["dist"]) * f, HOLD_MIN, HOLD_MAX)
		elif e.pressed:                              # (not holding: the viewer's flying speed)
			viewer.speed = clampf(viewer.speed * (1.25 if e.button_index == MOUSE_BUTTON_WHEEL_UP else 0.8), 2.0, 400.0)
		return
	if e.button_index == MOUSE_BUTTON_LEFT:
		if not e.pressed:
			_drop()
			return
		if cursor or props.visible:
			var t := _pick_at(e.position)
			if not t.is_empty():
				if props.visible and t["kind"] == "unit" and int(t["uid"]) != props_uid:
					_open_props(int(t["uid"]))
				_grab(t, false)
			return
		match tool:
			PHYSGUN:
				if not aim.is_empty():
					_grab(aim, true)
			REMOVER:
				if aim.get("kind", "") == "unit":
					_remove(int(aim["uid"]))
				else:
					notify("Aim at a unit to remove it", HOT)
			DUPLICATOR:
				if dup.is_empty():
					notify("Right click a unit first to copy it", HOT)
				else:
					var g = _spawn_point()
					if g == null:
						notify("Aim at the ground to place the copy", HOT)
					else:
						var full := _no_room(dup)
						if full != "":
							notify("Not pasted: " + full, BAD)
						else:
							var uid := _add_rec(dup, g, dup.decode_u16(20), dup[7], dup_src)
							_push({"op": "spawn", "uid": uid})
							notify("Pasted: " + viewer.data.type_name(dup[0], dup[1]))
							_warn_note(dup[0])
			TEAM:
				if aim.get("kind", "") == "unit":
					_regroup(int(aim["uid"]), team_group)
				else:
					notify("Aim at a unit to put it in group %d" % team_group, HOT)
	elif e.button_index == MOUSE_BUTTON_RIGHT and e.pressed:
		if cursor or props.visible:
			var t := _pick_at(e.position)
			if t.get("kind", "") == "unit":
				_open_unit_menu(t, e.position)
			return
		var tu: bool = aim.get("kind", "") == "unit"
		match tool:
			PHYSGUN:
				_drop()
			DUPLICATOR:
				if tu:
					dup = recs[_index(int(aim["uid"]))].duplicate()
					dup_src = _source_of(_index(int(aim["uid"])))
					notify("Copied: " + viewer.data.type_name(dup[0], dup[1]))
			TEAM:
				if tu:
					team_group = recs[_index(int(aim["uid"]))][7]
					notify("Group picked: " + _group_text(team_group))


func _set_tool(i: int) -> void:
	_drop()
	tool = i
	_paint_tools()
	menu.set_tool(i)


func _paint_tools() -> void:
	for i in tool_labels.size():
		var b: Button = tool_labels[i]
		b.text = "%s %s" % [_k(TOOL_KEYS[i]), TOOL_NAMES[i]]
		var on := i == tool
		var col := Color(0.3, 0.62, 0.95) if on else Color(0.2, 0.22, 0.26)
		b.add_theme_stylebox_override("normal", Menu._box(col.darkened(0.2) if on else Color(0.06, 0.07, 0.09, 0.75), col, 1, 6, 6))
		b.add_theme_stylebox_override("hover", Menu._box(col.darkened(0.1), Color(0.5, 0.8, 1.0), 1, 6, 6))
		b.add_theme_color_override("font_color", Color(1, 1, 1) if on else Color(0.7, 0.74, 0.78))


func _tool_list() -> Array:
	return [[TOOL_NAMES[0], "Grab, move and turn units and zone posts", _k(KEY_1)],
		[TOOL_NAMES[1], "Remove a unit (the mission's own too)", _k(KEY_2)],
		[TOOL_NAMES[2], "Right: copy a unit · Left: place the copy", _k(KEY_3)],
		[TOOL_NAMES[3], "Put units in a group (their side)", _k(KEY_4)]]


func _help() -> String:
	return ("%s held: this menu (tap: it stays open)\nMouse: look · %s: fly\nSpace / Ctrl: up / down · Shift: fast\n" +
		"%s held: cursor (drag, right click a unit)\n%s: properties of the unit aimed at\n" +
		"%s: undo · %s: turn · Del: remove\nF2: every unit's name\n" +
		"Ctrl+S: save · Esc: leave") % [_k(KEY_Q), _fly_keys(), _k(KEY_C), _k(KEY_P), _k(KEY_Z), _k(KEY_R)]


func _hint() -> String:
	if menu_open:
		return "Click a picture to spawn it where you aim   ·   %s %s (or Esc) to close" % [
			"press" if menu_sticky else "release", _k(KEY_Q)]
	if cursor or props.visible:
		if not held.is_empty():
			return "Move the mouse: move it   ·   %s + mouse: turn   ·   release: drop" % _k(KEY_E)
		if props.visible:
			return "Properties   ·   Left: pick another unit (drag: move it)   ·   Right click a unit: its menu   ·   %s or Esc: close" % _k(KEY_P)
		return "Left (drag): move   ·   Right click a unit: its menu   ·   release %s: back to the crosshair" % _k(KEY_C)
	if not held.is_empty():
		if rotating:
			return "Mouse: turn it   (Shift: 15° steps)   ·   release %s: stop turning" % _k(KEY_E)
		return "Aim: move it   ·   Wheel: push / pull   ·   %s + mouse: turn   ·   release: drop" % _k(KEY_E)
	match tool:
		REMOVER:
			return "Left: remove the unit aimed at   ·   %s: undo   ·   %s: spawn menu" % [_k(KEY_Z), _k(KEY_Q)]
		DUPLICATOR:
			var c: String = "nothing copied yet" if dup.is_empty() else "copied: " + viewer.data.type_name(dup[0], dup[1])
			return "Right: copy the unit aimed at   ·   Left: place the copy   (%s)" % c
		TEAM:
			return "Left: put the unit aimed at in %s   ·   Right: take its group" % _group_text(team_group)
	return "Left (hold): grab   ·   %s: spawn menu   ·   %s: cursor   ·   %s: properties   ·   %s: undo   ·   Esc: leave" % [
		_k(KEY_Q), _k(KEY_C), _k(KEY_P), _k(KEY_Z)]


# ---- menus
func _open_menu() -> void:
	_drop()
	menu_open = true
	menu_sticky = false
	menu_used = false
	menu_t = Time.get_ticks_msec()
	aim = {}                                         # (what was under the crosshair is hidden behind the menu)
	menu.set_file(path.get_file(), dirty)
	menu.visible = true
	notes.visible = false                            # (they would show through its bottom right corner)
	var want := []
	for c in catalog:
		want.append([c["cls"], c["sub"]])
	thumbs.paused = false
	thumbs.request(want)                             # (the pictures fill in as they are drawn)
	_capture(false)


func _close_menu() -> void:
	if not menu_open:
		return
	menu_open = false
	menu_sticky = false
	menu.visible = false
	notes.visible = true
	for p in notes.get_children():                   # (hidden under the menu until now: their time starts now)
		p.set_meta("t", Time.get_ticks_msec())
		p.modulate.a = 1.0
	thumbs.paused = true                             # (no drawing while flying: it would stutter)
	menu.search.release_focus()
	_recapture()


func _end_cursor() -> void:
	_drop()
	cursor = false
	_recapture()


func _on_menu_spawn(i: int) -> void:
	var c: Dictionary = catalog[i]
	var g = _spawn_point()
	if g == null:
		menu.flash(i, "Aim at the ground to spawn", BAD)
		notify("Aim at the ground to spawn %s" % c["name"], HOT)
		return
	var group := new_group
	var warn := ""
	if group < 0:
		group = _auto_group(c["cls"], c["sub"])
		if group < 0:
			group = 0
			warn = "no %s group in this mission: it joins %s" % [SIDES[_side_of(c["cls"], c["sub"])], _group_text(0)]
	var rec := PackedByteArray(c["rec"]).duplicate()
	for k in _armour_parts(rec[0]):                  # (some of the game's units start damaged: these start whole)
		rec[ARMOUR + k] = maxi(rec[ARMOUR + k], 100)
	var full := _no_room(rec)
	if full != "":
		menu.flash(i, "Not spawned: " + full, BAD)
		notify("Not spawned: " + full, BAD)
		return
	var uid := _add_rec(rec, g, _facing_camera(g), group, {"f": c["f"], "i": c["i"]})
	_push({"op": "spawn", "uid": uid})
	var n := 0
	for r in recs:
		if r[0] == c["cls"] and r[1] == c["sub"]:
			n += 1
	var many := _warn_class(c["cls"])
	if many != "":
		warn = many if warn == "" else warn + "; " + many
	if warn != "":                                   # (said in the menu: its notices are hidden while it is open)
		menu.flash(i, "Spawned %s: %s" % [c["name"], warn], HOT)
		notify("Spawned %s: %s" % [c["name"], warn], HOT)
	else:
		menu.flash(i, "Spawned %s  (%d here)" % [c["name"], n], GOOD)
		notify("Spawned " + c["name"])
	menu.set_file(path.get_file(), dirty)
	menu_used = true
	if menu_sticky:                                  # opened with a tap: closed, the new unit right under the crosshair
		_close_menu()


func _side_of(cls: int, sub: int) -> int:
	return 1 if viewer.data.is_friendly(viewer.data.type_name(cls, sub)) else 2


# a new unit's group: that of a unit of the same type in this mission, else the most used group of its side
# (Strike Force for the SFC's own types, else the enemy), else any group of that side; -1: none in this mission
func _auto_group(cls: int, sub: int) -> int:
	for r in recs:
		if r[0] == cls and r[1] == sub:
			return r[7]
	var want := _side_of(cls, sub)
	var count := {}
	for r in recs:
		if r[7] < sides.size() and sides[r[7]] == want:
			count[r[7]] = count.get(r[7], 0) + 1
	var best := -1
	for g in count:
		if best < 0 or count[g] > count[best]:
			best = g
	if best >= 0:
		return best
	for g in sides.size():
		if sides[g] == want:
			return g
	return -1


func _warn_note(cls: int) -> void:
	var w := _warn_class(cls)
	if w != "":
		notify(w, HOT)


# more units of a class than any of the game's missions has: the warning ("" if not)
func _warn_class(cls: int) -> String:
	var same := 0
	for r in recs:
		if r[0] == cls:
			same += 1
	if class_max.has(cls) and same > class_max[cls]:
		return "%d %s units here, more than any of the game's missions has (%d): the game may not take them all" % [
			same, KINDS.get(cls, "such").to_lower(), class_max[cls]]
	return ""


func _open_unit_menu(t: Dictionary, at: Vector2) -> void:
	menu_target = t
	var i := _index(int(t["uid"]))
	var r: PackedByteArray = recs[i]
	unit_menu.clear()
	unit_menu.add_separator(viewer.data.type_name(r[0], r[1]))
	unit_menu.add_item("Turn 90°", 1)
	unit_menu.add_item("Face me", 2)
	unit_menu.add_item("Duplicate", 3)
	unit_menu.add_item("Copy (duplicator)", 4)
	unit_menu.add_item("Properties", 6)
	unit_menu.add_item("Remove" if _is_added(i) else "Remove (the mission's own)", 5)
	unit_menu.add_separator("Put in group")
	var count := {}
	for q in recs:
		count[q[7]] = count.get(q[7], 0) + 1
	for g in groups.size():
		if count.has(g) or not _group_unnamed(g):
			unit_menu.add_radio_check_item(_group_text(g, count.get(g, 0)), 100 + g)
			unit_menu.set_item_checked(unit_menu.get_item_index(100 + g), g == r[7])
	unit_menu.reset_size()
	unit_menu.popup(Rect2i(Vector2i(at), Vector2i.ZERO))


func _on_unit_menu(id: int) -> void:
	var uid := int(menu_target.get("uid", -1))
	var i := _index(uid)
	if i < 0:
		return
	var r: PackedByteArray = recs[i]
	match id:
		1:
			_turn(uid, 90.0)
		2:
			var g := Vector2(r.decode_s32(8) / 65536.0, r.decode_s32(12) / 65536.0)
			_push({"op": "turn", "uid": uid, "h": r.decode_u16(20)})
			_set_heading(uid, _facing_camera(g))
		3:
			var g := _free_spot(Vector2(r.decode_s32(8) / 65536.0 + 2.0, r.decode_s32(12) / 65536.0))
			var full := _no_room(r)
			if full != "":
				notify("Not duplicated: " + full, BAD)
				return
			var nu := _add_rec(r, g, r.decode_u16(20), r[7], _source_of(i))
			_push({"op": "spawn", "uid": nu})
			notify("Duplicated " + viewer.data.type_name(r[0], r[1]))
			_warn_note(r[0])
		4:
			dup = r.duplicate()
			dup_src = _source_of(i)
			notify("Copied: %s  (duplicator, %s)" % [viewer.data.type_name(r[0], r[1]), _k(KEY_3)])
		5:
			_remove(uid)
		6:
			_open_props(uid)
		_:
			if id >= 100:
				_regroup(uid, id - 100)


func _ask_revert() -> void:
	if not FileAccess.file_exists(path + BACKUP):
		notify("Nothing to revert: this mission was never saved by the editor", HOT)
		return
	confirm.popup_centered()


# ---- limits: the game's tables
static func _is_ai(r: PackedByteArray) -> bool:
	return r[0] in [1, 2, 3] or (r[0] == 4 and (r[7] != 0 or r[30] != 0 or r[31] != 0))


func _ai_count() -> int:
	var n := SQUAD
	var later: PackedByteArray = lg.data(181) if lg != null else PackedByteArray()
	if later.size() >= 4:                            # the units the script brings in later: a bit a slot
		var m := later.decode_u32(0)
		for k in 32:
			n += (m >> k) & 1
	for r in recs:
		if _is_ai(r):
			n += 1
	return n


# why one more unit like r does not fit in the game ("" when it does)
func _no_room(r: PackedByteArray) -> String:
	if recs.size() + SQUAD + 1 > MAX_ENTITIES:
		return "the game has %d places for everything on the map" % MAX_ENTITIES
	if _is_ai(r) and _ai_count() + 1 > MAX_AI:
		return "the game drives %d units at most (soldiers, vehicles, probes, armed buildings, your squad): %d here" % [
			MAX_AI, _ai_count()]
	return ""


# ---- the properties panel
func _open_props(uid: int) -> void:
	var i := _index(uid)
	if i < 0:
		return
	var r: PackedByteArray = recs[i]
	var gl := []
	for g in MAX_GROUP + 1:
		gl.append([g, _group_text(g)])
	props_uid = uid
	props.show_unit(r, {"name": viewer.data.type_name(r[0], r[1]), "kind": "added" if _is_added(i) else "the mission's own",
		"groups": gl, "weapons": weapon_names, "note": _script_use(i, false)})
	props.visible = true
	_capture(false)


func _close_props() -> void:
	props.visible = false
	props_uid = -1
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	if f != null and props.is_ancestor_of(f):
		f.release_focus()
	_recapture()


# its unit moved, turned, undone or removed elsewhere
func _props_sync() -> void:
	if not props.visible:
		return
	var i := _index(props_uid)
	if i < 0:
		_close_props()
	elif props.rec != recs[i]:
		props.refresh(recs[i], _script_use(i, false))


# What the mission's script does with this unit's label and group (data/mission_refs.json, scanned from the game's
# scripts), and with `removing` what taking the unit out changes; "" when nothing is known to use it. The game
# counts an objective's units by label, in % of those the mission starts with; a group with no unit left does not
# exist for the script.
func _script_use(i: int, removing: bool) -> String:
	var r: PackedByteArray = recs[i]
	var label: int = r[26]
	var g: int = r[7]
	var same_label := 0
	var same_group := 0
	for k in recs.size():
		if k != i:
			same_label += 1 if recs[k][26] == label else 0
			same_group += 1 if recs[k][7] == g else 0
	var out := []
	if label != 0:
		var key := str(label)
		var uses := []
		var kill = refs.get("kill", {}).get(key)
		var alive = refs.get("alive", {}).get(key)
		if kill is Array:
			uses.append("the objectives count its units destroyed (%s %%)" % _pcts(kill))
		if alive is Array:
			uses.append("the objectives need its units alive (%s %%)" % _pcts(alive))
		if _has_num(refs.get("follow", []), label):
			uses.append("a group follows it")
		if _has_num(refs.get("attack", []), label):
			uses.append("a group is sent to attack it")
		if _has_num(refs.get("count", []), label):
			uses.append("the script counts its losses")
		if uses.is_empty():
			uses.append("the mission's script may know this unit by it")
		var t := "Label %d: %s" % [label, ", ".join(uses)]
		if removing:
			t += "; %d other unit%s with this label" % [same_label, "" if same_label == 1 else "s"]
			if same_label == 0:
				t += ": what waits for it is met at once, or never"
		out.append(t)
	if g != 0 and _has_num(refs.get("groups", []), g):
		var t := "Group %d gets its orders from the mission's script" % g
		if removing and same_group == 0:
			t = "It was the last unit of group %d, which the mission's script gives orders to: the group is gone for it" % g
		out.append(t)
	elif removing and g != 0 and same_group == 0:
		out.append("It was the last unit of group %d: the group is gone" % g)
	return ".  ".join(out)


static func _pcts(a: Array) -> String:
	var parts := []
	for v in a:
		parts.append(str(int(v)))
	return " / ".join(parts)


static func _has_num(a, v: int) -> bool:
	if a is Array:
		for x in a:
			if int(x) == v:
				return true
	return false


# ---- sharing: a creation is the changes against the original mission (mission_mod.gd)
func _state() -> Dictionary:
	return {"recs": recs, "origin": origin, "src": src, "zones": zones}


func creation() -> Dictionary:
	for i in recs.size():
		if _is_added(i) and (src[i] as Dictionary).is_empty():
			src[i] = _guess_source(recs[i])
	return Mod.make(path, orig_recs, orig_zones, _state(), _source)


# the creation as a code to paste ("" and a notice when it can't be made)
func export_code() -> String:
	var mod := creation()
	if mod.has("error"):
		_say("Not exported: " + str(mod["error"]), BAD)
		return ""
	return Mod.to_code(mod)


# "" when written, else what went wrong
func export_file(to: String) -> String:
	var mod := creation()
	if mod.has("error"):
		return str(mod["error"])
	var f := FileAccess.open(to, FileAccess.WRITE)
	if f == null:
		return "%s could not be written" % to.get_file()
	f.store_string(Mod.to_json(mod))
	f.close()
	return ""


# A creation (what a .tnmod file holds, or a pasted code) put on the ORIGINAL mission, in the editor only: nothing
# is written, the player saves; one undo brings back what was there. "" or why it was not taken.
func import_text(t: String) -> String:
	if lg == null:
		return "no mission to put it on"
	var mod := Mod.from_text(t)
	if mod.has("error"):
		return str(mod["error"])
	var st := Mod.apply(mod, path, orig_recs, orig_zones, _source)
	if st.has("error"):
		return str(st["error"])
	_drop()
	var before := _snapshot()
	_restore(st)
	_push({"op": "state", "st": before, "what": "the import"})
	return ""


func _snapshot() -> Dictionary:
	var rc := []
	for r in recs:
		rc.append(r.duplicate())
	return {"recs": rc, "uids": uids.duplicate(), "origin": origin.duplicate(), "src": src.duplicate(true),
		"zones": zones.duplicate(), "next_uid": next_uid}


# the whole state replaced (an import, or its undo): every unit drawn again, the zone posts put where they are
func _restore(st: Dictionary) -> void:
	_drop()
	aim = {}
	if props.visible:
		_close_props()
	for n in nodes:
		if n != null and is_instance_valid(n):
			n.queue_free()
	recs = st["recs"]
	origin = st["origin"]
	src = st["src"]
	zones = st["zones"]
	if st.has("uids"):
		uids = st["uids"]
		next_uid = maxi(next_uid, int(st["next_uid"]))
	else:
		uids = []
		for i in recs.size():
			uids.append(next_uid)
			next_uid += 1
	nodes = []
	for r in recs:
		var n := _make_node(r)
		_new_names(n)
		nodes.append(n)
	for zi in viewer.zone_nodes:
		_place_zone(int(zi))
	dirty = true
	if active:
		_fill_groups()


func _place_zone(zi: int) -> void:
	var zn = viewer.zone_nodes.get(zi)
	if zn == null or not is_instance_valid(zn) or 8 * zi + 8 > zones.size():
		return
	var g := Vector2(zones.decode_s32(8 * zi) / 65536.0, zones.decode_s32(8 * zi + 4) / 65536.0)
	zn.position = Vector3(g.x, TNData.height_at(viewer.current["map"], g.x, g.y) + 3.0, g.y)


# said where it is seen: the menu hides the notices while it is open
func _say(t: String, col: Color) -> void:
	notify(t, col)
	if menu_open:
		menu.flash(-1, t, col)
		menu.set_file(path.get_file(), dirty)


func _on_export_file() -> void:
	dlg_import = false
	file_dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	file_dlg.title = "Export this creation"
	if file_dlg.current_dir == "" or file_dlg.current_path.begins_with("res://"):
		file_dlg.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	file_dlg.current_file = "%s creation.%s" % [path.get_file().get_basename(), Mod.EXT]
	file_dlg.popup_centered()


func _on_import_file() -> void:
	dlg_import = true
	file_dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	file_dlg.title = "Import a creation"
	if file_dlg.current_dir == "" or file_dlg.current_path.begins_with("res://"):
		file_dlg.current_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	file_dlg.popup_centered()


func _on_file_picked(p: String) -> void:
	if dlg_import:
		var f := FileAccess.open(p, FileAccess.READ)
		if f == null or f.get_length() > Mod.MAX_TEXT:
			_say("Not imported: %s can't be read (or is too big to be a creation)" % p.get_file(), BAD)
		else:
			_import_report(import_text(f.get_as_text()))
	else:
		if p.get_extension().to_lower() != Mod.EXT:
			p += "." + Mod.EXT
		var err := export_file(p)
		if err != "":
			_say("Not exported: " + err, BAD)
		else:
			_say("Exported %s  (%s)" % [p.get_file(), Mod.summary(creation())], GOOD)
	_recapture.call_deferred()


func _on_copy_code() -> void:
	var code := export_code()
	if code != "":
		DisplayServer.clipboard_set(code)
		_say("Code copied (%d characters, %s): paste it anywhere" % [code.length(), Mod.summary(creation())], GOOD)


func _on_paste_code() -> void:
	_import_report(import_text(DisplayServer.clipboard_get()))


func _import_report(err: String) -> void:
	if err != "":
		_say("Not imported: " + err, BAD)
	else:
		_say("Imported (%s). Nothing is written until you save; %s undoes it" % [Mod.summary(creation()), _k(KEY_Z)], GOOD)


# ---- changes (each undoable)
func _push(op: Dictionary) -> void:
	undo.append(op)
	if undo.size() > UNDO_MAX:
		undo.pop_front()
	dirty = true


func _undo() -> void:
	_drop()
	if undo.is_empty():
		notify("Nothing to undo", HOT)
		return
	var op: Dictionary = undo.pop_back()
	match op["op"]:
		"spawn":
			var i := _index(int(op["uid"]))
			if i >= 0:
				var r: PackedByteArray = recs[i]
				_remove(int(op["uid"]), false)
				notify("Undone: spawned " + viewer.data.type_name(r[0], r[1]))
		"remove":
			var r: PackedByteArray = op["rec"]
			_insert(r, int(op["uid"]), int(op["o"]), op["src"], int(op["at"]))   # (the very record, where it was)
			notify("Undone: removed " + viewer.data.type_name(r[0], r[1]))
		"rec":
			var i := _index(int(op["uid"]))
			if i >= 0:
				_set_rec(i, op["rec"])
				notify("Undone: %s of %s" % [PROP_NAMES.get(str(op.get("tag", "")), "a property"), viewer.data.type_name(recs[i][0], recs[i][1])])
		"state":
			_restore(op["st"])
			notify("Undone: " + str(op.get("what", "the change")))
		"move":
			var t: Dictionary = op["t"]
			_set_raw(t, op["raw"])
			if t["kind"] == "unit":
				_set_heading(int(t["uid"]), int(op["h"]))
			notify("Undone: moved " + _describe(t).get_slice("\n", 0))
		"turn":
			_set_heading(int(op["uid"]), int(op["h"]))
			notify("Undone: turned")
		"group":
			_set_group(int(op["uid"]), int(op["g"]))
			notify("Undone: group change")
	dirty = true


# a copy of record `from` at g, facing h, in group, after the others; source: the game's record it starts from
# ({"f": mission file, "i": record}); returns its uid
func _add_rec(from: PackedByteArray, g: Vector2, h: int, group: int, source: Dictionary) -> int:
	var r := from.duplicate()
	r[7] = clampi(group, 0, MAX_GROUP)
	r.encode_s32(8, int(round(g.x * 65536.0)))
	r.encode_s32(12, int(round(g.y * 65536.0)))
	r.encode_s32(16, 0)
	r.encode_u16(20, h & 0xFFFF)
	var uid := next_uid
	next_uid += 1
	_insert(r, uid, -1, source.duplicate(), -1)
	return uid


# record r in the list at `at` (-1: at the end), as the original's unit `o` (-1: an added one), drawn
func _insert(r: PackedByteArray, uid: int, o: int, source: Dictionary, at: int) -> void:
	if at < 0 or at > recs.size():
		at = recs.size()
	recs.insert(at, r.duplicate())
	uids.insert(at, uid)
	origin.insert(at, o)
	src.insert(at, source)
	_renumber()
	var n := _make_node(recs[at])
	_new_names(n)
	nodes.insert(at, n)
	dirty = true


# a record replaced (a property changed, or its undo): drawn again
func _set_rec(i: int, r: PackedByteArray) -> void:
	recs[i] = r.duplicate()
	var old = nodes[i]
	if old != null and is_instance_valid(old):
		old.queue_free()
	var n := _make_node(recs[i])
	_new_names(n)
	nodes[i] = n
	dirty = true


# one field of a unit changed in the properties panel: one undo step for a field changed in a row (a slider)
func _edit_rec(uid: int, r: PackedByteArray, tag: String) -> void:
	var i := _index(uid)
	if i < 0 or r.size() != REC or recs[i] == r:
		return
	if r[7] > MAX_GROUP:
		return
	var now := Time.get_ticks_msec()
	var last: Dictionary = undo.back() if not undo.is_empty() else {}
	if last.get("op", "") == "rec" and int(last.get("uid", -1)) == uid and str(last.get("tag", "")) == tag \
			and now - int(last.get("t", 0)) < 1500:
		last["t"] = now
	else:
		_push({"op": "rec", "uid": uid, "rec": recs[i].duplicate(), "tag": tag, "t": now})
	var keep := r.duplicate()
	keep.encode_u16(2, recs[i].decode_u16(2))       # (its numbers are the editor's)
	keep.encode_u16(4, recs[i].decode_u16(4))
	_set_rec(i, keep)


# a record's node in the viewer's world, as the viewer makes them when it loads the mission (tn_data.load_mission)
func _make_node(r: PackedByteArray) -> Node3D:
	var g: int = r[7]
	var side: int = sides[g] if g < sides.size() else 2
	var n: Node3D = viewer._add_object(viewer.current["map"], r[0], r[1], r.decode_s32(8) / 65536.0,
		r.decode_s32(12) / 65536.0, r.decode_u16(20) / 65536.0 * TAU, groups[g] if g < groups.size() else "", true,
		r.decode_s32(16) / 65536.0, 1 if side == 1 else 2, r.decode_s16(22) / 65536.0 * TAU,
		(1 if r[0x1B] != 0 else 0) if r[0] == 0 else 0)
	n.set_meta("mission", true)
	return n


func _remove(uid: int, push := true) -> void:
	var i := _index(uid)
	if i < 0:
		return
	var r: PackedByteArray = recs[i]
	var own := not _is_added(i)
	var warn := _script_use(i, true) if push and own else ""
	var n = nodes[i]
	if n != null and is_instance_valid(n):         # (Garry's Mod's remover: it shrinks away)
		var tw: Tween = n.create_tween()
		tw.tween_property(n, "scale", Vector3(0.01, 0.01, 0.01), 0.15)
		tw.tween_callback(n.queue_free)
	var op := {"op": "remove", "rec": r, "uid": uid, "at": i, "o": int(origin[i]), "src": src[i]}
	recs.remove_at(i)
	nodes.remove_at(i)
	uids.remove_at(i)
	origin.remove_at(i)
	src.remove_at(i)
	_renumber()
	if aim.get("uid", -1) == uid:
		aim = {}
	if held.get("uid", -1) == uid:
		held = {}
	if push:
		_push(op)
		notify("Removed %s%s" % [viewer.data.type_name(r[0], r[1]), "  (the mission's own: %s brings it back)" % _k(KEY_Z) if own else ""])
		if warn != "":
			notify(warn, HOT)
	dirty = true


func _renumber() -> void:
	Mod.renumber(orig_recs, recs, origin)            # (the added units: the next numbers, tidy)


func _get_raw(t: Dictionary) -> Array:
	if t["kind"] == "unit":
		var r: PackedByteArray = recs[_index(int(t["uid"]))]
		return [r.decode_s32(8), r.decode_s32(12)]
	var zi := int(t["i"])
	return [zones.decode_s32(8 * zi), zones.decode_s32(8 * zi + 4)]


func _get_pos(t: Dictionary) -> Vector2:
	var raw := _get_raw(t)
	return Vector2(raw[0] / 65536.0, raw[1] / 65536.0)


func _set_pos(t: Dictionary, g: Vector2) -> void:
	_set_raw(t, [int(round(g.x * 65536.0)), int(round(g.y * 65536.0))])


# the file's own 16.16 values (an undo puts back exactly what was there)
func _set_raw(t: Dictionary, raw: Array) -> void:
	var g := Vector2(raw[0] / 65536.0, raw[1] / 65536.0)
	var ground := TNData.height_at(viewer.current["map"], g.x, g.y)
	if t["kind"] == "unit":
		var i := _index(int(t["uid"]))
		if i < 0:
			return
		var r: PackedByteArray = recs[i]
		r.encode_s32(8, int(raw[0]))
		r.encode_s32(12, int(raw[1]))
		recs[i] = r
		var n = nodes[i]
		if n != null and is_instance_valid(n):
			n.position = Vector3(g.x, ground + float(n.get_meta("lift", 0.0)), g.y)
	else:
		var zi := int(t["i"])
		zones.encode_s32(8 * zi, int(raw[0]))
		zones.encode_s32(8 * zi + 4, int(raw[1]))
		var zn = viewer.zone_nodes.get(zi)
		if zn != null and is_instance_valid(zn):
			zn.position = Vector3(g.x, ground + 3.0, g.y)
	dirty = true


func _set_heading(uid: int, h: int) -> void:
	var i := _index(uid)
	if i < 0:
		return
	var r: PackedByteArray = recs[i]
	r.encode_u16(20, h & 0xFFFF)
	recs[i] = r
	var n = nodes[i]
	if n != null and is_instance_valid(n):
		n.rotation.y = -(h & 0xFFFF) / 65536.0 * TAU
	dirty = true


func _turn(uid: int, deg: float) -> void:
	var i := _index(uid)
	if i < 0:
		return
	var h: int = recs[i].decode_u16(20)
	if held.is_empty():
		_push({"op": "turn", "uid": uid, "h": h})
	_set_heading(uid, h + int(round(deg / 360.0 * 65536.0)))


func _set_group(uid: int, g: int) -> void:
	var i := _index(uid)
	if i < 0:
		return
	var r: PackedByteArray = recs[i].duplicate()
	r[7] = clampi(g, 0, MAX_GROUP)
	_set_rec(i, r)                                   # (drawn again: the group gives its side, the side its colours)


func _regroup(uid: int, g: int) -> void:
	var i := _index(uid)
	if i < 0 or recs[i][7] == g:
		return
	_push({"op": "group", "uid": uid, "g": recs[i][7]})
	_set_group(uid, g)
	notify("%s → %s" % [viewer.data.type_name(recs[i][0], recs[i][1]), _group_text(g)])


# ---- the physgun
# where the hold puts the unit for the aim now (before its offset): along the aim at the held distance, or the
# ground the aim meets before (until the wheel was used: from then on along the aim, past that ground)
func _hold_point() -> Vector2:
	var cam: Camera3D = viewer.camera
	var o := cam.global_position
	var d := -cam.global_transform.basis.z
	var dist := float(held["dist"])
	var p := o + d * dist
	if not held.get("wheel", false):
		var hit := _ray_ground(o, d)
		if hit >= 0.0 and hit < dist:
			p = o + d * hit
	return Vector2(p.x, p.z)


func _grab(t: Dictionary, crosshair_mode: bool) -> void:
	_drop()                                          # (a grab left over keeps its own undo)
	var n := _node_of(t)
	if n == null:
		return
	held = t.duplicate()
	held["crosshair"] = crosshair_mode
	held["dist"] = clampf(viewer.camera.global_position.distance_to(n.global_position), HOLD_MIN, HOLD_MAX)
	held["from_raw"] = _get_raw(t)
	held["from_h"] = recs[_index(int(t["uid"]))].decode_u16(20) if t["kind"] == "unit" else 0
	var at = _hold_point() if crosshair_mode else _ground_at(get_viewport().get_mouse_position())
	held["off"] = _get_pos(t) - at if at != null else Vector2.ZERO   # (it stays put until the aim moves)
	rotating = false


func _hold_update() -> void:
	if _node_of(held) == null:
		held = {}
		return
	if rotating and not held.get("crosshair", false):
		var here = _ground_at(get_viewport().get_mouse_position())   # turning in cursor mode: it stays where it is,
		if here != null:                                             # and stays there once E is up
			held["off"] = _get_pos(held) - here
		return
	var at = _hold_point() if held.get("crosshair", false) else _ground_at(get_viewport().get_mouse_position())
	if at == null:
		return
	var g: Vector2 = at + held.get("off", Vector2.ZERO)
	g = Vector2(clampf(g.x, 2.0, 510.0), clampf(g.y, 2.0, 510.0))
	if g.distance_to(_get_pos(held)) > 0.001:
		_set_pos(held, g)


func _rotate_by(dx: float) -> void:
	rot_acc += dx * 0.006
	var step := rot_acc
	if Input.is_key_pressed(KEY_SHIFT):
		step = snappedf(rot_acc, deg_to_rad(15.0))
	_set_heading(int(held["uid"]), int(held.get("rot_base", 0)) + int(round(step / TAU * 65536.0)))


func _drop() -> void:
	if held.is_empty():
		return
	var t := {"kind": held["kind"]}
	if held["kind"] == "unit":
		t["uid"] = held["uid"]
	else:
		t["i"] = held["i"]
	if _node_of(t) != null:
		var h: int = recs[_index(int(t["uid"]))].decode_u16(20) if t["kind"] == "unit" else 0
		if _get_raw(t) != held["from_raw"] or h != int(held["from_h"]):
			_push({"op": "move", "t": t, "raw": held["from_raw"], "h": held["from_h"]})
			if t["kind"] == "unit":                  # (drawn again where it is now: a vehicle lies on its slope)
				_set_rec(_index(int(t["uid"])), recs[_index(int(t["uid"]))])
	held = {}
	rotating = false


# ---- notices
func notify(text: String, col: Color = Color(0.9, 0.95, 1.0)) -> void:
	var p := PanelContainer.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", Menu._box(Color(0.06, 0.07, 0.09, 0.88), col.darkened(0.2), 1, 6, 8))
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 15)
	l.add_theme_color_override("font_color", col)
	p.add_child(l)
	p.set_meta("t", Time.get_ticks_msec())
	notes.add_child(p)
	while notes.get_child_count() > 6:
		var old := notes.get_child(0)
		notes.remove_child(old)
		old.queue_free()


func _fade_notes() -> void:
	var now := Time.get_ticks_msec()
	for p in notes.get_children():
		var age: int = now - int(p.get_meta("t", now))
		if age > NOTE_MS + 600:
			p.queue_free()
		elif age > NOTE_MS:
			p.modulate.a = 1.0 - (age - NOTE_MS) / 600.0


# ---- the file
func save() -> void:
	if lg == null:
		return
	_drop()
	if not _whole(lg):
		notify("Not saved: %s is damaged (no units or zones in it): Revert puts the original back" % path.get_file(), BAD)
		return
	for r in recs:
		if r.size() != REC or r[7] > MAX_GROUP:
			notify("Not saved: a unit is in group %d, the game has groups 0 to %d" % [r[7], MAX_GROUP], BAD)
			return
	var mod := creation()                            # (before anything is written: what the note beside it will say)
	var bak := path + BACKUP
	if not adopted:                                  # none yet, or not this file's (the file was made anew since)
		if FileAccess.file_exists(bak):              # an original of another file: kept aside, never overwritten
			var old := bak + ".old"
			if FileAccess.file_exists(old):
				old = "%s.%d.old" % [bak, Time.get_unix_time_from_system()]
			if DirAccess.rename_absolute(bak, old) != OK:
				notify("Not saved: %s is another file's original and could not be put aside" % bak.get_file(), BAD)
				return
			notify("%s did not match this file: kept as %s" % [bak.get_file(), old.get_file()], HOT)
		var err := _copy_checked(path, bak)
		if err != "":
			notify("Not saved: could not keep the original (%s)" % err, BAD)
			return
		adopted = true
	if not lg.set_data(173, LGRes.compose(recs)) or not lg.set_data(176, zones.duplicate()):
		notify("Not saved: %s has no units or zones resource" % path.get_file(), BAD)
		return
	var e: String = lg.save(path)
	if e != "":
		notify("Not saved: " + e, BAD)
		return
	dirty = false
	menu.set_file(path.get_file(), dirty)
	var noted := false
	if not mod.has("error"):                         # the changes beside it: the next session's memory
		mod["saved"] = Mod.base_sum(recs, zones)
		var f := FileAccess.open(path + EDIT, FileAccess.WRITE)
		if f != null:
			f.store_string(Mod.to_json(mod))
			f.close()
			noted = true
	if not noted:
		DirAccess.remove_absolute(path + EDIT)       # (a stale one would not match the file anyway)
	notify("Saved %s  (the original: %s)" % [path.get_file(), bak.get_file()], GOOD)


# a copy written beside, checked byte for byte, then put in place; "" or what went wrong
func _copy_checked(from: String, to: String) -> String:
	var want := FileAccess.get_file_as_bytes(from)
	if want.is_empty():
		return "%s could not be read" % from.get_file()
	var tmp := to + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "%s could not be written" % tmp.get_file()
	f.store_buffer(want)
	f.close()
	if FileAccess.get_file_as_bytes(tmp) != want:
		DirAccess.remove_absolute(tmp)
		return "%s was not written whole" % tmp.get_file()
	if DirAccess.copy_absolute(tmp, to) != OK or FileAccess.get_file_as_bytes(to) != want:
		return "%s could not be written (a good copy is in %s)" % [to.get_file(), tmp.get_file()]
	DirAccess.remove_absolute(tmp)
	return ""


func _revert() -> void:
	var bak := path + BACKUP
	var b = LGRes.open(bak)
	if not _whole(b):
		notify("Not reverted: %s can't be read whole" % bak.get_file(), BAD)
		return
	var cur = LGRes.open(path)                       # (a damaged file: the original goes back whatever it is)
	if _whole(cur) and not (adopted and _same_but_units(b, cur)):
		notify("Not reverted: %s is not this file's original (the file was made anew since); both kept" % bak.get_file(), BAD)
		return
	var err := _copy_checked(bak, path)
	if err != "":
		notify("Not reverted: %s; the original is still in %s" % [err, bak.get_file()], BAD)
		return
	DirAccess.remove_absolute(bak)
	DirAccess.remove_absolute(path + EDIT)
	_close_menu()
	dirty = false
	notify("Original mission back: " + path.get_file(), GOOD)
	viewer._load_by_label(path.get_file())
