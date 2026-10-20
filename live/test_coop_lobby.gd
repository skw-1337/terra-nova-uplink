# Test of scripts/coop_lobby.gd (the guest's Mission Outfitting lobby) without the game: a real lobby state captured
# from the game (live/test_coop_lobby_state.json, Mission 27) fed as 'GLB' packets, the buttons and lists used as a
# click would, and the 'L' requests read on a port of ours. Checks: no column of his before he takes one (the host's
# is never offered), "Take this column" asks for that column, the picker opens once it is his, a pilot that is not
# available can't be picked, the pilot / suit / weapon / ASF choices ask for the right items, a two-slot weapon locks
# the arm's second slot, the Scout suit hides it, the specialty's ASF can't be changed, the state sent twice does not
# send anything, a locked column has no controls, a mission hides the lobby.
#   godot --headless --path . --script res://live/test_coop_lobby.gd
extends SceneTree

const Lobby := preload("res://scripts/coop_lobby.gd")
const PORT := 47864

var lobby
var rx := PacketPeerUDP.new()
var base := {}
var fails := 0
var checks := 0


func _initialize() -> void:
	rx.bind(PORT, "127.0.0.1")
	base = JSON.parse_string(FileAccess.get_file_as_string("res://live/test_coop_lobby_state.json"))
	lobby = Lobby.new()
	lobby.play_port = PORT
	root.add_child(lobby)
	_run.call_deferred()


func _check(ok: bool, what: String) -> void:
	checks += 1
	if not ok:
		fails += 1
	print(("ok   " if ok else "FAIL ") + what)


func _feed(st: Dictionary) -> void:
	lobby.feed(("GLB" + JSON.stringify(st)).to_utf8_buffer())


func _sent() -> Array:
	var out := []
	while rx.get_available_packet_count() > 0:
		var pk := rx.get_packet()
		if pk.size() > 1 and pk[0] == 76:            # 'L'
			out.append(JSON.parse_string(pk.slice(1).get_string_from_utf8()))
	return out


func _with(changes: Dictionary) -> Dictionary:
	var st: Dictionary = base.duplicate(true)
	for k in changes:
		st[k] = changes[k]
	return st


func _buttons(n: Node, out: Array) -> Array:
	for c in n.get_children():
		if c is Button and not (c is OptionButton):
			out.append(c)
		_buttons(c, out)
	return out


func _wait() -> void:
	await process_frame
	await process_frame
	OS.delay_msec(30)


func _run() -> void:
	# 1. not joined: three "Take this column" buttons (columns 2-4), none for the host's
	_feed(_with({"col": 0}))
	await _wait()
	var b := _buttons(lobby.cols_box, [])
	_check(b.size() == 3 and b.all(func(x): return x.text == "TAKE THIS COLUMN"), "3 columns to take, none for the host")
	var none_free := true
	for i in lobby.pilots_list.item_count:
		none_free = none_free and lobby.pilots_list.is_item_disabled(i)
	_check(none_free and lobby.suit_opt.disabled and lobby.ready_btn.disabled, "no pilot / loadout / ready before a column is his")
	_check(lobby.title.text.contains("OPERATION AEGIS"), "the operation in the title")
	_check(lobby.note_label.text.begins_with("Nik, we can't"), "the screen's note in the briefing")
	_check(lobby.root.visible, "lobby shown on the outfitting screen")
	b[1].pressed.emit()                              # column 3
	await _wait()
	var s := _sent()
	_check(s.size() == 1 and s[0]["act"] == "join" and int(s[0]["col"]) == 2, "take column 3 -> join col 2 (%s)" % [s])

	# 2. column 2 is his
	var cols: Array = base["cols"].duplicate(true)
	_feed(_with({"col": 1, "cols": cols}))
	await _wait()
	_check(not lobby.suit_opt.disabled and not lobby.ready_btn.disabled, "loadout and ready once the column is his")
	_check(lobby.spec_label.text.contains("Sensors") and lobby.slot_opts[0].tooltip_text.contains("Range"), "spec lines: his suit, his weapons on their drop-downs")
	var editing := false
	for c in lobby.cols_box.get_children():
		for l in c.find_children("*", "Label", true, false):
			editing = editing or l.text == "HOST EDITING"
	_check(editing, "the column the host is on is marked")
	b = _buttons(lobby.cols_box, [])
	_check(b.size() == 3 and b.any(func(x): return x.text == "LEAVE"), "a Leave button on his column")
	_check(_sent().is_empty(), "showing the state sends nothing")
	_feed(_with({"col": 1, "cols": cols}))
	await _wait()
	_check(_sent().is_empty(), "the same state again sends nothing")

	# pilots: an available one is asked for, one away is disabled
	var pl: ItemList = lobby.pilots_list
	var dewitt := -1
	var ashford := -1
	for i in pl.item_count:
		var t := pl.get_item_text(i)
		if t.begins_with("DeWitt"):
			dewitt = i
		if t.begins_with("Ashford"):
			ashford = i
	_check(dewitt >= 0 and not pl.is_item_disabled(dewitt), "DeWitt available")
	_check(ashford >= 0 and pl.is_item_disabled(ashford), "Ashford (away) can't be picked")
	pl.item_selected.emit(dewitt)
	await _wait()
	s = _sent()
	_check(s.size() == 1 and s[0]["act"] == "pilot" and int(s[0]["row"]) == int(pl.get_item_metadata(dewitt)), "pick DeWitt -> pilot row (%s)" % [s])

	# suit: Standard
	var so: OptionButton = lobby.suit_opt
	var std := -1
	for i in so.item_count:
		if so.get_item_text(i) == "Standard Suit":
			std = i
	so.item_selected.emit(std)
	await _wait()
	s = _sent()
	_check(s.size() == 1 and s[0]["act"] == "suit" and int(s[0]["id"]) == 1, "Standard Suit -> suit 1 (%s)" % [s])

	# weapon: Laser in left arm 1
	var o0: OptionButton = lobby.slot_opts[0]
	var laser := -1
	for i in o0.item_count:
		if o0.get_item_text(i) == "Laser":
			laser = i
	o0.item_selected.emit(laser)
	await _wait()
	s = _sent()
	_check(s.size() == 1 and s[0]["act"] == "weapon" and int(s[0]["slot"]) == 0 and int(s[0]["id"]) == 4, "Laser in left arm 1 (%s)" % [s])

	# a two-slot weapon on the right arm: its second slot is locked; the Scout suit has no Missile Launcher
	var c1: Dictionary = cols[1].duplicate(true)
	c1["w"] = [4, 11, 10, 0]
	c1["suit"] = 2
	var cols2: Array = cols.duplicate(true)
	cols2[1] = c1
	_feed(_with({"col": 1, "cols": cols2}))
	await _wait()
	_check(lobby.slot_opts[3].disabled and not lobby.slot_opts[2].disabled, "Missile Launcher: right arm 2 locked")
	_check(lobby.slot_opts[2].get_item_text(lobby.slot_opts[2].selected).begins_with("Missile Launcher"), "right arm 1 shows the Missile Launcher")
	c1 = c1.duplicate(true)
	c1["suit"] = 0
	c1["w"] = [4, 4, 4, 4]
	cols2[1] = c1
	_feed(_with({"col": 1, "cols": cols2}))
	await _wait()
	var missile := false
	for i in lobby.slot_opts[0].item_count:
		missile = missile or lobby.slot_opts[0].get_item_text(i).begins_with("Missile")
	_check(not missile, "Scout Suit: no Missile Launcher offered")

	# ASF: the specialty's one is fixed, another one can be changed
	_check(lobby.asf_opt.disabled, "Demolition Pack (specialty) can't be changed")
	c1 = c1.duplicate(true)
	c1["asf"] = 8
	c1["suit"] = 2
	cols2[1] = c1
	_feed(_with({"col": 1, "cols": cols2}))
	await _wait()
	_check(not lobby.asf_opt.disabled, "Personal Shield can be changed")
	var jj := -1
	for i in lobby.asf_opt.item_count:
		if lobby.asf_opt.get_item_text(i) == "Jump Jet Booster":
			jj = i
	lobby.asf_opt.item_selected.emit(jj)
	await _wait()
	s = _sent()
	_check(s.size() == 1 and s[0]["act"] == "asf" and int(s[0]["id"]) == 4, "Jump Jet Booster -> asf 4 (%s)" % [s])

	# locked by the host: no controls, no Leave, no other column
	_feed(_with({"col": 1, "cols": cols2, "locked": true}))
	await _wait()
	b = _buttons(lobby.cols_box, [])
	_check(b.is_empty(), "locked: no column buttons")
	_check(lobby.suit_opt.disabled and lobby.slot_opts.all(func(x): return x.disabled) and lobby.asf_opt.disabled, "locked: loadout disabled")
	var all_off := true
	for i in lobby.pilots_list.item_count:
		all_off = all_off and lobby.pilots_list.is_item_disabled(i)
	_check(all_off, "locked: no pilot can be picked")

	# ready, chat, saved loadouts
	_feed(_with({"col": 1, "cols": cols2}))
	await _wait()
	_sent()
	lobby.ready_btn.toggled.emit(true)
	await _wait()
	s = _sent()
	_check(s.size() == 1 and s[0]["act"] == "ready" and s[0]["on"] == true, "READY -> ready on (%s)" % [s])
	lobby.chat_edit.text_submitted.emit("on y va ?")
	await _wait()
	s = _sent()
	_check(s.size() == 1 and s[0]["act"] == "chat" and s[0]["text"] == "on y va ?", "chat line sent (%s)" % [s])
	_feed(_with({"col": 1, "cols": cols2, "chat": [[1, "host", "ok go"], [2, "guest", "on y va ?"]]}))
	await _wait()
	_check(lobby.chat_log.text.contains("ok go") and lobby.chat_log.text.contains("on y va ?"), "chat shown")
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://coop_loadouts.json"))
	lobby.save_btns[1].pressed.emit()
	await _wait()
	_check(_sent().is_empty() and FileAccess.file_exists("user://coop_loadouts.json"), "SAVE 2 writes the file, sends nothing")
	lobby.load_btns[1].pressed.emit()
	await _wait()
	s = _sent()
	var acts := s.map(func(x): return x["act"])
	_check(acts.size() >= 3 and acts[0] == "suit" and acts.has("weapon") and acts[-1] == "asf", "LOAD 2 -> suit, weapons, ASF (%s)" % [acts])
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://coop_loadouts.json"))

	# in a mission: hidden
	_feed(_with({"col": 1, "mission": true, "outfit": false}))
	await _wait()
	_check(not lobby.root.visible, "mission: lobby hidden")

	print("%d / %d checks passed" % [checks - fails, checks])
	quit(1 if fails else 0)
