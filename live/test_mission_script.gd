# Test of the mission scripts' reader and writer (scripts/babl.gd, mission_script.gd, mission_build.gd, res_file.gd).
# Without the game: code built with babl.gd's Asm reads back as the statements it was built from, a module taken
# apart and put back is the same, shift() moves the branch targets, an LG Res file is written back as read.
# With the game (TN_GAME_DIR, or one of tn_data.gd's usual places): every script module of RESBABL2.RES is read
# without an unknown opcode, every mission has its summary, and missions 37 and 8 say what the game does; then, on
# a COPY of the three data files in the test's own folder (never in the game's): numbers changed in place, scripts
# rebuilt from blocks, a new mission written in slot 18, the game's files kept and put back.
#   godot --headless --path . --script res://live/test_mission_script.gd [-- dump N]
extends SceneTree

const Babl := preload("res://scripts/babl.gd")
const MissionScript := preload("res://scripts/mission_script.gd")
const MissionBuild := preload("res://scripts/mission_build.gd")
const ResFile := preload("res://scripts/res_file.gd")
const MissionNew := preload("res://scripts/mission_new.gd")
const TNData := preload("res://scripts/tn_data.gd")

var fails := 0
var checks := 0


func _check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print(("ok   " if ok else "FAIL ") + what)


func _initialize() -> void:
	_synthetic()
	var root := TNData.find_root(OS.get_environment("TN_GAME_DIR"))
	if root == "":
		print("(no game found: the checks on the game's own scripts are skipped)")
	else:
		_game(root.path_join("TNOVA/DATA"))
		_write(root.path_join("TNOVA/DATA"))
	print("%d checks, %d failed" % [checks, fails])
	quit(1 if fails else 0)


func _synthetic() -> void:
	# a director as the game's compiler writes it
	var name0 := "missX".to_ascii_buffer()
	name0.resize(11)
	var a := Babl.Asm.new(name0.size())
	a.enter(0)
	a.label("loop")
	a.msg_wait()
	a.msg_type_not(97, "free")
	a.msg_field(0, 30)
	a.imm(129)
	a.op(0x19)
	a.ifnot("free")
	a.msg_field(0, 31)
	a.imm(1)
	a.op(0x19)
	a.ifnot("free")
	a.native(MissionScript.N_GRP_PATROL, [1, 4, 5, 6])
	a.drop()
	a.native(MissionScript.N_GRP_MOVE, [2, 300])
	a.drop()
	a.label("free")
	a.op(Babl.OP_MSG_FREE)
	a.goto("loop")
	a.ret()
	var code := a.done()
	_check(not code.is_empty(), "the assembler resolves its labels")
	var frames := [name0, code]
	var mod := Babl.join(frames)
	var back := Babl.split(mod)
	_check(back.get("name", "") == "missX" and back["frames"].size() == 2 and back["frames"][1] == code,
		"a module taken apart is the one put together")
	var st = Babl.lift(code, Babl.base_of(frames, 1))
	_check(st != null, "the built function reads back")
	var calls := []
	for s in st:
		for nd in Babl.stmt_nodes(s):
			if nd["k"] == "nat":
				calls.append(Babl.text(nd, MissionScript.NAMES))
	_check(calls == ["GrpPatrolZones(1, 4, 5, 6)", "GrpMoveToZone(2, 300)"], "its calls: %s" % str(calls))
	var free_at := -1
	for s in st:
		if s["k"] == "msg_free":
			free_at = s["at"]
	var ok_t := true
	for s in st:
		if s["k"] == "msgtype" or s["k"] == "ifnot":
			ok_t = ok_t and s["to"] == free_at
	_check(ok_t and free_at > 0, "its branches go to the message's release")
	# 5 bytes added in front of the function: every target follows
	var before: int = st[1]["at"]
	_check(Babl.shift(frames, name0.size(), 5), "shift accepts the function")
	var st2 = Babl.lift(frames[1], Babl.base_of(frames, 1))
	var moved := true
	for i in st.size():
		if st[i].has("to"):
			moved = moved and st2[i]["to"] == st[i]["to"] + 5
	_check(moved and st2[1]["at"] == before, "every branch target moved by 5")
	_check(Babl.walk(PackedByteArray([0x01, 0x02, 0x47])) == null, "an unknown opcode is refused")
	_check(Babl.walk(PackedByteArray([0x03, 0x02])) == null, "an instruction cut short is refused")
	# an LG Res file: built, read, changed, built again
	var rf := ResFile.empty()
	ResFile.add(rf, 170, 0, 0, "map5.res".to_ascii_buffer())
	ResFile.add(rf, 173, 0, 2, ResFile.compound([PackedByteArray([1, 2, 3]), PackedByteArray()]))
	ResFile.add(rf, 900, 1, 2, ResFile.strings(["Tu\u00E9s", "plain"]))
	var bytes := ResFile.build(rf)
	var rb := ResFile.parse(bytes)
	_check(rb.get("entries", []).size() == 3 and ResFile.data(rb, 170) == "map5.res".to_ascii_buffer()
		and ResFile.items(ResFile.data(rb, 173)).size() == 2, "an LG Res file reads back as built")
	_check(ResFile.build(rb) == bytes, "and is written back byte for byte")
	var st850: Array = ResFile.items(ResFile.data(rb, 900))
	_check(st850[0] == PackedByteArray([0x54, 0x75, 0x82, 0x73, 0]), "texts are stored in the game's code page")
	_check(ResFile.parse(bytes.slice(0, bytes.size() - 4)).is_empty(), "a file cut short is refused")


func _game(data_dir: String) -> void:
	var ms = MissionScript.open(data_dir)
	_check(ms != null, "RESBABL2.RES opens (%s)" % data_dir)
	if ms == null:
		return
	var args := OS.get_cmdline_user_args()
	if args.size() >= 2 and args[0] == "dump":
		_dump(ms, int(args[1]))
	_check(ms.modules.size() == 47, "47 script modules (%d)" % ms.modules.size())
	var unread := 0
	var functions := 0
	for rid in ms.modules:
		var frames: Array = ms.modules[rid]["frames"]
		for f in range(1, frames.size()):
			functions += 1
			if ms.statements(rid, f) == null:
				unread += 1
				print("     unread: %s.%d" % [ms.module_name(rid), f])
	_check(unread == 0, "every function of every module is read (%d functions)" % functions)
	var bad := 0
	var list: Array = ms.missions()
	for n in list:
		var s: Dictionary = ms.summary(n)
		if not s["ok"] or s["objectives"].size() != 3:
			bad += 1
			print("     mission %d: %s" % [n, s["error"]])
	_check(bad == 0 and list.size() >= 44, "every mission of do3d has its summary (%d missions)" % list.size())
	# mission 37: objective 3 = destroy 100 % of label 2; groups 1 and 2 patrol zones 1-2-3 and 4-5-6
	var s37: Dictionary = ms.summary(37)
	var o3: Dictionary = s37["objectives"][2]
	_check(o3["kind"] == "kill" and o3["conditions"][0]["label"] == 2 and o3["conditions"][0]["pct"] == 100,
		"37: objective 3 = %s" % o3["what"])
	_check(s37["objectives"][0]["kind"] == "none" and s37["objectives"][1]["kind"] == "none",
		"37: objectives 1 and 2 are not used")
	_check(_patrol(s37, 1) == [1, 2, 3] and _patrol(s37, 2) == [4, 5, 6],
		"37: groups 1 and 2 patrol zones 1-2-3 and 4-5-6")
	_check(MissionScript.uses(s37, "label", 2).size() >= 1 and MissionScript.uses(s37, "zone", 5).size() >= 1
		and MissionScript.uses(s37, "group", 1).size() >= 2, "37: label 2, zone 5 and group 1 are known as used")
	# mission 8: objective 2 = ID-lock a label-1 item for 5 s; groups 2, 3 patrol; 9, 10 go to zone 9, 11 to 18
	var s8: Dictionary = ms.summary(8)
	var o2: Dictionary = s8["objectives"][1]
	_check(o2["kind"] == "idlock" and o2["conditions"][0]["label"] == 1 and o2["conditions"][0]["ms"] == 5000,
		"8: objective 2 = %s" % o2["what"])
	_check(_patrol(s8, 2) == [12, 13, 14] and _patrol(s8, 3) == [15, 16, 17],
		"8: groups 2 and 3 patrol zones 12-13-14 and 15-16-17")
	_check(_move(s8, 9) == 9 and _move(s8, 10) == 9 and _move(s8, 11) == 18,
		"8: groups 9 and 10 go to zone 9, group 11 to zone 18")
	_check(s8["objectives"][0]["kind"] == "none" and s8["objectives"][2]["kind"] == "none",
		"8: objectives 1 and 3 are not used")


func _patrol(s: Dictionary, g: int) -> Array:
	for od in s["orders"]:
		if od["group"] == g and od["order"] == "patrol" and od["start"]:
			return od["zones"]
	return []


func _move(s: Dictionary, g: int) -> int:
	for od in s["orders"]:
		if od["group"] == g and od["order"] == "move" and od["start"]:
			return od["zones"][0]
	return -1


func _dump(ms, n: int) -> void:
	var list: Array = [n] if n > 0 else ms.missions()
	for m in list:
		var s: Dictionary = ms.summary(m)
		print("=== mission %d %s (%s): main %d debrief %d director %d %s" % [m, s["name"], s["module"], s["main"],
			s["debrief"], s["director"], s["error"]])
		for o in s["objectives"]:
			print("  objective %d [%s] %s: %s | %s" % [o["n"], o["kind"], o["text"], o["what"], "; ".join(o["custom"])])
		for od in s["orders"]:
			print("  order: group %d %s" % [od["group"], od["text"]])
		for kind in ["labels", "groups", "zones"]:
			var ks: Array = s[kind].keys()
			ks.sort()
			for k in ks:
				print("  %s %d: %s" % [kind, k, " / ".join(s[kind][k])])
		for note in s["notes"]:
			print("  note: %s" % note)
		print("  edits: %d" % s["edits"].size())


# ---- writing, on a copy
func _write(game_data: String) -> void:
	var dir := OS.get_user_data_dir().path_join("test_mission_script")
	_check(not dir.contains("Program Files") and not dir.contains("steamapps"), "the test writes in its own folder (%s)" % dir)
	if dir.contains("Program Files") or dir.contains("steamapps"):
		return
	DirAccess.make_dir_recursive_absolute(dir)
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	for f in ["RESBABL2.RES", "RESGAME.RES", "RESMISS.RES", "MISS37.RES"]:
		DirAccess.copy_absolute(game_data.path_join(f), dir.path_join(f))
	var game_file := FileAccess.get_file_as_bytes(game_data.path_join("RESBABL2.RES"))
	var mo = MissionScript.open(dir, true)
	_check(mo != null, "the copy opens")
	if mo == null:
		return
	# the file rebuilt with nothing changed is the game's
	var same: Dictionary = mo.file_bytes()
	_check(same["error"] == "" and same["bytes"] == game_file, "RESBABL2.RES is written back byte for byte")
	# --- numbers changed in place: mission 37, objective 3 = 80 % of label 3, group 2 patrols 4-5-7
	var s37: Dictionary = mo.summary(37)
	var cond: Dictionary = s37["objectives"][2]["conditions"][0]
	var order2 := {}
	for od in s37["orders"]:
		if od["group"] == 2 and od["order"] == "patrol":
			order2 = od
	var changes := [mo.change(s37["edits"][cond["edit"]["pct"]], 80), mo.change(s37["edits"][cond["edit"]["label"]], 3),
		mo.change(s37["edits"][order2["edit"]["zone3"]], 7)]
	_check(not changes[0].has("error") and changes[0]["old"] == 100 and changes[0]["sum"].length() == 16,
		"a change is made: %s" % JSON.stringify(changes[0]))
	_check(mo.change(s37["edits"][cond["edit"]["pct"]], 101).has("error"), "101 % is refused")
	var err := MissionBuild.install(dir, {"patch": changes})
	_check(err == "", "the changes are installed %s" % err)
	_check(FileAccess.get_file_as_bytes(dir.path_join("RESBABL2.RES.uplink-original")) == game_file,
		"the game's file is kept beside it")
	var now = MissionScript.open(dir)
	var n37: Dictionary = now.summary(37)
	var c2: Dictionary = n37["objectives"][2]["conditions"][0]
	_check(c2["pct"] == 80 and c2["label"] == 3 and _patrol(n37, 2) == [4, 5, 7] and _patrol(n37, 1) == [1, 2, 3],
		"the installed script says: %s; group 2 patrols %s" % [n37["objectives"][2]["what"], str(_patrol(n37, 2))])
	var diff := 0
	var gf := ResFile.parse(game_file)
	for e in now.raw["entries"]:
		if e["raw"] != ResFile.data(gf, e["id"]):
			diff += 1
	_check(diff == 1, "one resource of the file differs (%d)" % diff)
	# what a pasted code must not do
	var bad: Dictionary = changes[0].duplicate()
	bad["sum"] = "0000000000000000"
	_check(mo.check_change(bad) != "", "a change for another version of the function is refused")
	bad = changes[0].duplicate()
	bad["off"] = int(bad["off"]) + 1
	_check(mo.check_change(bad) != "", "a change beside a number is refused")
	bad = changes[0].duplicate()
	bad["new"] = 1000
	_check(mo.check_change(bad) != "", "a value that does not fit is refused")
	bad = changes[0].duplicate()
	bad["old"] = 99
	_check(mo.check_change(bad) != "", "a change whose old value is not the game's is refused")
	_check(MissionBuild.install(dir, {"patch": [changes[0], changes[0]]}) != "", "the same number twice is refused")
	# a second install starts from the game's file again, not from the changed one
	err = MissionBuild.install(dir, {"patch": [changes[0]]})
	var again = MissionScript.open(dir)
	_check(err == "" and again.summary(37)["objectives"][2]["conditions"][0]["label"] == 2,
		"a new install starts from the game's own file")
	err = MissionBuild.install(dir, {})
	_check(err == "" and FileAccess.get_file_as_bytes(dir.path_join("RESBABL2.RES")) == game_file,
		"an empty script part puts the game's file back")
	# --- a function replaced by a longer one: the functions after it keep their meaning
	var cp = mo.copy()
	var frames: Array = cp.modules[1071]["frames"]
	var before2 = Babl.lift(frames[2], Babl.base_of(frames, 2))
	var before3 = Babl.lift(frames[3], Babl.base_of(frames, 3))
	var longer: PackedByteArray = frames[1].duplicate()
	longer.append_array(PackedByteArray([0x7F, 0, 0, 0x7F, 0, 0, 0x7F, 0, 0]))
	_check(MissionBuild._replace(frames, 1, longer), "a function is replaced by a longer one")
	var after2 = Babl.lift(frames[2], Babl.base_of(frames, 2))
	var after3 = Babl.lift(frames[3], Babl.base_of(frames, 3))
	var moved: bool = after2.size() == before2.size() and after3.size() == before3.size()
	for pair in [[before2, after2], [before3, after3]]:
		for i in pair[0].size():
			moved = moved and pair[1][i]["at"] == pair[0][i]["at"] + 9 and pair[1][i]["k"] == pair[0][i]["k"]
			if pair[0][i].has("to"):
				moved = moved and pair[1][i]["to"] == pair[0][i]["to"] + 9
	_check(moved, "the functions after it and their branch targets moved with it")
	# --- scripts built from blocks: the empty slot 18, and mission 37 rebuilt
	var before := {}
	for n in mo.missions():
		before[n] = JSON.stringify(mo.summary(n))
	var spec18 := {"mission": 18,
		"objectives": [[{"kind": "idlock", "label": 4, "ms": 3000}], [{"kind": "kill", "label": 2, "pct": 50}],
			[{"kind": "kill", "label": 2, "pct": 100}, {"kind": "alive", "label": 3, "pct": 100}]],
		"orders": [{"group": 1, "order": "patrol", "zones": [1, 2, 3]}, {"group": 2, "order": "move", "zone": 4},
			{"group": 3, "order": "hold_zone", "zone": 5}, {"group": 4, "order": "attack_group", "target": 1, "on": 1},
			{"group": 5, "order": "follow", "label": 3}, {"group": 6, "order": "attack_label", "label": 3},
			{"group": 6, "order": "link", "target": 1}],
		"end": {"objective": 3, "seconds": 8},
		"debrief": ["Locked.", "Half of them.", "All of them, and the truck lives.", "Nothing done."]}
	var spec37 := {"mission": 37, "objectives": [null, null, [{"kind": "kill", "label": 2, "pct": 60}]],
		"orders": [{"group": 1, "order": "patrol", "zones": [3, 2, 1]}]}
	var made := MissionBuild.make(dir, {"build": [spec18, spec37]})
	_check(made["error"] == "", "two scripts are built %s" % made["error"])
	if made["error"] != "":
		return
	var b = made["ms"]
	var b18: Dictionary = b.summary(18)
	var kinds := []
	for o in b18["objectives"]:
		kinds.append(o["kind"])
	_check(b18["ok"] and kinds == ["idlock", "kill", "combined"], "18 reads back: %s" % str(kinds))
	_check(b18["objectives"][0]["conditions"][0]["label"] == 4 and b18["objectives"][0]["conditions"][0]["ms"] == 3000
		and b18["objectives"][1]["conditions"][0]["pct"] == 50 and b18["objectives"][2]["conditions"].size() == 2,
		"18: %s / %s / %s" % [b18["objectives"][0]["what"], b18["objectives"][1]["what"], b18["objectives"][2]["what"]])
	var got := []
	for od in b18["orders"]:
		got.append("%d %s %s %d on %d" % [od["group"], od["order"], str(od["zones"]), od["target"], od["when"]["group"]])
	_check(got == ["1 patrol [1, 2, 3] -1 on 1", "4 attack_group [] 1 on 1", "2 move [4] -1 on 2",
		"3 hold_zone [5] -1 on 3", "5 follow [] 3 on 5", "6 attack_label [] 3 on 6", "6 link [] 1 on 6"],
		"18: its orders read back (%s)" % str(got))
	_check(b18["debrief"] == 3 and b.table[18]["debrief"] == [1029, 3], "18 has a debriefing function now")
	var b37: Dictionary = b.summary(37)
	_check(b37["objectives"][2]["kind"] == "kill" and b37["objectives"][2]["conditions"][0]["pct"] == 60
		and _patrol(b37, 1) == [3, 2, 1] and _patrol(b37, 2) == [], "37 rebuilt: %s" % b37["objectives"][2]["what"])
	var others := 0
	for n in mo.missions():
		if n != 18 and n != 37 and JSON.stringify(b.summary(n)) != before[n]:
			others += 1
			print("     mission %d changed" % n)
	_check(others == 0, "no other mission's script changed")
	err = MissionBuild.install(dir, {"build": [spec18, spec37]})
	var inst = MissionScript.open(dir)
	_check(err == "" and inst != null and JSON.stringify(inst.summary(18)["objectives"]) == JSON.stringify(b18["objectives"]),
		"the built scripts are installed and read back from the file %s" % err)
	var texts: Array = ResFile.items(ResFile.data(inst.raw, 1030))
	_check(texts.size() == 4 and texts[3].get_string_from_ascii() == "Nothing done.", "18's debriefing texts are in the file")
	# what a spec must not do
	var bad_spec: Dictionary = spec18.duplicate(true)
	bad_spec["mission"] = 41
	_check(MissionBuild.make(dir, {"build": [bad_spec]})["error"] != "", "a mission sharing its script is refused")
	bad_spec = spec18.duplicate(true)
	bad_spec["orders"][0]["group"] = 32
	_check(MissionBuild.make(dir, {"build": [bad_spec]})["error"] != "", "group 32 is refused")
	bad_spec = spec18.duplicate(true)
	bad_spec["objectives"][1].append({"kind": "idlock", "label": 1, "ms": 1000})
	_check(MissionBuild.make(dir, {"build": [bad_spec]})["error"] != "", "an ID lock joined with a kill is refused")
	_check(MissionBuild.make(dir, {"build": [spec37], "patch": [changes[0]]})["error"] != "",
		"a script both rebuilt and changed in place is refused")
	err = MissionBuild.install(dir, {})
	_check(err == "" and FileAccess.get_file_as_bytes(dir.path_join("RESBABL2.RES")) == game_file,
		"the game's file is put back")
	_new_mission(dir, game_data)


# ---- a brand new mission in an empty slot
func _new_mission(dir: String, game_data: String) -> void:
	var game_texts := FileAccess.get_file_as_bytes(game_data.path_join("RESGAME.RES"))
	var game_names := FileAccess.get_file_as_bytes(game_data.path_join("RESMISS.RES"))
	var like := ResFile.read(game_data.path_join("MISS37.RES"))
	var src: PackedByteArray = ResFile.items(ResFile.data(like, 173))[0]
	var new18 := {"slot": 18, "like": "MISS37.RES",
		"zones": [[0, 256 << 16, 209 << 16], [31, 261 << 16, 217 << 16], [4, 228 << 16, 185 << 16]],
		"sides": {"3": 1},
		"add": [{"from": "MISS37.RES", "rec": 0, "label": 7, "g": 3, "x": 258 << 16, "o": [27, 1]}],
		"name": "OPERATION TEST", "objectives": ["First", "", "Third"]}
	var err := MissionNew.install(dir, new18)
	_check(err == "", "a new mission is written in slot 18 %s" % err)
	var f := ResFile.read(dir.path_join("MISS18.RES"))
	var ids := []
	for e in f.get("entries", []):
		ids.append(e["id"])
	_check(ids == [170, 171, 172, 173, 174, 175, 176, 177, 178, 180, 181, 182], "it has the twelve resources of a mission")
	var units: Array = ResFile.items(ResFile.data(f, 173))
	var u: PackedByteArray = units[0] if units.size() == 1 else PackedByteArray()
	var same_rest := u.size() == 50
	if same_rest:
		for o in range(6, 50):
			if not [7, 8, 9, 10, 11, 26, 27].has(o):
				same_rest = same_rest and u[o] == src[o]
	_check(same_rest and u[26] == 7 and u[7] == 3 and u.decode_s32(8) == 258 << 16 and u[27] == 1
		and u.decode_u16(2) == 1 and u.decode_u16(4) == 1, "its unit is the game's record with what was asked changed")
	var z := ResFile.data(f, 176)
	_check(z.size() == 1024 and z.decode_s32(0) == 256 << 16 and z.decode_s32(8 * 31 + 4) == 217 << 16
		and z.decode_s32(8 * 4) == 228 << 16 and z.decode_s32(8) == 0, "its zones are where they were put")
	_check(ResFile.data(f, 174)[3] == 1 and ResFile.data(f, 174)[4] == 2 and ResFile.data(f, 180) == PackedByteArray([4, 0])
		and ResFile.data(f, 178) == ResFile.data(like, 178) and ResFile.data(f, 181).size() == 1604
		and ResFile.data(f, 182).size() == 1280, "sides, version, parameters, reinforcements and shapes as the game's files")
	var map_name := ResFile.data(f, 170).slice(0, 9).get_string_from_ascii()
	_check(map_name == ResFile.data(like, 170).slice(0, 9).get_string_from_ascii() and ResFile.data(f, 170).size() == 80,
		"it takes the map of the mission it is like (%s)" % map_name)
	var ms = MissionScript.open(dir)
	_check(ms.obj_texts.size() == 144 and ms.obj_texts[54] == "First" and ms.obj_texts[56] == "Third"
		and ms.mission_names[17] == "OPERATION TEST" and ms.obj_texts[57] != "", "its name and objective lines are in the game's tables")
	var mo = MissionScript.open(dir, true)
	_check(mo.mission_names[17] != "OPERATION TEST" and FileAccess.get_file_as_bytes(dir.path_join("RESGAME.RES.uplink-original")) == game_texts,
		"the game's own tables are kept beside")
	# what a creation must not do
	var bad: Dictionary = new18.duplicate(true)
	bad["zones"].remove_at(1)
	_check(MissionNew.mission_file(dir, bad)["error"] != "", "a mission without its pickup zone is refused")
	bad = new18.duplicate(true)
	bad["slot"] = 19
	_check(MissionNew.mission_file(dir, bad)["error"] != "", "slot 19 is refused")
	bad = new18.duplicate(true)
	bad["like"] = "..\\MISS37.RES"
	_check(MissionNew.mission_file(dir, bad)["error"] != "", "a path in place of a mission name is refused")
	bad = new18.duplicate(true)
	bad["add"][0]["rec"] = 99
	_check(MissionNew.mission_file(dir, bad)["error"] != "", "a unit copied from a record the game does not have is refused")
	bad = new18.duplicate(true)
	bad["add"][0]["g"] = 32
	_check(MissionNew.mission_file(dir, bad)["error"] != "", "group 32 is refused")
	DirAccess.copy_absolute(game_data.path_join("MISS37.RES"), dir.path_join("MISS28.RES"))
	bad = new18.duplicate(true)
	bad["slot"] = 28
	_check(MissionNew.install(dir, bad) != "" and FileAccess.get_file_as_bytes(dir.path_join("MISS28.RES"))
		== FileAccess.get_file_as_bytes(game_data.path_join("MISS37.RES")), "a mission file that is not Uplink's is never replaced")
	_check(MissionNew.remove(dir, 28) != "" and FileAccess.file_exists(dir.path_join("MISS28.RES")), "nor removed")
	err = MissionNew.remove(dir, 18)
	_check(err == "" and not FileAccess.file_exists(dir.path_join("MISS18.RES"))
		and FileAccess.get_file_as_bytes(dir.path_join("RESGAME.RES")) == game_texts
		and FileAccess.get_file_as_bytes(dir.path_join("RESMISS.RES")) == game_names, "the new mission is removed, the game's tables are back")
