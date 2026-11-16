# Test of the mission editor's file side without the game: an LG Res file made up here (a plain resource, a
# compound one, an "LZW" one kept as read) written by lgres.gd's save() and read back the same; compose() is the
# inverse of frames(); the editor's numbering of added units (after the mission's own entity numbers, next in
# their class, again after one is removed).
#   godot --headless --path . --script res://live/test_mission_editor.gd
extends SceneTree

const LGRes := preload("res://scripts/lgres.gd")
const Editor := preload("res://scripts/mission_editor.gd")

var fails := 0
var checks := 0


func _check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print(("ok   " if ok else "FAIL ") + what)


func _res_file(entries: Array) -> PackedByteArray:
	# [[id, flags, type, data, size]] -> an LG Res v2 file as the game's
	var out := "LG Res File v2\r\n".to_ascii_buffer()
	out.resize(0x80)
	var data0 := out.size()
	for e in entries:
		out.append_array(e[3])
		out.resize((out.size() + 3) & ~3)
	var diro := out.size()
	out.encode_u32(0x7C, diro)
	var dir := PackedByteArray()
	dir.resize(6 + 10 * entries.size())
	dir.encode_u16(0, entries.size())
	dir.encode_u32(2, data0)
	for k in entries.size():
		var e: Array = entries[k]
		dir.encode_u16(6 + 10 * k, e[0])
		dir.encode_u32(8 + 10 * k, (e[4] & 0xFFFFFF) | (e[1] << 24))
		dir.encode_u32(12 + 10 * k, (e[3].size() & 0xFFFFFF) | (e[2] << 24))
	out.append_array(dir)
	return out


func _rec(cls: int, num: int, idx: int) -> PackedByteArray:
	var r := PackedByteArray()
	r.resize(50)
	r[0] = cls
	r.encode_u16(2, num)
	r.encode_u16(4, idx)
	return r


func _initialize() -> void:
	var dir := OS.get_user_data_dir().path_join("test_mission_editor")
	DirAccess.make_dir_recursive_absolute(dir)
	var src := dir.path_join("MISSTEST.RES")
	var dst := dir.path_join("MISSTEST_out.RES")
	var items := [PackedByteArray([1, 2, 3]), PackedByteArray([4, 5, 6, 7, 8]), PackedByteArray()]
	var file := _res_file([[170, 0, 0, "map5.res".to_ascii_buffer(), 8], [173, 2, 0, LGRes.compose(items), LGRes.compose(items).size()],
		[181, 1, 0, PackedByteArray([9, 9, 9, 9, 9, 9, 9]), 40]])
	var f := FileAccess.open(src, FileAccess.WRITE)
	f.store_buffer(file)
	f.close()

	var r = LGRes.open(src)
	_check(r != null and r.order == [170, 173, 181], "the made-up file reads, resources in order")
	_check(LGRes.frames(r.data(173)) == items, "frames() gives the items back")
	_check(LGRes.compose(LGRes.frames(r.data(173))) == r.data(173), "compose() is the inverse of frames()")
	r.save(dst)
	_check(FileAccess.get_file_as_bytes(dst) == file, "saved unchanged: the same bytes")
	var more := items.duplicate()
	more.append(PackedByteArray([10, 11]))
	r.set_data(173, LGRes.compose(more))
	r.save(dst)
	var r2 = LGRes.open(dst)
	_check(r2 != null and LGRes.frames(r2.data(173)) == more, "a changed resource: written and read back")
	_check(r2.data(170) == "map5.res".to_ascii_buffer() and r2.data(181) == PackedByteArray([9, 9, 9, 9, 9, 9, 9]),
		"the others as they were")
	_check(r2.resources[181]["size"] == 40 and r2.resources[181]["flags"] == 1, "the LZW one keeps its unpacked size")

	var e = Editor.new()
	e.recs = [_rec(1, 1, 1), _rec(1, 2, 2), _rec(4, 7, 3), _rec(1, 0, 0), _rec(4, 0, 0), _rec(1, 0, 0)]
	e.n_orig = 3
	e._renumber()
	var nums := []
	for q in e.recs:
		nums.append([q[0], q.decode_u16(2), q.decode_u16(4)])
	_check(nums.slice(3) == [[1, 8, 3], [4, 9, 4], [1, 10, 4]], "added units: numbers after 7, next in their class (%s)" % [nums.slice(3)])
	e.recs.remove_at(3)
	e._renumber()
	nums = []
	for q in e.recs:
		nums.append([q[0], q.decode_u16(2), q.decode_u16(4)])
	_check(nums.slice(3) == [[4, 8, 4], [1, 9, 3]], "one removed: renumbered with no gap (%s)" % [nums.slice(3)])
	_check(nums.slice(0, 3) == [[1, 1, 1], [1, 2, 2], [4, 7, 3]], "the mission's own units untouched")
	e.free()

	print("%d / %d checks passed" % [checks - fails, checks])
	quit(1 if fails else 0)
