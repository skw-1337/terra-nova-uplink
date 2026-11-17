# Reader for Looking Glass "LG Res File v2" archives (Terra Nova, System Shock).
# Header: 16-byte signature + comment, directory offset (u32) at 0x7C.
# Directory: count (u16), data offset (u32), then count x 10 bytes:
#   id (u16), size (24 bits) + flags (8), compressed size (24) + type (8).
# Data follows from the data offset, each resource aligned on 4 bytes.
# flags: 0x01 LZW (not supported here, not needed by the viewer), 0x02 compound.
# save() writes it back (the mission editor): the same header, the resources in their order, a changed one with
# its new size (an LZW one is kept as read).
extends RefCounted

const CP850 := "ÇüéâäàåçêëèïîìÄÅÉæÆôöòûùÿÖÜø£Ø×ƒáíóúñÑªº¿®¬½¼¡«»░▒▓│┤ÁÂÀ©╣║╗╝¢¥┐└┴┬├─┼ãÃ╚╔╩╦╠═╬¤ðÐÊËÈıÍÎÏ┘┌█▄¦Ì▀ÓßÔÒõÕµþÞÚÛÙýÝ¯´\u00AD±‗¾¶§÷¸°¨·¹³²■\u00A0"

var resources := {}   # id -> {"type": int, "flags": int, "data": PackedByteArray, "size": int}
var order := []       # the ids in file order
var header := PackedByteArray()


static func open(path: String):
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var d := f.get_buffer(f.get_length())
	if d.size() < 0x80 or d.slice(0, 14).get_string_from_ascii() != "LG Res File v2":
		return null
	var r = load("res://scripts/lgres.gd").new()
	var diro := d.decode_u32(0x7C)
	if diro + 6 > d.size():
		return null                               # (a file cut short: its directory is gone)
	var n := d.decode_u16(diro)
	var off := d.decode_u32(diro + 2)
	var p := diro + 6
	if p + 10 * n > d.size():
		return null
	r.header = d.slice(0, 0x7C)
	for i in n:
		var rid := d.decode_u16(p)
		var a := d.decode_u32(p + 2)
		var b := d.decode_u32(p + 6)
		p += 10
		var size := a & 0xFFFFFF
		var flags := a >> 24
		var length := (b & 0xFFFFFF) if (flags & 1) else size
		if off + length > diro:
			return null                           # (a resource past the data: not a whole file)
		r.resources[rid] = {"type": b >> 24, "flags": flags, "data": d.slice(off, off + length), "size": size}
		r.order.append(rid)
		off += (length + 3) & ~3
	return r


func has(rid: int) -> bool:
	return resources.has(rid)


# false: the file has no such resource (nothing changed)
func set_data(rid: int, d: PackedByteArray) -> bool:
	if not resources.has(rid):
		return false
	resources[rid]["data"] = d
	resources[rid]["size"] = d.size()
	return true


# "" when written, else what went wrong
func save(path: String) -> String:
	var out := header.duplicate()
	out.resize(0x80)
	var data0 := out.size()
	for rid in order:
		out.append_array(resources[rid]["data"])
		out.resize((out.size() + 3) & ~3)
	var diro := out.size()
	out.encode_u32(0x7C, diro)
	var dir := PackedByteArray()
	dir.resize(6 + 10 * order.size())
	dir.encode_u16(0, order.size())
	dir.encode_u32(2, data0)
	var p := 6
	for rid in order:
		var e: Dictionary = resources[rid]
		var stored: int = e["data"].size()
		dir.encode_u16(p, rid)
		dir.encode_u32(p + 2, ((e["size"] if e["flags"] & 1 else stored) & 0xFFFFFF) | (e["flags"] << 24))
		dir.encode_u32(p + 6, (stored & 0xFFFFFF) | (e["type"] << 24))
		p += 10
	out.append_array(dir)
	# written beside it first and read back (a write cut short by a full disk or a lock says nothing), then put in
	# place and read back again; the good copy stays beside it if that last step fails
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "%s could not be written" % tmp.get_file()
	f.store_buffer(out)
	f.close()
	if FileAccess.get_file_as_bytes(tmp) != out:
		DirAccess.remove_absolute(tmp)
		return "%s was not written whole (disk full?)" % tmp.get_file()
	if DirAccess.copy_absolute(tmp, path) != OK or FileAccess.get_file_as_bytes(path) != out:
		return "%s could not be written (the saved version is in %s)" % [path.get_file(), tmp.get_file()]
	DirAccess.remove_absolute(tmp)
	return ""


# A compound resource from its items (the inverse of frames()).
static func compose(items: Array) -> PackedByteArray:
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


func data(rid: int) -> PackedByteArray:
	if not resources.has(rid):
		return PackedByteArray()
	return resources[rid]["data"]


# Compound resource: count (u16), then count + 1 offsets (u32), then the items.
static func frames(d: PackedByteArray) -> Array:
	var out := []
	if d.size() < 2:
		return out
	var n := d.decode_u16(0)
	for k in n:
		out.append(d.slice(d.decode_u32(2 + 4 * k), d.decode_u32(2 + 4 * (k + 1))))
	return out


# DOS code page 850 text (the French data uses accented letters), stops at the first 0.
static func text(b: PackedByteArray) -> String:
	var s := ""
	for c in b:
		if c == 0:
			break
		s += String.chr(c) if c < 128 else CP850[c - 128]
	return s


# Fixed 16-byte name records, as used by several tables.
static func names16(d: PackedByteArray) -> PackedStringArray:
	var out := PackedStringArray()
	for i in range(0, d.size() - 15, 16):
		out.append(text(d.slice(i, i + 16)))
	return out


func strings(rid: int) -> PackedStringArray:
	var out := PackedStringArray()
	for f in frames(data(rid)):
		out.append(text(f))
	return out
