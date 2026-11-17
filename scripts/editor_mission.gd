# The mission editor's Mission panel (M, or the MISSION button of the spawn menu): what the mission asks of the
# player and what its groups do, in plain sentences, and the controls to change it.
#   - a mission whose script is made of the editor's blocks (a new mission of yours, or an imported creation that
#     has one): the three objectives (destroy / keep alive, a label, a percentage; several conditions an objective),
#     each group's orders at the start (patrol three zones, go to a zone, hold a zone, link with a group), the
#     mission ending by itself some seconds after an objective, the four debriefing texts;
#   - one of the game's own missions: its script is the game's ("custom"): shown as sentences, each of its numbers
#     (labels, percentages, zones, groups) changeable one by one;
#   - the zones (place one where you aim, remove one), what the script counts on and the mission no longer has,
#     PLAY THIS MISSION, and your own missions in the game's two free slots (create, open, remove).
# It only shows and asks: the editor (mission_editor.gd) keeps the script part, undoes, saves and installs.
# The blocks not offered (ID lock, attack a group / a label, follow) are kept as they are when a creation has them.
extends PanelContainer

signal edited(part: Dictionary, new_part: Dictionary, tag: String, soft: bool)   # soft: a value typed (no rebuild)
signal number_changed(id: String, value: int)        # one of the game's own numbers
signal numbers_reset
signal closed
signal play_pressed
signal new_pressed(like: String, mission_name: String)
signal open_pressed(slot: int)
signal remove_pressed(slot: int)
signal zone_place(z: int)
signal zone_remove(z: int)
signal zone_pick(setter: Callable)                   # the next zone post clicked in the world goes to setter(z)

const Menu = preload("res://scripts/editor_menu.gd")
const KINDS := [["kill", "Destroy"], ["alive", "Keep alive"]]
const ORDERS := [["patrol", "Patrol three zones"], ["move", "Go to a zone"], ["hold_zone", "Hold a zone"],
	["link", "Link with a group"]]
const DEBRIEF := ["Objective 1 is the best one done", "Objective 2 is the best one done",
	"Objective 3 is the best one done", "No objective done"]
const DEFAULT_DEBRIEF := ["Mission complete.", "Mission complete.", "Mission complete.", "Mission failed."]
const DIM := Color(0.65, 0.7, 0.75)
const WARN := Color(1.0, 0.78, 0.3)

var info := {}
var part := {}
var newp := {}
var busy := false
var title: Label
var sub: Label
var body: VBoxContainer
var fields := {}                 # tag -> its control (the tests press these)
var like_opt: OptionButton
var name_edit: LineEdit
var zone_spin: SpinBox


func _ready() -> void:
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 0.0
	anchor_bottom = 1.0
	offset_left = 12
	offset_right = 552
	offset_top = 60
	offset_bottom = -80
	add_theme_stylebox_override("panel", Menu._box(Menu.BG, Menu.ACCENT, 2, 10, 10))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	add_child(v)
	var top := HBoxContainer.new()
	v.add_child(top)
	title = Label.new()
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	top.add_child(title)
	var x := Button.new()
	x.text = "✕"
	x.focus_mode = Control.FOCUS_NONE
	x.pressed.connect(func(): closed.emit())
	top.add_child(x)
	sub = Label.new()
	sub.add_theme_font_size_override("font_size", 13)
	sub.add_theme_color_override("font_color", DIM)
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)
	var sc := ScrollContainer.new()
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	body = VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 4)
	sc.add_child(body)


# a field of the panel has the keyboard (the editor's keys are not for it then)
func typing() -> bool:
	var f := get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	return f != null and is_ancestor_of(f)


# ---- what the editor gives (see mission_editor.gd _mission_info), drawn whole
func show_mission(i: Dictionary) -> void:
	busy = true
	info = i
	part = (i.get("part", {}) as Dictionary).duplicate(true)
	newp = (i.get("new", {}) as Dictionary).duplicate(true)
	var keep_like := like_opt.selected if like_opt != null and is_instance_valid(like_opt) else -1
	var keep_name := name_edit.text if name_edit != null and is_instance_valid(name_edit) else ""
	var keep_zone := int(zone_spin.value) if zone_spin != null and is_instance_valid(zone_spin) else 1
	for c in body.get_children():
		body.remove_child(c)
		c.queue_free()
	fields.clear()
	title.text = "MISSION  ·  %s" % i.get("file", "")
	sub.text = str(i.get("name", ""))
	_play_rows()
	if str(i.get("error", "")) != "":
		_text(str(i["error"]), WARN)
	if str(i.get("mode", "none")) != "none":
		_objectives()
		if i["mode"] == "blocks":
			_orders()
			_end()
			_debrief()
		else:
			_game_script()
	_zones(keep_zone)
	_section("WHAT IS MISSING")
	fields["problems"] = _text("", WARN)
	fields["problems_game"] = _text("", DIM)
	_mine(keep_like, keep_name)
	busy = false
	refresh(i)


# the sentences and the problems only (a value was typed: the fields keep the keyboard)
func refresh(i: Dictionary) -> void:
	info = i
	var s: Array = i.get("sentences", [])
	for k in 3:
		if fields.has("what%d" % k) and k < s.size():
			fields["what%d" % k].text = "%d.  %s" % [k + 1, s[k]]
	if fields.has("problems"):
		var p: Array = i.get("problems", [])
		fields["problems"].text = "Nothing: the script finds every unit, group and zone it counts on." if p.is_empty() \
			else "\n".join(p.map(func(t): return "•  " + str(t)))
		fields["problems"].add_theme_color_override("font_color", DIM if p.is_empty() else WARN)
		var pg: Array = i.get("problems_game", [])
		fields["problems_game"].visible = not pg.is_empty()
		fields["problems_game"].text = "Already so in the game's own mission (units that come later, groups the script names without using them):
" 			+ "
".join(pg.map(func(t): return "•  " + str(t)))
	if fields.has("numbers_reset"):
		var np := int(i.get("patched", 0))
		fields["numbers_reset"].text = "Put the game's numbers back  (%d changed)" % np
		fields["numbers_reset"].disabled = np == 0
	if fields.has("orders_said"):
		fields["orders_said"].text = "\n".join((i.get("orders_said", []) as Array).map(func(t): return "•  " + str(t)))


# ---- play
func _play_rows() -> void:
	var pl: Dictionary = info.get("play", {})
	var b := _button("▶   PLAY THIS MISSION", func(): play_pressed.emit(), 16)
	b.add_theme_stylebox_override("normal", Menu._box(Color(0.12, 0.38, 0.2, 0.95), Color(0.45, 0.85, 0.5), 1, 6, 8))
	body.add_child(b)
	fields["play"] = b
	var t := "Saves if needed, then starts the game on this mission."
	if str(pl.get("why", "")) != "":
		t = str(pl["why"])
	if pl.get("alone", false):
		t += "\nKnown limit: in a mission of your own (slots 18 and 28) the game drops the player alone, in a standard suit."
	fields["play_note"] = _text(t, DIM if pl.get("ok", false) else WARN)
	b.disabled = not pl.get("ok", false)


# ---- the objectives
func _spec() -> Dictionary:
	for s in part.get("build", []):
		if int(s.get("mission", 0)) == int(info.get("n", -1)):
			return s
	return {}


func _conds(k: int) -> Array:
	var o = _spec()["objectives"][k]
	return o if o is Array else []


func _objectives() -> void:
	_section("OBJECTIVES")
	var blocks: bool = info["mode"] == "blocks"
	var lines: Array = info.get("lines", ["", "", ""])
	for k in 3:
		var w := _text("", Color(0.92, 0.95, 1.0))
		w.add_theme_font_size_override("font_size", 15)
		fields["what%d" % k] = w
		if not newp.is_empty():
			var le := _line(str(newp.get("objectives", ["", "", ""])[k]), "Its line on the game's objectives screen", 120,
				func(t): _set_new_line(k, t))
			fields["line%d" % k] = le
			body.add_child(le)
		elif k < lines.size() and str(lines[k]).strip_edges() != "":
			_text("     in the game: \"%s\"" % str(lines[k]).strip_edges(), DIM)
		if not blocks:
			continue
		var cs := _conds(k)
		for ci in cs.size():
			_cond_row(k, ci, cs[ci])
		if cs.size() < 5:
			var add := _button("+  Use this objective" if cs.is_empty() else "+  And another condition", func(): _add_cond(k), 13)
			fields["add%d" % k] = add
			var h := HBoxContainer.new()
			var pad := Control.new()
			pad.custom_minimum_size = Vector2(24, 0)
			h.add_child(pad)
			h.add_child(add)
			body.add_child(h)


func _cond_row(k: int, ci: int, c: Dictionary) -> void:
	var h := HBoxContainer.new()
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(24, 0)
	h.add_child(pad)
	var tag := "%d_%d" % [k, ci]
	if str(c.get("kind", "")) == "idlock":
		var l := Label.new()
		l.text = "ID-lock a unit labelled %d for %.1f s  (kept as it is)" % [int(c.get("label", 0)), int(c.get("ms", 0)) / 1000.0]
		l.add_theme_font_size_override("font_size", 14)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
	else:
		var ko := _option(KINDS, str(c.get("kind", "kill")), func(v): _set_cond(k, ci, "kind", v, false))
		ko.custom_minimum_size = Vector2(118, 0)
		h.add_child(ko)
		fields["kind" + tag] = ko
		var pct := _spin(1, 100, int(c.get("pct", 100)), func(v): _set_cond(k, ci, "pct", int(v), true))
		pct.suffix = "%"
		h.add_child(pct)
		fields["pct" + tag] = pct
		h.add_child(_small("of label"))
		var lab := _spin(1, 255, int(c.get("label", 1)), func(v): _set_cond(k, ci, "label", int(v), true))
		lab.tooltip_text = "The units that carry this label (a unit's label: its properties, P)"
		h.add_child(lab)
		fields["label" + tag] = lab
		var n: int = (info.get("labels", {}) as Dictionary).get(int(c.get("label", 0)), 0)
		var cnt := _small("%d unit%s" % [n, "" if n == 1 else "s"])
		cnt.add_theme_color_override("font_color", DIM if n > 0 else WARN)
		h.add_child(cnt)
		fields["count" + tag] = cnt
	var x := _button("✕", func(): _remove_cond(k, ci), 13)
	x.tooltip_text = "Remove this condition"
	h.add_child(x)
	fields["del" + tag] = x
	body.add_child(h)


func _set_cond(k: int, ci: int, key: String, v, soft: bool) -> void:
	_conds(k)[ci][key] = v
	if key == "label" and fields.has("count%d_%d" % [k, ci]):
		var n: int = (info.get("labels", {}) as Dictionary).get(int(v), 0)
		fields["count%d_%d" % [k, ci]].text = "%d unit%s" % [n, "" if n == 1 else "s"]
		fields["count%d_%d" % [k, ci]].add_theme_color_override("font_color", DIM if n > 0 else WARN)
	_commit("cond%d_%d_%s" % [k, ci, key], soft)


func _add_cond(k: int) -> void:
	var sp := _spec()
	if not (sp["objectives"][k] is Array):
		sp["objectives"][k] = []
	sp["objectives"][k].append({"kind": "kill", "label": 2, "pct": 100})
	_commit("cond_add", false)


func _remove_cond(k: int, ci: int) -> void:
	var sp := _spec()
	sp["objectives"][k].remove_at(ci)
	if sp["objectives"][k].is_empty():
		sp["objectives"][k] = null
		var e = sp.get("end", null)
		if e is Dictionary and int(e.get("objective", 0)) == k + 1:   # (the end waited for this objective)
			sp.erase("end")
	_commit("cond_remove", false)


func _set_new_line(k: int, t: String) -> void:
	var o: Array = newp.get("objectives", ["", "", ""])
	o[k] = t
	newp["objectives"] = o
	_commit("line%d" % k, true)


# ---- the orders at the start
func _orders() -> void:
	_section("ORDERS WHEN THE MISSION STARTS")
	var ol: Array = _spec().get("orders", [])
	if ol.is_empty():
		_text("None: every group is left to itself (it stands, and fights what comes near).", DIM)
	for oi in ol.size():
		_order_rows(oi, ol[oi])
	var add := _button("+  Add an order", _add_order, 13)
	fields["order_add"] = add
	body.add_child(add)
	_text("A group holds a zone once it stands inside it. Zones are picked from the list, or with ⌖ then a click on a zone post.", DIM)


func _order_rows(oi: int, od: Dictionary) -> void:
	var kind := str(od.get("order", ""))
	var known := false
	for o in ORDERS:
		known = known or o[0] == kind
	var h := HBoxContainer.new()
	var go := _option(_with(info.get("groups", []), int(od.get("group", 0)), "group %d  (no unit)"), int(od.get("group", 0)),
		func(v): _set_order(oi, "group", int(v)))
	go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(go)
	fields["ogroup%d" % oi] = go
	if known:
		var oo := _option(ORDERS, kind, func(v): _set_order_kind(oi, str(v)))
		oo.custom_minimum_size = Vector2(170, 0)
		h.add_child(oo)
		fields["okind%d" % oi] = oo
	else:
		h.add_child(_small({"attack_group": "attacks group %d" % int(od.get("target", 0)),
			"attack_label": "attacks the units labelled %d" % int(od.get("label", 0)),
			"follow": "follows the units labelled %d" % int(od.get("label", 0))}.get(kind, kind) + "  (kept as it is)"))
	var x := _button("✕", func(): _remove_order(oi), 13)
	x.tooltip_text = "Remove this order"
	h.add_child(x)
	fields["odel%d" % oi] = x
	body.add_child(h)
	if not known:
		return
	var p := HBoxContainer.new()
	var pad := Control.new()
	pad.custom_minimum_size = Vector2(24, 0)
	p.add_child(pad)
	match kind:
		"patrol":
			var zs: Array = od.get("zones", [0, 0, 0])
			for zi in 3:
				_zone_option(p, "ozone%d_%d" % [oi, zi], int(zs[zi]), func(v): _set_patrol_zone(oi, zi, int(v)))
		"move", "hold_zone":
			_zone_option(p, "ozone%d_0" % oi, int(od.get("zone", 0)), func(v): _set_order(oi, "zone", int(v)))
		"link":
			p.add_child(_small("with"))
			var to := _option(_with(info.get("groups", []), int(od.get("target", 0)), "group %d  (no unit)"),
				int(od.get("target", 0)), func(v): _set_order(oi, "target", int(v)))
			to.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			p.add_child(to)
			fields["otarget%d" % oi] = to
	body.add_child(p)


func _zone_option(row: HBoxContainer, tag: String, cur: int, on: Callable) -> void:
	var zo := _option(_with(info.get("zones", []), cur, "zone %d  (not placed)"), cur, on)
	zo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(zo)
	fields[tag] = zo
	var pick := _button("⌖", func(): zone_pick.emit(func(z): on.call(z)), 13)
	pick.tooltip_text = "Then click a zone post in the world"
	row.add_child(pick)
	fields[tag + "_pick"] = pick


# the list with the current value in it, even when the mission no longer has it
static func _with(items: Array, cur: int, missing: String) -> Array:
	var out := items.duplicate()
	for it in out:
		if int(it[0]) == cur:
			return out
	out.append([cur, missing % cur])
	return out


func _first(items: Array, skip: int = -1) -> int:
	for it in items:
		if int(it[0]) != skip:
			return int(it[0])
	return 1 if skip != 1 else 2


func _add_order() -> void:
	var sp := _spec()
	if not (sp.get("orders") is Array):
		sp["orders"] = []
	var zs := _three_zones()
	sp["orders"].append({"group": _first(info.get("groups", [])), "order": "patrol", "zones": zs})
	_commit("order_add", false)


func _three_zones() -> Array:
	var zs := []
	for it in info.get("zones", []):
		if int(it[0]) != 0 and int(it[0]) != 31 and zs.size() < 3:
			zs.append(int(it[0]))
	while zs.size() < 3:
		zs.append(zs[-1] if not zs.is_empty() else 1)
	return zs


func _remove_order(oi: int) -> void:
	_spec()["orders"].remove_at(oi)
	_commit("order_remove", false)


func _set_order(oi: int, key: String, v: int) -> void:
	_spec()["orders"][oi][key] = v
	_commit("order_" + key, false)


func _set_patrol_zone(oi: int, zi: int, v: int) -> void:
	_spec()["orders"][oi]["zones"][zi] = v
	_commit("order_zone", false)


func _set_order_kind(oi: int, kind: String) -> void:
	var od: Dictionary = _spec()["orders"][oi]
	var nd := {"group": int(od["group"]), "order": kind}
	if od.has("on"):
		nd["on"] = od["on"]
	var zs := _three_zones()
	match kind:
		"patrol":
			nd["zones"] = zs
		"move", "hold_zone":
			nd["zone"] = int(od.get("zone", zs[0]))
		"link":
			nd["target"] = _first(info.get("groups", []), int(od["group"]))
	_spec()["orders"][oi] = nd
	_commit("order_kind", false)


# ---- the end, the debriefing
func _end() -> void:
	_section("END OF THE MISSION")
	var sp := _spec()
	var e = sp.get("end", null)
	var used := []
	for k in 3:
		if not _conds(k).is_empty():
			used.append([k + 1, "objective %d" % (k + 1)])
	var h := HBoxContainer.new()
	var cb := CheckBox.new()
	cb.text = "Ends by itself"
	cb.focus_mode = Control.FOCUS_NONE
	cb.button_pressed = e is Dictionary
	cb.disabled = used.is_empty()
	cb.toggled.connect(func(on):
		if busy:
			return
		if on:
			_spec()["end"] = {"objective": int(used[0][0]), "seconds": 10}
		else:
			_spec().erase("end")
		_commit("end", false))
	h.add_child(cb)
	fields["end_on"] = cb
	if e is Dictionary:
		var s := _spin(0, 3600, int(e.get("seconds", 10)), func(v):
			_spec()["end"]["seconds"] = int(v)
			_commit("end_seconds", true))
		s.suffix = "s"
		h.add_child(s)
		fields["end_seconds"] = s
		h.add_child(_small("after"))
		var oo := _option(_with(used, int(e.get("objective", 1)), "objective %d  (not used)"), int(e.get("objective", 1)), func(v):
			_spec()["end"]["objective"] = int(v)
			_commit("end_objective", false))
		h.add_child(oo)
		fields["end_objective"] = oo
	body.add_child(h)
	if not (e is Dictionary):
		_text("It lasts until the player calls the dropship and boards it at the pickup zone (31).", DIM)


func _debrief() -> void:
	_section("DEBRIEFING  (what the colonel says)")
	var sp := _spec()
	var d = sp.get("debrief", null)
	var texts: Array = d if d is Array and d.size() == 4 else DEFAULT_DEBRIEF.duplicate()
	for i in 4:
		if i < 3 and _conds(i).is_empty():
			continue
		_text(DEBRIEF[i], DIM)
		var le := _line(str(texts[i]), "", 1000, func(t):
			var s2 := _spec()
			if not (s2.get("debrief") is Array) or s2["debrief"].size() != 4:
				s2["debrief"] = DEFAULT_DEBRIEF.duplicate()
			s2["debrief"][i] = t
			_commit("debrief%d" % i, true))
		fields["debrief%d" % i] = le
		body.add_child(le)


# ---- one of the game's own missions
func _game_script() -> void:
	_section("ORDERS AND EVENTS  (the game's own script)")
	fields["orders_said"] = _text("", Color(0.85, 0.88, 0.92))
	for t in info.get("notes", []):
		_text("•  " + str(t), DIM)
	_section("ITS NUMBERS")
	var eds: Array = info.get("edits", [])
	if eds.is_empty():
		_text("This script has no number that can be changed safely.", DIM)
	else:
		_text("This script is the game's own: it can't be rebuilt from blocks here, but each of its numbers can be changed.", DIM)
	for e in eds:
		var h := HBoxContainer.new()
		var l := Label.new()
		l.text = str(e["what"])
		l.add_theme_font_size_override("font_size", 13)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		var id := str(e["id"])
		var s := _spin(int(e["min"]), int(e["max"]), int(e["v"]), func(v): number_changed.emit(id, int(v)))
		s.tooltip_text = "The game's value: %d" % int(e["game"])
		if int(e["v"]) != int(e["game"]):
			s.get_line_edit().add_theme_color_override("font_color", WARN)
		h.add_child(s)
		fields["num:" + id] = s
		body.add_child(h)
	if not eds.is_empty():
		var b := _button("", func(): numbers_reset.emit(), 13)
		fields["numbers_reset"] = b
		body.add_child(b)


# ---- the zones
func _zones(keep: int) -> void:
	_section("ZONES")
	var zl: Array = info.get("zones", [])
	var names := PackedStringArray()
	for it in zl:
		names.append(str(it[1]))
	_text(", ".join(names) if not names.is_empty() else "No zone is placed.", DIM)
	var h := HBoxContainer.new()
	h.add_child(_small("Zone"))
	zone_spin = _spin(0, 127, keep, func(_v): pass)
	h.add_child(zone_spin)
	fields["zone_n"] = zone_spin
	var pl := _button("Place it where I aim", func(): zone_place.emit(int(zone_spin.value)), 13)
	pl.tooltip_text = "Puts this zone's post on the ground at the centre of the view (moves it if it is already placed).\n0: where the squad is dropped, 31: the pickup point; a group's zone events only know zones 0 to 31"
	h.add_child(pl)
	fields["zone_place"] = pl
	var rm := _button("Remove", func(): zone_remove.emit(int(zone_spin.value)), 13)
	h.add_child(rm)
	fields["zone_remove"] = rm
	body.add_child(h)
	_text("Zone posts are moved with the physgun, like units.", DIM)


# ---- the player's own missions (the game's two free slots)
func _mine(keep_like: int, keep_name: String) -> void:
	_section("MY MISSIONS  (the game's two free slots, 18 and 28)")
	var free := 0
	for s in info.get("slots", []):
		var h := HBoxContainer.new()
		var st := str(s["state"])
		var l := _small("Slot %d:  %s" % [int(s["slot"]), "free" if st == "free" else str(s["name"]) if st == "mine"
			else "a file that is not Uplink's (left alone)"])
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		if st == "mine":
			var slot := int(s["slot"])
			if not s.get("open", false):
				var ob := _button("Open", func(): open_pressed.emit(slot), 13)
				h.add_child(ob)
				fields["open%d" % slot] = ob
			var rb := _button("Remove my mission", func(): remove_pressed.emit(slot), 13)
			rb.tooltip_text = "Takes this mission out of the game again: its file, its script, its texts. The game's own files come back as they were."
			h.add_child(rb)
			fields["remove%d" % slot] = rb
		elif st == "free":
			free += 1
		body.add_child(h)
	if free == 0:
		_text("Both slots are in use: remove one of your missions to make another.", DIM)
		return
	var row := HBoxContainer.new()
	row.add_child(_small("Map of"))
	like_opt = OptionButton.new()
	like_opt.focus_mode = Control.FOCUS_NONE
	like_opt.fit_to_longest_item = false
	like_opt.clip_text = true
	like_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for m in info.get("maps", []):
		like_opt.add_item(str(m[1]))
		like_opt.set_item_metadata(like_opt.item_count - 1, str(m[0]))
		if keep_like < 0 and str(m[0]).to_upper() == str(info.get("file", "")).to_upper():
			keep_like = like_opt.item_count - 1
	if like_opt.item_count > 0:
		like_opt.select(clampi(keep_like, 0, like_opt.item_count - 1))
	row.add_child(like_opt)
	fields["new_like"] = like_opt
	body.add_child(row)
	var row2 := HBoxContainer.new()
	name_edit = LineEdit.new()
	name_edit.placeholder_text = "Its name (40 characters at most)"
	name_edit.max_length = 40
	name_edit.text = keep_name
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.text_submitted.connect(func(_t): name_edit.release_focus())
	row2.add_child(name_edit)
	fields["new_name"] = name_edit
	var nb := _button("Create a new mission", func():
		if like_opt.item_count > 0:
			new_pressed.emit(str(like_opt.get_item_metadata(like_opt.selected)), name_edit.text.strip_edges()), 13)
	row2.add_child(nb)
	fields["new_create"] = nb
	body.add_child(row2)
	_text("A new mission takes the map, sky and weather of the mission chosen, with nothing on it: a drop zone (0) and a pickup zone (31) to place, and one objective to start with (destroy every unit labelled 2). No campaign mission is touched.", DIM)


# ---- small parts
func _commit(tag: String, soft: bool) -> void:
	if not busy:
		edited.emit(part.duplicate(true), newp.duplicate(true), tag, soft)


func _section(t: String) -> void:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 4)
	body.add_child(gap)
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Menu.ACCENT.lightened(0.2))
	body.add_child(l)


func _text(t: String, col: Color) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", col)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_child(l)
	return l


func _small(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 14)
	return l


func _button(t: String, on: Callable, size: int) -> Button:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_stylebox_override("normal", Menu._box(Menu.CARD, Menu.CARD, 0, 6, 6))
	b.add_theme_stylebox_override("hover", Menu._box(Menu.CARD.lightened(0.08), Menu.ACCENT, 1, 6, 6))
	b.add_theme_stylebox_override("pressed", Menu._box(Menu.ACCENT.darkened(0.35), Menu.ACCENT, 1, 6, 6))
	b.pressed.connect(func(): if not busy: on.call())
	return b


# items: [[value, text]]; on(value)
func _option(items: Array, cur, on: Callable) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	o.fit_to_longest_item = false
	o.clip_text = true
	o.add_theme_font_size_override("font_size", 14)
	for it in items:
		o.add_item(str(it[1]))
		o.set_item_metadata(o.item_count - 1, it[0])
		if it[0] == cur:
			o.select(o.item_count - 1)
	o.item_selected.connect(func(i): if not busy: on.call(o.get_item_metadata(i)))
	return o


func _spin(lo: int, hi: int, v: int, on: Callable) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.step = 1
	s.value = v
	s.select_all_on_focus = true
	s.add_theme_font_size_override("font_size", 14)
	s.value_changed.connect(func(val): if not busy: on.call(val))
	s.get_line_edit().text_submitted.connect(func(_t): s.get_line_edit().release_focus())
	return s


func _line(t: String, hint: String, max_len: int, on: Callable) -> LineEdit:
	var le := LineEdit.new()
	le.text = t
	le.placeholder_text = hint
	le.max_length = max_len
	le.add_theme_font_size_override("font_size", 14)
	le.text_changed.connect(func(nt): if not busy: on.call(nt))
	le.text_submitted.connect(func(_t): le.release_focus())
	return le
