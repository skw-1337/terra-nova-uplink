# Coop lobby, the guest's side of the game's Mission Outfitting screen. The host's live/coop_lobby.py sends 'GLB' +
# JSON twice a second (through coop_hud.gd): the 4 squad columns (pilot, suit, weapons, ASF), the pilots and their
# status, the items the mission allows (with the game's spec lines) and the suits each can go with, the screen's
# palette, the operation's name and note, its mission file, the column the host clicked last, ready and the chat.
# The guest takes a teammate's column (2 to 4), picks its pilot and loadout; each choice goes to the host's bridge
# as 'L' + JSON on the play port (127.0.0.1:47834, online through coop_net.gd), which checks it against the game's
# rules and writes it: the host sees it at once on his own outfitting screen, with the guest's Steam name and face
# on that column. In a mission, the guest gets that teammate. The host can lock the column.
# Drawn like the game's screen: the pilots' portraits (RESBASE.RES 211, 128 x 128, in the screen's palette), blue
# plates for the AI, red for the players, both players' Steam names and avatars, the link; the game's menu sounds
# (RESSOUND.RES 1937 open, 1927 pick); a briefing panel with the mission's map from above; 3 saved loadouts.
extends CanvasLayer

const LGRes = preload("res://scripts/lgres.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
const PLAY_PORT := 47834
const TIMEOUT := 3.0
const SLOT_NAMES := ["Left arm 1", "Left arm 2", "Right arm 1", "Right arm 2"]
const STATUS_SHORT := ["", "Injured", "Away", "In squad"]
const PORTRAITS := 211               # RESBASE.RES: 33 portraits, by pilot (the names' order, RESGAME 364)
const SND_OPEN := 1937               # RESSOUND.RES: the outfitting screen's sounds (0x2B9A4B, 0x2B98E1)
const SND_PICK := 1927
const LOADOUTS := "user://coop_loadouts.json"

const BG := Color(0.02, 0.035, 0.04, 0.97)
const PANEL := Color(0.05, 0.08, 0.09)
const FRAME := Color(0.24, 0.32, 0.35)
const FRAME_HI := Color(0.95, 0.70, 0.19)
const BLUE := Color(0.11, 0.22, 0.80)
const RED := Color(0.75, 0.12, 0.09)
const GREEN := Color(0.10, 0.55, 0.22)
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
var chat_seen := -1
var pal := PackedColorArray()
var portraits := {}                 # pilot -> texture (in the palette last received)
var base_res = null
var sound_res = null
var sounds := {}
var player: AudioStreamPlayer
var mate_name := "Host"
var mate_face: Texture2D
var self_name := "You"
var self_face: Texture2D
var msn_asked := ""

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
var spec_label: Label
var ready_btn: Button
var save_btns := []
var load_btns := []
var brief_title: Label
var note_label: Label
var chat_log: Label
var chat_edit: LineEdit
var map_view: SubViewport
var map_cam: Camera3D
var map_rect: TextureRect
var busy := false                      # filling the controls: their signals are not choices


func _ready() -> void:
	layer = 20
	out.set_dest_address("127.0.0.1", play_port)
	player = AudioStreamPlayer.new()
	player.volume_db = -6.0
	add_child(player)
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
	# top bar: the screen's title and the operation, the link to the host
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
	room.custom_minimum_size = Vector2(90, 0)       # the window's fps counter, top right
	link.add_child(room)
	info = _label("", 15, AMBER)
	v.add_child(info)
	cols_box = HBoxContainer.new()
	cols_box.add_theme_constant_override("separation", 10)
	v.add_child(cols_box)
	# under the columns: personnel, loadout, briefing
	picker = HBoxContainer.new()
	picker.add_theme_constant_override("separation", 10)
	picker.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(picker)
	_build_personnel()
	_build_loadout()
	_build_briefing()
	root.visible = false


func _panel(t: String, stretch: float) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(PANEL, FRAME, 2, 8))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.size_flags_stretch_ratio = stretch
	picker.add_child(p)
	var pv := VBoxContainer.new()
	pv.add_theme_constant_override("separation", 4)
	p.add_child(pv)
	pv.add_child(_label(t, 14, AMBER))
	return pv


func _build_personnel() -> void:
	var pv := _panel("REVIEW PERSONNEL", 1.0)
	pilots_list = ItemList.new()
	pilots_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pilots_list.fixed_icon_size = Vector2i(24, 24)
	pilots_list.add_theme_stylebox_override("panel", _box(Color(0, 0, 0), FRAME, 1, 4))
	pilots_list.add_theme_color_override("font_color", TEXT)
	pilots_list.add_theme_color_override("font_disabled_color", DIM)
	pilots_list.add_theme_font_size_override("font_size", 14)
	pilots_list.item_selected.connect(_on_pilot)
	pv.add_child(pilots_list)


func _build_loadout() -> void:
	var lvb := _panel("LOADOUT", 1.2)
	var lv := GridContainer.new()
	lv.columns = 2
	lv.add_theme_constant_override("h_separation", 8)
	lv.add_theme_constant_override("v_separation", 2)
	lvb.add_child(lv)
	lv.add_child(_label("Suit", 14, DIM))
	suit_opt = _option()
	suit_opt.item_selected.connect(func(i): _send_item("suit", suit_opt, i))
	lv.add_child(suit_opt)
	for k in 4:
		lv.add_child(_label(SLOT_NAMES[k], 14, DIM))
		var o := _option()
		o.item_selected.connect(func(i): _on_weapon(k, i))
		slot_opts.append(o)
		lv.add_child(o)
	lv.add_child(_label("A.S.F.", 14, DIM))
	asf_opt = _option()
	asf_opt.item_selected.connect(func(i): _send_item("asf", asf_opt, i))
	lv.add_child(asf_opt)
	asf_note = _label("", 11, DIM)
	lvb.add_child(asf_note)
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spec_label = _label("", 11, Color(0.72, 0.8, 0.78))
	spec_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lvb.add_child(spec_label)
	lvb.add_child(gap)
	var fav := HBoxContainer.new()
	fav.add_theme_constant_override("separation", 4)
	lvb.add_child(fav)
	fav.add_child(_label("Saved", 13, DIM))
	for n in 3:
		var sb := _small_button("SAVE %d" % (n + 1))
		sb.pressed.connect(_save_loadout.bind(n))
		save_btns.append(sb)
		fav.add_child(sb)
	for n in 3:
		var lb := _small_button("LOAD %d" % (n + 1))
		lb.pressed.connect(_load_loadout.bind(n))
		load_btns.append(lb)
		fav.add_child(lb)
	ready_btn = _button("READY", GREEN)
	ready_btn.toggle_mode = true
	ready_btn.toggled.connect(_on_ready)
	lvb.add_child(ready_btn)


func _build_briefing() -> void:
	var bv := _panel("BRIEFING", 1.3)
	brief_title = _label("", 15, TEXT)
	bv.add_child(brief_title)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	bv.add_child(row)
	map_view = SubViewport.new()
	map_view.size = Vector2i(120, 120)
	map_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(map_view)
	map_cam = Camera3D.new()
	map_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	map_cam.size = 360.0
	map_cam.far = 4000.0
	map_view.add_child(map_cam)
	var mf := PanelContainer.new()
	mf.add_theme_stylebox_override("panel", _box(Color(0, 0, 0), FRAME, 1, 1))
	row.add_child(mf)
	map_rect = TextureRect.new()
	map_rect.custom_minimum_size = Vector2(120, 120)
	map_rect.texture = map_view.get_texture()
	map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mf.add_child(map_rect)
	note_label = _label("", 11, Color(0.75, 0.82, 0.8))
	note_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_label.custom_minimum_size = Vector2(140, 0)
	row.add_child(note_label)
	bv.add_child(_label("CHAT", 13, AMBER))
	chat_log = _label("", 13, TEXT)
	chat_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	chat_log.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	chat_log.clip_text = true
	bv.add_child(chat_log)
	chat_edit = LineEdit.new()
	chat_edit.placeholder_text = "Message to the host (Enter)"
	chat_edit.max_length = 120
	chat_edit.add_theme_stylebox_override("normal", _box(Color(0, 0, 0), FRAME, 1, 4))
	chat_edit.text_submitted.connect(_on_chat)
	bv.add_child(chat_edit)


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


func _plate(t: String, col: Color, size: int = 12) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _box(col, col.lightened(0.25), 1, 1))
	var l := _label(t, size, Color.WHITE)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.clip_text = true
	p.add_child(l)
	return p


func _option() -> OptionButton:
	var o := OptionButton.new()
	o.custom_minimum_size = Vector2(190, 0)
	o.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	o.add_theme_font_size_override("font_size", 13)
	o.add_theme_stylebox_override("normal", _box(BLUE, BLUE.lightened(0.25), 1, 2))
	o.add_theme_stylebox_override("hover", _box(BLUE.lightened(0.12), AMBER, 1, 3))
	o.add_theme_stylebox_override("pressed", _box(BLUE.darkened(0.2), AMBER, 1, 3))
	o.add_theme_stylebox_override("disabled", _box(Color(0.12, 0.15, 0.2), FRAME, 1, 3))
	o.add_theme_color_override("font_color", Color.WHITE)
	o.add_theme_color_override("font_disabled_color", DIM)
	o.pressed.connect(func(): _sound(SND_OPEN))
	return o


func _button(t: String, col: Color) -> Button:
	var b := Button.new()
	b.text = t
	b.add_theme_stylebox_override("normal", _box(col.darkened(0.35), col, 2, 4))
	b.add_theme_stylebox_override("hover", _box(col.darkened(0.15), AMBER, 2, 4))
	b.add_theme_stylebox_override("pressed", _box(col.lightened(0.1), AMBER, 2, 4))
	b.add_theme_stylebox_override("disabled", _box(Color(0.1, 0.12, 0.13), FRAME, 2, 4))
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	return b


func _small_button(t: String) -> Button:
	var b := _button(t, FRAME)
	b.add_theme_font_size_override("font_size", 12)
	return b


# ---- sounds (the game's VOC files: 8-bit unsigned PCM blocks)
func _sound(id: int) -> void:
	if not sounds.has(id):
		sounds[id] = _voc(id)
	if sounds[id]:
		player.stream = sounds[id]
		player.play()


func _voc(id: int) -> AudioStreamWAV:
	if sound_res == null:
		var vp := _viewer()
		if vp and "data" in vp:
			sound_res = LGRes.open(vp.data.data_dir().path_join("RESSOUND.RES"))
	if sound_res == null or not sound_res.has(id):
		return null
	var d: PackedByteArray = sound_res.data(id)
	if d.size() < 0x20 or d.slice(0, 19).get_string_from_ascii() != "Creative Voice File":
		return null
	var p := d.decode_u16(0x14)
	var pcm := PackedByteArray()
	var rate := 11025
	while p + 4 <= d.size():
		var typ := d[p]
		if typ == 0:
			break
		var n := d[p + 1] | (d[p + 2] << 8) | (d[p + 3] << 16)
		if typ == 1 and n > 2:
			rate = int(1000000.0 / (256 - d[p + 4]))
			pcm.append_array(d.slice(p + 6, p + 4 + n))
		elif typ == 2:
			pcm.append_array(d.slice(p + 4, p + 4 + n))
		p += 4 + n
	for i in pcm.size():
		pcm[i] = (pcm[i] - 128) & 0xFF                # unsigned -> signed
	var s := AudioStreamWAV.new()
	s.format = AudioStreamWAV.FORMAT_8_BITS
	s.mix_rate = rate
	s.data = pcm
	return s


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


func _viewer() -> Node:
	return get_parent().get_parent() if get_parent() else null


func _portrait(pilot: int) -> Texture2D:
	if pal.is_empty() or pilot < 0 or pilot >= 33:
		return null
	if portraits.has(pilot):
		return portraits[pilot]
	var tex: Texture2D = null
	if base_res == null:
		var vp := _viewer()
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
	var vp := _viewer()
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
	_chat_refresh()
	_mission_map()


func _process(delta: float) -> void:
	clock += delta
	var want: bool = not st.is_empty() and clock - last < TIMEOUT and not bool(st.get("mission", false))
	if want != shown:
		shown = want
		root.visible = want
		if want:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if not shown:
		return
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
	_map_aim()


func _send(msg: Dictionary) -> void:
	out.put_packet(("L" + JSON.stringify(msg)).to_utf8_buffer())


func _refresh() -> void:
	# twice a second the same state: rebuilt only when it changed (else an open drop-down would close)
	var sig := JSON.stringify([st.get("cols"), st.get("col"), st.get("locked"), st.get("outfit"), st.get("pilots"),
		st.get("suits"), st.get("weapons"), st.get("asf"), st.get("ready"), st.get("host_col"), st.get("op")])
	if sig == built_sig:
		return
	built_sig = sig
	busy = true
	var col := int(st.get("col", 0))
	var locked: bool = st.get("locked", false)
	var op := str(st.get("op", ""))
	title.text = "M I S S I O N   O U T F I T T I N G" + ("     " + op if op != "" else "")
	brief_title.text = op
	note_label.text = " ".join(str(st.get("note", "")).split("\n"))   # the game's line breaks: one paragraph
	if not st.get("outfit", false):
		info.text = "Waiting for the host's Mission Outfitting screen.  You can already take a column."
	elif col and locked:
		info.text = "Column %d is yours.  The host has locked it." % (col + 1)
	elif col:
		info.text = "Column %d is yours.  The host sees your name and choices on his screen.  Outfit Complete is his." % (col + 1)
	else:
		info.text = "Take a teammate's column: you play him in the mission."
	for c in cols_box.get_children():
		c.queue_free()
	var cols: Array = st.get("cols", [])
	var host_col: int = int(st.get("host_col", -1)) if st.get("outfit", false) else -1
	for i in cols.size():
		if not int(cols[i].get("on", 1)):                # a slot this mission doesn't have (3-man squads)
			continue
		cols_box.add_child(_column_card(i, cols[i], col if col > 0 else -1, locked, i == host_col))   # -1: none taken
	picker.visible = true
	_fill_picker(cols[col] if col > 0 and col < cols.size() else {}, locked, col > 0)
	busy = false


func _column_card(i: int, c: Dictionary, mine: int, locked: bool, editing: bool) -> Control:
	var player := i == 0 or i == mine
	var p := PanelContainer.new()
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	p.add_theme_stylebox_override("panel", _box(PANEL, FRAME_HI if i == mine else FRAME, 2, 6))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 1)
	p.add_child(v)
	# the portrait, its specialty under it as in the game; the column the host is on
	var top := Control.new()
	top.custom_minimum_size = Vector2(0, 64)
	v.add_child(top)
	var pic := TextureRect.new()
	pic.set_anchors_preset(Control.PRESET_FULL_RECT)
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	pic.texture = _portrait(int(c.get("pilot", -1)))
	top.add_child(pic)
	if editing:
		var tag := _plate("HOST EDITING", AMBER.darkened(0.3), 11)
		tag.position = Vector2(4, 4)
		tag.size = Vector2(96, 18)
		top.add_child(tag)
	if i == mine and st.get("ready", false):
		var rd := _plate("READY", GREEN, 11)
		rd.anchor_left = 1.0
		rd.anchor_right = 1.0
		rd.offset_left = -60
		rd.offset_right = -4
		rd.offset_top = 4
		rd.offset_bottom = 22
		top.add_child(rd)
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
		b.pressed.connect(func(): _sound(SND_PICK); _send({"act": "join", "col": i}))
		v.add_child(b)
	elif i == mine and not locked:
		var b := _button("LEAVE", RED)
		b.pressed.connect(func(): _sound(SND_OPEN); _send({"act": "leave"}))
		v.add_child(b)
	return p


func _item(list: String, id: int) -> Array:
	for it in st.get(list, []):
		if int(it[0]) == id:
			return it
	return []


func _weapon_name(id: int) -> String:
	var it := _item("weapons", id)
	return it[1] if it.size() > 1 else ("-" if id == 0 else "#%d" % id)


func _suit_name(id: int) -> String:
	var it := _item("suits", id)
	return it[1] if it.size() > 1 else "Suit %d" % id


func _asf_name(id: int) -> String:
	if id == 0:
		return st.get("fixed_asf", {}).get("Demolitions", "Demolition Pack")
	if id == 1:
		return st.get("fixed_asf", {}).get("Repair", "PBA Repair Pack")
	var it := _item("asf", id)
	return it[1] if it.size() > 1 else "#%d" % id


func _fill_picker(c: Dictionary, locked: bool, mine: bool) -> void:
	pilots_list.clear()
	for p in st.get("pilots", []):
		var free: bool = int(p["status"]) == 0
		var idx := pilots_list.add_item("%s  ·  %s%s" % [p["name"], p["spec"], "" if free else "  ·  " + STATUS_SHORT[clampi(int(p["status"]), 0, 3)]],
			_portrait(int(p["id"])))
		pilots_list.set_item_metadata(idx, int(p["row"]))
		pilots_list.set_item_disabled(idx, not free or locked or not mine)
		if mine and p["name"] == c.get("name", ""):
			pilots_list.set_item_custom_fg_color(idx, AMBER)
		elif int(p["status"]) == 1:
			pilots_list.set_item_custom_fg_color(idx, LED_BAD.darkened(0.2))
		elif int(p["status"]) == 2:
			pilots_list.set_item_custom_fg_color(idx, LED_WARN.darkened(0.3))
	var off := locked or not mine
	var suit := int(c.get("suit", 0))
	suit_opt.clear()
	for s in st.get("suits", []):
		suit_opt.add_item(s[1], int(s[0]))
		suit_opt.set_item_tooltip(suit_opt.item_count - 1, str(s[2]) if s.size() > 2 else "")
		if int(s[0]) == suit:
			suit_opt.select(suit_opt.item_count - 1)
	suit_opt.disabled = off
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
			o.set_item_tooltip(o.item_count - 1, str(it[4]) if it.size() > 4 else "")
			if id == int(w[arm if both else k]):
				o.select(o.item_count - 1)
		o.disabled = off or (both and k == arm + 1)
	var fixed: bool = int(c.get("asf", 0)) < 2
	asf_opt.clear()
	if fixed or not mine:
		asf_opt.add_item(_asf_name(int(c.get("asf", 0))), int(c.get("asf", 0)))
		asf_note.text = "Comes with the pilot's specialty" if mine and fixed else ""
	else:
		asf_note.text = ""
		for a in st.get("asf", []):
			if (int(a[2]) >> suit) & 1 == 0:
				continue
			asf_opt.add_item(a[1], int(a[0]))
			if int(a[0]) == int(c.get("asf", 0)):
				asf_opt.select(asf_opt.item_count - 1)
	asf_opt.disabled = off or fixed
	# the game's spec lines for what he carries
	var si := _item("suits", suit)
	spec_label.text = str(si[2]) if mine and si.size() > 2 else ""
	for k in 4:                                       # each weapon's line: on its drop-down
		var it := _item("weapons", int(w[k]))
		slot_opts[k].tooltip_text = str(it[4]) if it.size() > 4 else ""
	for b in save_btns + load_btns:
		b.disabled = off
	ready_btn.disabled = not mine
	ready_btn.set_pressed_no_signal(bool(st.get("ready", false)))
	ready_btn.text = "READY  ✓" if st.get("ready", false) else "READY"


# ---- the briefing: the mission's map from above (the viewer loads the host's mission), the chat
func _mission_map() -> void:
	var f := str(st.get("msnfile", ""))
	var vp := _viewer()
	if f == "" or vp == null or not vp.has_method("_load_by_label") or not ("current" in vp):
		return
	map_view.world_3d = vp.get_viewport().world_3d
	var cur: Dictionary = vp.current
	var loaded := not cur.is_empty() and str(cur["entry"]["file"]).get_file().to_upper() == f.to_upper()
	if not loaded and msn_asked != f:
		msn_asked = f                                  # once: loading takes a while
		vp._load_by_label(f)


func _map_aim() -> void:
	var vp := _viewer()
	if vp == null or not ("current" in vp) or vp.current.is_empty():
		return
	var ents: Array = vp.current["mission"]["entities"]
	var sum := Vector2.ZERO
	var n := 0
	for e in ents:
		if int(e["cls"]) == 1:                         # the suits: where the squad starts
			sum += Vector2(e["x"], e["y"])
			n += 1
	if n == 0:
		return
	var c := sum / n
	map_cam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, Vector3.FORWARD), Vector3(c.x, 200.0, c.y))   # under the live view's depth fog (250)


func _chat_refresh() -> void:
	var lines := []
	var top := -1
	for c in st.get("chat", []):
		top = maxi(top, int(c[0]))
		lines.append("%s: %s" % [mate_name if c[1] == "host" else self_name, c[2]])
	chat_log.text = "\n".join(lines.slice(-4))
	if chat_seen >= 0 and top > chat_seen and shown:
		_sound(SND_PICK)                               # a new line
	chat_seen = maxi(chat_seen, top)


func _on_chat(t: String) -> void:
	chat_edit.clear()
	if t.strip_edges() != "":
		_send({"act": "chat", "text": t.strip_edges()})


# ---- choices
func _on_ready(on: bool) -> void:
	if busy:
		return
	_sound(SND_PICK)
	_send({"act": "ready", "on": on})


func _on_pilot(i: int) -> void:
	if busy:
		return
	_sound(SND_PICK)
	_send({"act": "pilot", "row": int(pilots_list.get_item_metadata(i))})


func _on_weapon(k: int, i: int) -> void:
	if busy:
		return
	_sound(SND_PICK)
	_send({"act": "weapon", "slot": k, "id": slot_opts[k].get_item_id(i)})


func _send_item(act: String, o: OptionButton, i: int) -> void:
	if busy:
		return
	_sound(SND_PICK)
	_send({"act": act, "id": o.get_item_id(i)})


# ---- saved loadouts (this PC): suit, the 4 weapon slots, the ASF
func _loadouts() -> Array:
	var a = JSON.parse_string(FileAccess.get_file_as_string(LOADOUTS)) if FileAccess.file_exists(LOADOUTS) else null
	return a if typeof(a) == TYPE_ARRAY and a.size() == 3 else [null, null, null]


func _save_loadout(n: int) -> void:
	var col := int(st.get("col", 0))
	var cols: Array = st.get("cols", [])
	if col <= 0 or col >= cols.size():
		return
	var c: Dictionary = cols[col]
	var a := _loadouts()
	a[n] = {"suit": int(c["suit"]), "w": c["w"], "asf": int(c["asf"])}
	var f := FileAccess.open(LOADOUTS, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(a))
	_sound(SND_PICK)
	info.text = "Loadout saved in %d." % (n + 1)


func _load_loadout(n: int) -> void:
	var l = _loadouts()[n]
	if typeof(l) != TYPE_DICTIONARY:
		info.text = "Nothing saved in %d yet." % (n + 1)
		return
	_sound(SND_PICK)
	_send({"act": "suit", "id": int(l["suit"])})      # the bridge takes them in order: suit, arms, then the ASF
	var w: Array = l["w"]
	for arm in [0, 2]:
		_send({"act": "weapon", "slot": arm, "id": int(w[arm])})
		if int(w[arm + 1]) != 0:
			_send({"act": "weapon", "slot": arm + 1, "id": int(w[arm + 1])})
	if int(l["asf"]) >= 2:
		_send({"act": "asf", "id": int(l["asf"])})
