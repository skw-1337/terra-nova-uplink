# Looking down past the game's limit (an extra on top of the game's look: on unless TN_FX_LOOK_DOWN=0). The game
# stops the head 45 degrees down (0x2c9254; the bridge's look does the same). With this on, the mouse pulled further
# down turns Uplink's camera alone, down to nearly straight under the player: he sees the ground at his feet and his
# own suit's legs and feet (his body, drawn from his own joints: it already stands there for the cockpit's side
# views; here its legs get a round solid each for the main view, legs.gdshader). The game knows nothing of it: its head stays at its limit, its aim and its shots too. A mark shows where
# the game aims (where the shots go) while the view is turned past it. Pulled back up, the view first comes back to
# the game's limit, then the mouse turns the game's head again.
# The bridge says where the game's head is ('HPIT', sent only with the option on); between two of them the head is
# followed here as the bridge moves it (8 units of the game's angle a mouse count, stopped at +/-0x2000).
extends Node

const LEGS = preload("res://legs.gdshader")
const BodyModel = preload("res://scripts/body_model.gd")

const LIMIT := 0x2000                        # the game's head: 45 degrees down (its angle units, 65536 a turn)
const UNIT := 8                              # the bridge: units of the game's angle per mouse count (SENS_Y)
const RAD := TAU / 65536.0 * UNIT            # radians per mouse count
const MAX := 0.75                            # how far past the limit (rad): 43 degrees, 88 down in all
const EYE_CLEAR := 0.07                      # a leg piece whose bone passes this close to the eye: not drawn
# His body (TN_LOOK_DOWN_BODY): "model" a solid model of his suit's legs built from their own pictures (body_model.gd),
# seen as from a head bent over them: the eye comes back and down behind the hips and the view narrows as it goes
# down (the legs fill the picture, as in other games' first person views); "old" the round pieces dressed in the
# legs' front pictures (legs.gdshader), the eye brought over the hips
var body_mode := "old" if OS.get_environment("TN_LOOK_DOWN_BODY") == "old" else "model"
# his legs and feet drawn at all (TN_FX_OWN_BODY, the launcher's "Own body": on unless turned off); off, the view still
# turns past the game's limit and shows the ground only. Set again live by the Esc menu (uplink_menu.gd)
var body_on := OS.get_environment("TN_FX_OWN_BODY") != "0"
const EYE_BACK := 0.0                        # (model) at the lowest: the eye this far behind its place
const EYE_BACK_STAND := 0.0                  # ... and this much more while he stands (his feet in view)
const EYE_DOWN := 0.0                       # ... and this much lower (< 0: higher: the knees and feet in view)
var down_max := float(OS.get_environment("TN_LOOK_DOWN_CAP")) if OS.get_environment("TN_LOOK_DOWN_CAP") != "" else DOWN_MAX   # (tests: another cap)
const DOWN_MAX := 76.0                       # (model) how far down the view goes in all (degrees): further, the eye behind the legs
                                             # looked past them
const FOV_LOW := 0.0                         # ... the view this wide (degrees across)
const BELLY_FROM := 0.25                      # (model) the torso's lowest 30 %: the belly joining the thighs
const BELLY_W := 20.0                        # ... held to this half width (its pictures hold the arms too)
const BELLY_DOME := 6.0                      # ... its top rounded back over this many rows (no flat lid)
const BODY_GAIN := 1.35                      # (model) brighter than the pictures: lit from above, the suit's dark armour went black
const PIECE_FADE := Vector2(0.065, 0.08)       # (model) a piece whose surface comes this near the eye dissolves, whole (a thigh
                                             # swinging up; cut by the camera's near plane its inside showed)
const THIGH_TAPER := 0.75                    # (model) the thighs' tops held to this much of their middle
const THIGH_SLIM := 0.72                      # (model) the thighs this slim, their hip pads held to their middle
const THIGH_TOP := 0.6
const THIGH_DARK := 0.6                       # ... their back and side pictures this much towards the armour's grey
var stand_k := 1.0                            # how much he stands (eased)
var last_pos := Vector3.ZERO
var size_set := -1.0                          # the camera's width last set here (another: the viewer's own again)
var size_base := 0.0
const BACK := 0.9                            # at the lowest, the eye this far back from the game's to over the hips
const TEST := "TN_LOOK_DOWN_TEST"            # tests: "start,rate[,hold]" = from that second on, the mouse pulled down for
                                             # 3 s at that many counts a second, held 3 s (or hold), pulled back up 3 s

var v: Node                                  # the viewer
var extra := 0.0                             # the camera's turn past the game's limit (rad, <= 0: down)
var head := 0                                # the game's head as followed here (its units, > 0: down)
var known := false                           # the bridge told it once
var moved := -1000.0                         # when the mouse last moved it (s)
var shown := false                           # the legs are shown
var legs := []                               # their solids (children of the body's leg pieces)
var legs_of: Node3D                          # the body they were made for
var mark: Control
var test_t := -1.0

# the co-op guest's window (setup_guest): his look is his bridge's own (coop_guest.py: 0.003 rad a mouse count, stopped 0.9
# rad down), not the game's head; his head is then counted here in mouse counts and set again from his view's pitch
# whenever the mouse rests (his gamepad turns it too)
var guest := false
var lim := LIMIT                             # the head's stop, in its units
var unit := UNIT                             # its units a mouse count
var rad := RAD                               # radians a mouse count
var max_extra := MAX


func setup_guest() -> void:
	guest = true
	unit = 1
	rad = 0.003
	lim = int(round(0.9 / rad))
	max_extra = minf(MAX, PI / 2.0 - 0.04 - 0.9)       # (down to nearly straight under him, as the host)
	_cap()
	known = true


func _ready() -> void:
	_cap()
	var cl := CanvasLayer.new()
	cl.layer = 19                            # over the game's HUD, under Uplink's own lines
	add_child(cl)
	mark = Control.new()
	mark.set_anchors_preset(Control.PRESET_FULL_RECT)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark.draw.connect(_draw_mark)
	mark.visible = false
	cl.add_child(mark)


# the bridge: the game's head pitch (its units)
func head_is(units: int) -> void:
	if not known or Time.get_ticks_msec() / 1000.0 - moved > 0.2:
		head = units
	known = true


# The mouse moved dy counts down (< 0: up) in the look mode. Returns what goes to the game; the rest turns the
# camera past the limit.
func take(dy: float) -> float:
	if not known or v.menu_mode:
		return dy
	moved = Time.get_ticks_msec() / 1000.0
	if dy > 0.0:
		var room := maxf(0.0, float(lim - head) / unit - maxf(v.play_dy, 0.0))   # counts left before the limit
		var to_game := minf(dy, room)
		extra = maxf(extra - (dy - to_game) * rad, -max_extra)
		return to_game
	if extra < 0.0:
		extra -= dy * rad
		if extra > 0.0:
			var back := -extra / rad             # what is left of the move once the view is back at the limit
			extra = 0.0
			return back
		return 0.0
	return dy


# what the viewer sent the bridge (whole counts): the head moves as the bridge moves it
func sent(dy: int) -> void:
	head = clampi(head + dy * unit, -lim, lim)


func _process(dt: float) -> void:
	if v == null or not v.live:
		return
	if OS.has_environment(TRACE):
		_trace()
	if guest and Time.get_ticks_msec() / 1000.0 - moved > 0.2:
		head = clampi(int(round(-float(v.cam_to[2]) / rad)), -lim, lim)
	if OS.has_environment(TEST) and known:
		_test(dt)
	if OS.has_environment(SWEEP) and known:
		_sweep()
	if extra < 0.0 and (v.menu_mode or v.current.is_empty()):
		extra = 0.0                              # one of the game's screens: the view as the game's
	var on := extra < -0.001
	if on and body_mode == "model":
		_model_eye(dt)
	elif on:
		var k := -extra / max_extra
		# the game's eye is ahead of the suit (its cockpit): looking down from there the legs stood behind the view, at
		# the bottom edge, under the cockpit (two knee tops). The eye comes back over the hips as the view goes down
		# (the viewer puts the camera back on the game's eye every frame)
		var body: Node3D = v.live_player_node
		if body != null and is_instance_valid(body):
			var over := body.global_position
			var cp: Vector3 = v.camera.position
			v.camera.position = Vector3(lerpf(cp.x, over.x, k * BACK), cp.y, lerpf(cp.z, over.z, k * BACK))
	elif size_set > 0.0:
		if is_equal_approx(v.camera.size, size_set):
			v.camera.size = size_base               # (back up: the view's own width again)
		size_set = -1.0
	if on or shown:
		_legs(on and body_on)
	mark.visible = on
	if on:
		mark.queue_redraw()


func _cap() -> void:
	if body_mode == "model":
		max_extra = clampf(deg_to_rad(down_max) - float(lim) / float(unit) * rad, 0.05, max_extra)


# (model) the eye as a head bent over the legs: back and down, the view narrowed, eased in from the game's limit
func _model_eye(dt: float) -> void:
	var k := clampf(-extra / max_extra, 0.0, 1.0)
	var ks := k * k * (3.0 - 2.0 * k)
	var body: Node3D = v.live_player_node
	if body != null and is_instance_valid(body):
		var p := body.global_position
		var sp := Vector2(p.x - last_pos.x, p.z - last_pos.z).length() / maxf(dt, 1e-3)
		last_pos = p
		stand_k = lerpf(stand_k, 1.0 if sp < 0.08 else 0.0, 1.0 - exp(-dt * 4.0))
	var fwd := Vector3(-sin(v.yaw), 0.0, -cos(v.yaw))
	v.camera.position += fwd * (-(EYE_BACK + EYE_BACK_STAND * stand_k) * ks) + Vector3(0.0, -EYE_DOWN * ks, 0.0)
	if FOV_LOW > 0.0 and v.camera.projection == Camera3D.PROJECTION_FRUSTUM and v.camera.near > 0.0:
		if size_set < 0.0 or not is_equal_approx(v.camera.size, size_set):
			size_base = v.camera.size                  # (the viewer's own width, set again by it)
		var fov := 2.0 * atan(size_base / (2.0 * v.camera.near))
		var want := lerpf(fov, deg_to_rad(FOV_LOW), ks)
		size_set = size_base * tan(want * 0.5) / tan(fov * 0.5)
		v.camera.size = size_set


# (old) The player's own legs and feet (joints 0 to 7: toes, ankles, knees, hips) for the main view while it looks past the
# limit. His body's limbs are the game's flat pictures, taken all around each bone and none from above: they stay the
# side views' alone. Each leg piece gets a round solid around its bone instead (legs.gdshader), a child of the limb
# (it takes every pose with it), as thick as the limb's front picture and dressed in it; a foot is flatter than wide.
# The rest of the body (torso, head, arms: around the eye) is not shown.
func _legs(on: bool) -> void:
	shown = on
	var node: Node3D = v.live_player_node
	var ok := node != null and is_instance_valid(node) and node.has_meta("soldier") and node.has_meta("player_body")
	if not ok or node != legs_of:
		for l in legs:
			if is_instance_valid(l):
				l.queue_free()
		legs.clear()
		legs_of = null
		if not ok or not on:
			shown = false
			return
		legs_of = node
		_build(node)
	# a leg piece the eye is inside of (walking, a thigh swings up under the eye brought back over the hips) filled
	# the whole view with its dark inside: hidden while the eye is that close to its bone
	var eye: Vector3 = v.camera.global_position
	for l in legs:
		if is_instance_valid(l):
			var near := false
			var seg := l.get_parent() as Node3D
			if on and seg != null:
				var a: Vector3 = seg.global_position
				var b: Vector3 = a + seg.global_transform.basis.y * float(l.get_meta("bone_px", 0.0))
				var ab := b - a
				var s0 := float(l.get_meta("from", 0.0))
				var s := clampf((eye - a).dot(ab) / maxf(ab.length_squared(), 1e-8), s0, 1.0)
				var d := eye.distance_to(a + ab * s)
				if body_mode == "model":
					# the whole piece dissolves alike (a fade by the pixel's own distance showed the piece's inside through
					# its front's holes)
					var keep := smoothstep(PIECE_FADE.x, PIECE_FADE.y, d - float(l.get_meta("radius", 0.04)))
					l.set_instance_shader_parameter("piece_keep", keep)
					near = keep < 0.03
				else:
					near = d < EYE_CLEAR
			l.visible = on and not near


func _build(node: Node3D) -> void:
	var suit: int = node.get_meta("suit", 0)
	var segs: Array = v.objects.skeleton(suit)
	var parts: Array = node.get_meta("soldier")
	for k in mini(segs.size(), parts.size()):
		var part: Array = parts[k]
		var belly: bool = body_mode == "model" and mini(part[1], part[2]) == 8 and maxi(part[1], part[2]) == 9
		# (model) the whole suit as the others see it, from his eye at its head (as other games' full body views): legs,
		# torso below the neck; not the arms and the weapon pods (his weapon is the game's)
		var upper_arm := false        # (tried: at the eye's sides, dissolving, they hung there as half-seen blobs)
		if maxi(part[1], part[2]) > 7 and not belly and not upper_arm:
			continue
		var seg: MeshInstance3D = part[0]
		var ld: Dictionary = v.objects.limb(suit, segs[k][2], v.pal, v.pal_key)
		if ld.is_empty() or not is_instance_valid(seg):
			continue
		var foot: bool = maxi(part[1], part[2]) <= 3
		var thigh: bool = maxi(part[1], part[2]) in [6, 7]
		var mi := MeshInstance3D.new()
		mi.set_meta("shadow_twin", true)             # (the viewer's passes over a unit's pieces leave it alone)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # (his body's own twins cast its shadow)
		mi.set_instance_shader_parameter("mirror", seg.get_instance_shader_parameter("mirror"))
		if body_mode == "model":
			var m: ArrayMesh
			if belly:
				m = BodyModel.mesh(ld, false, BELLY_FROM, BELLY_W, 0.0, 1.0, BELLY_DOME)
			else:
				m = BodyModel.mesh(ld, float(seg.get_instance_shader_parameter("mirror")) > 0.5, 0.0, 0.0,
						THIGH_TOP if thigh else 0.0, THIGH_SLIM if thigh else 1.0, 0.0, THIGH_TAPER)
			if m == null:
				continue
			mi.mesh = m
			mi.material_override = BodyModel.material(ld)
			mi.set_instance_shader_parameter("back_dark", THIGH_DARK if thigh or belly else 0.0)
			var bb := m.get_aabb()
			mi.set_meta("radius", maxf(bb.size.x, bb.size.z) * 0.5 / 256.0)
			mi.set_meta("from", BELLY_FROM if belly else 0.0)
			mi.set_instance_shader_parameter("mirror", 0.0 if belly else seg.get_instance_shader_parameter("mirror"))
			mi.set_meta("belly", belly)
			mi.set_instance_shader_parameter("gain", BODY_GAIN)
		else:
			if not ld.has("solid"):
				ld["solid"] = _solid(ld, foot)
			var mat := ShaderMaterial.new()
			mat.shader = LEGS
			mat.set_shader_parameter("views", ld["tex"])
			mat.set_shader_parameter("front", float(mini(8, int(ld["views"]) - 1)))
			v._limb_light_set(mat)
			mi.mesh = ld["solid"]
			mi.material_override = mat
			mi.set_instance_shader_parameter("fade_top", 0.6 if thigh else 0.0)   # (a thigh: hip to knee)
		mi.extra_cull_margin = 2.0
		mi.set_meta("bone_px", float(ld["len"]))
		seg.add_child(mi)
		legs.append(mi)


# A limb's solid, in its picture's own space (the limb's node: x its front, y along the bone from joint a, z its
# side, in picture pixels): rings as wide as the picture's opaque part at that height, a foot 0.6 as thick as wide
func _solid(ld: Dictionary, foot: bool) -> ArrayMesh:
	var w := int(ld["size"].x)
	var h := int(ld["size"].y)
	var a1: float = ld["a1"]
	var img: Image = (ld["tex"] as Texture2DArray).get_layer_data(mini(8, int(ld["views"]) - 1))
	var rings := []                                # [y, half width, the middle's z]
	const N := 7
	for r in N:
		var row := clampi(int(lerpf(1.0, h - 2.0, float(r) / (N - 1))), 0, h - 1)
		var lo := w
		var hi := -1
		for x in w:
			if img != null and img.get_pixel(x, row).a > 0.5:
				lo = mini(lo, x)
				hi = maxi(hi, x)
		if hi < lo:
			continue
		rings.append([row - a1, (hi - lo + 1) * 0.5, (lo + hi + 1) * 0.5 - w * 0.5])
	if rings.size() < 2:
		rings = [[0.0, w * 0.25, 0.0], [float(ld["len"]), w * 0.25, 0.0]]
	const SIDES := 10
	var thick := 0.6 if foot else 1.0
	# closed at both ends: a narrower ring, then a point, just beyond
	var first: Array = rings[0]
	var last: Array = rings[-1]
	var ends := [[first[0] - first[1] * 0.35, 0.0, first[2]], [first[0] - first[1] * 0.25, first[1] * 0.6, first[2]]]
	var ends2 := [[last[0] + last[1] * 0.25, last[1] * 0.6, last[2]], [last[0] + last[1] * 0.35, 0.0, last[2]]]
	rings = ends + rings + ends2
	# the picture's rows the solid is dressed in: a little inside its opaque part (its first and last rows are the
	# picture's dark outline: the ends were black lids)
	var inset: float = 0.12 * (last[0] - first[0])
	var v0: float = (first[0] + inset + a1 + 0.5) / h
	var v1: float = (last[0] - inset + a1 + 0.5) / h
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in rings.size() - 1:
		for s in SIDES:
			var quad := []
			for c in [[0, 0], [1, 0], [1, 1], [0, 1]]:
				var ring: Array = rings[r + c[1]]
				var ang := TAU * float(s + c[0]) / SIDES
				var n := Vector3(cos(ang) / thick, 0.0, sin(ang)).normalized()
				var p := Vector3(cos(ang) * ring[1] * thick, ring[0], ring[2] + sin(ang) * ring[1])
				quad.append([p, n, Vector2(0.5 + p.z / w, clampf((p.y + a1) / h, v0, v1))])
			for i in [0, 1, 2, 0, 2, 3]:
				st.set_normal(quad[i][1])
				st.set_uv(quad[i][2])
				st.add_vertex(quad[i][0])
	return st.commit()


# Where the game aims (its head, at the limit): a small ring there; beyond the top of the view, an arrow at its edge
func _draw_mark() -> void:
	var cam: Camera3D = v.camera
	var dir := Basis.from_euler(Vector3(v.pitch, v.yaw, 0.0)) * Vector3(0.0, 0.0, -1.0)
	var at := cam.global_position + dir * 200.0
	var vs := mark.get_viewport_rect().size
	var top := 0.0
	var bottom := vs.y
	if v.hud_win.size.y > 0:                     # the game's 3D window in its cockpit
		top = v.hud_win.position.y / 400.0 * vs.y
		bottom = (v.hud_win.position.y + v.hud_win.size.y) / 400.0 * vs.y
	var s := maxf(1.0, vs.y / 540.0)
	var col := Color(0.3, 1.0, 0.4, 0.95)
	var rim := Color(0.0, 0.0, 0.0, 0.7)
	var p := cam.unproject_position(at)
	if not cam.is_position_behind(at) and p.y > top + 10.0 * s and p.y < bottom:
		mark.draw_arc(p, 7.0 * s, 0.0, TAU, 24, rim, 3.5 * s, true)
		mark.draw_arc(p, 7.0 * s, 0.0, TAU, 24, col, 1.6 * s, true)
		mark.draw_circle(p, 1.6 * s, col)
		return
	var x := clampf(p.x, 20.0 * s, vs.x - 20.0 * s) if not cam.is_position_behind(at) else vs.x * 0.5
	var c := Vector2(x, top + 14.0 * s)
	var tri := PackedVector2Array([c + Vector2(0.0, -8.0 * s), c + Vector2(8.0 * s, 4.0 * s), c + Vector2(-8.0 * s, 4.0 * s)])
	mark.draw_colored_polygon(tri, col)
	mark.draw_polyline(tri + PackedVector2Array([tri[0]]), rim, 1.5 * s, true)


# tests: TN_LOOK_DOWN_SWEEP = "start (Unix time), first angle, step, seconds a step, steps, rounds": the view held at
# that angle down in all (degrees), then the next, round after round (the head first pulled to its limit by TEST)
const SWEEP := "TN_LOOK_DOWN_SWEEP"


func _sweep() -> void:
	var a := OS.get_environment(SWEEP).split_floats(",")
	if a.size() < 6:
		return
	var k := int(floor((Time.get_unix_time_from_system() - a[0]) / a[3]))
	if k < 0 or k >= int(a[4]) * int(a[5]):
		return
	var want := deg_to_rad(a[1] + a[2] * float(k % int(a[4])))
	extra = clampf(-(want - float(head) / float(unit) * rad), -max_extra, 0.0)


func _test(dt: float) -> void:
	var a := OS.get_environment(TEST + "_GUEST" if guest and OS.has_environment(TEST + "_GUEST") else TEST).split_floats(",")
	if a.size() < 2:
		return
	test_t += dt if test_t >= 0.0 else dt + 1.0
	var t := test_t - a[0]
	var rate := 0.0
	var hold := a[2] if a.size() > 2 else 3.0
	if t >= 0.0 and t < 3.0:
		rate = a[1]
	elif t >= 3.0 + hold and t < 6.0 + hold:
		rate = -a[1]
	if rate != 0.0:
		v.play_dy += take(rate * dt)
	if int(t * 2.0) != int((t - dt) * 2.0) and t > -1.0 and t < 7.0 + hold:
		print("look down test: t %.1f head %d extra %.3f rad, view pitch %.1f deg" % [t, head, extra, rad_to_deg(v.camera.rotation.x)])


# tests: TN_BODY_TRACE = a file: each frame, the camera against his body (the view's own suit): time (ms), the body's
# entity, the camera's place, the body's place, its height from the game (ez), on its own steps, in the air, the view
# turned past the limit (rad)
const TRACE := "TN_BODY_TRACE"
var trace_f: FileAccess

func _trace() -> void:
	if trace_f == null:
		trace_f = FileAccess.open(OS.get_environment(TRACE) + ("_guest.csv" if guest else "_host.csv"), FileAccess.WRITE)
		if trace_f == null:
			return
		trace_f.store_line("unix,ms,body,cx,cy,cz,bx,by,bz,ez,gait,gait_y,extra")
	if FileAccess.file_exists(OS.get_environment(TRACE) + ".down"):   # (tests: the view held 70 degrees down meanwhile)
		extra = clampf(-(deg_to_rad(70.0) - float(head) / float(unit) * rad), -max_extra, 0.0)
	var b: Node3D = v.live_player_node
	var c: Vector3 = v.camera.global_position
	var ok := b != null and is_instance_valid(b)
	var p: Vector3 = b.global_position if ok else Vector3.ZERO
	trace_f.store_line("%.3f,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%d,%.4f,%.4f" % [Time.get_unix_time_from_system(), Time.get_ticks_msec(), v.live_player, c.x, c.y, c.z,
			p.x, p.y, p.z, float(b.get_meta("ez", 0.0)) if ok else 0.0, 1 if ok and b.has_meta("gait") else 0,
			float(b.get_meta("gait_y", 0.0)) if ok else 0.0, extra])
	trace_f.flush()
