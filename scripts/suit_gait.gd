extends RefCounted
# The game's own walk of a power suit, for the suits it does not pose (Live: beyond its draw distance, out of its
# view, the player's own): its code ported, not an imitation. The game keeps no animation: each picture it moves the
# pelvis with the suit (0x280a84: its height over the ground, lowered by a stretched leg, sprung after a jump or a
# change of stance; the torso leaning with the speed), and the feet step on their own: a foot is planted where it was
# set down until it trails the body by half a stride (0x27f658), then swings in a straight line with a parabola's lift
# (0x27e678) to where the body will be when the other foot trails in turn (0x280364: so the cadence follows the
# speed, with no clock of its own). Three paces from the speed against sqrt(leg x gravity) (0x281f58): standing
# (the feet step back under a body that turns or shifts, 0x280254), walking (stride = 0.9 x thigh + shin), and
# faster the stride grows with the speed; from 1.5 x that speed, forwards, each step is a kick up under the body
# (a shin high) then a reach down ahead. The knees (0x27f2a4: two bones, bent towards the foot's front), the toes
# (0x27fb28) and the arms (0x28059c: each one swung by the opposite foot, the forearm bent more at speed) it only
# computes when it draws the suit, then lifts each arm towards where its weapon aims (0x29c61e). In the air (pelvis above the leg's length) the feet hang under the body (0x27ffdc).
# Game axes: x, y on the ground, z up; angles in radians (a = the game's 16-bit turn x TAU / 65536); seconds.
# Joints: 0/1 toes, 2/3 ankles, 4/5 knees, 6/7 hips, 8 pelvis, 9 neck, 10/11 shoulders, 12/13 elbows, 14/15 hands
# (even = the left side, the one towards (sin, -cos) of the heading).

const A16 := TAU / 65536.0
const TIE := 0.0001                            # feet level: the second one steps first (the game's exact equality)
const FULL := 99                               # a "size on screen" (see detail) that passes all the game's tests

# the soldier's own constants, as its game record has them (the bridge's GAIT packet, live_bridge.py allures)
var torso := 0.18
var shup := 0.87                               # the shoulders' height along the torso
var shw := 0.16
var hipw := 0.0625
var uarm := 0.09
var farm := 0.1
var thigh := 0.138
var shin := 0.138
var footh := 0.042                             # the ankle above the sole
var f1 := 0.074                                # ankle to toe, flat
var f5 := 0.034
var lead := 0.3                                # how far along the lean the feet are placed
var toeout := -0.196
var walk := 0.13                               # speeds (units a second): above, walking
var run := 0.77                                # above, the stride grows
var reach := 0.25
var w217 := 0.0625                             # the feet's gap, walking
var zoff := 0.1458                             # the entity above its feet
var legtot := 0.32
var ts := 0.276                                # thigh + shin
var kneesign := 1
var flat := false
var player := false
var glances := true                           # a standing suit looks aside now and then (off: the tests)
# each arm's aim, set by the game's AI: turn from the heading, pitch (-90 degrees = down), share (0: none) - left, right
var aim := PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0, 0.0])

var J: Array[Vector3] = []
var l_yaw := [0.0, 0.0]                        # each foot: its turn, the heel's end, at rest since its last step
var l_c := [1.0, 1.0]
var l_s := [0.0, 0.0]
var l_heel: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var l_flag := [0, 0]
var l_ref: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]   # each leg's reference vector for its limbs' views (0x27f2a4)
var l_start := [0.0, 0.0]                      # its step: start, duration, lift, from, to (the ankle), state (0 due,
var l_dur := [0.0, 0.0]                        # 1 under way, 2 done), kind (1 cut short, 2 on the spot, 3 walking,
var l_lift := [0.0, 0.0]                       # 4 kick up, 5 reach down, 6 put under the body)
var l_from: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var l_to: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO]
var l_state := [2, 2]
var l_type := [0, 0]

var state := 0                                 # 0 on the ground, 1 sprung, 2 in the air
var lod := 0
# The suit's height on the game's screen in its pixels (the game's dword +5, 0x2820a4): what it does depends on it.
# Under 4 it does not walk the suit at all (never here: 5 at least); up to 6 the feet go where their steps put them,
# however far (the legs stretch); from 7 an ankle out of reach is pulled in; up to 15 the knees are half way between
# hip and ankle, the feet flat, the arms hang with the forearms straight ahead; from 16 the knees are solved and the
# arms swing. With TN+'s 848 x 480: 16 pixels at 8.5 units, 7 at 19, 4 at 34.
var detail := FULL
var started := false
var bodyh := 0.0
var lean := 0.0
var look := 0.0
var turn := 0.0
var pz := 0.0
var vz := 0.0
var vzc := 0.0
var cls := 0
var speed := 0.0
var tv := Vector3.ZERO
var g := 0.0
var target := 0.0
var fwdness := 0.0
var half := 0.0
var lift := 0.0
var width := 0.0
var ref := Vector2.ZERO
var now := 0.0
var dt := 0.0
var vx := 0.0
var vy := 0.0
var dx := 0.0
var dy := 0.0
var c := 1.0
var s := 0.0
var stance := 0
var hf_was := -1.0
var ground := Callable()                       # (x, y) -> the ground's height
var prev := Vector4.ZERO
var ent_h := 0.0                               # the entity's own heading (the body's may trail it, or glance aside)
var stand := Vector2(0.9, 0.0)                 # crouching or lying: the height factor and lean it stood with
var stood := false                             # it got up to move (0x281151)


func _init() -> void:
	J.resize(16)
	J.fill(Vector3.ZERO)


# the bridge's values for this soldier (22 floats, then knee side and flat feet)
func setup(v: PackedFloat32Array, knee: int, flat_feet: bool, is_player: bool) -> void:
	torso = v[0]
	shup = v[1]
	shw = v[2]
	hipw = v[3]
	uarm = v[4]
	farm = v[5]
	thigh = v[6]
	shin = v[7]
	footh = v[8]
	f1 = v[9]
	f5 = v[10]
	lead = v[11]
	toeout = v[12]
	walk = v[13]
	run = v[14]
	reach = v[15]
	w217 = v[16]
	zoff = v[17]
	legtot = v[18]
	ts = v[19]
	kneesign = knee
	flat = flat_feet
	player = is_player


# One picture: the suit at x, y, z (its entity), heading h, dt after the last one, at the clock now; hf, lean_t and
# stance as the game's own code sets them (height factor, lean wanted, 0 standing / 1 crouching / 2 lying). vel: its
# speed when known from elsewhere (else from its last place, as the game does). Long pictures are cut up (0x2814e4).
func step(x: float, y: float, z: float, h: float, d: float, t: float, hf: float, lean_t: float, st: int, vel = null) -> void:
	if not started:
		started = true
		bodyh = h
		lean = lean_t
		now = t
		_cheap(x, y, z, h, hf)
		lod = FULL
		prev = Vector4(x, y, z, h)
		hf_was = hf
	# crouching or lying, a suit that moves off gets up, as the game makes one it draws (0x281151): until its AI
	# changes its stance again
	if st == 0:
		stood = false
	elif stood:
		hf = stand.x if stand.x > 0.3 else 0.9
		lean_t = stand.y
		st = 0
	if hf != hf_was or st != stance:                  # a change of stance: sprung (0x27e99c and the like)
		hf_was = hf
		state = 1
	if d > 0.1:
		var n := int(ceil(d / 0.1))
		var sub := d / n
		for k in range(1, n):
			var a := float(k) / n
			_update(lerpf(prev.x, x, a), lerpf(prev.y, y, a), lerpf(prev.z, z, a), lerp_angle(prev.w, h, a), sub, t - d + sub * k, hf, lean_t, st, vel)
			lod = FULL
		d = sub
	_update(x, y, z, h, d, t, hf, lean_t, st, vel)
	prev = Vector4(x, y, z, h)


# the joints of the picture (what the game does when it draws the suit: feet along their steps, knees, toes, arms)
func pose() -> void:
	lod = maxi(detail, 5)
	c = cos(bodyh)
	s = sin(bodyh)
	for leg in 2:
		if l_state[leg] == 1:
			_interp(leg)
			_knee(leg)
			_toe(leg, flat)
		else:
			_knee(leg)
			if l_flag[leg] == 0:
				_toe(leg, flat)
	_arms()
	_aim(0, aim[0], aim[1], aim[2])
	_aim(1, aim[3], aim[4], aim[5])


# From a pose the game drew (joints in game axes, the suit heading h at the clock t, moving at vel): the walk goes on
# from it, the feet on the ground planted where they are, a foot in the air carried on to where the game's own step
# was taking it (the same rule: where the body will be when the other foot trails by half a stride).
func take_over(joints: Array, h: float, t: float, vel: Vector2, hf: float, lean_t: float, st: int) -> void:
	started = true
	now = t
	stance = st
	hf_was = hf
	bodyh = h
	ent_h = h
	c = cos(h)
	s = sin(h)
	for j in 16:
		J[j] = joints[j]
	pz = J[8].z
	vz = 0.0
	vzc = 0.0
	g = ground.call(J[8].x, J[8].y)
	target = hf * legtot
	state = 2 if pz - g > legtot else 0
	tv = J[9] - J[8]
	lean = clampf(atan2(tv.x * c + tv.y * s, maxf(tv.z, 0.001)), -1.0, 1.0)
	turn = 0.0
	vx = vel.x
	vy = vel.y
	speed = vel.length()
	dx = vx / speed if speed > 0.0 else 0.0
	dy = vy / speed if speed > 0.0 else 0.0
	cls = 2 if speed > run else (1 if speed > walk else 0)
	ref = Vector2(J[8].x + tv.x * lead, J[8].y + tv.y * lead)
	_params()
	var up := [0.0, 0.0]
	for leg in 2:
		var a: Vector3 = J[2 + leg]
		up[leg] = a.z - footh - ground.call(a.x, a.y)
		var yaw := h + (toeout if leg == 0 else -toeout)
		var toe: Vector3 = J[leg]
		if Vector2(toe.x - a.x, toe.y - a.y).length() > 0.3 * f1:
			yaw = atan2(toe.y - a.y, toe.x - a.x)
		l_yaw[leg] = yaw
		l_c[leg] = cos(yaw)
		l_s[leg] = sin(yaw)
		l_heel[leg] = Vector3(toe.x - l_c[leg] * (f1 + f5), toe.y - l_s[leg] * (f1 + f5), toe.z)
		l_to[leg] = a
		l_from[leg] = a
		l_start[leg] = t
		l_dur[leg] = 0.0
		l_lift[leg] = 0.0
		l_state[leg] = 2
		l_type[leg] = 3
		l_flag[leg] = 1
	prev = Vector4(J[8].x, J[8].y, J[8].z, h)
	lod = maxi(detail, 5)
	if state != 0 or cls == 0:
		return
	if half <= 0.0:
		return
	if run * 1.5 <= speed and fwdness >= 0.8:
		_take_run()
		return
	# walking. A foot clearly off the ground (the higher one): its step goes on. The game's step ends when the planted
	# foot trails the body by half a stride, at a place set by the body's speed: the same end and place found again
	# from the pose; how far along it the foot is, from where it is against the body (it left half a stride behind),
	# so its rise goes on along the same curve
	var sw := 0 if up[0] > up[1] else 1
	if up[sw] < 0.012:
		return
	var o: Vector3 = l_to[1 - sw]
	var other := (o.x - ref.x) * dx + (o.y - ref.y) * dy
	var p1: Vector3 = J[2 + sw]
	var mine := (p1.x - ref.x) * dx + (p1.y - ref.y) * dy
	var tau := 0.0
	var left := half + other
	if left > 0.0 and mine < half - 0.001:
		var gone := maxf((mine + half) * left / (half - mine), 0.0)
		tau = gone / (left + gone)
	_new_step(sw, other, 0.0, 3)
	var to: Vector3 = l_to[sw]
	var rest := maxf(l_dur[sw], 0.04)
	l_from[sw] = p1
	l_start[sw] = t
	l_dur[sw] = rest
	l_state[sw] = 1
	if tau < 0.03 or tau > 0.97:
		l_lift[sw] = 0.0
		return
	var k := tau / (1.0 - tau)
	var fr := Vector3(p1.x - (to.x - p1.x) * k, p1.y - (to.y - p1.y) * k, 0.0)
	fr.z = ground.call(fr.x, fr.y) + footh
	var zt: float = lerpf(fr.z, to.z, tau) + 4.0 * l_lift[sw] * (0.25 - (tau - 0.5) * (tau - 0.5))
	if absf(zt - p1.z) > 0.03:
		l_lift[sw] = 0.0                              # (not where that step would have it: straight on from here)
		return
	l_from[sw] = fr
	l_dur[sw] = rest / (1.0 - tau)
	l_start[sw] = t - l_dur[sw] * tau


# Running (take_over): in the game's run one foot is always in a step, a kick up under the body then a reach down far
# ahead, while the other stays where it came down: half a stride ahead of the body, out of the leg's reach, so the
# game draws it pulled in at 0.95 of the leg (in the air), leaves it there while the body passes over, then drags it
# behind. Steady, the whole pose depends on one number, how far the body has gone since the kick began (0 to a
# stride): the pose is matched against that cycle, for either foot stepping, and the steps set as the game has them
# at that point.
func _take_run() -> void:
	# (the stride follows the speed, known here a moment late: a suit slowing down or speeding up is also tried with
	# strides from 0.6 to 1.2 of it, the nearest kept for the steps under way)
	var half_now := half
	var fit := [1e9, 0.0, 0, 1.0]
	for k in [1.0, 0.9, 1.1, 0.8, 1.2, 0.7, 0.6]:
		half = half_now * k
		var r := _fit_run()
		var e: float = float(r[0]) + 0.0004 * absf(k - 1.0)   # (a slight lean towards the stride of its speed)
		if e < fit[0]:
			fit = [e, r[1], r[2], k]
	half = half_now * float(fit[3])
	_set_run(fit[1], fit[2])
	half = half_now


# the pose against the run's cycle with the stride as it is: [gap squared, way since the kick began, stepping foot]
func _fit_run() -> Array:
	var fo := f5 - f1                                # the ankle against the foot's goal
	var hip_x := (J[8].x - ref.x) * dx + (J[8].y - ref.y) * dy
	var hip_z := pz - (g + footh)
	var maxr := 0.95 * ts if maxi(detail, 5) > 6 else 1000.0   # (seen small, the game leaves the feet where their steps are)
	var d4 := half + fo + shin / 3.0               # the body's way during the kick (until the planted foot is a third
	var d5 := half - shin / 3.0                    # of a shin behind), then during the reach (until it is half a stride)
	var obs := []
	for leg in 2:
		var a: Vector3 = J[2 + leg]
		obs.append(Vector2((a.x - ref.x) * dx + (a.y - ref.y) * dy, a.z - (g + footh)))
	var steps := 48
	var best := [1e9, 0.0, 0]
	var pa := Vector2(half + fo, 0.0)                # the planted foot as it came down, against the body then:
	var hip0 := Vector2(hip_x, hip_z)                # pulled in along its leg
	if pa.distance_to(hip0) > maxr:
		pa = hip0 + (pa - hip0) * (maxr / pa.distance_to(hip0))
	for n in steps:
		var u := (d4 + d5) * (n + 0.5) / steps
		var hip := Vector2(hip_x + u, hip_z)         # (places against where the body was when the kick began)
		if pa.distance_to(hip) > maxr:
			pa = hip + (pa - hip) * (maxr / pa.distance_to(hip))   # dragged
		var pb := _run_foot(u, d4, d5, fo) + Vector2(u, 0.0)
		if pb.distance_to(hip) > maxr:
			pb = hip + (pb - hip) * (maxr / pb.distance_to(hip))
		var qa := pa - Vector2(u, 0.0)
		var qb := pb - Vector2(u, 0.0)
		for sw in 2:
			var e: float = qb.distance_squared_to(obs[sw]) + qa.distance_squared_to(obs[1 - sw])
			if e < best[0]:
				best = [e, u, sw]
	return best


# the steps of the run's cycle, u after the kick of foot sw began: the planted foot's true place (on the ground, half
# a stride less u ahead), the stepping one's step
func _set_run(u: float, sw: int) -> void:
	var fo := f5 - f1
	var d4 := half + fo + shin / 3.0
	var d5 := half - shin / 3.0
	var pl := 1 - sw
	_place(pl, half - u, 0.0)
	l_from[pl] = l_to[pl]
	l_type[pl] = 5
	l_state[pl] = 2
	l_flag[pl] = 1
	lift = shin * (minf((speed - run) / run, 1.0) + 0.25)
	if u < d4:
		_place(sw, -half - fo - u, 0.0)
		l_from[sw] = l_to[sw]
		_place(sw, d4 - u, shin)
		l_start[sw] = now - u / speed
		l_dur[sw] = d4 / speed
		l_lift[sw] = lift * 0.5
		l_type[sw] = 4
	else:
		_place(sw, d4 - u, shin)
		l_from[sw] = l_to[sw]
		_place(sw, 3.0 * half + fo - u, 0.0)
		l_start[sw] = now - (u - d4) / speed
		l_dur[sw] = d5 / speed
		l_lift[sw] = 0.0
		l_type[sw] = 5
	l_state[sw] = 1
	l_flag[sw] = 0


# the stepping foot's ankle in the run, u after its kick began: (ahead of the body, above its place on the ground)
func _run_foot(u: float, d4: float, d5: float, fo: float) -> Vector2:
	if u < d4:
		var k := u / d4
		var up := shin * (minf((speed - run) / run, 1.0) + 0.25) * 0.5
		return Vector2(-half + (half + fo) * k, shin * k + 4.0 * up * (0.25 - (k - 0.5) * (k - 0.5)))
	var k5 := (u - d4) / d5
	return Vector2(fo + half * k5, shin * (1.0 - k5))


# a foot's ankle put along ahead of the body's point on its side, up above the ground there (into l_to)
func _place(leg: int, along: float, up: float) -> void:
	var w := -w217 * 0.5 if leg == 0 else w217 * 0.5
	var vec := _toeyaw(leg, 0.0)
	var x := ref.x - s * w + dx * along
	var y := ref.y + c * w + dy * along
	l_to[leg] = Vector3(x + vec.x, y + vec.y, float(ground.call(x, y)) + up + vec.z)


# ---------------------------------------------------------------------------------------------- the game's routines
func _cheap(x: float, y: float, z: float, h: float, hf: float) -> void:        # 0x27ee34
	bodyh = h
	c = cos(h)
	s = sin(h)
	g = z - zoff
	target = hf * legtot
	pz = z + target - zoff
	J[8] = Vector3(x, y, pz)
	tv = Vector3(0.0, 0.0, torso)
	J[9] = J[8] + tv
	ref = Vector2(x, y)
	width = w217
	var hw := hipw * 0.5
	J[6] = Vector3(x + s * hw, y - c * hw, pz)
	J[7] = Vector3(x - s * hw, y + c * hw, pz)
	_stand_feet()
	lod = 0


func _update(x: float, y: float, z: float, h: float, d: float, t: float, hf: float, lean_t: float, st: int, vel) -> void:   # 0x280a84
	now = t
	dt = d
	stance = st
	ent_h = h
	if not player and lod < 4:
		_cheap(x, y, z, h, hf)
		return
	if vel != null:
		vx = vel.x
		vy = vel.y
	else:
		vx = (x - J[8].x) / d
		vy = (y - J[8].y) / d
	speed = Vector2(vx, vy).length()
	if not player and (st != 0 or speed < 0.0015):
		# standing: now and then a glance up to 22.5 degrees aside, the body turning after it (the game: one chance in
		# 32 and 3 degrees at most a picture; TN+, which Live runs with, makes both per second: 0.625 a second, 60
		# degrees a second, 0x280c58 / 0x280cb4)
		if glances and randf() < d * 0.625:
			look = float(randi_range(-0x800, 0x7ff)) * 2.0 * A16
		h = bodyh + clampf(angle_difference(bodyh, h + look), -d * TAU / 6.0, d * TAU / 6.0)
		turn = 0.0
	else:
		turn = angle_difference(bodyh, h) / d
	bodyh = h
	c = cos(h)
	s = sin(h)
	g = ground.call(x, y)
	var e := maxf(z - g - 0.05615, zoff)
	target = hf * legtot
	var tz := e + g + target - zoff
	var f4 := 0.0
	if state == 1:
		f4 = vz
		pz += vz * d
		if pz - g < target * 0.5:
			pz = g + target * 0.5
		elif pz - tz > 0.01666:
			pz = tz + 0.01666
		# (the game: 128 x the gap x dt, then an eighth lost each picture; here per 1 / 70 s, its usual picture)
		vz = (vz + (tz - pz) * d * 128.0) * pow(0.875, d * 70.0)
	else:
		f4 = (tz - pz) / d
		vz = f4
		pz = tz
	if pz - g > legtot:
		state = 2
	elif state == 2:
		state = 1 if vzc < -2.0 else 0
	elif state == 1:
		if f4 >= 0.0 and absf(pz - tz) < 0.05:
			state = 0
	var hw := hipw * 0.5
	J[6] = Vector3(x + s * hw, y - c * hw, 0.0)
	J[7] = Vector3(x - s * hw, y + c * hw, 0.0)
	if state == 0 and cls <= 1:
		# a planted leg stretched out lowers the pelvis (a quarter of what it lacks)
		var k := 1 if l_state[1] != 1 else 0
		var hip: Vector3 = J[6 + k]
		var a: Vector3 = J[2 + k]
		var d2 := (hip.x - a.x) * (hip.x - a.x) + (hip.y - a.y) * (hip.y - a.y)
		pz -= clampf(legtot - sqrt(maxf(legtot * legtot - d2, 0.0)), 0.0, shin) * 0.25
	J[8] = Vector3(x, y, pz)
	J[6] = Vector3(J[6].x, J[6].y, pz)
	J[7] = Vector3(J[7].x, J[7].y, pz)
	dx = vx / speed if speed > 0.0 else 0.0
	dy = vy / speed if speed > 0.0 else 0.0
	var old := cls
	cls = 2 if speed > run else (1 if speed > walk else 0)
	if cls != 0 and st != 0:
		stood = true                                  # (from the next picture on, see step)
		state = 1
	# the torso leans with the speed forwards (a turn / 50 per unit a second), 4.5 degrees a picture at most
	var want := (dx * c + dy * s) * speed * TAU / 50.0 + lean_t - lean
	lean += clampf(want, -0x333 * A16, 0x333 * A16)
	var tl := sin(lean) * torso
	tv = Vector3(tl * c, tl * s, cos(lean) * torso)
	vzc = vz
	J[9] = J[8] + tv
	for i in 2:
		if _finish(i):
			l_flag[i] = 1
	for i in 2:
		if l_state[i] != 1:
			continue
		# a step under way is cut short when the suit slows down a pace, or when its goal falls behind the body
		var cut := false
		if old - cls > 0:
			cut = true
		elif cls > 0 and l_type[i] != 4:
			cut = (l_to[i].x - x) * dx + (l_to[i].y - y) * dy < 0.0
		if cut:
			_interp(i)
			_freeze(i)
			l_type[i] = 1
	if state != 0 or (l_state[0] != 1 and l_state[1] != 1):
		ref = Vector2(x + tv.x * lead, y + tv.y * lead)
		_params()
		_choose()
	lod = 0


func _finish(i: int) -> bool:                                                  # 0x27e514
	if l_state[i] == 2:
		return false
	var el: float = now - l_start[i]
	if el >= l_dur[i]:
		J[2 + i] = l_to[i]
		l_state[i] = 2
		l_lift[i] = 0.0
		_toe(i, true)
		return true
	if el >= 0.0 and l_state[i] != 1:
		l_state[i] = 1
	return false


func _interp(i: int) -> void:                                                  # 0x27e678
	if l_state[i] == 2:
		return
	var el: float = now - l_start[i]
	if el >= l_dur[i]:
		J[2 + i] = l_to[i]
		return
	if el < 0.0:
		return
	var t: float = el / l_dur[i]
	var p: Vector3 = l_from[i].lerp(l_to[i], t)
	if l_lift[i] > 0.0:
		p.z += 4.0 * l_lift[i] * (0.25 - (t - 0.5) * (t - 0.5))
	J[2 + i] = p


func _freeze(i: int) -> void:                                                  # 0x27e470
	l_to[i] = J[2 + i]
	l_dur[i] = 0.0
	l_state[i] = 2
	l_start[i] = now
	_toe(i, flat)
	l_flag[i] = 0


func _params() -> void:                                                        # 0x27e778
	var stride := 0.0
	if speed > run:
		stride = reach * speed / run
		lift = shin * (minf((speed - run) / run, 1.0) + 0.25)
	elif speed > walk:
		lift = shin * 0.25
		stride = reach
	else:
		lift = footh
	if cls >= 1 and state == 0:
		fwdness = dx * c + dy * s
		stride *= (maxf(fwdness, 0.0) + 1.0) * 0.5
		width = w217
	else:
		width = (hipw + shw) * 0.5
	half = stride * 0.5


func _choose() -> void:                                                        # 0x27f658
	if state == 2 or (state == 1 and stance == 0):
		_stand_feet()
		return
	if cls >= 1:
		var p0: float = (l_to[0].x - ref.x) * dx + (l_to[0].y - ref.y) * dy
		var p1: float = (l_to[1].x - ref.x) * dx + (l_to[1].y - ref.y) * dy
		if l_type[0] == 4:
			_new_step(0, p1, now - (l_start[0] + l_dur[0]), 5)
			return
		if l_type[1] == 4:
			_new_step(1, p0, now - (l_start[1] + l_dur[1]), 5)
			return
		var m := minf(p0, p1)
		if -m <= half:
			return
		var late := minf((-m - half) / speed, dt)
		var typ := 3 if (run * 1.5 > speed or fwdness < 0.8) else 4
		if p0 < p1 - TIE:
			_new_step(0, p1, late, typ)
		else:
			_new_step(1, p0, late, typ)
		return
	var q0: float = (l_to[0].x - ref.x) * c + (l_to[0].y - ref.y) * s
	var q1: float = (l_to[1].x - ref.x) * c + (l_to[1].y - ref.y) * s
	var b0 := q0 < q1 - TIE
	for i in 2:
		if l_type[i] == 1:
			lift = 0.0
			_idle_step(i)
			return
	for i in 2:
		if l_flag[i] == 0:
			lift = 0.0
			_idle_step(i)
			return
	# the body's point between the feet has left one foot's side, a foot is turned too far from the body, or the
	# point has passed the toes' line or the heels'
	if _cross(J[1] - l_heel[1], ref, l_heel[1]) > 0.0:
		_idle_step(1)
		return
	if _cross(J[0] - l_heel[0], ref, l_heel[0]) < 0.0:
		_idle_step(0)
		return
	var da := [angle_difference(l_yaw[0], bodyh), -angle_difference(l_yaw[1], bodyh)]
	for i in 2:
		if da[i] < -0x1000 * A16:
			_idle_step(i)
			return
	for i in 2:
		if da[i] > 0x2000 * A16:
			_idle_step(i)
			return
	if _cross(J[0] - J[1], ref, J[1]) > 0.0:
		_idle_step(0 if b0 else 1)
		return
	if _cross(l_heel[0] - l_heel[1], ref, l_heel[1]) < 0.0:
		_idle_step(1 if b0 else 0)


func _cross(a: Vector3, r: Vector2, o: Vector3) -> float:
	return a.x * (r.y - o.y) - a.y * (r.x - o.x)


# where a foot is put: beside the body's point, the body carried on for the step's time (returns the turn made then)
func _foot_target(time: float, leg: int, out: Array) -> float:                 # 0x27fed8
	var w := -width * 0.5 if leg == 0 else width * 0.5
	if time != 0.0:
		var yawoff := turn * time
		var a := bodyh + yawoff
		out[0] = Vector3(ref.x - sin(a) * w + vx * time, ref.y + cos(a) * w + vy * time, 0.0)
		return yawoff
	out[0] = Vector3(ref.x - s * w, ref.y + c * w, 0.0)
	return 0.0


func _toeyaw(leg: int, yawoff: float) -> Vector3:                              # 0x27fe10
	var yaw := bodyh + yawoff + (toeout if leg == 0 else -toeout)
	l_yaw[leg] = yaw
	l_c[leg] = cos(yaw)
	l_s[leg] = sin(yaw)
	return Vector3(l_c[leg] * (f5 - f1), l_s[leg] * (f5 - f1), footh)


# the ground under a foot's goal; too high or low for the legs: the step halved, up to 6 times
func _ground_fix(tgt: Vector3, dur: float, out: Array) -> float:               # 0x2800bc
	var d := Vector2(tgt.x - ref.x, tgt.y - ref.y)
	var gz := g
	var k := 0
	while k < 6:
		gz = ground.call(tgt.x, tgt.y)
		if absf(gz - g) <= ts:
			break
		d *= 0.5
		dur *= 0.5
		lift *= 0.5
		tgt.x = ref.x + d.x
		tgt.y = ref.y + d.y
		k += 1
	if k == 6:
		gz = g + ts if gz > g else g
	tgt.z = gz
	out[0] = tgt
	return dur


func _new_step(leg: int, other: float, late: float, typ: int) -> void:         # 0x280364
	var off := Vector2.ZERO
	var dur := 0.0
	if typ == 4:
		dur = (shin / 3.0 + other) / speed
	else:
		dur = (half + other) / speed
		off = Vector2(dx, dy) * half
	if typ == 5:
		lift = 0.0
	var out := [Vector3.ZERO]
	var yawoff := _foot_target(dur, leg, out)
	var vec := _toeyaw(leg, yawoff)
	var tgt: Vector3 = out[0]
	tgt.x += off.x
	tgt.y += off.y
	dur = _ground_fix(tgt, dur, out)
	tgt = out[0]
	if typ == 4:
		lift *= 0.5
		tgt.z += shin
	l_start[leg] = now - late
	l_dur[leg] = dur + late
	l_from[leg] = l_to[leg]
	l_to[leg] = tgt + vec
	l_state[leg] = 0
	l_lift[leg] = lift
	l_type[leg] = typ


func _idle_step(leg: int) -> void:                                             # 0x280254
	var dur := reach / walk / 8.0
	var out := [Vector3.ZERO]
	var yawoff := _foot_target(dur, leg, out)
	var vec := _toeyaw(leg, yawoff)
	dur = _ground_fix(out[0], dur, out)
	l_start[leg] = now
	l_dur[leg] = dur
	l_from[leg] = l_to[leg]
	l_to[leg] = (out[0] as Vector3) + vec
	l_state[leg] = 0
	l_type[leg] = 2
	l_lift[leg] = lift


func _stand_feet() -> void:                                                    # 0x27ffdc
	var out := [Vector3.ZERO]
	for leg in 2:
		var yawoff := _foot_target(0.0, leg, out)
		var z := maxf(J[8].z - target, g)
		var vec := _toeyaw(leg, yawoff)
		var p: Vector3 = out[0]
		J[2 + leg] = Vector3(p.x + vec.x, p.y + vec.y, z + vec.z)
		_freeze(leg)
		l_type[leg] = 6


func _toe(leg: int, flat_now: bool) -> void:                                   # 0x27fb28
	var a: Vector3 = J[2 + leg]
	var lc: float = l_c[leg]
	var ls: float = l_s[leg]
	var lf := f1 + f5
	if flat_now or lod < 15:
		J[leg] = Vector3(a.x + lc * f1, a.y + ls * f1, a.z - footh)
		l_heel[leg] = Vector3(J[leg].x - lc * lf, J[leg].y - ls * lf, J[leg].z)
		return
	# the foot tipped with the shin (a third of its lean)
	var kn: Vector3 = J[4 + leg]
	var k := ((a.x - kn.x) * lc + (a.y - kn.y) * ls) / 3.0
	var dz := a.z - kn.z
	var n := sqrt(k * k + dz * dz)
	if n == 0.0:
		k = 0.0
		dz = -1.0
	else:
		k /= n
		dz /= n
	var u := footh * k - f1 * dz
	var v := footh * dz + f1 * k
	J[leg] = Vector3(a.x + u * lc, a.y + u * ls, a.z + v)
	l_heel[leg] = Vector3(J[leg].x + lf * dz * lc, J[leg].y + lf * dz * ls, J[leg].z - lf * k)


func _knee(leg: int) -> void:                                                  # 0x27f2a4
	var a: Vector3 = J[2 + leg]
	var hip: Vector3 = J[6 + leg]
	var d := a - hip
	var r := d.length()
	var maxr := 0.95 * ts
	if lod <= 6:
		pass
	elif r < 0.0233:
		a.z -= 0.0233
		J[2 + leg] = a
		r = 0.0233
		l_flag[leg] = 0
	elif r > maxr:                                 # out of reach: the foot pulled in at 0.95 of the leg
		d *= maxr / r
		a = hip + d
		J[2 + leg] = a
		l_flag[leg] = 0
		r = d.length()
	if lod <= 15:
		J[4 + leg] = (a + hip) * 0.5
		l_ref[leg] = Vector3(s, -c, 0.0)
		return
	var f := Vector3(l_c[leg], l_s[leg], 0.0)
	var n := d.cross(f)
	n = n.normalized() if n.length() > 0.0 else Vector3(1.0, 0.0, 0.0)
	l_ref[leg] = n
	var ee := thigh * thigh - shin * shin
	var m := (ee / r + r) * 0.5
	var hh := -sqrt(maxf(thigh * thigh - m * m, 0.0)) / r
	if kneesign < 0:
		hh = -hh
	J[4 + leg] = hip + d * ((ee / (r * r) + 1.0) * 0.5) + d.cross(n) * hh


func _arms() -> void:                                                          # 0x28059c
	var hv := Vector3(-s * shw * 0.5, c * shw * 0.5, 0.0)
	var up := tv * shup
	for arm in 2:
		var sh: Vector3 = J[8] + (hv if arm == 1 else -hv) + up
		J[10 + arm] = sh
		if lod <= 15:
			J[12 + arm] = Vector3(sh.x, sh.y, sh.z - uarm)
			J[14 + arm] = Vector3(sh.x + c * farm, sh.y + s * farm, sh.z - uarm)
			continue
		# each arm swung by the opposite foot, hanging 22.5 degrees back; the forearm bent 60 degrees, more at speed
		var foot: Vector3 = J[3 if arm == 0 else 2]
		var fwd := (foot.x - J[8].x) * c + (foot.y - J[8].y) * s
		var ang := atan2(2.0 * fwd, ts) - 0x1000 * A16
		var el := Vector3(sh.x + sin(ang) * uarm * c, sh.y + sin(ang) * uarm * s, sh.z - cos(ang) * uarm)
		var bend := 0x5555 * A16
		if stance == 2:
			bend = 0.0
		elif not player and stance != 1:
			bend = minf(speed * 0.25 * TAU + 0x2aaa * A16, 0x5555 * A16)
		var a2 := ang + bend
		J[12 + arm] = el
		J[14 + arm] = Vector3(el.x + sin(a2) * farm * c, el.y + sin(a2) * farm * s, el.z - cos(a2) * farm)


# The reference vectors the game's limb drawer picks each limb's view from (the suit's record +0x191, one per chain:
# body, right leg, right arm, left leg, left arm): the body's side, and for a leg with solved knees the normal of
# the plane its bones lie in.
func refs() -> Array[Vector3]:
	var side := Vector3(s, -c, 0.0)
	return [side, l_ref[1], side, l_ref[0], side]


# An arm lifted towards its weapon's aim (0x29c61e, after the walk's arms): the upper arm half way from hanging down
# to the aim, the forearm along the aim itself, each by the share the AI gives (the hand follows the elbow).
func _aim(arm: int, yaw: float, pitch: float, share: float) -> void:
	if share <= 0.0:
		return
	var sh: Vector3 = J[10 + arm]
	var d: Vector3 = J[12 + arm] - sh
	var el := sh + _aim_mix(_aim_dir(d.length(), wrapf(yaw, -PI, PI) * 0.5, -PI * 0.5 + fposmod(pitch + PI * 0.5, TAU) * 0.5), d, share)
	var f: Vector3 = J[14 + arm] - J[12 + arm]
	J[12 + arm] = el
	J[14 + arm] = el + _aim_mix(_aim_dir(f.length(), yaw, pitch), f, share)


func _aim_dir(length: float, yaw: float, pitch: float) -> Vector3:                # 0x29c114
	var a := ent_h - yaw
	return Vector3(cos(pitch) * cos(a), cos(pitch) * sin(a), sin(pitch)) * length


func _aim_mix(v: Vector3, d: Vector3, share: float) -> Vector3:                # 0x29c1dc
	if share >= 1.0:
		return v
	var b := d.lerp(v, share)
	return b * (d.length() / b.length()) if b.length() > 0.0 else v
