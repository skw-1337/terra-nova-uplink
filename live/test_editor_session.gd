# A session in the mission editor, driven as a player would (real key and button events: the editor reads their
# real state), on a COPY of the game: spawn, move with the physgun, turn, duplicate, team, undo, save, reload,
# revert. Not one of the stable channel's checks (it needs the game's data):
#   set TN_EDITOR_SANDBOX=<a folder holding a copy of TNOVA\DATA and TNOVA\MAPS>     (never the game itself)
#   godot --headless --path . --script res://live/test_editor_session.gd [-- --mission MISS5.RES]
# It refuses to run on a real game folder, and checks before every save that the file is inside the sandbox.
extends SceneTree

const LGRes := preload("res://scripts/lgres.gd")

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
	var saved := _units(file)
	_check(saved.size() == n0 + 1 and PackedByteArray(saved[a]) == ed.recs[a], "the file has the new unit")
	var same := true
	for i in n0:
		same = same and PackedByteArray(saved[i]) == PackedByteArray(_units(file + ".uplink-original")[i])
	_check(same, "the mission's own units are untouched")
	var r0 = LGRes.open(file + ".uplink-original")
	var r1 = LGRes.open(file)
	var others := true
	for rid in r0.order:
		if rid != 173 and rid != 176:
			others = others and r0.data(rid) == r1.data(rid)
	_check(others and r0.order == r1.order, "every other resource of the file is as it was")

	# leave, reload: the added unit is known as an added one
	await _tap(KEY_ESCAPE)
	_check(not ed.active and not viewer.look, "Esc leaves the build mode")
	viewer._load_by_label(file.get_file())
	for i in 600:
		await process_frame
		if ed.lg != null and ed.recs.size() == n0 + 1 and ed.nodes.size() == n0 + 1 and not viewer.current.is_empty() \
				and is_instance_valid(ed.nodes[0]):
			break
	await _frames(5)
	_check(ed.recs.size() == n0 + 1 and not ed.dirty, "reloaded: %d units" % ed.recs.size())
	_check(ed._is_added(a) and not ed._is_added(0), "the unit added before is still known as an added one")

	# revert: the original back
	if not _safe():
		_end()
		return
	ed.confirm.confirmed.emit()
	for i in 600:
		await process_frame
		if ed.lg != null and ed.recs.size() == n0 and not viewer.current.is_empty():
			break
	await _frames(5)
	_check(FileAccess.get_file_as_bytes(file) == pristine, "Revert: the mission file is the original again, byte for byte")
	_check(not FileAccess.file_exists(file + ".uplink-original"), "and the kept original is gone")
	_check(ed.recs.size() == n0, "the editor shows the original's %d units" % n0)
	_end()


func _end() -> void:
	print("%d / %d checks passed" % [checks - fails, checks])
	quit(1 if fails else 0)
