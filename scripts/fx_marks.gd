# Impact marks (an extra on top of the game's look: on unless TN_FX_MARKS=0). Where a shot hits the ground it leaves
# a mark that fits its weapon: a laser a thin burnt line along the way its beam went over the ground (its impacts of a
# held trigger joined), the energy bolts (pulsar, plasma, particle beam, ion rifle, disruptor) a small scorched
# spot, missiles, grenades and shells a wide burn, bullets small pocks. They fade out after a while and there are
# never more than MAX of them. Drawn over the ground by marks.gdshader; the game's own burnt squares (viewer.gd
# _live_scorch) stay the game's: a blast's burn is left out on a square the game burnt.
extends Node3D

const TNData = preload("res://scripts/tn_data.gd")
const MARKS = preload("res://marks.gdshader")
const MAX := 768
const HOLD := 45.0             # s a mark stays whole, then FADE s to go
const FADE := 20.0
# weapon (class 5 type) -> kind: 0 pock, 1 laser line, 2 scorched spot, 3 blast burn, -1 none (smoke grenade, EM)
const KIND := {2: -1, 3: 3, 4: 1, 5: 2, 6: 2, 7: 0, 8: -1, 9: 2, 10: 3, 11: 2, 12: -1, 13: 3, 14: 0, 22: 2, 25: 2, 23: 0}
# kind -> half width, half thickness of its box (world units: a suit is 0.4 tall), strength
const SIZE := {0: [0.022, 0.03, 0.85], 1: [0.016, 0.03, 0.95], 2: [0.07, 0.05, 0.9], 3: [0.45, 0.16, 0.8]}
const LINE_GAP := 0.4          # s: two laser impacts closer in time than this ...
const LINE_REACH := 1.3        # ... and nearer than this are joined by a line
const LINE_PIECE := 0.22       # a line follows the ground in stretches of this length

var v: Node                    # the viewer
var shots: Node                # fx_shots.gd
var node: MultiMeshInstance3D
var mat: ShaderMaterial
var next := 0                  # the ring's next slot
var used := 0
var newest := -1000.0
var lasers := []               # the last laser impacts: [position, time (s), joined on]
var recent := []               # the last marks: [kind, position, slot, time]
var burns := {}                # slot -> the map square of a blast's burn (left out where the game burns the square)
var map_ref = null
var scorch_ref := PackedByteArray()


func _ready() -> void:
	node = MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	mm.mesh = box
	mm.instance_count = MAX
	mm.visible_instance_count = 0
	node.multimesh = mm
	mat = ShaderMaterial.new()
	mat.shader = MARKS
	mat.set_shader_parameter("hold", HOLD)
	mat.set_shader_parameter("fade", FADE)
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	node.visible = false
	add_child(node)
	shots.impact.connect(_on_impact)


func _process(_dt: float) -> void:
	var now: float = v._ticks() / 1000.0
	if v.current.get("map") != map_ref:                # another map: its ground has none of them
		map_ref = v.current.get("map")
		clear()
	if not node.visible:
		return
	if now - newest > HOLD + FADE:
		clear()
		return
	mat.set_shader_parameter("now", now)
	if not burns.is_empty() and v.scorch_prev != scorch_ref:   # the game burnt squares: its own picture there
		scorch_ref = v.scorch_prev
		for slot in burns.keys():
			if _game_burnt(burns[slot]):
				node.multimesh.set_instance_custom_data(slot, Color(0, -1000.0, 0, 0))
				burns.erase(slot)


func clear() -> void:
	next = 0
	used = 0
	lasers.clear()
	recent.clear()
	burns.clear()
	node.multimesh.visible_instance_count = 0
	node.visible = false


func _game_burnt(cell: Vector2i) -> bool:
	var img: Image = v.burn_img
	return img != null and cell.x >= 0 and cell.y >= 0 and cell.x < img.get_width() and cell.y < img.get_height() \
			and img.get_pixel(cell.x, cell.y).r > 0.0


func _on_water(m: Dictionary, p: Vector3) -> bool:
	var pl: Dictionary = m.get("planet_data", {})
	var g: Dictionary = m["detail"]
	var water = pl.get("water")
	if water == null or not g.has("tile"):
		return false
	var n: int = g["n"]
	var tile: int = g["tile"][clampi(int(p.z), 0, n - 1) * n + clampi(int(p.x), 0, n - 1)]
	return tile < water.size() and water[tile] == 1


func _on_impact(typ: int, pos: Vector3, on_ground: bool, _dir: Vector3) -> void:
	var kind: int = KIND.get(typ, 0)
	if not on_ground or kind < 0 or v.current.is_empty():
		return
	var m: Dictionary = v.current["map"]
	if pos.x < 1.0 or pos.z < 1.0 or pos.x > 511.0 or pos.z > 511.0 or _on_water(m, pos):
		if shots.debug:
			print("fx mark: none at ", pos, " (off the detailed map, or water)")
		return                                          # (the detailed map only; nothing stays on water)
	var now: float = v._ticks() / 1000.0
	var half: float = SIZE[kind][0]
	# the same place again (a still aim): the mark there is made new, no pile of them
	for r in recent:
		if r[0] == kind and now - float(r[3]) < HOLD and (r[1] as Vector3).distance_to(pos) < half * 0.5:
			_date(r[2], now)
			r[3] = now
			if kind == 1:
				_laser(m, pos, now)
			return
	if kind == 3:
		var cell := Vector2i(int(pos.x), int(pos.z))
		if _game_burnt(cell):
			return
		burns[next] = cell
		scorch_ref = v.scorch_prev
	if kind == 1:
		_laser(m, pos, now)
		half *= 1.6                                     # (where the beam ends: a little wider than its line)
	var slot := _put(m, pos, Vector3.ZERO, half, half, SIZE[kind][1], 2 if kind == 1 else kind, float(SIZE[kind][2]), now)
	recent.append([kind, pos, slot, now])
	if shots.debug:
		print("fx mark: kind ", kind, " slot ", slot, " at ", pos)
	if recent.size() > 48:
		recent.pop_front()


# a laser's impact: joined to the one just before it nearby by a burnt line following the ground
func _laser(m: Dictionary, pos: Vector3, now: float) -> void:
	var from = null
	var best := LINE_REACH
	for l in lasers:
		var d: float = (l[0] as Vector3).distance_to(pos)
		if not l[2] and now - float(l[1]) < LINE_GAP and d < best:
			best = d
			from = l
	lasers.append([pos, now, false])
	if lasers.size() > 24:
		lasers.pop_front()
	if from == null or best < 0.02:
		return
	from[2] = true
	var a: Vector3 = from[0]
	var n := maxi(1, ceili(best / LINE_PIECE))
	var p0 := a
	for k in range(1, n + 1):
		var p1 := a.lerp(pos, float(k) / n)
		p1.y = TNData.height_at(m, p1.x, p1.z)
		_put(m, (p0 + p1) * 0.5, p1 - p0, (p1 - p0).length() * 0.5, SIZE[1][0], SIZE[1][1], 1, float(SIZE[1][2]), now)
		p0 = p1


func _date(slot: int, now: float) -> void:
	var c := node.multimesh.get_instance_custom_data(slot)
	c.g = now
	node.multimesh.set_instance_custom_data(slot, c)
	newest = now


# One mark: a box at pos on the ground, along "along" (zero: any way), half_x long, half_z wide, thick up and down
func _put(m: Dictionary, pos: Vector3, along: Vector3, half_x: float, half_z: float, thick: float, kind: int, strength: float, now: float) -> int:
	var e := clampf(maxf(half_x, half_z), 0.05, 0.5)
	var up := Vector3(TNData.height_at(m, pos.x - e, pos.z) - TNData.height_at(m, pos.x + e, pos.z), 2.0 * e,
			TNData.height_at(m, pos.x, pos.z - e) - TNData.height_at(m, pos.x, pos.z + e)).normalized()
	var x := along - up * along.dot(up)
	if x.length() < 1e-4:
		var turn := float((next * 7919 + int(pos.x * 131.0)) % 628) / 100.0
		x = Vector3(cos(turn), 0.0, sin(turn))
		x = x - up * x.dot(up)
	x = x.normalized()
	var z := x.cross(up).normalized()
	var slot := next
	next = (next + 1) % MAX
	used = mini(used + 1, MAX)
	if kind != 3:
		burns.erase(slot)
	var mm := node.multimesh
	mm.set_instance_transform(slot, Transform3D(Basis(x * half_x * 2.0, up * thick * 2.0, z * half_z * 2.0), pos))
	mm.set_instance_custom_data(slot, Color(float(kind), now, float((slot * 37) % 101) / 10.0, strength))
	mm.visible_instance_count = used
	node.visible = true
	newest = now
	mat.set_shader_parameter("now", now)
	return slot
