# Coop guest HUD (the second player's window, --coop-hud or --coop-guest). The host's live/coop_guest.py sends ~10
# packets a second to 127.0.0.1:47832: 'GHD' + <BhhHBBH: state (0 playing, 1 suit destroyed: next teammate in 3 s,
# 2 no teammate left: the host's view), armour, armour at pickup, entity, weapon slot (keys 1-4), weapon type, heading
# (game units), ... and at the end his pilot's health, his armour indicator's levels and place, the squad's pilots'
# health (coop_guest.py hud_more). And every 15 s 'GCK' + palette + zlib(index, alpha 320 x 400): the host's cockpit with his own panels
# emptied. With it the guest gets the game's cockpit filled with his own armour, weapon, compass and map, and the
# host's name and Steam avatar in the COMM panel (set_mate, from coop_net.gd), the game's crosshair and its armour
# indicator (in light blue). Before the first cockpit: a plain crosshair and armour bar. Online, the host window's coop_net.gd relays the packets over Steam and the guest's
# coop_net.gd forwards them here. Nothing is drawn when no packet came for 2 s.
extends CanvasLayer

const LGRes = preload("res://scripts/lgres.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
# the WEAPON panel's picture for each weapon type: the game's table at 0x35B27A (RESHLMHI.RES, 82 x 104-106, RLE),
# drawn from the guest's own game files in the game's palette (the cockpit packet's)
const WEAPON_PIC := [515, 516, 518, 507, 513, 508, 509, 511, 514, 510, 512, 519, 515, 517, 517, 520, 521, 522]

# the top bars' led cells in the game's screen: [x0, x1 (excluded), palette index lit], rows 30-33 (measured on the
# game's own bars, full); the left one 73-148, the right one (energy) 165-246, both lit pixel by pixel
const LEFT_LEDS := [[73, 75, 0x46], [76, 80, 0x46], [81, 85, 0x46], [86, 90, 0x46], [91, 95, 0x45], [96, 100, 0x45],
	[101, 105, 0x45], [106, 110, 0x45], [111, 115, 0x45], [116, 120, 0x44], [121, 125, 0x44], [126, 130, 0x43],
	[131, 135, 0x42], [136, 140, 0x41], [141, 145, 0x41], [146, 149, 0x40]]
const RIGHT_LEDS := [[165, 168, 0x83], [169, 172, 0x83], [173, 176, 0x84], [177, 180, 0x84], [181, 184, 0x85],
	[185, 188, 0x85], [189, 192, 0x86], [193, 196, 0x86], [197, 200, 0x87], [201, 204, 0x87], [205, 208, 0x88],
	[209, 212, 0x88], [213, 216, 0x88], [217, 220, 0x89], [221, 224, 0x89], [225, 228, 0x89], [229, 232, 0x8A],
	[233, 236, 0x8A], [237, 240, 0x8A], [241, 244, 0x8B], [245, 247, 0x8B]]

# the left top bar with its frame and tick rows (x 72-148, rows 26-37): the squad's bars in the COMM panel
const BAR_SRC := Rect2(72, 26, 77, 12)
# The guest's own colours. Energy: the game's green leds in orange, from its brightest (palette 0x83) to its dimmest
# (0x8B), and its "E" (on the cockpit picture: x 156-163, rows 24-37). Armour: light blue, on the game's armour
# indicator (RESHLMHI.RES 506: the game gives each part a level 0-6 and colours it green at 5-6, yellow at 3-4, red
# at 1-2, table 0x35a998; here light, middle and deep blue) and in the COMM bars.
const ENERGY_LIT := Color8(255, 165, 40)
const ENERGY_DIM := Color8(170, 95, 25)
const ENERGY_E := Rect2i(156, 24, 8, 14)
const ARMOUR_LIT := Color8(135, 200, 255)
const ARMOUR_DEEP := Color8(30, 70, 150)
const INDICATOR := 506
const INDICATOR_AT := Vector2i(211, 144)     # from the 3D window's corner, in the cockpit view (the host's says where)
const CROSS := 505                            # the game's cursors: the first is the crosshair, its tip at 6, 10
const CROSS_TIP := Vector2i(6, 10)

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
var energy := 100                     # his energy, % of the suit's max (+0x8A), as the game's panel bar (shots draw from it)
var entity := 0
var weapon_slot := 0
var weapon_type := 0
var heading := 0
var lock := 0                        # his locked unit (0: none) and its middle, the game's x, y, z
var lock_pos := Vector3.ZERO
var host_pos := Vector3.ZERO           # the host's suit (Godot units): his name above it
var guest_xy := Vector2.ZERO           # his own suit (game x, y): the map's centre
var squad := []                        # COMM panel: [entity, armour %, pilot] (the host first)
var squad_health := PackedByteArray()  # ... and each one's pilot's health, % (255 or none: not known)
var health := -1                       # his pilot's health, current and max (-1: the host's files do not send it)
var health_max := 1
var levels := PackedByteArray()        # his armour indicator: front, left, right, back, pilot (0-6); empty: not sent
var indicator_at := Vector2i(-1, -1)   # where the host's game draws it (-1: not seen)
var indicator_tex := {}                # levels -> texture
var indicator_idx := PackedByteArray() # its picture's palette indices (21 x 42)
var cross_tex: Texture2D               # the game's crosshair (false: its files have none)
var cross_tried := false
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
	map_cam.environment = get_parent().env_nofog()       # (high above the map: the live view's fog would cover it)
	map_cam.cull_mask = 0xFFFFF & ~(1 << 16)             # nor the haze of the ground (the viewer's NO_HAZE_LAYER)
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
	panel.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST   # the game's pixels (bars, portraits) kept crisp
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
				if so + 24 <= pk.size():
					health = pk.decode_u16(so + 8)
					health_max = maxi(1, pk.decode_u16(so + 10))
					levels = pk.slice(so + 12, so + 17)
					indicator_at = Vector2i(pk.decode_s16(so + 17), pk.decode_s16(so + 19))
					squad_health = pk.slice(so + 21, so + 24)
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
	# where that view looks, the window's middle (the viewer's _view_row)
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
	for y in range(ENERGY_E.position.y, ENERGY_E.end.y):     # the energy's "E": its greens in the leds' orange
		for x in range(ENERGY_E.position.x, ENERGY_E.end.x):
			var i := 4 * (320 * y + x)
			var gr := rgba[i + 1]
			if gr >= 96 and rgba[i] * 2 < gr and rgba[i + 2] * 2 < gr:
				var c := ENERGY_DIM.lerp(ENERGY_LIT, clampf((gr - 131.0) / 41.0, 0.0, 1.0))   # (its two greens: 131, 172)
				rgba[i] = c.r8
				rgba[i + 1] = c.g8
				rgba[i + 2] = c.b8
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
	if not big_map:
		_draw_indicator()
	if not looking:                                  # free look: no crosshair (his aim stays ahead)
		_draw_cross()
	# compass: 64 game pixels for 90 degrees, the heading at the strip's centre (the game's strip: x 33-288, y 6-21)
	var bearing := fposmod(360.0 - heading / 65536.0 * 360.0, 360.0)
	var amber := Color(1.0, 0.8, 0.25)
	for k in 8:
		var d := fposmod(k * 45.0 - bearing + 180.0, 360.0) - 180.0
		var x := 161.0 + d * 64.0 / 90.0
		if x < 38.0 or x > 284.0:
			continue
		if k % 2 == 0:
			_text(["N", "E", "S", "W"][k / 2], x, 8.0, 10.0, amber if k == 0 else Color(0.85, 0.85, 1.0), true)
		else:
			panel.draw_rect(_grect(x - 0.5, 11.0, x + 0.5, 16.0), Color(0.6, 0.6, 0.8))
	panel.draw_rect(_grect(160.0, 6.0, 162.0, 8.0), amber)
	panel.draw_rect(_grect(160.0, 20.0, 162.0, 22.0), amber)
	# the top bars, lit in the game's own led cells (the cockpit packet has them put out), each from its left end as
	# the game fills them (0x2652f4, 0x26541c: the lit bar, then black from the value to the bar's end): the pilot's
	# health on the left in the game's reds (its routine 0x2652a0: width x current / max, whole pixels), the energy on
	# the right from its "E", in orange
	var f := clampf(float(armour) / float(armour_max), 0.0, 1.0)
	var lw: int = LEFT_LEDS[LEFT_LEDS.size() - 1][1] - LEFT_LEDS[0][0]
	var rw: int = RIGHT_LEDS[RIGHT_LEDS.size() - 1][1] - RIGHT_LEDS[0][0]
	_draw_leds(LEFT_LEDS, 0, lw * clampi(health, 0, health_max) / health_max if health >= 0 else int(round(f * lw)), 0)
	_draw_leds(RIGHT_LEDS, 0, int(round(clampf(energy / 100.0, 0.0, 1.0) * rw)), 1)
	# COMM: his squad as the game lists it, in the game's rows: the host (Steam avatar, else his pilot's portrait),
	# then his other teammates (their portraits and names from his game files), each with one bar: the game's top
	# health bar, filled from the left with the pilot's health in red (half the bar when whole), then the suit's
	# armour in the indicator's light blue (the other half), the rest unlit
	var rows: Array = squad if not squad.is_empty() else [[0, 100, 255]]
	for i in rows.size():
		var y0 := 277.0 + 28.0 * i
		var who: Array = rows[i]
		var pic: Texture2D = mate_face if i == 0 and mate_face else _face(who[2])
		if pic:
			panel.draw_texture_rect(pic, _grect(18.0, y0, 39.0, y0 + 27.0), false)
		else:
			panel.draw_rect(_grect(18.0, y0, 39.0, y0 + 27.0), Color(0.05, 0.05, 0.1))
		var nm: String = mate_name if i == 0 else _pilot_name(who[2], who[0])
		_text(nm.to_upper(), 42.0, y0 + 2.0, 10.0, Color(1.0, 0.8, 0.2) if i == 0 else Color(0.9, 0.9, 0.95))
		var hp: float = squad_health[i] / 100.0 if i < squad_health.size() and squad_health[i] <= 100 else 1.0
		_draw_mini_bar(Rect2(42.0, y0 + 15.0, 55.0, 9.0), hp, who[1] / 100.0)
	if status_page:
		_draw_status()
	# WEAPON: his selected weapon, its picture under the texts where the game puts it
	var wpic := null if status_page else _weapon_pic(weapon_type)
	if wpic:
		panel.draw_texture_rect(wpic, _grect(217.0, 264.0, 217.0 + wpic.get_width(), 264.0 + wpic.get_height()), false)
	var wn: String = WEAPONS[weapon_type] if weapon_type < WEAPONS.size() else "?"
	if not status_page:
		_text(wn.to_upper(), 257.0, 267.0, 10.0, Color(0.95, 0.95, 1.0), true)
		_text("%d%%" % int(round(f * 100.0)), 219.0, 335.0, 10.0, Color(0.95, 0.95, 1.0))
		_text("FULLY OPERATIONAL" if f > 0.5 else "DAMAGED", 219.0, 353.0, 10.0,
			Color(0.95, 0.95, 1.0) if f > 0.5 else Color(1.0, 0.6, 0.2))
	_draw_map_units()
	# map: the guest in the middle, pointing up
	var c := _map_box().get_center()
	var u := _g(0, 6).y
	if big_map:
		_text("MAP  (M: back)", win.position.x + 16.0, win.position.y + 10.0, 10.0, Color(0.9, 0.9, 1.0))
	panel.draw_colored_polygon(PackedVector2Array([c + Vector2(0, -u), c + Vector2(u * 0.6, u * 0.6),
		c + Vector2(-u * 0.6, u * 0.6)]), Color(1, 1, 1))


# one top bar: its pixels from a to b (counted from its left end) lit, in the game's own led colours (kind 0), the
# energy's orange (1) or the armour's light blue (2)
# (dest: where the bar's source box BAR_SRC goes, in game units; none: in place, the top bar itself)
func _draw_leds(cells: Array, a: int, b: int, kind: int, dest := Rect2()) -> void:
	if hud_pal.is_empty():
		return
	var lo: int = cells[0][0]
	var k := Vector2.ONE if dest.size == Vector2.ZERO else dest.size / BAR_SRC.size
	var o := Vector2.ZERO if dest.size == Vector2.ZERO else dest.position - BAR_SRC.position * k
	for c in cells:
		var x0: int = maxi(c[0], lo + a)
		var x1: int = mini(c[1], lo + b)
		if x1 > x0:
			var col: Color = hud_pal[c[2]]
			if kind == 1:
				col = ENERGY_LIT.lerp(ENERGY_DIM, clampf((c[2] - 0x83) / 8.0, 0.0, 1.0))
			elif kind == 2:
				col = ARMOUR_LIT
			panel.draw_rect(_grect(o.x + x0 * k.x, o.y + 30.0 * k.y, o.x + x1 * k.x, o.y + 34.0 * k.y), col)


# a squadmate in the COMM panel: the game's own left top bar (its pixels from the cockpit picture, leds put out there)
# scaled into dest, lit from the left: his pilot's health hp in the game's reds, then his armour in light blue
func _draw_mini_bar(dest: Rect2, hp: float, arm: float) -> void:
	if cockpit.texture == null:
		return
	var r := _grect(dest.position.x, dest.position.y, dest.end.x, dest.end.y)
	panel.draw_texture_rect_region(cockpit.texture, r, BAR_SRC)
	var w: int = LEFT_LEDS[LEFT_LEDS.size() - 1][1] - LEFT_LEDS[0][0]
	var n := int(round(clampf(hp, 0.0, 1.0) * w / 2.0))
	_draw_leds(LEFT_LEDS, 0, n, 0, dest)
	_draw_leds(LEFT_LEDS, n, n + int(round(clampf(arm, 0.0, 1.0) * w / 2.0)), 2, dest)


func _helmet_frames(rid: int) -> Array:
	var vp := get_parent()
	if hl_res == null and vp and "data" in vp:
		hl_res = LGRes.open(vp.data.data_dir().path_join("RESHLMHI.RES"))
	return LGRes.frames(hl_res.data(rid)) if hl_res and hl_res.has(rid) else []


# the game's crosshair (its cursor in the 3D view, from his game files, in the game's palette) where the game keeps it
# in the look mode: its tip on the middle of the 3D window, 3 rows down (the bridge's centre()); that is where he aims
func _draw_cross() -> void:
	if not cross_tried and not hud_pal.is_empty():
		cross_tried = true
		var fr := _helmet_frames(CROSS)
		var img: Image = TNObjects._bitmap(fr[0], hud_pal) if fr.size() > 0 else null
		if img:
			cross_tex = ImageTexture.create_from_image(img)
	if cross_tex:
		var x := int(win.position.x) + int(win.size.x) / 2 - CROSS_TIP.x
		var y := int(win.position.y) + int(win.size.y) / 2 + 3 - CROSS_TIP.y
		panel.draw_texture_rect(cross_tex, _grect(x, y, x + cross_tex.get_width(), y + cross_tex.get_height()), false)
		return
	var cc := _g(win.position.x + win.size.x / 2.0, win.position.y + win.size.y * 0.5 + 2.0)
	for r in [Rect2(-12, -1, 8, 2), Rect2(4, -1, 8, 2), Rect2(-1, -12, 2, 8), Rect2(-1, 4, 2, 8)]:
		panel.draw_rect(Rect2(cc + r.position, r.size).grow(1), Color(0, 0, 0, 0.6))
		panel.draw_rect(Rect2(cc + r.position, r.size), Color(0.85, 1.0, 0.85, 0.9))


# his suit's armour indicator as the game draws the host's (0x2635c8, 0x2634b8), where the host's is: the picture's
# part colours 0xB0 + 16 k + ring (front, left, right, back; ring 0 the outer one) and 0xF0 (the pilot), a part at
# level n keeps its n inner rings; its dark outline as it is; the levels' colours in blue
func _draw_indicator() -> void:
	if levels.size() < 5 or hud_pal.is_empty():
		return
	var key := levels.hex_encode()
	if not indicator_tex.has(key):
		if indicator_idx.is_empty():
			var fr := _helmet_frames(INDICATOR)
			indicator_idx = TNObjects._bitmap_idx(fr[0]) if fr.size() > 0 else PackedByteArray([0])
			if fr.size() > 0 and indicator_idx.size() != fr[0].decode_u16(8) * fr[0].decode_u16(10):
				indicator_idx = PackedByteArray([0])
		var tex: Texture2D = null
		if indicator_idx.size() > 1:
			var w: int = _helmet_frames(INDICATOR)[0].decode_u16(8)
			var rgba := PackedByteArray()
			rgba.resize(indicator_idx.size() * 4)
			for p in indicator_idx.size():
				var c := indicator_idx[p]
				var col := hud_pal[c]
				var on := c != 0
				if c >= 0xB0 and c <= 0xF0:
					var part := mini((c - 0xB0) >> 4, 4)
					var lv := mini(levels[part], 6)
					on = lv > 0 and (part == 4 or (c & 15) >= 6 - lv)
					col = ARMOUR_LIT if lv >= 5 else (ARMOUR_LIT.lerp(ARMOUR_DEEP, 0.5) if lv >= 3 else ARMOUR_DEEP)
				rgba[4 * p] = col.r8
				rgba[4 * p + 1] = col.g8
				rgba[4 * p + 2] = col.b8
				rgba[4 * p + 3] = 255 if on else 0
			tex = ImageTexture.create_from_image(Image.create_from_data(w, indicator_idx.size() / w, false, Image.FORMAT_RGBA8, rgba))
		if indicator_tex.size() > 64:
			indicator_tex.clear()
		indicator_tex[key] = tex
	var t: Texture2D = indicator_tex[key]
	if t == null:
		return
	var at := indicator_at if indicator_at.x >= 0 else Vector2i(win.position) + INDICATOR_AT
	panel.draw_texture_rect(t, _grect(at.x, at.y, at.x + t.get_width(), at.y + t.get_height()), false)


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


# the lock: green corners around his target, where his camera sees it
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
	_text("STATUS", 257.0, 267.0, 10.0, Color(0.95, 0.95, 1.0), true)
	for k in 4:
		var t: int = slot_types[k]
		var nm: String = WEAPONS[t] if t < WEAPONS.size() and t > 0 else "-"
		var sel := k == weapon_slot
		_text("%d %s" % [k + 1, nm.to_upper()], 219.0, 284.0 + 13.0 * k, 10.0,
			Color(0.4, 1.0, 0.45) if sel else Color(0.75, 0.78, 0.9))
	_text("JUMP %s" % ("READY" if jump_ready else "..."), 219.0, 337.0, 10.0,
		Color(0.4, 1.0, 0.45) if jump_ready else Color(1.0, 0.7, 0.25))
	_text("LOCK %s" % ("#%d" % lock if lock else "-"), 219.0, 351.0, 10.0,
		Color(0.4, 1.0, 0.45) if lock else Color(0.75, 0.78, 0.9))


func toggle_map() -> void:
	big_map = not big_map


func _map_box() -> Rect2:
	if big_map and win.size.y > 0:
		return _grect(win.position.x + 12.0, win.position.y + 8.0, win.end.x - 12.0, win.end.y - 8.0)
	return _grect(118.0, 264.0, 204.0, 372.0)


func _rear_follow() -> void:
	var cam := get_viewport().get_camera_3d()
	rear_rect.visible = cockpit.visible and state == 0 and cam != null
	if not rear_rect.visible:
		return
	rear_rect.position = _g(146.0, 226.0)
	rear_rect.size = _g(172.0, 252.0) - _g(146.0, 226.0)
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
