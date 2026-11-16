# Test of the mission scripts' reader (scripts/babl.gd, scripts/mission_script.gd).
# Without the game: code built with babl.gd's Asm reads back as the statements it was built from, a module taken
# apart and put back is the same, shift() moves the branch targets.
# With the game (TN_GAME_DIR, or one of tn_data.gd's usual places): every script module of RESBABL2.RES is read
# without an unknown opcode, every mission has its summary, and missions 37 and 8 say what the game does.
#   godot --headless --path . --script res://live/test_mission_script.gd [-- dump N]
extends SceneTree

const Babl := preload("res://scripts/babl.gd")
const MissionScript := preload("res://scripts/mission_script.gd")
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
