# An LG Res file taken as it is stored, to write a changed copy of it: every resource keeps its stored bytes
# (an LZW-packed one is never unpacked), its flags, type and place; only the ones given new contents change.
# Used by the mission scripts' and new missions' writers (RESBABL2.RES, RESGAME.RES, RESMISS.RES, MISSnn.RES).
#   var f := ResFile.read(path)            # {} when the file is not a whole LG Res file
#   ResFile.put(f, id, bytes)              # new contents of a resource (false: it is LZW-packed, or not there)
#   ResFile.add(f, id, type, flags, bytes) # a new resource at the end
#   ResFile.write(path, ResFile.build(f))  # "" or what went wrong; the file is written beside, read back, then put in place
#   ResFile.keep_original(path)            # path + ".uplink-original" made once, never overwritten
extends RefCounted

const SIGN := "LG Res File v2"
const ORIGINAL := ".uplink-original"


static func read(path: String) -> Dictionary:
	return parse(FileAccess.get_file_as_bytes(path))


static func parse(d: PackedByteArray) -> Dictionary:
	if d.size() < 0x86 or d.slice(0, 14).get_string_from_ascii() != SIGN:
		return {}
	var diro := d.decode_u32(0x7C)
	if diro + 6 > d.size():
		return {}
	var n := d.decode_u16(diro)
	var off := d.decode_u32(diro + 2)
	if diro + 6 + 10 * n > d.size():
		return {}
	var entries := []
	var p := diro + 6
	for i in n:
		var a := d.decode_u32(p + 2)
		var b := d.decode_u32(p + 6)
		var flags := a >> 24
		var size := a & 0xFFFFFF
		var stored := (b & 0xFFFFFF) if (flags & 1) else size
		if off + stored > diro:
			return {}
		entries.append({"id": d.decode_u16(p), "flags": flags, "type": b >> 24, "size": size,
			"raw": d.slice(off, off + stored)})
		off += (stored + 3) & ~3
		p += 10
	return {"header": d.slice(0, 0x7C), "entries": entries}


static func find(f: Dictionary, id: int) -> int:
	var e: Array = f.get("entries", [])
	for i in e.size():
		if e[i]["id"] == id:
			return i
	return -1


static func has(f: Dictionary, id: int) -> bool:
	return find(f, id) >= 0


# the contents of a resource (empty: not there, or LZW-packed)
static func data(f: Dictionary, id: int) -> PackedByteArray:
	var i := find(f, id)
	if i < 0 or (f["entries"][i]["flags"] & 1):
		return PackedByteArray()
	return f["entries"][i]["raw"]


static func put(f: Dictionary, id: int, d: PackedByteArray) -> bool:
	var i := find(f, id)
	if i < 0 or (f["entries"][i]["flags"] & 1) or d.size() > 0xFFFFFF:
		return false
	f["entries"][i]["raw"] = d
	f["entries"][i]["size"] = d.size()
	return true


static func add(f: Dictionary, id: int, type: int, flags: int, d: PackedByteArray) -> bool:
	if has(f, id) or (flags & 1) or id < 0 or id > 0xFFFF:
		return false
	f["entries"].append({"id": id, "flags": flags, "type": type, "size": d.size(), "raw": d})
	return true


# a file with nothing in it yet (a new mission)
static func empty() -> Dictionary:
	var h := (SIGN + "\r\n").to_ascii_buffer()
	h.append(0x1A)
	h.resize(0x7C)
	return {"header": h, "entries": []}


static func build(f: Dictionary) -> PackedByteArray:
	var out: PackedByteArray = f["header"].duplicate()
	out.resize(0x80)
	var data0 := out.size()
	for e in f["entries"]:
		out.append_array(e["raw"])
		out.resize((out.size() + 3) & ~3)
	var diro := out.size()
	out.encode_u32(0x7C, diro)
	var entries: Array = f["entries"]
	var dir := PackedByteArray()
	dir.resize(6 + 10 * entries.size())
	dir.encode_u16(0, entries.size())
	dir.encode_u32(2, data0)
	var p := 6
	for e in entries:
		var stored: int = e["raw"].size()
		dir.encode_u16(p, e["id"])
		dir.encode_u32(p + 2, (int(e["size"]) & 0xFFFFFF) | (int(e["flags"]) << 24))
		dir.encode_u32(p + 6, (stored & 0xFFFFFF) | (int(e["type"]) << 24))
		p += 10
	out.append_array(dir)
	return out


# a compound resource from its items, and a string table from its strings (each ends with a 0)
static func compound(items: Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(2 + 4 * (items.size() + 1))
	out.encode_u16(0, items.size())
	var off := out.size()
	for k in items.size():
		out.encode_u32(2 + 4 * k, off)
		off += items[k].size()
	out.encode_u32(2 + 4 * items.size(), off)
	for it in items:
		out.append_array(it)
	return out


static func items(d: PackedByteArray) -> Array:
	var out := []
	if d.size() < 6:
		return out
	var n := d.decode_u16(0)
	if 2 + 4 * (n + 1) > d.size():
		return out
	for k in n:
		var a := d.decode_u32(2 + 4 * k)
		var b := d.decode_u32(2 + 4 * (k + 1))
		if a > b or b > d.size():
			return []
		out.append(d.slice(a, b))
	return out


# text -> the game's bytes (DOS code page 850, as lgres.gd reads it), with the ending 0
static func cp850(s: String) -> PackedByteArray:
	var table: String = load("res://scripts/lgres.gd").CP850
	var out := PackedByteArray()
	for i in s.length():
		var c := s.unicode_at(i)
		if c == 10 or (c >= 32 and c < 127):
			out.append(c)
		else:
			var k := table.find(s[i])
			out.append(128 + k if k >= 0 else 63)       # (63: "?", a letter the game's font does not have)
	out.append(0)
	return out


static func strings(list: Array) -> PackedByteArray:
	var its := []
	for s in list:
		its.append(cp850(str(s)))
	return compound(its)


# ---- writing: beside the file first and read back (a write cut short by a full disk says nothing), then in place
static func write(path: String, d: PackedByteArray) -> String:
	if parse(d).is_empty():
		return "%s: what was about to be written is not a whole LG Res file" % path.get_file()
	var tmp := path + ".tmp"
	var fa := FileAccess.open(tmp, FileAccess.WRITE)
	if fa == null:
		return "%s could not be written (is the folder write-protected?)" % tmp.get_file()
	fa.store_buffer(d)
	fa.close()
	if FileAccess.get_file_as_bytes(tmp) != d:
		DirAccess.remove_absolute(tmp)
		return "%s was not written whole (disk full?)" % tmp.get_file()
	if DirAccess.copy_absolute(tmp, path) != OK or FileAccess.get_file_as_bytes(path) != d:
		return "%s could not be replaced (the new version is in %s)" % [path.get_file(), tmp.get_file()]
	DirAccess.remove_absolute(tmp)
	return ""


# the game's own file kept beside it, once: "" or what went wrong
static func keep_original(path: String) -> String:
	var o := path + ORIGINAL
	if FileAccess.file_exists(o):
		return ""
	if not FileAccess.file_exists(path):
		return ""                                   # (a file the game does not have: nothing to keep)
	var d := FileAccess.get_file_as_bytes(path)
	if parse(d).is_empty():
		return "%s is not a whole LG Res file" % path.get_file()
	if DirAccess.copy_absolute(path, o) != OK or FileAccess.get_file_as_bytes(o) != d:
		return "%s could not be kept as %s" % [path.get_file(), o.get_file()]
	return ""


# the game's own version of a file: its kept original when there is one, else the file itself
static func original_path(path: String) -> String:
	return path + ORIGINAL if FileAccess.file_exists(path + ORIGINAL) else path


# back to the game's own file: "" or what went wrong (no kept original: nothing to do)
static func restore(path: String) -> String:
	var o := path + ORIGINAL
	if not FileAccess.file_exists(o):
		return ""
	var d := FileAccess.get_file_as_bytes(o)
	if parse(d).is_empty():
		return "%s is damaged" % o.get_file()
	if DirAccess.copy_absolute(o, path) != OK or FileAccess.get_file_as_bytes(path) != d:
		return "%s could not be put back" % path.get_file()
	return ""
