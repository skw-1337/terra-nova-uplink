# Coop lobby, the guest's side of the game's Mission Outfitting screen. The host's live/coop_lobby.py sends 'GLB' +
# JSON twice a second (through coop_hud.gd): the 4 squad columns (pilot, suit, weapons, ASF), the pilots and their
# status, the items the mission allows and the suits each can go with, and the screen's palette. The guest takes a
# teammate's column (2 to 4), picks its pilot and loadout; each choice goes to the host's bridge as 'L' + JSON on the
# play port (127.0.0.1:47834, online through coop_net.gd), which checks it against the game's rules and writes it:
# the host sees it at once on his own outfitting screen. In a mission, the guest gets that teammate. The host can
# lock the column. Drawn like the game's screen: the pilots' portraits (RESBASE.RES 211, 128 x 128, in the screen's
# palette), blue plates for the AI, red for the players, with both players' Steam names and avatars and the link.
extends CanvasLayer

const LGRes = preload("res://scripts/lgres.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
const PLAY_PORT := 47834
const TIMEOUT := 3.0
const SLOT_NAMES := ["Left arm 1", "Left arm 2", "Right arm 1", "Right arm 2"]
const STATUS_SHORT := ["", "Injured", "Away", "In squad"]
const PORTRAITS := 211               # RESBASE.RES: 33 portraits, by pilot (the names' order, RESGAME 364)

const BG := Color(0.02, 0.035, 0.04, 0.97)
const PANEL := Color(0.05, 0.08, 0.09)
const FRAME := Color(0.24, 0.32, 0.35)
const FRAME_HI := Color(0.95, 0.70, 0.19)
const BLUE := Color(0.11, 0.22, 0.80)
const RED := Color(0.75, 0.12, 0.09)
const AMBER := Color(0.95, 0.70, 0.19)
const TEXT := Color(0.90, 0.93, 0.92)
const DIM := Color(0.50, 0.58, 0.58)
const LED_OK := Color(0.35, 1.0, 0.45)
const LED_WARN := Color(1.0, 0.75, 0.25)
const LED_BAD := Color(1.0, 0.35, 0.3)

var out := PacketPeerUDP.new()
var play_port := PLAY_PORT          # tests: another port
var st := {}
var last := -100.0
var clock := 0.0
var shown := false
var built_sig := ""
var pal := PackedColorArray()
var portraits := {}                 # pilot -> texture (in the palette last received)
var base_res = null
var mate_name := "Host"
var mate_face: Texture2D
var self_name := "You"
var self_face: Texture2D

var root: Control
var title: Label
var info: Label
var link_led: ColorRect
var link_label: Label
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
	root.add_theme_stylebox_override("panel", _box(BG, FRAME, 0))
	add_child(root)
	var m := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, 12)
	root.add_child(m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	m.add_child(v)
	# top bar: the screen's title, the link to the host
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", _box(Color(0, 0, 0), FRAME, 2, 6))
	v.add_child(bar)
	var bh := HBoxContainer.new()
	bar.add_child(bh)
	title = _label("M I S S I O N   O U T F I T T I N G", 20, TEXT)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(title)
	var link := HBoxContainer.new()
	link.add_theme_constant_override("separation", 8)
	bh.add_child(link)
	link_led = ColorRect.new()
	link_led.custom_minimum_size = Vector2(12, 12)
	link_led.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	link.add_child(link_led)
	link_label = _label("", 15, DIM)
	link.add_child(link_label)
	var room := Control.new()
	room.custom_minimum_size = Vector2(90, 0)     # the window's fps counter, top right
	link.add_child(room)
	info = _label("", 15, AMBER)
	v.add_child(info)
	cols_box = HBoxContainer.new()
	cols_box.add_theme_constant_override("separation", 10)
	v.add_child(cols_box)
	# the picker: pilots on the left, loadout on the right
	picker = HBoxContainer.new()
	picker.add_theme_constant_override("separation", 12)
	picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(picker)
	var pp := PanelContainer.new()
	pp.add_theme_stylebox_override("panel", _box(PANEL, FRAME, 2, 8))
	pp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_child(pp)
	var pv := VBoxContainer.new()
	pp.add_child(pv)
	pv.add_child(_label("REVIEW PERSONNEL", 14, AMBER))
	pilots_list = ItemList.new()
	pilots_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pilots_list.fixed_icon_size = Vector2i(26, 26)
	pilots_list.max_columns = 2
	pilots_list.fixed_column_width = 270
	pilots_list.add_theme_stylebox_override("panel", _box(Color(0, 0, 0), FRAME, 1, 4))
	pilots_list.add_theme_color_override("font_color", TEXT)
	pilots_list.add_theme_color_override("font_disabled_color", DIM)
	pilots_list.item_selected.connect(_on_pilot)
	pv.add_child(pilots_list)
	var lp := PanelContainer.new()
	lp.add_theme_stylebox_override("panel", _box(PANEL, FRAME, 2, 8))
	lp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.add_child(lp)
	var lvb := VBoxContainer.new()
	lp.add_child(lvb)
	lvb.add_child(_label("LOADOUT", 14, AMBER))
	var lv := GridContainer.new()
	lv.columns = 2
	lv.add_theme_constant_override("h_separation", 10)
	lv.add_theme_constant_override("v_separation", 4)
	lvb.add_child(lv)
	lv.add_child(_label("Suit Type", 15, DIM))
	suit_opt = _option()
	suit_opt.item_selected.connect(func(i): _send_item("suit", suit_opt, i))
	lv.add_child(suit_opt)
	for k in 4:
		lv.add_child(_label(SLOT_NAMES[k], 15, DIM))
		var o := _option()
		o.item_selected.connect(func(i): _on_weapon(k, i))
		slot_opts.append(o)
		lv.add_child(o)
	lv.add_child(_label("A.S.F.", 15, DIM))
	asf_opt = _option()
	asf_opt.item_selected.connect(func(i): _send_item("asf", asf_opt, i))
	lv.add_child(asf_opt)
	lv.add_child(Control.new())
	asf_note = _label("", 13, DIM)
	lv.add_child(asf_note)
	root.visible = false


# ---- look
func _box(bg: Color, border: Color, width: int, pad: int = 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_content_margin_all(pad)
	return sb


func _label(t: String, size: int = 15, col: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _plate(t: String, col: Color, size: int = 13) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(col, col.lightened(0.25), 1, 1))
	var l := _label(t, size, Color.WHITE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.clip_text = true
	p.add_child(l)
	return p


func _option() -> OptionButton:
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(260, 0)
	o.add_theme_stylebox_override("normal", _box(BLUE, BLUE.lightened(0.25), 1, 4))
	o.add_theme_stylebox_override("hover", _box(BLUE.lightened(0.12), AMBER, 1, 4))
	o.add_theme_stylebox_override("pressed", _box(BLUE.darkened(0.2), AMBER, 1, 4))
	o.add_theme_stylebox_override("disabled", _box(Color(0.12, 0.15, 0.2), FRAME, 1, 4))
	o.add_theme_color_override("font_color", Color.WHITE)
	o.add_theme_color_override("font_disabled_color", DIM)
	return o


func _button(t: String, col: Color) -> Button:
	var b := Button.new()
	b.text = t
	b.add_theme_stylebox_override("normal", _box(col.darkened(0.35), col, 2, 4))
	b.add_theme_stylebox_override("hover", _box(col.darkened(0.15), AMBER, 2, 4))
	b.add_theme_stylebox_override("pressed", _box(col.darkened(0.5), AMBER, 2, 4))
	b.add_theme_color_override("font_color", Color.WHITE)
	return b


# ---- the players' Steam names and faces (coop_hud.gd <- coop_net.gd), the portraits
func set_mate(mate: String, face: Image) -> void:
	mate_name = mate
	if face:
		mate_face = ImageTexture.create_from_image(face)
	built_sig = ""


func set_self(me: String, face: Image) -> void:
	self_name = me
	if face:
		self_face = ImageTexture.create_from_image(face)
	built_sig = ""


func _portrait(pilot: int) -> Texture2D:
	if pal.is_empty() or pilot < 0 or pilot >= 33:
		return null
	if portraits.has(pilot):
		return portraits[pilot]
	var tex: Texture2D = null
	if base_res == null:
		var vp := get_parent().get_parent() if get_parent() else null
		if vp and "data" in vp:
			base_res = LGRes.open(vp.data.data_dir().path_join("RESBASE.RES"))
	if base_res and base_res.has(PORTRAITS):
		var fr: Array = LGRes.frames(base_res.data(PORTRAITS))
		if pilot < fr.size():
			var img: Image = TNObjects._bitmap(fr[pilot], pal)
			if img:
				tex = ImageTexture.create_from_image(img)
	portraits[pilot] = tex
	return tex


func _link() -> Node:
	var vp := get_parent().get_parent() if get_parent() else null
	if vp:
		for n in vp.get_children():
			if "ping_ms" in n and "peer" in n:
				return n
	return null


# ---- packets
# from coop_hud.gd: a 'GLB' packet
func feed(pk: PackedByteArray) -> void:
	var j = JSON.parse_string(pk.slice(3).get_string_from_utf8())
	if typeof(j) != TYPE_DICTIONARY:
		return
	if j.has("pal"):
		var raw := Marshalls.base64_to_raw(str(j["pal"]))
		if raw.size() == 768:
			var p := PackedColorArray()
			p.resize(256)
			for i in 256:
				p[i] = Color8(raw[3 * i], raw[3 * i + 1], raw[3 * i + 2])
			if p != pal:
				pal = p
				portraits.clear()
				built_sig = ""
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
	if shown:
		var n := _link()
		if n == null or not n.steam:
			link_led.color = LED_OK
			link_label.text = "LOCAL LINK"
		elif int(n.peer) == 0:
			link_led.color = LED_BAD if fmod(clock, 1.0) < 0.5 else Color(0.2, 0.05, 0.05)
			link_label.text = "NO LINK"
		else:
			var ms := int(n.ping_ms)
			link_led.color = LED_OK if ms >= 0 and ms < 100 else LED_WARN if ms >= 0 and ms < 200 else LED_BAD
			link_label.text = "LINK  %s  ·  %s" % ["%d ms" % ms if ms >= 0 else "...", mate_name]


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
	if not st.get("outfit", false):
		info.text = "Waiting for the host's Mission Outfitting screen.  You can already take a column."
	elif col and locked:
		info.text = "Column %d is yours.  The host has locked it." % (col + 1)
	elif col:
		info.text = "Column %d is yours.  The host sees your choices on his screen.  Outfit Complete is his." % (col + 1)
	else:
		info.text = "Take a teammate's column: you play him in the mission."
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
	var player := i == 0 or i == mine
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_theme_stylebox_override("panel", _box(PANEL, FRAME_HI if i == mine else FRAME, 2, 6))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	p.add_child(v)
	# the portrait, its specialty under it as in the game
	var pic := TextureRect.new()
	pic.custom_minimum_size = Vector2(0, 80)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.texture = _portrait(int(c.get("pilot", -1)))
	v.add_child(pic)
	var spec := _label(str(c.get("spec", "")), 13, DIM)
	spec.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(spec)
	v.add_child(_plate(str(c.get("name", "?")), RED if player else BLUE, 14))
	# who plays it: the host's and the guest's Steam names and faces
	var who := HBoxContainer.new()
	who.add_theme_constant_override("separation", 6)
	who.alignment = BoxContainer.ALIGNMENT_CENTER
	var face: Texture2D = mate_face if i == 0 else self_face if i == mine else null
	if face:
		var av := TextureRect.new()
		av.custom_minimum_size = Vector2(36, 24)
		av.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		av.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		av.texture = face
		who.add_child(av)
	who.add_child(_label(mate_name if i == 0 else self_name if i == mine else "AI squadmate", 13,
		AMBER if player else DIM))
	v.add_child(who)
	v.add_child(_plate(_suit_name(int(c.get("suit", 0))), BLUE))
	var w: Array = c.get("w", [0, 0, 0, 0])
	for arm in [0, 2]:
		v.add_child(_plate(_weapon_name(int(w[arm])), BLUE))
		if not (int(w[arm + 1]) == 0 and int(w[arm]) != 0):       # a two-slot weapon: one plate for the arm
			v.add_child(_plate(_weapon_name(int(w[arm + 1])), BLUE))
	var asf := int(c.get("asf", 0))
	v.add_child(_plate(_asf_name(asf), RED if asf < 2 else BLUE))
	if i > 0 and i != mine and not (locked and mine > 0):
		var b := _button("TAKE THIS COLUMN", BLUE)
		b.pressed.connect(func(): _send({"act": "join", "col": i}))
		v.add_child(b)
	elif i == mine and not locked:
		var b := _button("LEAVE", RED)
		b.pressed.connect(func(): _send({"act": "leave"}))
		v.add_child(b)
	return p


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
		var idx := pilots_list.add_item("%s  ·  %s%s" % [p["name"], p["spec"], "" if free else "  ·  " + STATUS_SHORT[clampi(int(p["status"]), 0, 3)]], _portrait(int(p["id"])))
		pilots_list.set_item_metadata(idx, int(p["row"]))
		pilots_list.set_item_disabled(idx, not free or locked)
		if p["name"] == c.get("name", ""):
			pilots_list.set_item_custom_fg_color(idx, AMBER)
		elif int(p["status"]) == 1:
			pilots_list.set_item_custom_fg_color(idx, LED_BAD.darkened(0.2))
		elif int(p["status"]) == 2:
			pilots_list.set_item_custom_fg_color(idx, LED_WARN.darkened(0.3))
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
