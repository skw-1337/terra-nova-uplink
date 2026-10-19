# Coop guest HUD (the second player's window, --coop-hud or --coop-guest). The host's live/coop_guest.py sends ~10
# packets a second to 127.0.0.1:47832: 'GHD' + <BhhHBBH: state (0 playing, 1 suit destroyed: next teammate in 3 s,
# 2 no teammate left: the host's view), armour, armour at pickup, entity, weapon slot (keys 1-4), weapon type, heading
# (game units). And every 10 s 'GCK' + palette + zlib(index, alpha 320 x 400): the host's cockpit with his own panels
# emptied. With it the guest gets the game's cockpit filled with his own armour, weapon, compass and map, and the
# host's name and Steam avatar in the COMM panel (set_mate, from coop_net.gd). Before the first cockpit: a plain
# crosshair and armour bar. Online, the host window's coop_net.gd relays the packets over Steam and the guest's
# coop_net.gd forwards them here. Nothing is drawn when no packet came for 2 s.
extends CanvasLayer

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
var entity := 0
var weapon_slot := 0
var weapon_type := 0
var heading := 0
var lock := 0                        # his locked unit (0: none) and its middle, the game's x, y, z
var lock_pos := Vector3.ZERO
var host_pos := Vector3.ZERO           # the host's suit (Godot units): his name above it

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
var mate_name := "Host"
var mate_face: ImageTexture
var font: Font
# --coop-preview (local coop, TN_COOP_PREVIEW=1): this PC's Steam account is the host, as online: its name and avatar
# in this (the guest's) cockpit. The host's HUD keeps "Player 2": a local guest has no Steam account of his own.
var preview_steam: Object
var win := Rect2()                   # the game's 3D window (320 x 400 units), from the cockpit packet

var ok_col := Color(0.35, 1.0, 0.45)
var warn_col := Color(1.0, 0.75, 0.25)
var bad_col := Color(1.0, 0.35, 0.3)


func _ready() -> void:
	layer = 9
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
	hint_label.text = "F8: next teammate   1-4: weapon   Shift+move: jump   right button: lock"
	bottom.add_child(hint_label)
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
	armour_label.text = "ARMOUR %d%%" % int(round(f * 100.0))
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


# the host: his Steam name and avatar in the COMM panel (coop_net.gd; "Host" and no picture in local coop)
func set_mate(mate: String, face: Image) -> void:
	mate_name = mate
	if face:
		mate_face = ImageTexture.create_from_image(face)


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
	_draw_lock()
	_draw_mate()
	if not cockpit.visible:
		return
	var vp := get_parent()
	var looking: bool = vp != null and "look_off" in vp and vp.look_off.length() > 0.03
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
	# COMM: the host's avatar and name
	if mate_face:
		panel.draw_texture_rect(mate_face, _grect(29.0, 273.0, 50.0, 300.0), false)
	else:
		panel.draw_rect(_grect(29.0, 273.0, 50.0, 300.0), Color(0.05, 0.05, 0.1))
	_text(mate_name.to_upper(), 54.0, 275.0, 12.0, Color(1.0, 0.8, 0.2))
	_text("SQUAD LEADER", 54.0, 289.0, 12.0, Color(0.9, 0.9, 0.95))
	_text("ARMOUR %d%%" % int(round(f * 100.0)), 31.0, 350.0, 11.0, Color(0.9, 0.9, 0.95))
	_text("SHIFT+MOVE JUMP  ALT LOOK  F8", 31.0, 363.0, 9.0, Color(0.6, 0.65, 0.8))
	# WEAPON: his selected weapon
	var wn: String = WEAPONS[weapon_type] if weapon_type < WEAPONS.size() else "?"
	_text(wn.to_upper(), 251.0, 278.0, 12.0, Color(0.95, 0.95, 1.0), true)
	_text("SLOT %d   KEYS 1-4" % (weapon_slot + 1), 251.0, 298.0, 10.0, Color(0.7, 0.75, 0.9), true)
	_text("%d%%" % int(round(f * 100.0)), 214.0, 338.0, 12.0, Color(0.95, 0.95, 1.0))
	_text("FULLY OPERATIONAL" if f > 0.5 else "DAMAGED", 214.0, 355.0, 12.0,
		Color(0.95, 0.95, 1.0) if f > 0.5 else Color(1.0, 0.6, 0.2))
	# map: the guest in the middle, pointing up
	var c := _g(160.0, 314.0)
	var u := _g(0, 6).y
	panel.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -u), c + Vector2(u * 0.6, u * 0.6),
		c + Vector2(-u * 0.6, u * 0.6)]), Color(1, 1, 1))


# the lock: green corners around his target, where his camera sees it
# the host's name over his suit (and how far he is)
func _draw_mate() -> void:
	var cam := get_viewport().get_camera_3d()
	if host_pos == Vector3.ZERO or cam == null:
		return
	var top := host_pos + Vector3(0, 1.0, 0)
	if cam.is_position_behind(top):
		return
	var c := cam.unproject_position(top)
	var d := cam.global_position.distance_to(host_pos)
	var fs := int(clampf(root.size.y * 0.028, 12.0, 26.0))
	var t := "%s  %dm" % [mate_name, int(round(d * 10.0))]
	var w := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := c - Vector2(w / 2.0, 6.0)
	panel.draw_string_outline(font, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 4, Color.BLACK)
	panel.draw_string(font, p, t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.45, 0.85, 1.0))
	panel.draw_colored_polygon(PackedVector2Array([c + Vector2(-5, -2), c + Vector2(5, -2), c + Vector2(0, 5)]),
		Color(0.45, 0.85, 1.0))


func _draw_lock() -> void:
	var cam := get_viewport().get_camera_3d()
	if lock == 0 or cam == null or cam.is_position_behind(lock_pos):
		return
	var c := cam.unproject_position(lock_pos)
	var r := maxf(10.0, root.size.y * 0.03)
	var col := Color(0.3, 1.0, 0.35)
	for sx in [-1, 1]:
		for sy in [-1, 1]:
			var k := c + Vector2(sx * r, sy * r)
			panel.draw_line(k, k - Vector2(sx * r * 0.5, 0), col, 2.0)
			panel.draw_line(k, k - Vector2(0, sy * r * 0.5), col, 2.0)


func _map_follow() -> void:
	map_rect.position = _g(118.0, 260.0)
	map_rect.size = _g(202.0, 368.0) - _g(118.0, 260.0)
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var p := cam.global_position
	var fwd := -cam.global_transform.basis.z
	fwd.y = 0.0
	if fwd.length() < 0.01:
		fwd = Vector3.FORWARD
	map_cam.global_transform = Transform3D(Basis.looking_at(Vector3.DOWN, fwd.normalized()), p + Vector3.UP * 150.0)
