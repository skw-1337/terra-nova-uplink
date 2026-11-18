# The co-op guest's shots, decided in his own picture (a child of coop_hud.gd). He sees the host's world late (the
# host's views at their rate, over Steam, then eased here): a walking enemy is drawn where it was a tenth of a second
# or more before. The host's bridge used to cast his view's line against where the units are NOW on the host, so a
# shot that was on a walking enemy in his picture went behind it. Here, while he fires, what his crosshair is on in
# this window is sent with it (the 'F' packet, and the same bytes after his left button's 'B' press):
#   kind 1: a unit, its entity and the point hit on it in its own frame (from its middle at its entity's place, turned
#           by its heading): the bridge aims at that unit where it is now, at that point of it;
#   kind 2: the ground, the point hit (the game's x, y, z): it does not move;
#   kind 0: nothing (the bridge aims along his view at his weapon's range).
# His crosshair's line is his camera's own, looking down past the game's limit included (look_down.gd): the ground
# he sees under it is where his shot lands. Older bridges read only the first 3 bytes of 'B' and skip 'F'.
# TN_COOP_PICK=0: nothing sent (the bridge then casts his view's line itself, coop_aim.py).
# Tests: TN_PICK_TRACE = a file: each frame his camera, his crosshair's line and the drawn place of the entity named
# in <file>.target (the game's coordinates).
extends Node

const TNData = preload("res://scripts/tn_data.gd")

const RATE := 0.033                          # an 'F' at most this often while he fires (s)
const REACH := 150.0                         # units looked along his crosshair's line
const STEP := 0.2                            # the ground: tested every this many units
const KINDS := [1, 2, 3]                     # the classes he can aim at (suits, vehicles, buildings and turrets)

var hud: Node
var on := OS.get_environment("TN_COOP_PICK") != "0"
var sent_t := -1.0
var trace_f: FileAccess
var trace_ent := -1
var trace_t := -1.0


func _vp() -> Node:
	return hud.get_parent() if hud != null else null


# his crosshair's line: from his camera, along his view (the game's head) turned down past its limit as his camera is
func line() -> Array:
	var vp := _vp()
	var ex: float = vp.look_dn.extra if vp.look_dn != null else 0.0
	var b := Basis.from_euler(Vector3(vp.pitch + ex, vp.yaw, 0.0))
	return [vp.camera.global_position, b * Vector3(0.0, 0.0, -1.0)]


# the world box of what is drawn of a unit (its pieces' boxes together)
static func _box(n: Node3D) -> AABB:
	var r := AABB()
	var first := true
	var todo: Array = [n]
	while not todo.is_empty():
		var x = todo.pop_back()
		todo.append_array(x.get_children())
		if x is MeshInstance3D and (x as MeshInstance3D).visible and (x as MeshInstance3D).mesh != null \
				and not (x as Node).has_meta("shadow_twin"):
			var ab: AABB = (x as MeshInstance3D).global_transform * (x as MeshInstance3D).get_aabb()
			if first:
				r = ab
				first = false
			else:
				r = r.merge(ab)
	return r


# what his crosshair is on: 15 bytes (kind, entity, 3 floats)
func pick() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(15)
	var vp := _vp()
	if vp == null or vp.current.is_empty() or not vp.current.has("map") or hud.state != 0:
		return out
	var l := line()
	var eye: Vector3 = l[0]
	var dir: Vector3 = l[1]
	var best_t := REACH
	var best := -1
	var best_n: Node3D = null
	for idx in vp.live_ents:
		var e: Array = vp.live_ents[idx]
		if not int(e[0]) in KINDS or idx == hud.entity or idx == vp.live_player:
			continue
		var n: Node3D = hud._drawn(idx)
		if n == null or n.has_meta("corpse"):
			continue
		var c := n.global_position - eye
		if c.length() > REACH + 5.0 or c.dot(dir) < 0.0:
			continue
		var ab := _box(n)
		if ab.size == Vector3.ZERO:
			continue
		var hit = ab.intersects_ray(eye, dir)
		if hit == null:
			continue
		var t: float = (hit as Vector3 - eye).dot(dir)
		if t > 0.2 and t < best_t:
			best_t = t
			best = idx
			best_n = n
	# the ground, nearer than that unit
	var m: Dictionary = vp.current["map"]
	var t := STEP
	var gt := -1.0
	var prev := 0.0
	while t < best_t:
		var p := eye + dir * t
		if p.y < TNData.height_at(m, p.x, p.z):
			var lo := prev
			var hi := t
			for k in 12:
				var mid := (lo + hi) * 0.5
				var q := eye + dir * mid
				if q.y < TNData.height_at(m, q.x, q.z):
					hi = mid
				else:
					lo = mid
			gt = hi
			break
		prev = t
		t += STEP
	if gt > 0.0:
		var g := eye + dir * gt
		out[0] = 2
		out.encode_float(3, g.x)
		out.encode_float(7, g.z)
		out.encode_float(11, g.y)
		return out
	if best < 0:
		return out
	# the point hit on it, from its entity's place (the game's: drawn y + the class's draw offset), in its own frame
	var e: Array = vp.live_ents[best]
	var hp := eye + dir * best_t
	var at: Vector3 = best_n.global_position
	var f: float = float(e[5]) - float(best_n.get_meta("ez", float(e[5])))   # (its draw offset)
	var dx := hp.x - at.x
	var dy := hp.z - at.z
	var h: float = float(e[6])
	out[0] = 1
	out.encode_u16(1, best)
	out.encode_float(3, dx * cos(h) + dy * sin(h))          # (turned by -heading: its own frame)
	out.encode_float(7, -dx * sin(h) + dy * cos(h))
	out.encode_float(11, hp.y - (at.y + f))
	return out


func _process(_dt: float) -> void:
	var vp := _vp()
	if vp == null or not vp.live:
		return
	if OS.has_environment("TN_PICK_TRACE"):
		_test_look()
		_trace()
		var ff := OS.get_environment("TN_PICK_TRACE") + ".fire"   # (tests: his click, as his left button sends it)
		if FileAccess.file_exists(ff):
			DirAccess.remove_absolute(ff)
			var pk := pick()
			_click_log(pk)
			vp._play_send(PackedByteArray([0x42, 1, 1]) + (pk if on else PackedByteArray()))
			vp.play_buttons[1] = true
			get_tree().create_timer(0.06).timeout.connect(func():
				vp._play_send(PackedByteArray([0x42, 1, 0]))
				vp.play_buttons.erase(1))
	if not on or hud.state != 0 or not vp.play_buttons.has(1):
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - sent_t < RATE:
		return
	sent_t = now
	vp._play_send(PackedByteArray([0x46]) + pick())


# tests: his mouse, as the viewer takes a captured mouse's moves (viewer.gd _input; a hidden test window cannot capture
# the mouse): <TN_PICK_TRACE>.look holds "seq total_dx total_dy" (counts), what is new since the last read is applied
var look_applied := Vector2.ZERO
func _test_look() -> void:
	var lf := OS.get_environment("TN_PICK_TRACE") + ".look"
	if not FileAccess.file_exists(lf):
		return
	var w := FileAccess.get_file_as_string(lf).strip_edges().split(" ")
	if w.size() < 3:
		return
	var tot := Vector2(w[1].to_float(), w[2].to_float())
	var d := tot - look_applied
	look_applied = tot
	if d == Vector2.ZERO:
		return
	var vp := _vp()
	vp.play_dx += d.x * vp.mouse_sens
	var down: float = d.y * vp.mouse_sens * (-1.0 if vp.invert_y else 1.0)
	vp.play_dy += vp.look_dn.take(down) if vp.look_dn != null else down


# tests: the frame of his click: his line, the target's drawn place, what was sent (<TN_PICK_TRACE>.clicks)
func _click_log(pk: PackedByteArray) -> void:
	var f := FileAccess.open(OS.get_environment("TN_PICK_TRACE") + ".clicks", FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(OS.get_environment("TN_PICK_TRACE") + ".clicks", FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	var l := line()
	var eye: Vector3 = l[0]
	var dir: Vector3 = l[1]
	var tp := Vector3.ZERO
	var n: Node3D = hud._drawn(trace_ent) if trace_ent > 0 else null
	if n != null:
		var e: Array = _vp().live_ents.get(trace_ent, [])
		var fz: float = float(e[5]) - float(n.get_meta("ez", float(e[5]))) if e.size() > 6 else 0.0
		tp = n.global_position + Vector3(0.0, fz, 0.0)
	f.store_line("%.4f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%d,%.4f,%.4f,%.4f,%d,%d,%.4f,%.4f,%.4f" % [
			Time.get_unix_time_from_system(), eye.x, eye.z, eye.y, dir.x, dir.z, dir.y, trace_ent if n != null else -1,
			tp.x, tp.z, tp.y, pk[0], pk.decode_u16(1), pk.decode_float(3), pk.decode_float(7), pk.decode_float(11)])
	f.close()


# tests: his camera and line, the target's drawn place (the game's x, y, z), each frame
func _trace() -> void:
	var path := OS.get_environment("TN_PICK_TRACE")
	if trace_f == null:
		trace_f = FileAccess.open(path, FileAccess.WRITE)
		if trace_f == null:
			return
		trace_f.store_line("unix,ex,ey,ez,dx,dy,dz,ent,tx,ty,tz,pick")
	var now := Time.get_ticks_msec() / 1000.0
	if now - trace_t > 0.5:
		trace_t = now
		trace_ent = -1
		if FileAccess.file_exists(path + ".target"):
			trace_ent = FileAccess.get_file_as_string(path + ".target").strip_edges().to_int()
	var l := line()
	var eye: Vector3 = l[0]
	var dir: Vector3 = l[1]
	var tp := Vector3.ZERO
	var n: Node3D = hud._drawn(trace_ent) if trace_ent > 0 else null
	if n != null:
		var e: Array = _vp().live_ents.get(trace_ent, [])
		var f: float = float(e[5]) - float(n.get_meta("ez", float(e[5]))) if e.size() > 6 else 0.0
		tp = n.global_position + Vector3(0.0, f, 0.0)
	var pk := pick() if _vp().play_buttons.has(1) else PackedByteArray([0])
	trace_f.store_line("%.4f,%.4f,%.4f,%.4f,%.5f,%.5f,%.5f,%d,%.4f,%.4f,%.4f,%d" % [Time.get_unix_time_from_system(),
			eye.x, eye.z, eye.y, dir.x, dir.z, dir.y, trace_ent if n != null else -1, tp.x, tp.z, tp.y, pk[0]])
	trace_f.flush()
