# The mission scripts' and new missions' writers from a command line (tests, and a look at what a script says):
#   godot --headless --path . --script res://live/mission_tool.gd -- summary DATA_DIR MISSION
#   godot --headless --path . --script res://live/mission_tool.gd -- install DATA_DIR CREATION.json
#   godot --headless --path . --script res://live/mission_tool.gd -- remove DATA_DIR
#   godot --headless --path . --script res://live/mission_tool.gd -- refs DATA_DIR      (every mission's refs(), JSON)
# DATA_DIR: a TNOVA\DATA folder (install and remove write there: give a copy). CREATION.json: {"new": {...} (see
# scripts/mission_new.gd), "script": {"patch": [...], "build": [...]} (see scripts/mission_build.gd)}.
extends SceneTree

const MissionScript := preload("res://scripts/mission_script.gd")
const MissionBuild := preload("res://scripts/mission_build.gd")
const MissionNew := preload("res://scripts/mission_new.gd")


func _initialize() -> void:
	var a := OS.get_cmdline_user_args()
	var code := 2
	if a.size() >= 3 and a[0] == "summary":
		code = _summary(a[1], int(a[2]))
	elif a.size() >= 3 and a[0] == "install":
		code = _install(a[1], a[2])
	elif a.size() >= 2 and a[0] == "refs":
		var ms = MissionScript.open(a[1], true)
		var all := {}
		for n in ms.missions():
			all["MISS%d.RES" % n] = ms.refs(n)
		print("REFS " + JSON.stringify(all))
		code = 0
	elif a.size() >= 2 and a[0] == "remove":
		code = _remove(a[1])
	else:
		print("usage: summary DATA_DIR MISSION | install DATA_DIR CREATION.json | remove DATA_DIR")
	quit(code)


func _summary(dir: String, n: int) -> int:
	var ms = MissionScript.open(dir)
	if ms == null:
		print("RESBABL2.RES was not found in %s" % dir)
		return 1
	var s: Dictionary = ms.summary(n)
	if not s["ok"]:
		print(s["error"])
		return 1
	print("mission %d  %s  (%s)" % [n, s["name"], s["module"]])
	for o in s["objectives"]:
		print("  objective %d [%s] \"%s\": %s%s" % [o["n"], o["kind"], o["text"], o["what"],
			("  (" + "; ".join(o["custom"]) + ")") if not o["custom"].is_empty() else ""])
	for od in s["orders"]:
		print("  group %d %s" % [od["group"], od["text"]])
	for kind in ["labels", "groups", "zones"]:
		var ks: Array = s[kind].keys()
		ks.sort()
		for k in ks:
			print("  %s %d: %s" % [kind.trim_suffix("s"), k, " / ".join(s[kind][k])])
	for note in s["notes"]:
		print("  note: %s" % note)
	return 0


func _install(dir: String, file: String) -> int:
	var c = JSON.parse_string(FileAccess.get_file_as_string(file))
	if not (c is Dictionary):
		print("%s is not a creation" % file)
		return 1
	if c.has("new"):
		var e := MissionNew.install(dir, c["new"])
		if e != "":
			print("new mission: %s" % e)
			return 1
		print("new mission: %s written" % MissionNew.file_name(int(c["new"]["slot"])))
	var e2 := MissionBuild.install(dir, c.get("script", {}))
	if e2 != "":
		print("script: %s" % e2)
		return 1
	print("script: installed")
	return 0


func _remove(dir: String) -> int:
	var e := MissionBuild.install(dir, {})
	for slot in MissionNew.SLOTS:
		if e == "":
			e = MissionNew.remove(dir, slot)
	if e != "":
		print(e)
		return 1
	print("the game's own files are back")
	return 0
