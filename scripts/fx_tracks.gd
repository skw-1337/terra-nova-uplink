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
#   vehicles (class 2)  two ruts rolled along the way they really drive, not prints: where what touches the ground
#       on their model runs (its triangles down in the bottom band of its height, seen from below: the tracks, wheels
#       or skids of its left and of its right; a bottom that is one flat hull: that hull's two edges), with a light
#       tread along them. One stretch of ruts is one long box, drawn out as the vehicle goes; the next begins where
#       its way bends, their ends cut on the bend's bisector (no gap, nothing laid twice). Nothing while it stands,
#       turns on the spot or slides by a rounding amount. The game's vehicles all ride on the ground (their height
#       over it read in the running game for eleven of the twelve models, the small "opheg14" too: 0.14 to 0.15,
#       the game's own resting height; the twelfth is the harvester's wreck); one that the game held clear of it
#       (HOVER) would leave a soft streak of blown dust as wide as itself instead.
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
const BAND := 0.22             # a vehicle's contact: what of it is in this share of its height from the bottom ...
const BAND_MAX := 0.15         # ... and no higher than this (a tall thing: the harvester's tower)
const RUT := 0.13              # a flat hull's ruts: this share of its width each, at its two edges
const SEG_START := 0.3         # a vehicle gone this far within SEG_WAIT s is driving: its ruts begin where it was
const SEG_WAIT := 4.0
const SEG_MAX := 6.0           # one stretch of ruts: no longer than this ...
const SEG_SIDE := 0.05         # ... its way within this of a straight line ...
const SEG_BUMP := 0.12         # ... and the ground under it within this of a flat one
const SEG_TURN := 0.15         # gone this far off a stretch: the next one's direction is known
const SEG_STEP := 0.12         # a stretch is drawn out by steps of this (under the hull: never seen), not every frame
const SEG_IDLE := 3.0          # stood this long: the stretch ends there
const JUMP := 3.0              # a move beyond this from one look to the next: put there, not driven (a new mission)
const THICK := 0.3             # half the height of a stretch's box
const DUST_LEN := 1.6          # the blown dust's pattern: this long

var v: Node                    # the viewer
var node: MultiMeshInstance3D
var mat: ShaderMaterial
var atlas: Texture2DArray
var images: Array[Image] = []
var shapes := {}               # key -> a foot: {layer, size (along, across), off (centre from the anchor), bone};
                               # a vehicle: {layer, wide, period, ruts, low, craft} (_rut_shape); "dust"
var next := 0
var used := 0
var newest := -1000.0
var feet := {}                 # suit node -> {"ref": the last pose seen, "t": when, "f": [per foot: pos, moving, last print]}
var cars := {}                 # vehicle node -> its stretch of ruts being drawn out (_vehicle)
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
	mm.use_colors = true                         # (a stretch of ruts: its second four numbers, tracks.gdshader)
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
	blank.generate_mipmaps()
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
	# (joints 0 / 2: the left foot, drawn from the right one's sprite mirrored: its print mirrored too)
	_feet(n, st, q, places, "s%d" % suit, m, now, func() -> Dictionary: return _sole_shape(suit, false),
			"s%dm" % suit, func() -> Dictionary: return _sole_shape(suit, true))


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
# (left_key / left_make: the left foot's own shape, joints 0 / 2; none: the same as the right one's)
func _feet(n: Node3D, st: Dictionary, ref, places: Array, key: String, m: Dictionary, now: float, make: Callable,
		left_key := "", left_make := Callable()) -> void:
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
		var left := i == 0 and left_key != ""
		var k_sh := left_key if left else key
		var sh: Dictionary = shapes.get(k_sh, {})
		if sh.is_empty():
			sh = left_make.call() if left else make.call()
			shapes[k_sh] = sh
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
# What a vehicle rolls into the ground. cars[n]: "a" where its stretch began ("ta" when), "b" where it has got to
# ("tb"), "idx" the stretch's box in the ring (-1: none, it stands or has not really set off), "gen" the count of
# marks when that box was taken (the ring gone round since: it is another mark's now), "pts" points of its way along
# the stretch, "dist" the way driven before it (the tread runs on from stretch to stretch), "prev" the stretch before
# (its end is cut to meet this one), "old" where its last stretches lie, "last" where the last look saw it.
func _vehicle(n: MeshInstance3D, m: Dictionary, now: float) -> void:
	var p := n.global_position
	var c: Dictionary = cars.get(n, {})
	if c.is_empty():
		cars[n] = {"a": p, "ta": now, "last": p, "idx": -1, "prev": -1, "dist": 0.0}
		return
	var last: Vector3 = c["last"]
	if p == last:                                # (the game has not moved it since the last look)
		if now - float(c["tb"] if int(c["idx"]) >= 0 else c["ta"]) > (SEG_IDLE if int(c["idx"]) >= 0 else SEG_WAIT):
			_rest(c, p, now)                     # (it stands: its stretch ends there)
		return
	c["last"] = p
	if not c.has("sh") or c["mesh"] != n.mesh:   # (its model: once, or when the viewer gives it another)
		c["mesh"] = n.mesh
		var key := "v%d" % n.mesh.get_rid().get_id() if n.mesh else ""
		if not shapes.has(key):
			shapes[key] = _rut_shape(n.mesh)
		c["sh"] = shapes[key]
	var sh: Dictionary = c["sh"]
	var over: float = p.y + float(sh.get("low", 0.0)) - TNData.height_at(m, p.x, p.z)
	var out: bool = p.x < 1.0 or p.z < 1.0 or p.x > 511.0 or p.z > 511.0
	if out or int(sh.get("layer", 0)) == 0 or over > OFF_GROUND or Vector2(p.x - last.x, p.z - last.z).length() > JUMP:
		_rest(c, p, now)                         # (in the air, on a roof; put there: a new mission, a teleport)
		return
	var wake := over > HOVER                     # held clear of the ground: blown dust, no ruts
	var a: Vector3 = c["a"]
	var d := Vector2(p.x - a.x, p.z - a.z)
	var length := d.length()
	if int(c["idx"]) < 0:                        # nothing being laid: has it really set off?
		if length < SEG_START:
			if now - float(c["ta"]) > SEG_WAIT:
				_rest(c, p, now)                 # (it stands, turns on the spot or slides by a rounding amount)
			return
		if _own(c, p):                           # along ruts it has just made (backing, forward again): nothing twice
			c["a"] = p
			c["ta"] = now
			return
		_begin(c, p, now, wake)
		_stretch(c, sh, m)
		return
	if stamps - int(c["gen"]) >= MAX or bool(c["wake"]) != wake:
		_rest(c, p, now)
		return
	var b: Vector3 = c["b"]
	var ab := Vector2(b.x - a.x, b.z - a.z)
	var bp := Vector2(p.x - b.x, p.z - b.z)
	if bp.length() < SEG_STEP:
		if now - float(c["tb"]) > SEG_IDLE:
			_rest(c, p, now)                     # (it stopped: the stretch ends there)
		return
	if length > ab.length() and length <= SEG_MAX and _straight(c["pts"], Vector2(a.x, a.z), d) and _level(m, a, p):
		c["b"] = p                               # straight on: the same stretch, drawn out to here
		c["tb"] = now
		if length - float(c["kept"]) >= 0.25:
			c["pts"].append(Vector2(p.x, p.z))
			c["kept"] = length
		_stretch(c, sh, m)
		return
	if bp.length() < SEG_TURN:
		return                                   # (off the line: a little further and its new direction is known)
	if bp.dot(ab) < 0.0:
		_rest(c, p, now)                         # (backing over its own ruts: nothing twice)
		return
	_keep(c)
	c["prev"] = c["idx"]                         # its way bends, or the ground does: the next stretch from b on
	c["prev_gen"] = c["gen"]
	c["prev_dir"] = ab.normalized()
	c["prev_col"] = c["col"]
	c["dist"] = float(c["dist"]) + ab.length()
	c["a"] = b
	c["ta"] = c["tb"]
	_begin(c, p, now, wake)
	_stretch(c, sh, m)


func _rest(c: Dictionary, p: Vector3, now: float) -> void:
	if int(c["idx"]) >= 0:
		_keep(c)
	c["idx"] = -1
	c["prev"] = -1
	c["a"] = p
	c["ta"] = now
	c["dist"] = 0.0


# its last stretches, where they lie (from, to): so as not to roll them again
func _keep(c: Dictionary) -> void:
	var old: Array = c.get("old", [])
	old.append([Vector2(c["a"].x, c["a"].z), Vector2(c["b"].x, c["b"].z)])
	if old.size() > 6:
		old.pop_front()
	c["old"] = old


func _own(c: Dictionary, p: Vector3) -> bool:
	for s: Array in c.get("old", []):
		var d: Vector2 = s[1] - s[0]
		var l := d.length()
		var q := Vector2(p.x, p.z) - (s[0] as Vector2)
		if l > 0.01 and q.dot(d) > -0.1 * l and q.dot(d) < (l + 0.1) * l and absf(q.cross(d)) < 0.12 * l:
			return true
	return false


func _begin(c: Dictionary, p: Vector3, now: float, wake: bool) -> void:
	c["idx"] = _take()
	c["gen"] = stamps
	c["wake"] = wake
	c["b"] = p
	c["tb"] = now
	c["pts"] = []
	c["kept"] = 0.0
	if debug:
		print("fx ruts: a stretch from ", c["a"], " towards ", p, ", dust" if wake else "")


# the points kept of a stretch's way (from a): all within SEG_SIDE of the straight line a -> a + d
func _straight(pts: Array, a: Vector2, d: Vector2) -> bool:
	var l := d.length()
	for q: Vector2 in pts:
		if absf((q - a).cross(d)) > SEG_SIDE * l:
			return false
	return true


# the ground between two places: within SEG_BUMP of the straight slope from one to the other
func _level(m: Dictionary, a: Vector3, b: Vector3) -> bool:
	var ga := TNData.height_at(m, a.x, a.z)
	var gb := TNData.height_at(m, b.x, b.z)
	for f: float in [0.25, 0.5, 0.75]:
		if absf(TNData.height_at(m, lerpf(a.x, b.x, f), lerpf(a.z, b.z, f)) - lerpf(ga, gb, f)) > SEG_BUMP:
			return false
	return true


# A stretch's box put from a to b on the ground (half its width longer at each end: room for the slanted cuts),
# tilted as the ground is along and across it; its end and the last stretch's cut on the bisector of the bend
func _stretch(c: Dictionary, sh: Dictionary, m: Dictionary) -> void:
	var a: Vector3 = c["a"]
	var b: Vector3 = c["b"]
	var wake: bool = c["wake"]
	var lay: Dictionary = shapes["dust"] if wake else sh
	var wide: float = float(sh.get("craft", 1.0)) * 1.2 if wake else float(sh["wide"])
	var ga := TNData.height_at(m, a.x, a.z)
	var gb := TNData.height_at(m, b.x, b.z)
	var along := Vector3(b.x - a.x, gb - ga, b.z - a.z)
	var flat := Vector2(along.x, along.z)
	if flat.length() < 1e-3:
		return
	var x := along.normalized()
	var mid := Vector3((a.x + b.x) * 0.5, 0.0, (a.z + b.z) * 0.5)
	var side := Vector3(flat.x, 0.0, flat.y).normalized().cross(Vector3.UP)
	var across := side * wide + Vector3(0.0, TNData.height_at(m, mid.x + side.x * wide * 0.5, mid.z + side.z * wide * 0.5)
			- TNData.height_at(m, mid.x - side.x * wide * 0.5, mid.z - side.z * wide * 0.5), 0.0)
	var up := across.cross(x).normalized()
	var z := x.cross(up).normalized()
	mid.y = ((ga + gb) * 0.5 + TNData.height_at(m, mid.x, mid.z)) * 0.5
	var s: float = (0.75 if wake else 1.0) * _strength(m, mid)
	var cut_a := 0.0
	var dir := flat.normalized()
	if int(c["prev"]) >= 0 and stamps - int(c["prev_gen"]) < MAX:
		var pd: Vector2 = c["prev_dir"]
		if pd.dot(dir) > 0.3:                    # (a sharper bend than that: both ends left square)
			var bis := (pd + dir).normalized()
			cut_a = clampf(-Vector2(-dir.y, dir.x).dot(bis) / dir.dot(bis), -1.0, 1.0)
			var pc: Color = c["prev_col"]
			pc.b = clampf(-Vector2(-pd.y, pd.x).dot(bis) / pd.dot(bis), -1.0, 1.0)
			node.multimesh.set_instance_color(int(c["prev"]), pc)
	var mm := node.multimesh
	var i: int = c["idx"]
	var period: float = lay["period"]
	c["col"] = Color(float(c["tb"]) - float(c["ta"]), cut_a, 0.0, period)
	mm.set_instance_transform(i, Transform3D(Basis(x * (along.length() + wide), up * THICK * 2.0, z * wide), mid))
	mm.set_instance_custom_data(i, Color(float(lay["layer"]), float(c["tb"]), fposmod(float(c["dist"]), period), s))
	mm.set_instance_color(i, c["col"])
	newest = float(c["tb"])


# ---- the shapes, from the models
func _layer(img: Image) -> int:
	if images.size() >= LAYERS:
		return 0
	img.generate_mipmaps()                       # (a stretch of ruts seen from afar: its tread evened out)
	images.append(img)
	atlas = Texture2DArray.new()
	atlas.create_from_images(images)
	mat.set_shader_parameter("shapes", atlas)
	mat.set_shader_parameter("shapes_rep", atlas)
	return images.size() - 1


# A suit's sole: the back view of its foot's limb sprite (the foot seen from below), its outline in the atlas with
# the bone along x (ankle -> toe), across y; its size and centre in the sprite's pixels, and the bone's pixels.
# Across, the atlas is centred on the bone (the sprite's anchor column, as the limb is drawn: the sole is not
# centred on it, 0 to 2.5 pixels off): sprite x to the right of the bone is the walker's right for the right foot
# (seen from below, toes down the sprite); the left foot is the right one's sprite mirrored (mirror: its print too)
func _sole_shape(suit: int, mirror := false) -> Dictionary:
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
	var ax := float(f[o + 16])                 # (the bone's column)
	var bone_px := float(f.decode_u16(9))
	var used_r := img.get_used_rect()
	if used_r.size.x < 2 or used_r.size.y < 2:
		return {}
	var out := Image.create(ATLAS, ATLAS, false, Image.FORMAT_L8)
	var len_px := float(used_r.size.y)
	var half_w := maxf(ax - used_r.position.x, used_r.end.x - ax)     # (either side of the bone)
	var s := float(ATLAS - 4) / maxf(len_px, 2.0 * half_w)
	var sgn := -1.0 if mirror else 1.0
	for y in ATLAS:
		for x in ATLAS:
			# atlas x along the bone (ankle -> toe: down the sprite), atlas y across (+: the walker's right)
			var sy := used_r.position.y + (x + 0.5 - ATLAS / 2.0) / s + len_px / 2.0
			var sx := ax + sgn * (y + 0.5 - ATLAS / 2.0) / s
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


# A vehicle's ruts, from its model (x its length, y up, z across): what of it is down in the bottom band, seen from
# below, gives for each line along it how much of its length touches the ground there. Two runs of such lines apart
# from each other: its left and its right (tracks, wheels, skids), a rut under each. One run only, wide: a flat hull,
# a rut along each of its two edges (RUT of its width); narrow: the one rut of that keel. The atlas layer: across it
# the ruts where they are from the model's middle line ("wide" the layer's width on the ground), along it one length
# ("period") of their tread, the bars a track's links press in.
func _rut_shape(mesh: Mesh) -> Dictionary:
	var tris := _triangles(mesh, Transform3D.IDENTITY)
	if tris.is_empty():
		return {"layer": 0}
	var lo := Vector3(1e9, 1e9, 1e9)
	var hi := -lo
	for t in tris:
		for q: Vector3 in t:
			lo = lo.min(q)
			hi = hi.max(q)
	var size := hi - lo
	if size.x < 1e-3 or size.z < 1e-3:
		return {"layer": 0}
	var cut := lo.y + minf(size.y * BAND, BAND_MAX)
	const N := 96
	var hit := PackedByteArray()
	hit.resize(N * N)
	for t in tris:
		var q0: Vector3 = t[0]
		var q1: Vector3 = t[1]
		var q2: Vector3 = t[2]
		if minf(q0.y, minf(q1.y, q2.y)) > cut:
			continue
		var p0 := Vector2((q0.x - lo.x) / size.x, (q0.z - lo.z) / size.z) * N
		var p1 := Vector2((q1.x - lo.x) / size.x, (q1.z - lo.z) / size.z) * N
		var p2 := Vector2((q2.x - lo.x) / size.x, (q2.z - lo.z) / size.z) * N
		var area := (p1 - p0).cross(p2 - p0)
		if absf(area) < 1e-6:
			continue
		var mn := p0.min(p1).min(p2).floor()
		var mx := p0.max(p1).max(p2).ceil()
		for y in range(maxi(0, int(mn.y)), mini(N, int(mx.y) + 1)):
			for x in range(maxi(0, int(mn.x)), mini(N, int(mx.x) + 1)):
				var q := Vector2(x + 0.5, y + 0.5)
				var w0 := (p2 - p1).cross(q - p1) / area
				var w1 := (p0 - p2).cross(q - p2) / area
				var w2 := 1.0 - w0 - w1
				if w0 >= -0.02 and w1 >= -0.02 and w2 >= -0.02 and w0 * q0.y + w1 * q1.y + w2 * q2.y <= cut:
					hit[y * N + x] = 1
	var cover := PackedFloat32Array()            # per line across: the share of the model's length that touches
	cover.resize(N)
	var top := 0.0
	for y in N:
		var k := 0
		for x in N:
			k += hit[y * N + x]
		cover[y] = float(k) / N
		top = maxf(top, cover[y])
	var out := {"layer": 0, "low": lo.y, "craft": size.z, "long": size.x, "ruts": [], "kind": "nothing on the ground"}
	if top <= 0.0:
		return out
	var runs := []                               # [first line, last line] of each run that touches (a one-line hole: none)
	for y in N:
		if cover[y] < 0.3 * top:
			continue
		if not runs.is_empty() and y - int(runs[-1][1]) <= 2:
			runs[-1][1] = y
		else:
			runs.append([y, y])
	var line := size.z / N
	var ruts := []                               # [its middle from the model's middle line (z), its width]
	var first: Array = runs[0]
	var last: Array = runs[-1]
	var whole := (int(last[1]) - int(first[0]) + 1) * line
	if runs.size() >= 2 and (int(last[0]) - int(first[1]) - 1) * line >= 0.1 * whole:
		for r: Array in [first, last]:
			ruts.append([lo.z + (int(r[0]) + int(r[1]) + 1) * 0.5 * line, clampf((int(r[1]) - int(r[0]) + 1) * line, 0.06, 0.3 * whole)])
		out["kind"] = "its left and right"
	elif whole < 0.2 * size.z:
		ruts.append([lo.z + (int(first[0]) + int(last[1]) + 1) * 0.5 * line, maxf(whole, 0.06)])
		out["kind"] = "one keel"
	else:
		var w := maxf(RUT * whole, 0.06)
		ruts.append([lo.z + int(first[0]) * line + w * 0.5, w])
		ruts.append([lo.z + (int(last[1]) + 1) * line - w * 0.5, w])
		out["kind"] = "a flat hull's two edges"
	var reach := 0.0
	var mean := 0.0
	for r in ruts:
		reach = maxf(reach, absf(float(r[0])) + float(r[1]) * 0.5)
		mean += float(r[1]) / ruts.size()
	var wide := (reach + maxf(0.05, 0.12 * reach)) * 2.0
	var img := Image.create(ATLAS, ATLAS, false, Image.FORMAT_L8)
	for y in ATLAS:
		var zz := ((y + 0.5) / ATLAS - 0.5) * wide
		var in_rut := 0.0
		for r in ruts:
			in_rut = maxf(in_rut, clampf((float(r[1]) * 0.5 - absf(zz - float(r[0]))) / (wide / ATLAS) + 0.5, 0.0, 1.0))
		if in_rut <= 0.0:
			continue
		for x in ATLAS:
			# the tread: a bar pressed in over nearly half of each length, the ground between less so
			var bar := clampf((0.24 - absf((x + 0.5) / ATLAS - 0.5)) * 12.0 + 0.5, 0.0, 1.0)
			img.set_pixel(x, y, Color(in_rut * (0.62 + 0.38 * bar), 0, 0))
	out["layer"] = _layer(img)
	out["wide"] = wide
	out["period"] = clampf(mean * 1.5, 0.18, 0.6)
	out["ruts"] = ruts
	return out


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


# blown dust (the wake of a craft held clear of the ground): a soft streak along its way, strongest in its middle,
# combed into fine lines along it that swell and thin (one DUST_LEN of them, then again)
func _dust_shape() -> void:
	var img := Image.create(ATLAS, ATLAS, false, Image.FORMAT_L8)
	for y in ATLAS:
		var d := absf((y + 0.5) / ATLAS - 0.5) * 2.0
		var soft := pow(maxf(0.0, 1.0 - d * d), 1.5)
		for x in ATLAS:
			var u := (x + 0.5) / ATLAS * TAU
			var wisp := 0.8 + 0.1 * sin(y * 1.9 + 0.8 * sin(u)) * sin(y * 0.7 + 1.3) + 0.1 * sin(u + y * 0.35)
			img.set_pixel(x, y, Color(clampf(soft * wisp, 0.0, 1.0), 0, 0))
	shapes["dust"] = {"layer": _layer(img), "period": DUST_LEN}


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


# the next place of the ring (the oldest mark's once it has gone round)
func _take() -> int:
	var i := next
	next = (next + 1) % MAX
	used = mini(used + 1, MAX)
	node.multimesh.visible_instance_count = used
	node.visible = true
	stamps += 1
	return i


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
	var i := _take()
	mm.set_instance_transform(i, Transform3D(Basis(x * half_x * 2.0, up * thick * 2.0, z * half_z * 2.0), pos))
	mm.set_instance_custom_data(i, Color(float(layer), now, float((i * 37) % 101) / 10.0, s))
	mm.set_instance_color(i, Color(0, 0, 0, 0))    # (a single mark, not a stretch of ruts)
	newest = now
	if debug:
		print("fx track: layer ", layer, " at ", pos, " ", half_x, " x ", half_z, " strength ", s)
