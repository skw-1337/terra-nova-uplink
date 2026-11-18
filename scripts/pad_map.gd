# The gamepad, as the player set it (the Controls pages, launcher and in-game: data/controls.txt's sixth column,
# viewer.cfg [gamepad], scripts/controls.gd), in every live window that plays: solo, host and co-op guest. (The game's
# own DOS joystick, through DOSBox, gets nothing while Uplink is in front: SDL gives a window behind no pad.)
# - The sticks: one moves, one looks; the dead zone, the look's speed, up / down inverted, the two swapped, as set.
#   A co-op guest's go to the host as his gamepad (coop_net.gd 'P' packets: his suit moves as far as the stick goes).
#   Solo and host: the move stick presses the move keys (forward, back, the side steps: the game's controls are
#   keys), the look stick moves as the mouse does (turn, look up / down, or the game's cursor).
# - A button (or a trigger, or a stick pushed far, past the threshold) on one of the game's commands presses that
#   command's key as he has it (his own keys: his window turns them as for the keyboard), with its Shift / Ctrl / Alt;
#   on Uplink's keys, theirs (a guest's menu: Esc; the order wheel: its mouse button). The pad's own commands: a guest's
#   go in the 'P' packets' bits (fire, lock, a jump where the left stick points); solo and host: fire = the left mouse
#   button, lock = Next target, the jump = the jump jets.
# Nothing while the menu is open (its Controls page takes a pad's input for a new binding), except the menu's own button.
extends Node

const Controls := preload("res://scripts/controls.gd")
const STICK_PUSH := 0.6                  # a stick direction bound as a button: pushed that far
const OWN := {"p_fire": 1, "p_jumpto": 2, "p_lock": 4}
const LOOK_PX := 1200.0                  # solo / host: the look stick fully over, mouse pixels a second (speed 1)
const MOVE_PUSH := 0.5                   # solo / host: the move stick past this presses a move key
const HOST_OWN := {"p_lock": "tnext", "p_jumpto": "jump"}

var v: Node
var model: Controls
var binds := {}                          # input ("B3", "A5+") -> command id
var down := {}                           # input -> true while held
var bits := 0                            # the pad's own commands held (OWN)
var keys_held := {}                      # input -> [the Godot keys pressed for it, in order]
var mods_down := {}                      # Shift / Ctrl / Alt pressed by the pad
var log_to: FileAccess                   # tests (TN_PAD_LOG): what the pad did
var guest := false
var move_held := {}                      # solo / host: move command id -> true while its key is down
var look_acc := Vector2.ZERO


func _ready() -> void:
	v = get_parent()
	guest = bool(v.get("guest_win"))
	reload()
	var lf := OS.get_environment("TN_PAD_LOG")
	if lf != "":
		log_to = FileAccess.open(lf, FileAccess.WRITE)


# the bindings and the sticks' settings again (the in-game Controls page: at once)
func reload(m: Controls = null) -> void:
	_release_all()
	model = m if m != null else Controls.new()
	binds = {}
	for c in model.cmds:
		if model.pad_ok(c) and str(c["pad"]) != "":
			binds[str(c["pad"])] = str(c["id"])


func _log(s: String) -> void:
	if log_to:
		log_to.store_line("%d %s" % [Time.get_ticks_msec(), s])
		log_to.flush()


func _menu() -> Node:
	return v.get("uplink_menu") if v else null


func _input(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton or event is InputEventJoypadMotion) or OS.get_environment("TN_NO_PAD") == "1":
		return
	var m := _menu()
	if m and (not (m.get("capture") as Dictionary).is_empty() or int(m.get("pad_frame")) == Engine.get_process_frames()):
		return                                         # (a new binding being asked for, or just taken: the menu's)
	if event is InputEventJoypadButton:
		_press("B%d" % event.button_index, event.pressed)
	else:
		var a: int = event.axis
		var x: float = event.axis_value
		var th: float = float(model.sticks["trigger"]) if a >= 4 else STICK_PUSH
		_press("A%d+" % a, x > th)
		if a < 4:
			_press("A%d-" % a, x < -th)


func _press(input: String, on: bool) -> void:
	if bool(down.get(input, false)) == on:
		return
	down[input] = on
	var id: String = binds.get(input, "")
	if id == "":
		return
	var m := _menu()
	if m and m.is_open() and id != "menu":
		return
	_log("%s %s -> %s" % [input, "down" if on else "up", id])
	if OWN.has(id) and guest:
		bits = (bits | OWN[id]) if on else (bits & ~int(OWN[id]))
		return
	if id == "p_fire":
		_button(MOUSE_BUTTON_LEFT, on)                   # (solo / host: the left button, where the mouse is)
		return
	id = HOST_OWN.get(id, id)
	if on:
		var c := model.find(id)
		var ks := []
		if id == "menu" and guest:
			ks = [KEY_ESCAPE]                            # (a guest's menu: Esc)
		elif not c.is_empty() and int(c["key"][0]) < 0:  # (on a mouse button: the order wheel's)
			var mb: int = {-1: MOUSE_BUTTON_MIDDLE, -2: MOUSE_BUTTON_XBUTTON1, -3: MOUSE_BUTTON_XBUTTON2}.get(int(c["key"][0]), 0)
			if mb:
				_button(mb, true)
				keys_held[input] = [-mb]
			return
		elif not c.is_empty() and int(c["key"][0]) > 0:
			var mods := int(c["key"][1])
			for mk in [[1, KEY_SHIFT], [2, KEY_CTRL], [4, KEY_ALT]]:
				if mods & int(mk[0]):
					ks.append(mk[1])
			var pk: Key = model.physical(int(c["key"][0]))
			if pk == KEY_NONE:
				return
			ks.append(pk)
		keys_held[input] = ks
		for k in ks:
			_key(k, true)
	else:
		var ks: Array = keys_held.get(input, [])
		keys_held.erase(input)
		for i in range(ks.size() - 1, -1, -1):
			if int(ks[i]) < 0:
				_button(-int(ks[i]), false)
			else:
				_key(ks[i], false)


func _key(k: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.physical_keycode = k
	e.keycode = k
	e.pressed = pressed
	if k in [KEY_SHIFT, KEY_CTRL, KEY_ALT]:
		mods_down[k] = pressed
	e.shift_pressed = bool(mods_down.get(KEY_SHIFT, false))
	e.ctrl_pressed = bool(mods_down.get(KEY_CTRL, false))
	e.alt_pressed = bool(mods_down.get(KEY_ALT, false))
	Input.parse_input_event(e)
	_log("key %s %s" % [OS.get_keycode_string(k), "down" if pressed else "up"])


func _button(b: int, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = b
	e.pressed = pressed
	var p := get_viewport().get_mouse_position() if get_viewport() else Vector2.ZERO
	e.position = p
	e.global_position = p
	Input.parse_input_event(e)
	_log("mouse %d %s" % [b, "down" if pressed else "up"])


func _release_all() -> void:
	for input in keys_held.keys():
		var ks: Array = keys_held[input]
		for i in range(ks.size() - 1, -1, -1):
			if int(ks[i]) < 0:
				_button(-int(ks[i]), false)
			else:
				_key(ks[i], false)
	for id in move_held.keys():
		_move_key(id, false)
	move_held = {}
	keys_held = {}
	down = {}
	bits = 0


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_release_all()                                 # (nothing left held while his window is away)


# for coop_net.gd's 'P' packets: [lx, ly, rx, ry] (int8, XInput signs: up = positive) and the own commands' bits
func sticks(dev := 0) -> Array:
	var s: Dictionary = model.sticks
	var mv := [JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y]
	var lk := [JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y]
	if bool(s["swap"]):
		var t := mv
		mv = lk
		lk = t
	var dead := clampf(float(s["dead"]), 0.0, 0.9)
	var inv := -1.0 if bool(s["invert_y"]) else 1.0
	return [_axis(dev, mv[0], 1.0, dead, 1.0), _axis(dev, mv[1], -1.0, dead, 1.0),
			_axis(dev, lk[0], 1.0, dead, float(s["sens_x"])), _axis(dev, lk[1], -inv, dead, float(s["sens_y"]))]


static func _axis(dev: int, a: JoyAxis, sign_: float, dead: float, sens: float) -> int:
	var x := Input.get_joy_axis(dev, a) * sign_
	if absf(x) < dead:
		return 0
	return clampi(roundi(signf(x) * (absf(x) - dead) / (1.0 - dead) * sens * 127.0), -127, 127)


# solo / host: the move stick presses the move keys, the look stick moves as the mouse
func _process(delta: float) -> void:
	if guest or model == null or OS.get_environment("TN_NO_PAD") == "1" or (Input.get_connected_joypads().is_empty() and OS.get_environment("TN_PAD_TEST") == ""):
		return
	var m := _menu()
	if m and m.is_open():
		for id in move_held.keys():
			_move_key(id, false)
		move_held = {}
		look_acc = Vector2.ZERO
		return
	var st := sticks()                                 # (XInput signs: up positive)
	var want := {"fwd": st[1] > MOVE_PUSH * 127, "back": st[1] < -MOVE_PUSH * 127, "sider": st[0] > MOVE_PUSH * 127,
			"sidel": st[0] < -MOVE_PUSH * 127}
	for id in want:
		if bool(want[id]) != bool(move_held.get(id, false)):
			_move_key(id, want[id])
			if want[id]:
				move_held[id] = true
			else:
				move_held.erase(id)
	look_acc += Vector2(st[2], -st[3]) / 127.0 * LOOK_PX * delta
	var mv := Vector2(int(look_acc.x), int(look_acc.y))
	if mv != Vector2.ZERO:
		look_acc -= mv
		var e := InputEventMouseMotion.new()
		e.relative = mv
		e.screen_relative = mv
		var p := get_viewport().get_mouse_position()
		e.position = p
		e.global_position = p
		Input.parse_input_event(e)


func _move_key(id: String, on: bool) -> void:
	var c := model.find(id)
	if c.is_empty() or int(c["key"][0]) <= 0:
		return
	var pk: Key = model.physical(int(c["key"][0]))
	if pk != KEY_NONE:
		_key(pk, on)
