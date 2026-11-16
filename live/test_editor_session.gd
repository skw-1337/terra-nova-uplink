# A session in the mission editor, driven as a player would (real key and button events: the editor reads their
# real state), on a COPY of the game: spawn, move with the physgun, turn, duplicate, team, undo, the properties
# panel, one of the mission's own units removed, the creation exported (code and file), save, reload, revert,
# import on the fresh original. Not one of the stable channel's checks (it needs the game's data):
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
	_check(not ed.props.visible and viewer.look, "P closes it, the mouse looks around again")

	# the remover takes the mission's own units too; undo puts one back where it was
	var victim := -1
	for i in n0:
		if ed.recs[i][0] == 1 and ed.recs[i][26] == 0:
			victim = i
			break
	var vuid: int = ed.uids[victim]
	var vrec: PackedByteArray = ed.recs[victim].duplicate()
	var heads := []
	for i in ed.recs.size():
		heads.append(ed.recs[i].slice(0, 6))
	await _tap(KEY_2)
	await _look_at_ground(_pos(victim))
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
