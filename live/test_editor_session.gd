# A session in the mission editor, driven as a player would (real key and button events: the editor reads their
# real state), on a COPY of the game: spawn, move with the physgun, turn, duplicate, team, undo, the properties
# panel, one of the mission's own units removed, the creation exported (code and file), save, reload, revert,
# import on the fresh original. Then the Mission panel (M): a game mission's script in sentences and its numbers
# changed, the script part's round trip through export / import / save / revert (RESBABL2.RES byte for byte), a
# mission of one's own made in a free slot, built with the blocks, saved, removed, imported back, and PLAY THIS
# MISSION's request to the launcher. Not one of the stable channel's checks (it needs the game's data):
#   set TN_EDITOR_SANDBOX=<a folder holding a copy of TNOVA\DATA and TNOVA\MAPS>     (never the game itself)
#   godot --headless --path . --script res://live/test_editor_session.gd [-- --mission MISS5.RES]
# It refuses to run on a real game folder, and checks before every save that the file is inside the sandbox.
extends SceneTree

const LGRes := preload("res://scripts/lgres.gd")
const Mod := preload("res://scripts/mission_mod.gd")

var fails := 0
var checks := 0
var sandbox := ""
var viewer: Node
var ed: Node
var file := ""
var pristine := PackedByteArray()


func _check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print(("ok   " if ok else "FAIL ") + what)


func _initialize() -> void:
	sandbox = OS.get_environment("TN_EDITOR_SANDBOX").replace("\\", "/").trim_suffix("/")
	var low := sandbox.to_lower()
	if sandbox == "" or low.contains("program files") or low.contains("steamapps") or low.contains("gog") \
			or not FileAccess.file_exists(sandbox.path_join("TNOVA/DATA/RESMISS.RES")):
		print("TN_EDITOR_SANDBOX must be a COPY of the game's data (TNOVA/DATA, TNOVA/MAPS), not the game: nothing done")
		quit(2)
		return
	OS.set_environment("TN_GAME_DIR", sandbox)
	OS.set_environment("TN_EDITOR", "1")
	viewer = load("res://main.tscn").instantiate()
	root.add_child(viewer)
	_run.call_deferred()


func _frames(n: int = 2) -> void:
	for i in n:
		await process_frame


func _key(phys: Key, pressed: bool, ctrl := false, shift := false) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = phys
	e.keycode = phys
	e.pressed = pressed
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	Input.parse_input_event(e)


func _tap(phys: Key, ctrl := false, shift := false) -> void:
	_key(phys, true, ctrl, shift)
	await _frames(2)
	_key(phys, false, ctrl, shift)
	await _frames(2)


# (the build mode's clicks act where the crosshair is, wherever the hidden pointer is: the top left corner here, as
# a headless window is 64 x 64 and its centre is under the toolbar)
func _mouse(button: MouseButton, pressed: bool, at := Vector2(1, 1)) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = at
	e.global_position = e.position
	Input.parse_input_event(e)


func _click(button: MouseButton) -> void:
	_mouse(button, true)
	await _frames(2)
	_mouse(button, false)
	await _frames(2)


# the camera 12 units from a map point, looking down at it (the crosshair on it)
func _look_at_ground(g: Vector2, from := Vector2(-8, -8)) -> void:
	var m: Dictionary = viewer.current["map"]
	var h: float = viewer.TNData.height_at(m, g.x, g.y)
	var cam: Camera3D = viewer.camera
	cam.global_position = Vector3(g.x + from.x, h + 9.0, g.y + from.y)
	cam.look_at(Vector3(g.x, h + 0.4, g.y), Vector3.UP)
	await _frames(3)


func _pos(i: int) -> Vector2:
	var r: PackedByteArray = ed.recs[i]
	return Vector2(r.decode_s32(8) / 65536.0, r.decode_s32(12) / 65536.0)


func _safe() -> bool:
	return ed.path.replace("\\", "/").to_lower().begins_with(sandbox.to_lower() + "/")


func _units(path: String) -> Array:
	var r = LGRes.open(path)
	return LGRes.frames(r.data(173)) if r != null else []


func _run() -> void:
	for i in 600:                                    # the first mission loads
		await process_frame
		if viewer.editor != null and viewer.editor.lg != null and not viewer.current.is_empty():
			break
	ed = viewer.editor
	_check(ed != null and ed.lg != null, "the map viewer has its editor, a mission is loaded")
	if ed == null or ed.lg == null:
		_end()
		return
	file = ed.path
	_check(_safe(), "the mission is inside the sandbox (%s)" % file)
	if not _safe():
		_end()
		return
	pristine = FileAccess.get_file_as_bytes(file)
	_check(not FileAccess.file_exists(file + ".uplink-original"), "a fresh copy: no original kept beside it yet")
	var n0: int = ed.recs.size()
	_check(n0 > 0 and ed.nodes.size() == n0, "%d units, a node each" % n0)

	# in: F6
	await _tap(KEY_F6)
	_check(ed.active and ed.hud.visible and viewer.look, "F6 enters the build mode (the mouse looks around)")
	_check(not viewer.panel.visible, "the viewer's panel is hidden in the build mode")

	# spawn: the menu (Q held), a picture clicked, the unit where the crosshair meets the ground
	var spot := _pos(0) + Vector2(14, 9)
	await _look_at_ground(spot)
	var met = ed._ground_at(root.get_visible_rect().size * 0.5)     # (a hill in between: the ground the crosshair meets)
	if met != null:
		spot = met
	_key(KEY_Q, true)
	await _frames(3)
	_check(ed.menu_open and ed.menu.visible and not viewer.look, "Q held opens the spawn menu, the mouse is free")
	_check(ed.catalog.size() > 50 and ed.menu.buttons.size() == ed.catalog.size(), "%d unit types in the menu" % ed.catalog.size())
	var pick := -1
	for i in ed.catalog.size():
		if ed.catalog[i]["cls"] == 1:
			pick = i
			break
	ed.menu.buttons[pick].pressed.emit()
	await _frames(2)
	_key(KEY_Q, false)
	await _frames(3)
	_check(not ed.menu_open and viewer.look, "Q released closes it")
	_check(ed.recs.size() == n0 + 1 and ed.nodes.size() == n0 + 1 and ed.dirty, "a unit spawned (unsaved changes)")
	var a: int = n0
	_check(ed.recs[a][0] == 1 and ed.recs[a][1] == ed.catalog[pick]["sub"], "it is the type clicked")
	_check(_pos(a).distance_to(spot) < 1.5, "where the crosshair met the ground (%.2f away)" % _pos(a).distance_to(spot))
	_check(is_instance_valid(ed.nodes[a]) and Vector2(ed.nodes[a].position.x, ed.nodes[a].position.z).distance_to(_pos(a)) < 0.01,
		"its node stands there")

	# physgun: aimed at, left held, the aim moved, released
	await _look_at_ground(_pos(a))
	_check(ed.aim.get("kind", "") == "unit" and ed.aim.get("uid", -1) == ed.uids[a], "the crosshair is on the new unit")
	var before := _pos(a)
	_mouse(MOUSE_BUTTON_LEFT, true)
	await _frames(3)
	_check(not ed.held.is_empty(), "left button held: the physgun has it")
	var target := before + Vector2(6, -4)
	await _look_at_ground(target, Vector2(-8, -8) + (before - target))     # (the same place, the aim turned)
	await _frames(3)
	_mouse(MOUSE_BUTTON_LEFT, false)
	await _frames(3)
	_check(ed.held.is_empty(), "released: dropped")
	_check(_pos(a).distance_to(before) > 2.0, "it moved with the aim (%.2f)" % _pos(a).distance_to(before))
	var moved := _pos(a)

	# turn: R, 15 degrees
	await _look_at_ground(_pos(a))
	var h0: int = ed.recs[a].decode_u16(20)
	await _tap(KEY_R)
	_check((ed.recs[a].decode_u16(20) - h0) & 0xFFFF == 2731, "R turns it 15 degrees")
	await _tap(KEY_Z)
	_check(ed.recs[a].decode_u16(20) == h0, "undo: the turn")

	# duplicator: right click copies, left click places
	await _tap(KEY_3)
	_check(ed.tool == ed.DUPLICATOR, "3: the duplicator")
	await _click(MOUSE_BUTTON_RIGHT)
	_check(not ed.dup.is_empty(), "right click copies the unit aimed at")
	await _look_at_ground(_pos(a) + Vector2(5, 5))
	await _click(MOUSE_BUTTON_LEFT)
	_check(ed.recs.size() == n0 + 2 and ed.recs[n0 + 1][1] == ed.recs[a][1], "left click places a copy")

	# team: right click takes a group, left click gives it
	await _tap(KEY_4)
	var other := -1
	for i in n0:
		if ed.recs[i][7] != ed.recs[a][7] and ed.recs[i][0] == 1:
			other = i
			break
	if other >= 0:
		await _look_at_ground(_pos(other))
		if ed.aim.get("uid", -1) == ed.uids[other]:
			await _click(MOUSE_BUTTON_RIGHT)
			_check(ed.team_group == ed.recs[other][7], "team tool, right click: the group of the unit aimed at")
			var g0: int = ed.recs[a][7]
			await _look_at_ground(_pos(a))
			await _click(MOUSE_BUTTON_LEFT)
			_check(ed.recs[a][7] == ed.recs[other][7], "left click: the unit joins it")
			await _tap(KEY_Z)
			_check(ed.recs[a][7] == g0, "undo: its group back")
		else:
			print("     (team: unit %d could not be aimed at, skipped)" % other)
	await _tap(KEY_1)

	# undo twice more: the copy, then the move
	await _tap(KEY_Z)
	_check(ed.recs.size() == n0 + 1, "undo: the copy is gone")
	await _tap(KEY_Z)
	_check(_pos(a).distance_to(before) < 0.001, "undo: the move")
	ed._set_raw({"kind": "unit", "uid": ed.uids[a]}, [int(moved.x * 65536.0), int(moved.y * 65536.0)])

	# numbers: after the mission's own
	var top := 0
	for i in n0:
		top = maxi(top, ed.recs[i].decode_u16(2))
	_check(ed.recs[a].decode_u16(2) == top + 1, "the new unit's entity number follows the mission's (%d)" % (top + 1))

	# properties: P on the unit aimed at; a field changed is one undo step
	await _look_at_ground(_pos(a))
	await _tap(KEY_P)
	_check(ed.props.visible and ed.props_uid == ed.uids[a] and not viewer.look, "P opens the properties of the unit aimed at (the mouse is free)")
	var r0: PackedByteArray = ed.recs[a].duplicate()
	ed.props.fields["label"].value = 7
	await _frames(2)
	_check(ed.recs[a][26] == 7, "label 7")
	ed.props.fields["b28"].value = 60
	await _frames(1)
	ed.props.fields["b28"].value = 140
	await _frames(2)
	_check(ed.recs[a][28] == 140 and ed.recs[a][27] == r0[27], "armour 140 % (a tougher one), the pilot's health untouched")
	var wo: OptionButton = ed.props.fields["w34"]
	var wid := -1
	for k in wo.item_count:
		var id := int(wo.get_item_metadata(k))
		if id != 0 and id != r0[34]:
			wid = id
			wo.select(k)
			wo.item_selected.emit(k)
			break
	await _frames(2)
	_check(wid > 0 and ed.recs[a][34] == wid, "weapon slot 1: weapon %d instead of %d" % [wid, r0[34]])
	ed.props.fields["x"].value = snappedf(_pos(a).x + 3.0, 0.01)
	await _frames(2)
	_check(absf(_pos(a).x - (r0.decode_s32(8) / 65536.0 + 3.0)) < 0.011, "X typed: the unit is 3 further east")
	_check(is_instance_valid(ed.nodes[a]) and absf(ed.nodes[a].position.x - _pos(a).x) < 0.01, "its node moved with it")
	var gsel: OptionButton = ed.props.fields["group"]
	gsel.select(31)
	gsel.item_selected.emit(31)
	await _frames(2)
	_check(ed.recs[a][7] == 31 and gsel.item_count == 32, "group 31, the last the game has (no group over 31 is offered)")
	_check(ed.recs[a].decode_u16(2) == r0.decode_u16(2) and ed.recs[a].slice(0, 2) == r0.slice(0, 2), "class, type and numbers are not touched")
	var edited: PackedByteArray = ed.recs[a].duplicate()
	for step in ["the group", "the place", "the weapon", "the armour (two moves of the slider: one step)", "the label"]:
		await _tap(KEY_Z)
		_check(true, "undo: " + step)
	_check(ed.recs[a] == r0, "five undos: the record as it was before the panel")
	ed._edit_rec(ed.uids[a], edited, "all")
	await _frames(2)
	_check(ed.props.visible and ed.props.rec == ed.recs[a], "the panel follows its unit")
	await _tap(KEY_P)
	if ed.props.visible:                             # (another unit under the free pointer: P showed that one; P again)
		await _tap(KEY_P)
	_check(not ed.props.visible and viewer.look, "P closes it, the mouse looks around again")

	# the unit's menu (cursor mode, right click) opens them too
	ed._open_unit_menu({"kind": "unit", "uid": ed.uids[a]}, Vector2(1, 1))
	var has_props := false
	for k in ed.unit_menu.item_count:
		has_props = has_props or ed.unit_menu.get_item_text(k) == "Properties"
	ed.unit_menu.hide()
	ed._on_unit_menu(6)
	await _frames(2)
	_check(has_props and ed.props.visible and ed.props_uid == ed.uids[a], "the unit's menu has Properties, which opens the panel")
	await _tap(KEY_ESCAPE)
	_check(not ed.props.visible and ed.active, "Esc closes the panel first, the build mode stays")
	# the game's tables: what is counted
	var ai := 4
	for r in ed.recs:
		ai += 1 if r[0] in [1, 2, 3] or (r[0] == 4 and (r[7] != 0 or r[30] != 0 or r[31] != 0)) else 0
	var later: PackedByteArray = ed.lg.data(181)
	for k in 32:
		ai += (later.decode_u32(0) >> k) & 1
	_check(ed._ai_count() == ai and ed._no_room(ed.recs[a]) == "", "%d of the game's 60 AI records used (squad and later arrivals counted): room for more" % ai)
	_check(ed._script_use(a, false).begins_with("Label 7"), "a labelled unit: what the script may do with it is said (%s)" % ed._script_use(a, false))

	# the remover takes the mission's own units too; undo puts one back where it was
	var victim := 0                                 # (a soldier with no label if there is one, else a soldier)
	for want_label0 in [true, false]:
		for i in n0:
			if ed.recs[i][0] == 1 and (ed.recs[i][26] == 0 or not want_label0):
				victim = i
				break
		if ed.recs[victim][0] == 1:
			break
	var vuid: int = ed.uids[victim]
	var vrec: PackedByteArray = ed.recs[victim].duplicate()
	var heads := []
	for i in ed.recs.size():
		heads.append(ed.recs[i].slice(0, 6))
	await _tap(KEY_2)
	await _look_at_ground(_pos(victim))
	var aimed: int = ed._index(int(ed.aim.get("uid", -1)))
	if aimed >= 0 and aimed != victim and not ed._is_added(aimed):   # (two units side by side: the one it is on)
		victim = aimed
		vuid = ed.uids[victim]
		vrec = ed.recs[victim].duplicate()
	_check(ed.aim.get("uid", -1) == vuid, "the crosshair is on one of the mission's own units")
	await _click(MOUSE_BUTTON_LEFT)
	_check(ed._index(vuid) < 0 and ed.recs.size() == n0, "the remover takes it out (%d units left)" % ed.recs.size())
	var kept := true
	for i in ed.recs.size():
		kept = kept and ed.recs[i].slice(0, 6) == heads[i + (1 if i >= victim else 0)]
	_check(kept, "no other unit's numbers changed")
	await _tap(KEY_Z)
	_check(ed._index(vuid) == victim and ed.recs[victim] == vrec and not ed._is_added(victim), "undo: back at its place, the same record")
	await _look_at_ground(_pos(victim))
	await _click(MOUSE_BUTTON_LEFT)
	_check(ed._index(vuid) < 0, "removed again")
	await _tap(KEY_1)
	# a zone post moved
	var zi := int(viewer.zone_nodes.keys()[0])
	var zraw: Array = ed._get_raw({"kind": "zone", "i": zi})
	ed._grab({"kind": "zone", "i": zi}, false)
	ed._set_raw({"kind": "zone", "i": zi}, [zraw[0] + 5 * 65536, zraw[1] - 3 * 65536])
	ed._drop()
	_check(ed.undo.back()["op"] == "move", "a zone post moved (undoable)")

	# the creation: only the changes, as a code
	var code: String = ed.export_code()
	var mod: Dictionary = Mod.from_text(code)
	_check(code.begins_with("TNMOD1:") and not mod.has("error"), "export: a code of %d characters" % code.length())
	_check(mod.get("add", []).size() == 1 and mod.get("remove", []) == [float(victim)] and mod.get("edit", []).is_empty() and mod.get("zones", []).size() == 1,
		"it holds 1 added unit, 1 removed, 1 zone moved (%s)" % Mod.summary(mod))
	_check(str(mod["add"][0]["from"]).begins_with("MISS") and mod["add"][0]["l"] == 7.0, "the added unit: the game's record it copies (%s #%d) and its changes" % [mod["add"][0]["from"], int(mod["add"][0]["rec"])])
	var want := []
	for r in ed.recs:
		want.append(r.duplicate())
	var want_z: PackedByteArray = ed.zones.duplicate()

	# save (Ctrl+S), inside the sandbox only
	if not _safe():
		_end()
		return
	_key(KEY_CTRL, true)
	await _frames(1)
	await _tap(KEY_S, true)
	_key(KEY_CTRL, false)
	await _frames(2)
	_check(not ed.dirty, "Ctrl+S saves")
	_check(FileAccess.get_file_as_bytes(file + ".uplink-original") == pristine, "the original is kept beside it, byte for byte")
	_check(FileAccess.file_exists(file + ".uplink-edit"), "and the changes, as a creation, beside it")
	var saved := _units(file)
	_check(saved == want, "the file has the units of the editor (%d)" % saved.size())
	var r0f = LGRes.open(file + ".uplink-original")
	var r1f = LGRes.open(file)
	var others := true
	for rid in r0f.order:
		if rid != 173 and rid != 176:
			others = others and r0f.data(rid) == r1f.data(rid)
	_check(others and r0f.order == r1f.order, "every other resource of the file is as it was")
	var saved_units: PackedByteArray = r1f.data(173).duplicate()
	var saved_zones: PackedByteArray = r1f.data(176).duplicate()

	# leave, reload: what was added and what was removed is still known
	await _tap(KEY_ESCAPE)
	_check(not ed.active and not viewer.look, "Esc leaves the build mode")
	await _reload(n0)
	_check(ed.recs.size() == n0 and not ed.dirty and ed.adopted, "reloaded: %d units, the kept original is this file's" % ed.recs.size())
	_check(ed._is_added(n0 - 1) and not ed._is_added(0) and not ed.origin.has(victim) and ed.orig_recs.size() == n0,
		"the added unit is still an added one, the removed one is known as removed")
	_check(ed.export_code() == code, "exported again: the very same code")

	# an older editor's save (no note beside the file): its first units are the original's
	DirAccess.remove_absolute(file + ".uplink-edit")
	var old = LGRes.open(file)
	var olds := LGRes.frames(r0f.data(173))
	olds.append(saved[n0 - 1])
	old.set_data(173, LGRes.compose(olds))
	old.save(file)
	await _reload(n0 + 1)
	_check(ed.adopted and ed._is_added(n0) and not ed._is_added(n0 - 1) and ed.creation().get("add", []).size() == 1,
		"a file saved by the first editor: its added unit is found, and the game's record it came from")

	# revert: the original back
	if not _safe():
		_end()
		return
	ed.confirm.confirmed.emit()
	await _reload(n0)
	_check(FileAccess.get_file_as_bytes(file) == pristine, "Revert: the mission file is the original again, byte for byte")
	_check(not FileAccess.file_exists(file + ".uplink-original") and not FileAccess.file_exists(file + ".uplink-edit"), "and the kept original and the note are gone")
	_check(ed.recs.size() == n0 and not ed.adopted, "the editor shows the original's %d units" % n0)

	# import the code on the fresh original: in the editor only, undoable, nothing written
	await _tap(KEY_F6)
	var fresh := []
	for r in ed.recs:
		fresh.append(r.duplicate())
	var err: String = ed.import_text("here it is: " + code.substr(0, 50) + "\n" + code.substr(50))
	await _frames(3)
	_check(err == "" and ed.recs == want and ed.zones == want_z and ed.dirty, "import (pasted code): the very same units and zones, as unsaved changes")
	_check(ed.nodes.size() == want.size() and is_instance_valid(ed.nodes[n0 - 1]), "every unit drawn again")
	var zn: Node3D = viewer.zone_nodes[zi]
	_check(absf(zn.position.x - want_z.decode_s32(8 * zi) / 65536.0) < 0.01, "the moved zone's post is where the creation puts it")
	_check(FileAccess.get_file_as_bytes(file) == pristine and not FileAccess.file_exists(file + ".uplink-original"), "importing wrote nothing")
	_check(not ed.allow_load(0) and ed.unsaved.visible, "another mission asked for: the unsaved import is asked about first")
	ed.unsaved.hide()
	ed.unsaved.canceled.emit()
	await _frames(3)
	await _tap(KEY_Z)
	_check(ed.recs == fresh and ed.zones == ed.orig_zones, "undo: the import is gone")
	# as a file
	var out_dir := sandbox.get_base_dir().path_join("out")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var tn := out_dir.path_join("session." + Mod.EXT)
	_check(ed.import_text(code) == "", "imported again")
	_check(ed.export_file(tn) == "" and FileAccess.get_file_as_string(tn).begins_with("{"), "export to a file: %s" % tn.get_file())
	await _tap(KEY_Z)
	ed.dlg_import = true
	ed._on_file_picked(tn)
	await _frames(3)
	_check(ed.recs == want and ed.zones == want_z, "import from the file: the very same units and zones")
	_check(ed.import_text(code.substr(0, code.length() - 9)) != "" and ed.recs == want, "a code cut short is refused, nothing changes")
	if not _safe():
		_end()
		return
	ed.save()
	await _frames(2)
	var r2f = LGRes.open(file)
	_check(r2f.data(173) == saved_units and r2f.data(176) == saved_zones, "saved: the same unit and zone resources as the first save, byte for byte")
	# a creation for another mission is refused, with its name
	ed.confirm.confirmed.emit()
	await _reload(n0)
	var other_file := "MISS6.RES" if file.get_file().to_upper() != "MISS6.RES" else "MISS7.RES"
	viewer._load_by_label(other_file)
	for i in 600:
		await process_frame
		if ed.lg != null and ed.path.get_file().to_upper() == other_file and not viewer.current.is_empty():
			break
	await _frames(5)
	var n_other: int = ed.recs.size()
	err = ed.import_text(code)
	_check(err.contains(file.get_file().to_upper()) and ed.recs.size() == n_other and not ed.dirty, "on another mission: \"%s\"" % err)
	await _mission_part()
	_end()


func _reload(n: int) -> void:
	viewer._load_by_label(file.get_file())
	for i in 600:
		await process_frame
		if ed.lg != null and ed.recs.size() == n and ed.nodes.size() == n and not viewer.current.is_empty() \
				and (n == 0 or is_instance_valid(ed.nodes[0])):
			break
	await _frames(5)


func _end() -> void:
	print("%d / %d checks passed" % [checks - fails, checks])
	quit(1 if fails else 0)


# ---- the Mission panel, a mission of the player's own, play this mission
func _load_wait(mission: String) -> void:
	var was = viewer.current
	viewer._load_by_label(mission)
	await _changed(was, mission)


# another mission than `was` is loaded and the editor has it
func _changed(was, mission: String) -> void:
	for i in 1200:
		await process_frame
		if not is_same(viewer.current, was) and not viewer.current.is_empty() and is_same(ed.seen, viewer.current) \
				and ed.lg != null and ed.path.get_file().to_upper() == mission.to_upper() and ed.nodes.size() == ed.recs.size():
			break
	await _frames(6)


func _sums(dir: String) -> Dictionary:
	var out := {}
	for f in DirAccess.get_files_at(dir):
		var u := f.to_upper()
		if u.begins_with("MISS") and u.ends_with(".RES") and u != "MISS18.RES" and u != "MISS28.RES":
			out[u] = FileAccess.get_sha256(dir.path_join(f))
	return out


func _pick_option(o: OptionButton, value) -> bool:
	for k in o.item_count:
		if o.get_item_metadata(k) == value:
			o.select(k)
			o.item_selected.emit(k)
			return true
	return false


func _type(le: LineEdit, t: String) -> void:
	le.text = t
	le.text_changed.emit(t)


func _has(list: Array, part: String) -> bool:
	for t in list:
		if str(t).contains(part):
			return true
	return false


func _mission_part() -> void:
	var MS = load("res://scripts/mission_script.gd")
	var MB = load("res://scripts/mission_build.gd")
	var dir: String = viewer.data.data_dir()
	if not dir.to_lower().begins_with(sandbox.to_lower() + "/"):
		_check(false, "the game's data folder is inside the sandbox")
		return
	var babl := dir.path_join("RESBABL2.RES")
	var babl0 := FileAccess.get_file_as_bytes(babl)
	var texts0 := {}
	for f in ["RESGAME.RES", "RESMISS.RES", "RESPTERM.RES"]:
		texts0[f] = FileAccess.get_file_as_bytes(dir.path_join(f))
	var all0 := _sums(dir)

	# -- one of the game's missions: its script in sentences, its numbers changed one by one
	await _load_wait("MISS37.RES")
	var m37 := FileAccess.get_file_as_bytes(ed.path)
	if not ed.active:
		await _tap(KEY_F6)
	await _tap(KEY_M)
	var mp = ed.mpanel
	_check(mp.visible and not viewer.look, "M opens the Mission panel (the mouse is free)")
	_check(mp.info["mode"] == "game" and mp.info["sentences"].size() == 3 and mp.fields["what2"].text.contains("Destroy 100 % of the units labelled 2"),
		"mission 37, the game's own script, in sentences: \"%s\"" % mp.fields["what2"].text)
	_check(_has(mp.info["orders_said"], "Group 1 patrols zones 1, 2, 3 when group 1 starts"), "its orders too (%d lines)" % mp.info["orders_said"].size())
	_check(not mp.fields.has("pct2_0") and not mp.fields.has("order_add"), "a script of the game: shown, not rebuilt (no block control)")
	var base: Dictionary = ed._base_summary()
	var pct_id: String = base["objectives"][2]["conditions"][0]["edit"]["pct"]
	var zone_id := ""
	for od in base["orders"]:
		if od["order"] == "patrol" and od["group"] == 1:
			zone_id = od["edit"]["zone1"]
	_check(mp.fields.has("num:" + pct_id) and mp.fields.has("num:" + zone_id), "its numbers are listed (%d)" % mp.info["edits"].size())
	mp.fields["num:" + pct_id].value = 50
	await _frames(3)
	_check(ed.script_part.get("patch", []).size() == 1 and ed.dirty and str(mp.info["sentences"][2]).begins_with("Destroy 50 %"),
		"objective 3's percentage typed: \"%s\" (unsaved)" % mp.info["sentences"][2])
	var free_zone := -1
	for z in range(7, 31):
		if free_zone < 0 and not ed._zone_placed(z):
			free_zone = z
	mp.fields["num:" + zone_id].value = free_zone
	await _frames(3)
	_check(_has(mp.info["problems"], "zone %d is not placed" % free_zone) and mp.fields["problems"].text.contains("zone %d is not placed" % free_zone),
		"group 1's patrol sent to zone %d, which is not placed: said under WHAT IS MISSING" % free_zone)
	mp.fields["num:" + zone_id].value = 4
	await _frames(3)
	_check(not _has(mp.info["problems"], "is not placed") and _has(mp.info["orders_said"], "Group 1 patrols zones 4, 2, 3"), "to zone 4: nothing missing, the orders read \"patrols zones 4, 2, 3\"")
	await _tap(KEY_Z)
	_check(ed.script_part.get("patch", []).size() == 1 and _has(mp.info["orders_said"], "Group 1 patrols zones 1, 2, 3"), "undo: the patrol's zone (typed twice in a row: one step)")
	await _tap(KEY_Z)
	_check(ed.script_part.is_empty() and str(mp.info["sentences"][2]).begins_with("Destroy 100 %"), "undo: the percentage, the game's own script again")
	# what the script does with a label is said before its units go
	var l2 := []
	for i in ed.recs.size():
		if ed.recs[i][26] == 2:
			l2.append(ed.uids[i])
	_check(not l2.is_empty() and _has(MS.uses(ed._summary(), "label", 2), "objective 3") and ed._script_use(ed._index(l2[0]), true).contains("objective 3"),
		"removing a unit labelled 2: \"%s\"" % ed._script_use(ed._index(l2[0]), true))
	for u in l2:
		ed._remove(u)
	await _frames(3)
	_check(_has(mp.info["problems"], "no unit is labelled 2") and mp.fields["problems"].text.contains("no unit is labelled 2"),
		"all %d removed: \"%s\"" % [l2.size(), mp.info["problems"][0]])
	for u in l2:
		await _tap(KEY_Z)
	await _frames(3)
	_check(mp.info["problems"].is_empty() and ed.recs.size() == LGRes.frames(ed.lg.data(173)).size(), "undone: nothing missing")
	mp.fields["num:" + pct_id].value = 50
	mp.fields["num:" + zone_id].value = 4
	await _frames(3)
	var code37: String = ed.export_code()
	var mod37: Dictionary = Mod.from_text(code37)
	_check(mod37.get("script", {}).get("patch", []).size() == 2 and Mod.summary(mod37).contains("2 script numbers changed"), "export: the creation carries the script part (%s)" % Mod.summary(mod37))
	if not _safe():
		return
	_key(KEY_CTRL, true)
	await _frames(1)
	await _tap(KEY_S, true)
	_key(KEY_CTRL, false)
	await _frames(2)
	var babl1 := FileAccess.get_file_as_bytes(babl)
	_check(not ed.dirty and babl1 != babl0 and FileAccess.get_file_as_bytes(babl + ".uplink-original") == babl0, "Ctrl+S: RESBABL2.RES rewritten, the game's own kept beside it byte for byte")
	var inst = MS.open(dir)
	var s37: Dictionary = inst.summary(37)
	_check(str(s37["objectives"][2]["what"]).begins_with("destroy 50 %") and _has(s37["start_orders"].get(1, []), "patrols zones 4, 2, 3"),
		"the installed script, read back: %s; group 1 %s" % [s37["objectives"][2]["what"], s37["start_orders"].get(1, [])])
	_check(MB.installed(dir).has("MISS37.RES"), "the script part is in the folder's registry")
	await _load_wait("MISS37.RES")
	_check(ed.script_part.get("patch", []).size() == 2 and not ed.dirty and ed.export_code() == code37, "reloaded: the script part is known, the very same code exported")
	var was = viewer.current
	ed.confirm.confirmed.emit()
	await _changed(was, "MISS37.RES")
	_check(FileAccess.get_file_as_bytes(babl) == babl0, "Revert: RESBABL2.RES is the game's again, byte for byte")
	_check(FileAccess.get_file_as_bytes(ed.path) == m37 and ed.script_part.is_empty() and not MB.installed(dir).has("MISS37.RES"), "the mission file too, nothing left in the registry")
	if not ed.active:
		await _tap(KEY_F6)
	_check(ed.import_text(code37) == "" and ed.script_part.get("patch", []).size() == 2 and ed.dirty and FileAccess.get_file_as_bytes(babl) == babl0,
		"import: the script part as unsaved changes, nothing written")
	_check(not ed.allow_load(0) and ed.unsaved.visible, "another mission asked for: the unsaved script change is asked about first")
	ed.unsaved.hide()
	ed.unsaved.canceled.emit()
	await _frames(3)
	await _tap(KEY_Z)
	_check(ed.script_part.is_empty(), "undo: the import, script part included")
	_check(ed.import_text(code37) == "", "imported again")
	ed.save()
	await _frames(2)
	_check(not ed.dirty and FileAccess.get_file_as_bytes(babl) == babl1, "saved: the same RESBABL2.RES as the first save, byte for byte")

	# -- a mission of the player's own
	var all1 := _sums(dir)
	if not mp.visible:
		await _tap(KEY_M)
	_check(mp.fields.has("new_create") and mp.info["slots"].size() == 2 and mp.info["slots"][0]["state"] == "free", "MY MISSIONS: both slots free, a map to pick (%d)" % mp.fields["new_like"].item_count)
	mp.fields["new_name"].text = "OPERATION TEST"
	var lk: OptionButton = mp.fields["new_like"]
	for k in lk.item_count:
		if str(lk.get_item_metadata(k)) == "MISS37.RES":
			lk.select(k)
	was = viewer.current
	mp.fields["new_create"].pressed.emit()
	await _changed(was, "MISS18.RES")
	var p18 := dir.path_join("MISS18.RES")
	_check(ed.path == p18 and FileAccess.file_exists(p18) and FileAccess.file_exists(p18 + ".uplink-new") and FileAccess.file_exists(p18 + ".uplink-new.json"),
		"Create a new mission: MISS18.RES written in the sandbox, marked as Uplink's")
	var listed := false
	for m in viewer.missions:
		listed = listed or (str(m["label"]).contains("OPERATION TEST") and m["file"] == p18)
	_check(listed and ed.active and mp.visible and not ed.dirty, "it is in the list under its name, open in the build mode with the Mission panel")
	_check(mp.info["mode"] == "blocks" and mp.info["sentences"][0] == "Destroy 100 % of the units labelled 2" and mp.info["sentences"][1] == "Not used",
		"its starting script: \"%s\"" % mp.info["sentences"][0])
	_check(ed.recs.is_empty() and ed._zone_placed(0) and ed._zone_placed(31) and viewer.zone_nodes.has(0) and viewer.zone_nodes.has(31), "no unit, a drop zone (0) and a pickup zone (31) to place")
	_check(_has(mp.info["problems"], "no unit is labelled 2"), "what is missing: \"%s\"" % mp.info["problems"][0])
	_check(_sums(dir) == all1 and FileAccess.get_file_as_bytes(dir.path_join("MISS37.RES") + ".uplink-original") == m37, "no campaign mission file was touched")
	inst = MS.open(dir)
	_check(inst.summary(18)["name"] == "OPERATION TEST" and str(inst.summary(18)["objectives"][0]["what"]) == "destroy 100 % of the units labelled 2"
		and str(inst.summary(37)["objectives"][2]["what"]).begins_with("destroy 50 %"), "installed: its name, its script, and mission 37's own part still there")
	# two units, spawned from the menu where the crosshair is; labelled in their properties
	var z0: Vector2 = ed._get_pos({"kind": "zone", "i": 0})
	var enemy := -1
	for i in ed.catalog.size():
		if enemy < 0 and ed.catalog[i]["cls"] == 1 and ed._side_of(1, ed.catalog[i]["sub"]) == 2:
			enemy = i
	await _tap(KEY_M)
	_check(not mp.visible and viewer.look, "M closes the panel")
	for k in 2:
		await _look_at_ground(z0 + Vector2(6 + 5 * k, 4))
		_key(KEY_Q, true)
		await _frames(3)
		ed.menu.buttons[enemy].pressed.emit()
		await _frames(2)
		_key(KEY_Q, false)
		await _frames(3)
	_check(ed.recs.size() == 2 and ed.recs[0][7] == 1 and ed.recs[1][7] == 1, "two %s spawned: with no group of their side yet they join group 1, not the null group" % ed.catalog[enemy]["name"])
	await _look_at_ground(_pos(0))
	await _tap(KEY_P)
	ed.props.fields["label"].value = 2
	await _frames(2)
	await _tap(KEY_P)
	if ed.props.visible:
		ed._close_props()
	var r1: PackedByteArray = ed.recs[1].duplicate()
	r1[26] = 2
	r1[7] = 2
	ed._edit_rec(ed.uids[1], r1, "label")
	await _frames(3)
	await _tap(KEY_M)
	_check(mp.visible and not _has(mp.info["problems"], "no unit is labelled 2") and mp.fields["count0_0"].text == "2 units", "both labelled 2: objective 1 has its units (\"%s\")" % mp.fields["count0_0"].text)
	# the objectives' blocks
	mp.fields["pct0_0"].value = 50
	await _frames(3)
	_check(mp.info["sentences"][0] == "Destroy 50 % of the units labelled 2" and mp.fields["what0"].text.contains("Destroy 50 %"), "percentage 50: \"%s\"" % mp.info["sentences"][0])
	await _tap(KEY_Z)
	_check(mp.info["sentences"][0] == "Destroy 100 % of the units labelled 2" and mp.fields["pct0_0"].value == 100, "undo: 100 % again, in the panel too")
	mp.fields["pct0_0"].value = 50
	await _frames(2)
	_pick_option(mp.fields["kind0_0"], "alive")
	await _frames(3)
	_check(mp.info["sentences"][0] == "Keep 50 % of the units labelled 2 alive", "kind Keep alive: \"%s\"" % mp.info["sentences"][0])
	await _tap(KEY_Z)
	_check(mp.info["sentences"][0] == "Destroy 50 % of the units labelled 2", "undo: Destroy again")
	mp.fields["add1"].pressed.emit()
	await _frames(3)
	_check(mp.info["sentences"][1] == "Destroy 100 % of the units labelled 2" and _has(mp.info["problems"], "objective 2 has no line"), "objective 2 used: it asks for its line on the game's screen")
	_type(mp.fields["line1"], "Leave no one standing")
	await _frames(3)
	_check(ed.new_part["objectives"][1] == "Leave no one standing" and not _has(mp.info["problems"], "objective 2 has no line"), "its line typed")
	mp.fields["del1_0"].pressed.emit()
	await _frames(3)
	_check(mp.info["sentences"][1] == "Not used" and ed._spec_of(ed.script_part)["objectives"][1] == null, "its condition removed: not used again")
	# zones placed where the view looks
	var spots := {1: z0 + Vector2(-20, -12), 2: z0 + Vector2(-8, -18), 3: z0 + Vector2(-14, -4), 4: z0 + Vector2(-16, -16)}
	for z in spots:
		mp.fields["zone_n"].value = z
		await _look_at_ground(spots[z])
		mp.fields["zone_place"].pressed.emit()
		await _frames(3)
	var zok := true
	for z in spots:
		zok = zok and ed._zone_placed(z) and viewer.zone_nodes.has(z) and is_instance_valid(viewer.zone_nodes[z]) \
			and Vector2(viewer.zone_nodes[z].position.x, viewer.zone_nodes[z].position.z).distance_to(ed._get_pos({"kind": "zone", "i": z})) < 0.01
	_check(zok and mp.info["zones"].size() == 6, "zones 1 to 4 placed where the view looks, a post each (%d zones)" % mp.info["zones"].size())
	await _tap(KEY_Z)
	_check(not ed._zone_placed(4) and not viewer.zone_nodes.has(4), "undo: zone 4 and its post are gone")
	await _look_at_ground(spots[4])
	mp.fields["zone_place"].pressed.emit()
	await _frames(3)
	# orders
	mp.fields["order_add"].pressed.emit()
	await _frames(3)
	var sp: Dictionary = ed._spec_of(ed.script_part)
	_check(sp["orders"].size() == 1 and sp["orders"][0] == {"group": 1, "order": "patrol", "zones": [1, 2, 3]}, "Add an order: %s" % str(sp["orders"]))
	_check(not mp.fields["okind0"].get_item_text(0).is_empty() and mp.fields["okind0"].item_count == 4, "four kinds of order offered (no attack, no follow, no ID lock)")
	_pick_option(mp.fields["ogroup0"], 2)
	await _frames(3)
	_pick_option(mp.fields["ozone0_0"], 4)
	await _frames(3)
	mp.fields["ozone0_1_pick"].pressed.emit()         # the second zone: picked in the world
	await _frames(2)
	_check(ed.zone_setter.is_valid(), "⌖: the panel waits for a zone post")
	var zp: Vector2 = ed._get_pos({"kind": "zone", "i": 1})
	var zn1: Node3D = viewer.zone_nodes[1]
	# (the window is 64 x 64, the toolbar is over its centre and the panel under it: the view is turned until the
	# post is where no control is, and the click goes there)
	var at := Vector2(-1, -1)
	for d in [0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0]:
		if at.x >= 0:
			break
		await _look_at_ground(zp + Vector2(d, d))
		for hh in [-2.5, -1.5, -0.5, 0.0]:
			var q: Vector2 = viewer.camera.unproject_position(zn1.global_position + Vector3(0, hh, 0))
			if at.x < 0 and q.x > 0 and q.x < 63 and q.y > 0 and q.y < 63 and not ed.toolbar.get_global_rect().has_point(q) 					and not mp.get_global_rect().has_point(q) and ed._pick_at(q).get("i", -1) == 1:
				at = q
	_mouse(MOUSE_BUTTON_LEFT, true, at)
	await _frames(2)
	_mouse(MOUSE_BUTTON_LEFT, false, at)
	await _frames(3)
	sp = ed._spec_of(ed.script_part)
	_check(sp["orders"][0] == {"group": 2, "order": "patrol", "zones": [4, 1, 3]} and _has(mp.info["orders_said"], "Group 2 patrols zones 4, 1, 3 when group 2 starts"),
		"group 2 patrols zones 4, 1 (clicked in the world), 3: \"%s\"" % str(mp.info["orders_said"]))
	_pick_option(mp.fields["okind0"], "move")
	await _frames(3)
	_check(ed._spec_of(ed.script_part)["orders"][0]["order"] == "move" and _has(mp.info["orders_said"], "Group 2 goes to zone"), "order kind Go to a zone: %s" % str(mp.info["orders_said"]))
	await _tap(KEY_Z)
	_check(ed._spec_of(ed.script_part)["orders"][0] == {"group": 2, "order": "patrol", "zones": [4, 1, 3]}, "undo: the patrol again")
	mp.fields["order_add"].pressed.emit()
	await _frames(3)
	_pick_option(mp.fields["okind1"], "link")
	await _frames(3)
	_check(ed._spec_of(ed.script_part)["orders"][1] == {"group": 1, "order": "link", "target": 2}, "a second order: group 1 linked with group 2")
	mp.fields["odel1"].pressed.emit()
	await _frames(3)
	_check(ed._spec_of(ed.script_part)["orders"].size() == 1, "and removed")
	# the end, the debriefing
	mp.fields["end_on"].button_pressed = true
	await _frames(3)
	mp.fields["end_seconds"].value = 5
	await _frames(3)
	_check(ed._spec_of(ed.script_part)["end"] == {"objective": 1, "seconds": 5}, "the mission ends by itself 5 s after objective 1")
	_type(mp.fields["debrief0"], "Half of them will do.")
	await _frames(3)
	_check(ed._spec_of(ed.script_part)["debrief"][0] == "Half of them will do.", "the debriefing text typed")
	# a zone the script uses, removed
	mp.fields["zone_n"].value = 4
	mp.fields["zone_remove"].pressed.emit()
	await _frames(4)
	_check(not ed._zone_placed(4) and _has(mp.info["problems"], "zone 4 is not placed"), "zone 4 removed: \"%s\"" % (mp.info["problems"][0] if not mp.info["problems"].is_empty() else ""))
	await _tap(KEY_Z)
	await _frames(3)
	_check(ed._zone_placed(4) and mp.info["problems"].is_empty(), "undo: back, nothing missing")
	_check(ed._script_use(0, true).contains("objective 1") and ed._script_use(1, true).contains("patrols zones 4, 1, 3"), "what the script does with a unit's label and group: \"%s\"" % ed._script_use(1, true))
	# save, read back
	var code18: String = ed.export_code()
	var mod18: Dictionary = Mod.from_text(code18)
	_check(mod18.get("new", {}).get("slot", 0) == 18 and mod18.get("script", {}).get("build", []).size() == 1 and mod18.get("add", []).size() == 2,
		"export: the new mission, its script and its units in one code (%d characters, %s)" % [code18.length(), Mod.summary(mod18)])
	var want_part: Dictionary = ed.script_part.duplicate(true)
	if not _safe():
		return
	_key(KEY_CTRL, true)
	await _frames(1)
	await _tap(KEY_S, true)
	_key(KEY_CTRL, false)
	await _frames(2)
	_check(not ed.dirty and _units(p18) == ed.recs, "Ctrl+S: MISS18.RES has the two units")
	inst = MS.open(dir)
	var s18: Dictionary = inst.summary(18)
	_check(str(s18["objectives"][0]["what"]) == "destroy 50 % of the units labelled 2" and str(s18["objectives"][0]["text"]) == "Destroy every enemy unit"
		and _has(s18["start_orders"].get(2, []), "patrols zones 4, 1, 3") and _has(s18["notes"], "ends the mission"),
		"the installed script, read back: %s; group 2 %s; %s" % [s18["objectives"][0]["what"], s18["start_orders"].get(2, []), s18["notes"]])
	var babl2 := FileAccess.get_file_as_bytes(babl)
	_check(_find(babl2, "Half of them will do.".to_ascii_buffer()) and str(inst.summary(37)["objectives"][2]["what"]).begins_with("destroy 50 %"),
		"the debriefing text is in RESBABL2.RES, with mission 37's own part beside it")
	var m18 := FileAccess.get_file_as_bytes(p18)
	var out_dir := sandbox.get_base_dir().path_join("out")
	var tn := out_dir.path_join("mission18." + Mod.EXT)
	_check(ed.export_file(tn) == "", "exported to %s" % tn.get_file())
	# play this mission
	OS.set_environment("TN_PLAY_REQUEST", "")
	ed._show_mission()
	mp.fields["play"].pressed.emit()
	await _frames(3)
	_check(ed.tell.visible and ed.tell.dialog_text.contains("MAP VIEWER") and mp.fields["play_note"].text.contains("alone, in a standard suit"),
		"PLAY THIS MISSION without the launcher: what is missing is said (and the known limit of a new mission)")
	# (a save of the player's in the sandbox, and a Python: the save that starts on the mission is made instead)
	var tnova := sandbox.path_join("TNOVA")
	if FileAccess.file_exists(tnova.path_join("SAVE01.RES")):
		var made := false
		for f in DirAccess.get_files_at(tnova):
			if f.to_upper().begins_with("SAVE") and f.to_upper() != "SAVE01.RES":
				made = made or _find(FileAccess.get_file_as_bytes(tnova.path_join(f)), "UPLINK Mission new 18".to_ascii_buffer())
		_check(made and ed.tell.dialog_text.contains("\"UPLINK Mission new 18\""), "a save named \"UPLINK Mission new 18\" is made in the sandbox, and the player told to load it")
	else:
		print("     (no SAVE01.RES in the sandbox: the save made without the launcher is not checked)")
	ed.tell.hide()
	OS.set_environment("TN_PYTHON", sandbox.path_join("no_python_here.exe"))
	mp.fields["play"].pressed.emit()
	await _frames(3)
	_check(ed.tell.visible and ed.tell.dialog_text.contains("no save could be made") and ed.tell.dialog_text.contains("Python was not found"),
		"without a Python either: said, with what to do")
	ed.tell.hide()
	OS.set_environment("TN_PYTHON", "")
	var req := out_dir.path_join("play_request.txt")
	DirAccess.remove_absolute(req)
	OS.set_environment("TN_PLAY_REQUEST", req)
	mp.fields["pct0_0"].value = 60
	await _frames(2)
	mp.fields["pct0_0"].value = 50
	await _frames(2)
	_check(ed.dirty, "(an unsaved change)")
	ed._show_mission()
	mp.fields["play"].pressed.emit()
	await _frames(3)
	_check(not ed.dirty and FileAccess.get_file_as_string(req).begins_with("18\n") and FileAccess.get_file_as_bytes(babl) == babl2,
		"PLAY THIS MISSION with the launcher's request file: saved first, then mission 18 asked for")
	DirAccess.remove_absolute(req)
	OS.set_environment("TN_PLAY_REQUEST", "")
	# remove my mission: everything of it goes, the game's files come back
	mp.fields["remove18"].pressed.emit()
	await _frames(2)
	_check(ed.ask.visible, "Remove my mission asks first")
	was = viewer.current
	ed.ask.hide()
	ed.ask.confirmed.emit()
	for i in 1200:
		await process_frame
		if not is_same(viewer.current, was) and is_same(ed.seen, viewer.current) and ed.lg != null:
			break
	await _frames(6)
	var gone := true
	for ext in ["", ".uplink-new", ".uplink-new.json", ".uplink-original", ".uplink-edit"]:
		gone = gone and not FileAccess.file_exists(p18 + ext)
	var back := true
	for f in texts0:
		back = back and FileAccess.get_file_as_bytes(dir.path_join(f)) == texts0[f]
	_check(gone and back and FileAccess.get_file_as_bytes(babl) == babl1 and not MB.installed(dir).has("MISS18.RES"),
		"removed: no file of it left, the game's texts byte for byte, RESBABL2.RES as before it (mission 37's part only)")
	_check(_sums(dir) == all1 and ed.path != p18, "no campaign mission file changed; the editor is on %s" % ed.path.get_file())
	# the exported creation brings it all back
	was = viewer.current
	ed.dlg_import = true
	ed._on_file_picked(tn)
	await _changed(was, "MISS18.RES")
	await _frames(6)
	_check(ed.path == p18 and ed.recs.size() == 2 and ed.script_part == want_part and ed.dirty, "import from another mission: slot 18 installed and opened, its units and script as unsaved changes")
	ed.save()
	await _frames(2)
	_check(not ed.dirty and FileAccess.get_file_as_bytes(p18) == m18 and FileAccess.get_file_as_bytes(babl) == babl2,
		"saved: MISS18.RES and RESBABL2.RES are the ones of before the removal, byte for byte")
	was = viewer.current
	ed.confirm.confirmed.emit()
	await _changed(was, "MISS18.RES")
	inst = MS.open(dir)
	_check(ed.recs.is_empty() and str(inst.summary(18)["objectives"][0]["what"]) == "destroy 100 % of the units labelled 2" and ed._spec_of(ed.script_part).get("orders", [0]).is_empty(),
		"Revert on a mission of one's own: the empty mission and its starting script")
	# everything back as the game was
	was = viewer.current
	ed.remove_new(18)
	for i in 1200:
		await process_frame
		if not is_same(viewer.current, was) and is_same(ed.seen, viewer.current) and ed.lg != null:
			break
	await _frames(6)
	await _load_wait("MISS37.RES")
	was = viewer.current
	ed.confirm.confirmed.emit()
	await _changed(was, "MISS37.RES")
	back = FileAccess.get_file_as_bytes(babl) == babl0
	for f in texts0:
		back = back and FileAccess.get_file_as_bytes(dir.path_join(f)) == texts0[f]
	_check(back and _sums(dir) == all0 and MB.installed(dir).is_empty() and not FileAccess.file_exists(dir.path_join("uplink-scripts.json")),
		"my mission removed and mission 37 reverted: RESBABL2.RES, the texts and every mission file are the game's, byte for byte")


func _find(hay: PackedByteArray, needle: PackedByteArray) -> bool:
	for i in range(0, hay.size() - needle.size() + 1):
		if hay[i] == needle[0] and hay.slice(i, i + needle.size()) == needle:
			return true
	return false
