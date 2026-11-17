# Test of the mission editor's file side without the game: an LG Res file made up here (a plain resource, a
# compound one, an "LZW" one kept as read) written by lgres.gd's save() and read back the same; compose() is the
# inverse of frames(); the editor's numbering of added units (after the mission's own entity numbers, next in
# their class, again after one is removed); mission_mod.gd: a creation (the changes against a mission) made, written
# as a file and as a code, read back and applied on a fresh copy: the very same records; each error told.
#   godot --headless --path . --script res://live/test_mission_editor.gd
extends SceneTree

const LGRes := preload("res://scripts/lgres.gd")
const Editor := preload("res://scripts/mission_editor.gd")
const Mod := preload("res://scripts/mission_mod.gd")

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


func _nums(recs: Array) -> Array:
	var out := []
	for q in recs:
		out.append([q[0], q.decode_u16(2), q.decode_u16(4)])
	return out


# a unit record with something in every part of it
func _unit(cls: int, type: int, num: int, idx: int, seed_v: int) -> PackedByteArray:
	var r := _rec(cls, num, idx)
	r[1] = type
	r[7] = seed_v % 5
	r.encode_s32(8, (100 + seed_v * 7) * 65536 + seed_v * 311)
	r.encode_s32(12, (200 + seed_v * 3) * 65536 + seed_v * 97)
	r.encode_u16(20, seed_v * 4001)
	r[26] = seed_v % 3
	for k in 7:
		r[27 + k] = 100
	r[34] = 0x12 + seed_v % 8
	r[35] = 0x14
	return r


# the game's missions of this test: MISSA.RES (the one edited) and MISSB.RES (units are copied from it)
var lib := {}


func _source(file: String, index: int) -> PackedByteArray:
	var l: Array = lib.get(file.to_upper(), [])
	return l[index] if index >= 0 and index < l.size() else PackedByteArray()


func _copy(a: Array) -> Array:
	var out := []
	for r in a:
		out.append(PackedByteArray(r).duplicate())
	return out


# Sharing: a creation is the changes against the original mission; export -> import on a fresh copy gives the very
# same records and zones; the errors are told.
func _creations() -> void:
	var orig := []
	for k in 6:
		orig.append(_unit(1 if k < 4 else 4, 10 + k % 2, k + 1, k + 1, k + 1))
	var other := []
	for k in 4:
		other.append(_unit(1 if k < 2 else 2, 4 + k, k + 1, k + 1, 20 + k))
	lib = {"MISSA.RES": orig, "MISSB.RES": other}
	var zones := PackedByteArray()
	zones.resize(8 * 4)
	for z in 4:
		zones.encode_s32(8 * z, (50 + z) * 65536)
		zones.encode_s32(8 * z + 4, (60 + z) * 65536)
	# the edited state: unit 1 removed, unit 2 moved / turned / regrouped / labelled / rearmed, two units added (one a
	# copy of MISSB's unit 1, one of this mission's own unit 4), zone 2 moved
	var recs := _copy(orig)
	recs.remove_at(1)
	var e: PackedByteArray = recs[1]
	e.encode_s32(8, 333 * 65536 + 5)
	e.encode_s32(16, 2 * 65536)
	e.encode_u16(20, 0xC000)
	e[7] = 9
	e[26] = 4
	e[28] = 140
	e[36] = 0x1D
	var a1: PackedByteArray = PackedByteArray(other[1]).duplicate()
	a1.encode_s32(8, 12 * 65536)
	a1.encode_s32(12, 34 * 65536 + 1)
	a1[7] = 2
	var a2: PackedByteArray = PackedByteArray(orig[4]).duplicate()
	a2.encode_s32(12, 77 * 65536)
	a2[27] = 55
	recs.append(a1)
	recs.append(a2)
	var origin := [0, 2, 3, 4, 5, -1, -1]
	var src := [{}, {}, {}, {}, {}, {"f": "MISSB.RES", "i": 1}, {"f": "MISSA.RES", "i": 4}]
	Mod.renumber(orig, recs, origin)
	var z2 := zones.duplicate()
	z2.encode_s32(16, 99 * 65536 + 9)
	var st := {"recs": recs, "origin": origin, "src": src, "zones": z2}
	var mod := Mod.make("C:/game/TNOVA/DATA/missa.res", orig, zones, st, _source)
	_check(not mod.has("error") and mod["base"]["file"] == "MISSA.RES" and mod["base"]["units"] == 6, "a creation is made, for MISSA.RES")
	_check(mod["remove"] == [1] and mod["edit"].size() == 1 and mod["add"].size() == 2 and mod["zones"] == [[2, 99 * 65536 + 9, 62 * 65536]],
		"it holds 1 removal, 1 changed unit, 2 added units, 1 moved zone (%s)" % Mod.summary(mod))
	var ed: Dictionary = mod["edit"][0]
	_check(ed["i"] == 2 and ed["g"] == 9 and ed["l"] == 4 and ed["h"] == 0xC000 and ed["x"] == 333 * 65536 + 5 and ed["z"] == 2 * 65536
		and not ed.has("y") and ed["o"] == [28, 140, 36, 0x1D], "the changed unit: only the fields that changed (%s)" % [ed])
	var ad: Dictionary = mod["add"][0]
	_check(ad["from"] == "MISSB.RES" and ad["rec"] == 1 and ad["sum"] == Mod.digest([other[1]], 8) and ad["g"] == 2 and not ad.has("h"),
		"an added unit: the game's record it copies and what differs (%s)" % [ad])
	var js := Mod.to_json(mod)
	var has_game_data := false
	for r in orig + other:
		has_game_data = has_game_data or js.contains(Marshalls.raw_to_base64(r)) or js.contains(PackedByteArray(r).hex_encode())
	_check(not has_game_data and js.length() < 700, "no record of the game in it (%d characters)" % js.length())

	# round trip, as a file and as a code, on a fresh copy of the original
	for form in ["file", "code"]:
		var text: String = js if form == "file" else Mod.to_code(mod)
		if form == "code":
			_check(text.begins_with(Mod.PREFIX) and not text.contains(" ") and not text.contains("\n"), "the code: one word of %d characters" % text.length())
			text = "look at this:\n" + text.substr(0, 40) + " \r\n " + text.substr(40, 30) + "\n" + text.substr(70) + "\n"   # (pasted through a chat)
		var back := Mod.from_text(text)
		_check(not back.has("error"), "%s: read back%s" % [form, "" if not back.has("error") else " (%s)" % back.get("error")])
		var got := Mod.apply(back, "MISSA.RES", _copy(orig), zones.duplicate(), _source)
		_check(not got.has("error") and got["recs"] == recs and got["zones"] == z2, "%s: on a fresh copy, the very same units and zones" % form)
		_check(not got.has("error") and got["origin"] == origin and got["src"] == src, "%s: each unit known as the mission's own or an added one" % form)
		if not got.has("error"):
			var again := Mod.make("MISSA.RES", orig, zones, got, _source)
			_check(Mod.to_json(again) == js, "%s: exported again, the same creation" % form)
	var none := Mod.make("MISSA.RES", orig, zones, {"recs": _copy(orig), "origin": [0, 1, 2, 3, 4, 5], "src": [{}, {}, {}, {}, {}, {}], "zones": zones}, _source)
	_check(Mod.is_empty(none) and Mod.summary(none) == "no change", "an untouched mission: an empty creation")

	# the errors, each told
	var code := Mod.to_code(mod)
	var er: Dictionary = Mod.apply(mod.duplicate(true), "MISSB.RES", other, zones, _source)
	_check(str(er.get("error", "")).contains("is for MISSA.RES") and er.get("wrong_mission") == "MISSA.RES", "wrong mission: " + str(er.get("error")))
	var changed := _copy(orig)
	changed[3][34] = 0x1F
	er = Mod.apply(mod.duplicate(true), "MISSA.RES", changed, zones, _source)
	_check(str(er.get("error", "")).contains("another MISSA.RES"), "another version of the mission: " + str(er.get("error")))
	lib["MISSB.RES"] = [other[0]]
	er = Mod.apply(mod.duplicate(true), "MISSA.RES", orig, zones, _source)
	_check(str(er.get("error", "")).contains("unit 1 of MISSB.RES") and str(er.get("error", "")).contains("does not have"), "a source record missing: " + str(er.get("error")))
	lib["MISSB.RES"] = [other[0], other[2]]
	er = Mod.apply(mod.duplicate(true), "MISSA.RES", orig, zones, _source)
	_check(str(er.get("error", "")).contains("not the same in this game"), "a source record that differs: " + str(er.get("error")))
	lib["MISSB.RES"] = other
	er = Mod.from_text(code.substr(0, code.length() - 30))
	_check(str(er.get("error", "")).contains("cut short") or str(er.get("error", "")).contains("damaged"), "a code cut short: " + str(er.get("error")))
	var k := code.length() / 2
	er = Mod.from_text(code.substr(0, k) + ("A" if code[k] != "A" else "B") + code.substr(k + 1))
	_check(str(er.get("error", "")).contains("damaged"), "a code with a wrong character: " + str(er.get("error")))
	er = Mod.from_text("hello there")
	_check(str(er.get("error", "")).contains("no creation code"), "not a code: " + str(er.get("error")))
	er = Mod.from_text("{\"tnmod\": 2, \"base\": {}}")
	_check(str(er.get("error", "")).contains("newer Uplink"), "a newer format: " + str(er.get("error")))
	er = Mod.from_text("{\"tnmod\": 1, \"base\": {\"file\": \"../../x.RES\", \"sum\": \"0\"}}")
	_check(er.has("error"), "a mission name that is a path: refused (%s)" % str(er.get("error")))
	var bad: Dictionary = mod.duplicate(true)
	bad["edit"][0]["g"] = 40
	er = Mod.apply(bad, "MISSA.RES", orig, zones, _source)
	_check(str(er.get("error", "")).contains("group 40"), "a group the game does not have: " + str(er.get("error")))
	bad = mod.duplicate(true)
	bad["remove"] = [17]
	er = Mod.apply(bad, "MISSA.RES", orig, zones, _source)
	_check(er.has("error"), "a removal out of the mission: refused (%s)" % str(er.get("error")))
	bad = mod.duplicate(true)
	bad["add"][0]["o"] = [3, 1]
	er = Mod.apply(bad, "MISSA.RES", orig, zones, _source)
	_check(er.has("error"), "a change of a unit's class or numbers: refused (%s)" % str(er.get("error")))


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

	# the added units' numbers: after the mission's own entity numbers, the next ones in their class
	var orig := [_rec(1, 1, 1), _rec(1, 2, 2), _rec(4, 7, 3)]
	var recs := [_rec(1, 1, 1), _rec(1, 2, 2), _rec(4, 7, 3), _rec(1, 0, 0), _rec(4, 0, 0), _rec(1, 0, 0)]
	var origin := [0, 1, 2, -1, -1, -1]
	Mod.renumber(orig, recs, origin)
	_check(_nums(recs).slice(3) == [[1, 8, 3], [4, 9, 4], [1, 10, 4]], "added units: numbers after 7, next in their class (%s)" % [_nums(recs).slice(3)])
	recs.remove_at(3)
	origin.remove_at(3)
	Mod.renumber(orig, recs, origin)
	_check(_nums(recs).slice(3) == [[4, 8, 4], [1, 9, 3]], "one removed: renumbered with no gap (%s)" % [_nums(recs).slice(3)])
	_check(_nums(recs).slice(0, 3) == [[1, 1, 1], [1, 2, 2], [4, 7, 3]], "the mission's own units untouched")
	recs.remove_at(1)                                # one of the mission's own taken out: the others keep their numbers
	origin.remove_at(1)
	Mod.renumber(orig, recs, origin)
	_check(_nums(recs) == [[1, 1, 1], [4, 7, 3], [4, 8, 4], [1, 9, 3]], "one of the mission's own removed: no number moves (%s)" % [_nums(recs)])
	_check(Editor._is_ai(_rec(1, 1, 1)) and not Editor._is_ai(_rec(4, 1, 1)) and not Editor._is_ai(_rec(0, 1, 1)),
		"a soldier takes an AI record of the game, a plain building or a rock does not")

	_creations()

	print("%d / %d checks passed" % [checks - fails, checks])
	quit(1 if fails else 0)
