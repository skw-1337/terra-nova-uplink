# Every key of Terra Nova Uplink, as one model for the in-game menu's Controls page (uplink_menu.gd). The list is
# data/controls.txt, which the launcher's Controls page reads as well (TerraNovaUplink.cs, Controls), with the same
# rules:
# - the game's commands are Terra Nova Plus's (its TNPlus.ini next to this Uplink: tnplus\, else tnplus_coop\):
#   key_game_<id> = [SHIFT+|CTRL+|ALT+]scancode, written only when not as it comes, mouse_<id> = MID / M4 / M5 /
#   WHEELUP / WHEELDOWN / PGUP..., its own keys key_freelook... Read as TN+ reads them (its keys' version 4: freelook
#   on F and Centre view without a key; settings with keys from before keep freelook on Y, Centre view on F, and a
#   plain game key on one of TN+'s own goes to a spare key). TN+ reads its settings when the game starts: a host's
#   game keys change at the next start; a guest's are turned by his own Uplink (the viewer's key_map): at once.
# - Uplink's own keys are the launcher's (TN_KEY_* when it starts this window). A change made here is kept in this
#   Uplink's viewer.cfg, [launcher] key_<id>, with the time it was made: the launcher takes it over (it reads that
#   section when it starts and whenever its window comes to the front) and gives it again at the next start.
# Keys are physical places (a key's position, as the game reads them): AZERTY or QWERTY, the same command stays on
# the same key; its name is the one printed there on this keyboard.
extends RefCounted

const CFG := "user://viewer.cfg"
const SPARE := [0x25, 0x26, 0x27, 0x08, 0x09, 0x0A, 0x0B]      # TN+: a game key on one of its own goes to the first free
const TOOL_IDS := ["freelook", "noclip", "distance", "stereo"]
const MOUSE_INI := ["", "MID", "M4", "M5", "WHEELUP", "WHEELDOWN", "PGUP", "PGDN", "HOME", "END", "INS", "DEL"]
const MOUSE_SHORT := ["", "Middle", "Mouse 4", "Mouse 5", "Wheel up", "Wheel down", "PgUp", "PgDn", "Home", "End", "Ins", "Del"]
const MID := -1                    # an Uplink key on a mouse button (the order wheel's)
const M4 := -2
const M5 := -3
# Uplink's own keys: the environment the launcher gives (as TN_KEY_<NAME>), the launcher's ini name
const UPLINK_ENV := {"menu": "TN_KEY_MENU", "order": "TN_ORDER_KEY", "photo": "TN_KEY_PHOTO", "oldschool": "TN_KEY_OLDSCHOOL",
		"sharp": "TN_KEY_SHARP", "shot": "TN_KEY_SHOT", "fps": "TN_KEY_FPS"}

var cmds := []                     # each: {group, id, name, kind ("game", "fixed", "tnplus", "uplink"), def: [sc, mods], key: [sc, mods], mouse}
var ini_path := ""                 # TN+'s settings ("": none found: the game's keys are shown, not kept)
var scancodes := {}                # Godot's physical key -> PC scancode (viewer.gd SCANCODES)


func _init() -> void:
	scancodes = load("res://scripts/viewer.gd").SCANCODES
	reload()


# ---------------------------------------------------------------- keys as text
# A key here: [sc, mods]: sc a PC scancode (E0xx: the grey block's), or MID / M4 / M5, 0: none; mods 1 Shift, 2 Ctrl, 4 Alt.
static func parse(spec: String) -> Array:
	var s := spec.strip_edges().to_upper()
	if s == "" or s == "-":
		return [0, 0]
	if s == "MID":
		return [MID, 0]
	if s == "M4" or s == "M5":
		return [M4 if s == "M4" else M5, 0]
	var parts := s.split("+", false)
	var mods := 0
	for i in parts.size() - 1:
		mods |= int({"SHIFT": 1, "CTRL": 2, "ALT": 4}.get(parts[i].strip_edges(), 0))
	return [parts[parts.size() - 1].strip_edges().hex_to_int(), mods]


static func spec(k: Array) -> String:
	if int(k[0]) == 0:
		return ""
	if int(k[0]) < 0:
		return ["", "MID", "M4", "M5"][-int(k[0])]
	var s := ""
	for m in [[1, "SHIFT+"], [2, "CTRL+"], [4, "ALT+"]]:
		if int(k[1]) & int(m[0]):
			s += m[1]
	return s + ("%04X" % int(k[0]) if int(k[0]) > 0xFF else "%02X" % int(k[0]))


# TN+'s way: one modifier (1 Shift, 2 Ctrl, 3 Alt), the grey block's keys as 0x80 + code
static func _from_tnp(sc: int, mod: int) -> Array:
	return [0xE000 | (sc & 0x7F) if sc >= 0x80 else sc, [0, 1, 2, 4][clampi(mod, 0, 3)]]


static func _to_tnp(k: Array) -> String:
	var sc := int(k[0])
	var code := (0x80 | (sc & 0x7F)) if sc >= 0xE000 else sc
	var m := int(k[1])
	return ("ALT+" if m & 4 else "CTRL+" if m & 2 else "SHIFT+" if m & 1 else "") + "%02X" % code


func physical(sc: int) -> Key:
	for k in scancodes:
		if int(scancodes[k]) == sc:
			return k
	return KEY_NONE


# the key as this keyboard prints it: "Shift+F12", "A", "Middle mouse"
func name_of(k: Array) -> String:
	var sc := int(k[0])
	if sc == 0:
		return "-"
	if sc < 0:
		return ["", "Middle mouse", "Mouse 4", "Mouse 5"][-sc]
	var s := ""
	for m in [[1, "Shift+"], [2, "Ctrl+"], [4, "Alt+"]]:
		if int(k[1]) & int(m[0]):
			s += m[1]
	var own: String = {0x2A: "Shift", 0x36: "Right Shift", 0x1D: "Ctrl", 0xE01D: "Right Ctrl", 0x38: "Alt", 0xE038: "Alt Gr"}.get(sc, "")
	if own != "":
		return s + own
	var pk := physical(sc)
	if pk == KEY_NONE:
		return s + "key %02X" % sc
	var lab := pk
	if DisplayServer.get_name() != "headless":
		lab = DisplayServer.keyboard_get_label_from_physical(pk)
	var t := OS.get_keycode_string(lab if lab != KEY_NONE else pk)
	return s + (t if t != "" else OS.get_keycode_string(pk))


# ---------------------------------------------------------------- reading
func reload() -> void:
	cmds = []
	var f := FileAccess.open("res://data/controls.txt", FileAccess.READ)
	if f == null:
		return
	while not f.eof_reached():
		var l := f.get_line().strip_edges()
		if l == "" or l.begins_with("#"):
			continue
		var p := l.split("|")
		if p.size() < 5:
			continue
		var d := parse(p[3])
		if p[4] != "uplink" and int(d[0]) >= 0x80 and int(d[0]) < 0x100:
			d[0] = 0xE000 | (int(d[0]) & 0x7F)            # (TN+ writes the grey block's keys as 0x80 + code)
		cmds.append({"group": p[0], "id": p[1], "name": p[2], "kind": p[4], "def": d, "key": d.duplicate(), "mouse": 0})
	_read_tnplus()
	_read_uplink()


func find(id: String) -> Dictionary:
	for c in cmds:
		if c["id"] == id:
			return c
	return {}


func _tnplus_ini() -> String:
	if OS.get_environment("TN_TNPLUS_INI") != "":                 # (checks: another file)
		return OS.get_environment("TN_TNPLUS_INI")
	var comp := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
	for d in ["tnplus", "tnplus_coop"]:
		var p := comp.path_join(d).path_join("TNPlus.ini")
		if FileAccess.file_exists(p):
			return p
	return ""


func _read_tnplus() -> void:
	ini_path = _tnplus_ini()
	var lines := PackedStringArray()
	if ini_path != "":
		lines = FileAccess.get_file_as_string(ini_path).split("\n")
	var kv := 0
	var saw_keys := false
	var saw := {}
	var vals := {}
	for raw in lines:
		var l := raw.strip_edges()
		if l.begins_with(";") or not "=" in l:
			continue
		var k := l.substr(0, l.find("=")).strip_edges().to_lower()
		var v := l.substr(l.find("=") + 1).strip_edges()
		if k.begins_with("key_") or k.begins_with("keys_"):
			saw_keys = true
		if k == "keys_version":
			kv = v.to_int()
		saw[k] = true
		vals[k] = v
	# as it comes (version 4): Centre view without a key, freelook on F; before it: on F and on Y
	var old := saw_keys and kv < 4
	for c in cmds:
		if c["kind"] == "game" or c["kind"] == "fixed":
			if c["id"] == "centre" and not old:
				c["def"] = [0, 0]
			c["key"] = c["def"].duplicate()
			var gk := "key_game_" + str(c["id"])
			if c["kind"] == "game" and vals.has(gk):
				var p := parse(str(vals[gk]))
				var code := int(p[0])
				var tnp_mod := 3 if int(p[1]) & 4 else 2 if int(p[1]) & 2 else 1 if int(p[1]) & 1 else 0
				if code > 0 and code < 0x100 and not (c["id"] == "bound" and tnp_mod != 0):
					c["key"] = _from_tnp(code, tnp_mod)
			var mk := "mouse_" + str(c["id"])
			c["mouse"] = maxi(0, MOUSE_INI.find(str(vals.get(mk, "")).to_upper()))
		elif c["kind"] == "tnplus":
			var tk := "key_" + str(c["id"])
			if c["id"] == "freelook" and old:
				c["def"] = [0x15, 0]
			c["key"] = [str(vals[tk]).hex_to_int(), 0] if vals.has(tk) else c["def"].duplicate()
			if c["id"] == "distance" and kv < 3 and int(c["key"][0]) == 0x17:
				c["key"] = [0x24, 0]
			c["mouse"] = maxi(0, MOUSE_INI.find(str(vals.get("mouse_" + str(c["id"]), "")).to_upper()))
	_tool_clashes()


# TN+'s ResolveToolClashes: a plain game key on one of its own keys goes to the first spare key free
func _tool_clashes() -> void:
	var tools := {}
	for c in cmds:
		if c["kind"] == "tnplus":
			tools[int(c["key"][0])] = true
	for c in cmds:
		if c["kind"] == "game" and int(c["key"][1]) == 0 and int(c["key"][0]) > 0 and int(c["key"][0]) < 0x80 and tools.has(int(c["key"][0])):
			for f in SPARE:
				if not tools.has(f) and _game_owner([f, 0]).is_empty():
					c["key"] = [f, 0]
					break


func _game_owner(k: Array) -> Dictionary:
	for c in cmds:
		if (c["kind"] == "game" or c["kind"] == "fixed") and int(c["key"][0]) == int(k[0]) and int(c["key"][1]) == int(k[1]):
			return c
	return {}


func _read_uplink() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	for c in cmds:
		if c["kind"] != "uplink":
			continue
		var e := OS.get_environment(UPLINK_ENV.get(c["id"], ""))
		var s := str(cfg.get_value("launcher", "key_" + str(c["id"]), e if e != "" else "__default__"))
		c["key"] = c["def"].duplicate() if s == "__default__" or s == "" else parse(s)
	# the old school look's three companions follow its key unless set (as the launcher's SharpKey, ShotKey, FpsKey)
	var old := find("oldschool")
	var olds := str(cfg.get_value("launcher", "key_oldschool", OS.get_environment("TN_KEY_OLDSCHOOL")))
	var plain := int(old["key"][1]) == 0
	for p in [["sharp", 1, "TN_KEY_SHARP"], ["shot", 2, "TN_KEY_SHOT"], ["fps", 3, "TN_KEY_FPS"]]:
		var c := find(p[0])
		var set_ := str(cfg.get_value("launcher", "key_" + str(p[0]), OS.get_environment(p[2])))
		var d := [old["key"][0], int(old["key"][1]) | int(p[1])] if (plain or p[0] == "sharp") and not (p[0] == "sharp" and int(old["key"][1]) & 1) else [0, 0]
		c["def"] = d
		if set_ == "" or olds != "" and set_ == "":
			c["key"] = d.duplicate()


# ---------------------------------------------------------------- what is wrong
# commands that share a key with another (not counting the game's fixed keys, nor two keys both as they come: Uplink's
# F12 is the game's Mission info by design)
func conflicts() -> Dictionary:
	var out := {}
	for i in cmds.size():
		var a: Dictionary = cmds[i]
		if a["kind"] == "fixed" or int(a["key"][0]) == 0:
			continue
		for j in cmds.size():
			var b: Dictionary = cmds[j]
			if i == j or b["kind"] == "fixed" or int(b["key"][0]) != int(a["key"][0]) or int(b["key"][1]) != int(a["key"][1]):
				continue
			if a["key"] == a["def"] and b["key"] == b["def"]:
				continue
			out[a["id"]] = b["name"]
	return out


# ---------------------------------------------------------------- writing
func set_key(id: String, k: Array) -> void:
	var c := find(id)
	if c.is_empty() or c["kind"] == "fixed":
		return
	c["key"] = k


func set_mouse(id: String, m: int) -> void:
	var c := find(id)
	if c.is_empty() or c["kind"] == "fixed" or c["kind"] == "uplink":
		return
	for o in cmds:                                    # a second bind is on one command at most
		if m != 0 and int(o["mouse"]) == m:
			o["mouse"] = 0
	c["mouse"] = m


func reset() -> void:
	for c in cmds:
		c["key"] = c["def"].duplicate() if c["kind"] != "game" or c["id"] != "centre" else [0, 0]
		if c["id"] == "freelook":
			c["key"] = [0x21, 0]
		c["mouse"] = 0


# TN+'s settings: the game's keys that are not as they come, its own keys, its keys' version 4; the rest kept
func save_tnplus() -> bool:
	if ini_path == "":
		return false
	var keep := PackedStringArray()
	for raw in FileAccess.get_file_as_string(ini_path).split("\n"):
		var l := raw.strip_edges(false, true)
		var k := l.strip_edges().to_lower()
		if k.begins_with("key_game_") or k.begins_with("mouse_") or k.begins_with("keys_version") or k.begins_with("key_freelook") \
				or k.begins_with("key_noclip") or k.begins_with("key_distance") or k.begins_with("key_stereo"):
			continue
		keep.append(l)
	while keep.size() > 0 and keep[keep.size() - 1] == "":
		keep.remove_at(keep.size() - 1)
	for c in cmds:
		if c["kind"] == "tnplus":
			keep.append("key_%s = %02X" % [c["id"], int(c["key"][0])])
	keep.append("keys_version = 4")
	for c in cmds:
		if c["kind"] != "game":
			continue
		var v4_def: Array = [0, 0] if c["id"] == "centre" else c["def"]
		if c["id"] == "centre":
			v4_def = [0, 0]
		if c["key"] != v4_def and int(c["key"][0]) > 0:
			keep.append("key_game_%s = %s" % [c["id"], _to_tnp(c["key"])])
		elif c["key"] != v4_def:
			keep.append("key_game_%s = 00" % c["id"])
	for c in cmds:
		if int(c["mouse"]) > 0:
			keep.append("mouse_%s = %s" % [c["id"], MOUSE_INI[int(c["mouse"])]])
	var f := FileAccess.open(ini_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string("\r\n".join(keep) + "\r\n")
	return true


# Uplink's own keys: in viewer.cfg for the launcher to take over (with the time: newer than its own)
func save_uplink() -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	for c in cmds:
		if c["kind"] == "uplink":
			cfg.set_value("launcher", "key_" + str(c["id"]), spec(c["key"]) if c["key"] != c["def"] else "")
	cfg.set_value("launcher", "stamp", int(Time.get_unix_time_from_system()))
	cfg.save(CFG)


# The guest's key turning (as the launcher's KeyMap): a game command he moved to another plain key -> its own key;
# the own key of a moved command, now no command's, gives nothing (Shift, the bound's, stays Shift)
func key_map() -> Dictionary:
	var m := {}
	var moved := {}
	for c in cmds:
		if c["kind"] != "game" or int(c["def"][1]) != 0 and c["id"] != "centre":
			continue
		var own: Array = parse(_own_default(c["id"]))
		if int(own[1]) != 0:
			continue
		var k: Array = c["key"]
		if int(k[1]) == 0 and int(k[0]) > 0 and int(k[0]) < 0x80 and int(k[0]) != int(own[0]):
			moved[int(k[0])] = int(own[0])
		elif int(k[0]) == 0:
			moved[-int(own[0])] = int(own[0])     # (no key: its own key is nobody's)
	for nk in moved:
		if nk > 0:
			m[nk] = moved[nk]
	for nk in moved:
		var own_sc: int = moved[nk]
		if not m.has(own_sc) and own_sc != 0x2A:
			m[own_sc] = 0
	return m


# the game's own key for a command (data/controls.txt's, before Centre view lost its key)
func _own_default(id: String) -> String:
	var f := FileAccess.open("res://data/controls.txt", FileAccess.READ)
	while f and not f.eof_reached():
		var p := f.get_line().split("|")
		if p.size() >= 5 and p[1] == id:
			return p[3]
	return ""
