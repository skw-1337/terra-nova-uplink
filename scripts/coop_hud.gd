# Coop guest HUD (the second player's window, --coop-hud or --coop-guest). The host's live/coop_guest.py sends ~10
# packets a second to 127.0.0.1:47832: 'GHD' + <BhhHBBH: state (0 playing, 1 suit destroyed: next teammate in 3 s,
# 2 no teammate left: the host's view), armour, armour at pickup, entity, weapon slot (keys 1-4), weapon type, heading
# (game units), ... and at the end his pilot's health, his armour indicator's levels and place, the squad's pilots'
# health (coop_guest.py hud_more). And every 15 s 'GCK' + palette + zlib(index, alpha 320 x 400): the host's cockpit with his own panels
# emptied. With it the guest gets the game's cockpit filled with his own armour, weapon, compass and map, and the
# host's name and Steam avatar in the COMM panel (set_mate, from coop_net.gd), the game's crosshair and its armour
# indicator (light blue, its damaged parts in the game's yellow and red). Before the first cockpit: a plain crosshair and armour bar. Online, the host window's coop_net.gd relays the packets over Steam and the guest's
# coop_net.gd forwards them here. Nothing is drawn when no packet came for 2 s.
# The map panel is the game's own picture of the ground (_ground: its colour tables, a pixel a world unit, north up)
# with the marks the host's game would draw for him ('GHD' ends with them, coop_guest.py map_block), and the small box
# over it shows his weapon as the game's does (TN_GUEST_REAR=1: the rear view Uplink had there before).
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
# (0x8B), and its "E" (on the cockpit picture: x 156-163, rows 24-37). Armour: light blue, in the COMM bars and on
# the game's armour indicator (RESHLMHI.RES 506: the game gives each part a level 0-6 and one colour of its palette
# by level, table 0x35a998: 0x84 green at 5-6, 0x4E yellow at 3-4, 0x44 red at 1-2). A whole part (5-6) is light blue
# here, a damaged one keeps the game's warning colours.
const ENERGY_LIT := Color8(255, 165, 40)
const ENERGY_DIM := Color8(170, 95, 25)
const ENERGY_E := Rect2i(156, 24, 8, 14)
const ARMOUR_LIT := Color8(135, 200, 255)
const ARMOUR_WARN: Array[int] = [0, 0x44, 0x44, 0x4E, 0x4E]   # levels 1-4: the game's red, red, yellow, yellow (palette)
const INDICATOR := 506
const INDICATOR_AT := Vector2i(211, 144)     # from the 3D window's corner, in the cockpit view (the host's says where)
const CROSS := 505                            # the game's cursors: the first is the crosshair, its tip at 6, 10
const CROSS_TIP := Vector2i(6, 10)

# The small box over the map (the game's region at 146, 226, 26 x 26; its routine 0x265094): RESHLMHI.RES 535, a
# frame for each weapon type (the game's table at 0x35A9BC)
const BOX_PICS := 535
const BOX_FRAME := [8, 9, 11, 0, 6, 1, 2, 4, 7, 3, 5, 12, 8, 10, 10, 13, 14, 15]
const BOX := Rect2i(146, 226, 26, 26)
# The map panel (the game's region 118, 264 - 202, 372; its routine 0x2774c0): a pixel for a world unit, two screen
# rows for one; a point's colour = RESPLNT 54 [light, RESPLNT 71 [material (RESPLNT 43) of its tile, its height]],
# the light from the slope towards the next point east through the game's table at 0x35B3F2 (mission 8: 0x35B432)
const MAP_BOX := Rect2i(118, 264, 84, 108)
const MAP_LIGHT := "02020202020202020202020202020202030303030303030304040404040404040405050505060606060606060707070707070606060606060505050505050404"
const MAP_LIGHT_8 := "04040404040404040404040404040404040404040404040404040404040404040505050505050505050505050505050505050505050505050505050505050505"
enum { M_CROSS, M_SELF, M_SHAPE, M_WAYPOINT, M_NAV, M_RECT, M_ROUND, M_TEXT, M_MATE }   # the marks' kinds (coop_guest.py)

const LOCK_SOUND := 2021                     # the game's sound when its player locks a target (0x262BBF)
const LOCK_SEEN := 2028                      # ... and when it first draws the new target's box (0x26A309)
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
var lock_info := PackedByteArray()     # what the host's bridge says of his target: armour %, beyond range, metres
var lock_heard := 0                  # (his lock in the last packet: a new one sounds)
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
var ground: Image                    # the map: the game's picture of the whole ground (513 x 513, a pixel a unit)
var ground_of := ""                  # ... of which map file
var map_img: Image                   # the panel's picture: the ground around him and the marks
var map_tex: ImageTexture
var map_dirty := true
var big_font := PackedByteArray()     # the game's small HUD letters, for the panel (the lock's lines)
var note_font := PackedByteArray()    # the game's small letters (the map's written notes)
var pal_map := ""                    # the map file the palette was taken with (another planet: other ground colours)
var map_from := Vector2i.ZERO        # its top left corner in the world, and the world units of a pixel
var map_step := 1
var map_marks := []                  # the marks the host's game would draw: [kind, palette colour, payload]
var map_told := false                # the host sends them (an older host: the squad from the view's entities)
# His own map marker (the host's is the game's nav marker): a click on his map with the mouse free puts it there, a
# click on it or the right button on the map takes it away. His window only asks ('W' + world x, y to the host's
# bridge, again while the answer differs, for 3 s); what is drawn is what the bridge says back in the map's marks.
var own_mark := Vector2.ZERO          # as the host's bridge says it (x = 0: none)
var mark_want := Vector2.ZERO         # what he last asked for, when, and when it was last sent
var mark_want_t := -100.0
var mark_sent_t := -100.0
var weapon_state := 0                # his weapon: 0 ready, 1 destroyed, 2 no ammunition, 5 not ready yet
var weapon_ammo := 0xFFFF            # its ammunition (0xFFFF: a weapon that counts none)
var tints := [PackedByteArray(), PackedByteArray()]   # the game's colour tables for states 1-2 and 5
var box_pics := {}                   # weapon type and table -> the small box's texture
var status_page := false             # Tab (or the STATUS tab with the mouse free): his weapon slots, jump, lock
var slot_types := PackedByteArray([0, 0, 0, 0])
var jump_ready := true
var rear_on := OS.get_environment("TN_GUEST_REAR") == "1"   # the small box as a rear view instead of his weapon
var rear_view: SubViewport            # the rear view (TN_GUEST_REAR=1)
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
var sound: Node                      # the game's sounds at his place ('SND' packets, coop_sound.gd)

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
	if rear_on:
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
		elif tag == "SND":
			if sound == null:
				sound = preload("res://scripts/coop_sound.gd").new()
				add_child(sound)
			sound.feed(pk)
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
					_map_packet(pk, so + 24)
			if pk.size() >= 52:
				host_pos = Vector3(pk.decode_float(40), pk.decode_float(48) - 0.12, pk.decode_float(44))
			if pk.size() >= 28:
				lock = pk.decode_u16(14)
				if lock != 0 and lock != lock_heard:
					if sound == null:
						sound = preload("res://scripts/coop_sound.gd").new()
						add_child(sound)
					sound.play_own(LOCK_SOUND, 64)                    # (the game's two lock sounds, at their volume:
					sound.play_own(LOCK_SEEN, 64)                     # set, 0x262BBF; first drawn, 0x26A309)
				lock_heard = lock
				lock_info = PackedByteArray()
				if lock != 0 and pk.size() >= 7 and pk.slice(pk.size() - 7, pk.size() - 4).get_string_from_ascii() == "LCK":
					lock_info = pk.slice(pk.size() - 4)                   # (armour %, beyond range, metres: lock_info)
				lock_pos = Vector3(pk.decode_float(16), pk.decode_float(24) - 0.12, pk.decode_float(20))   # Godot: x, up, y
			last = clock
			got = true
			map_dirty = true
	root.visible = clock - last < TIMEOUT
	if clock - mark_want_t < 3.0 and clock - mark_sent_t > 0.4 and (own_mark - mark_want).length() > 0.05:
		_mark_ask()                                           # (asked and not answered yet)
	if not root.visible and own_mark.x != 0.0:
		own_mark = Vector2.ZERO                               # (the host is gone: his marker with it)
		if get_parent().has_method("mate_marker"):
			get_parent().mate_marker(Vector2.ZERO)
	if got and root.visible:
		_update()
	if root.visible:
		if map_dirty and cockpit.visible and state == 0:
			_map_paint()
		if rear_on:
			_rear_follow()
		panel.visible = true
		panel.queue_redraw()


func _update() -> void:
	var ck := cockpit.texture != null
	cross.visible = state == 0 and not ck
	bottom.visible = state == 0 and not ck
	cockpit.visible = ck
	panel.visible = ck
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
	var map_now := str(vp.current.get("map_path", "")) if vp and "current" in vp else ""
	if hud_pal.is_empty() or map_now != pal_map:             # (the game's palette changes with the planet)
		pal_map = map_now
		hud_pal.clear()
		for i in 256:
			hud_pal.append(Color8(pal[3 * i], pal[3 * i + 1], pal[3 * i + 2]))
		weapon_pics.clear()
		box_pics.clear()
		faces.clear()
		indicator_tex.clear()
		cross_tried = false
		cross_tex = null
		ground_of = ""
		map_dirty = true
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


# the end of a 'GHD' packet (coop_guest.py map_block): 'M', flags (bit 0: the weapon box's two colour tables follow),
# his weapon's state and ammunition, the number of marks, then the marks: kind, colour, payload length, payload
func _map_packet(pk: PackedByteArray, at: int) -> void:
	if at + 6 > pk.size() or pk[at] != 0x4D:
		return
	var p := at + 6
	if pk[at + 1] & 1:
		if p + 512 > pk.size():
			return
		var t := [pk.slice(p, p + 256), pk.slice(p + 256, p + 512)]
		if t != tints:
			tints = t
			box_pics.clear()
		p += 512
	weapon_state = pk[at + 2]
	weapon_ammo = pk.decode_u16(at + 3)
	var marks := []
	for i in pk[at + 5]:
		if p + 3 > pk.size() or p + 3 + pk[p + 2] > pk.size():
			break
		marks.append([pk[p], pk[p + 1], pk.slice(p + 3, p + 3 + pk[p + 2])])
		p += 3 + pk[p + 2]
	map_marks = marks
	map_told = true
	var mine := Vector2.ZERO
	for m in marks:
		if m[0] == M_MATE and m[2].size() >= 4:
			mine = Vector2(m[2].decode_u16(0), m[2].decode_u16(2)) / 64.0
	if mine != own_mark:
		own_mark = mine
		var vp := get_parent()
		if vp and vp.has_method("mate_marker"):
			vp.mate_marker(mine)                            # (and in the 3D, as the host's)


# The game's picture of the whole ground, as its map panels draw it (0x2774c0), from his own game files in the
# game's palette: 513 x 513, a pixel for a point of the map. Null: no map yet, or files without the tables.
# Not done: the picture a few missions lay over a part of their map (the game's resource 0x18C + mission).
func _ground() -> Image:
	var vp := get_parent()
	if vp == null or not ("current" in vp) or hud_pal.is_empty():
		return null
	var cur: Dictionary = vp.current
	var path := str(cur.get("map_path", ""))
	if path != pal_map:
		return null                                          # (the palette of the map before: wait for this one's)
	if path == ground_of:
		return ground
	ground_of = path
	ground = null
	if path == "":
		return null
	var mission := str(cur["entry"]["file"]).get_file().to_upper().trim_prefix("MISS").to_int()
	var m = LGRes.open(path)
	var pl = LGRes.open(vp.data.resolve(cur["entry"]["file"], str(cur["map"].get("planet", ""))))
	if m == null or pl == null or not m.has(86) or not pl.has(43) or not pl.has(71) or not pl.has(54):
		return null
	var d: PackedByteArray = m.data(86)
	var material: PackedByteArray = pl.data(43)
	var by_height: PackedByteArray = pl.data(71)
	var lit: PackedByteArray = pl.data(54)
	const N := 513 * 513
	if d.size() < N * 3 or material.size() < 64 or by_height.size() < 4096 or lit.size() < 2048:
		return null
	var light := (MAP_LIGHT_8 if mission == 8 else MAP_LIGHT).hex_decode()
	var rgba := PackedByteArray()
	rgba.resize(N * 4)
	rgba.fill(255)
	var h := (d[2] << 4) | (d[1] >> 4)                       # 12-bit heights, signed
	h = h - 4096 if h >= 2048 else h
	for i in N:
		var east := h
		if i + 1 < N:
			east = (d[3 * i + 5] << 4) | (d[3 * i + 4] >> 4)
			east = east - 4096 if east >= 2048 else east
		var c := 0
		if mission != 29:                                    # (mission 29: the game leaves its map black)
			var lv := light[clampi(((h - east + 8192) >> 1) - 4096 + 32, 0, 63)]
			c = lit[lv * 256 + by_height[(material[d[3 * i] & 0x3F] & 15) * 256 + ((h + 0x800) >> 4)]]
		var col := hud_pal[c]
		rgba[4 * i] = col.r8
		rgba[4 * i + 1] = col.g8
		rgba[4 * i + 2] = col.b8
		h = east
	ground = Image.create_from_data(513, 513, false, Image.FORMAT_RGBA8, rgba)
	return ground


# the map picture's size, in the game's pixels: the panel's, or (M) the 3D window's
func _map_size() -> Vector2i:
	if big_map and win.size.y > 0:
		return Vector2i(int(win.size.x) - 24, (int(win.size.y) - 16) & ~1)
	return MAP_BOX.size


func _map_box() -> Rect2:
	if big_map and win.size.y > 0:
		var sz := _map_size()
		return _grect(win.position.x + 12.0, win.position.y + 8.0, win.position.x + 12.0 + sz.x, win.position.y + 8.0 + sz.y)
	return _grect(MAP_BOX.position.x, MAP_BOX.position.y, MAP_BOX.end.x, MAP_BOX.end.y)


# a place of the world (1/64 units, two words of a mark) -> its pixel of the map picture, as the game's (a screen
# row is half a pixel)
func _map_at(d: PackedByteArray, o: int, plus := Vector2i.ZERO) -> Vector2i:
	if o + 4 > d.size():
		return Vector2i(-99, -99)
	var w := Vector2(d.decode_u16(o) + plus.x, d.decode_u16(o + 2) + plus.y) / 64.0
	return Vector2i(floori((w.x - map_from.x) / map_step), floori((w.y - map_from.y) * 2.0 / map_step))


func _dot(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, c)


func _line(img: Image, a: Vector2i, b: Vector2i, c: Color) -> void:
	var n := maxi(absi(b.x - a.x), absi(b.y - a.y))
	if n > 2000:
		return
	for i in n + 1:
		var t := float(i) / maxf(n, 1.0)
		_dot(img, roundi(lerpf(a.x, b.x, t)), roundi(lerpf(a.y, b.y, t)), c)


# a unit's mark as the game's (0x277bac, its 400-row screen): 3 pixels across, 5 rows down
func _cross(img: Image, p: Vector2i, c: Color, rows := 2) -> void:
	for k in range(-1, 2):
		_dot(img, p.x + k, p.y, c)
	for k in range(-rows, rows + 1):
		_dot(img, p.x, p.y + k, c)


# The map panel's picture: the ground around him (north up, him in the middle, kept inside the map: 0x2779a0) and the
# marks the host's game would draw for him, in its order: the mission's notes, the squad's contacts (a building: its
# outline), himself with a line where he faces (6 pixels), the squad's waypoints, the nav marker (0x276ef8).
func _map_paint() -> void:
	map_dirty = false
	var size := _map_size()
	if size.x < 8 or size.y < 8:
		return
	map_step = 2 if big_map else 1                           # world units a pixel (the game's zooms 2 and 4)
	var span := Vector2i(size.x * map_step, size.y / 2 * map_step)
	map_from = Vector2i(clampi(floori(guest_xy.x) - span.x / 2, 0, maxi(0, 512 - span.x)),
			clampi(floori(guest_xy.y) - span.y / 2, 0, maxi(0, 512 - span.y)))
	var img := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color.BLACK)
	var g := _ground()
	if g != null:
		var part := Image.create_empty(span.x, span.y, false, Image.FORMAT_RGBA8)
		part.fill(Color.BLACK)
		part.blit_rect(g, Rect2i(map_from, span), Vector2i.ZERO)
		part.resize(size.x, size.y, Image.INTERPOLATE_NEAREST)
		img = part
	var pal := hud_pal
	for m in map_marks:
		var d: PackedByteArray = m[2]
		var c: Color = pal[m[1]] if not pal.is_empty() else Color.WHITE
		var p := _map_at(d, 0)
		match m[0]:
			M_CROSS:
				_cross(img, p, c)
			M_SELF:
				_cross(img, p, c)
				var a := heading / 65536.0 * TAU
				_line(img, p, p + Vector2i(roundi(6.0 * cos(a)), roundi(12.0 * sin(a))), c)
			M_SHAPE:
				for k in range(0, d.size() - 3, 4):
					_line(img, _map_at(d, k), _map_at(d, (k + 4) % (d.size() & ~3)), c)
			M_WAYPOINT:
				_frame(img, p - Vector2i(2, 2), p + Vector2i(1, 1), c)
			M_NAV:
				_cross(img, p, ENERGY_LIT, 1)                   # the host's marker, in his colour
			M_MATE:
				_cross(img, p, ARMOUR_LIT, 1)                   # his own
			M_RECT, M_ROUND, M_TEXT:
				if d.size() < 8:
					continue
				var q := _map_at(d, 0, Vector2i(d.decode_u16(4), d.decode_u16(6)))
				if m[0] == M_RECT:
					_frame(img, p, q, c)
				elif m[0] == M_ROUND:
					var r := (q.x - p.x) / 2.0
					for k in 64:
						_dot(img, roundi((p.x + q.x) / 2.0 + r * cos(k * TAU / 64.0)), roundi((p.y + q.y) / 2.0 + r * sin(k * TAU / 64.0)), c)
				else:
					_write(img, p, d.slice(8), c)
	if not map_told:                                         # an older host: the squad from the view's entities
		_map_squad(img)
	map_img = img
	if map_tex == null or Vector2i(map_tex.get_size()) != size:
		map_tex = ImageTexture.create_from_image(img)
	else:
		map_tex.update(img)


# a note's letters in the game's small font (RESHLMHI.RES 503: first and last letter at +36, +38, the bits at the
# offset of +76 in rows of +80 bytes, +82 rows high, each letter's first column from +84), its top left corner at p
func _letters() -> PackedByteArray:
	if note_font.is_empty():
		_helmet_frames(0)
		note_font = hl_res.data(503) if hl_res and hl_res.has(503) else PackedByteArray([0])
	return note_font


# how wide a text is in those letters
func _written(text: PackedByteArray) -> int:
	var f := _letters()
	var n := 0
	for ch in text:
		var k := ch - (f.decode_s16(36) if f.size() >= 88 else 0)
		if f.size() >= 88 and k >= 0 and 88 + 2 * k <= f.size():
			n += f.decode_s16(86 + 2 * k) - f.decode_s16(84 + 2 * k)
	return n


func _write(img: Image, p: Vector2i, text: PackedByteArray, c: Color) -> void:
	var f := _letters()
	if f.size() < 88:
		return
	var first := f.decode_s16(36)
	var bits := f.decode_s32(76)
	var row := f.decode_s16(80)
	var x := p.x
	for ch in text:
		if ch < first or ch > f.decode_s16(38) or 86 + 2 * (ch - first) + 2 > f.size():
			continue
		var a := f.decode_s16(84 + 2 * (ch - first))
		var b := f.decode_s16(86 + 2 * (ch - first))
		for yy in f.decode_s16(82):
			for xx in range(a, b):
				var at := bits + yy * row + (xx >> 3)
				if at < f.size() and f[at] & (0x80 >> (xx & 7)):
					_dot(img, x + xx - a, p.y + yy, c)
		x += b - a


# a box's outline, corners included
func _frame(img: Image, a: Vector2i, b: Vector2i, c: Color) -> void:
	_line(img, a, Vector2i(b.x, a.y), c)
	_line(img, Vector2i(a.x, b.y), b, c)
	_line(img, a, Vector2i(a.x, b.y), c)
	_line(img, Vector2i(b.x, a.y), b, c)


# without the host's marks: his squad and the other suits from the entities of the view (teammates green, the host
# blue, others red), and himself in white
func _map_squad(img: Image) -> void:
	var vp := get_parent()
	if vp == null or not ("live_ents" in vp) or guest_xy == Vector2.ZERO:
		return
	var host_e: int = squad[0][0] if not squad.is_empty() else -1
	var mates := {}
	for w in squad:
		mates[w[0]] = true
	var me := Vector2i.ZERO
	for idx in vp.live_ents:
		var e: Array = vp.live_ents[idx]
		if e[0] < 1 or e[0] > 3 or e[2] == 0:
			continue
		var p := Vector2i(floori((e[3] - map_from.x) / map_step), floori((e[4] - map_from.y) * 2.0 / map_step))
		if idx == entity:
			me = p
		else:
			_cross(img, p, Color(0.4, 0.8, 1.0) if idx == host_e else (Color(0.3, 1.0, 0.35) if mates.has(idx) else Color(1.0, 0.3, 0.25)))
	if me == Vector2i.ZERO:
		me = Vector2i(floori((guest_xy.x - map_from.x) / map_step), floori((guest_xy.y - map_from.y) * 2.0 / map_step))
	var a := heading / 65536.0 * TAU
	_cross(img, me, Color.WHITE)
	_line(img, me, me + Vector2i(roundi(6.0 * cos(a)), roundi(12.0 * sin(a))), Color.WHITE)


# The small box over the map: his weapon's picture as the game's box shows the player's (0x265094), through the game's
# colour table when it cannot fire (table 0: destroyed or out of ammunition, 1: not ready yet; -1: as it is), then its
# ammunition in the game's small letters, grey (palette 0x22), in the lower right corner
func _box_pic(t: int, table: int, ammo := 0xFFFF) -> Texture2D:
	var key := (t * 4 + table + 1) * 65536 + ammo
	if box_pics.has(key):
		return box_pics[key]
	if box_pics.size() > 64:
		box_pics.clear()
	var tex: Texture2D = null
	if t < BOX_FRAME.size() and not hud_pal.is_empty():
		var fr := _helmet_frames(BOX_PICS)
		var f: PackedByteArray = fr[BOX_FRAME[t]] if BOX_FRAME[t] < fr.size() else PackedByteArray()
		var idx := TNObjects._bitmap_idx(f)
		if not idx.is_empty():
			var through: PackedByteArray = tints[table] if table >= 0 and tints[table].size() == 256 else PackedByteArray()
			var rgba := PackedByteArray()
			rgba.resize(idx.size() * 4)
			for p in idx.size():
				var col := hud_pal[through[idx[p]] if not through.is_empty() else idx[p]]
				rgba[4 * p] = col.r8
				rgba[4 * p + 1] = col.g8
				rgba[4 * p + 2] = col.b8
				rgba[4 * p + 3] = 255
			var w := f.decode_u16(8)
			var img := Image.create_from_data(w, idx.size() / w, false, Image.FORMAT_RGBA8, rgba)
			if ammo != 0xFFFF:
				var digits := str(ammo).to_ascii_buffer()
				_write(img, Vector2i(img.get_width() - _written(digits), img.get_height() - 12), digits, hud_pal[0x22])
			tex = ImageTexture.create_from_image(img)
	box_pics[key] = tex
	return tex


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


# why his keys or his mouse do nothing just now, in a line over the bottom of his view (nothing: they are taken)
func _input_notice() -> String:
	var vp := get_parent()
	if vp == null or not ("play_started" in vp) or state != 0:
		return ""
	if not get_window().has_focus():
		return "CLICK IN THIS WINDOW: IT DOES NOT HAVE THE KEYBOARD"
	if not vp.play_started:
		return "CLICK TO TAKE THE MOUSE AND PLAY"
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return "MOUSE FREE (MAP, BUTTONS)   %s: BACK TO THE LOOK" % OS.get_keycode_string(vp.look_key)
	return ""


func _draw_panel() -> void:
	if state != 0:
		return
	var notice := _input_notice()
	if notice != "":
		var wy := win.position.y + win.size.y * 0.8 if win.size.y > 0 else 200.0
		_text(notice, 160.0, wy, 10.0, Color(1.0, 0.8, 0.25), true)
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
	# compass: 64 game pixels for 90 degrees, the heading at the strip's centre (the game's strip: x 33-288, y 6-21);
	# the game's heading 0 is east and grows towards the south (its map: x to the east, y to the south)
	var bearing := fposmod(heading / 65536.0 * 360.0 + 90.0, 360.0)
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
	if map_tex:
		panel.draw_texture_rect(map_tex, _map_box(), false)
	if big_map:
		_text("MAP  (M: back)", win.position.x + 16.0, win.position.y + 10.0, 10.0, Color(0.9, 0.9, 1.0))
	# the small box over the map: his weapon, as the game's
	if not rear_on:
		var bp := _box_pic(weapon_type, 0 if weapon_state in [1, 2] else (1 if weapon_state in [4, 5] else -1), weapon_ammo)
		if bp:
			panel.draw_texture_rect(bp, _grect(BOX.position.x, BOX.position.y, BOX.end.x, BOX.end.y), false)


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
# level n keeps its n inner rings; its dark outline as it is; a whole part (levels 5-6) in light blue where the game
# has green, a damaged one in the game's yellow (3-4) or red (1-2)
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
					col = ARMOUR_LIT if lv >= 5 else hud_pal[ARMOUR_WARN[lv]]
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


# A point of the world on the screen. Not Camera3D.unproject_position: with the cockpit's camera (the viewer's
# _hud_camera, a frustum given by its width) Godot takes the frustum's size for its height, so a unit seen 512 pixels
# left of the middle came back 288 pixels left of it: the host's name and the lock's corners slid towards the middle
# of the window, away from the suit they belong to. The viewer's own projection (_order_pixel) is used instead.
func _pixel(cam: Camera3D, p: Vector3) -> Vector2:
	var vp := get_parent()
	if vp != null and vp.has_method("_order_pixel") and vp.get("camera") == cam:
		return vp._order_pixel(p)
	return cam.unproject_position(p)


# the host's name over his suit (and how far he is)
func _draw_mate() -> void:
	var cam := get_viewport().get_camera_3d()
	if host_pos == Vector3.ZERO or cam == null:
		return
	var n := _drawn(host_ent)                  # the suit as drawn (20 views a second); these packets come ~twice a second
	var top := (n.global_position if n else host_pos) + Vector3(0, 0.72, 0)   # just over his head (a suit stands ~0.6)
	if cam.is_position_behind(top):
		return
	var c := _pixel(cam, top)
	var fs := int(clampf(root.size.y * 0.028, 12.0, 26.0))
	if win.size.y > 0 and not _grect(win.position.x, win.position.y, win.end.x, win.end.y).grow_individual(0, -fs - 6.0, 0, 0).has_point(c):
		return                                               # (not over the cockpit around the 3D window: its compass, its panels)
	var d := cam.global_position.distance_to(top)
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


# His target, drawn as the game marks its player's (the game's screen units; read from its code):
# - brackets (0x26A380): around the middle of the target on the screen, x - 5 to x + 5, y - 9 to y + 8 (the 400-row
#   screen), each corner a quarter of the box's width and of its height (2 at least), in the game's green (0x84);
# - under it (0x26A7C8), 12 rows below the middle: its armour, a bar from x - 6 to x + 6 in green, the part lost in red
#   (0x44) from its right end, a white (0x1D) dot at each end;
# - beside it, from x + 12 and 5 rows above the middle, in the game's small letters (RESHLMHI.RES 503) and its red
#   (0x44): what it is (a word a line), a blank line, its distance ("%d m", the game's metres), a blank line, then
#   "LOCKED", or "Out of" "Range" when it is beyond his weapon's range (the game's own texts, RESGAME.RES 369 / 370).
# The host's bridge says the armour, the range and the distance (lock_info). Not drawn: the game's target camera.
func _draw_lock() -> void:
	var cam := get_viewport().get_camera_3d()
	if lock == 0 or cam == null or hud_pal.size() < 256:
		return
	var n := _drawn(lock)
	var at := n.global_position + Vector3(0, 0.35, 0) if n else lock_pos   # its middle, as the bridge's lock_pos
	if cam.is_position_behind(at):
		return
	var c := _pixel(cam, at)
	var cx := floorf(c.x * 320.0 / root.size.x)
	var cy := floorf(c.y * 400.0 / root.size.y)
	var green: Color = hud_pal[0x84]
	var red: Color = hud_pal[0x44]
	var white: Color = hud_pal[0x1D]
	# the brackets
	var x0 := cx - 5.0
	var x1 := cx + 5.0
	var y0 := cy - 9.0
	var y1 := cy + 8.0
	var aw := maxf(2.0, floorf((x1 - x0) / 4.0))
	var ah := maxf(2.0, floorf((y1 - y0) / 4.0))
	for corner in [[x0, y0, 1, 1], [x1, y0, -1, 1], [x0, y1, 1, -1], [x1, y1, -1, -1]]:
		var px: float = corner[0]
		var py: float = corner[1]
		_gline(px, py, px + corner[2] * aw, py, green)
		_gline(px, py, px, py + corner[3] * ah, green)
	# the armour bar
	var arm: int = lock_info[0] if lock_info.size() >= 4 else 100
	var by := cy + 12.0
	_gline(cx - 7.0, by, cx - 7.0, by, white)
	_gline(cx + 7.0, by, cx + 7.0, by, white)
	_gline(cx - 6.0, by, cx + 6.0, by, green)
	var keep := maxi(1, arm * 12 / 100)
	if keep < 12:
		_gline(cx - 6.0 + keep, by, cx + 6.0, by, red)
	# the text
	var name := "Unknown"
	var vp := get_parent()
	if vp and "live_ents" in vp and vp.live_ents.has(lock) and "data" in vp:
		var e: Array = vp.live_ents[lock]
		name = vp.data.type_name(e[0], e[1])
	var metres: int = lock_info.decode_u16(2) if lock_info.size() >= 4 else int(round(cam.global_position.distance_to(at) * 6.0))
	var far := lock_info.size() >= 4 and lock_info[1] != 0
	var lines: Array = Array(name.to_upper().split(" ", false)) + ["", "%d M" % metres, ""] + (["OUT OF", "RANGE"] if far else ["LOCKED"])
	var y := cy - 5.0
	for t in lines:
		_glyphs(str(t), cx + 12.0, y, red)
		y += 12.0


# a line of the game's screen, a game pixel thick, from (ax, ay) to (bx, by), ends included
func _gline(ax: float, ay: float, bx: float, by: float, col: Color) -> void:
	panel.draw_rect(_grect(minf(ax, bx), minf(ay, by), maxf(ax, bx) + 1.0, maxf(ay, by) + 1.0), col)


# a text in the game's small HUD letters (RESHLMHI.RES 503, as _write's), drawn at x, y of the game's screen
func _glyphs(text: String, x: float, y: float, col: Color) -> void:
	if big_font.is_empty():
		_helmet_frames(0)
		big_font = hl_res.data(503) if hl_res and hl_res.has(503) else PackedByteArray([0])
	var f := big_font
	if f.size() < 88 or text == "":
		return
	var first := f.decode_s16(36)
	var bits := f.decode_s32(76)
	var row := f.decode_s16(80)
	var h := f.decode_s16(82)
	for ch in text.to_ascii_buffer():
		if ch < first or ch > f.decode_s16(38) or 88 + 2 * (ch - first) > f.size():
			continue
		var a := f.decode_s16(84 + 2 * (ch - first))
		var b := f.decode_s16(86 + 2 * (ch - first))
		for yy in h:
			for xx in range(a, b):
				var at := bits + yy * row + (xx >> 3)
				if at < f.size() and f[at] & (0x80 >> (xx & 7)):
					panel.draw_rect(_grect(x + xx - a, y + yy, x + xx - a + 1, y + yy + 1), col)
		x += b - a


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


# the mouse free, a button pressed at a place of the window: true if it was on his map (his marker's, see own_mark)
func map_click(at: Vector2, right: bool) -> bool:
	var box := _map_box()
	if not cockpit.visible or state != 0 or map_tex == null or not map_told or not box.has_point(at):
		return false
	var px := (at - box.position) / box.size * Vector2(map_tex.get_size())
	var w := Vector2(map_from) + Vector2(px.x, px.y / 2.0) * map_step
	var on_it := own_mark.x != 0.0 and absf(w.x - own_mark.x) <= 2.0 * map_step and absf(w.y - own_mark.y) <= 2.0 * map_step
	mark_want = Vector2.ZERO if right or on_it else w.clamp(Vector2(1, 1), Vector2(511, 511))
	mark_want_t = clock
	_mark_ask()
	return true


func _mark_ask() -> void:
	mark_sent_t = clock
	var b := PackedByteArray([0x57, 0, 0, 0, 0, 0, 0, 0, 0])
	b.encode_float(1, mark_want.x)
	b.encode_float(5, mark_want.y)
	lobby.out.put_packet(b)


func toggle_map() -> void:
	big_map = not big_map
	map_dirty = true


# TN_GUEST_REAR=1: the box as a rear view
func _rear_follow() -> void:
	var cam := get_viewport().get_camera_3d()
	rear_rect.visible = cockpit.visible and state == 0 and cam != null
	if not rear_rect.visible:
		return
	rear_rect.position = _g(BOX.position.x, BOX.position.y)
	rear_rect.size = _g(BOX.end.x, BOX.end.y) - rear_rect.position
	var back := cam.global_transform
	back.basis = back.basis.rotated(Vector3.UP, PI)
	rear_cam.global_transform = back
