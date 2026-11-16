# A mission's script made from building blocks, and the installation of a creation's script part.
#
# The script part of a creation (no game data in it):
#   {"patch": [changes],     numbers of the game's own scripts replaced in place (mission_script.gd: change())
#    "build": [specs]}       whole scripts rebuilt from blocks, one per mission
# A spec:
#   {"mission": 18,
#    "objectives": [o1, o2, o3],    each null (not used) or a list of conditions that must ALL hold:
#                                   {"kind": "kill",  "label": L, "pct": P}   P % of the units labelled L destroyed
#                                   {"kind": "alive", "label": L, "pct": P}   P % of them still alive at the end
#                                   {"kind": "idlock", "label": L, "ms": T}   one of them ID-locked for T ms (alone
#                                                                             in its objective, one per mission)
#    "orders": [{"group": g, "order": "patrol", "zones": [a, b, c]} | {"order": "move", "zone": z} |
#               {"order": "hold_zone", "zone": z} | {"order": "attack_group", "target": g2} |
#               {"order": "attack_label", "label": L} | {"order": "follow", "label": L} |
#               {"order": "link", "target": g2}],  given when the group starts (or when group "on" starts)
#    "end": {"objective": k, "seconds": s},        the mission ends by itself s seconds after objective k (optional)
#    "debrief": [t1, t2, t3, t0]}   what the colonel says when objective 1 / 2 / 3 is the best one completed, and
#                                   when none is (optional; a text of an unused objective is ignored)
#
# What is built is what the game's own compiler wrote for the same things (missions 37, 8, 1 and the scenario
# builder): the objectives function sets the game's tables (ObjInit, ObjNeedKill, ObjNeedAlive), then lets the
# game's generic check (missgen.4) complete what is done, each turn; the director answers each group's start
# event; the debriefing completes the "alive" objectives (the game only judges them once the mission is over)
# and says one text. NOT built: reactions to other events (a label dying, a zone entered, a group wiped out),
# reinforcements, speech and music, counters, anything computed: such a script stays "custom" and can only be
# changed number by number (patch).
#
# A rebuilt function takes the place of the mission's own at the same index (do3d calls it by index); the
# functions after it move, and every branch target of the module is corrected (babl.gd shift()). A mission
# without a debriefing function (18, 28, 39, 40) gets one more function at the end of its module and one more
# case in do3d's switch.
extends RefCounted

const Babl := preload("res://scripts/babl.gd")
const MissionScript := preload("res://scripts/mission_script.gd")
const ResFile := preload("res://scripts/res_file.gd")

const N_TICKS := 42
const MAX_NEEDS := 5              # the game's tables: five "kill" and five "alive" needs an objective
const ORDERS := {"patrol": MissionScript.N_GRP_PATROL, "move": MissionScript.N_GRP_MOVE,
	"hold_zone": MissionScript.N_GRP_HOLD_ZONE, "attack_group": MissionScript.N_GRP_ATTACK_GROUP,
	"attack_label": MissionScript.N_GRP_ATTACK_LABEL, "follow": MissionScript.N_GRP_FOLLOW,
	"link": MissionScript.N_GRP_LINK}
const DEFAULT_DEBRIEF := ["Mission complete.", "Mission complete.", "Mission complete.", "Mission failed."]


static func _int(d: Dictionary, key: String, lo: int, hi: int) -> bool:
	return d.has(key) and MissionScript._is_int(d[key]) and int(d[key]) >= lo and int(d[key]) <= hi


# "" when a spec is well formed (ms: the game's scripts, to know the mission)
static func check(ms, spec) -> String:
	if not (spec is Dictionary) or not _int(spec, "mission", 1, 127):
		return "a built script has no mission number"
	var n := int(spec["mission"])
	if not ms.table.has(n) or ms.table[n]["main"].is_empty() or ms.table[n]["director"].is_empty():
		return "mission %d has no script slot in the game" % n
	var rid: int = ms.table[n]["main"][0]
	if ms.table[n]["director"][0] != rid:
		return "mission %d's script is spread over several modules" % n
	for other in ms.table:
		if other == n:
			continue
		for role in ["main", "debrief", "director"]:
			var p: Array = ms.table[other][role]
			if not p.is_empty() and p[0] == rid:
				return "mission %d shares its script with mission %d: it cannot be rebuilt" % [n, other]
	var objs = spec.get("objectives", null)
	if not (objs is Array) or objs.size() != 3:
		return "a built script needs its three objectives (unused ones empty)"
	var locks := 0
	var used := [false, false, false]
	for k in 3:
		var o = objs[k]
		if o == null:
			continue
		if not (o is Array):
			return "objective %d is not well formed" % (k + 1)
		var kills := 0
		var alives := 0
		for c in o:
			if not (c is Dictionary) or not _int(c, "label", 1, 255):
				return "objective %d: a condition needs a label from 1 to 255" % (k + 1)
			match str(c.get("kind", "")):
				"kill":
					kills += 1
					if not _int(c, "pct", 1, 100):
						return "objective %d: a percentage from 1 to 100 is needed" % (k + 1)
				"alive":
					alives += 1
					if not _int(c, "pct", 1, 100):
						return "objective %d: a percentage from 1 to 100 is needed" % (k + 1)
				"idlock":
					locks += 1
					if o.size() != 1:
						return "objective %d: an ID lock cannot be joined with other conditions" % (k + 1)
					if not _int(c, "ms", 100, 600000):
						return "objective %d: the lock's time must be from 100 to 600000 ms" % (k + 1)
				_:
					return "objective %d: unknown kind of condition" % (k + 1)
		if kills > MAX_NEEDS or alives > MAX_NEEDS:
			return "objective %d: the game takes at most %d conditions of a kind" % [k + 1, MAX_NEEDS]
		used[k] = not o.is_empty()
	if locks > 1:
		return "only one objective can be an ID lock"
	var orders = spec.get("orders", [])
	if not (orders is Array):
		return "the orders are not well formed"
	for od in orders:
		if not (od is Dictionary) or not _int(od, "group", 1, 31):
			return "an order needs its group (1 to 31)"
		if od.has("on") and not _int(od, "on", 1, 31):
			return "an order's starting group must be from 1 to 31"
		var g := int(od["group"])
		match str(od.get("order", "")):
			"patrol":
				var z = od.get("zones", null)
				if not (z is Array) or z.size() != 3:
					return "group %d: a patrol needs three zones" % g
				for v in z:
					if not MissionScript._is_int(v) or int(v) < 0 or int(v) > 127:
						return "group %d: a zone is from 0 to 127" % g
			"move", "hold_zone":
				if not _int(od, "zone", 0, 127):
					return "group %d: a zone is from 0 to 127" % g
			"attack_group", "link":
				if not _int(od, "target", 0, 31):
					return "group %d: the other group is from 0 to 31" % g
			"attack_label", "follow":
				if not _int(od, "label", 1, 255):
					return "group %d: a label is from 1 to 255" % g
			_:
				return "group %d: unknown order" % g
	if spec.has("end") and spec["end"] != null:
		var e = spec["end"]
		if not (e is Dictionary) or not _int(e, "objective", 1, 3) or not _int(e, "seconds", 0, 3600):
			return "the mission's end needs an objective (1 to 3) and seconds (0 to 3600)"
		if not used[int(e["objective"]) - 1]:
			return "the mission's end waits for objective %d, which is not used" % e["objective"]
	if spec.has("debrief") and spec["debrief"] != null:
		var d = spec["debrief"]
		if not (d is Array) or d.size() != 4:
			return "the debriefing needs four texts"
		for t in d:
			if not (t is String) or t.length() > 1000:
				return "a debriefing text is too long (1000 characters at most)"
	return ""


static func _conds(spec: Dictionary, k: int) -> Array:
	var o = spec["objectives"][k]
	return o if o is Array else []


static func _lock_of(spec: Dictionary) -> Dictionary:
	for k in 3:
		for c in _conds(spec, k):
			if c["kind"] == "idlock":
				return {"obj": k + 1, "label": int(c["label"]), "ms": int(c["ms"])}
	return {}


# ---- the objectives function
static func build_main(spec: Dictionary, base: int) -> PackedByteArray:
	var a := Babl.Asm.new(base)
	var lock := _lock_of(spec)
	a.enter(8)                                      # loc0 (+0): the lock is done; loc1 (+4): when the end began
	for k in 3:                                     # missgen's "already completed": 1 keeps its generic check away
		a.set_global(MissionScript.G_DONE + 4 * k)  # from an objective the game cannot judge by itself
		a.imm(1 if (not lock.is_empty() and lock["obj"] == k + 1) else 0)
		a.store()
	a.set_local(0)
	a.imm(0)
	a.store()
	a.set_local(4)
	a.imm(0)
	a.store()
	a.native(MissionScript.N_OBJ_INIT, [int(not _conds(spec, 0).is_empty()), int(not _conds(spec, 1).is_empty()),
		int(not _conds(spec, 2).is_empty())])
	a.drop()
	for k in 3:
		for c in _conds(spec, k):
			if c["kind"] == "idlock":
				continue
			var pct := [0, 0, 0]
			pct[k] = int(c["pct"])
			a.native(MissionScript.N_NEED_KILL if c["kind"] == "kill" else MissionScript.N_NEED_ALIVE,
				[int(c["label"]), pct[0], pct[1], pct[2]])
			a.drop()
	a.label("loop")
	a.op(Babl.OP_YIELD)
	a.call_script(MissionScript.RES_MISSGEN, 4)
	a.drop()
	if not lock.is_empty():
		a.local(0)                                  # if (loc0 == 0 && (LockedTarget() & 255) == L && missgen.9(ms))
		a.imm(0)
		a.op(0x19)
		a.ifnot("lock_end")
		a.native(MissionScript.N_LOCKED)
		a.imm(255)
		a.op(0x14)
		a.imm(lock["label"])
		a.op(0x19)
		a.ifnot("lock_end")
		a.call_script(MissionScript.RES_MISSGEN, 9, [lock["ms"]])
		a.ifnot("lock_end")
		a.native(MissionScript.N_OBJ_COMPLETE, [lock["obj"]])
		a.drop()
		a.set_local(0)
		a.imm(1)
		a.store()
		a.label("lock_end")
	var e = spec.get("end", null)
	if e is Dictionary:
		a.native(MissionScript.N_OBJ_STATE, [int(e["objective"])])
		a.imm(1)
		a.op(0x19)
		a.ifnot("end_skip")
		a.local(4)
		a.imm(0)
		a.op(0x19)
		a.ifnot("armed")
		a.set_local(4)
		a.native(N_TICKS)
		a.store()
		a.goto("end_skip")
		a.label("armed")
		a.native(N_TICKS)
		a.local(4)
		a.op(0x10)
		a.imm(int(e["seconds"]) * 1000)
		a.op(0x1C)
		a.ifnot("end_skip")
		a.set_cvar(MissionScript.CV_MISSION_OVER)
		a.imm(1)
		a.store()
		a.label("end_skip")
	a.goto("loop")
	a.op(Babl.OP_HALT)
	return a.done()


# ---- the director: each group's orders at a group's start
static func _order_args(od: Dictionary) -> Array:
	var g := int(od["group"])
	match str(od["order"]):
		"patrol":
			return [g, int(od["zones"][0]), int(od["zones"][1]), int(od["zones"][2])]
		"move", "hold_zone":
			return [g, int(od["zone"])]
		"attack_group", "link":
			return [g, int(od["target"])]
		"attack_label", "follow":
			return [g, int(od["label"])]
	return [g]


static func build_director(spec: Dictionary, base: int) -> PackedByteArray:
	var a := Babl.Asm.new(base)
	var by_start := {}
	for od in spec.get("orders", []):
		var t := int(od.get("on", od["group"]))
		if not by_start.has(t):
			by_start[t] = []
		by_start[t].append(od)
	var starts := by_start.keys()
	starts.sort()
	a.enter(0)
	a.label("loop")
	a.msg_wait()
	a.msg_type_not(97, "free")
	a.msg_field(0, 30)
	a.imm(129)
	a.op(0x19)
	a.ifnot("free")
	for t in starts:
		a.msg_field(0, 31)
		a.imm(t)
		a.op(0x19)
		a.ifnot("next%d" % t)
		for od in by_start[t]:
			a.native(ORDERS[str(od["order"])], _order_args(od))
			a.drop()
		a.goto("free")
		a.label("next%d" % t)
	a.label("free")
	a.op(Babl.OP_MSG_FREE)
	a.goto("loop")
	a.ret()
	return a.done()


# ---- the debriefing: [texts in the string table's order], and the function saying the best one
static func debrief_texts(spec: Dictionary) -> Array:
	var d = spec.get("debrief", null)
	var src: Array = d if d is Array else DEFAULT_DEBRIEF
	var out := []
	for k in 3:
		if not _conds(spec, k).is_empty():
			out.append([k + 1, str(src[k])])
	out.append([0, str(src[3])])
	return out


static func build_debrief(spec: Dictionary, base: int, str_res: int) -> PackedByteArray:
	var a := Babl.Asm.new(base)
	a.enter(0)
	for k in 3:
		var needs := false
		for c in _conds(spec, k):
			if c["kind"] != "idlock":
				needs = true
		if not needs:
			continue
		a.native(MissionScript.N_ALIVE_OK, [k + 1])
		a.ifnot("judged%d" % k)
		a.native(MissionScript.N_KILL_OK, [k + 1])
		a.ifnot("judged%d" % k)
		a.native(MissionScript.N_OBJ_COMPLETE, [k + 1])
		a.drop()
		a.label("judged%d" % k)
	var texts := debrief_texts(spec)
	for i in range(texts.size() - 2, -1, -1):          # the best objective first
		var k: int = texts[i][0]
		a.native(MissionScript.N_OBJ_STATE, [k])
		a.imm(1)
		a.op(0x19)
		a.ifnot("not%d" % k)
		a.imm(0)
		a.string(str_res, i)
		a.op(Babl.OP_SAY)
		a.goto("said")
		a.label("not%d" % k)
	a.imm(0)
	a.string(str_res, texts.size() - 1)
	a.op(Babl.OP_SAY)
	a.label("said")
	a.ret()
	return a.done()


# ---- into the module
# function f of frames replaced by new code; false when the module's branch targets could not be corrected
static func _replace(frames: Array, f: int, code: PackedByteArray) -> bool:
	if code.is_empty():
		return false
	var old: PackedByteArray = frames[f]
	var base := Babl.base_of(frames, f)
	if not Babl.shift(frames, base + old.size(), code.size() - old.size()):
		return false
	frames[f] = code
	return true


# one more case in a switch of do3d on the mission number: "" or what went wrong
static func _add_case(ms, do3d_f: int, mission: int, rid: int, f: int) -> String:
	var frames: Array = ms.modules[MissionScript.RES_DO3D]["frames"]
	var base := Babl.base_of(frames, do3d_f)
	var st = Babl.lift(frames[do3d_f], base)
	if st == null:
		return "do3d's function %d could not be read" % do3d_f
	var end_at := -1
	for s in st:
		if s["k"] == "case" and s["on"]["k"] == "cv" and s["on"]["o"] == MissionScript.CV_MISSION:
			if s["e"]["k"] == "imm" and s["e"]["v"] == mission:
				return "do3d already has a case for mission %d" % mission
			end_at = s["to"]
	var code: PackedByteArray = frames[do3d_f]
	var at := end_at - base
	if end_at < 0 or at < 0 or at >= code.size() or code[at] != Babl.OP_DROP:
		return "do3d's switch does not end as expected"
	var block := PackedByteArray([0x01, mission, 0x2B, 0, 0, 0x25, 0, 0, 0, 0, 0x0E, 0x2D, 0, 0])
	var after := end_at + block.size()
	if after > 0xFFFF:
		return "do3d is too big"
	block.encode_u16(3, after)
	block.encode_u32(6, (rid << 16) | f)
	block.encode_u16(12, after)
	# the switch's end keeps its place for the cases before it (they now fall on the new case); everything
	# after it moves
	if not Babl.shift(frames, end_at + 1, block.size()):
		return "do3d's branch targets could not be corrected"
	code = frames[do3d_f]
	frames[do3d_f] = code.slice(0, at) + block + code.slice(at)
	ms.changed[MissionScript.RES_DO3D] = true
	return ""


# a spec built into ms (a copy of the game's scripts, changed in memory); extra gets the new string tables
# {resource id: bytes}. "" or what went wrong.
static func apply(ms, spec, extra: Dictionary) -> String:
	var err := check(ms, spec)
	if err != "":
		return err
	var n := int(spec["mission"])
	var t: Dictionary = ms.table[n]
	var rid: int = t["main"][0]
	var str_res := rid + 1
	if not ResFile.has(ms.raw, str_res) or ResFile.find(ms.raw, str_res) < 0:
		return "mission %d has no string table for its debriefing" % n
	var frames: Array = ms.modules[rid]["frames"]
	for f in range(1, frames.size()):
		if Babl.walk(frames[f]) == null:
			return "%s.%d could not be read" % [ms.module_name(rid), f]
	var f_main: int = t["main"][1]
	if not _replace(frames, f_main, build_main(spec, Babl.base_of(frames, f_main))):
		return "the objectives function could not be rebuilt"
	var f_dir: int = t["director"][1]
	if not _replace(frames, f_dir, build_director(spec, Babl.base_of(frames, f_dir))):
		return "the director function could not be rebuilt"
	if not t["debrief"].is_empty() and t["debrief"][0] == rid:
		var f_deb: int = t["debrief"][1]
		if not _replace(frames, f_deb, build_debrief(spec, Babl.base_of(frames, f_deb), str_res)):
			return "the debriefing function could not be rebuilt"
	else:
		if not t["debrief"].is_empty():
			return "mission %d's debriefing is in another module" % n
		var code := build_debrief(spec, Babl.base_of(frames, frames.size()), str_res)
		if code.is_empty():
			return "the debriefing function could not be built"
		frames.append(code)
		err = _add_case(ms, MissionScript.DO3D_DEBRIEF, n, rid, frames.size() - 1)
		if err != "":
			return err
	if Babl.join(frames).size() > 0xFFFF:
		return "the script is too big"
	var list := []
	for p in debrief_texts(spec):
		list.append(p[1])
	extra[str_res] = ResFile.strings(list)
	ms.changed[rid] = true
	ms._read_table()
	ms.legal.clear()
	return ""


# ---- a creation's script part -> the scripts in memory: {"error", "ms", "extra"}
static func make(data_dir: String, script: Dictionary) -> Dictionary:
	var mo = MissionScript.open(data_dir, true)
	if mo == null:
		return {"error": "RESBABL2.RES was not found in %s" % data_dir, "ms": null, "extra": {}}
	var patch = script.get("patch", [])
	var builds = script.get("build", [])
	if not (patch is Array) or not (builds is Array):
		return {"error": "the script part of the creation is not well formed", "ms": null, "extra": {}}
	var r: Dictionary = mo.patched(patch)
	if r["error"] != "":
		return {"error": r["error"], "ms": null, "extra": {}}
	var ms = r["ms"]
	var extra := {}
	var rebuilt := {}
	for spec in builds:
		var err := check(mo, spec)
		if err != "":
			return {"error": err, "ms": null, "extra": {}}
		var rid: int = mo.table[int(spec["mission"])]["main"][0]
		if rebuilt.has(rid):
			return {"error": "mission %d's script is rebuilt twice" % spec["mission"], "ms": null, "extra": {}}
		rebuilt[rid] = true
		for c in patch:
			if int(c["res"]) == rid:
				return {"error": "mission %d's script is both rebuilt and changed in place" % spec["mission"],
					"ms": null, "extra": {}}
		err = apply(ms, spec, extra)
		if err != "":
			return {"error": err, "ms": null, "extra": {}}
	return {"error": "", "ms": ms, "extra": extra}


# ---- a creation's script part written into data_dir\RESBABL2.RES (the game's own file is kept beside it as
# RESBABL2.RES.uplink-original, and is always what the changes are applied to). An empty script part puts the
# game's file back. "" or what went wrong (nothing is written then).
static func install(data_dir: String, script: Dictionary) -> String:
	var path := data_dir.path_join(MissionScript.FILE)
	if script.get("patch", []).is_empty() and script.get("build", []).is_empty():
		return ResFile.restore(path)
	var r := make(data_dir, script)
	if r["error"] != "":
		return r["error"]
	var fb: Dictionary = r["ms"].file_bytes(r["extra"])
	if fb["error"] != "":
		return fb["error"]
	var err := ResFile.keep_original(path)
	if err != "":
		return err
	return ResFile.write(path, fb["bytes"])
