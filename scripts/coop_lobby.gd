# Coop lobby, the guest's side of the game's Mission Outfitting screen. The host's live/coop_lobby.py sends 'GLB' +
# JSON twice a second (through coop_hud.gd): the 4 squad columns (pilot, suit, weapons, ASF), the pilots and their
# status, the items the mission allows and the suits each can go with. The guest takes a teammate's column (2 to 4),
# picks its pilot and loadout; each choice goes to the host's bridge as 'L' + JSON on the play port (127.0.0.1:47834,
# online through coop_net.gd), which checks it against the game's rules and writes it: the host sees it at once on
# his own outfitting screen. In a mission, the guest gets that teammate. The host can lock the column.
extends CanvasLayer

const PLAY_PORT := 47834
const TIMEOUT := 3.0
const SLOT_NAMES := ["Left arm 1", "Left arm 2", "Right arm 1", "Right arm 2"]

var out := PacketPeerUDP.new()
var play_port := PLAY_PORT          # tests: another port
var st := {}
var last := -100.0
var clock := 0.0
var shown := false
var built_sig := ""

var root: Control
var title: Label
var info: Label
var cols_box: HBoxContainer
var picker: HBoxContainer
var pilots_list: ItemList
var suit_opt: OptionButton
var slot_opts := []
var asf_opt: OptionButton
var asf_note: Label
var busy := false                      # filling the controls: their signals are not choices


func _ready() -> void:
	layer = 20
	out.set_dest_address("127.0.0.1", play_port)
	root = PanelContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.05, 0.09, 0.09, 0.94)
	root.add_theme_stylebox_override("panel", sb)
	add_child(root)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 18)
	root.add_child(m)
	m.add_child(v)
	title = Label.new()
	title.add_theme_font_size_override("font_size", 22)
	v.add_child(title)
	info = Label.new()
	info.modulate = Color(0.75, 0.85, 0.8)
	v.add_child(info)
	cols_box = HBoxContainer.new()
	cols_box.add_theme_constant_override("separation", 8)
	v.add_child(cols_box)
	picker = HBoxContainer.new()
	picker.add_theme_constant_override("separation", 14)
	picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(picker)
	var pv := VBoxContainer.new()
	pv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_child(pv)
	pv.add_child(_label("Pilot (click an available one)"))
	pilots_list = ItemList.new()
	pilots_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pilots_list.item_selected.connect(_on_pilot)
	pv.add_child(pilots_list)
	var lv := GridContainer.new()
	lv.columns = 2
	lv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_child(lv)
	lv.add_child(_label("Suit"))
	suit_opt = OptionButton.new()
	suit_opt.item_selected.connect(func(i): _send_item("suit", suit_opt, i))
	lv.add_child(suit_opt)
	for k in 4:
		lv.add_child(_label(SLOT_NAMES[k]))
		var o := OptionButton.new()
		o.item_selected.connect(func(i): _on_weapon(k, i))
		slot_opts.append(o)
		lv.add_child(o)
	lv.add_child(_label("ASF"))
	asf_opt = OptionButton.new()
	asf_opt.item_selected.connect(func(i): _send_item("asf", asf_opt, i))
	lv.add_child(asf_opt)
	lv.add_child(Control.new())
	asf_note = _label("")
	asf_note.modulate = Color(0.7, 0.75, 0.72)
	lv.add_child(asf_note)
	root.visible = false


func _label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	return l


# from coop_hud.gd: a 'GLB' packet
func feed(pk: PackedByteArray) -> void:
	var j = JSON.parse_string(pk.slice(3).get_string_from_utf8())
	if typeof(j) != TYPE_DICTIONARY:
		return
	st = j
	last = clock
	_refresh()


func _process(delta: float) -> void:
	clock += delta
	var want: bool = not st.is_empty() and clock - last < TIMEOUT and not bool(st.get("mission", false))
	if want != shown:
		shown = want
		root.visible = want
		if want:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _send(msg: Dictionary) -> void:
	out.put_packet(("L" + JSON.stringify(msg)).to_utf8_buffer())


func _refresh() -> void:
	# twice a second the same state: rebuilt only when it changed (else an open drop-down would close)
	var sig := JSON.stringify([st.get("cols"), st.get("col"), st.get("locked"), st.get("outfit"), st.get("pilots"),
		st.get("suits"), st.get("weapons"), st.get("asf")])
	if sig == built_sig:
		return
	built_sig = sig
	busy = true
	var col := int(st.get("col", 0))
	var locked: bool = st.get("locked", false)
	title.text = "Mission outfitting" + ("  -  your column is locked by the host" if locked and col else "")
	if not st.get("outfit", false):
		info.text = "The host is not on the Mission Outfitting screen yet: you can still take a column."
	elif col:
		info.text = "Column %d is yours. The host sees your choices on his screen. Outfit Complete is his." % (col + 1)
	else:
		info.text = "Take a teammate's column to play him in the mission."
	for c in cols_box.get_children():
		c.queue_free()
	var cols: Array = st.get("cols", [])
	for i in cols.size():
		cols_box.add_child(_column_card(i, cols[i], col if col > 0 else -1, locked))   # -1: none taken yet
	picker.visible = col > 0
	if col > 0 and col < cols.size():
		_fill_picker(cols[col], locked)
	busy = false


func _column_card(i: int, c: Dictionary, mine: int, locked: bool) -> Control:
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.16, 0.16)
	sb.set_border_width_all(2 if i == mine else 1)
	sb.border_color = Color(0.95, 0.7, 0.2) if i == mine else Color(0.25, 0.35, 0.33)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", sb)
	var v := VBoxContainer.new()
	p.add_child(v)
	var who: String = "Host" if i == 0 else ("You" if i == mine else "AI")
	var head := _label("Column %d - %s" % [i + 1, who])
	head.modulate = Color(0.95, 0.75, 0.3) if i == mine else Color(0.7, 0.8, 0.78)
	v.add_child(head)
	var name := _label("%s  (%s)" % [c.get("name", "?"), c.get("spec", "")])
	v.add_child(name)
	v.add_child(_label(_suit_name(int(c.get("suit", 0)))))
	var w: Array = c.get("w", [0, 0, 0, 0])
	v.add_child(_label(_arm(w[0], w[1])))
	v.add_child(_label(_arm(w[2], w[3])))
	v.add_child(_label(_asf_name(int(c.get("asf", 0)))))
	if i > 0 and i != mine and not (locked and mine):
		var b := Button.new()
		b.text = "Take this column"
		b.pressed.connect(func(): _send({"act": "join", "col": i}))
		v.add_child(b)
	elif i == mine and not locked:
		var b := Button.new()
		b.text = "Leave"
		b.pressed.connect(func(): _send({"act": "leave"}))
		v.add_child(b)
	return p


func _arm(a, b) -> String:
	if int(b) == 0:
		return _weapon_name(int(a)) + " (both slots)"
	return _weapon_name(int(a)) + " / " + _weapon_name(int(b))


func _weapon_name(id: int) -> String:
	for w in st.get("weapons", []):
		if int(w[0]) == id:
			return w[1]
	return "-" if id == 0 else "#%d" % id


func _suit_name(id: int) -> String:
	for s in st.get("suits", []):
		if int(s[0]) == id:
			return s[1]
	return "Suit %d" % id


func _asf_name(id: int) -> String:
	if id == 0:
		return st.get("fixed_asf", {}).get("Demolitions", "Demolition Pack")
	if id == 1:
		return st.get("fixed_asf", {}).get("Repair", "PBA Repair Pack")
	for a in st.get("asf", []):
		if int(a[0]) == id:
			return a[1]
	return "#%d" % id


func _fill_picker(c: Dictionary, locked: bool) -> void:
	pilots_list.clear()
	for p in st.get("pilots", []):
		var free: bool = int(p["status"]) == 0
		var idx := pilots_list.add_item("%s  -  %s  -  %s" % [p["name"], p["spec"], p["status_name"]])
		pilots_list.set_item_metadata(idx, int(p["row"]))
		pilots_list.set_item_disabled(idx, not free or locked)
		if p["name"] == c.get("name", ""):
			pilots_list.set_item_custom_fg_color(idx, Color(0.95, 0.75, 0.3))
	var suit := int(c.get("suit", 0))
	suit_opt.clear()
	for s in st.get("suits", []):
		suit_opt.add_item(s[1], int(s[0]))
		if int(s[0]) == suit:
			suit_opt.select(suit_opt.item_count - 1)
	suit_opt.disabled = locked
	var w: Array = c.get("w", [0, 0, 0, 0])
	for k in 4:
		var o: OptionButton = slot_opts[k]
		o.clear()
		var arm := k / 2 * 2
		var both: bool = int(w[arm + 1]) == 0 and int(w[arm]) != 0
		for it in st.get("weapons", []):
			var id := int(it[0])
			if (int(it[2]) >> suit) & 1 == 0 or (int(it[3]) == 1 and suit == 0):
				continue                            # not with this suit
			o.add_item(it[1] + (" (both slots)" if int(it[3]) == 1 else ""), id)
			if id == int(w[arm if both else k]):
				o.select(o.item_count - 1)
		o.disabled = locked or (both and k == arm + 1)
	var fixed: bool = int(c.get("asf", 0)) < 2
	asf_opt.clear()
	if fixed:
		asf_opt.add_item(_asf_name(int(c.get("asf", 0))), int(c.get("asf", 0)))
		asf_note.text = "Comes with the pilot's specialty"
	else:
		asf_note.text = ""
		for a in st.get("asf", []):
			if (int(a[2]) >> suit) & 1 == 0:
				continue
			asf_opt.add_item(a[1], int(a[0]))
			if int(a[0]) == int(c.get("asf", 0)):
				asf_opt.select(asf_opt.item_count - 1)
	asf_opt.disabled = locked or fixed


func _on_pilot(i: int) -> void:
	if busy:
		return
	_send({"act": "pilot", "row": int(pilots_list.get_item_metadata(i))})


func _on_weapon(k: int, i: int) -> void:
	if busy:
		return
	_send({"act": "weapon", "slot": k, "id": slot_opts[k].get_item_id(i)})


func _send_item(act: String, o: OptionButton, i: int) -> void:
	if busy:
		return
	_send({"act": act, "id": o.get_item_id(i)})
