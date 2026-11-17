# A brand new mission in one of the game's two empty slots: missions 18 and 28 have their script modules (miss18,
# miss28), their names and objective lines, and their cases in do3d's switches, but no MISS18.RES / MISS28.RES.
# This writes that file, and the mission's name and objective lines where the game reads them.
#
# The "new" part of a creation (no game data in it):
#   {"slot": 18,
#    "like": "MISS37.RES",              the game's mission whose map (resource 170) and sky / light / weather
#                                       parameters (178) the new one takes: the map is chosen by choosing it
#    "zones": [[index, x, y], ...],     16.16; zone 0 = where the squad is dropped, zone 31 = the pickup point;
#                                       or [index, x, y, shape, w, h]: shape 0 a circle of diameter w, 1 a rectangle
#                                       w by h (16.16). Without a shape a zone is the game's usual point (a circle
#                                       0.5 wide): fine as a place to go to, but a group only "enters" a zone or
#                                       holds it when it stands INSIDE its shape (0x2C9D50)
#    "sides": {"3": 1},                 groups on the player's side (1); every other group is an enemy (2)
#    "add": [{"from": "MISS37.RES", "rec": 0, "sum": "<8 hex>", "l": 2, "g": 1, "x": .., "y": .., "z": .., "h": .., "o": [off, value...]}],
#                                       units, each a copy of a unit record of one of the game's missions with
#                                       what differs: the same entries as mission_mod.gd's "add" (l = label, record
#                                       byte +26; "sum", the record's checksum, is checked when given)
#    "name": "OPERATION ...",           the mission's name (RESMISS.RES 0x6AA, string slot - 1)
#    "objectives": ["", "", ""],        the three objective lines (RESGAME.RES 0x175, strings slot * 3 + k)
#    "briefing": "...",                 the text briefing (RESPTERM.RES 0x5AF, string slot)
#    "note": "..."}                     the commander's line on the outfitting screen (same table, string slot + 48)
# The mission's script (objectives, orders, debriefing) is a "build" spec of mission_build.gd for the same slot.
#
# The file: 170 map name (80 bytes), 171 / 172 / 177 names of sets, groups and zones (the game does not read
# them), 173 units (compound, 50-byte records), 174 side of each of the 32 groups, 175 map annotations (none),
# 176 the 128 zones (x, y; 0, 0 = free), 178 parameters, 180 version = 4 (the game refuses another), 181
# reinforcements (none), 182 the zones' shapes (circles).
extends RefCounted

const ResFile := preload("res://scripts/res_file.gd")

const SLOTS := [18, 28]
const MARK := ".uplink-new"        # beside a mission file this module wrote: remove() deletes no other
const REC := 50
const ZONES := 128
const RES_OBJ_TEXT := 0x175
const RES_NAMES := 0x6AA
const RES_BRIEFING := 0x5AF        # RESPTERM.RES: string mission = the text briefing, mission + 48 = the outfitting note
const FIELDS := [["g", 7, 1], ["x", 8, 4], ["y", 12, 4], ["z", 16, 4], ["h", 20, 2], ["p", 22, 2], ["l", 26, 1], ["label", 26, 1]]
const MAX_UNITS := 300              # the game's entity table


static func _is_int(v) -> bool:
	return (v is int or v is float) and float(v) == floorf(float(v)) and absf(float(v)) < 4294967296.0


static func file_name(slot: int) -> String:
	return "MISS%d.RES" % slot


static func _names16(list: Array, count: int) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(16 * count)
	for i in mini(count, list.size()):
		var b: PackedByteArray = str(list[i]).to_ascii_buffer().slice(0, 15)
		for k in b.size():
			out[16 * i + k] = b[k]
	return out


# a mission file name as the game's own: MISS<digits or letters>.RES, nothing else (no path)
static func _plain_mission_name(s) -> bool:
	if not (s is String) or s.length() < 9 or s.length() > 12:
		return false
	var u: String = s.to_upper()
	if not u.begins_with("MISS") or not u.ends_with(".RES"):
		return false
	var mid := u.substr(4, u.length() - 8)
	for i in mid.length():
		var c := mid.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90)):
			return false
	return true


# the game's own version of one of its missions (its kept original when the editor changed it)
static func _game_mission(data_dir: String, name: String) -> Dictionary:
	return ResFile.read(ResFile.original_path(data_dir.path_join(name.to_upper())))


# {"error": "", "bytes": the mission file}
static func mission_file(data_dir: String, new) -> Dictionary:
	var bad := {"error": "", "bytes": PackedByteArray()}
	if not (new is Dictionary) or not _is_int(new.get("slot", null)) or not SLOTS.has(int(new["slot"])):
		bad["error"] = "a new mission takes slot 18 or 28"
		return bad
	if not _plain_mission_name(new.get("like", null)):
		bad["error"] = "a new mission names the game's mission whose map it takes"
		return bad
	var like := _game_mission(data_dir, new["like"])
	if like.is_empty() or ResFile.data(like, 170).is_empty() or ResFile.data(like, 178).is_empty():
		bad["error"] = "%s was not found in the game (its map and parameters are needed)" % new["like"]
		return bad
	var zones := PackedByteArray()
	zones.resize(8 * ZONES)
	var seen := {}
	var zl = new.get("zones", [])
	if not (zl is Array):
		bad["error"] = "the zones are not well formed"
		return bad
	var shapes := PackedByteArray()
	shapes.resize(10 * ZONES)
	for z in ZONES:
		shapes.encode_s32(10 * z + 2, 0x8000)
		shapes.encode_s32(10 * z + 6, 0x8000)
	for z in zl:
		var ok: bool = z is Array and (z.size() == 3 or z.size() == 6)
		if ok:
			for v in z:
				ok = ok and _is_int(v)
		if not ok or int(z[0]) < 0 or int(z[0]) >= ZONES or int(z[1]) <= 0 or int(z[2]) <= 0:
			bad["error"] = "a zone is [index 0..127, x, y] or [index, x, y, shape, width, height]"
			return bad
		zones.encode_s32(8 * int(z[0]), int(z[1]))
		zones.encode_s32(8 * int(z[0]) + 4, int(z[2]))
		if z.size() == 6:
			if (int(z[3]) != 0 and int(z[3]) != 1) or int(z[4]) <= 0 or int(z[5]) <= 0:
				bad["error"] = "a zone's shape is 0 (circle) or 1 (rectangle), with a width and a height"
				return bad
			shapes.encode_u16(10 * int(z[0]), int(z[3]))
			shapes.encode_s32(10 * int(z[0]) + 2, int(z[4]))
			shapes.encode_s32(10 * int(z[0]) + 6, int(z[5]))
		seen[int(z[0])] = true
	if not seen.has(0) or not seen.has(31):
		bad["error"] = "a mission needs zone 0 (where the squad is dropped) and zone 31 (the pickup point)"
		return bad
	var sides := PackedByteArray()
	sides.resize(32)
	sides.fill(2)
	var sd = new.get("sides", {})
	if not (sd is Dictionary):
		bad["error"] = "the sides are not well formed"
		return bad
	for k in sd:
		if not str(k).is_valid_int() or int(str(k)) < 1 or int(str(k)) > 31 or not _is_int(sd[k]) \
				or (int(sd[k]) != 1 and int(sd[k]) != 2):
			bad["error"] = "a side is 1 or 2, for a group from 1 to 31"
			return bad
		sides[int(str(k))] = int(sd[k])
	var units := []
	var al = new.get("add", [])
	if not (al is Array) or al.size() > MAX_UNITS:
		bad["error"] = "the units are not well formed"
		return bad
	var sources := {}
	var per_class := {}
	for a in al:
		if not (a is Dictionary) or not _plain_mission_name(a.get("from", null)) or not _is_int(a.get("rec", null)):
			bad["error"] = "a unit names the game's mission and record it is a copy of"
			return bad
		var src: String = a["from"].to_upper()
		if not sources.has(src):
			var f := _game_mission(data_dir, src)
			sources[src] = ResFile.items(ResFile.data(f, 173)) if not f.is_empty() else []
		var recs: Array = sources[src]
		var ri := int(a["rec"])
		if ri < 0 or ri >= recs.size() or recs[ri].size() != REC:
			bad["error"] = "%s has no unit %d" % [src, ri]
			return bad
		var r: PackedByteArray = recs[ri].duplicate()
		if a.has("sum"):
			var hc := HashingContext.new()
			hc.start(HashingContext.HASH_SHA256)
			hc.update(r)
			if hc.finish().hex_encode().substr(0, 8) != str(a["sum"]):
				bad["error"] = "unit %d of %s is not the same in this game (another version, or a changed file)" % [ri, src]
				return bad
		for fd in FIELDS:
			if a.has(fd[0]):
				if not _is_int(a[fd[0]]):
					bad["error"] = "a unit's %s is not a number" % fd[0]
					return bad
				var v := int(a[fd[0]])
				if fd[2] == 1:
					r[fd[1]] = v & 0xFF
				elif fd[2] == 2:
					r.encode_u16(fd[1], v & 0xFFFF)
				else:
					r.encode_s32(fd[1], v)
		if a.has("o"):
			var o = a["o"]
			if not (o is Array) or o.size() % 2 != 0:
				bad["error"] = "a unit's other bytes are not well formed"
				return bad
			for k in range(0, o.size(), 2):
				if not _is_int(o[k]) or not _is_int(o[k + 1]) or int(o[k]) < 6 or int(o[k]) >= REC:
					bad["error"] = "a unit's other bytes are not well formed"
					return bad
				r[int(o[k])] = int(o[k + 1]) & 0xFF
		if r[7] < 1 or r[7] > 31:
			bad["error"] = "a unit's group must be from 1 to 31 (the game's own table ends there)"
			return bad
		per_class[r[0]] = per_class.get(r[0], 0) + 1
		r.encode_u16(2, units.size() + 1)           # (numbers the game never reads: in order, as its own files)
		r.encode_u16(4, per_class[r[0]])
		units.append(r)
	var map := PackedByteArray()
	map.resize(80)
	var mn := ResFile.data(like, 170)
	for i in mini(79, mn.size()):
		if mn[i] == 0:
			break
		map[i] = mn[i]
	var group_names := ["(NULL GRP)"]
	for g in range(1, 32):
		group_names.append("group %d" % g)
	var zone_names := []
	for z in ZONES:
		zone_names.append("0: Drop point" if z == 0 else "31: pickup" if z == 31 else "%d: " % z)
	var reinf := PackedByteArray()
	reinf.resize(4 + 32 * REC)
	var f := ResFile.empty()
	ResFile.add(f, 170, 0, 0, map)
	ResFile.add(f, 171, 0, 0, _names16(["Default"], 32))
	ResFile.add(f, 172, 0, 0, _names16(group_names, 32))
	ResFile.add(f, 173, 0, 2, ResFile.compound(units))
	ResFile.add(f, 174, 0, 0, sides)
	ResFile.add(f, 175, 0, 2, ResFile.compound([]))
	ResFile.add(f, 176, 0, 0, zones)
	ResFile.add(f, 177, 0, 0, _names16(zone_names, ZONES))
	ResFile.add(f, 178, 0, 0, ResFile.data(like, 178))
	ResFile.add(f, 180, 0, 0, PackedByteArray([4, 0]))
	ResFile.add(f, 181, 0, 0, reinf)
	ResFile.add(f, 182, 0, 0, shapes)
	return {"error": "", "bytes": ResFile.build(f)}


# one string table of a file with some strings replaced: "" or what went wrong
static func _set_strings(path: String, rid: int, changes: Dictionary) -> String:
	var f := ResFile.read(path)                     # (the file as it is now: the other slot's texts stay)
	if f.is_empty():
		return "%s was not found" % path.get_file()
	var its := ResFile.items(ResFile.data(f, rid))
	for i in changes:
		if int(i) < 0 or int(i) >= its.size():
			return "%s has no string %d in its table %d" % [path.get_file(), i, rid]
		its[int(i)] = ResFile.cp850(str(changes[i]))
	if not ResFile.put(f, rid, ResFile.compound(its)):
		return "%s: table %d could not be replaced" % [path.get_file(), rid]
	var err := ResFile.keep_original(path)
	if err != "":
		return err
	return ResFile.write(path, ResFile.build(f))


# the new mission written into data_dir (the game's TNOVA\DATA or a copy): its file, its name and its objective
# lines (the game's RESMISS.RES and RESGAME.RES kept beside as .uplink-original). "" or what went wrong.
static func install(data_dir: String, new) -> String:
	var made := mission_file(data_dir, new)
	if made["error"] != "":
		return made["error"]
	var slot := int(new["slot"])
	var path := data_dir.path_join(file_name(slot))
	if FileAccess.file_exists(path) and not FileAccess.file_exists(path + MARK):
		return "%s is already there and is not one of Uplink's: left as it is" % file_name(slot)
	var texts := {}
	var objs = new.get("objectives", ["", "", ""])
	if not (objs is Array) or objs.size() != 3:
		return "a new mission has three objective lines (empty for the unused ones)"
	for k in 3:
		if not (objs[k] is String) or objs[k].length() > 120:
			return "an objective line is too long (120 characters at most)"
		texts[slot * 3 + k] = objs[k] if objs[k] != "" else " "
	var name = new.get("name", "")
	if not (name is String) or name.length() > 40:
		return "the mission's name is too long (40 characters at most)"
	var err := _set_strings(data_dir.path_join("RESGAME.RES"), RES_OBJ_TEXT, texts)
	if err != "":
		return err
	err = _set_strings(data_dir.path_join("RESMISS.RES"), RES_NAMES, {slot - 1: name if name != "" else "MISSION %d" % slot})
	if err != "":
		return err
	var brief = new.get("briefing", "")
	var note = new.get("note", "")
	if not (brief is String) or brief.length() > 1500 or not (note is String) or note.length() > 300:
		return "the briefing (1500 characters at most) or the outfitting note (300) is too long"
	if FileAccess.file_exists(data_dir.path_join("RESPTERM.RES")):
		err = _set_strings(data_dir.path_join("RESPTERM.RES"), RES_BRIEFING,
			{slot: brief if brief != "" else " ", slot + 48: note if note != "" else " "})
		if err != "":
			return err
	var mk := FileAccess.open(path + MARK, FileAccess.WRITE)
	if mk == null:
		return "%s could not be written (is the folder write-protected?)" % (file_name(slot) + MARK)
	mk.store_string("written by Terra Nova Uplink's mission editor\n")
	mk.close()
	return ResFile.write(path, made["bytes"])


# the new mission taken out again (only a file this module wrote), the game's texts put back
static func remove(data_dir: String, slot: int) -> String:
	if not SLOTS.has(slot):
		return "a new mission is in slot 18 or 28"
	var path := data_dir.path_join(file_name(slot))
	if FileAccess.file_exists(path):
		if not FileAccess.file_exists(path + MARK):
			return "%s is not one of Uplink's: left as it is" % file_name(slot)
		if DirAccess.remove_absolute(path) != OK:
			return "%s could not be removed" % file_name(slot)
	if FileAccess.file_exists(path + MARK):
		DirAccess.remove_absolute(path + MARK)
	for other in SLOTS:                              # the texts stay while the other slot is in use
		if other != slot and FileAccess.file_exists(data_dir.path_join(file_name(other)) + MARK):
			return ""
	for f in ["RESGAME.RES", "RESPTERM.RES"]:
		var err := ResFile.restore(data_dir.path_join(f))
		if err != "":
			return err
	return ResFile.restore(data_dir.path_join("RESMISS.RES"))
