# Coop guest HUD (the second player's window, --coop-hud or --coop-guest). The host's live/coop_guest.py sends ~10
# packets a second to 127.0.0.1:47832: 'GHD' + <BhhHBBH: state (0 playing, 1 suit destroyed: next teammate in 3 s,
# 2 no teammate left: the host's view), armour, armour at pickup, entity, weapon slot (keys 1-4), weapon type, heading
# (game units). And every 10 s 'GCK' + palette + zlib(index, alpha 320 x 400): the host's cockpit with his own panels
# emptied. With it the guest gets the game's cockpit filled with his own armour, weapon, compass and map, and the
# host's name and Steam avatar in the COMM panel (set_mate, from coop_net.gd). Before the first cockpit: a plain
# crosshair and armour bar. Online, the host window's coop_net.gd relays the packets over Steam and the guest's
# coop_net.gd forwards them here. Nothing is drawn when no packet came for 2 s.
extends CanvasLayer

const LGRes = preload("res://scripts/lgres.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
# the WEAPON panel's picture for each weapon type: the game's table at 0x35B27A (RESHLMHI.RES, 82 x 104-106, RLE),
# drawn from the guest's own game files in the game's palette (the cockpit packet's)
const WEAPON_PIC := [515, 516, 518, 507, 513, 508, 509, 511, 514, 510, 512, 519, 515, 517, 517, 520, 521, 522]

const HUD_PORT := 47832
const TIMEOUT := 2.0
const WEAPONS := ["", "Flare Launcher", "Smoke Grenade", "Grenade Launcher", "Laser", "Multipulsar", "Particle Beam",
	"Railgun", "EM Emitter", "Thermal Disruptor", "Missile Launcher", "Ionic Fusion Rifle", "SIR Mark IV", "M-B Cannon",
	"M-B Accelerator", "Pulsar", "Particle Beam", "Grenade Launcher"]   # the game's weapon names (by slot type)

var udp := PacketPeerUDP.new()
var clock := 0.0
var last := -100.0
var state := 0
var armour := 0
var armour_max := 1
var host_ent := 0                    # the host's entity: his name over the suit the viewer draws
var energy := 100                     # his energy, % of what he had at pickup (shots draw from it)
var entity := 0
var weapon_slot := 0
var weapon_type := 0
var heading := 0
var lock := 0                        # his locked unit (0: none) and its middle, the game's x, y, z
var lock_pos := Vector3.ZERO
var host_pos := Vector3.ZERO           # the host's suit (Godot units): his name above it
var guest_xy := Vector2.ZERO           # his own suit (game x, y): the map's centre
var squad := []                        # COMM panel: [entity, armour %, pilot] (the host first)
var game_res = null                    # RESGAME.RES (pilot names, resource 364)
var faces := {}                        # pilot -> portrait texture (RESHLMHI.RES 538)

var root: Control
var cross: Control
var bottom: Control
var armour_label: Label
var bar_fill: ColorRect
var mate_label: Label
var hint_label: Label
var down_title: Label
var down_text: Label
var spec_label: Label
var cockpit: TextureRect             # the game's cockpit (from the host's screen), over the whole window
var panel: Control                   # what is drawn on it, in the game's 320 x 400 screen units (_draw_panel)
var map_view: SubViewport            # the map: the 3D world from above, around the guest
var map_cam: Camera3D
var map_rect: TextureRect
var status_page := false             # Tab (or the STATUS tab with the mouse free): his weapon slots, jump, lock
var slot_types := PackedByteArray([0, 0, 0, 0])
var jump_ready := true
var rear_view: SubViewport            # the dashboard's rear view (the game's small screen under the 3D window)
var rear_cam: Camera3D
var rear_rect: TextureRect
var big_map := false                 # M (or the MAP button with the mouse free): the map over the 3D window, wider
var mate_name := "Host"
var mate_face: ImageTexture
var font: Font
var hud_pal := PackedColorArray()     # the game's palette (cockpit packet)
var weapon_pics := {}                 # type -> texture
var hl_res = null                     # RESHLMHI.RES
# --coop-preview (local coop, TN_COOP_PREVIEW=1): this PC's Steam account is the host, as online: its name and avatar
# in this (the guest's) cockpit. The host's HUD keeps "Player 2": a local guest has no Steam account of his own.
var preview_steam: Object
var win := Rect2()                   # the game's 3D window (320 x 400 units), from the cockpit packet
var lobby: CanvasLayer               # the Mission Outfitting lobby ('GLB' packets, coop_lobby.gd)

var ok_col := Color(0.35, 1.0, 0.45)
var warn_col := Color(1.0, 0.75, 0.25)
var bad_col := Color(1.0, 0.35, 0.3)


func _ready() -> void:
	layer = 9
	lobby = preload("res://scripts/coop_lobby.gd").new()
	add_child(lobby)
	udp.bind(HUD_PORT, "127.0.0.1", 1 << 20)
	font = ThemeDB.fallback_font
	if "--coop-preview" in OS.get_cmdline_user_args():
		_preview()
	root = Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.visible = false
	add_child(root)
	cockpit = TextureRect.new()
	cockpit.set_anchors_preset(Control.PRESET_FULL_RECT)
	cockpit.stretch_mode = TextureRect.STRETCH_SCALE
	cockpit.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cockpit.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	cockpit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cockpit.visible = false
	root.add_child(cockpit)
	map_view = SubViewport.new()
	map_view.size = Vector2i(168, 216)
	map_view.world_3d = get_viewport().world_3d
	map_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(map_view)
	map_cam = Camera3D.new()
	map_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	map_cam.size = 60.0
	map_cam.far = 600.0
	map_view.add_child(map_cam)
	map_rect = TextureRect.new()
	map_rect.texture = map_view.get_texture()
	map_rect.stretch_mode = TextureRect.STRETCH_SCALE
	map_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	map_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	map_rect.visible = false
	root.add_child(map_rect)
	rear_view = SubViewport.new()
	rear_view.size = Vector2i(120, 100)
	rear_view.world_3d = get_viewport().world_3d
	add_child(rear_view)
	rear_cam = Camera3D.new()
	rear_cam.fov = 60.0
	rear_cam.far = 400.0
	rear_cam.cull_mask = 0xFFFFF & ~(1 << 18)            # not his own body (the viewer's PLAYER_LAYER)
	rear_view.add_child(rear_cam)
	rear_rect = TextureRect.new()
	rear_rect.texture = rear_view.get_texture()
	rear_rect.stretch_mode = TextureRect.STRETCH_SCALE
	rear_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rear_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rear_rect.visible = false
	root.add_child(rear_rect)
	panel = Control.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.draw.connect(_draw_panel)
	panel.visible = false
	root.add_child(panel)
	# crosshair: four short bars around the centre, dark edge for bright skies
	cross = Control.new()
	cross.set_anchors_preset(Control.PRESET_CENTER)
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cross)
	for r in [Rect2(-12, -1, 8, 2), Rect2(4, -1, 8, 2), Rect2(-1, -12, 2, 8), Rect2(-1, 4, 2, 8)]:
		cross.add_child(_rect(r.grow(1), Color(0, 0, 0, 0.6)))
		cross.add_child(_rect(r, Color(0.85, 1.0, 0.85, 0.9)))
	# bottom left (before the first cockpit): armour bar, teammate, hint
	bottom = Control.new()
	bottom.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	bottom.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bottom)
	armour_label = _label(18, ok_col)
	armour_label.position = Vector2(16, -96)
	bottom.add_child(armour_label)
	bottom.add_child(_rect(Rect2(15, -67, 202, 12), Color(0, 0, 0, 0.7)))
	bar_fill = _rect(Rect2(16, -66, 200, 10), ok_col)
	bottom.add_child(bar_fill)
	mate_label = _label(14, Color(0.8, 0.85, 0.9))
	mate_label.position = Vector2(16, -50)
	bottom.add_child(mate_label)
	hint_label = _label(14, Color(0.8, 0.85, 0.9))
	hint_label.position = Vector2(16, -30)
	hint_label.text = "F8: next teammate   1-4: weapon   Space: jets   Shift+move: jump   right button: lock   Enter: dropship"
	bottom.add_child(hint_label)
	var drop := Button.new()                 # the game's "Call dropship" (Enter), posted to the host's game
	drop.text = "CALL DROPSHIP"
	drop.focus_mode = Control.FOCUS_NONE
	drop.position = Vector2(232, -72)
	drop.pressed.connect(func():
		for d in [1, 0]:
			lobby.out.put_packet(PackedByteArray([0x4B, 0x1C, 0, d])))
	bottom.add_child(drop)
	# centre: suit destroyed / spectating
	var centre := Control.new()
	centre.set_anchors_preset(Control.PRESET_CENTER)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centre)
	down_title = _label(48, bad_col)
	down_title.text = "SUIT DESTROYED"
	down_title.add_theme_constant_override("outline_size", 8)
	_centre(down_title, -70, 70)
	centre.add_child(down_title)
	down_text = _label(20, Color(0.9, 0.9, 0.9))
	down_text.text = "switching to the next teammate..."
	_centre(down_text, 0, 30)
	centre.add_child(down_text)
	spec_label = _label(22, warn_col)
	spec_label.text = "NO TEAMMATE LEFT - watching the host"
	_centre(spec_label, -160, 34)
	centre.add_child(spec_label)


func _label(size: int, col: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _centre(l: Label, y: float, h: float) -> void:
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.position = Vector2(-500, y)
	l.size = Vector2(1000, h)


func _rect(r: Rect2, col: Color) -> ColorRect:
	var c := ColorRect.new()
	c.position = r.position
	c.size = r.size
	c.color = col
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _process(delta: float) -> void:
	clock += delta
	if preview_steam:
		preview_steam.run_callbacks()
	var got := false
	while udp.get_available_packet_count() > 0:
		var pk := udp.get_packet()
		var tag := pk.slice(0, 3).get_string_from_ascii() if pk.size() >= 3 else ""
		if tag == "GCK" and pk.size() > 11 + 768:
			_cockpit(pk)
		elif tag == "GLB":
			lobby.feed(pk)
		elif tag == "GHD" and pk.size() >= 10:
			state = pk.decode_u8(3)
			armour = pk.decode_s16(4)
			armour_max = maxi(1, pk.decode_s16(6))
			entity = pk.decode_u16(8)
			if pk.size() >= 14:
				weapon_slot = pk.decode_u8(10)
				weapon_type = pk.decode_u8(11)
				heading = pk.decode_u16(12)
			lock = 0
			if pk.size() >= 40:
				guest_xy = Vector2(pk.decode_float(28), pk.decode_float(32))
			squad = []
			if pk.size() >= 53:
				for i in mini(pk.decode_u8(52), 3):
					if 53 + 4 * i + 4 <= pk.size():
						squad.append([pk.decode_u16(53 + 4 * i), pk.decode_u8(55 + 4 * i), pk.decode_u8(56 + 4 * i)])
				var so := 53 + 4 * mini(pk.decode_u8(52), 3)
				if so + 5 <= pk.size():
					slot_types = pk.slice(so, so + 4)
					jump_ready = pk.decode_u8(so + 4) != 0
				if so + 6 <= pk.size():
					energy = pk.decode_u8(so + 5)
				if so + 8 <= pk.size():
					host_ent = pk.decode_u16(so + 6)
			if pk.size() >= 52:
				host_pos = Vector3(pk.decode_float(40), pk.decode_float(48) - 0.12, pk.decode_float(44))
			if pk.size() >= 28:
				lock = pk.decode_u16(14)
				lock_pos = Vector3(pk.decode_float(16), pk.decode_float(24) - 0.12, pk.decode_float(20))   # Godot: x, up, y
			last = clock
			got = true
	root.visible = clock - last < TIMEOUT
	if got and root.visible:
		_update()
	if root.visible:
		if cockpit.visible:
			_map_follow()
		_rear_follow()
		panel.visible = true
		panel.queue_redraw()


func _update() -> void:
	var ck := cockpit.texture != null
	cross.visible = state == 0 and not ck
	bottom.visible = state == 0 and not ck
	cockpit.visible = ck
	panel.visible = ck
	map_rect.visible = ck and state == 0
	down_title.visible = state == 1
	down_text.visible = state == 1
	spec_label.visible = state == 2
	if state != 0:
		return
	var f := clampf(float(armour) / float(armour_max), 0.0, 1.0)
	var col: Color = ok_col if f > 0.5 else (warn_col if f > 0.25 else bad_col)
	armour_label.text = "ARMOUR %d%%     ENERGY %d%%" % [int(round(f * 100.0)), energy]
	armour_label.add_theme_color_override("font_color", col)
	bar_fill.size.x = 200.0 * f
	bar_fill.color = col
	mate_label.text = "TEAMMATE #%d   %s" % [entity, WEAPONS[weapon_type] if weapon_type < WEAPONS.size() else ""]


func _cockpit(pk: PackedByteArray) -> void:
	# the game's 3D window: the viewer frames its view on it like the host's (off-centre frustum), the crosshair
	# at the game's view centre, 51 % down the window
	win = Rect2(pk.decode_s16(3), pk.decode_s16(5), pk.decode_s16(7), pk.decode_s16(9))
	var vp := get_parent()
	if vp and "hud_win" in vp:
		vp.hud_win = Rect2i(win)
	var pal := pk.slice(11, 11 + 768)
	if hud_pal.is_empty():
		for i in 256:
			hud_pal.append(Color8(pal[3 * i], pal[3 * i + 1], pal[3 * i + 2]))
	var raw := pk.slice(11 + 768).decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != 320 * 400 * 2:
		return
	var rgba := PackedByteArray()
	rgba.resize(320 * 400 * 4)
	for i in 320 * 400:
		var c := raw[2 * i] * 3
		rgba[4 * i] = pal[c]
		rgba[4 * i + 1] = pal[c + 1]
		rgba[4 * i + 2] = pal[c + 2]
		rgba[4 * i + 3] = raw[2 * i + 1]
	cockpit.texture = ImageTexture.create_from_image(Image.create_from_data(320, 400, false, Image.FORMAT_RGBA8, rgba))
	_update()


func _preview() -> void:
	if not Engine.has_singleton("Steam"):
		GDExtensionManager.load_extension("res://addons/godotsteam/godotsteam.gdextension")
	if not Engine.has_singleton("Steam"):
		return
	preview_steam = Engine.get_singleton("Steam")
	if int(preview_steam.steamInitEx(480, false).get("status", 1)) != 0:
		preview_steam = null
		return
	preview_steam.connect("avatar_loaded", _preview_avatar)
	preview_steam.getPlayerAvatar(2, preview_steam.getSteamID())


func _preview_avatar(_id: int, size: int, data: PackedByteArray) -> void:
	if size <= 0 or data.size() != size * size * 4:
		return
	var img := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, data)
	var h := int(size / 1.73)
	img = img.get_region(Rect2i(0, int((size - h) * 0.4), size, h))
	var name: String = preview_steam.getPersonaName()
	set_mate(name, img)


# the map's units: teammates green, the host blue, others red; north-up like the 3D (his heading up)
func _draw_map_units() -> void:
	var vp := get_parent()
	if vp == null or not ("live_ents" in vp) or guest_xy == Vector2.ZERO:
		return
	var h := heading / 65536.0 * TAU
	var fwd := Vector2(cos(h), sin(h))
	var right := Vector2(-fwd.y, fwd.x)
	var box := _map_box().grow(-1.0)
	var c := box.get_center()
	var k := box.size.y / map_cam.size                      # screen pixels per game unit (the map camera's height)
	var host_e: int = squad[0][0] if not squad.is_empty() else -1
	var mates := {}
	for w in squad:
		mates[w[0]] = true
	for idx in vp.live_ents:
		var e: Array = vp.live_ents[idx]
		if e[0] < 1 or e[0] > 3 or e[2] == 0 or idx == entity:
			continue
		var rel := Vector2(e[3], e[4]) - guest_xy
		var p := c + Vector2(rel.dot(right), -rel.dot(fwd)) * k
		if not box.has_point(p):
			continue
		var col := Color(0.4, 0.8, 1.0) if idx == host_e else (Color(0.3, 1.0, 0.35) if mates.has(idx) else Color(1.0, 0.3, 0.25))
		panel.draw_rect(Rect2(p - Vector2(2.5, 2.5), Vector2(5, 5)), Color.BLACK)
		panel.draw_rect(Rect2(p - Vector2(1.5, 1.5), Vector2(3, 3)), col)


func _face(pilot: int) -> Texture2D:
	if pilot >= 33 or hud_pal.is_empty():
		return null
	if faces.has(pilot):
		return faces[pilot]
	var tex: Texture2D = null
	var vp := get_parent()
	if hl_res == null and vp and "data" in vp:
		hl_res = LGRes.open(vp.data.data_dir().path_join("RESHLMHI.RES"))
	if hl_res and hl_res.has(538):
		var fr: Array = LGRes.frames(hl_res.data(538))
		if pilot < fr.size():
			var img: Image = TNObjects._bitmap(fr[pilot], hud_pal)
			if img:
				tex = ImageTexture.create_from_image(img)
	faces[pilot] = tex
	return tex


func _pilot_name(pilot: int, e: int) -> String:
	var vp := get_parent()
	if game_res == null and vp and "data" in vp:
		game_res = LGRes.open(vp.data.data_dir().path_join("RESGAME.RES"))
	if pilot < 33 and game_res and game_res.has(364):
		var names: PackedStringArray = game_res.strings(364)
		if pilot < names.size():
			return names[pilot]
	return "#%d" % e


func _weapon_pic(t: int) -> Texture2D:
	if weapon_pics.has(t):
		return weapon_pics[t]
	var tex: Texture2D = null
	var vp := get_parent()
	if t < WEAPON_PIC.size() and not hud_pal.is_empty() and vp and "data" in vp:
		if hl_res == null:
			hl_res = LGRes.open(vp.data.data_dir().path_join("RESHLMHI.RES"))
		if hl_res and hl_res.has(WEAPON_PIC[t]):
			var fr: Array = LGRes.frames(hl_res.data(WEAPON_PIC[t]))
			var img: Image = TNObjects._bitmap(fr[0], hud_pal) if fr.size() > 0 else null
			if img:
				tex = ImageTexture.create_from_image(img)
	weapon_pics[t] = tex
	return tex


# the host: his Steam name and avatar in the COMM panel (coop_net.gd; "Host" and no picture in local coop)
func set_mate(mate: String, face: Image) -> void:
	mate_name = mate
	if face:
		mate_face = ImageTexture.create_from_image(face)
	lobby.set_mate(mate, face)


# the guest: his own Steam name and avatar, for the lobby
func set_self(me: String, face: Image) -> void:
	lobby.set_self(me, face)


# the game's screen units (320 x 400) to the window
func _g(x: float, y: float) -> Vector2:
	var s := root.size
	return Vector2(x * s.x / 320.0, y * s.y / 400.0)


func _grect(x0: float, y0: float, x1: float, y1: float) -> Rect2:
	return Rect2(_g(x0, y0), _g(x1, y1) - _g(x0, y0))


func _text(t: String, x: float, y: float, h: float, col: Color, centre := false) -> void:
	var fs := int(maxf(8.0, _g(0, h).y))
	var p := _g(x, y)
	if centre:
		p.x -= font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x / 2.0
	p.y += fs * 0.8
	panel.draw_string_outline(font, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 3, Color.BLACK)
	panel.draw_string(font, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw_panel() -> void:
	if state != 0:
		return
	if not big_map:                                  # the big map covers the 3D view: no marks on it
		_draw_lock()
		_draw_mate()
	if not cockpit.visible:
		return
	var vp := get_parent()
	var looking: bool = big_map or (vp != null and "look_off" in vp and vp.look_off.length() > 0.03)
	var cc := _g(win.position.x + win.size.x / 2.0, win.position.y + 0.51 * win.size.y)
	for r in ([] if looking else [Rect2(-12, -1, 8, 2), Rect2(4, -1, 8, 2), Rect2(-1, -12, 2, 8), Rect2(-1, 4, 2, 8)]):   # free look: no crosshair (his aim stays ahead)
		panel.draw_rect(Rect2(cc + r.position, r.size).grow(1), Color(0, 0, 0, 0.6))
		panel.draw_rect(Rect2(cc + r.position, r.size), Color(0.85, 1.0, 0.85, 0.9))
	# compass: 64 game pixels for 90 degrees, the heading at the strip's centre (x 160)
	var bearing := fposmod(360.0 - heading / 65536.0 * 360.0, 360.0)
	var amber := Color(1.0, 0.8, 0.25)
	for k in 8:
		var d := fposmod(k * 45.0 - bearing + 180.0, 360.0) - 180.0
		var x := 160.0 + d * 64.0 / 90.0
		if x < 36.0 or x > 284.0:
			continue
		if k % 2 == 0:
			_text(["N", "E", "S", "W"][k / 2], x, 3.0, 12.0, amber if k == 0 else Color(0.85, 0.85, 1.0), true)
		else:
			panel.draw_rect(_grect(x - 0.5, 8.0, x + 0.5, 14.0), Color(0.6, 0.6, 0.8))
	panel.draw_rect(_grect(159.0, 1.0, 161.0, 3.0), amber)
	panel.draw_rect(_grect(159.0, 16.0, 161.0, 18.0), amber)
	# armour: the left bar, red leds from its inner end
	var f := clampf(float(armour) / float(armour_max), 0.0, 1.0)
	for i in int(round(f * 22.0)):
		var x1 := 161.0 - i * 4.0
		panel.draw_rect(_grect(x1 - 3.0, 26.0, x1, 33.0), Color(0.9, 0.2, 0.15) if f > 0.25 else Color(1.0, 0.5, 0.1))
	# energy: the right bar, green leds from its inner end (the game's "E")
	for i in int(round(energy / 100.0 * 22.0)):
		var x0 := 163.0 + i * 4.0
		panel.draw_rect(_grect(x0, 26.0, x0 + 3.0, 33.0), Color(0.25, 0.9, 0.3) if energy > 25 else Color(1.0, 0.75, 0.2))
	# COMM: his squad as the game lists it: the host (Steam avatar and name), then his other teammates (their
	# portraits and names from his game files), each with an armour bar
	var rows: Array = squad if not squad.is_empty() else [[0, 100, 255]]
	for i in rows.size():
		var y0 := 273.0 + 30.0 * i
		var who: Array = rows[i]
		var pic: Texture2D = mate_face if i == 0 else _face(who[2])
		if pic:
			panel.draw_texture_rect(pic, _grect(29.0, y0, 50.0, y0 + 27.0), false)
		else:
			panel.draw_rect(_grect(29.0, y0, 50.0, y0 + 27.0), Color(0.05, 0.05, 0.1))
		var nm: String = mate_name if i == 0 else _pilot_name(who[2], who[0])
		_text(nm.to_upper(), 54.0, y0 + 1.0, 11.0, Color(1.0, 0.8, 0.2) if i == 0 else Color(0.9, 0.9, 0.95))
		var a: float = who[1] / 100.0
		panel.draw_rect(_grect(54.0, y0 + 17.0, 104.0, y0 + 21.0), Color(0.1, 0.1, 0.15))
		panel.draw_rect(_grect(54.0, y0 + 17.0, 54.0 + 50.0 * a, y0 + 21.0),
			Color(0.3, 0.9, 0.3) if a > 0.5 else (Color(1.0, 0.7, 0.2) if a > 0.25 else Color(1.0, 0.25, 0.2)))
	_text("SHIFT+MOVE JUMP  ALT LOOK  F8", 31.0, 366.0, 8.0, Color(0.6, 0.65, 0.8))
	if status_page:
		_draw_status()
	# WEAPON: his selected weapon, its picture under the texts as in the game
	var wpic := null if status_page else _weapon_pic(weapon_type)
	if wpic:
		panel.draw_texture_rect(wpic, _grect(211.0, 276.0, 211.0 + wpic.get_width(), 276.0 + wpic.get_height()), false)
	var wn: String = WEAPONS[weapon_type] if weapon_type < WEAPONS.size() else "?"
	if not status_page:
		_text(wn.to_upper(), 251.0, 278.0, 12.0, Color(0.95, 0.95, 1.0), true)
		_text("%d%%" % int(round(f * 100.0)), 214.0, 338.0, 12.0, Color(0.95, 0.95, 1.0))
		_text("FULLY OPERATIONAL" if f > 0.5 else "DAMAGED", 214.0, 355.0, 12.0,
			Color(0.95, 0.95, 1.0) if f > 0.5 else Color(1.0, 0.6, 0.2))
	_draw_map_units()
	# map: the guest in the middle, pointing up
	var c := _map_box().get_center()
	var u := _g(0, 6).y
	if big_map:
		_text("MAP  (M: back)", win.position.x + 16.0, win.position.y + 10.0, 10.0, Color(0.9, 0.9, 1.0))
	panel.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -u), c + Vector2(u * 0.6, u * 0.6),
		c + Vector2(-u * 0.6, u * 0.6)]), Color(1, 1, 1))


# the lock: green corners around his target, where his camera sees it
# the host's name over his suit (and how far he is)
func _draw_mate() -> void:
	var cam := get_viewport().get_camera_3d()
	if host_pos == Vector3.ZERO or cam == null:
		return
	var n := _drawn(host_ent)                  # the suit as drawn (20 views a second); these packets come ~twice a second
	var top := (n.global_position if n else host_pos) + Vector3(0, 0.72, 0)   # just over his head (a suit stands ~0.6)
	if cam.is_position_behind(top):
		return
	var c := cam.unproject_position(top)
	var d := cam.global_position.distance_to(top)
	var fs := int(clampf(root.size.y * 0.028, 12.0, 26.0))
	var t := "%s  %dm" % [mate_name, int(round(d * 6.0))]   # the game's metres (its lock reads 51 m where 8.5 units)
	var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := c - Vector2(w / 2.0, 6.0)
	panel.draw_string_outline(font, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color.BLACK)
	panel.draw_string(font, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.45, 0.85, 1.0))
	panel.draw_colored_polygon(PackedVector2Array([c + Vector2(-5, -2), c + Vector2(5, -2), c + Vector2(0, 5)]),
		Color(0.45, 0.85, 1.0))


func _drawn(idx: int) -> Node3D:
	# the viewer's node for an entity, where it is drawn now (null: none, or not shown)
	var vp := get_parent()
	if idx <= 0 or vp == null or not vp.has_method("_live_node"):
		return null
	var n: Node3D = vp._live_node(idx)
	return n if n != null and is_instance_valid(n) and n.visible else null


func _draw_lock() -> void:
	var cam := get_viewport().get_camera_3d()
	if lock == 0 or cam == null:
		return
	var n := _drawn(lock)
	var at := n.global_position + Vector3(0, 0.35, 0) if n else lock_pos   # its middle, as the bridge's lock_pos
	if cam.is_position_behind(at):
		return
	var c := cam.unproject_position(at)
	var r := maxf(10.0, root.size.y * 0.03)
	var col := Color(0.3, 1.0, 0.35)
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			var k := c + Vector2(sx * r, sy * r)
			panel.draw_line(k, k - Vector2(sx * r * 0.5, 0), col, 2.0)
			panel.draw_line(k, k - Vector2(0, sy * r * 0.5), col, 2.0)


func toggle_status() -> void:
	status_page = not status_page


# STATUS page (the WEAPON panel's other tab): his 4 weapon slots, the selected one lit, jump and lock
func _draw_status() -> void:
	_text("STATUS", 251.0, 278.0, 12.0, Color(0.95, 0.95, 1.0), true)
	for k in 4:
		var t: int = slot_types[k]
		var nm: String = WEAPONS[t] if t < WEAPONS.size() and t > 0 else "-"
		var sel := k == weapon_slot
		_text("%d %s" % [k + 1, nm.to_upper()], 215.0, 296.0 + 13.0 * k, 10.0,
			Color(0.4, 1.0, 0.45) if sel else Color(0.75, 0.78, 0.9))
	_text("JUMP %s" % ("READY" if jump_ready else "..."), 215.0, 350.0, 10.0,
		Color(0.4, 1.0, 0.45) if jump_ready else Color(1.0, 0.7, 0.25))
	_text("LOCK %s" % ("#%d" % lock if lock else "-"), 215.0, 363.0, 10.0,
		Color(0.4, 1.0, 0.45) if lock else Color(0.75, 0.78, 0.9))


func toggle_map() -> void:
	big_map = not big_map


func _map_box() -> Rect2:
	if big_map and win.size.y > 0:
		return _grect(win.position.x + 12.0, win.position.y + 8.0, win.end.x - 12.0, win.end.y - 8.0)
	return _grect(118.0, 260.0, 202.0, 368.0)


func _rear_follow() -> void:
	var cam := get_viewport().get_camera_3d()
	rear_rect.visible = cockpit.visible and state == 0 and cam != null
	if not rear_rect.visible:
		return
	rear_rect.position = _g(147.0, 223.0)
	rear_rect.size = _g(175.0, 252.0) - _g(147.0, 223.0)
	var back := cam.global_transform
	back.basis = back.basis.rotated(Vector3.UP, PI)
	rear_cam.global_transform = back


func _map_follow() -> void:
	var box := _map_box()
	map_rect.position = box.position
	map_rect.size = box.size
	map_cam.size = 220.0 if big_map else 60.0
	map_view.size = Vector2i(maxi(16, int(box.size.x)), maxi(16, int(box.size.y)))
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := cam.global_position
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	map_cam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, fwd.normalized()), p + Vector3.UP * 150.0)
