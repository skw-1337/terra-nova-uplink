# What a mission's script does, read from the game's RESBABL2.RES (see babl.gd), in plain terms for the mission
# editor: the three objectives and what completes each, the labels, groups and zones the script counts on (so the
# editor can warn before one is removed or changed), the orders each group gets and when, and every number that
# can be changed in place (edits).
#
#   var ms = MissionScript.open(data_dir)          # null: no RESBABL2.RES there (ms.error says why otherwise)
#   var s: Dictionary = ms.summary(37)
#     s["objectives"][k] = {"n": 1..3, "text": the game's line, "active", "kind": "none" | "kill" | "alive" |
#                           "idlock" | "combined" | "custom", "what": one sentence, "conditions": [{"kind", "label",
#                           "pct" | "ms", "edit": {field: edit id}}], "custom": [notes]}
#     s["orders"]      = [{"group", "order" ("patrol", "move", "attack_group", "attack_label", "follow", "hold_zone",
#                          "link", "tactic", "other"), "zones": [..], "target", "native", "when": {"event", "group",
#                          "label", "zone", "enter", "complex", "text"}, "start": true for the orders given when a
#                          group starts, "text", "edit": {field: edit id}}]
#     s["start_orders"] = {group: [sentences]}
#     s["labels"] / s["groups"] / s["zones"] = {number: [what the script does with it]}
#     s["edits"]       = {id: {"what", "kind", "v", "min", "max", "res", "frame", "off", "n"}}
#   MissionScript.uses(s, "label", 2)              # the sentences to show before label 2 goes away
#
# Who is who in a script (the game's code): a unit is known by its LABEL (unit record +26), a group by its number
# (+7), a place by its zone index. The director function receives events: 97 = a group that exists when the
# mission starts (one event per group, 0x2566CC), 108 = a labelled unit died, 109 = a group was wiped out,
# 110 = a group entered or left one of the zones 0-31 (0x253814). The orders (0x25A7E8, executed at 0x25A22C and by
# the group at 0x253F70): 113 go to a zone, 120 patrol three zones, 118 / 119 attack a group / a label, 122 follow a
# label, 124 "hold zone z" (group record +0x120 = 1, +0x121 = z, only when the group is inside that zone; z = 0
# releases it), 132 "link with group v" (the group leaves its ring of groups, +0x165 / +0x166, and joins v's).
extends RefCounted

const Babl := preload("res://scripts/babl.gd")
const LGRes := preload("res://scripts/lgres.gd")

const FILE := "RESBABL2.RES"
const RES_DO3D := 1005
const RES_MISSGEN := 1009
const DO3D_MAIN := 3            # do3d's switch on the mission number: the objectives function,
const DO3D_DEBRIEF := 7         # the debriefing,
const DO3D_DIRECTOR := 8        # the director
const CV_MISSION := 7
const CV_OBJ_ON := 24           # 24, 25, 26: the three objectives' "in use" flags
const CV_MISSION_OVER := 30
const G_DONE := 0x90            # 0x90, 0x94, 0x98: missgen's "objective k already completed" globals
const RES_OBJ_TEXT := 0x175     # RESGAME.RES: string mission * 3 + k - 1
const RES_NAMES := 0x6AA        # RESMISS.RES: string mission - 1

# the game's functions a mission script calls (index in the game's table at 0x35DCCC)
const N_OBJ_INIT := 83
const N_NEED_KILL := 84
const N_NEED_ALIVE := 85
const N_LOCKED := 101
const N_KILL_OK := 103
const N_ALIVE_OK := 104
const N_OBJ_COMPLETE := 105
const N_CALL_DROPSHIP := 106
const N_GRP_FIRST := 112
const N_GRP_MOVE := 113
const N_GRP_ATTACK_GROUP := 118
const N_GRP_ATTACK_LABEL := 119
const N_GRP_PATROL := 120
const N_GRP_FOLLOW := 122
const N_GRP_HOLD_ZONE := 124
const N_GRP_STOP_FOLLOW := 129
const N_GRP_LINK := 132
const N_GRP_TACTIC := 133
const N_REINFORCE := 134
const N_GRP_LAST := 136
const N_KILLED := 137
const N_OBJ_SET := 138
const N_OBJ_STATE := 141
const N_DIST := 143
const N_ENT_OF_LABEL := 144
const N_ONE_SHOT := 163

const NAMES := {
	"fn83": "ObjInit", "fn84": "ObjNeedKill", "fn85": "ObjNeedAlive", "fn101": "LockedTarget",
	"fn102": "DropshipState", "fn103": "ObjKillOK", "fn104": "ObjAliveOK", "fn105": "ObjComplete",
	"fn106": "CallDropship", "fn113": "GrpMoveToZone", "fn118": "GrpAttackGroup", "fn119": "GrpAttackLabel",
	"fn120": "GrpPatrolZones", "fn122": "GrpFollowLabel", "fn124": "GrpHoldZone", "fn129": "GrpStopFollow",
	"fn132": "GrpLink", "fn133": "GrpTactic", "fn134": "ReinforceTimer", "fn137": "KilledCount",
	"fn138": "ObjSetState", "fn141": "ObjState", "fn142": "MissionSeconds", "fn143": "Dist",
	"fn144": "EntOfLabel", "fn163": "OneShotTimer", "fn82": "Speech", "fn139": "MusicCue6", "fn140": "MusicCue7",
	"cv7": "MISSION", "cv24": "obj1_on", "cv25": "obj2_on", "cv26": "obj3_on", "cv30": "MISSION_OVER",
}
# (96 and 99 are named after what the game's missions do with them: 96 moves a convoy on to its next zone, 99 fails
# the "avoid detection" objectives)
const EVENTS := {96: "a group has finished its move", 97: "a group starts", 99: "a group spots an enemy",
	108: "a labelled unit dies", 109: "a group is wiped out", 110: "a group enters or leaves a zone"}

var path := ""
var error := ""
var res = null                     # the file (lgres.gd)
var modules := {}                  # resource id -> {"name", "frames"}
var table := {}                    # mission -> {"main": [res, f], "debrief": [res, f], "director": [res, f]}
var obj_texts := PackedStringArray()
var mission_names := PackedStringArray()


# data_dir: the game's TNOVA\DATA (or a copy of it). null when RESBABL2.RES is not there or not readable.
static func open(data_dir: String, babl_file: String = ""):
	var ms = load("res://scripts/mission_script.gd").new()
	ms.path = babl_file if babl_file != "" else data_dir.path_join(FILE)
	ms.res = LGRes.open(ms.path)
	if ms.res == null:
		return null
	for rid in ms.res.resources:
		if ms.res.resources[rid]["type"] == 12:
			var m: Dictionary = Babl.split(ms.res.data(rid))
			if not m.is_empty():
				ms.modules[rid] = m
	ms._read_table()
	var g = LGRes.open(data_dir.path_join("RESGAME.RES"))
	if g != null:
		ms.obj_texts = g.strings(RES_OBJ_TEXT)
	var m2 = LGRes.open(data_dir.path_join("RESMISS.RES"))
	if m2 != null:
		ms.mission_names = m2.strings(RES_NAMES)
	return ms


func missions() -> Array:
	var out := table.keys()
	out.sort()
	return out


func module_name(rid: int) -> String:
	return modules[rid]["name"] if modules.has(rid) else "res%d" % rid


func module_res(name: String) -> int:
	for rid in modules:
		if modules[rid]["name"] == name:
			return rid
	return -1


# a function of a module as statements (babl.gd lift), null when it is not there or not readable
func statements(rid: int, f: int):
	if not modules.has(rid):
		return null
	var frames: Array = modules[rid]["frames"]
	if f < 1 or f >= frames.size():
		return null
	return Babl.lift(frames[f], Babl.base_of(frames, f))


func _read_table() -> void:
	table.clear()
	for pair in [[DO3D_MAIN, "main"], [DO3D_DEBRIEF, "debrief"], [DO3D_DIRECTOR, "director"]]:
		var st = statements(RES_DO3D, pair[0])
		if st == null:
			error = "do3d's function %d could not be read" % pair[0]
			continue
		for i in st.size() - 1:
			var s: Dictionary = st[i]
			if s["k"] != "case" or s["on"]["k"] != "cv" or s["on"]["o"] != CV_MISSION or s["e"]["k"] != "imm":
				continue
			var nxt: Dictionary = st[i + 1]
			if nxt["k"] != "call":
				continue
			var n: int = s["e"]["v"]
			if not table.has(n):
				table[n] = {"main": [], "debrief": [], "director": []}
			table[n][pair[1]] = [nxt["res"], nxt["f"]]


# ---- small readers of expressions
# the constant an expression is, or null: an immediate, or two of them joined by | (typed references)
static func const_of(e):
	if not (e is Dictionary):
		return null
	if e["k"] == "imm":
		return e["v"]
	if e["k"] == "bin" and e["op"] == "|":
		var a = const_of(e["a"])
		var b = const_of(e["b"])
		if a != null and b != null:
			return int(a) | int(b)
	return null


static func _flatten_and(e, out: Array) -> void:
	if e is Dictionary and e["k"] == "bin" and e["op"] == "&&":
		_flatten_and(e["a"], out)
		_flatten_and(e["b"], out)
	else:
		out.append(e)


# guards of each statement: [{"type": message type or -1, "e": condition or null}] it stands under
static func _guards(st: Array) -> Array:
	var out := []
	var open_g := []
	for s in st:
		var at: int = s["at"]
		var kept := []
		for g in open_g:
			if g["to"] > at:
				kept.append(g)
		open_g = kept
		out.append(open_g.duplicate())
		if s["k"] == "msgtype" and s["to"] > at:
			open_g.append({"to": s["to"], "type": s["t"], "e": null})
		elif s["k"] == "ifnot" and s["to"] > at:
			open_g.append({"to": s["to"], "type": -1, "e": s["e"]})
	return out


# what the guards say: {"event", "group", "label", "zone", "enter", "complex", "text"}
static func _when(guards: Array, role: String) -> Dictionary:
	var w := {"event": -1, "group": -1, "label": -1, "zone": -1, "enter": -1, "complex": false, "text": ""}
	var eq := {}
	for g in guards:
		if g["type"] >= 0:
			w["event"] = g["type"]
			continue
		var terms := []
		_flatten_and(g["e"], terms)
		for t in terms:
			var ok := false
			if t is Dictionary and t["k"] == "bin" and t["op"] == "==":
				var m = t["a"]
				var c = const_of(t["b"])
				if m is Dictionary and m["k"] == "msg" and c != null:
					eq["%d_%d" % [m["t"], m["i"]]] = int(c)
					ok = true
			if not ok:
				w["complex"] = true
	var ev: int = w["event"]
	var txt := ""
	if ev < 0:
		txt = "at the debriefing" if role == "debrief" else "in the %s function" % role
	else:
		if eq.has("0_30") and eq["0_30"] == 129 and eq.has("0_31"):
			w["group"] = eq["0_31"]
		match ev:
			97:
				txt = "when group %d starts" % w["group"] if w["group"] >= 0 else "when any group starts"
			108:
				w["label"] = eq.get("4_0", -1)
				txt = "when a unit labelled %d dies" % w["label"] if w["label"] >= 0 else "when a labelled unit dies"
			109:
				w["group"] = eq.get("4_0", -1)
				txt = "when group %d is wiped out" % w["group"] if w["group"] >= 0 else "when a group is wiped out"
			110:
				w["group"] = eq.get("1_0", -1)
				w["zone"] = eq.get("1_1", -1)
				w["enter"] = eq.get("1_2", -1)
				txt = "when %s %s %s" % ["group %d" % w["group"] if w["group"] >= 0 else "a group",
					"enters" if w["enter"] == 1 else "leaves" if w["enter"] == 0 else "enters or leaves",
					"zone %d" % w["zone"] if w["zone"] >= 0 else "a zone"]
			96:
				txt = "when %s has finished its move" % ("group %d" % w["group"] if w["group"] >= 0 else "a group")
			99:
				txt = "when %s spots an enemy" % ("group %d" % w["group"] if w["group"] >= 0 else "a group")
			_:
				txt = "on event %d%s" % [ev, " from group %d" % w["group"] if w["group"] >= 0 else ""]
	if w["complex"]:
		txt += " (and other conditions)"
	w["text"] = txt
	return w


# ---- the summary
func summary(mission: int) -> Dictionary:
	var out := {"mission": mission, "ok": false, "error": "", "name": "", "module": "", "res": -1,
		"main": -1, "debrief": -1, "director": -1, "objectives": [], "orders": [], "start_orders": {},
		"labels": {}, "groups": {}, "zones": {}, "edits": {}, "notes": []}
	if mission >= 1 and mission - 1 < mission_names.size():
		out["name"] = mission_names[mission - 1].strip_edges()
	if not table.has(mission):
		out["error"] = "the game's scripts have nothing for mission %d" % mission
		return out
	var t: Dictionary = table[mission]
	var roles := {}                                # "res.f" -> role
	var todo := []
	for role in ["main", "debrief", "director"]:
		var p: Array = t[role]
		if p.is_empty():
			continue
		roles["%d.%d" % [p[0], p[1]]] = role
		todo.append(p)
		if role == "main" or out["res"] < 0:
			out["res"] = p[0]
		out[role] = p[1]
	if out["res"] < 0:
		out["error"] = "mission %d has no script function" % mission
		return out
	out["module"] = module_name(out["res"])
	# the mission's functions and the ones of its own modules they call
	var lifted := {}                               # "res.f" -> statements
	var generic_main := false
	var generic_debrief := false
	while not todo.is_empty():
		var p: Array = todo.pop_back()
		var key := "%d.%d" % [p[0], p[1]]
		if lifted.has(key):
			continue
		var st = statements(p[0], p[1])
		if st == null:
			out["error"] = "%s.%d could not be read" % [module_name(p[0]), p[1]]
			return out
		lifted[key] = st
		for s in st:
			for nd in Babl.stmt_nodes(s):
				if nd["k"] == "nat" and (nd["i"] == N_KILL_OK or nd["i"] == N_ALIVE_OK):
					generic_main = true             # (the script asks the game itself)
				if nd["k"] == "spawn" and nd["res"] != RES_MISSGEN and modules.has(nd["res"]):
					var k3 := "%d.%d" % [nd["res"], nd["f"]]
					if not roles.has(k3):
						roles[k3] = "helper"
					todo.append([nd["res"], nd["f"]])
			if s["k"] != "call":
				continue
			if s["res"] == RES_MISSGEN:
				if s["f"] == 4 or s["f"] == 1:
					generic_main = true
				if s["f"] == 5:
					generic_debrief = true
			elif s["res"] != RES_DO3D and modules.has(s["res"]):
				var k2 := "%d.%d" % [s["res"], s["f"]]
				if not roles.has(k2):
					roles[k2] = "helper"
				todo.append([s["res"], s["f"]])
	var active := [false, false, false]
	var conds := [[], [], []]
	var custom := [[], [], []]
	var keys := lifted.keys()
	keys.sort()
	for key in keys:
		var st: Array = lifted[key]
		var rid := int(key.get_slice(".", 0))
		var f := int(key.get_slice(".", 1))
		var role: String = roles[key]
		var base := Babl.base_of(modules[rid]["frames"], f)
		var guards := _guards(st)
		var lock := _id_lock(st)
		if not lock.is_empty():
			var k: int = lock["obj"]
			var c := {"kind": "idlock", "label": lock["label"], "ms": lock["ms"], "edit": {}}
			c["edit"]["label"] = _edit(out, lock["label_node"], rid, f, base, "label",
				"objective %d: the label to ID-lock" % k, 1, 127)
			c["edit"]["ms"] = _edit(out, lock["ms_node"], rid, f, base, "ms",
				"objective %d: how long the lock must be held (ms)" % k, 100, 32767)
			conds[k - 1].append(c)
			active[k - 1] = true
			_use(out, "labels", lock["label"], "objective %d: one of them must be ID-locked for %s s" % [
				k, _secs(lock["ms"])])
		for si in st.size():
			var s: Dictionary = st[si]
			var when := _when(guards[si], role)
			# the objectives' flags written directly
			if s["k"] == "set" and s["dst"]["k"] == "&cv":
				var o: int = s["dst"]["o"]
				var v = const_of(s["e"])
				if o >= CV_OBJ_ON and o < CV_OBJ_ON + 3 and v != null:
					active[o - CV_OBJ_ON] = v != 0
				elif o == CV_MISSION_OVER and role != "debrief":
					out["notes"].append("the script ends the mission itself %s" % when["text"])
			for nd in Babl.stmt_nodes(s):
				if nd["k"] == "bin" and nd["op"] == "|":
					_typed_ref(out, nd, when)
				if nd["k"] != "nat":
					continue
				_native(out, nd, when, role, rid, f, base, active, conds, custom, lock)
			# the conditions themselves: what the script waits for
			if s["k"] == "ifnot" or s["k"] == "msgtype":
				_watch(out, guards[si], s, role)
	# the three objectives
	for k in 3:
		var o := {"n": k + 1, "text": "", "active": active[k], "kind": "none", "what": "",
			"conditions": conds[k], "custom": custom[k]}
		var ti := mission * 3 + k
		if ti < obj_texts.size():
			o["text"] = obj_texts[ti].strip_edges()
		var parts := PackedStringArray()
		for c in conds[k]:
			parts.append(_cond_text(c))
		var has_needs := false
		for c in conds[k]:
			if c["kind"] != "idlock":
				has_needs = true
		if has_needs and not generic_main and not generic_debrief:
			custom[k].append("its conditions are set but the script never asks the game to check them")
		if not custom[k].is_empty() or (active[k] and conds[k].is_empty()):
			o["kind"] = "custom"
			if parts.is_empty():
				o["what"] = "custom logic"
			else:
				o["what"] = "%s; plus custom logic" % ", and ".join(parts)
		elif conds[k].size() == 1:
			o["kind"] = conds[k][0]["kind"]
			o["what"] = parts[0]
		elif conds[k].size() > 1:
			o["kind"] = "combined"
			o["what"] = ", and ".join(parts)
		else:
			o["what"] = "not used"
		out["objectives"].append(o)
	for od in out["orders"]:
		if od["start"] and od["group"] >= 0:
			if not out["start_orders"].has(od["group"]):
				out["start_orders"][od["group"]] = []
			out["start_orders"][od["group"]].append(od["text"])
	out["ok"] = true
	return out


# the sentences about one label, group or zone ("label", "group", "zone"), empty when the script ignores it
static func uses(s: Dictionary, kind: String, n: int) -> Array:
	return s.get(kind + "s", {}).get(n, [])


static func _secs(ms: int) -> String:
	return str(ms / 1000) if ms % 1000 == 0 else "%.1f" % (ms / 1000.0)


static func _cond_text(c: Dictionary) -> String:
	match c["kind"]:
		"kill":
			return "destroy %d %% of the units labelled %d" % [c["pct"], c["label"]]
		"alive":
			return "keep %d %% of the units labelled %d alive" % [c["pct"], c["label"]]
		"idlock":
			return "ID-lock a unit labelled %d for %s s" % [c["label"], _secs(c["ms"])]
	return "?"


static func _use(out: Dictionary, kind: String, n, what: String) -> void:
	if n == null or int(n) < 0:
		return
	var d: Dictionary = out[kind]
	if not d.has(int(n)):
		d[int(n)] = []
	if not d[int(n)].has(what):
		d[int(n)].append(what)


# an immediate that can be changed in place: its id ("" when the node is not a plain immediate)
static func _edit(out: Dictionary, node, rid: int, f: int, base: int, kind: String, what: String,
		lo: int, hi: int) -> String:
	if not (node is Dictionary) or node["k"] != "imm":
		return ""
	var n: int = node["n"]
	var cap_lo := -128 if n == 1 else -32768 if n == 2 else -2147483648
	var cap_hi := 127 if n == 1 else 32767 if n == 2 else 2147483647
	var id := "%d.%d.%d" % [rid, f, node["at"] - base]
	out["edits"][id] = {"what": what, "kind": kind, "v": node["v"], "min": maxi(lo, cap_lo),
		"max": mini(hi, cap_hi), "res": rid, "frame": f, "off": node["at"] - base, "n": n}
	return id


# (0x20000 | label) and (0x30000 | zone): the typed references of Dist()
static func _typed_ref(out: Dictionary, nd: Dictionary, when: Dictionary) -> void:
	var a = const_of(nd["a"])
	var b = const_of(nd["b"])
	if a == null or b == null:
		return
	if int(a) == 0x20000:
		_use(out, "labels", b, "a distance to them is measured %s" % when["text"])
	elif int(a) == 0x30000:
		_use(out, "zones", b, "a distance to it is measured %s" % when["text"])


# the ID lock pattern (missions 1 and 8): LockedTarget() & 255 compared with a label, missgen.9(ms) holding the
# lock, then ObjComplete(k). {} when the function has none.
static func _id_lock(st: Array) -> Dictionary:
	var seen_lock := false
	var label_node = null
	var ms_node = null
	for s in st:
		for nd in Babl.stmt_nodes(s):
			if nd["k"] == "nat" and nd["i"] == N_LOCKED:
				seen_lock = true
		if not seen_lock:
			continue
		if label_node == null and s["k"] == "ifnot":
			var e = s["e"]
			if e is Dictionary and e["k"] == "bin" and (e["op"] == "!=" or e["op"] == "==") and e["b"]["k"] == "imm":
				label_node = e["b"]
		if s["k"] == "call" and s["res"] == RES_MISSGEN and s["f"] == 9 and s["args"].size() == 1:
			if ms_node == null and s["args"][0]["k"] == "imm":
				ms_node = s["args"][0]
		if ms_node != null and label_node != null:
			for nd in Babl.stmt_nodes(s):
				if nd["k"] == "nat" and nd["i"] == N_OBJ_COMPLETE and nd["args"].size() == 1:
					var k = const_of(nd["args"][0])
					if k != null and int(k) >= 1 and int(k) <= 3:
						return {"obj": int(k), "label": label_node["v"], "ms": ms_node["v"],
							"label_node": label_node, "ms_node": ms_node, "complete_at": nd["at"]}
	return {}


func _native(out: Dictionary, nd: Dictionary, when: Dictionary, role: String, rid: int, f: int, base: int,
		active: Array, conds: Array, custom: Array, lock: Dictionary) -> void:
	var i: int = nd["i"]
	var a: Array = nd["args"]
	var c := []
	for x in a:
		c.append(const_of(x))
	match i:
		N_OBJ_INIT:
			for k in mini(3, a.size()):
				if c[k] == null:
					custom[k].append("turned on or off by a computed value")
				else:
					active[k] = active[k] or c[k] != 0
					_edit(out, a[k], rid, f, base, "flag", "objective %d in use (1) or not (0)" % (k + 1), 0, 1)
		N_NEED_KILL, N_NEED_ALIVE:
			if a.size() < 4:
				return
			var kind := "kill" if i == N_NEED_KILL else "alive"
			for k in 3:
				var what := "objective %d: %% of the units labelled %s to %s (0: not asked)" % [
					k + 1, str(c[0]), "destroy" if kind == "kill" else "keep alive"]
				var pct_id := _edit(out, a[k + 1], rid, f, base, "pct", what, 0, 100)
				if c[k + 1] == null or c[0] == null:
					custom[k].append("a need (%s) with a computed label or percentage" % kind)
					continue
				if c[k + 1] == 0:
					continue
				var cd := {"kind": kind, "label": int(c[0]), "pct": int(c[k + 1]), "edit": {"pct": pct_id}}
				cd["edit"]["label"] = _edit(out, a[0], rid, f, base, "label",
					"the label counted by ObjNeed%s (objectives %s)" % ["Kill" if kind == "kill" else "Alive",
					_objs_of(c)], 1, 127)
				conds[k].append(cd)
				active[k] = true
				if int(c[0]) >= 0x100:
					out["notes"].append("objective %d counts every unit of class %d" % [k + 1, int(c[0]) - 0x100])
				else:
					_use(out, "labels", c[0], "objective %d: %d %% of them must %s" % [
						k + 1, c[k + 1], "be destroyed" if kind == "kill" else "stay alive"])
		N_OBJ_COMPLETE, N_OBJ_SET:
			if a.is_empty() or c[0] == null or int(c[0]) < 1 or int(c[0]) > 3:
				return
			if not lock.is_empty() and lock["complete_at"] == nd["at"]:
				return
			var state := 1
			if i == N_OBJ_SET:
				state = int(c[2]) if a.size() >= 3 and c[2] != null else -1
			var word := "completed" if state == 1 else "failed" if state == 4 else "set to state %d" % state
			custom[int(c[0]) - 1].append("%s %s" % [word, when["text"]])
			if when["label"] >= 0:
				_use(out, "labels", when["label"], "objective %d is %s when one of them dies" % [c[0], word])
		N_KILLED:
			if not a.is_empty() and c[0] != null and int(c[0]) < 0x100:
				_use(out, "labels", c[0], "the script counts how many of them were destroyed (%s)" % when["text"])
		N_ENT_OF_LABEL:
			if not a.is_empty():
				_use(out, "labels", c[0], "the script looks one of them up (%s)" % when["text"])
		N_REINFORCE:
			if a.size() >= 2 and c[0] != null:
				var secs := "a computed time" if c[1] == null else "%d s" % c[1]
				var txt := "reinforcement %d arrives after %s" % [c[0], secs]
				if c[1] != null and int(c[1]) <= 0:
					txt = "reinforcement %d is cancelled" % c[0]
				_use(out, "zones", c[0], "%s %s (it appears at this zone)" % [txt, when["text"]])
				_edit(out, a[1], rid, f, base, "s", "%s: seconds (%s)" % [txt, when["text"]], 0, 32767)
		N_ONE_SHOT:
			if not a.is_empty():
				_edit(out, a[0], rid, f, base, "ms", "a delay of the script (ms), %s" % when["text"], 0, 32767)
		_:
			if i >= N_GRP_FIRST and i <= N_GRP_LAST and i != N_REINFORCE:
				_order(out, nd, c, when, role, rid, f, base)


static func _objs_of(c: Array) -> String:
	var p := PackedStringArray()
	for k in 3:
		if c[k + 1] != null and c[k + 1] != 0:
			p.append(str(k + 1))
	return ", ".join(p)


func _order(out: Dictionary, nd: Dictionary, c: Array, when: Dictionary, role: String, rid: int, f: int,
		base: int) -> void:
	var i: int = nd["i"]
	var a: Array = nd["args"]
	var g: int = int(c[0]) if not c.is_empty() and c[0] != null else -1
	var od := {"group": g, "order": "other", "zones": [], "target": -1, "native": i, "when": when,
		"start": when["event"] == 97, "text": "", "edit": {}, "res": rid, "frame": f}
	var who := "group %d" % g if g > 0 else "the group of the event" if g == 0 else "a computed group"
	if not a.is_empty():
		od["edit"]["group"] = _edit(out, a[0], rid, f, base, "group", "%s: which group gets it" % _order_name(i), 1, 31)
	var txt := ""
	match i:
		N_GRP_MOVE:
			od["order"] = "move"
			txt = "goes to zone %s" % _n(c, 1)
			_zone_arg(out, od, a, c, 1, rid, f, base, "%s goes there" % who, when)
		N_GRP_PATROL:
			od["order"] = "patrol"
			txt = "patrols zones %s, %s, %s" % [_n(c, 1), _n(c, 2), _n(c, 3)]
			for k in [1, 2, 3]:
				_zone_arg(out, od, a, c, k, rid, f, base, "%s patrols through it" % who, when)
		N_GRP_HOLD_ZONE:
			od["order"] = "hold_zone"
			if c.size() > 1 and c[1] != null and int(c[1]) == 0:
				txt = "is released from its zone"
			else:
				txt = "holds zone %s" % _n(c, 1)
				_zone_arg(out, od, a, c, 1, rid, f, base, "%s holds it" % who, when)
		N_GRP_ATTACK_GROUP:
			od["order"] = "attack_group"
			od["target"] = int(c[1]) if c.size() > 1 and c[1] != null else -1
			txt = "attacks group %s" % _n(c, 1)
			if a.size() > 1:
				od["edit"]["target"] = _edit(out, a[1], rid, f, base, "group", "the group attacked by %s" % who, 0, 31)
			_use(out, "groups", od["target"], "%s is sent to attack it %s" % [who, when["text"]])
		N_GRP_ATTACK_LABEL, N_GRP_FOLLOW:
			od["order"] = "attack_label" if i == N_GRP_ATTACK_LABEL else "follow"
			od["target"] = int(c[1]) if c.size() > 1 and c[1] != null else -1
			var verb := "attacks" if i == N_GRP_ATTACK_LABEL else "follows"
			txt = "%s the units labelled %s" % [verb, _n(c, 1)]
			if a.size() > 1:
				od["edit"]["target"] = _edit(out, a[1], rid, f, base, "label", "the label %s %s" % [who, verb], 1, 127)
			_use(out, "labels", od["target"], "%s %s them %s" % [who, verb, when["text"]])
		N_GRP_STOP_FOLLOW:
			od["order"] = "stop_follow"
			txt = "stops following"
		N_GRP_LINK:
			od["order"] = "link"
			od["target"] = int(c[1]) if c.size() > 1 and c[1] != null else -1
			txt = "is linked with group %s" % _n(c, 1) if od["target"] != 0 else "is unlinked from the other groups"
			if od["target"] > 0:
				_use(out, "groups", od["target"], "%s is linked with it %s" % [who, when["text"]])
		N_GRP_TACTIC:
			od["order"] = "tactic"
			txt = "takes tactic value %s" % _n(c, 1)
		_:
			var parts := PackedStringArray()
			for k in range(1, c.size()):
				parts.append(_n(c, k))
			txt = "gets command %d (%s)" % [i, ", ".join(parts)]
	od["text"] = "%s %s" % [txt, when["text"]]
	out["orders"].append(od)
	if g > 0:
		_use(out, "groups", g, "it %s" % od["text"])


static func _order_name(i: int) -> String:
	match i:
		N_GRP_MOVE:
			return "go to a zone"
		N_GRP_PATROL:
			return "patrol"
		N_GRP_HOLD_ZONE:
			return "hold a zone"
		N_GRP_ATTACK_GROUP:
			return "attack a group"
		N_GRP_ATTACK_LABEL:
			return "attack a label"
		N_GRP_FOLLOW:
			return "follow a label"
		N_GRP_LINK:
			return "link with a group"
	return "command %d" % i


static func _n(c: Array, k: int) -> String:
	return str(c[k]) if k < c.size() and c[k] != null else "?"


func _zone_arg(out: Dictionary, od: Dictionary, a: Array, c: Array, k: int, rid: int, f: int, base: int,
		what: String, when: Dictionary) -> void:
	if k >= a.size():
		return
	if c[k] != null:
		od["zones"].append(int(c[k]))
		_use(out, "zones", c[k], "%s %s" % [what, when["text"]])
	od["edit"]["zone%d" % k] = _edit(out, a[k], rid, f, base, "zone", "%s (zone, %s)" % [what, when["text"]], 0, 127)


# a condition of the script: what it waits for (a group starting, a label dying, a zone entered...)
func _watch(out: Dictionary, guards: Array, s: Dictionary, role: String) -> void:
	if s["k"] != "ifnot":
		return
	var g2 := guards.duplicate()
	g2.append({"to": 0, "type": -1, "e": s["e"]})
	var w := _when(g2, role)
	match w["event"]:
		97:
			_use(out, "groups", w["group"], "the script gives orders when it starts (no unit in it: those orders are never given)")
		108:
			_use(out, "labels", w["label"], "the script reacts when one of them dies")
		109:
			_use(out, "groups", w["group"], "the script reacts when it is wiped out")
		110:
			if w["zone"] >= 0:
				_use(out, "zones", w["zone"], "the script reacts %s" % w["text"])
			if w["group"] >= 0:
				_use(out, "groups", w["group"], "the script reacts %s" % w["text"])
		_:
			if w["event"] >= 0 and w["group"] >= 0:
				_use(out, "groups", w["group"], "the script reacts to its event %d" % w["event"])
