# The game's shots followed from one state of the running game to the next, for Uplink's optional extras (impact
# marks: fx_marks.gd, light from shots: fx_lights.gd; nothing of this exists unless one of them is asked for).
# A shot is a class 5 entity (its type = the weapon, the game's table 0x395110) that lives until it hits; the game
# then puts an effect (class 6: a spark, a blast) where it hit. Here: "fired" when a shot is first seen, "impact"
# one state after it is gone (the effect that appeared on its path says where it hit; without one, the ground on its
# way), "blast" when one of the game's animated effects appears (fx_def: its type and width).
extends Node

const TNData = preload("res://scripts/tn_data.gd")

signal fired(idx: int, typ: int, pos: Vector3)
signal impact(typ: int, pos: Vector3, on_ground: bool, dir: Vector3)
signal blast(typ: int, pos: Vector3, width: float)

const REACH := 2.5            # a shot gone: the ground looked for this many of its last steps ahead (it flies on
                              # between two states of the game), and at least REACH_MIN
const REACH_MIN := 0.4
const NEAR_GROUND := 0.12     # an impact this close to the ground is on the ground
const EFFECT_SIDE := 0.35     # an effect this close to a gone shot's path is its impact
const THROWN := [2, 3, 13]    # grenades and shells fall in an arc: their impact is where they were last seen

var v: Node                   # the viewer (viewer.gd)
var shots := {}               # entity -> [type, position, the one before, steps seen]
var effects := {}             # entity -> [type, position] of the animated effects in the last state
var gone := []                # shots that left in the last state: [type, position, direction, step], judged at the next
var ents := {}                # the shots and animated effects of the game's last state (viewer.gd _live_units:
                              # entity -> [class, type, active, x, y, z, heading])
var seen := -1
var debug := OS.has_environment("TN_FX_DEBUG")   # tests: what is seen, said in the log


func _process(_dt: float) -> void:
	if v == null or not v.live or v.current.is_empty() or v.live_units_seen == seen:
		return
	seen = v.live_units_seen
	var m: Dictionary = v.current["map"]
	var fresh := []                                    # the effects that appeared in this state
	var now_fx := {}
	for idx in ents:
		var e = ents[idx]
		if e[0] != 6 or e[2] == 0 or e[1] == 28 or e[1] == 29 or e[1] == 31 or e[1] == 32 or e[1] == 33:
			continue
		var p := Vector3(e[3], e[5], e[4])
		now_fx[idx] = [e[1], p]
		var was = effects.get(idx)
		if was == null or was[0] != e[1] or (was[1] as Vector3).distance_to(p) > 0.5:
			fresh.append([e[1], p])
			var fd: Dictionary = v.objects.fx_def(e[1]) if v.objects_ok else {}
			if not fd.is_empty():
				blast.emit(e[1], p, float(fd["width"]))
				if debug:
					print("fx effect: type ", e[1], " width ", fd["width"], " at ", p)
	# the shots gone one state ago: where they hit
	for g in gone:
		var typ: int = g[0]
		var p: Vector3 = g[1]
		var d: Vector3 = g[2]
		var reach := maxf(float(g[3]) * REACH, REACH_MIN)
		var hit = null
		var best := reach + EFFECT_SIDE
		for f in fresh + g[4]:
			var rel: Vector3 = (f[1] as Vector3) - p
			var along := rel.dot(d) if d != Vector3.ZERO else 0.0
			var side := (rel - d * along).length()
			if along > -EFFECT_SIDE and along < best and side < EFFECT_SIDE:
				best = along
				hit = f[1]
		if hit != null:
			var hp: Vector3 = hit
			var gh := TNData.height_at(m, hp.x, hp.z)
			var on := absf(hp.y - gh) < NEAR_GROUND or (THROWN.has(typ) and hp.y - gh < 0.5)
			impact.emit(typ, Vector3(hp.x, gh, hp.z) if on else hp, on, d)
			if debug:
				print("fx impact: weapon ", typ, " at its effect ", hp, " ground ", gh, " on the ground " if on else " off the ground ")
			continue
		var gp = _ground_on(m, p, d, 0.0 if THROWN.has(typ) else reach)
		if gp != null:
			impact.emit(typ, gp, true, d)
		if debug:
			print("fx impact: weapon ", typ, " no effect on its way, ground ", gp, " from ", p, " dir ", d, " step ", g[3])
	gone.clear()
	for idx in shots.keys():
		var s: Array = shots[idx]
		var e = ents.get(idx)
		var left: bool = e == null or e[0] != 5 or e[1] != s[0] or e[2] == 0
		if not left:
			var p := Vector3(e[3], e[5], e[4])
			var step: Vector3 = p - s[1]
			var last: Vector3 = (s[1] as Vector3) - s[2]
			# its slot taken by the next shot: it jumps back, or much further than it flies
			if int(s[3]) > 0 and step.length() > 0.3 and (step.dot(last) < 0.0 or step.length() > 3.0 * last.length() + 1.0):
				left = true
		if left:
			var d: Vector3 = (s[1] as Vector3) - s[2]
			gone.append([s[0], s[1], d.normalized() if d.length() > 0.001 else Vector3.ZERO, d.length(), fresh])
			shots.erase(idx)
	for idx in ents:
		var e = ents[idx]
		if e[0] != 5 or e[2] == 0:
			continue
		var p := Vector3(e[3], e[5], e[4])
		if not shots.has(idx):
			shots[idx] = [e[1], p, p, 0]
			fired.emit(idx, e[1], p)
			if debug:
				print("fx fired: weapon ", e[1], " entity ", idx, " at ", p)
		elif p != shots[idx][1]:
			var s: Array = shots[idx]
			s[2] = s[1]
			s[1] = p
			s[3] = int(s[3]) + 1
	effects = now_fx


# Where a shot gone at p, flying along d, meets the ground within reach (null: it does not; reach 0: only right there)
func _ground_on(m: Dictionary, p: Vector3, d: Vector3, reach: float):
	var h := TNData.height_at(m, p.x, p.z)
	if p.y - h < NEAR_GROUND:
		return Vector3(p.x, h, p.z) if p.y - h > -0.5 else null
	if d == Vector3.ZERO or reach <= 0.0:
		return Vector3(p.x, h, p.z) if p.y - h < 0.5 and reach <= 0.0 else null
	var t0 := 0.0
	var t := 0.0
	while t < reach:
		t = minf(t + 0.08, reach)
		var q := p + d * t
		if q.y <= TNData.height_at(m, q.x, q.z):
			for k in 8:                                # between the last point above and this one
				var mid := (t0 + t) * 0.5
				var qm := p + d * mid
				if qm.y <= TNData.height_at(m, qm.x, qm.z):
					t = mid
				else:
					t0 = mid
			var r := p + d * t
			return Vector3(r.x, TNData.height_at(m, r.x, r.z), r.z)
		t0 = t
	return null
