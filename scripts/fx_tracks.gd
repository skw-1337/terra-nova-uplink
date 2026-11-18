# Footprints and vehicle tracks (an extra on top of the game's look: on unless TN_FX_TRACKS=0). Every walking suit
# leaves a print of its own sole where a foot plants (the player himself, the squad, the co-op partner, the enemy's
# soldiers and the walking mech), every ground vehicle the marks of what of it touches the ground; they fade out
# after a while, never more than MAX of them, and are drawn over the ground by tracks.gdshader (a box laid on the
# ground, the view's own ground inside it darkened by the mark's shape: no mesh to fit to the slopes).
#
# Each mark's shape comes from that unit's own model in the player's game files (made at load, nothing of the game
# kept here), one layer of a small atlas per model:
#   suits (class 1, suit s 0-10)  the foot's limb sprite (RESTNOBJ 800 + 7 s): the limb runs from the ankle to the
#       toe and its views turn round that bone, the front (view 8) facing up on a foot (viewer.gd _pose_apply): its
#       back, view 0, is the foot seen from below, the sole. Its outline, at the scale of the suit's own foot (the
#       sprite's bone pixels over the ankle-toe length of its pose), placed by its ankle.
#   the mech (suit 11)  its foot's 3D part (RESTNOBJ 877 + part of the skeleton segment ankle -> toe): its triangles
#       seen from below (the part's y from the ankle to the toe, z across), claws and all.
#   ground vehicles (class 2)  their model's triangles in the bottom band of its height (tracks, wheels, skids) seen
#       from below; laid along their path, each stamp the length of that contact. A vehicle whose lowest point rides
#       clear of the ground (the hover tanks) touches nothing: a faint wake of blown dust instead.
# Where a foot plants: the suit's 16 joints as posed (pose_last: the game's pose, or the ported gait of a suit the
# game does not pose; mechs: their parts' places), a foot that moved and then stays still, down by the ground.
# The ground: clear on snow and sand, faint on dark rock or grass (the planet's tile colour there), none on water nor
# off the ground (a roof, the air).
extends Node3D

const TNData = preload("res://scripts/tn_data.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
const TRACKS = preload("res://tracks.gdshader")
const MAX := 1024
const HOLD := 40.0             # s a mark stays whole, then FADE s to go
const FADE := 20.0
const ATLAS := 64              # an atlas layer's pixels
const LAYERS := 48
const MOVED := 0.25            # a foot faster than this (units a second) is swinging
const STILL := 0.06            # ... slower than this after it: planted
const UP_MAX := 0.12           # its ankle at most this much above the ankle's height standing on the ground
const OFF_GROUND := 0.3        # a unit this far above the map's ground stands on something else (no mark)
const HOVER := 0.1             # a vehicle's lowest point this high over the ground: it does not touch it
const BAND := 0.22             # a vehicle's contact: its triangles in this share of its height from the bottom

var v: Node                    # the viewer
var node: MultiMeshInstance3D
var mat: ShaderMaterial
var atlas: Texture2DArray
var images: Array[Image] = []
var shapes := {}               # key -> {layer, size (world: along, across), off (centre from the anchor, along)}
var next := 0
var used := 0
var newest := -1000.0
var feet := {}                 # suit node -> {"ref": the last pose seen, "t": when, "f": [per foot: pos, moving, last print]}
var cars := {}                 # vehicle node -> [last stamp place, contact key]
var map_ref = null
var debug := OS.has_environment("TN_FX_DEBUG")
var stamps := 0                # (tests: how many were laid)
var cost := OS.has_environment("TN_FX_COST")   # (tests: its time a frame, said every 600 frames)
var cost_us := 0
var cost_n := 0


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
	mat.shader = TRACKS
	mat.set_shader_parameter("hold", HOLD)
	mat.set_shader_parameter("fade", FADE)
	node.material_override = mat
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))
	node.visible = false
	add_child(node)
	var blank := Image.create(ATLAS, ATLAS, false, Image.FORMAT_L8)
	images.append(blank)                         # (layer 0: nothing)
	_dust_shape()


func _process(_dt: float) -> void:
	if v == null or not v.live or v.current.is_empty():
		return
	var now: float = v._ticks() / 1000.0
	var m: Dictionary = v.current["map"]
	if m != map_ref:                             # another map: its ground has none of them
		map_ref = m
		clear()
	if v.get("photo_on"):
		mat.set_shader_parameter("now", now)
		return                                   # (the photo mode: everything stays as it is)
	var t0 := Time.get_ticks_usec() if cost else 0
	var units: Array = v.live_nodes + v.live_extra.values()
	for n in units:
		if n == null or not is_instance_valid(n) or not n.is_visible_in_tree():
			continue
		if n.has_meta("corpse"):
			continue
		if n.has_meta("pose_last") and n.has_meta("suit"):
			_suit(n, m, now)
		elif n.has_meta("mech"):
			_mech(n, m, now)
		elif n.has_meta("half") and n is MeshInstance3D:
			_vehicle(n, m, now)
	if node.visible:
		mat.set_shader_parameter("now", now)
		if now - newest > HOLD + FADE:
			clear()
	if cost:
		cost_us += Time.get_ticks_usec() - t0
		cost_n += 1
		if cost_n >= 600:
			print("fx tracks: %.3f ms a frame (cpu), %d marks shown, %d laid, %d shapes" % [cost_us / 600000.0, used, stamps, images.size() - 1])
			cost_us = 0
			cost_n = 0


func clear() -> void:
	next = 0
	used = 0
	feet.clear()
	cars.clear()
	node.multimesh.visible_instance_count = 0
	node.visible = false


# ---- suits
func _suit(n: Node3D, m: Dictionary, now: float) -> void:
	var q: Array = n.get_meta("pose_last")
	var st: Dictionary = feet.get(n, {})
	if not st.is_empty() and st["ref"] == q:
		return                                   # (no new pose since the last look)
	if q.size() < 4:
		return
	var suit: int = n.get_meta("suit")
	var places := []
	for i in 2:
		var toe: Vector3 = n.to_global(Vector3(q[i].z, q[i].y, q[i].x))
		var ankle: Vector3 = n.to_global(Vector3(q[2 + i].z, q[2 + i].y, q[2 + i].x))
		places.append([ankle, toe])
	_feet(n, st, q, places, "s%d" % suit, m, now, func() -> Dictionary: return _sole_shape(suit))


func _mech(n: Node3D, m: Dictionary, now: float) -> void:
	var places := []
	var foot_part: MeshInstance3D = null
	for part in n.get_meta("mech"):
		if int(part[1]) == 2 or int(part[1]) == 3:
			var pn: MeshInstance3D = part[0]
			var ankle := pn.global_position
			var len := 0.1
			var aabb: AABB = pn.mesh.get_aabb() if pn.mesh else AABB()
			len = maxf(len, aabb.size.y)
			places.append([ankle, ankle - pn.global_basis.y.normalized() * len])   # (y from the toe to the ankle)
			foot_part = pn
	if places.size() < 2 or foot_part == null:
		return
	var st: Dictionary = feet.get(n, {})
	var ref: Vector3 = places[0][0]
	if not st.is_empty() and (st["ref"] as Vector3).is_equal_approx(ref):
		return
	var fm := foot_part.mesh
	_feet(n, st, ref, places, "mech", m, now, func() -> Dictionary: return _part_shape(fm))


# one look at a walker's feet: [ankle, toe] each, in the world; a foot that swung and now stays still is planted
func _feet(n: Node3D, st: Dictionary, ref, places: Array, key: String, m: Dictionary, now: float, make: Callable) -> void:
	if st.is_empty():
		st = {"ref": ref, "t": now, "f": [[places[0][1], false, Vector3(-99, 0, 0)], [places[1][1], false, Vector3(-99, 0, 0)]]}
		feet[n] = st
		return
	var dt := maxf(now - float(st["t"]), 0.001)
	st["ref"] = ref
	st["t"] = now
	for i in 2:
		var f: Array = st["f"][i]
		var ankle: Vector3 = places[i][0]
		var toe: Vector3 = places[i][1]
		var flat := Vector2(toe.x - (f[0] as Vector3).x, toe.z - (f[0] as Vector3).z)
		var speed := flat.length() / dt
		f[0] = toe
		if speed > MOVED:
			f[1] = true
			continue
		if not f[1] or speed > STILL or dt > 1.0:
			continue
		var g := TNData.height_at(m, toe.x, toe.z)
		var lowest := minf(ankle.y, toe.y)
		if lowest - g > UP_MAX or lowest - g < -0.3:
			continue                             # (in the air, or on something else than the ground)
		f[1] = false
		if (f[2] as Vector3).distance_to(toe) < 0.03:
			continue
		f[2] = toe
		var sh: Dictionary = shapes.get(key, {})
		if sh.is_empty():
			sh = make.call()
			shapes[key] = sh
		if sh.is_empty() or int(sh["layer"]) == 0:
			continue
		var along := Vector3(toe.x - ankle.x, 0.0, toe.z - ankle.z)
		if along.length() < 1e-3:
			continue
		var bone := Vector3(toe - ankle).length()
		var k: float = bone / float(sh["bone"]) if float(sh["bone"]) > 0.0 else 1.0
		var dir := along.normalized()
		var at := Vector3(ankle.x, g, ankle.z) + dir * float(sh["off"]) * k
		_put(m, at, dir, float(sh["size"].x) * k * 0.5, float(sh["size"].y) * k * 0.5, int(sh["layer"]), 1.0, now)


# ---- vehicles
func _vehicle(n: MeshInstance3D, m: Dictionary, now: float) -> void:
	var p := n.global_position
	var c: Array = cars.get(n, [])
	if c.is_empty():
		cars[n] = [p, ""]
		return
	var key := "v%d" % n.mesh.get_rid().get_id() if n.mesh else ""
	if key == "":
		return
	var sh: Dictionary = shapes.get(key, {})
	if sh.is_empty():
		sh = _contact_shape(n)
		shapes[key] = sh
	var step: float = maxf(0.15, float(sh.get("len", float(sh.get("size", Vector2(0.6, 0.0)).x))) * 0.95)   # (its contact's length: end to end)
	var last: Vector3 = c[0]
	var d := Vector3(p.x - last.x, 0.0, p.z - last.z)
	if d.length() < step:
		return
	cars[n] = [p, key]
	if d.length() > step * 6.0:
		return                                   # (a jump: a teleport, a new mission)
	var g := TNData.height_at(m, p.x, p.z)
	var bottom: float = p.y + float(sh.get("low", 0.0))
	if bottom - g > OFF_GROUND:
		return
	var dir := d.normalized()
	var mid := Vector3((p.x + last.x) * 0.5, 0.0, (p.z + last.z) * 0.5)
	mid.y = TNData.height_at(m, mid.x, mid.z)
	if bottom - g > HOVER or int(sh.get("layer", 0)) == 0:
		var dust: Dictionary = shapes["dust"]       # hovering: a light wake of blown dust, as wide as the craft
		var wide: float = maxf(float(sh.get("size", Vector2(0.6, 0.6)).y), 0.3)
		_put(m, mid, dir, d.length() * 0.5, wide * 0.5, int(dust["layer"]), 0.5, now)
		return
	_put(m, mid, dir, float(sh["size"].x) * 0.5 * d.length() / step * 0.95, float(sh["size"].y) * 0.5, int(sh["layer"]), 1.0, now)


# ---- the shapes, from the models
func _layer(img: Image) -> int:
	if images.size() >= LAYERS:
		return 0
	images.append(img)
	atlas = Texture2DArray.new()
	atlas.create_from_images(images)
	mat.set_shader_parameter("shapes", atlas)
	return images.size() - 1


# A suit's sole: the back view of its foot's limb sprite (the foot seen from below), its outline in the atlas with
# the bone along x (ankle -> toe), across y; its size and centre in the sprite's pixels, and the bone's pixels
func _sole_shape(suit: int) -> Dictionary:
	if not v.objects_ok or v.pal.is_empty():
		return {}
	# (the sprite's own pixels, as tn_objects.gd _limb_views reads them: view 0, its anchor = the ankle)
	var fr: Array = TNObjects.LGRes.frames(v.objects.res.data(800 + 7 * suit))
	if fr.is_empty() or (fr[0] as PackedByteArray).size() < 17:
		return {}
	var f: PackedByteArray = fr[0]
	var o := f.decode_u32(13)
	if o + 0x20 > f.size() or not (f[o + 4] == 2 or f[o + 4] == 4):
		return {}
	var img: Image = TNObjects._bitmap(f.slice(o), v.pal, 0x20)
	if img == null:
		return {}
	var a1 := float(f[o + 17])                 # (the ankle's row; the bone runs down the sprite)
	var bone_px := float(f.decode_u16(9))
	var used_r := img.get_used_rect()
	if used_r.size.x < 2 or used_r.size.y < 2:
		return {}
	var out := Image.create(ATLAS, ATLAS, false, Image.FORMAT_L8)
	var len_px := float(used_r.size.y)
	var wid_px := float(used_r.size.x)
	var s := float(ATLAS - 4) / maxf(len_px, wid_px)
	for y in ATLAS:
		for x in ATLAS:
			# atlas x along the bone (ankle -> toe: down the sprite), atlas y across
			var sy := used_r.position.y + (x - ATLAS / 2.0) / s + len_px / 2.0
			var sx := used_r.position.x + (y - ATLAS / 2.0) / s + wid_px / 2.0
			if sx >= 0 and sy >= 0 and sx < img.get_width() and sy < img.get_height():
				out.set_pixel(x, y, Color(img.get_pixel(int(sx), int(sy)).a, 0, 0))
	var layer := _layer(out)
	var bone: float = maxf(1.0, bone_px)
	return {"layer": layer, "bone": bone, "size": Vector2(ATLAS, ATLAS) / s,
			"off": used_r.position.y + len_px / 2.0 - a1}


# A 3D part seen from below (the mech's foot): its triangles projected on its -y (along, from the ankle) and z (across)
func _part_shape(mesh: Mesh) -> Dictionary:
	var tris := _triangles(mesh, Transform3D.IDENTITY)
	if tris.is_empty():
		return {}
	var pts: Array = []
	for t in tris:
		pts.append([Vector2(-t[0].y, t[0].z), Vector2(-t[1].y, t[1].z), Vector2(-t[2].y, t[2].z)])
	var r := _raster(pts)
	if r.is_empty():
		return {}
	var aabb := mesh.get_aabb()
	return {"layer": _layer(r["img"]), "bone": maxf(aabb.size.y, 0.01), "size": r["size"], "off": r["centre"].x}


# A vehicle's contact: its model's triangles in the bottom BAND of its height, from below (x along, z across)
func _contact_shape(n: MeshInstance3D) -> Dictionary:
	var tris := _triangles(n.mesh, Transform3D.IDENTITY)       # (its model's own axes: x its length, y up)
	if tris.is_empty():
		return {}
	var lo := 1e9
	var hi := -1e9
	for t in tris:
		for p in t:
			lo = minf(lo, p.y)
			hi = maxf(hi, p.y)
	var cut := lo + (hi - lo) * BAND
	var pts: Array = []
	for t in tris:
		if t[0].y <= cut and t[1].y <= cut and t[2].y <= cut:
			pts.append([Vector2(t[0].x, t[0].z), Vector2(t[1].x, t[1].z), Vector2(t[2].x, t[2].z)])
	var r := _raster(pts)
	if r.is_empty():
		return {"layer": 0, "low": lo, "size": Vector2(hi - lo, hi - lo)}
	var img: Image = r["img"]
	var ext: Vector2 = r["ext"]
	# a bottom that is one flat hull (most of its outline filled: the model has no tracks or wheels of its own)
	# rolls on its two sides: two strips, each a fifth of its width, at its outer edges
	var px := Vector2i(ceili(ext.x / float(r["size"].x) * ATLAS), ceili(ext.y / float(r["size"].y) * ATLAS))
	var lo_px := (Vector2i(ATLAS, ATLAS) - px) / 2
	var filled := 0
	for y in range(lo_px.y, lo_px.y + px.y):
		for x in range(lo_px.x, lo_px.x + px.x):
			if x >= 0 and y >= 0 and x < ATLAS and y < ATLAS and img.get_pixel(x, y).r > 0.5:
				filled += 1
	if filled > 0.7 * px.x * px.y:
		var band := maxi(1, px.y / 5)
		for y in range(lo_px.y, lo_px.y + px.y):
			for x in range(lo_px.x, lo_px.x + px.x):
				if x >= 0 and y >= 0 and x < ATLAS and y < ATLAS:
					var side := y - lo_px.y < band or y >= lo_px.y + px.y - band
					img.set_pixel(x, y, Color(1.0 if side and img.get_pixel(x, y).r > 0.5 else 0.0, 0, 0))
	return {"layer": _layer(img), "low": lo, "size": r["size"], "len": ext.x, "off": 0.0}


func _triangles(mesh: Mesh, xf: Transform3D) -> Array:
	var out := []
	if mesh == null:
		return out
	for s in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var a := mesh.surface_get_arrays(s)
		var vx: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var ix = a[Mesh.ARRAY_INDEX]
		if ix != null and (ix as PackedInt32Array).size() > 0:
			var ii: PackedInt32Array = ix
			for k in range(0, ii.size() - 2, 3):
				out.append([xf * vx[ii[k]], xf * vx[ii[k + 1]], xf * vx[ii[k + 2]]])
		else:
			for k in range(0, vx.size() - 2, 3):
				out.append([xf * vx[k], xf * vx[k + 1], xf * vx[k + 2]])
	return out


# triangles (2D: x along, y across) into an atlas layer, square, the shape centred: {img, size (world), centre}
func _raster(tris: Array) -> Dictionary:
	if tris.is_empty():
		return {}
	var lo := Vector2(1e9, 1e9)
	var hi := Vector2(-1e9, -1e9)
	for t in tris:
		for p: Vector2 in t:
			lo = lo.min(p)
			hi = hi.max(p)
	var ext := hi - lo
	if ext.x < 1e-3 or ext.y < 1e-3:
		return {}
	var side := maxf(ext.x, ext.y) * 1.06
	var centre := (lo + hi) * 0.5
	var img := Image.create(ATLAS, ATLAS, false, Image.FORMAT_L8)
	for t in tris:
		var a: Vector2 = (t[0] - centre) / side * ATLAS + Vector2(ATLAS, ATLAS) * 0.5
		var b: Vector2 = (t[1] - centre) / side * ATLAS + Vector2(ATLAS, ATLAS) * 0.5
		var c: Vector2 = (t[2] - centre) / side * ATLAS + Vector2(ATLAS, ATLAS) * 0.5
		var mn := a.min(b).min(c).floor()
		var mx := a.max(b).max(c).ceil()
		var area := (b - a).cross(c - a)
		if absf(area) < 1e-6:
			continue
		for y in range(maxi(0, int(mn.y)), mini(ATLAS, int(mx.y) + 1)):
			for x in range(maxi(0, int(mn.x)), mini(ATLAS, int(mx.x) + 1)):
				var p := Vector2(x + 0.5, y + 0.5)
				var w0 := (c - b).cross(p - b) / area
				var w1 := (a - c).cross(p - c) / area
				var w2 := (b - a).cross(p - a) / area
				if w0 >= -0.02 and w1 >= -0.02 and w2 >= -0.02:
					img.set_pixel(x, y, Color(1, 0, 0))
	return {"img": img, "size": Vector2(side, side), "centre": centre, "ext": ext}


# blown dust (the hover craft's wake): a soft streak along its way
func _dust_shape() -> void:
	var img := Image.create(ATLAS, ATLAS, false, Image.FORMAT_L8)
	for y in ATLAS:
		for x in ATLAS:
			var d := absf(y - ATLAS / 2.0) / (ATLAS / 2.0)
			img.set_pixel(x, y, Color(clampf((1.0 - d * d) * 0.6, 0.0, 1.0), 0, 0))
	shapes["dust"] = {"layer": _layer(img), "size": Vector2(1, 1), "off": 0.0}


# ---- laying one
func _strength(m: Dictionary, p: Vector3) -> float:
	var pl: Dictionary = m.get("planet_data", {})
	var g: Dictionary = m["detail"]
	if not g.has("tile"):
		return 0.6
	var n: int = g["n"]
	var tile: int = g["tile"][clampi(int(p.z), 0, n - 1) * n + clampi(int(p.x), 0, n - 1)]
	var water = pl.get("water")
	if water != null and tile < water.size() and water[tile] == 1:
		return 0.0                               # (water keeps nothing)
	var tc = pl.get("tile_color")
	if tc == null or tile >= (tc as PackedColorArray).size():
		return 0.6
	var c: Color = tc[tile]
	# light, soft ground (snow, sand) takes a clear print; dark rock or grass a faint one
	var lum := 0.3 * c.r + 0.59 * c.g + 0.11 * c.b
	var green := clampf((c.g - maxf(c.r, c.b)) * 3.0, 0.0, 1.0)
	return clampf(0.25 + (lum - 0.2) * 1.6, 0.25, 1.0) * (1.0 - 0.5 * green)


func _put(m: Dictionary, pos: Vector3, along: Vector3, half_x: float, half_z: float, layer: int, strength: float, now: float) -> void:
	if pos.x < 1.0 or pos.z < 1.0 or pos.x > 511.0 or pos.z > 511.0:
		return
	var s := strength * _strength(m, pos)
	if s <= 0.02:
		return
	var e := clampf(maxf(half_x, half_z), 0.05, 0.5)
	var up := Vector3(TNData.height_at(m, pos.x - e, pos.z) - TNData.height_at(m, pos.x + e, pos.z), 2.0 * e,
			TNData.height_at(m, pos.x, pos.z - e) - TNData.height_at(m, pos.x, pos.z + e)).normalized()
	var x := (along - up * along.dot(up)).normalized()
	var z := x.cross(up).normalized()
	var mm := node.multimesh
	var thick := maxf(0.06, maxf(half_x, half_z) * 0.5)
	mm.set_instance_transform(next, Transform3D(Basis(x * half_x * 2.0, up * thick * 2.0, z * half_z * 2.0), pos))
	mm.set_instance_custom_data(next, Color(float(layer), now, float((next * 37) % 101) / 10.0, s))
	next = (next + 1) % MAX
	used = mini(used + 1, MAX)
	mm.visible_instance_count = used
	node.visible = true
	newest = now
	stamps += 1
	if debug:
		print("fx track: layer ", layer, " at ", pos, " ", half_x, " x ", half_z, " strength ", s)
