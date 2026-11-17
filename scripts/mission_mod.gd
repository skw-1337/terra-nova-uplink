# A creation of the mission editor, to share: only the CHANGES against one of the game's missions, with none of
# the game's data in it. Two forms of the same thing: a small file (.tnmod, the JSON below) and a code to copy
# and paste (the same JSON, gzip, base64, "TNMOD1:" before and a checksum after).
#   {"tnmod": 1,
#    "base":   {"file": "MISS5.RES", "units": 29, "sum": "<16 hex>"}    the mission it changes; sum = SHA-256 (its
#                                                                       first 8 bytes) of the ORIGINAL file's unit
#                                                                       and zone resources (173, 176)
#    "remove": [3, 7],                                                  original units taken out (record index)
#    "edit":   [{"i": 12, <fields>}],                                   original units changed
#    "add":    [{"from": "MISS17.RES", "rec": 22, "sum": "<8 hex>", <fields>}],   new units: each a copy of a unit
#                                                                       record of one of the game's missions (file,
#                                                                       record index, checksum of that record)
#    "zones":  [[3, x, y]],                                             zones moved (number, x, y in 16.16)
#    "script": {"patch": [...], "build": [...]},                        (optional) the mission's script changed: numbers
#                                                                       replaced in place, or the script rebuilt from
#                                                                       blocks (scripts/mission_build.gd, which checks
#                                                                       and installs it: set_mission_script())
#    "new":    {"slot": 18, "like": "MISS37.RES", ...}}                 (optional) a brand new mission in one of the
#                                                                       game's two empty slots (scripts/mission_new.gd):
#                                                                       base.file is then MISS18.RES or MISS28.RES
# <fields>: only what differs from the record it starts from: "g" group, "l" label (what the mission's scripts know
# the unit by), "x" "y" "z" position and height above the ground (16.16), "h" heading (1/65536 turn), "p" pitch,
# and "o": [offset, value, offset, value...] for any other byte of the 50-byte record from +6 on (the state
# percentages, the weapons...). The numbers at +2 / +4 are not in it: the game never reads them (its loader,
# 0x2C9898), the editor gives the added units the next ones.
# The mission's own units stay first, in their order, the added ones follow in theirs.
extends RefCounted

const REC := 50
const EXT := "tnmod"
const PREFIX := "TNMOD1:"
const MAX_TEXT := 2 << 20                        # nothing bigger is read (a creation is a few kilobytes)
const MAX_ADD := 4000
const FIELDS := [["g", 7, 1], ["x", 8, 4], ["y", 12, 4], ["z", 16, 4], ["h", 20, 2], ["p", 22, 2], ["l", 26, 1]]   # name, offset, bytes


static func digest(parts: Array, hex_chars: int = 16) -> String:
	var h := HashingContext.new()
	h.start(HashingContext.HASH_SHA256)
	for p in parts:
		var b: PackedByteArray = p
		if not b.is_empty():
			h.update(b)
	return h.finish().hex_encode().substr(0, hex_chars)


static func compose(recs: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for r in recs:
		out.append_array(r)
	return out


# the checksum of a mission's units and zones (the same in every language of the game: only the texts differ)
static func base_sum(recs: Array, zones: PackedByteArray) -> String:
	return digest([compose(recs), zones])


# ---- one record against the one it starts from
static func _rd(r: PackedByteArray, off: int, size: int) -> int:
	return r[off] if size == 1 else r.decode_u16(off) if size == 2 else r.decode_s32(off)


static func _wr(r: PackedByteArray, off: int, size: int, v: int) -> void:
	if size == 1:
		r[off] = v & 0xFF
	elif size == 2:
		r.encode_u16(off, v & 0xFFFF)
	else:
		r.encode_s32(off, v)


# what differs in r from base (both REC bytes), as <fields>
static func patch(base: PackedByteArray, r: PackedByteArray) -> Dictionary:
	var d := {}
	var named := {}
	for f in FIELDS:
		for k in f[2]:
			named[int(f[1]) + k] = true
		if _rd(base, f[1], f[2]) != _rd(r, f[1], f[2]):
			d[f[0]] = _rd(r, f[1], f[2])
	var other := []
	for o in range(6, REC):
		if not named.has(o) and base[o] != r[o]:
			other.append(o)
			other.append(r[o])
	if not other.is_empty():
		d["o"] = other
	return d


# base with <fields> applied; empty when d is not well formed
static func patched(base: PackedByteArray, d: Dictionary) -> PackedByteArray:
	var r := PackedByteArray(base).duplicate()
	for f in FIELDS:
		if d.has(f[0]):
			if not _is_int(d[f[0]]):
				return PackedByteArray()
			_wr(r, f[1], f[2], int(d[f[0]]))
	if d.has("o"):
		var o = d["o"]
		if not (o is Array) or o.size() % 2 != 0:
			return PackedByteArray()
		for k in range(0, o.size(), 2):
			if not _is_int(o[k]) or not _is_int(o[k + 1]) or int(o[k]) < 6 or int(o[k]) >= REC:
				return PackedByteArray()
			r[int(o[k])] = int(o[k + 1]) & 0xFF
	return r


static func _is_int(v) -> bool:
	return (v is int or v is float) and float(v) == floorf(float(v)) and absf(float(v)) < 4294967296.0


# ---- the added units' numbers: after the mission's own entity numbers, the next ones in their class
static func renumber(orig: Array, recs: Array, origin: Array) -> void:
	var top := 0
	var per := {}
	for o in orig:
		var r: PackedByteArray = o
		top = maxi(top, r.decode_u16(2))
		per[r[0]] = maxi(per.get(r[0], 0), r.decode_u16(4))
	for i in recs.size():
		if int(origin[i]) >= 0:
			continue
		var r: PackedByteArray = recs[i]
		top += 1
		per[r[0]] = per.get(r[0], 0) + 1
		r.encode_u16(2, top & 0xFFFF)
		r.encode_u16(4, per[r[0]] & 0xFFFF)
		recs[i] = r


# ---- a state of the editor <-> a creation
# st: {"recs": [PackedByteArray], "origin": [index in orig, -1 = added], "src": [{"f": file, "i": record} for the
# added ones], "zones": PackedByteArray}; source(file, record) gives that record of the game's mission (empty: none)
static func make(file: String, orig: Array, orig_zones: PackedByteArray, st: Dictionary, source: Callable) -> Dictionary:
	var recs: Array = st["recs"]
	var origin: Array = st["origin"]
	var src: Array = st["src"]
	var seen := {}
	var edit := []
	var add := []
	for i in recs.size():
		var o := int(origin[i])
		if o >= 0:
			seen[o] = true
			var d := patch(orig[o], recs[i])
			if not d.is_empty():
				d["i"] = o
				edit.append(d)
		else:
			var s: Dictionary = src[i] if src[i] is Dictionary else {}
			var base: PackedByteArray = source.call(str(s.get("f", "")), int(s.get("i", -1))) if not s.is_empty() else PackedByteArray()
			if base.size() != REC or base[0] != recs[i][0] or base[1] != recs[i][1]:
				return {"error": "unit %d has no record of the game to start from" % i}
			var d := patch(base, recs[i])
			d["from"] = str(s["f"]).to_upper()
			d["rec"] = int(s["i"])
			d["sum"] = digest([base], 8)
			add.append(d)
	var remove := []
	for o in orig.size():
		if not seen.has(o):
			remove.append(o)
	var zones := []
	var zcur: PackedByteArray = st["zones"]
	for z in mini(zcur.size(), orig_zones.size()) / 8:
		if zcur.decode_s32(8 * z) != orig_zones.decode_s32(8 * z) or zcur.decode_s32(8 * z + 4) != orig_zones.decode_s32(8 * z + 4):
			zones.append([z, zcur.decode_s32(8 * z), zcur.decode_s32(8 * z + 4)])
	return {"tnmod": 1, "base": {"file": file.get_file().to_upper(), "units": orig.size(), "sum": base_sum(orig, orig_zones)},
		"remove": remove, "edit": edit, "add": add, "zones": zones}


static func is_empty(mod: Dictionary) -> bool:
	return mod.get("remove", []).is_empty() and mod.get("edit", []).is_empty() and mod.get("add", []).is_empty() \
		and mod.get("zones", []).is_empty() and script_of(mod).is_empty() and not (mod.get("new") is Dictionary)


# (hook: mission scripts) the script part of a creation, {} when it has none: what mission_build.gd's
# check_for() and set_mission_script() take
static func script_of(mod: Dictionary) -> Dictionary:
	var s = mod.get("script")
	if not (s is Dictionary):
		return {}
	var patch = s.get("patch", [])
	var build = s.get("build", [])
	if not (patch is Array) or not (build is Array) or (patch.is_empty() and build.is_empty()):
		return {}
	return {"patch": patch, "build": build}


# what a creation holds, in a few words
static func summary(mod: Dictionary) -> String:
	var parts := []
	for k in [["add", "added"], ["edit", "changed"], ["remove", "removed"]]:
		var n: int = mod.get(k[0], []).size()
		if n > 0:
			parts.append("%d unit%s %s" % [n, "" if n == 1 else "s", k[1]])
	var z: int = mod.get("zones", []).size()
	if z > 0:
		parts.append("%d zone%s moved" % [z, "" if z == 1 else "s"])
	var sc := script_of(mod)                         # (hook: mission scripts)
	if not sc.is_empty():
		var n: int = sc["patch"].size()
		parts.append("script rebuilt" if not sc["build"].is_empty() else "%d script number%s changed" % [n, "" if n == 1 else "s"])
	if mod.get("new") is Dictionary:
		parts.append("a new mission")
	return ", ".join(parts) if not parts.is_empty() else "no change"


# the creation on the ORIGINAL mission (file, its units and zones): {"error": why not} or a state as make() takes
static func apply(mod: Dictionary, file: String, orig: Array, orig_zones: PackedByteArray, source: Callable) -> Dictionary:
	var bad := check(mod)
	if bad != "":
		return {"error": bad}
	var base: Dictionary = mod["base"]
	if str(base["file"]).to_upper() != file.get_file().to_upper():
		return {"error": "this creation is for %s, not for %s: load that mission first" % [str(base["file"]).to_upper(), file.get_file().to_upper()],
			"wrong_mission": str(base["file"]).to_upper()}
	if str(base["sum"]) != base_sum(orig, orig_zones):
		return {"error": "this creation was made on another %s (another version of the game, or a file changed by something else): its units are not this game's" % file.get_file().to_upper()}
	var removed := {}
	for o in mod["remove"]:
		if int(o) < 0 or int(o) >= orig.size():
			return {"error": "it removes unit %d, which %s does not have" % [int(o), file.get_file()]}
		removed[int(o)] = true
	var edits := {}
	for e in mod["edit"]:
		var o := int(e["i"])
		if o < 0 or o >= orig.size() or removed.has(o) or edits.has(o):
			return {"error": "it changes unit %d, which %s does not have (or twice, or removed too)" % [o, file.get_file()]}
		var r := patched(orig[o], e)
		if r.is_empty():
			return {"error": "the changes of unit %d can't be read" % o}
		edits[o] = r
	var recs := []
	var origin := []
	var src := []
	for o in orig.size():
		if removed.has(o):
			continue
		recs.append(edits[o] if edits.has(o) else PackedByteArray(orig[o]).duplicate())
		origin.append(o)
		src.append({})
	for a in mod["add"]:
		var f := str(a["from"]).to_upper()
		var b: PackedByteArray = source.call(f, int(a["rec"]))
		if b.size() != REC:
			return {"error": "it needs unit %d of %s, which this game does not have (a demo, or another version)" % [int(a["rec"]), f]}
		if digest([b], 8) != str(a["sum"]):
			return {"error": "unit %d of %s is not the same in this game (another version, or a changed file)" % [int(a["rec"]), f]}
		var r := patched(b, a)
		if r.is_empty():
			return {"error": "an added unit can't be read"}
		recs.append(r)
		origin.append(-1)
		src.append({"f": f, "i": int(a["rec"])})
	var zones := PackedByteArray(orig_zones).duplicate()
	for z in mod["zones"]:
		if int(z[0]) < 0 or 8 * int(z[0]) + 8 > zones.size():
			return {"error": "it moves zone %d, which %s does not have" % [int(z[0]), file.get_file()]}
		zones.encode_s32(8 * int(z[0]), int(z[1]))
		zones.encode_s32(8 * int(z[0]) + 4, int(z[2]))
	for r in recs:
		if r[7] > 31:
			return {"error": "it puts a unit in group %d: the game has groups 0 to 31" % r[7]}
	renumber(orig, recs, origin)
	return {"recs": recs, "origin": origin, "src": src, "zones": zones}


# "" when the creation is well formed (whatever it came from: a file, a pasted code), else what is wrong
static func check(mod: Dictionary) -> String:
	if not _is_int(mod.get("tnmod")):
		return "not a Terra Nova Uplink creation"
	if int(mod["tnmod"]) != 1:
		return "made by a newer Uplink (format %d): update Uplink to open it" % int(mod["tnmod"])
	var base = mod.get("base")
	if not (base is Dictionary) or not (base.get("file") is String) or not (base.get("sum") is String):
		return "its mission is missing"
	var file: String = base["file"]
	if file != file.get_file() or file.length() > 12 or not file.to_upper().ends_with(".RES") or not file.is_valid_filename():
		return "its mission is not a mission file's name"
	for k in ["remove", "edit", "add", "zones"]:
		if not mod.has(k):
			mod[k] = []
		if not (mod[k] is Array):
			return "its list \"%s\" can't be read" % k
	if mod["add"].size() > MAX_ADD:
		return "too many added units (%d)" % mod["add"].size()
	for o in mod["remove"]:
		if not _is_int(o):
			return "its list \"remove\" can't be read"
	for e in mod["edit"]:
		if not (e is Dictionary) or not _is_int(e.get("i")):
			return "its list \"edit\" can't be read"
	for a in mod["add"]:
		if not (a is Dictionary) or not (a.get("from") is String) or not _is_int(a.get("rec")) or not (a.get("sum") is String):
			return "its list \"add\" can't be read"
		var f: String = a["from"]
		if f != f.get_file() or f.length() > 12 or not f.to_upper().ends_with(".RES") or not f.is_valid_filename():
			return "an added unit names a file that is not a mission"
	for z in mod["zones"]:
		if not (z is Array) or z.size() != 3 or not _is_int(z[0]) or not _is_int(z[1]) or not _is_int(z[2]):
			return "its list \"zones\" can't be read"
	# (hook: mission scripts) only their shape here: mission_build.gd and mission_new.gd check what they hold
	if mod.has("script"):
		var s = mod["script"]
		if not (s is Dictionary) or not (s.get("patch", []) is Array) or not (s.get("build", []) is Array):
			return "its script part can't be read"
	if mod.has("new") and not (mod["new"] is Dictionary):
		return "its new mission can't be read"
	return ""


# ---- text forms
static func to_json(mod: Dictionary) -> String:
	return JSON.stringify(mod, "", false)


static func to_code(mod: Dictionary) -> String:
	var z := to_json(mod).to_utf8_buffer().compress(FileAccess.COMPRESSION_GZIP)
	return PREFIX + Marshalls.raw_to_base64(z) + ":" + digest([z], 8)


# a creation from what a file holds or from a pasted code: the creation, or {"error": why not}
static func from_text(text: String) -> Dictionary:
	if text.length() > MAX_TEXT:
		return {"error": "too long to be a creation"}
	var t := text.strip_edges()
	if t.begins_with("{"):
		return _from_json(t)
	var k := t.find(PREFIX)
	if k < 0:
		if t.to_upper().contains("TNMOD"):
			return {"error": "this code is from another version of Uplink (it does not start with %s)" % PREFIX}
		return {"error": "no creation code here (one starts with %s)" % PREFIX}
	var body := ""
	for c in t.substr(k + PREFIX.length()):      # (pasted through a chat or a mail: spaces and line breaks in it)
		if c != " " and c != "\n" and c != "\r" and c != "\t":
			body += c
	var cut := body.find(":")
	if cut < 0 or body.length() - cut - 1 < 8:
		return {"error": "the code is cut short: copy all of it, to its last character"}
	var b64 := body.substr(0, cut)
	var want := body.substr(cut + 1, 8).to_lower()
	var z := Marshalls.base64_to_raw(b64)
	if z.is_empty() or digest([z], 8) != want:
		return {"error": "the code is damaged (a part is missing or was changed): copy it again, all of it"}
	var raw := z.decompress_dynamic(MAX_TEXT, FileAccess.COMPRESSION_GZIP)
	if raw.is_empty():
		return {"error": "the code can't be unpacked"}
	return _from_json(raw.get_string_from_utf8())


static func _from_json(t: String) -> Dictionary:
	var j := JSON.new()
	if j.parse(t) != OK or not (j.data is Dictionary):
		return {"error": "not a creation (it can't be read)"}
	var mod: Dictionary = j.data
	var bad := check(mod)
	return {"error": bad} if bad != "" else mod
