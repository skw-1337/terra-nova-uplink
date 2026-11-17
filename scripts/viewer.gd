# Terra Nova Uplink: terrain, water, mission entities, named script zones, free camera.
extends Node3D

const TNData = preload("res://scripts/tn_data.gd")
const Terrain = preload("res://scripts/terrain.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
const GROUND = preload("res://terrain.gdshader")
const LIMB = preload("res://limb.gdshader")
const OLDSCHOOL = preload("res://oldschool.gdshader")
const SPRITE_SHADOW = preload("res://sprite_shadow.gdshader")
const WAYPOINT = preload("res://waypoint.gdshader")
const INFRARED = preload("res://infrared.gdshader")
const SUBVIEW = preload("res://subview.gdshader")
const SMOKE = preload("res://smoke.gdshader")
const PUFF = preload("res://puff.gdshader")
const ANIM = preload("res://anim.gdshader")
const ANIM_SOFT = preload("res://anim_soft.gdshader")
const DUST = preload("res://dust.gdshader")
const HAZE = preload("res://haze.gdshader")
const BEAM = preload("res://beam.gdshader")
const WATER = preload("res://water.gdshader")
const SPRITE = preload("res://sprite.gdshader")
const SNOW = preload("res://snow.gdshader")
const SKY_SHADER = preload("res://sky.gdshader")
const SKY_DISTANCE := 2400.0             # sky sprites: far away, following the camera
const SKY_PIXEL := 0.0024                # their angular size per image pixel (radians)
const DEFAULT_SUN := Vector3(-52, -35, 0)
const SMOKE_WIDTH := 1.4                # world width of a smoke column
const FUMEE_COLUMN := false             # the "Fumee" objects (4/61) as a looping smoke column (not the game's: it
                                        # deletes them at load, see tn_objects.gd SMOKE_TYPE); the owner's choice
const POSES_FILE := "res://data/soldier_poses.json"   # real poses read from the running game
# Standing pose computed by the game for a Hog scout (suit 4), read in a RAM snapshot:
# joints (right, up, forward) in world units, ground at 0. Other suits get the same joint
# directions with their own bone lengths (sprite pixel length / 256 x the game's size factor, _part_scale).
const TEMPLATE_POSE := [Vector3(-0.0378, 0.0, 0.0329), Vector3(0.0378, 0.0, 0.0329),
		Vector3(-0.0279, 0.0422, -0.0169), Vector3(0.0279, 0.0422, -0.0169),
		Vector3(-0.0203, 0.1445, 0.0034), Vector3(0.0388, 0.1445, 0.0035),
		Vector3(-0.0312, 0.2494, 0.0), Vector3(0.0312, 0.2494, -0.0), Vector3(0.0, 0.2494, 0.0),
		Vector3(0.0, 0.4043, 0.0), Vector3(-0.0689, 0.3826, 0.0117), Vector3(0.0874, 0.3826, 0.012),
		Vector3(-0.0695, 0.322, 0.061), Vector3(0.0932, 0.3227, 0.0609),
		Vector3(-0.0714, 0.3061, 0.1374), Vector3(0.111, 0.3112, 0.136)]
const TEMPLATE_SUIT := 4
# A soldier's size (0x27F00C, 0x2817B0): v = 6 + (r1 + r2 + r3) / 4 (r: 0..15, mean 11.25), 11 for the clones (suits 6-8);
# the squad's from a table by character. d = v + the suit's offset - 8: legs (thigh, shin) x (1 + d / 64), arms and
# torso x (1 + d / 128), feet as they are. Standing, the game's legs reach 0.9 x thigh + shin (its field +0x2ED).
const SIZE_OFFSET := {4: 10, 2: 5, 5: 5, 3: 2, 1: -2}
const SIZE_MEAN := 11.25
const SIZE_CLONE := 11.0
const LEG_STAND := 0.9
const CFG := "user://viewer.cfg"

var data = TNData.new()
var objects = TNObjects.new()
var objects_ok := false
var pal := PackedColorArray()   # 256-color palette of the current planet
var pal_key := ""
var pal_first := 17           # the old school's first palette colour (1 on a planet whose ground uses colours 1-16)
var world: Node3D
var camera: Camera3D
var ui: CanvasLayer
var oldschool_rect: ColorRect      # live mode, "old school": the game's pixels and palette over the 3D view (F12)
var ir_rect: ColorRect            # live mode: the game's infrared view (its orange ramp), under the HUD
var ir_on := false
# The HUD's side views (live mode): the selected squadmate's camera (bottom left, button VUE) and the probe's (right),
# drawn here by Godot over the game's own small views (panels 1 = squadmate, 2 = target camera, 3 = probe, 4 = the
# player's own view in the probe's panel while the probe's is in the HUD, 5 to 7 = the 360 view's left, back and
# right cameras, 8 = the player's own view in the map's panel while the map is in the HUD).
const SUB_RECTS := {1: true, 2: true, 3: true, 4: true, 5: true, 6: true, 7: true, 8: true}
const SUB_FOV_PROBE := 78.0      # the probe's: its compass labels (45 deg apart) seen at 340 of its 670 pixels (the
                                  # game's code says 84.55 at zoom 1, as SUB_FOV: kept until a live check settles it)
const PROBE_TILT := 0.3
const SUB_FOV := 84.55            # horizontal, degrees: the game's panel cameras at zoom 1, 2 atan(1 / 1.1) (its
                                  # projection multiplies the zoom by 1.1, 0x29e7b3), over their whole canvas
const SUB_FOV_SELF := 84.55       # the player's own view in a panel (4, 8): the game's own field (its compass
                                  # labels there: S seen 37 deg aside at 140 of the panel's 170 half pixels)
const SUB_FOV_AROUND := 84.55     # the 360 view's cameras (5 to 7): the player's own field too (a squadmate followed
                                  # across each panel while the player turns on the spot: 83 to 85 degrees)
const SUB_EASE := 0.2             # side view cameras: share of the way to the new reading (~120 a second)
const SUB_HIDE_LAYER := 1 << 19   # the unit carrying a side view's camera: hidden from that view only
const PLAYER_LAYER := 1 << 18     # the player's own body: seen only in the side views (the main view is its eyes)
const FX_LAYER := 1 << 1          # shots and effects: seen by every view, left alone by the ground's burn marks (decals)
const DEEP_LAYER := 1 << 17       # models on the map's darkest light level: lit by sun_half, not by the sun (_apply_deep)
const NO_HAZE_LAYER := 1 << 16    # a camera without it sees no haze (tn_haze.gdshaderinc: the co-op maps high above)
var live_ents := {}               # coop guest's map: the last live entities (index -> class, type, active, x, y, z, h)
var live_player := -1             # the entity whose body is hidden (the view's own suit)
var live_player_node: Node3D        # its node (an extra, or one of the mission's units)
var sub_views := {}               # panel -> {"vp", "cam", "rect", "seen", "node"}
var sub_layer: CanvasLayer
var oldschool_key := ""
var panel: PanelContainer
var list: ItemList
var info: Label
var status: Label
var path_edit: LineEdit
var missions := []
var labels_on := true
var zones_on := true
var veg_on := true
var yaw := 0.0
var pitch := -0.45
var speed := 30.0
var look := false
var current := {}
var env: Environment
var sun: DirectionalLight3D
var sky_root: Node3D
var mats := {}
# --live: the camera follows the running game (sent by live/live_bridge.py over UDP, port 47821:
# x, y, z in game units, camera heading and pitch in radians, horizontal field of view in degrees)
var LIVE_PORT := 47821                         # --live-port N (coop: the guest's window)
const MINE_TYPE := 47          # class 4: the mine, pitched with the ground as a vehicle (0x29b3ac)
# half the length of each vehicle type's model (RESTNOBJ 1372 headers), when a node has no model to read it from
const VEHICLE_HALF := [1.1730, 0.9594, 1.0267, 1.7062, 0.7459, 1.1133, 1.1266, 2.7452, 1.2472, 4.6339, 0.9448, 0.7686]
const GAME_Z := 0.12          # shots, smoke, flying lift: this much below the game's heights (units are drawn with
								# the game's own offset by class and type: TNObjects.draw_offset)
var live := false
var udp: PacketPeerUDP
var live_seen := 0
var live_units_seen := 0          # entity packets applied since the game came back to its 3D (_start_ready)
var live_shot := ""
var live_shot_frame := 60
var live_nodes := []          # one node per mission entity, in file order
var live_off := -1            # game entity table index of the first mission entity
var mission_tag := ""         # the mission's file (the pirates' arms in the map viewer, _pirate_arms)
var draw_distance := OS.get_environment("TN_DRAW_DISTANCE") == "1"   # live: hide what the game does not draw
var live_drawn := PackedByteArray()  # the bridge's DRAW bits (entity index), empty: none received
var live_sizes := {}          # game entity index -> its soldier's bone lengths (the bridge's SLEN, _live_size)
var live_refs := {}           # live: game index -> [handedness, the 5 chains' limb reference vectors (right, up, fwd)]
var live_alarm := false       # the mission's alarm (the bridge, [0x371174] of the English exe): type-57 lamps lit
var live_extra := {}          # game entity index -> node, for units not in the mission file (squadmates...)
var live_fx := {}             # game entity index -> glowing sprite: shots (class 5) and their sparks (class 6)
var live_piles := {}          # game entity index -> pile of armour pieces of a burst suit (6/33)
var fx_mats := {}
var puffs := []               # live smoke puffs: [node, start msec]; type 6/29 (jetpack exhaust, laser trail)
var puff_mat: ShaderMaterial
var puff_mesh: QuadMesh
var veg_cells := {}           # vegetation cell (cx * 128 + cy) -> [[multimesh, instance]]: what to hide when it goes
var veg_values := PackedByteArray()
var scorch_prev := PackedByteArray()
var ground_mats := []        # ground materials of the map, for the sky they mirror (the water's too)
var water_mats := []         # the water's (water.gdshader): plain in the infrared view
var sky_clouds: Texture2D
var sky_haze_lut: ImageTexture = null    # the sky's haze rows (SKY 150) as colours: 256 indices x 16 levels
var sky_haze_idx: ImageTexture = null    # the same as palette indices (R8)
var cur_ir := {}                         # the planet's IR tables (TNData.ir_palettes)
var sky_haze := Color(0.7, 0.76, 0.84)
var sky_light := Color(0.91, 0.94, 0.97)     # the lightest cloud colour (the horizon)
var sun_to := Vector3(0, 0.7, 0.7)           # towards the sun (the map's light direction)
# --hud: the game's own screen (cockpit, HUD) over the view, its 3D window transparent (port 47823: 'PAL' palette +
# 3D window, then one 'HUZ' packet: the 320 x 400 screen as (palette index, alpha), deflated); the camera is then
# off-centre like the game's, whose view looks at the middle of its 3D window (_view_row)
const HUD_PORT := 47823
const LIVE_LIGHT := 0.73       # sun in live mode, and the sky's share of the ambient light: the game's ground is
const SUIT_SQUASH := 1.0       # suits: height of the joints (0.75 was measured while the live view was zoomed in)
const LIVE_AMBIENT := 0.28     # darker (measured on the same view against the running game)
# live mode: the game's haze (0x2B4E8C), one curve for every planet: level 0 up to 20 units, then
# min(15, 16 (1 - exp(-(d - 20) / k))), k = the mission's haze radius (99 in most). Godot's depth fog
# pow(smoothstep(begin, end, d), 0.4) follows it within 0.01 with begin 20 + 16 k / 99, end 20 + 300 k / 99; its
# level 15 is not a wall (0.66-0.80 of the way to the haze colour in the SKY tables): LIVE_FOG_MAX
const LIVE_FOG_BEGIN := 36.0
const LIVE_FOG_END := 320.0
const LIVE_FOG_MAX := 0.72
const LIVE_FOG_CURVE := 0.4
const LIVE_SHADOW := 70.0       # live mode: the objects' shadows up to there (the ground casts none)
const LIVE_SATURATION := 1.4    # the 3D's colours (the sky and the water take it back: their "desat")
const LIVE_SKY := 1.0          # its sky as is (1.5 was brighter than the game once the bloom was off)
# live mode: each planet's ambiance over that look (its RESPLNTn file; a storm sky, SKY0S, changes its planet's):
# the fog's colour (the sky's haze mixed with a tint), the sun's colour (the ground's: the models take a white sun) and
# light, the sky's share of the ambient light, saturation, contrast, brightness; sparkle: snow crystals catching the
# light
const PLANET_LOOK := {
	"RESPLNT0.RES": {"tint": Color(0.78, 0.84, 0.92), "tint_mix": 0.0,        # temperate (its haze: the sky's own)
		"sun": Color(1.0, 0.94, 0.82), "light": 0.82, "ambient": 0.3, "sat": 1.45, "contrast": 1.03},
	"RESPLNT1.RES": {"tint": Color(0.80, 0.86, 0.95), "tint_mix": 0.0,        # ice (its fog: the sky's own pale green haze)
		"sun": Color(0.86, 0.93, 1.0), "light": 0.8, "ambient": 0.4, "sat": 1.2, "contrast": 1.08, "sparkle": 1.2},
	"RESPLNT2.RES": {"tint": Color(0.86, 0.62, 0.42), "tint_mix": 0.6,       # desert
		"sun": Color(1.0, 0.87, 0.68), "light": 0.95, "ambient": 0.24, "sat": 1.3, "contrast": 1.1},
	"RESPLNT3.RES": {"tint": Color(0.1, 0.12, 0.1), "tint_mix": 0.6,          # meteor:
		"sun": Color(0.82, 1.0, 0.84), "light": 0.62, "ambient": 0.2, "sat": 1.3, "contrast": 1.08},       # dark teal

	"RESPLNT4.RES": {"tint": Color(0.18, 0.24, 0.36), "tint_mix": 0.6,        # night
		"sun": Color(0.62, 0.74, 1.0), "light": 0.42, "ambient": 0.1, "sat": 1.0, "contrast": 1.12, "bright": 0.72},
	"SKY0S.RES": {"tint": Color(0.52, 0.56, 0.6), "tint_mix": 0.55,          # storm
		"sun": Color(0.82, 0.86, 0.92), "light": 0.5, "ambient": 0.36, "sat": 1.15, "contrast": 0.98},
}
var hud := false
var hud_udp: PacketPeerUDP
var hud_img: Image
var hud_tex: ImageTexture
var hud_pal_img: Image
var hud_pal: ImageTexture
var hud_rect: TextureRect
var hud_parts := {}
var hud_frame := -1
var hud_win := Rect2i()           # 3D window in the game's 320 x 400 screen
# --play: keyboard and mouse go to the game through the bridge (port 47824): keys as PC scancodes of their physical
# position ('K'), mouse moves ('M', the bridge turns them into the look), left / right buttons ('B'). A click in the
# window captures the mouse; Pause gives it back (also when the window loses the focus).
var PLAY_PORT := 47824                         # --play-port N
var play := false
var play_udp: PacketPeerUDP
var play_dx := 0.0
# coop guest's window (--coop-hud / --coop-guest): free look, the middle button or Alt held: the mouse turns only
# his camera (up to 120 degrees aside, 60 up / down), his suit and aim stay; let go: the view comes back
var guest_win := false
var lobby_was_open := false
var free_look := false
var look_off := Vector2.ZERO
var play_dy := 0.0
var mouse_sens := maxf(0.1, OS.get_environment("TN_MOUSE_SENS").to_float()) if OS.get_environment("TN_MOUSE_SENS") != "" else 1.0
var invert_y := OS.get_environment("TN_INVERT_Y") == "1"    # the launcher's settings (its environment)
var play_held := {}
var play_started := false        # the first click in the window only takes the mouse
# live mode without coop: "Host online" (top left, while the mouse is free) turns this game into an online coop host,
# as Coop online - host.bat does: coop_net.gd opens the Steam lobby, the bridge ('HOST') starts its coop module
# (only with TN_COOP set: it needs the TN+ coop build, which the solo game does not run; the Coop launcher hosts with
# --coop-host itself)
var host_btn: Button
var versus_btn: Button           # "1v1 (versus)": the same, the guest drives a suit of the other side (experimental)
# the game's own screen when it is not in its 3D (menus, death screen, briefing, video, pause): the bridge captures
# the DOSBox window and sends it (see live_bridge.py menu_loop); shown over everything, the mouse goes to the game
var menu_mode := false
var menu_rect: TextureRect
var menu_bg: ColorRect            # black behind it, where it does not fill the window
var menus43 := OS.get_environment("TN_MENUS43") == "1"   # the launcher: the game's screens come whole (see _menu_box)
var hd_movie: VideoStreamPlayer               # a cutscene in HD (movies_hd\, made by tools/upscale_movies.py on the
var hd_movie_box: AspectRatioContainer        # player's own files) over the game's own, while the game plays it
var hd_movie_name := ""
var menu_tex: ImageTexture
var menu_img: Image                # the game's screen as received (zones of it are updated)
var menu_cursor: Image             # the game's arrow, shown as the mouse cursor on its screens (no lag)
var menu_cursor_hot := Vector2i.ZERO
var menu_cursor_own := false       # the bridge hides the game's arrow: ours is shown
var menu_frame := Vector2i(640, 480)  # the game's mouse range on that screen
var menu_parts := {}
var menu_img_n := -1
var play_cursor := Vector2i(-1, -1)
var play_cursor_sent := Vector2i(-1, -1)
# the game's cursor in its 3D while the mouse is free: the bridge empties the game's own and sends its picture ('CUR'
# with its first bit set), shown here as the mouse cursor itself (_play_cursor)
var play_cur_img: Image
var play_cur_hot := Vector2i.ZERO
var play_cur_n := 0               # (one more with each new picture)
var play_cur_t := -100000         # when the bridge last sent it (msec)
var play_cur_set := ""            # the one set as the mouse cursor now ("": not ours)
var play_free := -1               # what the bridge was told last ('F'), and when
var play_free_t := 0
# The crosshair of the look mode is the game's own cursor, which the bridge keeps on the view's centre (_cross_pixel:
# row 144 of the game's screen in the cockpit view). The player can have a dot instead, or nothing (the launcher:
# TN_CROSSHAIR = dot / none): the
# bridge is then asked to empty the game's cursor in the look mode too (as for the free cursor), and the dot is
# drawn here.
var crosshair := OS.get_environment("TN_CROSSHAIR").to_lower()
var cross_dot: TextureRect
# The right button held, the mouse free. On a map the game then keeps its cursor where the button went down: it reads
# how far the mouse goes from there, scrolls the map by that much and puts the cursor back. Positions sent as the
# cursor's ('P') made the map race away: while the button is held the mouse's moves are sent as moves ('R'), and the
# bridge says when the game holds its cursor ('PIN'). From then on, as in the game, the mouse is taken (no edge of the
# window stops the hand), the cursor stays where the button went down (the game's picture of it, drawn here:
# drag_cur) and the mouse comes back there when the button is let go. Anywhere else (the 3D view) the cursor goes on
# following the mouse.
var play_hold := false              # the right button is down, the mouse free
var play_drag := false              # ... and the game holds its cursor
var drag_cur: TextureRect
var play_drag_at := Vector2i.ZERO   # where the button went down, on the game's screen
var play_drag_win := Vector2.ZERO   # ... and in the window
var play_drag_acc := Vector2.ZERO   # moves not sent yet (game pixels)
const SCANCODES := {
	KEY_ESCAPE: 0x01, KEY_1: 0x02, KEY_2: 0x03, KEY_3: 0x04, KEY_4: 0x05, KEY_5: 0x06, KEY_6: 0x07, KEY_7: 0x08,
	KEY_8: 0x09, KEY_9: 0x0A, KEY_0: 0x0B, KEY_MINUS: 0x0C, KEY_EQUAL: 0x0D, KEY_BACKSPACE: 0x0E, KEY_TAB: 0x0F,
	KEY_Q: 0x10, KEY_W: 0x11, KEY_E: 0x12, KEY_R: 0x13, KEY_T: 0x14, KEY_Y: 0x15, KEY_U: 0x16, KEY_I: 0x17,
	KEY_O: 0x18, KEY_P: 0x19, KEY_BRACKETLEFT: 0x1A, KEY_BRACKETRIGHT: 0x1B, KEY_ENTER: 0x1C, KEY_A: 0x1E,
	KEY_S: 0x1F, KEY_D: 0x20, KEY_F: 0x21, KEY_G: 0x22, KEY_H: 0x23, KEY_J: 0x24, KEY_K: 0x25, KEY_L: 0x26,
	KEY_SEMICOLON: 0x27, KEY_APOSTROPHE: 0x28, KEY_QUOTELEFT: 0x29, KEY_BACKSLASH: 0x2B, KEY_Z: 0x2C, KEY_X: 0x2D,
	KEY_C: 0x2E, KEY_V: 0x2F, KEY_B: 0x30, KEY_N: 0x31, KEY_M: 0x32, KEY_COMMA: 0x33, KEY_PERIOD: 0x34,
	KEY_SLASH: 0x35, KEY_KP_MULTIPLY: 0x37, KEY_SPACE: 0x39, KEY_CAPSLOCK: 0x3A, KEY_F1: 0x3B, KEY_F2: 0x3C,
	KEY_F3: 0x3D, KEY_F4: 0x3E, KEY_F5: 0x3F, KEY_F6: 0x40, KEY_F7: 0x41, KEY_F8: 0x42, KEY_F9: 0x43, KEY_F10: 0x44,
	KEY_NUMLOCK: 0x45, KEY_SCROLLLOCK: 0x46, KEY_KP_7: 0x47, KEY_KP_8: 0x48, KEY_KP_9: 0x49, KEY_KP_SUBTRACT: 0x4A,
	KEY_KP_4: 0x4B, KEY_KP_5: 0x4C, KEY_KP_6: 0x4D, KEY_KP_ADD: 0x4E, KEY_KP_1: 0x4F, KEY_KP_2: 0x50, KEY_KP_3: 0x51,
	KEY_KP_0: 0x52, KEY_KP_PERIOD: 0x53, KEY_SECTION: 0x56, KEY_F11: 0x57, KEY_F12: 0x58,
	KEY_KP_ENTER: 0xE01C, KEY_KP_DIVIDE: 0xE035, KEY_HOME: 0xE047, KEY_UP: 0xE048, KEY_PAGEUP: 0xE049,
	KEY_LEFT: 0xE04B, KEY_RIGHT: 0xE04D, KEY_END: 0xE04F, KEY_DOWN: 0xE050, KEY_PAGEDOWN: 0xE051,
	KEY_INSERT: 0xE052, KEY_DELETE: 0xE053}


func _ready() -> void:
	RenderingServer.frame_pre_draw.connect(_sky_rows)
	_build_scene()
	_build_ui()
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	var given := OS.get_environment("TN_GAME_DIR").replace("\\", "/")   # the launcher (Uplink or Coop): its game
	var root := TNData.find_root(given if given != "" else cfg.get_value("game", "root", ""))
	if root == "" or not data.setup(root):
		_ask_path("Terra Nova folder not found. Paste the game folder (the one containing TNOVA):")
		return
	objects_ok = objects.setup(data.data_dir())
	_fill_list()
	var args := OS.get_cmdline_user_args()
	if "--live" in args:
		live = true
		if "--native" in args:                          # the screen's own resolution: fullscreen on the main screen
			get_window().current_screen = DisplayServer.get_primary_screen()
			get_window().mode = Window.MODE_FULLSCREEN
		var fl := CanvasLayer.new()                     # frames per second, top right, over the game's HUD
		fl.layer = 20
		add_child(fl)
		fps_label = Label.new()
		fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		fps_label.offset_left = -110
		fps_label.offset_right = -8
		fps_label.offset_top = 6
		fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		fps_label.add_theme_font_size_override("font_size", 18)
		fps_label.add_theme_color_override("font_color", Color(1, 1, 0.4))
		fps_label.add_theme_color_override("font_outline_color", Color.BLACK)
		fps_label.add_theme_constant_override("outline_size", 4)
		fl.add_child(fps_label)
		# the launcher's "In game" switches: the counter is off unless asked for (ticket #13), and a cap on the pictures
		# a second (the view ran as fast as the card goes: 240 a second for nothing on a fast one)
		fps_label.visible = OS.get_environment("TN_FPS") == "1"
		var cap := int(OS.get_environment("TN_FPS_CAP"))
		if cap > 0:
			Engine.max_fps = clampi(cap, 20, 1000)
		_make_oldschool()
		var il := CanvasLayer.new()                     # the game's infrared view, under the old school mode and the HUD
		il.layer = -2
		add_child(il)
		ir_rect = ColorRect.new()
		ir_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
		ir_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var im := ShaderMaterial.new()
		im.shader = INFRARED
		ir_rect.material = im
		ir_rect.visible = false
		il.add_child(ir_rect)
		# colours of the running game: its 3D is darker and more saturated than this viewer's look (fitted on the
		# same view, 3D pixels only: mean error 61 -> 16 / 255); the HUD on top is not affected
		# done on the lights (terrain, objects), not on the whole image: the sky and the water keep their light. The
		# ground's light is mostly the sky's ambient, which only its sky contribution scales (not its energy), and
		# the blurred sky reflection Godot adds to every surface: off
		sun.light_energy = LIVE_LIGHT
		# shadows: trees, objects, suits (the player's too, see _shadow_twin) cast them; the hills do not (their shade
		# is in the map's light levels, which the ground is drawn with). Sharper near the eye: 8192 atlas, splits at
		# 4, 14, 35 units
		sun.shadow_enabled = true
		sun.directional_shadow_max_distance = LIVE_SHADOW
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
		sun.directional_shadow_split_1 = 0.06
		sun.directional_shadow_split_2 = 0.2
		sun.directional_shadow_split_3 = 0.5
		sun.directional_shadow_blend_splits = true
		sun.shadow_blur = 0.6
		sun.shadow_opacity = 0.75
		sun.shadow_bias = 0.03
		sun.shadow_normal_bias = 1.0
		RenderingServer.directional_shadow_atlas_set_size(8192, true)
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)
		env.ambient_light_sky_contribution = LIVE_AMBIENT
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		env.adjustment_enabled = true
		env.adjustment_saturation = LIVE_SATURATION
		# the game's view ends in its haze: depth fog (its colour is the planet's haze, set with the sky)
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_depth_begin = LIVE_FOG_BEGIN
		env.fog_depth_end = LIVE_FOG_END
		env.fog_density = LIVE_FOG_MAX
		env.fog_depth_curve = LIVE_FOG_CURVE
		env.fog_aerial_perspective = 0.0      # (its colour as is, as the game's haze rows and the shaders' haze)
		env.fog_sun_scatter = 0.0
		env.fog_sky_affect = 0.0
		var lpi := args.find("--live-port")
		if lpi >= 0 and lpi + 1 < args.size():
			LIVE_PORT = int(args[lpi + 1])
		var ppi := args.find("--play-port")
		if ppi >= 0 and ppi + 1 < args.size():
			PLAY_PORT = int(args[ppi + 1])
		udp = PacketPeerUDP.new()
		udp.bind(LIVE_PORT, "127.0.0.1")
		var ls := args.find("--shot")
		if ls >= 0 and ls + 1 < args.size():
			live_shot = args[ls + 1]
		var lf := args.find("--shot-frame")
		if lf >= 0 and lf + 1 < args.size():
			live_shot_frame = int(args[lf + 1])
	if not live:                              # the map viewer: old school too (F12), to see a map as in the game
		_make_oldschool()
	if live and ("--coop-host" in args or "--coop-guest" in args):   # coop over Steam (coop_net.gd)
		add_child(load("res://scripts/coop_net.gd").new())
	if live and ("--coop-hud" in args or "--coop-guest" in args):  # the coop guest's HUD (coop_hud.gd)
		add_child(load("res://scripts/coop_hud.gd").new())
		guest_win = true
	if live and "--hud" in args:
		_hud_setup()
	if live and "--play" in args:
		play = true
		play_udp = PacketPeerUDP.new()
		play_udp.set_dest_address("127.0.0.1", PLAY_PORT)
		if OS.get_environment("TN_COOP") != "" and not ("--coop-host" in args or "--coop-guest" in args or "--coop-hud" in args):
			var bl := CanvasLayer.new()
			bl.layer = 21                               # over the game's screens (menus)
			add_child(bl)
			host_btn = Button.new()
			host_btn.text = "Host online"
			host_btn.tooltip_text = "Online coop: a Steam friend drives a teammate (TN+ Coop build, Steam running)"
			host_btn.position = Vector2(12, 8)
			host_btn.focus_mode = Control.FOCUS_NONE        # keys stay the game's
			host_btn.add_theme_font_size_override("font_size", 16)
			host_btn.pressed.connect(_host_online)
			bl.add_child(host_btn)
			versus_btn = Button.new()
			versus_btn.text = "1v1 (versus)"
			versus_btn.tooltip_text = "Experimental: a Steam friend drives an enemy suit and fights you (pick a mission or a\n" + \
				"scenario with enemy suits, then start it)"
			versus_btn.position = Vector2(12, 44)
			versus_btn.focus_mode = Control.FOCUS_NONE
			versus_btn.add_theme_font_size_override("font_size", 16)
			versus_btn.pressed.connect(_host_online.bind(true))
			bl.add_child(versus_btn)
	if live:                                  # shots and sparks glow (only what is brighter than white: no bloom
		env.glow_enabled = true               # over the whole picture, it made it too bright)
		env.glow_intensity = 0.8
		env.glow_bloom = 0.0
		env.glow_hdr_threshold = 1.3          # (the explosions' own pictures, at most white, do not glow)
	if "--clean" in args or live:             # screenshots: no labels, zones, panel or help line
		labels_on = false
		zones_on = false
		panel.visible = false
		status.visible = false
	if OS.get_environment("TN_LAB") != "" and not ("--coop-guest" in args or "--coop-hud" in args):
		add_child(load("res://scripts/lab.gd").new())   # live graphics lab (lab.gd): only with the lab shortcut
	if "--all" in args:                       # test: load every mission, then quit
		for k in missions.size():
			await _load(k)
		get_tree().quit()
		return
	var i := args.find("--mission")
	if i >= 0 and i + 1 < args.size():
		_load_by_label(args[i + 1])
	elif live:                                # the game in its menus: the small flat map until a mission starts
		_load_by_label("MISSFLAT.RES")          # ('MIS' then loads the real one; a whole map here was a slow start)
	else:
		list.select(4)
		_load(4)


# ------------------------------------------------------------------ scene
func _build_scene() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sm := ProceduralSkyMaterial.new()
	sm.sky_top_color = Color(0.32, 0.5, 0.78)
	sm.sky_horizon_color = Color(0.72, 0.78, 0.86)
	sm.ground_horizon_color = Color(0.72, 0.78, 0.86)
	sky.sky_material = sm
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = VIEW_AMBIENT
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.76, 0.84)
	env.fog_density = 0.0005
	env.fog_sky_affect = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_haze_globals()
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = DEFAULT_SUN
	sun.light_energy = VIEW_LIGHT
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	add_child(sun)
	sun_half = DirectionalLight3D.new()            # (no shadows of its own: a second shadow map would halve the sun's)
	sun_half.light_cull_mask = DEEP_LAYER
	sun_half.visible = deep_shade
	add_child(sun_half)
	if deep_shade:
		sun.light_cull_mask = 0xFFFFF & ~DEEP_LAYER
	world = Node3D.new()
	add_child(world)
	sky_root = Node3D.new()
	add_child(sky_root)
	camera = Camera3D.new()
	camera.cull_mask = 0xFFFFF & ~PLAYER_LAYER       # the player's body: only in the HUD's side views
	camera.far = 3000.0
	camera.fov = 70.0
	add_child(camera)
	var terrain_mat := StandardMaterial3D.new()
	terrain_mat.vertex_color_use_as_albedo = true
	terrain_mat.vertex_color_is_srgb = true
	terrain_mat.roughness = 1.0
	mats["terrain"] = terrain_mat
	var water := ShaderMaterial.new()          # the sky mirrored on ripples (its clouds set with the sky)
	water.shader = WATER
	mats["water"] = water
	for key in ["friend", "enemy", "building", "decor", "tree", "rock", "zone"]:
		var m := StandardMaterial3D.new()
		m.roughness = 0.8
		m.albedo_color = {"friend": Color(0.25, 0.55, 1.0), "enemy": Color(0.95, 0.25, 0.2),
			"building": Color(0.72, 0.72, 0.78), "decor": Color(0.7, 0.55, 0.35),
			"tree": Color(0.16, 0.38, 0.14), "rock": Color(0.5, 0.48, 0.45),
			"zone": Color(1.0, 0.85, 0.15)}[key]
		if key == "zone":
			m.emission_enabled = true
			m.emission = Color(1.0, 0.8, 0.1)
			m.emission_energy_multiplier = 0.6
		mats[key] = m


func _build_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	panel = PanelContainer.new()
	panel.position = Vector2(10, 10)
	ui.add_child(panel)
	var vb := VBoxContainer.new()
	panel.add_child(vb)
	var title := Label.new()
	title.text = "Terra Nova Uplink"
	vb.add_child(title)
	list = ItemList.new()
	list.custom_minimum_size = Vector2(360, 520)
	list.item_selected.connect(_load)
	vb.add_child(list)
	info = Label.new()
	info.custom_minimum_size = Vector2(360, 0)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(info)
	path_edit = LineEdit.new()
	path_edit.visible = false
	path_edit.text_submitted.connect(_on_path)
	vb.add_child(path_edit)
	status = Label.new()
	status.anchor_top = 1.0
	status.anchor_bottom = 1.0
	status.offset_left = 10
	status.offset_top = -34
	status.text = "Right mouse: look   WASD/ZQSD: move   Space/Ctrl: up/down   Shift: fast   Wheel: speed   Tab: panel   F2: labels   F3: script zones (yellow posts)   F4: vegetation"
	ui.add_child(status)


func _ask_path(msg: String) -> void:
	info.text = msg
	path_edit.visible = true


func _on_path(t: String) -> void:
	var root := TNData.find_root(t.strip_edges().replace("\\", "/"))
	if root == "" or not data.setup(root):
		info.text = "Still not found: pick the folder that contains TNOVA."
		return
	var cfg := ConfigFile.new()
	cfg.set_value("game", "root", root)
	cfg.save(CFG)
	path_edit.visible = false
	objects_ok = objects.setup(data.data_dir())
	_fill_list()


func _fill_list() -> void:
	missions = data.mission_list()
	if objects_ok:
		missions.append({"label": "Gallery  all 3D models", "file": "", "gallery": true})
	list.clear()
	for m in missions:
		list.add_item(m["label"])
	info.text = "%d missions found in\n%s" % [missions.size(), data.root]


func _load_by_label(t: String) -> void:
	for i in missions.size():
		if missions[i]["label"].contains(t) or missions[i]["file"].get_file().to_upper() == t.to_upper():
			list.select(i)
			_load(i)
			return


# ------------------------------------------------------------------ loading
func _load(index: int) -> void:
	var entry: Dictionary = missions[index]
	info.text = "Loading %s..." % entry["label"]
	await get_tree().process_frame
	await get_tree().process_frame
	if entry.get("gallery", false):
		_load_gallery()
		return
	var t0 := Time.get_ticks_msec()
	var mis: Dictionary = data.load_mission(entry["file"])
	if mis.is_empty():
		info.text = "Cannot read " + entry["file"]
		return
	var note := ""
	var map_path: String = data.resolve(entry["file"], mis["map"])
	if map_path == "":
		note = "\nMap %s is missing from the game: shown on the generator's flat terrain." % mis["map"]
		map_path = data.resolve(entry["file"], "FLAT.RES")
	var m: Dictionary = data.load_map(map_path, entry["file"])
	if m.is_empty():
		info.text = "Cannot read map " + map_path
		return
	for c in world.get_children():
		c.queue_free()
	var pl: Dictionary = m["planet_data"]
	ground_mats.clear()
	water_mats.clear()
	var det_mat: Material = mats["terrain"]
	var out_mat: Material = mats["terrain"]
	snow_pl = pl                          # (the game's snow on its tiles: _live_tiles)
	snow_tex = null
	snow_lit = null
	snow_idx = null
	snow_raw.clear()
	snow_mats.clear()
	if pl["ok"]:                          # real ground textures (else: average colors)
		det_mat = _ground_mat(pl, m["detail"], Vector2(0, 0), 1.0)
		snow_mats.append(det_mat)
		if not m["outer"].is_empty():
			out_mat = _ground_mat(pl, m["outer"], Vector2(-256, -256), 4.0)
			snow_mats.append(out_mat)
	Terrain.build(world, m["detail"], 1.0, Vector2(0, 0), Rect2i(), det_mat)
	if not m["outer"].is_empty():
		Terrain.build(world, m["outer"], 4.0, Vector2(-256, -256), Rect2i(64, 64, 128, 128), out_mat)
	# the hills cast no shadow: the map's light levels already hold them (the ground is drawn with them, see
	# terrain.gdshader), and the game shades no object behind a hill
	for gi in world.find_children("*", "GeometryInstance3D", true, false):
		if gi.material_override == det_mat or gi.material_override == out_mat:
			gi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if pl["ok"] and pl.get("water_mask") != null:    # the water, over its tiles (water.gdshader)
		var tint: Color = pl["water_tint"]
		if entry["file"].get_file().to_upper() == "MISS2.RES":
			tint = Color8(128, 128, 128)              # (the game's mission 2: a grey tint, 0x2A83BC)
		for gi in [[m["detail"], 1.0, Vector2(0, 0), Rect2i()], [m["outer"], 4.0, Vector2(-256, -256), Rect2i(64, 64, 128, 128)]]:
			var grid: Dictionary = gi[0]
			if grid.is_empty():
				continue
			var only := _water_cells(grid, pl["water"])
			if only.is_empty():
				continue
			Terrain.build(world, grid, gi[1], gi[2], gi[3], _water_mat(pl, grid, gi[2], gi[1], tint), only)
	pal = pl["palette"] if pl.has("palette") else data.full_palette(PackedByteArray())
	cur_ir = pl.get("ir", {})
	pal_first = 1 if pl.get("base_share", 0.0) > 0.05 else 17
	pal_key = m["planet"]
	haze_k = mis.get("haze_k", 99)
	mis_params = mis.get("params", {})
	cloud_base = Vector2.ZERO
	cloud_set = Vector2(-1.0, -1.0)
	_limb_light(m)
	sky_ref_y = TNData.height_at(m, _drop_zone(mis).x, _drop_zone(mis).y) + SKY_EYE
	far_ground = _mean_ground(m, pl)
	_set_sky(data.resolve(entry["file"], mis.get("sky", "")) if mis.get("sky", "") != "" else "", m["light"])
	map_dif = m.get("dif", DEFAULT_DIF)
	map_amb = m.get("amb", DEFAULT_AMB)
	# live: the models shaded as the game does (model.gdshader): the planet's light table, the map's light (res 82)
	objects.game_shade = {}
	if live and objects_ok and pl.get("shade_idx") != null and pal.size() >= 256:
		var pimg := Image.create(256, 1, false, Image.FORMAT_RGB8)
		for i in 256:
			pimg.set_pixel(i, 0, pal[i])
		objects.game_shade = {"shade_idx": pl["shade_idx"], "pal_tex": ImageTexture.create_from_image(pimg),
				"ir_lut": pl.get("ir_lut")}
	_ir_colours(pl)
	RenderingServer.global_shader_parameter_set("tn_model_light", Vector4(sun_to.x, sun_to.y, sun_to.z, 1.0))
	RenderingServer.global_shader_parameter_set("tn_model_shade", Vector4(map_amb, map_dif, 0.0, 0.0))
	if live:
		planet_look(m["planet"], mis.get("sky", ""))
	else:                                     # the map's own sun and ambient (res 82), against the pair the look was
		sun.light_energy = VIEW_LIGHT * map_dif / DEFAULT_DIF          # tuned on (36 maps of 55 have it)
		env.ambient_light_energy = VIEW_AMBIENT * map_amb / DEFAULT_AMB
		_ground_look(VIEW_LIGHT, VIEW_AMBIENT)
	var nveg := _add_vegetation(m)
	var counts := {}
	live_nodes.clear()
	live_off = -1
	live_alarm = false                        # (cleared by the game at each mission start)
	live_sizes.clear()
	live_drawn = PackedByteArray()            # (the last mission's DRAW bits)
	mission_tag = String(entry["file"]).get_file().to_upper()
	live_extra.clear()
	live_fx.clear()
	live_piles.clear()
	scorch_prev = PackedByteArray()           # (the burns: on the new map's ground, _live_scorch)
	anims.clear()
	anim_seen.clear()
	anim_mats.clear()                         # (their pictures are in the mission's palette)
	smoke_pending.clear()
	puffs.clear()                             # (their nodes went with the old world too: kept, every later frame
	puff_units.clear()                        # threw errors on freed nodes until Uplink crashed)
	for e in mis["entities"]:
		live_nodes.append(_add_object(m, e["cls"], e["sub"], e["x"], e["y"], e["heading"], e["group"], true, e["z"],
				e.get("team", 0), e.get("pitch", 0.0), e.get("state", 0)))
		live_nodes[-1].set_meta("mission", true)       # placed from the file: buildings stay on the ground
		counts[e["cls"]] = counts.get(e["cls"], 0) + 1
	for z in mis["zones"]:
		_add_zone(m, z)
	current = {"map": m, "mission": mis, "entry": entry}
	_sync_sun_half()
	_place_camera(m, mis)
	info.text = "%s\nmap %s (%s), %d objects, %d named zones, %d plants%s\nloaded in %.1f s" % [
		entry["label"], mis["map"], m["planet"], mis["entities"].size(), mis["zones"].size(), nveg, note,
		(Time.get_ticks_msec() - t0) / 1000.0]
	print(info.text.replace("\n", " | "))
	var args := OS.get_cmdline_user_args()
	var s := args.find("--shot")
	if s >= 0 and s + 1 < args.size() and not live:
		_screenshot(args[s + 1])


# Vegetation generated like the engine does (see TNData.load_map). Each plant is a decor type whose
# sprite (or model) comes from RESTNOBJ: one MultiMesh per sprite.
func _add_vegetation(m: Dictionary) -> int:
	var vmap: PackedByteArray = m["veg_map"]
	var sets: Array = m["veg_sets"]
	if vmap.size() < 128 * 128:
		return 0
	var groups := {}                  # sprite / model ref (or stand-in shape name) -> Array[Transform3D]
	var n := 0
	for cx in 128:
		for cy in 128:
			var v := vmap[cx * 128 + cy]  # column by column
			if v == 0 or v > sets.size():
				continue
			for it in sets[v - 1]:
				var x: float = cx * 4.0 + it["ox"]
				var y: float = cy * 4.0 + it["oy"]
				var key := Vector2i(it["cls"], it["sub"])
				if not groups.has(key):
					groups[key] = []
				groups[key].append([Transform3D(Basis.IDENTITY, Vector3(x, TNData.height_at(m, x, y), y)), cx * 128 + cy])
				n += 1
	veg_cells.clear()
	veg_values = vmap.duplicate()
	for key in groups:                # key = (class, type)
		var mesh: Mesh = null
		var mat: Material = null
		var shadow: Material = null
		var ref: Vector2i = objects.ref_for(key.x, key.y) if objects_ok else Vector2i.ZERO
		if OS.has_environment("TN_DEBUG"):
			print("vegetation %s ref %s %s x%d largeur %.3f" % [key, ref, data.type_name(key.x, key.y), groups[key].size(), objects.sprite_width(key.x, key.y)])
		if TNObjects.is_sprite(ref):
			var sp: Dictionary = objects.sprite(ref, pal, pal_key)
			if not sp.is_empty():
				mesh = _sprite_quad(sp, objects.sprite_width(key.x, key.y) * SPRITE_SCALE, SPRITE_TALL, sprite_hd)
				mat = _sprite_mat_rows(ref, sp, m) if _sprites_per_index(m) else _sprite_mat(ref, sp)
				shadow = _sprite_shadow_mat(ref, sp)
		elif TNObjects.is_model(ref):
			var md: Dictionary = objects.model(ref, pal, pal_key)
			if not md.is_empty():
				mesh = md["mesh"]
		if mesh == null:
			var name: String = data.type_name(key.x, key.y).to_lower()
			var shape := "rock" if name.contains("rocher") or name.contains("rock") else (
					"bush" if name.contains("buisson") or name.contains("bush") else "tree")
			mesh = _placeholder(shape)
			mat = mats["rock"] if shape == "rock" else mats["tree"]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		var lit := mat is StandardMaterial3D or mat is ShaderMaterial   # sprites: the light of the ground at their foot
		mm.use_colors = lit                   # (before the count)
		mm.mesh = mesh
		var trs: Array = groups[key]
		mm.instance_count = trs.size()
		for i in trs.size():
			mm.set_instance_transform(i, trs[i][0])
			if lit:
				var o: Vector3 = trs[i][0].origin
				mm.set_instance_color(i, Color(_foot_row(m, o.x, o.z) / 15.0, 0.0, 0.0) if mat is ShaderMaterial and 						(mat as ShaderMaterial).get_shader_parameter("per_index") else _foot_light(m, o.x, o.z))
			var cell: int = trs[i][1]
			if not veg_cells.has(cell):
				veg_cells[cell] = []
			veg_cells[cell].append([mm, i, trs[i][0]])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		if mat != null:
			mmi.material_override = mat
		if mat is StandardMaterial3D:
			(mat as StandardMaterial3D).vertex_color_use_as_albedo = true
		elif lit:
			(mat as ShaderMaterial).set_shader_parameter("use_vcol", true)
		mmi.add_to_group("vegetation")
		mmi.visible = veg_on
		world.add_child(mmi)
		if shadow != null:                    # sprites: their shadow comes from a twin facing the light, which shares
			mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # the plants (one hidden: its shadow too)
			var sh := MultiMeshInstance3D.new()
			sh.multimesh = mm
			sh.material_override = shadow
			sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			sh.add_to_group("vegetation")
			sh.visible = veg_on
			world.add_child(sh)
	return n


# Sprites (plants, rocks, probes) take the light of the ground at their foot, as the game draws them (0x29B039 ->
# 0x294B18: twice the light level there, on the ground's triangles, floored; that row of the planet's light table)
func _foot_light(m: Dictionary, x: float, y: float) -> Color:
	var rows: PackedFloat32Array = m["planet_data"].get("rows", PackedFloat32Array())
	var k := rows[clampi(TNData.level2_at(m, x, y), 0, 15)] if rows.size() == 16 else 1.0
	return Color(ground_light.r * k, ground_light.g * k, ground_light.b * k)


# The row of the planet's light table at that foot (file row: 0 = full light)
func _foot_row(m: Dictionary, x: float, y: float) -> int:
	return clampi(TNData.level2_at(m, x, y), 0, 15)


# Live: the sprites as the game lights them, each texel's palette index through that row (TNData.shade_luts), in the
# game's colours, not the ground's look times the row's mean brightness (the plants came out darker than the game's)
func _sprites_per_index(m: Dictionary) -> bool:
	return live and not m.is_empty() and ((m["planet_data"] as Dictionary).get("shade_luts", []) as Array).size() == 16


func _sprite_mat_rows(ref: Vector2i, sp: Dictionary, m: Dictionary) -> ShaderMaterial:
	var k := "spriterows%s/%s" % [ref, pal_key]
	if not mats.has(k):
		var arr := objects.sprite_rows(ref, pal_key, (m["planet_data"] as Dictionary)["shade_luts"])
		if arr == null:
			return _sprite_mat(ref, sp)
		var sm := ShaderMaterial.new()
		sm.shader = SPRITE
		sm.set_shader_parameter("tex", sp["texture"])
		sm.set_shader_parameter("tex_rows", arr)
		sm.set_shader_parameter("per_index", true)
		var irp: Dictionary = (m["planet_data"] as Dictionary).get("ir", {})
		if irp.has(60):                                # infrared: the plants through table 60 (0x29BFE1)
			var ti := objects.sprite_ir(ref, pal_key, 60, irp[60])
			if ti != null:
				sm.set_shader_parameter("tex_ir", ti)
				sm.set_shader_parameter("has_ir", true)
		mats[k] = sm
	return mats[k]


func _sprite_lit_row(ref: Vector2i, sp: Dictionary, m: Dictionary, row: int) -> ShaderMaterial:
	var key := "spriterows%s/%s/%d" % [ref, pal_key, row]
	if not mats.has(key):
		var sm := _sprite_mat_rows(ref, sp, m).duplicate() as ShaderMaterial
		sm.set_shader_parameter("use_vcol", false)
		sm.set_shader_parameter("row", float(row))
		mats[key] = sm
	return mats[key]


# (a sprite object: its own copy of the sprite's material at that light)
func _sprite_lit(ref: Vector2i, sp: Dictionary, c: Color) -> ShaderMaterial:
	var q := Color(roundi(c.r * 40.0) / 40.0, roundi(c.g * 40.0) / 40.0, roundi(c.b * 40.0) / 40.0)
	var key := "sprite%s/lit%s" % [ref, q.to_html(false)]
	if not mats.has(key):
		var sm := _sprite_mat(ref, sp).duplicate() as ShaderMaterial
		sm.set_shader_parameter("use_vcol", false)
		sm.set_shader_parameter("albedo", q)             # (alpha untouched: the sprite's cut-out)
		mats[key] = sm
	return mats[key]


# The ground at full light (light level 0), the colour terrain.gdshader draws it with: what flat ground took from the
# sun and the sky under the high sun of the map the look was tuned on (MAP30, 57.7 deg: GROUND_SUN_REF), from the
# look's base sun (not the map's own diffuse light: the levels hold it)
const GROUND_SUN_REF := 0.845
var ground_light := Color(1, 1, 1)
var planet_sun := Color(1, 1, 1)         # the planet's sun colour (PLANET_LOOK), for the ground only
const VIEW_LIGHT := 1.0                  # the map viewer's sun and ambient
const VIEW_AMBIENT := 0.35
const DEFAULT_DIF := 46000.0 / 65536.0   # the usual pair of res 82 (diffuse, ambient once clamped)
const DEFAULT_AMB := 19536.0 / 65536.0
var map_dif := DEFAULT_DIF
var map_amb := DEFAULT_AMB


# An object on the map's darkest stored light level (all its triangle's corners at it: 0x294B18 gives twice the map's
# highest level, 0x294900) is lit with half the sun and no shine (0x29B645 -> 0x29E544); a suit there also loses the
# ambient lift the game gives them (0x29C9B3: (amb + 1) / 2 -> amb). On the 10 maps stored at level 0 everywhere,
# every model. Off unless TN_DEEP_SHADE=1 (not yet compared with the running game).
var deep_shade := OS.get_environment("TN_DEEP_SHADE") == "1"
var sun_half: DirectionalLight3D


func _apply_deep(node: Node3D, m: Dictionary, x: float, y: float) -> void:
	if not deep_shade or m.is_empty():
		return
	var deep: bool = TNData.level2_at(m, x, y) == 2 * int(m["detail"].get("level_max", 0))
	if node.get_meta("deep", false) == deep and node.has_meta("deep"):
		return
	node.set_meta("deep", deep)
	var dif := map_dif
	var amb := map_amb
	var r := (amb + dif / 4.0) / ((amb + 1.0) / 2.0 + dif / 2.0)   # a suit: deep against normal, at N.L = 0.5
	var stack: Array = [node]
	while not stack.is_empty():
		var nd = stack.pop_back()
		stack.append_array(nd.get_children())
		if nd.has_meta("shadow_twin") or nd is Label3D or not (nd is GeometryInstance3D):
			continue
		if node.has_meta("soldier") or node.has_meta("suit"):
			(nd as GeometryInstance3D).set_instance_shader_parameter("deep", r if deep else 1.0)
		elif (nd as VisualInstance3D).layers == 1 or (nd as VisualInstance3D).layers == DEEP_LAYER:
			(nd as VisualInstance3D).layers = DEEP_LAYER if deep else 1


func _sync_sun_half() -> void:
	if sun_half == null or not deep_shade:
		return
	sun_half.global_transform = sun.global_transform
	sun_half.light_color = sun.light_color
	sun_half.light_energy = 0.5 * sun.light_energy


func _ground_look(base_light: float, base_ambient: float) -> void:
	var amb := base_ambient
	var c := planet_sun * base_light * GROUND_SUN_REF
	ground_light = Color(c.r + sky_haze.r * amb, c.g + sky_haze.g * amb, c.b + sky_haze.b * amb)
	for sm in ground_mats:
		sm.set_shader_parameter("ground_light", Vector3(ground_light.r, ground_light.g, ground_light.b))


# The game projects its world with 1.1 x the focal it draws its sprites with (camera matrix 0x29EB64 against the view's
# focal 0x29EA84): a sprite looks like an object 1 / 1.1 as wide as its width (twice its radius, sprite_width), with
# its bitmap's proportions. (The 21/10/2026 eye fit, 1.2 x radius by 1.5 x taller, matched Terra Nova Plus's HD720
# view, whose focal across is too short: TN_SPRITES_HD720=1 brings that look back, 0.70 x as wide.)
const SPRITE_SCALE := 1.0 / 1.1
const SPRITE_TALL := 1.0
var sprite_hd := 0.70 if OS.get_environment("TN_SPRITES_HD720") == "1" else 1.0


# Simple stand-in shapes, standing on their base, when the game data has no sprite / model.
func _placeholder(shape: String) -> Mesh:
	var mesh: PrimitiveMesh
	match shape:
		"tree":
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 1.1
			cone.height = 4.5
			cone.radial_segments = 7
			cone.rings = 1
			mesh = cone
		"bush":
			var sph := SphereMesh.new()
			sph.radius = 0.7
			sph.height = 1.0
			sph.radial_segments = 8
			sph.rings = 4
			mesh = sph
		_:
			var bx := BoxMesh.new()
			bx.size = Vector3(1.6, 1.0, 1.4)
			mesh = bx
	# lift the shape so that it stands on its base
	var arrays := mesh.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var up := Vector3(0, mesh.get_aabb().size.y * 0.5, 0)
	for i in verts.size():
		verts[i] += up
	arrays[Mesh.ARRAY_VERTEX] = verts
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return out


# Sprite (tree, bush, rock, probe): upright quad turning to face the camera, standing on the node's point (its
# bottom middle), or, for a frame with an anchor, that pixel on the point (the game's rule, 0x29BF41: either word
# non-zero, both used; the probes' discs are centred so). narrow: its width alone (TN_SPRITES_HD720)
func _sprite_quad(sp: Dictionary, width: float, tall: float = 1.0, narrow: float = 1.0) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(width * narrow, width * sp["aspect"] * tall)
	q.center_offset = Vector3(0, q.size.y * 0.5, 0)
	if _sprite_anchored(sp):
		var an: Vector2 = sp["anchor"]
		var px: Vector2 = sp["px"]
		q.center_offset = Vector3(q.size.x * (0.5 - an.x / px.x), q.size.y * (an.y / px.y - 0.5), 0)
	return q


static func _sprite_anchored(sp: Dictionary) -> bool:
	var px: Vector2 = sp.get("px", Vector2.ZERO)
	return sp.get("anchor", Vector2.ZERO) != Vector2.ZERO and px.x > 0.0 and px.y > 0.0


func _sprite_mat(key: Vector2i, sp: Dictionary) -> ShaderMaterial:
	var k := "sprite%s" % key
	if mats.has(k):
		return mats[k]
	var sm := ShaderMaterial.new()                 # upright, facing the camera, alpha cut, no sun: the ground's light
	sm.shader = SPRITE                             # at their foot (_foot_light), hazed as the game does
	sm.set_shader_parameter("tex", sp["texture"])
	mats[k] = sm
	return sm


# A sprite's shadow: the sprite turns to face the camera and its shadow turned with it (it swung round as the player
# looked around, and thinned to a line when he looked across the light). The sprite casts none; a twin of its quad,
# drawn in the shadow passes only, stands facing the light (sprite_shadow.gdshader).
func _sprite_shadow_mat(key: Vector2i, sp: Dictionary) -> ShaderMaterial:
	var k := "shadow%s" % key
	if not mats.has(k):
		var sm := ShaderMaterial.new()
		sm.shader = SPRITE_SHADOW
		sm.set_shader_parameter("tex", sp["texture"])
		mats[k] = sm
	return mats[k]


# (a sprite object's: a child, it follows it and hides with it)
func _sprite_shadow(mi: MeshInstance3D, key: Vector2i, sp: Dictionary) -> void:
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var tw := MeshInstance3D.new()
	tw.set_meta("shadow_twin", true)
	tw.mesh = mi.mesh
	tw.material_override = _sprite_shadow_mat(key, sp)
	tw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	tw.extra_cull_margin = (mi.mesh as QuadMesh).size.x * 0.5    # (turned towards the light: out of the quad's own box)
	mi.add_child(tw)


# Every model of RESTNOBJ.RES in rows on flat ground (planet 0 colors), each with its file name
# and the object types that use it. Models face +X (east).
func _load_gallery() -> void:
	for c in world.get_children():
		c.queue_free()
	var pl: Dictionary = data.load_planet(data.data_dir().path_join("RESPLNT0.RES"))
	pal = pl["palette"] if pl.has("palette") else data.full_palette(PackedByteArray())
	pal_key = "RESPLNT0.RES"
	var users := {}                   # model ref -> names of the object types using it
	for c in objects.refs:
		var arr: Array = objects.refs[c]
		for i in arr.size():
			var nm: String = data.type_name(c, i).strip_edges()
			if nm == "" or nm.begins_with("?"):
				continue
			if not users.has(arr[i]):
				users[arr[i]] = PackedStringArray()
			if not users[arr[i]].has(nm):
				users[arr[i]].append(nm)
	var x := 0.0
	var z := 0.0
	var depth := 0.0
	var n := 0
	for ref in objects.all_models():
		var md: Dictionary = objects.model(ref, pal, pal_key)
		if md.is_empty():
			continue
		var box: AABB = md["mesh"].get_aabb()
		if x > 0.0 and x + box.size.x > 70.0:
			x = 0.0
			z += depth + 4.0
			depth = 0.0
		var mi := MeshInstance3D.new()
		mi.mesh = md["mesh"]
		mi.position = Vector3(x - box.position.x, 0.0, z - box.position.z)
		world.add_child(mi)
		var l := Label3D.new()
		var who: PackedStringArray = users.get(ref, PackedStringArray())
		l.text = md["name"] + ("" if who.is_empty() else "
" + ", ".join(who))
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.font_size = 32
		l.pixel_size = 0.01
		l.outline_size = 8
		l.position = Vector3(box.get_center().x, md["height"] + 0.4, box.get_center().z)
		l.add_to_group("labels")
		l.visible = labels_on
		mi.add_child(l)
		x += box.size.x + 2.0
		depth = maxf(depth, box.size.z)
		n += 1
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(400, 400)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.36, 0.4, 0.34)
	gm.roughness = 1.0
	ground.material_override = gm
	ground.position = Vector3(35, -0.01, z * 0.5)
	world.add_child(ground)
	yaw = 0.0
	pitch = -0.3
	camera.position = Vector3(12, 5, z + depth + 14)
	var args := OS.get_cmdline_user_args()
	var c := args.find("--cam")          # test: --cam x,z,height,yaw_deg,pitch_deg
	if c >= 0 and c + 1 < args.size():
		var v := args[c + 1].split_floats(",")
		camera.position = Vector3(v[0], v[2], v[1])
		yaw = deg_to_rad(v[3])
		pitch = deg_to_rad(v[4])
	camera.rotation = Vector3(pitch, yaw, 0)
	current = {}
	info.text = "Gallery: %d distinct 3D models from RESTNOBJ.RES
(file name, then the object types using it)" % n
	print(info.text.replace("
", " | "))
	var sh := args.find("--shot")
	if sh >= 0 and sh + 1 < args.size():
		_screenshot(args[sh + 1])


# The cells of a grid whose tile is water (0x2B219C: the cell's first point), 1 at y * n + x; empty: none.
func _water_cells(grid: Dictionary, water: PackedByteArray) -> PackedByteArray:
	var tiles: PackedByteArray = grid["tile"]
	var n: int = grid["n"]
	var out := PackedByteArray()
	out.resize(n * n)
	var any := false
	for i in n * n:
		if water[tiles[i]] == 1:
			out[i] = 1
			any = true
	return out if any else PackedByteArray()


func _water_mat(pl: Dictionary, grid: Dictionary, origin: Vector2, step: float, tint: Color) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = WATER
	sm.set_shader_parameter("tiles", pl["textures"])
	sm.set_shader_parameter("water_mask", pl["water_mask"])
	sm.set_shader_parameter("tilemap", ImageTexture.create_from_image(grid["tilemap"]))
	sm.set_shader_parameter("origin", origin)
	sm.set_shader_parameter("step_size", step)
	sm.set_shader_parameter("grid_n", float(grid["n"]))
	sm.set_shader_parameter("tint", Vector3(tint.r, tint.g, tint.b))
	sm.set_shader_parameter("plain", ir_on)
	var far: Color = pl.get("water_far", Color(0.41, 0.54, 0.5))
	sm.set_shader_parameter("water_far", far)
	var fp: PackedColorArray = pl.get("palette", PackedColorArray())
	if fp.size() >= 256:
		var pimg := Image.create(256, 1, false, Image.FORMAT_RGB8)
		for i in 256:
			pimg.set_pixel(i, 0, fp[i])
		sm.set_shader_parameter("pal_tex", ImageTexture.create_from_image(pimg))
		sm.set_shader_parameter("has_pal", true)
	ground_mats.append(sm)
	water_mats.append(sm)
	_sky_to(sm)
	return sm


func _ground_mat(pl: Dictionary, grid: Dictionary, origin: Vector2, step: float) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = GROUND
	sm.set_shader_parameter("tiles", pl["textures"])
	sm.set_shader_parameter("tiles_soft", pl["textures"])
	sm.set_shader_parameter("tiles_wrap", pl["textures"])
	if pl.get("tiles_lit") != null:                     # lit per palette index through the shade rows, as the game
		sm.set_shader_parameter("tiles_lit", pl["tiles_lit"])
		sm.set_shader_parameter("tiles_lit_soft", pl["tiles_lit"])
		sm.set_shader_parameter("tile_count", float(pl["count"]))
		sm.set_shader_parameter("per_index", true)
	if pl.get("tiles_idx") != null and pl.get("shade_idx") != null:   # (live, old school: _sky_to adds the haze rows)
		sm.set_shader_parameter("tiles_idx", pl["tiles_idx"])
		sm.set_shader_parameter("shade_idx", pl["shade_idx"])
	if pl.get("ir_lut") != null:
		sm.set_shader_parameter("ir_lut", pl["ir_lut"])
		sm.set_shader_parameter("has_ir", true)
	sm.set_shader_parameter("game_colours", live)
	sm.set_shader_parameter("tilemap", ImageTexture.create_from_image(grid["tilemap"]))
	sm.set_shader_parameter("origin", origin)
	sm.set_shader_parameter("step_size", step)
	sm.set_shader_parameter("grid_n", float(grid["n"]))
	var rows: PackedFloat32Array = pl.get("rows", PackedFloat32Array())
	if rows.size() == 16:
		sm.set_shader_parameter("light_rows", rows)
	sm.set_shader_parameter("ground_light", Vector3(ground_light.r, ground_light.g, ground_light.b))
	var t0 := Time.get_ticks_msec()
	sm.set_shader_parameter("relief", ImageTexture.create_from_image(_relief_image(grid["h"], grid["n"], step)))
	sm.set_shader_parameter("has_relief", true)
	print("relief %dx%d : %d ms" % [grid["n"], grid["n"], Time.get_ticks_msec() - t0])
	ground_mats.append(sm)
	_sky_to(sm)
	return sm


# Relief of a height grid for the ground shader: hollows darker, crests lighter. The height minus its blur at two
# sizes (about 3 and 12 world units), each scaled by its spread over the map; one texel per grid vertex, 0.5 =
# unchanged (the shader adds 0.5).
func _relief_image(h: PackedFloat32Array, n: int, step: float) -> Image:
	var fine := _box_blur(h, n, maxi(1, roundi(3.0 / step)))
	var wide := _box_blur(h, n, maxi(1, roundi(12.0 / step)))
	var s1 := 0.0
	var s2 := 0.0
	for i in n * n:
		s1 += (h[i] - fine[i]) * (h[i] - fine[i])
		s2 += (h[i] - wide[i]) * (h[i] - wide[i])
	s1 = maxf(sqrt(s1 / (n * n)), 1e-4)
	s2 = maxf(sqrt(s2 / (n * n)), 1e-4)
	var data := PackedByteArray()
	data.resize(n * n)
	for i in n * n:
		var m := 1.0 + clampf((h[i] - fine[i]) / s1 * 0.07 + (h[i] - wide[i]) / s2 * 0.07, -0.3, 0.2)
		data[i] = clampi(roundi((m - 0.5) * 255.0), 0, 255)
	return Image.create_from_data(n, n, false, Image.FORMAT_R8, data)


# Box blur of an n x n grid, radius r (edges clamped), in two passes of running sums.
func _box_blur(src: PackedFloat32Array, n: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(n * n)
	var out := PackedFloat32Array()
	out.resize(n * n)
	var w := float(2 * r + 1)
	for y in n:
		var row := y * n
		var acc := 0.0
		for k in range(-r, r + 1):
			acc += src[row + clampi(k, 0, n - 1)]
		for x in n:
			tmp[row + x] = acc / w
			acc += src[row + mini(x + r + 1, n - 1)] - src[row + maxi(x - r, 0)]
	for x in n:
		var acc := 0.0
		for k in range(-r, r + 1):
			acc += tmp[clampi(k, 0, n - 1) * n + x]
		for y in n:
			out[y * n + x] = acc / w
			acc += tmp[mini(y + r + 1, n - 1) * n + x] - tmp[maxi(y - r, 0) * n + x]
	return out


# The sky's clouds and haze to a material that mirrors them (water plane, water tiles of the ground).
func _sky_to(sm: ShaderMaterial) -> void:
	sm.set_shader_parameter("has_clouds", sky_clouds != null)
	sm.set_shader_parameter("has_haze_lut", sky_haze_lut != null)
	if sky_haze_lut != null:
		sm.set_shader_parameter("haze_lut", sky_haze_lut)
		sm.set_shader_parameter("haze_lut_idx", sky_haze_idx)
	if sky_clouds != null:
		sm.set_shader_parameter("clouds", sky_clouds)
	sm.set_shader_parameter("haze", Vector3(sky_haze.r, sky_haze.g, sky_haze.b))
	sm.set_shader_parameter("reflect_gain", 0.8)
	if sky_clouds != null:
		sm.set_shader_parameter("clouds_soft", sky_clouds)
	sm.set_shader_parameter("light", Vector3(sky_light.r, sky_light.g, sky_light.b))
	sm.set_shader_parameter("sun_dir", sun_to)
	sm.set_shader_parameter("desat", 1.0 / LIVE_SATURATION if live else 1.0)
	sm.set_shader_parameter("modern", _is_modern())


# The planet's IR colours (RESPLNT 66 through tables 59-62) to the passes over the view (old school, infrared): in IR,
# what the ground, the plants and the models drew in them is kept, the rest goes through the old luma ramp.
func _ir_colours(pl: Dictionary) -> void:
	var cols: Array = pl.get("ir_colours", [])
	var img := Image.create(64, 1, false, Image.FORMAT_RGB8)
	for i in mini(cols.size(), 64):
		img.set_pixel(i, 0, cols[i])
	var tex := ImageTexture.create_from_image(img)
	for r in [oldschool_rect, ir_rect]:
		if r != null:
			(r.material as ShaderMaterial).set_shader_parameter("ir_pal", tex)
			(r.material as ShaderMaterial).set_shader_parameter("ir_n", mini(cols.size(), 64))


# Old school off (F12, and the map viewer): the modern sky and water (sky_common.gdshaderinc); on: the game's.
func _is_modern() -> bool:
	return oldschool_rect == null or not oldschool_rect.visible


# The planet's ambiance (PLANET_LOOK) over the live look, once per map, after its sky (whose haze the fog starts from).
# Also called by the lab, for the map viewer. The sun's and the ambient's strength: the planet's, tuned on the maps
# that have the usual pair (DEFAULT_DIF / DEFAULT_AMB), scaled by the map's own (map_dif, map_amb: res 82). The night
# planet and the storm sky take planet 0's: their darkness is in their maps' pair.
func planet_look(planet: String, sky_file: String) -> void:
	var a: Dictionary = PLANET_LOOK.get(sky_file.get_file().to_upper(), PLANET_LOOK.get(planet.to_upper(), {}))
	var base: Dictionary = a
	if sky_file.get_file().to_upper() == "SKY0S.RES" or planet.to_upper() == "RESPLNT4.RES":
		base = PLANET_LOOK["RESPLNT0.RES"]
	_haze_fog(haze_k)
	env.fog_light_color = env.fog_light_color.lerp(a.get("tint", Color.WHITE), a.get("tint_mix", 0.0))
	# the sun lights the models (the ground takes the planet's sun colour in ground_light): white, as the game shades
	# them through its shade rows (RESPLNT 53), which keep a grey grey on every planet. A tinted sun showed once
	# the maps' own light (res 82) made it the models' main light: MAP10's 1.36 x the sun and 0.16 x the sky's ambient
	# turned the temperate planet's warm sun into khaki buildings and olive weapons
	planet_sun = a.get("sun", Color.WHITE)
	sun.light_color = Color.WHITE
	sun.light_energy = base.get("light", LIVE_LIGHT) * map_dif / DEFAULT_DIF
	env.ambient_light_sky_contribution = base.get("ambient", LIVE_AMBIENT) * map_amb / DEFAULT_AMB
	_ground_look(base.get("light", LIVE_LIGHT), env.ambient_light_energy * base.get("ambient", LIVE_AMBIENT))
	env.adjustment_saturation = a.get("sat", LIVE_SATURATION)
	env.adjustment_contrast = a.get("contrast", 1.0)
	env.adjustment_brightness = a.get("bright", 1.0)
	for sm in ground_mats:
		sm.set_shader_parameter("sparkle", a.get("sparkle", 0.0))
	_haze_globals()                               # (after the view's adjustments: the haze colour goes through them)
	if env_nofog_cache != null:                   # the coop's maps: the same colours
		for p in ["ambient_light_sky_contribution", "adjustment_saturation", "adjustment_contrast", "adjustment_brightness"]:
			env_nofog_cache.set(p, env.get(p))


# The depth fog for haze radius k (see LIVE_FOG_BEGIN): the mission's, or the one the running game draws with (the
# bridge's 'HAZE': Terra Nova Plus's FAR distance makes it 180)
var haze_k := 99


func _haze_fog(k: float) -> void:
	haze_k = roundi(k)
	env.fog_depth_begin = 20.0 + 16.0 * k / 99.0
	env.fog_depth_end = 20.0 + 300.0 * k / 99.0
	env.fog_depth_curve = LIVE_FOG_CURVE
	env.fog_density = LIVE_FOG_MAX
	_haze_globals()


# The haze of the shaders that draw it as the game does (tn_haze.gdshaderinc: the ground, the water, the sprites, the
# suits, the effects): in live mode the game's levels from the haze radius k, each a share of the way to the haze
# colour in the palette's values (measured on the running game, MISS10, its table forced to one level: 0.11 at
# level 4, 0.27 at 8, 0.49 at 12, 0.70 at 15, towards the sky's own haze colour, SKY 150 level 15); the colour is
# taken back through the view's contrast and saturation (applied after, in sRGB: the haze then ends on the sky's own
# colour, as in the game). The map viewer keeps its exponential fog. Godot's fog (env) still hazes the models.
const HAZE_SHARE_A := 0.019      # share at level L: (A + B L) L
const HAZE_SHARE_B := 0.00185


func _haze_globals() -> void:
	var c := env.fog_light_color
	var r := Vector4.ZERO
	var b := 1.0
	if env.fog_enabled and env.fog_mode == Environment.FOG_MODE_DEPTH:
		r = Vector4(maxf(float(haze_k), 1.0), HAZE_SHARE_A, HAZE_SHARE_B, 1.0)
		if env.adjustment_enabled:
			b = maxf(env.adjustment_brightness, 0.01)
			var v := Vector3(c.r, c.g, c.b)
			var m := (v.x + v.y + v.z) / 3.0
			v = Vector3(m, m, m) + (v - Vector3(m, m, m)) / maxf(env.adjustment_saturation, 0.01)
			v = Vector3(0.5, 0.5, 0.5) + (v - Vector3(0.5, 0.5, 0.5)) / maxf(env.adjustment_contrast, 0.01)
			c = Color(v.x, v.y, v.z)
	elif env.fog_enabled:
		r = Vector4(env.fog_density, 0.0, 0.0, 2.0)
	RenderingServer.global_shader_parameter_set("tn_haze_color", Vector4(c.r, c.g, c.b, b))
	RenderingServer.global_shader_parameter_set("tn_haze_range", r)
	var on := live and env.adjustment_enabled
	RenderingServer.global_shader_parameter_set("tn_view_bcs", Vector4(env.adjustment_brightness,
			env.adjustment_contrast, env.adjustment_saturation, 1.0) if on else Vector4(1, 1, 1, 0))


# The cloud ceiling (mission resource 178): a plane at cloud_h, 1 texel a unit, seen from the eye (0x2A7222:
# cloud_h - 8 x the eye's height): the shaders' texels per unit of slope, 44 at MISS30's start (1080, eye 6.18). The
# wind moves it (live: the game's own offset, SKYO; the viewer: from the mission's wind); the desert missions' clouds
# also ripple and sway in a circle of 30 texels (0x2A6F38). At most 10 times a second (a sky's change redraws its light).
var mis_params := {}
var cloud_base := Vector2.ZERO         # texels (column, row)
var cloud_set := Vector2(-1.0, -1.0)   # (cloud_px, time) last set
var cloud_sway := 0                    # live: the game's sway phase
var cloud_live_t := 0
var ripple_img: Image
var ripple_tex: ImageTexture
const CLOUD_REF := 1030.56             # 1080 - 8 x 6.18
const TICK_HZ := 280.0                 # the game's clock (not measured: the map viewer's wind and ripple speed)
var ripple_sin := PackedInt32Array()


# The game picks its sky's haze level per screen row, at the row's end (sky.gdshader ceiling_r): the main camera's
# axes and the tangent of half its width, given to the sky just before each frame is drawn.
func _sky_rows() -> void:
	if camera == null or env == null or env.sky == null or not (env.sky.sky_material is ShaderMaterial):
		return
	var sm := env.sky.sky_material as ShaderMaterial
	var b := camera.global_transform.basis.orthonormalized()
	var px := camera.get_camera_projection().x.x
	sm.set_shader_parameter("row_right", b.x)
	sm.set_shader_parameter("row_up", b.y)
	sm.set_shader_parameter("row_fwd", -b.z)
	sm.set_shader_parameter("row_edge", 1.0 / px if px > 0.0 else 0.0)


func _clouds_update() -> void:
	if mis_params.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now - cloud_set.y < 0.1:
		return
	var dt := now - cloud_set.y if cloud_set.y > 0.0 else 0.0
	var mats_c: Array = ground_mats + [mats["water"]]
	if env.sky.sky_material is ShaderMaterial:
		mats_c.append(env.sky.sky_material)
	var px := 44.0 * maxf(64.0, float(mis_params["cloud_h"]) - 8.0 * camera.position.y) / CLOUD_REF
	var ticks := now * TICK_HZ
	if live:
		ticks = cloud_sway / 193.0
	else:
		var a: float = mis_params["wind_angle"]
		cloud_base += float(mis_params["wind_speed"]) / 65536.0 * dt * TICK_HZ * Vector2(cos(a), sin(a))
		cloud_base = Vector2(fposmod(cloud_base.x, 256.0), fposmod(cloud_base.y, 256.0))
	var off := cloud_base
	var desert: bool = mis_params["desert"]
	if desert:
		var phi := (floorf(193.0 * ticks) / 256.0) / 65536.0 * TAU
		off += Vector2(30.0 * sin(phi), 30.0 * cos(phi))
		_ripple_tables(ticks)
	for sm in mats_c:
		sm.set_shader_parameter("cloud_px", px)
		sm.set_shader_parameter("cloud_off", off)
		sm.set_shader_parameter("has_ripple", desert)
		if desert:
			sm.set_shader_parameter("ripple", ripple_tex)
	cloud_set = Vector2(px, now)


# The two 256-entry tables of the desert clouds (0x2A6F38): two waves each (1 and 3 periods over the table, 6144 and
# 1536 x the game's biased sine S[k] = int((sin(2 pi k / 1024) 65536 + 65536) / 513), / 65536), their phases V x
# ticks / 65536 index units: 1797 and 16384 (columns, 0x425200), 2615 and 14099 (rows, 0x425300).
static func ripple_table(ticks: float, v1: int, v2: int, sn: PackedInt32Array) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(256)
	var p1 := int(floorf(v1 * ticks / 65536.0))
	var p2 := int(floorf(v2 * ticks / 65536.0))
	for i in 256:
		out[i] = ((6144 * sn[(4 * i + p1) & 1023]) >> 16) + ((1536 * sn[(12 * i + p2) & 1023]) >> 16)
	return out


static func ripple_sine() -> PackedInt32Array:
	var sn := PackedInt32Array()
	sn.resize(1024)
	for k in 1024:
		sn[k] = int((sin(TAU * k / 1024.0) * 65536.0 + 65536.0) / 513.0)
	return sn


func _ripple_tables(ticks: float) -> void:
	if ripple_sin.is_empty():
		ripple_sin = ripple_sine()
	var d := ripple_table(ticks, 1797, 16384, ripple_sin) + ripple_table(ticks, 2615, 14099, ripple_sin)
	if ripple_img == null:
		ripple_img = Image.create_from_data(256, 2, false, Image.FORMAT_R8, d)
		ripple_tex = ImageTexture.create_from_image(ripple_img)
	else:
		ripple_img.set_data(256, 2, false, Image.FORMAT_R8, d)
		ripple_tex.update(ripple_img)


func _apply_look() -> void:
	var m := _is_modern()
	if env.sky.sky_material is ShaderMaterial:
		(env.sky.sky_material as ShaderMaterial).set_shader_parameter("modern", m)
	for sm in ground_mats + [mats["water"]]:
		sm.set_shader_parameter("modern", m)


const PITCH_SIGN := 1.0   # a mission record's pitch: nose up for > 0 (not compared with the game yet, MISS16 #20)


# team: the mission's side of its group (1 = the player's; 0: unknown, told from the type's name); pitch: the mission
# record's (classes 0, 3 and 4; vehicles and building type 0x2F lie on the slope instead, 0x29DD64); state: a decor
# object's picture (1: hit once, its burnt stump; the mission file or the live game say so).
func _add_object(m: Dictionary, cls: int, sub: int, x: float, y: float, heading: float, group: String,
		label: bool, z: float = 0.0, team: int = 0, pitch: float = 0.0, state: int = 0) -> MeshInstance3D:
	var name: String = data.type_name(cls, sub)
	var low := name.to_lower()
	var ground := TNData.height_at(m, x, y)
	# z = height above the ground; the mission files leave it at 0 except for the Nid d'aigle bridge
	# (spanning a ravine): ships then sit on the ground / dock, probes are shown hovering a little
	var lift := z
	if z == 0.0 and cls == 3 and (low.contains("sonde") or low.contains("probe")):
		lift = 3.0
	var mi := MeshInstance3D.new()
	var top := 0.0
	var ref: Vector2i = objects.ref_for(cls, sub, state) if objects_ok else Vector2i.ZERO
	var no_picture := objects_ok and cls == 0 and state != 0 and ref == Vector2i.ZERO   # (the game draws nothing)
	mi.set_meta("state", state)
	var soldier := false
	if cls == 1 and objects_ok:
		var suit := TNObjects.suit_of(sub)
		top = _add_mech(mi) if suit == TNObjects.MECH_SUIT else _add_soldier(mi, suit, _pirate_arms(suit, x, y))
		soldier = top > 0.0
	# "Fumee" (4/61): the game deletes it right after loading it (one puff of 1186, 0.9 s): nothing to draw. The old
	# smoke column (looping for ever) is kept behind FUMEE_COLUMN, at the game's 14 frames a second
	var fumee := cls == 4 and sub == TNObjects.SMOKE_TYPE and objects_ok
	if fumee:
		mi.visible = false
	if fumee and FUMEE_COLUMN:
		var sm: Dictionary = objects.anim(TNObjects.SMOKE_ANIM, pal, pal_key)
		if not sm.is_empty():
			mi.visible = true
			var q := QuadMesh.new()
			q.size = Vector2(SMOKE_WIDTH, SMOKE_WIDTH * sm["size"].y / sm["size"].x)
			q.center_offset = Vector3(0, q.size.y * 0.5, 0)
			mi.mesh = q
			var smat := ShaderMaterial.new()
			smat.shader = SMOKE
			smat.set_shader_parameter("frames", sm["tex"])
			smat.set_shader_parameter("frame_count", sm["frames"])
			smat.set_shader_parameter("fps", 1000.0 / float(objects.fx_def(15).get("ms", 71)))
			mi.material_override = smat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.extra_cull_margin = SMOKE_WIDTH
			top = q.size.y
	if soldier or mi.mesh != null or fumee:
		pass
	elif TNObjects.is_model(ref):
		# lamps (types 56 / 57): their colour and full brightness (tn_objects.gd LAMP_TYPES); 57 waits for the alarm
		var lamp := TNObjects.lamp_state(cls, sub, live_alarm)
		var md: Dictionary = objects.model(ref, pal, pal_key, PackedByteArray(), lamp)
		if not md.is_empty():
			mi.mesh = md["mesh"]
			top = md["height"]
			if md["params"] > 0:
				mi.set_meta("art_ref", ref)              # articulated parts: posed by the live game (_live_arts)
			if lamp != TNObjects.LAMP_NONE:
				mi.set_meta("lamp", [ref, cls, sub])
				mi.add_to_group("lamps")
			if cls == 2 or (cls == 4 and sub == MINE_TYPE):
				mi.set_meta("half", md["half_len"])      # (its pitch on the ground: _ground_pitch)
			if cls == 3 and sub >= SHIP_FIRST and sub <= SHIP_LAST:
				mi.set_meta("foot", _foot_of(md["mesh"]))   # (kept out of the slopes: _ship_lift)
	elif TNObjects.is_sprite(ref):
		var sp: Dictionary = objects.sprite(ref, pal, pal_key)
		if not sp.is_empty():
			var q := _sprite_quad(sp, objects.sprite_width(cls, sub) * SPRITE_SCALE, SPRITE_TALL, sprite_hd)
			mi.mesh = q
			if _sprite_anchored(sp):
				mi.set_meta("anchored", true)          # its anchor on the game's point itself (_live_place)
			mi.material_override = _sprite_lit_row(ref, sp, m, _foot_row(m, x, y)) if _sprites_per_index(m) 					else _sprite_lit(ref, sp, _foot_light(m, x, y))   # lit like the vegetation
			_sprite_shadow(mi, ref, sp)
			top = q.size.y
	# nothing usable in the data (e.g. the biped mech): a box; not for the Fumee the game deletes at load, nor a hit
	# decor whose second picture is none
	if mi.mesh == null and not soldier and not fumee and not no_picture:
		var box := BoxMesh.new()
		match cls:
			0:
				box.size = Vector3(1.2, 1.2, 1.2)
				mi.material_override = mats["decor"]
			1:
				box.size = Vector3(0.5, 1.4, 0.5)
				mi.material_override = mats["friend"] if (team == 1 or (team == 0 and data.is_friendly(name))) else mats["enemy"]
			2, 3:
				box.size = Vector3(1.4, 0.8, 1.4)
				mi.material_override = mats["friend"] if (team == 1 or (team == 0 and data.is_friendly(name))) else mats["enemy"]
			_:
				box.size = Vector3(4, 3, 4)
				mi.material_override = mats["building"]
		mi.mesh = box
		top = box.size.y
		lift += box.size.y * 0.5
		top -= box.size.y * 0.5
	mi.position = Vector3(x, ground + lift, y)
	mi.rotation.y = -heading
	if (cls == 2 or (cls == 4 and sub == MINE_TYPE)) and mi.has_meta("half"):   # a vehicle or a mine: pitched with
		# the ground as the game draws it (0x29DD64)
		mi.basis = Basis(Vector3.UP, -heading) * Basis(Vector3(0, 0, 1), _ground_pitch(m, x, y, heading, mi.get_meta("half")))
	elif pitch != 0.0 and TNObjects.is_model(ref) and (cls == 0 or cls == 3 or (cls == 4 and sub != MINE_TYPE)):
		mi.rotate_object_local(Vector3(0, 0, 1), PITCH_SIGN * pitch)   # (models face +X: their side axis is Z)
	mi.set_meta("lift", lift)
	world.add_child(mi)
	if soldier or TNObjects.is_model(ref):         # (sprites take the light at their foot: _foot_light)
		mi.set_meta("deep_ok", true)
		_apply_deep(mi, m, x, y)
	if label:
		var l := Label3D.new()
		l.text = name if group == "" or group.begins_with("(NULL") or group.begins_with("DEFAULT") else "%s\n[%s]" % [name, group]
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.font_size = 36
		l.pixel_size = 0.02
		l.outline_size = 10
		l.visibility_range_end = 140.0
		l.position = Vector3(0, top + 1.0, 0)
		l.add_to_group("labels")
		l.visible = labels_on
		mi.add_child(l)
	return mi


const PIRATE_SUIT := 9
const CAPTAIN_SUIT := 10
const CAPTAIN_ARM := 12605.0 / 32768.0    # the game's odds for each arm (rand 0..0x7FFF mod 13 < 5)


# The map viewer cannot know which pirates the game gives captain arms (its random draws at mission start, seeded 0,
# depend on every draw before): each arm drawn with the game's odds from the mission and the place, the same at each
# load. Live, the bridge's ARMS packet tells the real ones (_live_arms).
func _pirate_arms(suit: int, x: float, y: float) -> int:
	if suit != PIRATE_SUIT:
		return 0
	var h := hash("%s/%.3f/%.3f" % [mission_tag, x, y])
	var out := 0
	if float(h & 0x7FFF) / 32768.0 < CAPTAIN_ARM:
		out |= 1
	if float((h >> 15) & 0x7FFF) / 32768.0 < CAPTAIN_ARM:
		out |= 2
	return out


# A pirate whose arms the game drew otherwise than the viewer's guess: built again.
func _live_arms(idx: int, arms: int) -> void:
	var node := _live_node(idx)
	if node == null or not node.has_meta("soldier") or node.has_meta("corpse") or int(node.get_meta("suit", -1)) != PIRATE_SUIT:
		return
	if int(node.get_meta("arms", 0)) == arms:
		return
	for part in node.get_meta("soldier"):
		(part[0] as Node).queue_free()
	_add_soldier(node, PIRATE_SUIT, arms)
	node.remove_meta("size")                     # (its standing lengths were reset: its own sizes put back, SLEN)


const LIMB_WPX := 1.0 / 256.0   # a limb sprite's pixel across its bone, in world units (the game's part +4 = 256)
const LIMB_PULL := 0.05          # a standing suit's feet and shins drawn this much nearer the camera (_add_soldier)

# Power suit in its standing pose (see TEMPLATE_POSE); the limbs become children of holder.
# Joints of skeletons 884 / 885: 0/1 toes, 2/3 ankles, 4/5 knees, 6/7 hips, 8 pelvis, 9 neck,
# 10/11 shoulders, 12/13 elbows, 14/15 hands. Returns the suit height (0 when it has no sprites).
# arms: a pirate's (suit 9) captain arms, bit 0 the right one (segments 3, 4), bit 1 the left (9, 10): the game draws
# each, at the pirate's creation, with the captain's sprites (suit 10) 5 times in 13 (0x27F150).
func _add_soldier(holder: Node3D, suit: int, arms := 0) -> float:
	var segs: Array = objects.skeleton(suit)
	var limbs := {}                                    # segment index -> its limb
	var lsuit := {}                                    # segment index -> the suit its sprites come from
	for k in segs.size():
		var sg: Array = segs[k]
		var es := suit
		if suit == PIRATE_SUIT and ((k in [3, 4] and arms & 1) or (k in [9, 10] and arms & 2)):
			es = CAPTAIN_SUIT
		var ld: Dictionary = objects.limb(es, sg[2], pal, pal_key)
		if ld.is_empty():
			return 0.0
		limbs[k] = ld
		lsuit[k] = es
	var p := _soldier_pose(suit, segs, limbs)
	var parts := []
	for k in segs.size():
		var sg: Array = segs[k]
		var ld: Dictionary = limbs[k]
		var seg := MeshInstance3D.new()
		seg.mesh = _limb_quad(ld)
		seg.material_override = _limb_mat(lsuit[k], sg[2], ld)
		# a left limb: the right one's sprite, mirrored (per instance: both sides share the material)
		seg.set_instance_shader_parameter("mirror", 1.0 if int(sg[3]) & 1 else 0.0)
		# drawn nearer the camera than they are (limb.gdshader pull): the feet and shins only, a sole reaching under
		# the ground (0.25 for the whole suit: one just behind a wall showed through it)
		(seg.material_override as ShaderMaterial).set_shader_parameter("pull", LIMB_PULL if maxi(sg[0], sg[1]) <= 5 else 0.0)
		holder.add_child(seg)
		parts.append([seg, sg[0], sg[1], float(ld["len"]), float(ld["size"].x), _part_scale(suit, sg[2]), int(sg[4])])
	holder.set_meta("soldier", parts)
	holder.set_meta("suit", suit)
	holder.set_meta("arms", arms)
	holder.set_meta("leg_rest", [p[6].distance_to(p[4]), p[4].distance_to(p[2]), p[7].distance_to(p[5]),
			p[5].distance_to(p[3])])          # thighs and shins standing (see _leg_lengths)
	holder.set_meta("stand", p)              # and its arms (_arms_back)
	return _pose_soldier(holder, p) + 0.1


# Facing of a left / right pair of joints, in node axes (forward = +X, right = +Z): level, square to the pair.
func _facing(left: Vector3, right: Vector3) -> Vector3:
	var r := right - left                             # (right, up, forward)
	var f := r.cross(Vector3.UP)
	f.y = 0.0
	if f.length() < 0.0001:
		return Vector3(1, 0, 0)
	f = f.normalized()
	return Vector3(f.z, 0.0, f.x)


# The views the game's limb drawer 0x2F6C50 picks for a suit's limbs (live: the bridge's reference vectors, 'refs'
# meta, taken once): n = (eye -> joint a) x bone, normalized, X = asin(n . R) through its 64-step table (0x30FB60),
# R the reference vector of the limb's chain (skeleton byte 2; the suit's record +0x26F, 12 bytes a chain);
# (eye -> joint a) . R > 0: 90 deg - X, else 270 deg + X, in 16 views rounded; a left limb (flags bit 0) takes
# (16 - v) & 15 mirrored, a 9-view torso 16 - v mirrored past 8. Worked out in the suit's own frame (the bridge's
# (right, up, forward), a turn of the game's: the same cross products; refs[0] = -1 when it is upside down).
# {limb node: Vector2(view, 1 or -1 mirrored)}, empty without refs.
func _game_views(holder: Node3D, p: Array) -> Dictionary:
	var out := {}
	var refs: Array = holder.get_meta("refs", [])
	holder.remove_meta("refs")
	var cam := get_viewport().get_camera_3d()
	if refs.size() != 6 or cam == null:
		return out
	var e := _node_axes(holder.global_transform.affine_inverse() * cam.global_position)
	e.y /= SUIT_SQUASH
	var hand := -float(refs[0])
	for part in holder.get_meta("soldier"):
		if part[6] >= 5:
			continue
		var a: Vector3 = p[part[1]]
		var v := a - e
		var nn := v.cross((p[part[2]] as Vector3) - a)
		var r: Vector3 = refs[1 + part[6]]
		var c := 0.0 if nn.length() < 1e-6 else hand * nn.normalized().dot(r)
		var q := asin(floorf(clampf(c, -1.0, 1.0) * 64.0) / 64.0) / (PI / 2.0)
		var psi := 4.0 - 4.0 * q if v.dot(r) > 0.0 else 12.0 + 4.0 * q
		var vw := int(floorf(psi + 0.5)) & 15
		var f := 1.0
		var seg: MeshInstance3D = part[0]
		if float(seg.get_instance_shader_parameter("mirror")) > 0.5:
			vw = (16 - vw) & 15
			f = -1.0
		var mat := seg.material_override as ShaderMaterial
		if mat != null and int(mat.get_shader_parameter("view_count")) < 16 and vw > 8:
			vw = 16 - vw
			f = -f
		out[seg] = Vector2(vw, f)
	return out


# Puts a soldier's limbs on its 16 joints, (right, up, forward) from the ground under it: its pose at load, then
# in live mode the game's own joints every frame (walking, arms, aiming). Returns the highest joint.
func _pose_soldier(holder: Node3D, p: Array, knees_given := false) -> float:
	if holder.has_meta("leg_rest") and not holder.has_meta("corpse") and not knees_given:
		p = _leg_lengths(p, holder.get_meta("leg_rest"))
	var top := 0.0
	# last guard: a bone far longer than its limb (joints the game left where it last drew the suit) is not drawn, the
	# suit keeps its previous pose (each sprite is scaled by its bone: such a limb came out several times too big)
	if _bones_long(holder, p):
		return -1.0
	# the body's right, which sets each limb's front (the views turn around the bone): the hips' line for the legs
	# and feet, the shoulders' for the torso and arms (joints 6 / 7 hips, 10 / 11 shoulders). Front = right x bone:
	# a leg hanging down faces forward, a foot (the same leg turned forward at the ankle) faces up
	var r_hips := _node_axes(p[7] - p[6])
	var r_top := _node_axes(p[11] - p[10])
	# live, a pose the game drew: each limb's view picked as the game does, from its chain's reference vector
	# (_game_views); the suit's own steps and the map viewer: from the limb's front below (limb.gdshader)
	var gv := _game_views(holder, p)
	for part in holder.get_meta("soldier"):
		var a: Vector3 = p[part[1]]
		var b: Vector3 = p[part[2]]
		var ga := _node_axes(a) * Vector3(1.0, SUIT_SQUASH, 1.0)
		var gb := _node_axes(b) * Vector3(1.0, SUIT_SQUASH, 1.0)
		var dir := _node_axes(b - a)                     # (scale from the true bone)
		var sc: float = maxf(dir.length(), 0.001) / part[3]
		var yn := dir.normalized() if dir.length() > 0.0001 else Vector3.DOWN
		var r: Vector3 = r_hips if maxi(part[1], part[2]) <= 8 else r_top
		var side := r - yn * r.dot(yn)
		if side.length() < 0.2 * r.length():             # bone along the body's right (arm held out sideways):
			side = (Vector3.UP - yn * yn.y) * signf(r.dot(yn))   # its front is still the body's forward
		side = side.normalized()
		var xn := side.cross(yn).normalized()
		var seg: MeshInstance3D = part[0]
		# across the bone: the game's fixed 1/256 unit a sprite pixel (limb.gdshader), not the bone's scale
		seg.transform = Transform3D(Basis(xn * LIMB_WPX, yn * sc, xn.cross(yn) * LIMB_WPX), ga)
		seg.set_instance_shader_parameter("game_view", gv.get(part[0], Vector2(-1.0, 1.0)))
		seg.extra_cull_margin = maxf(part[4] * LIMB_WPX, part[3] * sc)
		top = maxf(top, maxf(ga.y, gb.y))
	return top


# The game rewrites a suit's toes, ankles, hips, pelvis and neck every frame but its knees, shoulders, elbows and
# hands only when it draws the suit: the player's own (never drawn, seen from inside) and the ones the bridge reads
# between two game frames lag behind, and the walk replayed for the far suits (walk_anim.py, learnt from such poses,
# often another type's) keeps them: thighs and shins from 0.4 to 1.5 x their length along a stride (each limb sprite,
# stretched to its bone, grew and shrank), arms off the shoulders. Each knee is put back from the hip and the ankle, two
# bones of the suit's standing length bent forwards, every frame (only the stretched ones, and the bones jumped from
# one way to the other: spasms). A suit walking on its own steps lowers its pelvis to keep within LEG_REACH (_gait).
const LEGS := [[6, 4, 2, 0], [7, 5, 3, 1]]     # hip, knee, ankle, toe (left, right)
const LEG_REACH := 0.98
const LEG_SOFT := 0.04
const LEG_KEEP := 0.04


func _leg_lengths(p: Array, rest: Array) -> Array:
	var q := p.duplicate()
	for s in 2:
		var leg: Array = LEGS[s]
		var l1: float = rest[2 * s]
		var l2: float = rest[2 * s + 1]
		var hip: Vector3 = q[leg[0]]
		var d: Vector3 = (q[leg[2]] as Vector3) - hip
		var dl := d.length()
		if l1 <= 0.0 or l2 <= 0.0 or dl < 0.001:
			continue
		# a knee the game has just drawn already sits a thigh from the hip and a shin from the ankle (within 1.5 %
		# measured): kept as it is, whichever way it bends (a stride's leg turned out, a foot up on a step); only the
		# stale ones are put back
		var gk: Vector3 = (q[leg[1]] as Vector3) - hip
		if absf(gk.length() / l1 - 1.0) < LEG_KEEP and absf(((q[leg[2]] as Vector3) - (q[leg[1]] as Vector3)).length() / l2 - 1.0) < LEG_KEEP:
			continue
		var dn := d / dl
		# near a straight leg the knee's bend changes fast with the reach (a standing suit, its ankle a hair nearer or
		# farther each frame: the knee jumped from straight to bent, it stuttered in place): over the last LEG_SOFT of
		# the reach it straightens smoothly, never quite (the shin a hair longer to the ankle)
		var full := l1 + l2
		var soft := full * LEG_SOFT
		if dl > full - soft:
			dl = full - soft + soft * (1.0 - exp(-(dl - full + soft) / soft))
		var a := (l1 * l1 - l2 * l2 + dl * dl) / (2.0 * dl)
		var fw := Vector3(0, 0, 1) - dn * dn.z          # (pose axes: right, up, forward)
		fw = fw.normalized() if fw.length() > 0.001 else Vector3(0, 0, 1)
		# towards the game's own knee when it is clearly bent and not backwards (a stride, a crouch turned aside)
		var gp := gk - dn * gk.dot(dn)
		if gp.length() > 0.25 * l1 and gp.normalized().dot(fw) > 0.0:
			fw = gp.normalized()
		q[leg[1]] = hip + dn * a + fw * sqrt(maxf(l1 * l1 - a * a, 0.0))
	return q


# Suits walking on their own steps. The game animates only the suits it draws up close: the far ones keep a frozen
# pose it slides along with them (their ankles, hips and pelvis rewritten every frame, always in the same place: the
# game shows them gliding too, unseen at its size), and the player's own (never drawn, seen from inside) only gets its
# feet moved from one footfall to the next. Those suits (the player's; one without a pose from the game for GAIT_STALE
# ms, the bridge leaving out the ones the game has not just drawn; and for GAIT_BACK ms after) walk on their own steps
# instead: the
# feet one after the other, each planted on the ground until the body has moved on, set down ahead of its hip and
# lifted as far behind it, at the cadence of a long stride (GAIT_STRIDE: faster, longer steps, both feet off the
# ground a moment between them, a run); when it stops, the foot left behind steps up to its place (the one ahead
# stays within GAIT_REST of the leg), and turning on the spot, the feet follow. The pelvis as standing, lowered as
# far as a long stride needs (at most GAIT_DROP of the leg); the knees from the hips and ankles (_leg_lengths); the
# upper body as standing, leaning a little at speed, the shoulders turning against the hips and the arms swinging
# against the legs. In the air (a jump) the legs hang under it. Suits the game draws keep its own pose (aiming,
# crouching, dying), cross-faded from and to their steps (_pose_suit).
const ARM_TOL := 0.15                          # an arm's bone against the other arm's (_arms_off)
const GAIT_STALE := 250                        # ms without a pose from the game
const GAIT_BACK := 400                         # ms of its poses again before they are drawn
const GAIT_STRIDE := 2.6                       # legs covered by a cycle, a step of each foot (the game's walk: 4.3,
const GAIT_CYCLE := Vector2(0.55, 1.3)         # its feet sliding); a cycle's duration (s), the quickest, the slowest
const GAIT_DUTY := 0.6                         # a foot planted at most this share of the cycle (walking: both down a
const GAIT_HALF := 0.45                        # while), at most this share of the leg ahead of its hip, as far behind
const GAIT_ADJUST := 0.35                      # a step back to its place, stopped (s)
const GAIT_REST := 0.45                        # stopped: a foot this far ahead of its place stays (share of the leg)
const GAIT_TURN := 0.6                         # a foot set down with the suit facing this far (radians) away steps
const GAIT_LIFT := 0.16                        # a foot's lift mid-step, share of the leg
const GAIT_DROP := 0.14                        # the pelvis lowered at most this share of the leg
const GAIT_AIR := 0.3                          # its feet this share of the leg above the ground: in the air
const GAIT_FEET := 0.034                       # a suit's feet below its entity (its height minus the game's
										# draw offset, 0.146: the same feet as when it was 0.06 below the entity - 0.12)
const GAIT_LEAN := 0.12                        # forward lean at full speed (radians)
const GAIT_NEAR := 12.0                        # its steps every frame nearer the camera (~28 us each), else GAIT_FAR_HZ
const GAIT_FAR_HZ := Vector2(60.0, 30.0)       # times a second, the second one beyond GAIT_FAR
const GAIT_FAR := 50.0
const WALK_ARMS := 0.45                        # arm swing for the leg's (opposite side)
const WALK_TWIST := 0.12                       # shoulders against the hips
const WALK_EASE := 8.0                         # the upper body's swing eased (rate a second)
const POSE_FADE := 250.0                       # ms: from the game's pose to its own steps and back


# A pose read while the game was writing it (a bridge that cannot wait for the gap between two pictures): an arm's
# bone is not the other arm's. (Every bone was held to the suit's own lengths, thighs and shins to 10 %: the game's
# legs have no fixed length, the knee is put half way with both bones stretched or squeezed to fit, 0.06 to 0.2 for
# 0.115 standing, so a suit crouching, kneeling to fire or striding out never passed, nor the Hog clones at all, and
# stood on its own steps as a statue while the game moved it. A pose the game has not just drawn is left out by the
# bridge, which sees the joints the game only writes when it draws.)
func _arms_off(p: Array) -> bool:
	for pair in [[[10, 12], [11, 13]], [[12, 14], [13, 15]]]:
		var a := (p[pair[0][0]] as Vector3).distance_to(p[pair[0][1]])
		var b := (p[pair[1][0]] as Vector3).distance_to(p[pair[1][1]])
		if absf(a - b) > ARM_TOL * maxf(a, b):
			return true
	return false


# a bone far longer than its limb's sprite (_pose_soldier does not draw such a pose; the game's own legs go up to
# 1.7 x their standing length in a long stride)
const BONE_LONG := 2.0


func _bones_long(node: Node3D, p: Array) -> bool:
	for part in node.get_meta("soldier"):
		if ((p[part[2]] as Vector3) - (p[part[1]] as Vector3)).length() > BONE_LONG * float(part[3]) / 256.0 * float(part[5]):
			return true
	return false


# A soldier's own bone lengths, read by the bridge in its game record (thigh, shin, upper arm, forearm, torso, reach):
# the knees are put back with the thigh and shin as they are (the game draws its suits with exactly these bones; its
# hip to ankle, 0.9 x their sum standing, bends the knees: with bones of 0.9 x a crouching suit's legs came out
# straight); its feet stay at their file length.
func _live_size(node: Node3D, sz: Array) -> void:
	node.set_meta("size", sz)
	if node.has_meta("corpse") or not node.has_meta("stand"):
		return
	var th: float = float(sz[0])                 # (the bones the game draws its suits with: standing, its hip to ankle is
	var sh: float = float(sz[1])                 # LEG_STAND x their sum, the knees a little bent)
	node.set_meta("leg_rest", [th, sh, th, sh])


func _gait_wanted(node: Node3D, now: int) -> bool:
	if not node.has_meta("leg_rest") or node.has_meta("corpse"):
		return false
	return node.has_meta("player_body") or \
			now - int(node.get_meta("jt", -100000)) > GAIT_STALE or now - int(node.get_meta("jt0", -100000)) < GAIT_BACK


# every frame (after the game's state): the suits walking on their own steps take theirs
func _gait_update(dt: float) -> void:
	if current.is_empty() or dt <= 0.0:
		return
	var m: Dictionary = current["map"]
	var now := Time.get_ticks_msec()
	for node in live_nodes + live_extra.values():
		if node == null or not is_instance_valid(node) or not node.visible or not node.has_meta("soldier"):
			continue
		if not _gait_wanted(node, now):
			if node.has_meta("gait"):
				node.remove_meta("gait")             # the game draws it again: its own pose (steps start afresh later)
			continue
		_gait_place(node, now)
		var acc: float = float(node.get_meta("gait_dt", 0.0)) + dt
		var far: float = node.global_position.distance_to(camera.global_position)
		if far > GAIT_NEAR and not node.has_meta("player_body") and \
				acc < 1.0 / (GAIT_FAR_HZ.x if far < GAIT_FAR else GAIT_FAR_HZ.y):
			node.set_meta("gait_dt", acc)            # (a pose each time: the far ones less often)
			continue
		node.set_meta("gait_dt", 0.0)
		_gait(node, m, minf(acc, 0.1))


# a suit on its own steps: its moves from the game (~30 a second, each one a jump: its planted legs jerked) kept for
# its speed, and the suit drawn one move late, eased from the one before (TN_SMOOTH does it for all, see _live_smooth)
func _gait_place(node: Node3D, now: int) -> void:
	var st: Dictionary = node.get_meta("gait", {})
	if not st.has("arms"):
		return
	var hist: Array = st["hist"]
	var p2: Vector2 = node.get_meta("pkt", Vector2(node.position.x, node.position.z))
	var ez: float = node.get_meta("ez", node.position.y)
	st["ez"] = float(node.get_meta("ez_s", ez)) if unit_smooth else ez   # (eased with its place, _unit_smooth)
	if hist.is_empty() or hist[-1][1] != p2 or hist[-1][2] != ez:
		if not hist.is_empty() and now - int(hist[-1][0]) > 120:   # moving again: from one game move before
			hist.assign([[now - 33, hist[-1][1], hist[-1][2]]])
		hist.append([now, p2, ez])
	while hist.size() > 2 and now - int(hist[1][0]) >= 150:
		hist.pop_front()
	if smooth or unit_smooth or hist.size() < 2:
		return
	var a: Vector2 = hist[-2][1]
	var b: Vector2 = hist[-1][1]
	var gap := int(hist[-1][0]) - int(hist[-2][0])
	if gap > 0 and gap < 120 and a.distance_to(b) < 1.0 and absf(float(hist[-1][2]) - float(hist[-2][2])) < 1.0:
		var k := clampf((now - int(hist[-1][0])) / float(gap), 0.0, 1.0)
		var d := a.lerp(b, k)
		node.position.x = d.x
		node.position.z = d.y
		st["ez"] = lerpf(hist[-2][2], hist[-1][2], k)


# a suit's pose from the game or from its own steps (_gait): from one to the other cross-faded over POSE_FADE (the
# upper body jumped from the game's aim to standing, the feet from its stride to theirs)
func _pose_suit(node: Node3D, q: Array, own: bool) -> void:
	var now := Time.get_ticks_msec()
	if bool(node.get_meta("own", own)) != own and node.has_meta("pose_last"):
		node.set_meta("fade_from", node.get_meta("pose_last"))
		node.set_meta("fade_t", now)
	node.set_meta("own", own)
	var game := q                                    # (the pose given, before the fade)
	var wf := 1.0
	if node.has_meta("fade_t"):
		var w := clampf((now - int(node.get_meta("fade_t"))) / POSE_FADE, 0.0, 1.0)
		wf = w * w * (3.0 - 2.0 * w)
		if w >= 1.0:
			node.remove_meta("fade_t")
			node.remove_meta("fade_from")
		else:
			w = w * w * (3.0 - 2.0 * w)
			var from: Array = node.get_meta("fade_from")
			var b := []
			for j in q.size():
				b.append((from[j] as Vector3).lerp(q[j], w))
			q = b
	node.set_meta("pose_last", q)
	if own or not node.has_meta("leg_rest") or node.has_meta("corpse"):
		_pose_soldier(node, q)
		return
	# the game's pose: its knees where the game has them, the thigh and shin stretched or squeezed between the hip and
	# the ankle as it draws them (put back at the suit's standing lengths, _leg_lengths, a crouching suit's knees
	# stuck out); from its own steps, from those knees to the game's over the fade
	var g := q.duplicate()
	if wf < 1.0:
		var solved := _leg_lengths(q, node.get_meta("leg_rest"))
		for k in [4, 5]:
			g[k] = (solved[k] as Vector3).lerp(game[k], wf)
	_pose_soldier(node, g, true)


# where the suit's joints are drawn now (world), from its limbs
func _joints_now(node: Node3D) -> Dictionary:
	var j := {}
	for part in node.get_meta("soldier"):
		var seg: MeshInstance3D = part[0]
		j[part[1]] = node.global_transform * seg.transform.origin
		j[part[2]] = node.global_transform * (seg.transform.origin + seg.transform.basis.y * float(part[3]))
	return j


func _gait(node: Node3D, m: Dictionary, dt: float) -> void:
	var stand: Array = node.get_meta("stand")
	var rest: Array = node.get_meta("leg_rest")
	var leg: float = (rest[0] + rest[1] + rest[2] + rest[3]) * 0.5
	var ground := TNData.height_at(m, node.position.x, node.position.z)
	# on the ground under it; above where the game has its feet (its entity minus GAIT_FEET) once they are clearly
	# off the ground (a jump: rising with it, no jump at the start)
	var ez: float = (node.get_meta("gait", {}) as Dictionary).get("ez", node.get_meta("ez", ground))
	var gy := ground + maxf(ez - GAIT_FEET - ground - 0.04, 0.0)
	var now := Time.get_ticks_msec()
	if not node.has_meta("gait") and absf(node.position.y - gy) < 1.0:
		node.set_meta("y_off", [node.position.y - gy, now])   # (from the game's pose: its height eased, _y_ease)
	node.set_meta("gait_y", gy)
	node.position.y = gy + _y_ease(node, now)
	var air := gy - ground > leg * GAIT_AIR
	var xf := node.global_transform
	var home := []                                       # where each ankle stands (under its hip: a stride even
	for s in 2:                                          # both ways)
		home.append(xf * _node_axes(Vector3(stand[2 + s].x, stand[2 + s].y, stand[6 + s].z)))
	var st: Dictionary = node.get_meta("gait", {})
	if not st.has("arms") or (st["feet"][0] as Vector3).distance_to(home[0]) > leg * 3.0:
		var f: Array = [home[0], home[1]]
		if not st.has("arms"):                          # from where it is drawn now (a jump away: where it stands)
			var now_j := _joints_now(node)
			for s in 2:
				if now_j.has(2 + s) and (now_j[2 + s] as Vector3).distance_to(home[s]) < leg:
					f[s] = now_j[2 + s]
		st = {"feet": f, "from": f.duplicate(), "k": [-1.0, -1.0], "phase": 0.25, "moving": false, "vel": Vector3.ZERO,
				"hist": [], "dir": Vector3.ZERO, "yaw": [node.rotation.y, node.rotation.y], "arms": [0.0, 0.0]}
		node.set_meta("gait", st)
	# its speed over the last 150 ms of its moves (_gait_place; none for 80 ms: stopped), eased
	var hist: Array = st["hist"]
	var v2 := Vector2.ZERO
	if hist.size() >= 2 and now - int(hist[-1][0]) < 80:
		v2 = ((hist[-1][1] as Vector2) - (hist[0][1] as Vector2)) / maxf((int(hist[-1][0]) - int(hist[0][0])) / 1000.0, 0.001)
	if v2.length() > 20.0:
		v2 = Vector2.ZERO
	st["vel"] = (st["vel"] as Vector3).lerp(Vector3(v2.x, 0.0, v2.y), 1.0 - exp(-dt * 8.0))
	var vel: Vector3 = st["vel"]
	var speed := vel.length()
	var vdir := vel / speed if speed > 0.001 else Vector3.ZERO
	var moving: bool = speed > leg * (0.08 if bool(st["moving"]) else 0.12)
	if moving:
		st["dir"] = vdir
	# its cadence: a cycle (a step of each foot) covers GAIT_STRIDE legs; each foot planted GAIT_DUTY of it, or as
	# long as its reach allows (GAIT_HALF of the leg ahead of its hip, as far behind), swinging the rest
	var cyc := clampf(GAIT_STRIDE * leg / maxf(speed, 0.001), GAIT_CYCLE.x, GAIT_CYCLE.y)
	var stance := minf(GAIT_DUTY * cyc, 2.0 * GAIT_HALF * leg / maxf(speed, 0.001))
	var swing_t := cyc - stance if moving else GAIT_ADJUST
	var half := speed * stance * 0.5                     # set down this far ahead of its hip, lifted as far behind
	var feet: Array = st["feet"]
	var from: Array = st["from"]
	var yaws: Array = st["yaw"]
	var k: Array = st["k"]                               # each foot's swing (0 to 1), -1 planted
	var ph: float = st["phase"]                          # the cycle: the left foot sets off at 0, the right at 0.5
	if air:
		var was_at: Vector3 = st.get("at", xf.origin)
		for s in 2:                                      # its legs hanging under it, a little bent (eased: with it)
			var o: Vector3 = (feet[s] as Vector3) - was_at
			o = o.lerp((home[s] as Vector3) + Vector3(0.0, leg * 0.12, 0.0) - xf.origin, 1.0 - exp(-dt * 20.0))
			feet[s] = xf.origin + o
			k[s] = -1.0
	else:
		var need := [false, false]
		var behind := [0.0, 0.0]
		for s in 2:
			var d: Vector3 = (feet[s] as Vector3) - (home[s] as Vector3)
			d.y = 0.0
			behind[s] = -d.dot(vdir if moving else st["dir"])
			need[s] = d.length() > leg * GAIT_REST or behind[s] > leg * 0.15 or \
					absf(angle_difference(float(yaws[s]), node.rotation.y)) > GAIT_TURN
		var first := 0 if behind[0] >= behind[1] else 1
		var start := [false, false]
		var down := float(k[0]) < 0.0 and float(k[1]) < 0.0
		if moving and not bool(st["moving"]) and down:   # setting off: the foot behind first
			ph = 0.5 * first
			start[first] = true
		elif moving:
			var nph := ph + dt / cyc
			start[0] = nph >= 1.0
			start[1] = ph < 0.5 and nph >= 0.5
			ph = fmod(nph, 1.0)
		elif down and (need[0] or need[1]):              # stopped: a foot left behind (or too far ahead, or turned
			start[first if need[0] and need[1] else (0 if need[0] else 1)] = true   # from) steps back, one at a time
		for s in 2:
			if start[s] and float(k[s]) < 0.0:
				k[s] = 0.0
				from[s] = feet[s]
		for s in 2:
			var f: Vector3 = feet[s]
			if float(k[s]) < 0.0:                        # planted: where it was set down, on the ground (landing
				var fy := TNData.height_at(m, f.x, f.z) + (stand[2 + s] as Vector3).y   # from a jump: down to it)
				f.y = fy if f.y < fy + 0.002 else minf(lerpf(f.y, fy, 1.0 - exp(-dt * 30.0)), (home[s] as Vector3).y + leg * 0.12)
				feet[s] = f
				continue
			var kk := minf(float(k[s]) + dt / swing_t, 1.0)
			var to: Vector3 = (home[s] as Vector3) + vel * ((1.0 - kk) * swing_t) + vdir * half
			var fr: Vector3 = from[s]
			f = fr.lerp(to, kk * kk * (3.0 - 2.0 * kk))
			var hop := Vector2(to.x - fr.x, to.z - fr.z).length()
			f.y = TNData.height_at(m, f.x, f.z) + (stand[2 + s] as Vector3).y + \
					sin(PI * kk) * leg * GAIT_LIFT * clampf(hop / (leg * 0.6), 0.3, 1.0)
			feet[s] = f
			k[s] = kk
			if kk >= 1.0:
				k[s] = -1.0                              # set down
				yaws[s] = node.rotation.y
	st["phase"] = ph
	st["moving"] = moving
	st["at"] = xf.origin
	# the pose (right, up, forward from the ground under the suit): the feet where they are, toes with them
	var inv := xf.affine_inverse()
	var q: Array = stand.duplicate()
	for s in 2:
		var lf: Vector3 = inv * (feet[s] as Vector3)
		var a := Vector3(lf.z, lf.y / SUIT_SQUASH, lf.x)
		q[2 + s] = a
		q[s] = (stand[s] as Vector3) + (a - (stand[2 + s] as Vector3))
	# the pelvis (with the hips and the upper body) as standing, lowered as far as a long stride needs; a foot still
	# out of reach (a stride too long for its legs) drawn at the end of its leg
	var dy := 0.0
	for s in 2:
		var full: float = (rest[2 * s] + rest[2 * s + 1]) * LEG_REACH
		var hip: Vector3 = stand[6 + s]
		var a: Vector3 = q[2 + s]
		var flat := Vector2(a.x - hip.x, a.z - hip.z).length()
		dy = minf(dy, a.y + sqrt(maxf(full * full - flat * flat, 0.0)) - hip.y)
	dy = maxf(dy, -leg * GAIT_DROP)
	dy = lerpf(float(st.get("dy", dy)), dy, 1.0 - exp(-dt * 30.0))   # (eased: the pelvis jumped as a long stride
	st["dy"] = dy                                        # ended)
	for j in range(6, 16):
		q[j] = (stand[j] as Vector3) + Vector3(0.0, dy, 0.0)
	for s in 2:
		var full: float = (rest[2 * s] + rest[2 * s + 1]) * LEG_REACH
		var d: Vector3 = (q[2 + s] as Vector3) - (q[6 + s] as Vector3)
		if d.length() > full:
			var a: Vector3 = (q[6 + s] as Vector3) + d.normalized() * full
			q[s] = (q[s] as Vector3) + (a - (q[2 + s] as Vector3))
			q[2 + s] = a
	# the upper body: leaning a little at speed, the shoulders against the hips, each arm against its leg
	var swing := [0.0, 0.0]
	for s in 2:
		var d: Vector3 = (q[2 + s] as Vector3) - (q[6 + s] as Vector3)
		swing[s] = atan2(d.z, maxf(-d.y, 0.001))
	var arms: Array = st["arms"]                         # (eased: the legs swing quickly, the arms less)
	for s in 2:
		arms[s] = lerpf(float(arms[s]), swing[s], 1.0 - exp(-dt * WALK_EASE))
	var fwd := (inv.basis * vel).x                       # (node axes: forward = +X)
	var pel: Vector3 = q[8]
	var upper := Basis(Vector3.UP, WALK_TWIST * (float(arms[1]) - float(arms[0]))) * \
			Basis(Vector3.RIGHT, GAIT_LEAN * clampf(fwd / (leg * 6.0), -0.5, 1.0))
	for j in range(9, 16):
		q[j] = pel + upper * ((q[j] as Vector3) - pel)
	var right: Vector3 = upper * Vector3.RIGHT
	for s in 2:                                          # (the left arm 10, 12, 14 with the left leg, backwards)
		var sh: Vector3 = q[10 + s]
		var r := Basis(right, WALK_ARMS * float(arms[s]))
		for j in [12 + s, 14 + s]:
			q[j] = sh + r * ((q[j] as Vector3) - sh)
	_pose_suit(node, q, true)


# (right, up, forward) -> node axes (forward = +X, up = +Y, right = +Z)
func _node_axes(v: Vector3) -> Vector3:
	return Vector3(v.z, v.y, v.x)


var captured_poses = null


# A suit's standing bone length for a part, x its pixels / 256: the game's size rule (SIZE_OFFSET) for a soldier of the
# mean size (the game draws each one's at random: not reproducible), the legs as they stand (LEG_STAND).
static func _part_scale(suit: int, part: int) -> float:
	var v := SIZE_CLONE if suit in [6, 7, 8] else SIZE_MEAN
	var d: float = v + SIZE_OFFSET.get(suit, 0) - 8.0
	match part:
		0:
			return 1.0
		1, 2:
			return LEG_STAND * (1.0 + d / 64.0)
		_:
			return 1.0 + d / 128.0


# The pose captured in the game for this suit when there is one (data/soldier_poses.json, written
# by _MODS/re/poses.py), else the template pose rebuilt with this suit's bone lengths.
func _soldier_pose(suit: int, segs: Array, limbs: Dictionary) -> Array[Vector3]:
	if captured_poses == null:
		captured_poses = {}
		if FileAccess.file_exists(POSES_FILE):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(POSES_FILE))
			if parsed is Dictionary:
				captured_poses = parsed
	var p: Array[Vector3] = []
	p.resize(16)
	if captured_poses.has(str(suit)):
		var raw: Array = captured_poses[str(suit)]
		for k in mini(16, raw.size()):
			p[k] = Vector3(raw[k][0], raw[k][1], raw[k][2])
		return p
	var t: Array[Vector3] = []
	for v in TEMPLATE_POSE:
		t.append(v)
	var length := func(k: int) -> float:              # segment k's bone (limbs by segment)
		return limbs[k]["len"] / 256.0 * _part_scale(suit, segs[k][2]) if limbs.has(k) else 0.08
	var torso := -1
	for k in segs.size():
		if segs[k][2] == 5:
			torso = k
	# free joints (pelvis, hips, shoulders) keep their place relative to the pelvis / neck,
	# scaled with the torso; every limb keeps its direction and takes this suit's length
	var k_torso: float = length.call(torso) / t[8].distance_to(t[9])
	p[8] = t[8]
	p[9] = p[8] + (t[9] - t[8]).normalized() * length.call(torso)
	for i in 2:
		p[6 + i] = p[8] + (t[6 + i] - t[8]) * k_torso
		p[10 + i] = p[9] + (t[10 + i] - t[9]) * k_torso
	for chain in [[6, 4, 2, 0], [7, 5, 3, 1], [10, 12, 14], [11, 13, 15]]:
		for c in range(1, chain.size()):
			var a: int = chain[c - 1]
			var b: int = chain[c]
			var seg_k := -1
			for k in segs.size():
				if (segs[k][0] == a and segs[k][1] == b) or (segs[k][0] == b and segs[k][1] == a):
					seg_k = k
			p[b] = p[a] + (t[b] - t[a]).normalized() * length.call(seg_k)
	var ground := minf(minf(p[0].y, p[1].y), minf(p[2].y, p[3].y))
	for k in 16:
		p[k].y -= ground
	return p


# Biped mech (skeleton 886): legs and body are small 3D models (RESTNOBJ 877-883, "pbmb00-06"),
# each hanging from its first joint with its y axis along the segment. Joints: 0/1 toes, 2/3 ankles, 4/5 knees,
# 6/7 hips, 8 body bottom, 9 body top.
# Standing pose as the game builds it (0x281918, 0x281CBC) from the parts' heights h (header max y - min y), in 16.16:
# shin = h(878) x 0.8, thigh = h(879) x 0.8, body = h(880) x 0.8, hips h(881) x 0.983 apart, ankle h(877) x 0.327 high,
# toes 0x2E00 ahead of the ankle, hips (thigh + shin + ankle) x 0.8 high. The game keeps no knee at rest: put back by
# the two bones, bent backwards as all its walking frames show them (bird legs).
func _add_mech(holder: Node3D) -> float:
	var segs: Array = objects.skeleton(TNObjects.MECH_SUIT)
	var p: Array[Vector3] = []                     # (right, up, forward)
	p.resize(16)
	var h := func(part: int, fallback: int) -> int:
		var e: int = objects.mech_yext(part)
		return e if e > 0 else fallback
	var shin_i: int = (h.call(1, 0x7D2A) * 0xCCCC) >> 16
	var thigh_i: int = (h.call(2, 0x601A) * 0xCCCC) >> 16
	var body_i: int = (h.call(3, 0x68A4) * 0xCCCC) >> 16
	var hipw_i: int = (h.call(4, 0x6723) * 0xFB9F) >> 16
	var ankle_i: int = (h.call(0, 0x6723) * 0x539C) >> 16
	var hip_i: int = ((thigh_i + shin_i + ankle_i) * 0xCCCC) >> 16
	var ankle := ankle_i / 65536.0
	var hip_y := hip_i / 65536.0
	var half := hipw_i / 131072.0
	var toe := 0x2E00 / 65536.0
	# the knee: half way from the hip to the ankle, as the game puts it on every mech it draws (read on MISS30's two
	# walking mechs, every frame: within 0.003), so a standing leg is straight
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		p[i] = Vector3(side * half, 0.0, toe)
		p[2 + i] = Vector3(side * half, ankle, 0.0)
		p[4 + i] = Vector3(side * half, (hip_y + ankle) / 2.0, 0.0)
		p[6 + i] = Vector3(side * half, hip_y, 0.0)
	p[8] = Vector3(0.0, hip_y, 0.0)
	p[9] = Vector3(0.0, hip_y + body_i / 65536.0, 0.0)
	var parts := []
	for sg in segs:
		var md: Dictionary = objects.model(Vector2i(877 + sg[2], 0), pal, pal_key)
		if md.is_empty():
			return 0.0
		var part := MeshInstance3D.new()
		part.mesh = md["mesh"]
		holder.add_child(part)
		parts.append([part, sg[0], sg[1]])
	holder.set_meta("mech", parts)
	return _pose_mech(holder, p) + 0.1


# Puts a mech's parts (3D models, not stretched) on its joints: this standing pose at load, the game's own
# joints every frame in live mode (it walks like the suits). Returns the highest joint.
func _pose_mech(holder: Node3D, p: Array) -> float:
	var top := 0.0
	var f_hips := _facing(p[6], p[7])
	for part in holder.get_meta("mech"):
		var a: Vector3 = p[part[1]]
		var b: Vector3 = p[part[2]]
		var ga := Vector3(a.z, a.y, a.x)
		var gb := Vector3(b.z, b.y, b.x)
		var d := gb - ga
		var down := d.normalized() if d.length() > 0.0001 else Vector3.DOWN   # model y (mesh -Y) runs from a to b
		var yn := -down
		var fw := f_hips
		if absf(fw.dot(yn)) > 0.95:
			fw = Vector3(0, 1, 0)
		var xn := (fw - yn * fw.dot(yn)).normalized()
		var node: MeshInstance3D = part[0]
		# every part as the game places it (0x2F737C), the feet too: y along its segment (a foot: ankle to toe, down
		# the slope to the ground), x the mech's facing square to it (the game's reference vectors at suit +0x26F,
		# all "backwards" in the mech's frame, x = minus that)
		node.transform = Transform3D(Basis(xn, yn, xn.cross(yn)), ga)
		top = maxf(top, maxf(ga.y, gb.y))
	return top


func _limb_quad(ld: Dictionary) -> ArrayMesh:
	if ld.has("mesh"):
		return ld["mesh"]
	var w: float = ld["size"].x
	var h: float = ld["size"].y
	var a1: float = ld["a1"]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var corners := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]
	for c in corners:
		st.set_uv(c)
		st.add_vertex(Vector3((c.x - 0.5) * w, c.y * h - a1, 0.0))
	var mesh := st.commit()
	ld["mesh"] = mesh
	return mesh


func _limb_mat(suit: int, part: int, ld: Dictionary, shade := -1.0) -> ShaderMaterial:
	var k := "limb%d/%d/%s/%.2f" % [suit, part, pal_key, shade]
	if mats.has(k):
		return mats[k]
	var sm := ShaderMaterial.new()
	sm.shader = LIMB
	sm.set_shader_parameter("views", ld["tex"])
	sm.set_shader_parameter("view_count", ld["views"])
	sm.set_shader_parameter("shade", shade if shade >= 0.0 else 1.0)
	if shade < 0.0:                                 # a standing suit: lit like the game's (_limb_light)
		sm.set_meta("lit", true)
		_limb_light_set(sm)
	mats[k] = sm
	return sm


# The game's light on the standing suits (limb.gdshader lit), for the map: its light direction without the sky's
# azimuth offset (the game's own model light vector, 0x36244F), ambient (amb + 1) / 2 and diffuse from resource 82,
# and the planet's shade rows (resource 53) as colour gains, weighted by how often each colour shows on the limbs
# (linear light: the textures are). The infrared view: unlit (the game swaps its palette remap, no light per limb).
var limb_light := {}


func _limb_light(m: Dictionary) -> void:
	var light: Vector2 = m.get("light", Vector2(0.0, TAU / 8.0))
	var dir := Vector3(cos(light.y) * cos(light.x), sin(light.y), cos(light.y) * sin(light.x))
	var rows := PackedVector3Array()
	rows.resize(16)
	rows.fill(Vector3.ONE)
	var sr: PackedByteArray = (m.get("planet_data", {}) as Dictionary).get("shade_rows", PackedByteArray())
	if sr.size() >= 16 * 256 and objects_ok:
		var hist := objects.limb_histogram()
		var lin := PackedVector3Array()
		lin.resize(256)
		for i in 256:
			var c := (pal[i] as Color).srgb_to_linear()
			lin[i] = Vector3(c.r, c.g, c.b)
		var base := Vector3.ZERO
		for i in 256:
			base += lin[i] * hist[i]
		for r in 15:
			var fo := 256 * (15 - r)                 # the game's row r = file row 15 - r
			var acc := Vector3.ZERO
			for i in 256:
				acc += lin[sr[fo + i]] * hist[i]
			rows[r] = Vector3(acc.x / maxf(base.x, 1e-6), acc.y / maxf(base.y, 1e-6), acc.z / maxf(base.z, 1e-6))
	limb_light = {"dir": dir, "amb": (float(m.get("light_amb", 0.3)) + 1.0) * 0.5, "dif": float(m.get("light_dif", 0.7)),
			"rows": rows}
	for k in mats:
		if mats[k] is ShaderMaterial and (mats[k] as ShaderMaterial).has_meta("lit"):
			_limb_light_set(mats[k])


func _limb_light_set(sm: ShaderMaterial) -> void:
	if limb_light.is_empty():
		return
	sm.set_shader_parameter("lit", not ir_on)
	sm.set_shader_parameter("light_dir", limb_light["dir"])
	sm.set_shader_parameter("light_amb", limb_light["amb"])
	sm.set_shader_parameter("light_dif", limb_light["dif"])
	sm.set_shader_parameter("light_rows", limb_light["rows"])


func _add_zone(m: Dictionary, z: Dictionary) -> void:
	# script zone (waypoint, trigger, drop / pickup point): thin post, name at eye level
	var ground := TNData.height_at(m, z["x"], z["y"])
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.07
	cyl.bottom_radius = 0.07
	cyl.height = 6.0
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mats["zone"]
	mi.position = Vector3(z["x"], ground + 3.0, z["y"])
	mi.add_to_group("zones")
	mi.visible = zones_on
	var l := Label3D.new()
	l.text = z["name"]
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = 40
	l.pixel_size = 0.018
	l.modulate = Color(1.0, 0.9, 0.3)
	l.outline_size = 12
	l.visibility_range_end = 300.0
	l.fixed_size = false
	l.position = Vector3(0, 3.6, 0)
	mi.add_child(l)
	world.add_child(mi)


func _drop_zone(mis: Dictionary) -> Vector2:
	for z in mis.get("zones", []):
		if z["name"].to_lower().contains("drop"):
			return Vector2(z["x"], z["y"])
	return Vector2(256, 256)


func _place_camera(m: Dictionary, mis: Dictionary) -> void:
	var target := _drop_zone(mis)
	var ground := TNData.height_at(m, target.x, target.y)
	yaw = 0.0
	pitch = -0.45
	camera.position = Vector3(target.x, ground + 28.0, target.y + 45.0)
	var args := OS.get_cmdline_user_args()
	var c := args.find("--cam")          # test: --cam x,y,height_above_ground,yaw_deg,pitch_deg
	if c >= 0 and c + 1 < args.size():
		var v := args[c + 1].split_floats(",")
		camera.position = Vector3(v[0], TNData.height_at(m, v[0], v[1]) + v[2], v[1])
		yaw = deg_to_rad(v[3])
		pitch = deg_to_rad(v[4])
	camera.rotation = Vector3(pitch, yaw, 0)


func _screenshot(path: String) -> void:
	for i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	print("screenshot ", path)
	get_tree().quit()


# ------------------------------------------------------------------ camera
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			look = event.pressed
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if look else Input.MOUSE_MODE_VISIBLE
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			speed = minf(speed * 1.25, 400.0)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			speed = maxf(speed / 1.25, 2.0)
	elif event is InputEventMouseMotion and look:
		yaw -= event.relative.x * 0.003
		pitch = clampf(pitch - event.relative.y * 0.003, -1.5, 1.5)
		camera.rotation = Vector3(pitch, yaw, 0)
	elif event is InputEventKey and _look_keys(event):
		pass
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_TAB:
				panel.visible = not panel.visible
			KEY_F2:
				labels_on = not labels_on
				get_tree().call_group("labels", "set_visible", labels_on)
			KEY_F3:
				zones_on = not zones_on
				get_tree().call_group("zones", "set_visible", zones_on)
			KEY_F4:
				veg_on = not veg_on
				get_tree().call_group("vegetation", "set_visible", veg_on)


# old school mode: the game's look over the 3D view, under its HUD (F12)
func _make_oldschool() -> void:
	var rl := CanvasLayer.new()
	rl.layer = -1
	add_child(rl)
	oldschool_rect = ColorRect.new()
	oldschool_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	oldschool_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rm := ShaderMaterial.new()
	rm.shader = OLDSCHOOL
	oldschool_rect.material = rm
	oldschool_rect.visible = false                      # shown once the planet's palette is known
	rl.add_child(oldschool_rect)
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	var k := int(cfg.get_value("look", "old_sharp", 1))
	old_sharp = k if k in OLD_SHARP else 1
	_oldschool_grid()
	get_viewport().size_changed.connect(_oldschool_grid)   # (its grid is counted in the window's pixels)


# the planet's palette for it (each new map); live: on from the start (--smooth: off), the map viewer: off (F12;
# TN_OLDSCHOOL=1: on)
func _oldschool_palette() -> void:
	if oldschool_rect != null and pal_key != oldschool_key and pal.size() >= 256:
		var pimg := Image.create(256, 1, false, Image.FORMAT_RGB8)
		for i in 256:
			pimg.set_pixel(i, 0, pal[i])
		(oldschool_rect.material as ShaderMaterial).set_shader_parameter("pal_tex", ImageTexture.create_from_image(pimg))
		(oldschool_rect.material as ShaderMaterial).set_shader_parameter("first_index", pal_first)
		if oldschool_key == "":
			oldschool_rect.visible = (live and not ("--smooth" in OS.get_cmdline_user_args()) and OS.get_environment("TN_OLDSCHOOL") != "0") \
					or (not live and OS.get_environment("TN_OLDSCHOOL") == "1")     # (the map viewer: on when asked)
			_apply_look()
		oldschool_key = pal_key


func _oldschool_toggle() -> void:
	if oldschool_rect != null and oldschool_key != "":
		oldschool_rect.visible = not oldschool_rect.visible
		_apply_look()


# How fine the old school's pixel grid is (Shift+F12, kept in viewer.cfg): the game's own pixels (848 x 400 over the
# window, its HD screen), 2 or 3 times as many each way, or the window's own (0): the palette alone is then left of
# the look. Never finer than the window. The HUD's side views follow (_sub_views).
const OLD_GRID := Vector2(848, 400)
const OLD_SHARP := [1, 2, 3, 0]
var old_sharp := 1


func _old_grid(k: int) -> Vector2:
	var vs := get_viewport().get_visible_rect().size
	return vs if k <= 0 else (OLD_GRID * k).min(vs)


func _oldschool_grid() -> void:
	if oldschool_rect != null:
		(oldschool_rect.material as ShaderMaterial).set_shader_parameter("grid", _old_grid(old_sharp))


# the next one that changes something in this window (1280 x 720: twice the game's pixels is already the window's)
func _oldschool_sharper() -> void:
	if oldschool_rect == null or not oldschool_rect.visible:
		return
	var was := _old_grid(old_sharp)
	var i := OLD_SHARP.find(old_sharp)
	for n in OLD_SHARP.size():
		i = (i + 1) % OLD_SHARP.size()
		if _old_grid(OLD_SHARP[i]) != was:
			break
	old_sharp = OLD_SHARP[i]
	_oldschool_grid()
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	cfg.set_value("look", "old_sharp", old_sharp)
	cfg.save(CFG)
	var g := _old_grid(old_sharp)
	_note("Old school: %s (%d x %d)" % ["the game's pixels" if old_sharp == 1 else ("the window's pixels" if
			g == get_viewport().get_visible_rect().size else "%d x finer" % old_sharp), g.x, g.y])


# A line at the top of the window for a moment (a setting just changed).
var note_label: Label
var note_n := 0


func _note(text: String) -> void:
	if note_label == null:
		var nl := CanvasLayer.new()
		nl.layer = 20                                   # over the game's HUD
		add_child(nl)
		note_label = Label.new()
		note_label.set_anchors_preset(Control.PRESET_TOP_WIDE)
		note_label.offset_top = 8
		note_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		note_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		note_label.add_theme_font_size_override("font_size", 20)
		note_label.add_theme_color_override("font_color", Color(1, 1, 0.4))
		note_label.add_theme_color_override("font_outline_color", Color.BLACK)
		note_label.add_theme_constant_override("outline_size", 5)
		nl.add_child(note_label)
	note_label.text = text
	note_label.visible = true
	note_n += 1
	var mine := note_n
	await get_tree().create_timer(2.5).timeout
	if mine == note_n:
		note_label.visible = false


# The mission's sky (see TNObjects.load_sky): shader sky with the cloud texture and the haze color
# (also the fog color), sprites placed by azimuth / elevation, the moon and the sunlight in the
# map's light direction (map resource 82).
func _set_sky(path: String, light: Vector2) -> void:
	for c in sky_root.get_children():
		c.queue_free()
	sky_items.clear()
	var sk: Dictionary = objects.load_sky(path, pal) if objects_ok and path != "" else {}
	# the map's light direction (azimuth, elevation; game y axis = Godot z), azimuth 0 along +x: the light levels the
	# maps store are baked from it so (MAP10 99.6 % of points, MAP23 99.85 %), and the game lights its models with
	# (sin az cos el, -sin el, cos az cos el) in its 3D library's axes (0x29E5FC), which place world x on their z
	var to_light := Vector3(cos(light.y) * cos(light.x), sin(light.y), cos(light.y) * sin(light.x))
	sun.look_at_from_position(Vector3.ZERO, -to_light, Vector3.UP if absf(to_light.y) < 0.99 else Vector3.FORWARD)
	sun_to = to_light
	if sk.is_empty():
		var sm := ProceduralSkyMaterial.new()
		sm.sky_top_color = Color(0.32, 0.5, 0.78)
		sm.sky_horizon_color = Color(0.72, 0.78, 0.86)
		sm.ground_horizon_color = Color(0.72, 0.78, 0.86)
		env.sky.sky_material = sm
		env.fog_light_color = Color(0.7, 0.76, 0.84)
		_haze_globals()
		return
	var mat := ShaderMaterial.new()
	mat.shader = SKY_SHADER
	mat.set_shader_parameter("has_clouds", sk["clouds"] != null)
	mat.set_shader_parameter("has_stars", sk.get("stars") != null)
	if sk.get("stars") != null:
		mat.set_shader_parameter("stars", sk["stars"])
	if sk["clouds"] != null:
		mat.set_shader_parameter("clouds", sk["clouds"])
		mat.set_shader_parameter("clouds_soft", sk["clouds"])
		mat.set_shader_parameter("levels", sk["cloud_levels"])
		mat.set_shader_parameter("levels_soft", sk["cloud_levels"])
		var band: Array = sk["band_rain"] if int(mis_params.get("weather_kind", 0)) == 2 else sk["band"]
		var bi := Image.create(5, 1, false, Image.FORMAT_RGB8)   # sampled as the cloud texels are (the same colours)
		for i in 4:
			bi.set_pixel(i, 0, band[i])
		# 5th: under the horizon, where no ground is drawn (beyond the outer map, 256 units past the map's edge),
		# the map's mean ground colour at the modern look's full haze (tn_haze: 0.70 of the haze colour, sRGB)
		bi.set_pixel(4, 0, far_ground.lerp(sk["haze"], 0.7))
		mat.set_shader_parameter("bands", ImageTexture.create_from_image(bi))
	var haze: Color = sk["haze"]
	mat.set_shader_parameter("haze", Vector3(haze.r, haze.g, haze.b))
	env.sky.sky_material = mat
	env.fog_light_color = haze
	_haze_globals()
	mat.set_shader_parameter("gain", LIVE_SKY if live else 1.0)
	mat.set_shader_parameter("desat", 1.0 / LIVE_SATURATION if live else 1.0)
	if sk.get("light") != null:                         # the clouds lighten towards the horizon
		var lt: Color = sk["light"]
		if int(mis_params.get("weather_kind", 0)) == 2 and pal.size() > 0x20:
			lt = pal[0x20]                              # rain (0x2A7085): its far band in greys 0x20.. (not 0xA2..)
		mat.set_shader_parameter("light", Vector3(lt.r, lt.g, lt.b))
		sky_light = lt
	else:
		sky_light = haze                                # (no clouds: the horizon's haze, not the last sky's clouds:
		# the water mirrored a white horizon under a black night sky)
	sky_clouds = sk["clouds"]
	sky_haze = haze
	mat.set_shader_parameter("has_ir", false)
	if live and cur_ir.has(60) and sk.get("cloud_idx") != null:   # infrared: the cloud layer through table 60 (0x2A7654)
		var c60: PackedColorArray = cur_ir[60]
		var cidx: PackedByteArray = sk["cloud_idx"]
		var t151: PackedByteArray = sk.get("cloud_haze", PackedByteArray())
		var ilayers: Array[Image] = []
		for k in 8:
			var rgb := PackedByteArray()
			rgb.resize(256 * 256 * 3)
			for p in 256 * 256:
				var c: Color = c60[t151[k * 256 + cidx[p]] if k > 0 and t151.size() >= 2048 else cidx[p]]
				rgb[3 * p] = c.r8
				rgb[3 * p + 1] = c.g8
				rgb[3 * p + 2] = c.b8
			var li := Image.create_from_data(256, 256, false, Image.FORMAT_RGB8, rgb)
			li.generate_mipmaps()
			ilayers.append(li)
		var iarr := Texture2DArray.new()
		iarr.create_from_images(ilayers)
		var bimg := Image.create(4, 1, false, Image.FORMAT_RGB8)
		for i in 4:
			bimg.set_pixel(i, 0, c60[0xA5 - i])
		mat.set_shader_parameter("levels_ir", iarr)
		mat.set_shader_parameter("bands_ir", ImageTexture.create_from_image(bimg))
		mat.set_shader_parameter("has_ir", true)
	sky_haze_lut = null
	var t150: PackedByteArray = sk.get("haze_rows", PackedByteArray())
	if t150.size() >= 4096 and pal.size() >= 256:      # the colour of each palette index at each haze level
		var rgb := PackedByteArray()
		rgb.resize(4096 * 3)
		for i in 4096:
			var c: Color = pal[t150[i]]
			rgb[3 * i] = c.r8
			rgb[3 * i + 1] = c.g8
			rgb[3 * i + 2] = c.b8
		sky_haze_lut = ImageTexture.create_from_image(Image.create_from_data(256, 16, false, Image.FORMAT_RGB8, rgb))
		sky_haze_idx = ImageTexture.create_from_image(Image.create_from_data(256, 16, false, Image.FORMAT_R8,
				t150.slice(0, 4096)))
		# the haze rows give the far ground the base colours 1-16 (the temperate planet's greens go to its teal greys
		# 1 and 2 from level 12 on): the old school pass then needs them, or it turned that far ground a neutral grey
		var base_n := 0
		for i in range(256, 4096):
			if i % 256 >= 17 and t150[i] >= 1 and t150[i] < 17:
				base_n += 1
		if base_n > 40:
			pal_first = 1
			if oldschool_rect != null:
				(oldschool_rect.material as ShaderMaterial).set_shader_parameter("first_index", pal_first)
	for sm in ground_mats + [mats["water"]]:
		_sky_to(sm)
	_apply_look()
	var sprites: Array = sk["items"].duplicate()
	if sk["clouds"] != null:
		sprites.clear()                                 # under a cloud ceiling the game shows none of them: no sun,
		# moon or little clouds on a full turn of the running game (they are beyond its opaque ceiling); only the
		# skies without clouds (space) show them
	elif sk.get("moon") != null:
		var moon: Dictionary = sk["moon"].duplicate()
		moon["moon"] = true
		moon["az"] = light.x
		moon["el"] = light.y
		sprites.append(moon)
	for it in sprites:
		var az: float = it["az"]
		var el: float = it["el"]
		var dir := Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az))
		var q := QuadMesh.new()
		q.size = it["size"] * SKY_PIXEL * SKY_DISTANCE
		var m3 := StandardMaterial3D.new()
		m3.albedo_texture = it["tex"]
		m3.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m3.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m3.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		m3.disable_fog = true
		m3.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.material_override = m3
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = dir * SKY_DISTANCE
		sky_root.add_child(mi)
		if not it.get("moon", false):
			sky_items.append([mi, az, el, q.size.y / SKY_DISTANCE * 0.5])
	sky_items_y = INF
	_sky_items_place()


var far_ground := Color(0.5, 0.5, 0.5)      # the ground at the outer map's edge (sRGB), _mean_ground


# The mean colour of the ground at the outer map's edge (what the far ground under the horizon continues): its tiles'
# mean colours along the outer grid's border (8 points deep), or over the detail grid without one.
func _mean_ground(m: Dictionary, pl: Dictionary) -> Color:
	var cols = pl.get("tile_color", [])
	var g: Dictionary = m.get("outer", {})
	var rim := 8
	if not g.has("tilemap"):
		g = m.get("detail", {})
		rim = 1 << 20
	if cols.is_empty() or not g.has("tilemap"):
		return Color(0.5, 0.5, 0.5)
	var img: Image = g["tilemap"]
	var w := img.get_width()
	var h := img.get_height()
	var acc := Vector3.ZERO
	var n := 0
	for y in range(0, h, 2):
		for x in range(0, w, 2):
			if mini(mini(x, w - 1 - x), mini(y, h - 1 - y)) >= rim:
				continue
			var ti := int(round(img.get_pixel(x, y).r * 255.0))
			if ti < cols.size():
				var c: Color = cols[ti]
				acc += Vector3(c.r, c.g, c.b)
				n += 1
	acc /= maxf(1.0, float(n))
	return Color(acc.x, acc.y, acc.z)


# The sky's own pictures (resource 153's list, not the moon) are drawn lower the higher the eye (0x2A816C: (eye's
# height + 64) / 384 in tangent units, the eye's height 0x41EB70): at the eye's usual height, half hidden by the
# horizon. The game moves them with the eye (as if they stood 384 units away: the Earth went down when the player
# jumped, up when he fell); here they sit at infinity, at the game's angle for the eye at the drop zone (sky_ref_y)
var sky_items := []          # [node, azimuth, elevation, half its height (tangent)]
var sky_items_y := INF
var sky_ref_y := 0.0         # the eye's height the sky's pictures are placed for (_load)
const SKY_EYE := 0.4         # the eye above the ground (entity z + 0x38FB1C + 0x3000, 0x2752C4: 0.39 measured)


func _sky_items_place() -> void:
	if sky_items_y == sky_ref_y:
		return
	sky_items_y = sky_ref_y
	var drop := (sky_ref_y + 64.0) / 384.0
	var keep := []
	for it in sky_items:
		if not is_instance_valid(it[0]):
			continue
		keep.append(it)
		var az: float = it[1]
		# the game's point is the picture's foot (MISS1's moon: rows 56-77 of 196 drawn, its foot at the computed
		# row 92, behind the hills; centred there it was hidden whole): the billboard's middle half its height above
		var el: float = atan(tan(it[2]) - drop + it[3])
		(it[0] as Node3D).position = Vector3(cos(el) * cos(az), sin(el), cos(el) * sin(az)) * SKY_DISTANCE
	sky_items = keep


func _hud_setup() -> void:
	hud = true
	hud_udp = PacketPeerUDP.new()
	var err := hud_udp.bind(HUD_PORT, "127.0.0.1", 1 << 22)   # ~256 KB of screen per frame
	if err != OK:
		push_warning("HUD port %d: error %d" % [HUD_PORT, err])
	hud_img = Image.create(320, 400, false, Image.FORMAT_RG8)
	hud_tex = ImageTexture.create_from_image(hud_img)
	hud_pal_img = Image.create(256, 1, false, Image.FORMAT_RGB8)
	hud_pal = ImageTexture.create_from_image(hud_pal_img)
	var sh := Shader.new()
	sh.code = """shader_type canvas_item;
uniform sampler2D pal : filter_nearest;
void fragment() {
	vec4 t = texture(TEXTURE, UV);
	COLOR = vec4(texture(pal, vec2((floor(t.r * 255.0 + 0.5) + 0.5) / 256.0, 0.5)).rgb, t.g);
}"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	mat.set_shader_parameter("pal", hud_pal)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud_rect = TextureRect.new()
	hud_rect.texture = hud_tex
	hud_rect.material = mat
	hud_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	hud_rect.stretch_mode = TextureRect.STRETCH_SCALE
	hud_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	hud_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	hud_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(hud_rect)
	var ml := CanvasLayer.new()                    # the game's screen out of its 3D: over the view and the HUD
	ml.layer = 10
	add_child(ml)
	menu_bg = ColorRect.new()
	menu_bg.color = Color.BLACK
	menu_bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	menu_bg.visible = false
	ml.add_child(menu_bg)
	menu_rect = TextureRect.new()
	menu_rect.stretch_mode = TextureRect.STRETCH_SCALE
	menu_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# the game's own pixels (640 x 480 in its menus) blown up crisp: each pixel flat, only its edges blended over one
	# window pixel ("sharp bilinear"), so that uneven scales do not give uneven pixels
	var msh := Shader.new()
	msh.code = """shader_type canvas_item;
uniform float fade = 1.0;
void fragment() {
	vec2 src = vec2(textureSize(TEXTURE, 0));
	vec2 t = UV * src;
	vec2 sc = 1.0 / max(fwidth(t), vec2(1e-4));
	vec2 c = fract(t) - 0.5;
	vec2 r = max(0.5 - 0.5 / sc, vec2(0.0));
	vec2 f = (c - clamp(c, -r, r)) * sc + 0.5;
	COLOR = texture(TEXTURE, (floor(t) + f) / src);
	COLOR.a *= fade;
}"""
	var mmat := ShaderMaterial.new()
	mmat.shader = msh
	menu_rect.material = mmat
	menu_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	menu_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE   # (placed by _menu_place)
	menu_rect.visible = false
	ml.add_child(menu_rect)
	var mbg := ColorRect.new()
	mbg.color = Color.BLACK
	mbg.set_anchors_preset(Control.PRESET_FULL_RECT)
	mbg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hd_movie_box = AspectRatioContainer.new()
	hd_movie_box.set_anchors_preset(Control.PRESET_FULL_RECT)
	hd_movie_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hd_movie_box.visible = false
	hd_movie = VideoStreamPlayer.new()
	hd_movie.expand = true
	hd_movie.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hd_movie_box.add_child(hd_movie)
	mbg.visible = false
	ml.add_child(mbg)
	ml.add_child(hd_movie_box)
	hd_movie_box.set_meta("bg", mbg)
	_compass_setup()


# The compass at the top is the game's own, in its screen: a new picture per game frame (~30 a second), while the view
# follows the heading 120 times a second, so it moved by jerks. Its strip (COMPASS in the 320 x 400 screen: 256 pixels
# = 360 degrees) is drawn again every frame over it, shifted by what the heading turned since. Where the letters are in
# each game picture: measured on it (their pixels against the first picture's, the best match near where the heading
# puts them); how the heading maps to that: learnt while playing (the direction when turning, the offset when still:
# the game's own compass until then). The game's yellow brackets stay in place.
const COMPASS := Rect2i(32, 5, 256, 17)
const COMPASS_ROWS := [9, 10, 11, 12, 13, 14, 15, 16, 17]   # all the letters' rows (N / S and E / W look alike in the
                                                           # middle ones: half a turn off now and then)
var compass_rect: TextureRect
var compass_mat: ShaderMaterial
var compass_ref := []                          # per row: x of the letters' pixels in the first picture
var compass_sig := ""                          # the game picture last measured
var compass_phase := 0.0                       # where its letters are (pixels from the first picture)
var compass_prev := []                         # [heading, phase] of the previous game picture
var compass_votes := 0                         # the direction: + when letters and heading move together
var compass_off := Vector2.ZERO                # the offset (an average on a circle)
var compass_yaw := 0.0                         # the heading when it last moved more than 0.5 degree, and when
var compass_yaw_t := 0
var compass_rows := []                         # the letters' pixels of the last game picture read, and which one
var compass_read := -1
var hud_version := 0                           # game pictures received (the compass reads only a new one)


func _compass_setup() -> void:
	var sh := Shader.new()
	sh.code = """shader_type canvas_item;
uniform sampler2D hud : filter_nearest;
uniform sampler2D pal : filter_nearest;
uniform float shift = 0.0;
uniform vec4 strip = vec4(32.0, 5.0, 256.0, 17.0);
vec3 col(vec2 px) {
	vec4 t = texture(hud, (floor(px) + 0.5) / vec2(320.0, 400.0));
	return texture(pal, vec2((floor(t.r * 255.0 + 0.5) + 0.5) / 256.0, 0.5)).rgb;
}
bool yellow(vec3 c) { return c.r > 0.55 && c.g > 0.45 && c.b < 0.35; }
void fragment() {
	vec2 p = strip.xy + UV * strip.zw;
	vec3 c0 = col(p);
	vec3 c1 = col(vec2(strip.x + mod(p.x - strip.x - shift, strip.z), p.y));
	COLOR = vec4(yellow(c0) ? c0 : (yellow(c1) ? vec3(0.0) : c1), 1.0);
}"""
	compass_mat = ShaderMaterial.new()
	compass_mat.shader = sh
	compass_mat.set_shader_parameter("hud", hud_tex)
	compass_mat.set_shader_parameter("pal", hud_pal)
	compass_mat.set_shader_parameter("strip", Vector4(COMPASS.position.x, COMPASS.position.y, COMPASS.size.x,
			COMPASS.size.y))
	var cl := CanvasLayer.new()
	cl.layer = 2                               # over the game's screen (1), under its menus (10)
	add_child(cl)
	compass_rect = TextureRect.new()
	compass_rect.texture = hud_tex
	compass_rect.material = compass_mat
	compass_rect.stretch_mode = TextureRect.STRETCH_SCALE
	compass_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	compass_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	compass_rect.anchor_left = COMPASS.position.x / 320.0
	compass_rect.anchor_right = COMPASS.end.x / 320.0
	compass_rect.anchor_top = COMPASS.position.y / 400.0
	compass_rect.anchor_bottom = COMPASS.end.y / 400.0
	compass_rect.visible = false
	cl.add_child(compass_rect)


func _compass_update() -> void:
	if compass_rect == null:
		return
	if menu_mode:
		compass_rect.visible = false
		return
	# the strip is the cockpit view's place for it. In the full view (G) the game's bars are there and its compass
	# lower, over the 3D: the strip redrew the bars, shifted as the view turned (#11). The game's own compass then
	if hud_win.size.y > 0 and hud_win.intersects(COMPASS):
		compass_rect.visible = false
		return
	var now := Time.get_ticks_msec()
	var yaw: float = cam_to[1]
	if absf(angle_difference(compass_yaw, yaw)) > deg_to_rad(0.5):
		compass_yaw = yaw
		compass_yaw_t = now
	var w := COMPASS.size.x
	if compass_read != hud_version:            # the letters' pixels (light, not the brackets' yellow): read once per
		compass_read = hud_version             # game picture (~30 a second), not every frame
		compass_rows = []
		for y in COMPASS_ROWS:
			var xs := []
			for x in w:
				var c := hud_pal_img.get_pixel(int(round(hud_img.get_pixel(COMPASS.position.x + x, y).r * 255.0)), 0)
				if c.get_luminance() > 0.55 and not (c.r > 0.55 and c.g > 0.45 and c.b < 0.35):
					xs.append(x)
			compass_rows.append(xs)
	var rows := compass_rows
	var n := 0
	for r in rows:
		n += (r as Array).size()
	if n < 6:                                  # no compass on the game's screen
		compass_rect.visible = false
		return
	var learnt := absi(compass_votes) >= 3 and compass_off.length() >= 0.5
	var sig := str(rows)
	if sig != compass_sig:                     # a new game picture: where its letters are
		compass_sig = sig
		if compass_ref.is_empty():
			compass_ref = rows
		var hist := PackedInt32Array()
		hist.resize(w)
		for k in rows.size():
			for p in rows[k]:
				for q in compass_ref[k]:
					hist[posmod(p - q, w)] += 1
		var best := 0
		for d in w:
			if hist[d] > hist[best]:
				best = d
		if learnt:                             # the best match near where the heading puts them
			var c := posmod(int(round(signf(compass_votes) * yaw * w / TAU + compass_off.angle() / TAU * w)), w)
			best = c
			for o in range(-48, 49):
				if hist[posmod(c + o, w)] > hist[best]:
					best = posmod(c + o, w)
		compass_phase = float(best)
		if not compass_prev.is_empty():        # the direction: letters and heading between two game pictures
			var dy := rad_to_deg(angle_difference(compass_prev[0], yaw))
			var dp := wrapf(compass_phase - float(compass_prev[1]), -w / 2.0, w / 2.0)
			if absf(dy) > 3.0 and absf(dp) > 1.0 and absf(dp) < 60.0:
				compass_votes = clampi(compass_votes + (1 if dp * dy > 0.0 else -1), -20, 20)
		compass_prev = [yaw, compass_phase]
	if compass_votes != 0 and now - compass_yaw_t > 250:   # still: the game picture is up to date (and does not
		var a := (compass_phase - signf(compass_votes) * yaw * w / TAU) / w * TAU   # change), the offset
		compass_off = compass_off * 0.8 + Vector2(cos(a), sin(a))
	if not learnt:
		compass_rect.visible = false           # (the game's own compass as it is)
		return
	var want := signf(compass_votes) * yaw * w / TAU + compass_off.angle() / TAU * w
	var shift := wrapf(want - compass_phase, -w / 2.0, w / 2.0)
	if absf(shift) > 120.0:                    # (nearly half a turn off: something is wrong, the game's own)
		compass_rect.visible = false
		return
	compass_mat.set_shader_parameter("shift", shift)
	compass_rect.visible = true


func _hud_update() -> void:
	var last_pal := PackedByteArray()
	var last_huz := PackedByteArray()
	while hud_udp.get_available_packet_count() > 0:
		var pk := hud_udp.get_packet()
		if pk.size() < 9:
			continue
		var tag := pk.slice(0, 3).get_string_from_ascii()
		var frame := pk.decode_u32(3)
		if tag == "MOV":                                 # the game's cutscene: its HD version, if made
			_hd_movie_play(pk.slice(7).get_string_from_ascii().to_upper())
			continue
		if tag == "FAD" and pk.size() >= 11:             # the game's own fade (its palette), see _menu_fade
			game_fade = clampf(pk.decode_float(7), 0.0, 1.0)
			game_fade_t = Time.get_ticks_msec()
			continue
		if tag == "MIS":                                 # back in the game's 3D: another mission?
			var mf := pk.slice(7).get_string_from_ascii().to_upper()
			live_mis_name = mf
			if not current.is_empty() and current["entry"]["file"].get_file().to_upper() != mf:
				_load_by_label(mf)
			continue
		if tag == "PIN":                                 # the game holds its cursor: a map dragged (see play_hold)
			if frame & 1:
				_play_hold_pin()
			continue
		if tag == "CUR" and pk.size() >= 15:
			var cw := pk.decode_s16(7)
			var ch := pk.decode_s16(9)
			if frame & 1:                                  # the cursor of the game's 3D (_play_cursor); no size: none
				if cw > 0 and ch > 0 and pk.size() >= 15 + cw * ch * 4:
					var im3 := Image.create_from_data(cw, ch, false, Image.FORMAT_RGBA8, pk.slice(15, 15 + cw * ch * 4))
					var hot3 := Vector2i(pk.decode_s16(11), pk.decode_s16(13))
					if play_cur_img == null or im3.get_data() != play_cur_img.get_data() or hot3 != play_cur_hot:
						play_cur_img = im3
						play_cur_hot = hot3
						play_cur_n += 1
					play_cur_t = Time.get_ticks_msec()
				else:
					play_cur_t = -100000
				continue
			if cw > 0 and ch > 0 and pk.size() >= 15 + cw * ch * 4:
				var img := Image.create_from_data(cw, ch, false, Image.FORMAT_RGBA8, pk.slice(15, 15 + cw * ch * 4))
				var hot := Vector2i(pk.decode_s16(11), pk.decode_s16(13))
				if menu_cursor == null or img.get_data() != menu_cursor.get_data() or hot != menu_cursor_hot:
					menu_cursor = img
					menu_cursor_hot = hot
					_menu_cursor_apply()
			continue
		if tag == "MOD" and pk.size() >= 12:
			menu_frame = Vector2i(maxi(1, pk.decode_s16(8)), maxi(1, pk.decode_s16(10)))
			var own := pk.size() >= 13 and pk[12] == 1
			if own != menu_cursor_own:
				menu_cursor_own = own
				_menu_cursor_apply()
			_set_menu_mode(pk[7] == 1)
			continue
		if tag == "SCR" and pk.size() > 11:
			if frame != menu_img_n:
				menu_parts.clear()
				menu_img_n = frame
			menu_parts[pk.decode_u16(7)] = pk.slice(11)
			if menu_parts.size() == pk.decode_u16(9):
				var jpg := PackedByteArray()
				for k in menu_parts.size():
					jpg.append_array(menu_parts.get(k, PackedByteArray()))
				# the game's screen size, then the zone that changed (x, y, w, h) and its RGB pixels (zlib)
				if jpg.size() > 12:
					var sw := jpg.decode_u16(0)
					var sh := jpg.decode_u16(2)
					var zx := jpg.decode_u16(4)
					var zy := jpg.decode_u16(6)
					var zw := jpg.decode_u16(8)
					var zh := jpg.decode_u16(10)
					var raw := jpg.slice(12).decompress(zw * zh * 3, FileAccess.COMPRESSION_DEFLATE)
					var whole := zx == 0 and zy == 0 and zw == sw and zh == sh
					if raw.size() == zw * zh * 3 and (whole or (menu_img != null and menu_img.get_size() == Vector2i(sw, sh))):
						var zone := Image.create_from_data(zw, zh, false, Image.FORMAT_RGB8, raw)
						if whole:
							menu_img = zone
						else:
							menu_img.blit_rect(zone, Rect2i(0, 0, zw, zh), Vector2i(zx, zy))
						if menu_tex == null or menu_tex.get_size() != Vector2(menu_img.get_size()):
							menu_tex = ImageTexture.create_from_image(menu_img)
							menu_rect.texture = menu_tex
						else:
							menu_tex.update(menu_img)
						menu_fresh = true                               # (shown by _menu_fade)
				menu_parts.clear()
			continue
		if tag == "PAL" and pk.size() >= 15 + 768:
			last_pal = pk                               # the bridge sends every game frame: only the latest is shown
		elif tag == "HUZ":
			last_huz = pk
		elif tag == "HUD":
			if frame != hud_frame:
				hud_parts.clear()
				hud_frame = frame
			hud_parts[pk.decode_u16(7)] = pk.slice(9)
			if hud_parts.size() == 5:
				var buf := PackedByteArray()
				for row in [0, 80, 160, 240, 320]:
					if not hud_parts.has(row):
						return
					buf.append_array(hud_parts[row])
				if buf.size() == 320 * 400 * 2:
					hud_img.set_data(320, 400, false, Image.FORMAT_RG8, buf)
					hud_tex.update(hud_img)
					hud_version += 1
					if OS.has_environment("TN_DEBUG") and frame % 20 == 0:
						print("hud image ", frame, " win ", hud_win)
				hud_parts.clear()
	if not last_pal.is_empty():
		hud_win = Rect2i(last_pal.decode_s16(7), last_pal.decode_s16(9), last_pal.decode_s16(11), last_pal.decode_s16(13))
		hud_pal_img.set_data(256, 1, false, Image.FORMAT_RGB8, last_pal.slice(15, 15 + 768))
		hud_pal.update(hud_pal_img)
	if not last_huz.is_empty():
		var raw := last_huz.slice(7).decompress(320 * 400 * 2, FileAccess.COMPRESSION_DEFLATE)
		if raw.size() == 320 * 400 * 2:
			hud_img.set_data(320, 400, false, Image.FORMAT_RG8, raw)
			hud_tex.update(hud_img)
			hud_version += 1


# The row of the game's 320 x 400 screen the view looks at: the middle of its 3D window. The game projects about
# half its canvas ([0x41ebd8] = height >> 1: 99 of the cockpit's 199 rows, 191 of the full view's 383); 2 rows
# lower (the old 51 %) put Uplink's whole picture 2 rows under the game's at every pitch, in both views.
func _view_row() -> float:
	return hud_win.position.y + hud_win.size.y * 0.5


# The pixel of the game's screen its cursor is kept on in the look mode (the bridge's centre()): the middle of the 3D
# window, 3 rows down. 160, 144 in the cockpit view; 160, 210 in the full view.
func _cross_pixel() -> Vector2i:
	if hud_win.size.x < 100 or hud_win.size.y < 100:
		return Vector2i(160, 144)
	return Vector2i(hud_win.position.x + hud_win.size.x / 2, hud_win.position.y + hud_win.size.y / 2 + 3)


# The game's 3D window (in its 320 x 400 screen, stretched over the window) with the view's centre where the game's
# is (_view_row): off-centre frustum, the horizontal field of view over the whole width (true 16:9: the 3D spans the
# screen).
func _hud_camera(fov: float) -> void:
	if hud_win.size.y <= 0:
		return
	var vs := get_viewport().get_visible_rect().size
	var near := 0.05
	var w := 2.0 * near * tan(deg_to_rad(fov) / 2.0)
	var yc := _view_row() / 400.0 * vs.y
	camera.projection = Camera3D.PROJECTION_FRUSTUM
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.near = near
	camera.size = w
	camera.frustum_offset = Vector2(0, (yc - vs.y / 2.0) / vs.x * w)
	for sm in water_mats:                     # (the water's mirror stops at the game's 3D window)
		(sm as ShaderMaterial).set_shader_parameter("view_rows", 400.0)
		(sm as ShaderMaterial).set_shader_parameter("view_top", hud_win.position.y / 400.0)
		(sm as ShaderMaterial).set_shader_parameter("view_bottom", (hud_win.position.y + hud_win.size.y) / 400.0)


func _play_scancode(e: InputEventKey) -> int:
	var k := e.physical_keycode
	match k:
		KEY_CTRL:
			return 0xE01D if e.location == KEY_LOCATION_RIGHT else 0x1D
		KEY_SHIFT:
			return 0x36 if e.location == KEY_LOCATION_RIGHT else 0x2A
		KEY_ALT:
			return 0xE038 if e.location == KEY_LOCATION_RIGHT else 0x38
	var sc: int = SCANCODES.get(k, 0)
	return key_map.get(sc, sc)


# The coop guest's own keys (his launcher's Game keys, in TN+'s KEYBOARD page): TN_KEYS = "2C:11,11:0,...", the key
# pressed -> the game's key for that command (0: none). The host's are TN+'s own, in his game.
var key_map := _key_map()

static func _key_map() -> Dictionary:
	var m := {}
	for pair in OS.get_environment("TN_KEYS").split(",", false):
		var ab := pair.split(":")
		if ab.size() == 2:
			m[ab[0].hex_to_int()] = ab[1].hex_to_int()
	return m


# The key that swaps look and cursor: TN+'s freelook key, which the player sets on its KEYBOARD page (the launcher's
# Game keys). Its PC scancode comes from the launcher (TN_KEY_FREELOOK) or, with a launcher that does not send it,
# from the TNPlus.ini of the launcher's TN+ next to this folder (tnplus\, else tnplus_coop\: key_freelook); Y when
# neither says, or for a key this window does not know.
var look_key := _look_key()

static func _look_key() -> int:
	var sc := OS.get_environment("TN_KEY_FREELOOK").hex_to_int()
	if sc <= 0:
		var comp := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()
		for d in ["tnplus", "tnplus_coop"]:
			var ini := comp.path_join(d).path_join("TNPlus.ini")
			if not FileAccess.file_exists(ini):
				continue
			for line in FileAccess.get_file_as_string(ini).split("\n"):
				var kv := line.split("=")
				if kv.size() == 2 and kv[0].strip_edges() == "key_freelook":
					sc = kv[1].strip_edges().hex_to_int()
			break                                    # (the first one there is the one the keys are set in)
	for k in SCANCODES:
		if SCANCODES[k] == sc:
			return k
	return KEY_Y


# The viewer's own two keys: the old school look on / off (F12) and its pixel grid finer or coarser (Shift+F12). The
# player picks them in the launcher (TN_KEY_OLDSCHOOL, TN_KEY_SHARP: a PC scancode in hex, after SHIFT+, CTRL+ or ALT+
# if any, as TN+ writes its keys). The grid's not given: Shift with the look's key.
# Two more of its own: a screenshot (TN_KEY_SHOT; not given: Ctrl with the look's key) and the frame counter on / off
# (TN_KEY_FPS; not given: Ctrl+Shift with it).
var own_keys := _own_keys()       # [the look's, the grid's, the screenshot's, the counter's], each [physical key, modifiers (KEY_MASK_...)]
var own_held := {}                # those that are down: their release is the viewer's too

static func _own_keys() -> Array:
	var old := _own_key(OS.get_environment("TN_KEY_OLDSCHOOL"))
	if old.is_empty():
		old = [KEY_F12, 0]
	var sharp := _own_key(OS.get_environment("TN_KEY_SHARP"))
	if sharp.is_empty():
		sharp = [KEY_NONE, 0] if int(old[1]) & KEY_MASK_SHIFT else [old[0], int(old[1]) | KEY_MASK_SHIFT]
	var shot := _own_key(OS.get_environment("TN_KEY_SHOT"))
	if shot.is_empty():
		shot = [KEY_NONE, 0] if int(old[1]) != 0 else [old[0], KEY_MASK_CTRL]
	var fps := _own_key(OS.get_environment("TN_KEY_FPS"))
	if fps.is_empty():
		fps = [KEY_NONE, 0] if int(old[1]) != 0 else [old[0], KEY_MASK_CTRL | KEY_MASK_SHIFT]
	return [old, sharp, shot, fps]


static func _own_key(spec: String) -> Array:
	var parts := spec.strip_edges().to_upper().split("+", false)
	if parts.is_empty():
		return []
	var mods := 0
	for i in parts.size() - 1:
		mods |= int({"SHIFT": KEY_MASK_SHIFT, "CTRL": KEY_MASK_CTRL, "ALT": KEY_MASK_ALT}.get(parts[i].strip_edges(), 0))
	var sc := parts[parts.size() - 1].strip_edges().hex_to_int()
	for k in SCANCODES:
		if SCANCODES[k] == sc:
			return [k, mods]
	return []


# TN+'s second binds (the launcher's Game keys: the middle and side buttons, the wheel, PgUp / PgDn, Home / End, Ins /
# Del can press a command's key as well). TN+ only acts on them when the game's own window is in front: behind
# Uplink's they did nothing. Uplink does it: the launcher says which input presses which key (TN_BINDS: NAME:chord,
# the chord a PC scancode in hex after SHIFT+, CTRL+ or ALT+ if any, the player's own key for that command; or
# NAME:FREELOOK for the look / cursor swap). A button or a key: held as long as it is; a wheel notch: a short press,
# one at a time (as TN+ does).
const BIND_BUTTONS := {MOUSE_BUTTON_MIDDLE: "MID", MOUSE_BUTTON_XBUTTON1: "M4", MOUSE_BUTTON_XBUTTON2: "M5",
		MOUSE_BUTTON_WHEEL_UP: "WHEELUP", MOUSE_BUTTON_WHEEL_DOWN: "WHEELDOWN"}
const BIND_KEYS := {KEY_PAGEUP: "PGUP", KEY_PAGEDOWN: "PGDN", KEY_HOME: "HOME", KEY_END: "END", KEY_INSERT: "INS",
		KEY_DELETE: "DEL"}
var binds := _binds()             # input's name -> [scancode, its modifier's scancode (0: none)]; []: the look swap
var bind_down := {}               # those held: name -> the modifier pressed with it (0: none, or the player's own)
var bind_taps := []               # wheel notches waiting
var bind_tap := ""                # the one pressed now
var bind_tap_t := 0               # when it is let go, then when the next may start (msec)

static func _binds() -> Dictionary:
	var d := {}
	for it in OS.get_environment("TN_BINDS").split(",", false):
		var kv := it.split(":")
		if kv.size() != 2:
			continue
		var parts := kv[1].strip_edges().to_upper().split("+", false)
		if parts.is_empty():
			continue
		if parts[0] == "FREELOOK":
			d[kv[0].strip_edges().to_upper()] = []
			continue
		var mod := int({"SHIFT": 0x2A, "CTRL": 0x1D, "ALT": 0x38}.get(parts[0], 0)) if parts.size() > 1 else 0
		var sc := parts[parts.size() - 1].hex_to_int()
		if sc > 0:
			d[kv[0].strip_edges().to_upper()] = [sc, mod]
	return d


# a bound input pressed or let go, in a mission: true if it has a bind. One that is held is always let go, whatever
# is on screen by then: a game screen that came while it was down left its key down in the game (repeated into the
# menus and the next mission, an Alt bind turning every later key into an Alt chord).
func _bind(name: String, down: bool) -> bool:
	if not binds.has(name) or guest_win:
		return false
	if not down and bind_down.has(name):
		_bind_set(name, false)
		return true
	if not play_started or _on_menu():
		return false
	if (binds[name] as Array).is_empty():             # the look / cursor swap
		if down:
			_look_swap()
	elif name.begins_with("WHEEL"):
		if down and bind_taps.size() < 8:
			bind_taps.append(name)
	else:
		_bind_set(name, down)
	return true


func _bind_set(name: String, down: bool) -> void:
	if down == bind_down.has(name):
		return
	var b: Array = binds[name]
	if down:
		_key_hold(int(b[1]), name, true)              # its Alt / Ctrl / Shift first, if it has one
		_key_hold(int(b[0]), name, true)
		bind_down[name] = int(b[1])
	else:
		_key_hold(int(b[0]), name, false)
		_key_hold(int(bind_down[name]), name, false)
		bind_down.erase(name)


# One of the game's own screens (menus, briefing, debriefing, options: its mouse frame is 640 wide), where the second
# binds do nothing. A paused mission is not one: its binds stay on, like its keys (a bind on Pause must resume too).
func _on_menu() -> bool:
	return menu_mode and menu_frame.x >= 640


# Who holds each of the game's keys down: the player's own finger ("") and the second binds (their input's name). A
# key goes down in the game with its first holder and up with its last. (A bind let go used to send its key's and
# its modifier's release whoever else held them: turning with A held, a click on a bind for Alt + A stopped the turn;
# a bind's Alt let go under the player's own Alt turned his next order into a plain letter.)
var key_holders := {}             # scancode -> {holder: true}

func _key_hold(sc: int, who: String, down: bool) -> void:
	if sc == 0:
		return
	var h: Dictionary = key_holders.get(sc, {})
	if down:
		if h.is_empty():
			_play_key(sc, true)
		h[who] = true
		key_holders[sc] = h
		return
	if not h.erase(who) and not (who == "" and h.is_empty()):
		return                                        # (not one of its holders: nothing of its to let go)
	if h.is_empty():
		key_holders.erase(sc)
		_play_key(sc, false)                          # (also a key that went down before the window was in play)


# the wheel's notches, each frame: one pressed for 50 ms, the next 30 ms after it is let go
func _bind_taps() -> void:
	var now := Time.get_ticks_msec()
	if bind_tap != "":
		if now >= bind_tap_t:
			_bind_set(bind_tap, false)
			bind_tap = ""
			bind_tap_t = now + 30
	elif not bind_taps.is_empty() and now >= bind_tap_t:
		if not play_started or _on_menu():
			bind_taps.clear()
			return
		bind_tap = bind_taps.pop_front()
		_bind_set(bind_tap, true)
		bind_tap_t = now + 50


# look <-> cursor (the look key, Pause, or a bind): the cursor starts on the view's centre
func _look_swap() -> void:
	if not play_started or play_hold or menu_mode:      # (a game screen: the mouse is its cursor's)
		return
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN      # the game draws its own cursor
		var vs := get_viewport().get_visible_rect().size
		Input.warp_mouse((Vector2(_cross_pixel()) + Vector2(0.5, 0.5)) / Vector2(320.0, 400.0) * vs)   # (where the crosshair was)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# old school on / off, or its grid: true if the key was one of the two (the game does not get it)
func _look_keys(event: InputEventKey) -> bool:
	var k := event.physical_keycode
	if not event.pressed:
		return own_held.erase(k)
	var mods := (KEY_MASK_SHIFT if event.shift_pressed else 0) | (KEY_MASK_CTRL if event.ctrl_pressed else 0) | \
			(KEY_MASK_ALT if event.alt_pressed else 0)
	for i in own_keys.size():
		if k == int(own_keys[i][0]) and mods == int(own_keys[i][1]):
			own_held[k] = true
			if not event.echo:
				match i:
					0: _oldschool_toggle()
					1: _oldschool_sharper()
					2: _shot_key()
					3: _fps_toggle()
			return true
	return false


# The window's picture as it is (the view, the HUD, a game screen) saved as a PNG: in the player's Pictures folder,
# "Terra Nova Uplink" (TN_SHOT_DIR: another folder, the tests'). Its name is the date and the time.
func _shot_key() -> void:
	var dir := OS.get_environment("TN_SHOT_DIR")
	if dir == "":
		dir = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES).path_join("Terra Nova Uplink")
	DirAccess.make_dir_recursive_absolute(dir)
	var t := Time.get_datetime_dict_from_system()
	var path := dir.path_join("uplink_%04d-%02d-%02d_%02d-%02d-%02d.png" % [t.year, t.month, t.day, t.hour, t.minute, t.second])
	var img := get_viewport().get_texture().get_image()
	if img != null and img.save_png(path) == OK:
		_note("Screenshot saved: " + path)
	else:
		_note("The screenshot could not be saved in " + dir)


func _fps_toggle() -> void:
	if fps_label != null:
		fps_label.visible = not fps_label.visible


# its name on the player's keyboard (the key at that place: Y is Z on a German one)
func look_key_name() -> String:
	var s := OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(look_key))
	return s if s != "" else OS.get_keycode_string(look_key)


func _play_send(bytes: PackedByteArray) -> void:
	play_udp.put_packet(bytes)


func _host_online(versus := false) -> void:
	host_btn.get_parent().queue_free()
	host_btn = null
	versus_btn = null
	_play_send(("HOSTV" if versus else "HOST").to_ascii_buffer())
	add_child(load("res://scripts/coop_net.gd").new())


func _play_key(sc: int, down: bool) -> void:
	var b := PackedByteArray([0x4B, sc & 0xFF, sc >> 8, 1 if down else 0])
	_play_send(b)
	if down:
		play_held[sc] = true
	else:
		play_held.erase(sc)


func _play_release_all() -> void:
	for sc in play_held.keys():
		_play_key(sc, false)
	key_holders.clear()
	bind_down.clear()                                    # (their keys were among those)
	bind_taps.clear()
	bind_tap = ""
	for bt in [1, 2]:                                    # a button let go elsewhere (alt-tab) would fire forever
		_play_send(PackedByteArray([0x42, bt, 0]))
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	play_started = false


# In and out of the game's own screen (menus...): shown over everything, the mouse freed for the game's cursor (it is
# drawn in the picture); back in the 3D, the mouse is taken again for looking around.
func _hd_movie_play(movie: String) -> void:
	if movie == hd_movie_name or hd_movie == null:
		return
	hd_movie_name = movie
	if OS.has_environment("TN_DEBUG"):
		print("cinematique HD : ", movie)
	var path := ProjectSettings.globalize_path("res://movies_hd/%s.ogv" % movie) if movie != "" else ""
	if path == "" or not FileAccess.file_exists(path):
		hd_movie.stop()
		hd_movie_box.visible = false
		hd_movie_box.get_meta("bg").visible = false
		return
	var st := VideoStreamTheora.new()
	st.file = path
	hd_movie.stream = st
	hd_movie.play()
	hd_movie_box.visible = true
	hd_movie_box.get_meta("bg").visible = true


func _set_menu_mode(on: bool) -> void:
	if on == menu_mode:
		return
	if not on:
		_hd_movie_play("")
	if OS.has_environment("TN_DEBUG"):
		print("menus : mode ", on, " (image ", menu_tex != null, ")")
	menu_mode = on
	if not on and live:
		start_hold = true                               # (black until the mission is ready, _start_ready)
		start_hold_t = Time.get_ticks_msec()
		live_units_seen = 0
	if on:
		menu_fresh = false                              # its picture: one taken from now on (the last one is an old screen)
		menu_mode_t = Time.get_ticks_msec()
	if not play:
		return
	_play_hold_end()                                    # (a button held when one of the game's screens comes)
	if on:
		play_started = true
		_menu_cursor_apply()
	else:
		Input.set_custom_mouse_cursor(null)
		if play_started:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# On the game's screens: its arrow (sent by the bridge, which hides the game's own) as the mouse cursor, stretched
# like the picture; until it is known, the game's cursor in the picture (the mouse hidden).
func _menu_cursor_apply() -> void:
	if not (play and menu_mode):
		return
	if menu_cursor == null or not menu_cursor_own:
		Input.set_custom_mouse_cursor(null)
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		return
	var vs := _menu_box().size
	var k := Vector2(clampf(vs.x / menu_frame.x, 1.0, 4.0), clampf(vs.y / menu_frame.y, 1.0, 4.0))
	var im := menu_cursor.duplicate() as Image
	im.resize(maxi(1, roundi(im.get_width() * k.x)), maxi(1, roundi(im.get_height() * k.y)), Image.INTERPOLATE_NEAREST)
	var hot := (Vector2(menu_cursor_hot) * k).floor()
	hot = hot.clamp(Vector2.ZERO, Vector2(im.get_width() - 1, im.get_height() - 1))
	Input.set_custom_mouse_cursor(im, Input.CURSOR_ARROW, hot)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# The mouse free in the game's 3D (the cursor mode). The bridge is told (F: at once when it changes, and twice a
# second); it empties the game's cursor and sends its picture, which is shown here as the mouse cursor itself: it
# follows the hand at once, where the game's own came with the cockpit's picture (as often as the game draws, one
# game pixel at a time: jerky over the cockpit's map). Stretched like the game's screen, its tip on the pixel it
# points at. Until the bridge has sent it, and if it stops: the game's own, the mouse hidden.
func _play_cursor() -> void:
	if guest_win:                                     # (a coop guest's window: no game of its own to tell)
		return
	var now := Time.get_ticks_msec()
	var free := play_started and not menu_mode and (play_drag or Input.mouse_mode != Input.MOUSE_MODE_CAPTURED)
	# (the game's cursor emptied: for the free cursor, shown here, and for a look mode without the game's crosshair)
	var empty := free or _cross_own(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED)
	if int(empty) != play_free or now - play_free_t > 500:
		play_free = int(empty)
		play_free_t = now
		_play_send(PackedByteArray([0x46, play_free]))
	var vs := get_viewport().get_visible_rect().size
	_cross_draw(_cross_own(Input.mouse_mode == Input.MOUSE_MODE_CAPTURED) and crosshair == "dot" and not play_drag
			and play_cur_img != null and now - play_cur_t < 1500, vs)
	var want := "%d %s %s" % [play_cur_n, vs, play_drag] if free and play_cur_img != null and now - play_cur_t < 1500 else ""
	if want == play_cur_set:
		if want != "" and not play_drag and Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	play_cur_set = want
	if drag_cur != null:
		drag_cur.visible = false
	if want == "":
		if menu_mode:
			_menu_cursor_apply()                          # (a game screen: its own arrow)
		else:
			Input.set_custom_mouse_cursor(null)
			if free and not play_drag:
				Input.mouse_mode = Input.MOUSE_MODE_HIDDEN  # the game draws its own cursor
		return
	var k := Vector2(vs.x / 320.0, vs.y / 400.0)
	k *= minf(1.0, 256.0 / maxf(play_cur_img.get_width() * k.x, play_cur_img.get_height() * k.y))   # (a cursor's most)
	var im := play_cur_img.duplicate() as Image
	im.resize(maxi(1, roundi(im.get_width() * k.x)), maxi(1, roundi(im.get_height() * k.y)), Image.INTERPOLATE_NEAREST)
	var hot := ((Vector2(play_cur_hot) + Vector2(0.5, 0.5)) * k).floor()
	hot = hot.clamp(Vector2.ZERO, Vector2(im.get_width() - 1, im.get_height() - 1))
	if play_drag:                                     # held where the button went down (the mouse is taken: it has
		if drag_cur == null:                          # no cursor of its own meanwhile)
			var dl := CanvasLayer.new()
			dl.layer = 20                             # over the game's HUD
			add_child(dl)
			drag_cur = TextureRect.new()
			drag_cur.mouse_filter = Control.MOUSE_FILTER_IGNORE
			drag_cur.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			dl.add_child(drag_cur)
		drag_cur.texture = ImageTexture.create_from_image(im)
		drag_cur.position = play_drag_win - hot
		drag_cur.size = Vector2(im.get_size())
		drag_cur.visible = true
		return
	Input.set_custom_mouse_cursor(im, Input.CURSOR_ARROW, hot)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# the look mode with the player's own choice of crosshair (a dot, or none) instead of the game's
func _cross_own(captured: bool) -> bool:
	return captured and play_started and not menu_mode and crosshair in ["dot", "none"]


# The dot: on the pixel the game's cursor is kept on in the look mode (_cross_pixel: 160, 144 of its 320 x 400 screen
# in the cockpit view, 160, 210 in the full view), in the colour of the game's crosshair, a dark rim around it. Only
# once the bridge has the game's cursor in hand (it sends
# its picture): until then the game's own crosshair is still there.
func _cross_draw(on: bool, vs: Vector2) -> void:
	if not on:
		if cross_dot != null:
			cross_dot.visible = false
		return
	var d := maxi(4, roundi(vs.y / 180.0))               # its width: 5 pixels at 960 rows, 12 at 4K
	if cross_dot == null:
		var cl := CanvasLayer.new()
		cl.layer = 20                                 # over the game's HUD
		add_child(cl)
		cross_dot = TextureRect.new()
		cross_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cl.add_child(cross_dot)
	if cross_dot.get_meta("key", "") != "%d %d" % [d, play_cur_n]:
		cross_dot.set_meta("key", "%d %d" % [d, play_cur_n])
		var col := Color(0.25, 1.0, 0.35)
		var best := -1.0                                  # the crosshair's brightest colour
		for y in play_cur_img.get_height():
			for x in play_cur_img.get_width():
				var c := play_cur_img.get_pixel(x, y)
				if c.a > 0.5 and c.get_luminance() > best:
					best = c.get_luminance()
					col = Color(c.r, c.g, c.b)
		var n := d + 4
		var im := Image.create(n, n, false, Image.FORMAT_RGBA8)
		var mid := (n - 1) * 0.5
		for y in n:
			for x in n:
				var r := Vector2(x - mid, y - mid).length()
				var a := clampf(d * 0.5 + 1.5 - r, 0.0, 1.0)        # the rim, soft outside
				var k := clampf(d * 0.5 - r + 0.5, 0.0, 1.0)        # the dot inside it
				im.set_pixel(x, y, Color(col.r * k, col.g * k, col.b * k, a * (0.75 + 0.25 * k)))
		cross_dot.texture = ImageTexture.create_from_image(im)
		cross_dot.size = Vector2(n, n)
	cross_dot.position = ((Vector2(_cross_pixel()) + Vector2(0.5, 0.5)) / Vector2(320.0, 400.0) * vs - cross_dot.size * 0.5).round()
	cross_dot.visible = true


# Where the game's own screen is shown in the window. Its 640 x 480 screens (menus, briefings, outfitting) keep their
# own proportions, black on the sides: stretched over a 16:9 window everything on them was a third too wide. (TN+
# 1.2.5 narrows them itself, in the game's picture, by dropping columns of pixels: uneven letters once blown up here.
# The launcher tells it to leave the picture whole: wide_menus = 1.) The other screens fill the window, like the
# cockpit they come with.
func _menu_box() -> Rect2:
	var vs := get_viewport().get_visible_rect().size
	var px: Vector2i = menu_img.get_size() if menu_img != null else menu_frame
	# (only when the launcher says the picture is whole, TN_MENUS43: it started the game with wide_menus = 1. A game
	# the player started himself, or an older launcher: TN+ may have narrowed the screens already, the picture fills
	# the window as it always did)
	if not menus43 or px != Vector2i(640, 480) or vs.x * 3.0 <= vs.y * 4.0:
		return Rect2(Vector2.ZERO, vs)
	var w := roundf(vs.y * 4.0 / 3.0)
	return Rect2(Vector2(floorf((vs.x - w) * 0.5), 0.0), Vector2(w, vs.y))


# each frame: the picture in its box, the black behind it when it does not fill the window
# The game's screen fades in over the view and out to it (0.35 s) instead of cutting: a mission that ends and its
# debriefing, a mission that starts. In: once a picture taken after the change has come (or 0.6 s later: the game's
# screen may be the same as before, and nothing new is sent then).
const MENU_FADE_S := 0.3
var menu_fade := 0.0
var menu_veil := 0.0                             # the black between the two (menu_bg, which is also the screen's black sides)
var menu_fresh := false
var menu_mode_t := 0
# The game's own fade to black (a mission that ends, the death screen: its palette, bridge 'FAD', 1 = as in play): the
# black follows it over the whole window, and the 3D stays as it was (no removal, no unloading) until the game's
# screen comes. The fade used to start only once the game had left its mission: the player saw its objects and its
# map vanish first. Back in a mission: black until its map is loaded and its objects are placed (start_hold).
var game_fade := 1.0
var game_fade_t := 0
var live_mis_name := ""
var start_hold := false
var start_hold_t := 0


func _menu_fade() -> void:
	if menu_rect == null:
		return
	var want := 0.0
	if menu_mode and menu_tex != null and (menu_fresh or Time.get_ticks_msec() - menu_mode_t > 600):
		want = 1.0
	var step := get_process_delta_time() / MENU_FADE_S
	var now := Time.get_ticks_msec()
	if game_fade < 1.0 and now - game_fade_t > 2000:
		game_fade = 1.0                                      # (no news: the bridge went away)
	if start_hold and (now - start_hold_t > 4000 or _start_ready()):
		start_hold = false
	if menu_mode:
		menu_veil = move_toward(menu_veil, 1.0, step)        # to black first, then the screen out of it
		if menu_veil >= 1.0:
			menu_fade = move_toward(menu_fade, want, step)
	else:
		menu_fade = move_toward(menu_fade, 0.0, step)        # the screen to black first, then the view out of it
		if menu_fade <= 0.0 and not start_hold:
			menu_veil = move_toward(menu_veil, 0.0, step)
		menu_veil = maxf(menu_veil, 1.0 - game_fade)         # the game's own fade, as it goes
	menu_rect.visible = menu_fade > 0.0
	(menu_rect.material as ShaderMaterial).set_shader_parameter("fade", menu_fade)   # (its shader writes COLOR: no modulate)
	menu_bg.visible = menu_veil > 0.0
	menu_bg.modulate.a = menu_veil


# a mission back in the game's 3D is ready to be seen: its map loaded (the one the bridge names) and its objects placed
func _start_ready() -> bool:
	if current.is_empty() or live_units_seen < 2:
		return false
	return live_mis_name != "" and current["entry"]["file"].get_file().to_upper() == live_mis_name


func _menu_place() -> void:
	if menu_rect == null:
		return
	_menu_fade()
	var box := _menu_box()
	if menu_rect.position != box.position or menu_rect.size != box.size:
		menu_rect.position = box.position
		menu_rect.size = box.size
		_menu_cursor_apply()                              # (the game's arrow is stretched like its screen)


# Window position -> the game's mouse range on its own screen (menus), the picture in its box (_menu_box).
func _menu_game_pos(p: Vector2) -> Vector2i:
	var box := _menu_box()
	return Vector2i(clampi(int((p.x - box.position.x) / box.size.x * menu_frame.x), 0, menu_frame.x - 1),
			clampi(int((p.y - box.position.y) / box.size.y * menu_frame.y), 0, menu_frame.y - 1))


# Window position -> the game's 320 x 400 screen (the HUD image is stretched over the whole window).
func _play_game_pos(p: Vector2) -> Vector2i:
	var vs := get_viewport().get_visible_rect().size
	return Vector2i(clampi(int(p.x / vs.x * 320.0), 0, 319), clampi(int(p.y / vs.y * 400.0), 0, 399))


func _lobby_open() -> bool:
	for n in get_children():                              # coop guest: the outfitting lobby (coop_lobby.gd) is on screen
		if n.get("lobby") and n.lobby.root and n.lobby.root.visible:
			return true
	return false


func _input(event: InputEvent) -> void:
	if not play:
		return
	if guest_win and _lobby_open():                       # its buttons, lists and chat get the mouse and keys
		if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if not lobby_was_open:
			_play_release_all()                              # nothing held from the mission into the lobby
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		lobby_was_open = true
		return
	if lobby_was_open:                                     # the mission starts: the next click takes the mouse again
		lobby_was_open = false
		play_started = false
	# Two modes, swapped by the freelook key (Y unless the player changed it, see look_key) or Pause, which stay in
	# the viewer: look (mouse captured, it turns the view, clicks at the view's centre) and cursor (the game's own
	# cursor follows the mouse, clicks where it is: the HUD's buttons, the map, free aiming).
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	# a second bind's button let go: seen first, the branches below take the mouse's events for something else (the
	# right button held, a game screen, a button of Uplink's own). (A bound key's release always reaches _bind below.)
	if event is InputEventMouseButton and not event.pressed and BIND_BUTTONS.has(event.button_index):
		_bind(BIND_BUTTONS[event.button_index], false)
	if play_hold and event is InputEventMouse:           # the right button held (see play_hold): moves sent as moves
		if event is InputEventMouseMotion:
			play_drag_acc += event.relative * Vector2(320.0, 400.0) / get_viewport().get_visible_rect().size
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
			if not event.pressed:
				_play_hold_end(event.position)
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			var at := play_drag_at if play_drag else _play_game_pos(event.position)   # (where the game's cursor is)
			var lb := PackedByteArray([0x43, 1, 1 if event.pressed else 0, 0, 0, 0, 0])
			lb.encode_s16(3, at.x)
			lb.encode_s16(5, at.y)
			_play_send(lb)
		get_viewport().set_input_as_handled()
		return
	if host_btn and host_btn.visible and event is InputEventMouse and (host_btn.get_global_rect().has_point(event.position) or
			(versus_btn and versus_btn.get_global_rect().has_point(event.position))):
		return                                          # the "Host online" button's, not the game's
	if event is InputEventKey:
		for n in get_children():                         # typing in coop_net.gd's search or chat
			if n.has_method("wants_keys") and n.wants_keys():
				return
	if event is InputEventMouse:
		for n in get_children():                         # coop_net.gd's own buttons (invite a friend, lock, chat)
			if n.has_method("owns_point") and n.owns_point(event.position):
				return
	if menu_mode and (event is InputEventMouseButton or event is InputEventMouseMotion):
		var mp := _menu_game_pos(event.position)          # the game's own screen: its cursor follows the mouse
		if event is InputEventMouseMotion:
			var c := PackedByteArray([0x50, 0, 0, 0, 0])
			c.encode_s16(1, mp.x)
			c.encode_s16(3, mp.y)
			_play_send(c)
		elif event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			# (a press in the black beside a 4:3 screen is not the game's: it was sent as a click on its first or last
			# column; a release always goes, for a press that began on the picture)
			if not event.pressed or _menu_box().has_point(event.position):
				var b := PackedByteArray([0x43, 1 if event.button_index == MOUSE_BUTTON_LEFT else 2, 1 if event.pressed else 0, 0, 0, 0, 0])
				b.encode_s16(3, mp.x)
				b.encode_s16(5, mp.y)
				_play_send(b)
		elif BIND_BUTTONS.has(event.button_index):       # (a paused mission keeps its second binds: see _on_menu)
			_bind(BIND_BUTTONS[event.button_index], event.pressed)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		if not play_started:
			if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
				play_started = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED   # this click only takes the mouse
		elif guest_win and event.button_index == MOUSE_BUTTON_MIDDLE:
			free_look = event.pressed
		elif guest_win and not captured and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and \
				(Rect2(58, 377, 28, 17).has_point(Vector2(_play_game_pos(event.position))) or
				Rect2(240, 256, 44, 14).has_point(Vector2(_play_game_pos(event.position)))):
			var on_map := Rect2(58, 377, 28, 17).has_point(Vector2(_play_game_pos(event.position)))
			for n in get_children():                     # coop guest: the cockpit's MAP / STATUS buttons, mouse free
				if on_map and n.has_method("toggle_map"):
					n.toggle_map()
				elif not on_map and n.has_method("toggle_status"):
					n.toggle_status()
		elif event.button_index == MOUSE_BUTTON_LEFT or event.button_index == MOUSE_BUTTON_RIGHT:
			var bt := 1 if event.button_index == MOUSE_BUTTON_LEFT else 2
			if captured:
				_play_send(PackedByteArray([0x42, bt, 1 if event.pressed else 0]))
			else:
				var gp := _play_game_pos(event.position)
				var b := PackedByteArray([0x43, bt, 1 if event.pressed else 0, 0, 0, 0, 0])
				b.encode_s16(3, gp.x)
				b.encode_s16(5, gp.y)
				_play_send(b)
				if bt == 2 and event.pressed and not guest_win:     # held: its moves are sent as moves (see play_hold)
					play_hold = true
					play_drag = false
					play_drag_at = gp
					play_drag_win = event.position
					play_drag_acc = Vector2.ZERO
		elif BIND_BUTTONS.has(event.button_index):       # the wheel, the middle and side buttons: TN+'s second binds
			_bind(BIND_BUTTONS[event.button_index], event.pressed)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		if captured and guest_win and (free_look or Input.is_physical_key_pressed(KEY_ALT)):
			look_off.x = clampf(look_off.x - event.relative.x * 0.004, -2.1, 2.1)
			look_off.y = clampf(look_off.y - event.relative.y * 0.004, -1.05, 1.05)
		elif captured:
			play_dx += event.relative.x * mouse_sens
			play_dy += event.relative.y * mouse_sens * (-1.0 if invert_y else 1.0)
		elif play_started:
			play_cursor = _play_game_pos(event.position)
		get_viewport().set_input_as_handled()
	elif event is InputEventKey:
		if guest_win and event.physical_keycode == KEY_TAB and event.pressed and not event.echo:
			for n in get_children():                 # coop guest: WEAPON / STATUS page (coop_hud.gd)
				if n.has_method("toggle_status"):
					n.toggle_status()
			get_viewport().set_input_as_handled()
			return
		if guest_win and event.physical_keycode == KEY_M and event.pressed and not event.echo:
			for n in get_children():                 # coop guest: his map, big or small (coop_hud.gd)
				if n.has_method("toggle_map"):
					n.toggle_map()
			get_viewport().set_input_as_handled()
			return
		# (not on a game screen: the swap took the mouse there, which then stayed hidden; and the key is the game's
		# there, a letter to type in a save's name)
		if (event.physical_keycode == KEY_PAUSE or event.physical_keycode == look_key) and not menu_mode:
			if event.pressed and not event.echo:
				_look_swap()
		elif _look_keys(event):                         # the viewer's own: old school on / off, its pixel grid
			pass
		elif not event.echo:
			var sc := _play_scancode(event)
			if sc != 0:
				_key_hold(sc, "", event.pressed)
				# both Shift keys down, one let go: Windows only tells of the last one let go. The other stayed down
				# in the game for good (the bridge holds a Shift until told: the Bound went on with nothing held)
				if not event.pressed and (sc == 0x2A or sc == 0x36) and (key_holders.get(0x2A + 0x36 - sc, {}) as Dictionary).has(""):
					_key_hold(0x2A + 0x36 - sc, "", false)
			if BIND_KEYS.has(event.physical_keycode):    # (a second bind on it: its command's key as well)
				_bind(BIND_KEYS[event.physical_keycode], event.pressed)
		get_viewport().set_input_as_handled()


# the bridge: the game holds its cursor where the right button went down (a map is being dragged)
func _play_hold_pin() -> void:
	if play_hold and not play_drag:
		play_drag = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# The right button let go (or the window left, or one of the game's screens come): the button up where the game's
# cursor is. Where the button went down if the game held it there (the mouse comes back to that place, free), else
# where the mouse is.
func _play_hold_end(win_pos = null) -> void:
	if not play_hold:
		return
	play_hold = false
	var at := play_drag_at
	if not play_drag:
		at = _play_game_pos(win_pos if win_pos != null else get_viewport().get_mouse_position())
	var b := PackedByteArray([0x43, 2, 0, 0, 0, 0, 0])
	b.encode_s16(3, at.x)
	b.encode_s16(5, at.y)
	_play_send(b)
	play_cursor = at
	play_drag_acc = Vector2.ZERO
	if play_drag:
		play_drag = false
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_HIDDEN      # the cursor mode again (_play_cursor shows the cursor)
			Input.warp_mouse(play_drag_win)


func _notification(what: int) -> void:
	if play and what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_play_hold_end()
		_play_release_all()


func _live_update() -> void:
	_smoke_linger()
	if play and (absf(play_dx) >= 1.0 or absf(play_dy) >= 1.0):
		var dx := clampi(int(play_dx), -32000, 32000)
		var dy := clampi(int(play_dy), -32000, 32000)
		play_dx -= dx
		play_dy -= dy
		var b := PackedByteArray([0x4D, 0, 0, 0, 0])
		b.encode_s16(1, dx)
		b.encode_s16(3, dy)
		_play_send(b)
	if play and play_cursor != play_cursor_sent and play_cursor.x >= 0 and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		var c := PackedByteArray([0x50, 0, 0, 0, 0])
		c.encode_s16(1, play_cursor.x)
		c.encode_s16(3, play_cursor.y)
		_play_send(c)
		play_cursor_sent = play_cursor
	if play_hold and (absf(play_drag_acc.x) >= 1.0 or absf(play_drag_acc.y) >= 1.0):
		var mv := Vector2i(play_drag_acc)               # (whole pixels of the game's screen; the rest kept)
		play_drag_acc -= Vector2(mv)
		var r := PackedByteArray([0x52, 0, 0, 0, 0])
		r.encode_s16(1, clampi(mv.x, -32000, 32000))
		r.encode_s16(3, clampi(mv.y, -32000, 32000))
		_play_send(r)
	if play:
		_play_cursor()
		_bind_taps()
	if host_btn:
		host_btn.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
		if versus_btn:
			versus_btn.visible = host_btn.visible
	if hud:
		_hud_update()
	_menu_place()                                     # (after the screen's own news: its black sides come and go with it)
	_puffs_update()
	_anims_update()
	if fps_label != null:
		fps_label.text = "%d fps" % Engine.get_frames_per_second()
	_oldschool_palette()
	var pk := PackedByteArray()
	while udp.get_available_packet_count() > 0:
		var q := udp.get_packet()
		if q.size() == 4 + 128 * 128 and q.slice(0, 4).get_string_from_ascii() == "VEGM":
			_live_vegetation(q.slice(4))
		elif q.size() >= 8 and q.slice(0, 4).get_string_from_ascii() == "SCOR":
			_live_scorch(q.slice(4))
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "DRAW" and q.size() == 6 + (q.decode_u16(4) + 7) / 8:
			live_drawn = q.slice(6)
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "SLEN" and q.size() == 6 + 28 * q.decode_u16(4):
			for k in q.decode_u16(4):
				var o := 6 + 28 * k
				live_sizes[q.decode_s32(o)] = [q.decode_float(o + 4), q.decode_float(o + 8), q.decode_float(o + 12),
						q.decode_float(o + 16), q.decode_float(o + 20), q.decode_float(o + 24)]
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "ARMS" and q.size() == 6 + 5 * q.decode_u16(4):
			for k in q.decode_u16(4):
				_live_arms(q.decode_s32(6 + 5 * k), q[10 + 5 * k])
		elif q.size() == 5 and q.slice(0, 4).get_string_from_ascii() == "IRVW":
			if ir_on != (q[4] == 1):
				ir_on = q[4] == 1                           # the game's infrared view (key I)
				for k in mats:                              # (the suits: unlit in it, _limb_light)
					if mats[k] is ShaderMaterial and (mats[k] as ShaderMaterial).has_meta("lit"):
						_limb_light_set(mats[k])
			var old := oldschool_rect != null and oldschool_rect.visible
			if ir_rect != null:
				ir_rect.visible = ir_on and not old             # (the old school mode reads the view itself: it tints)
			for wm in water_mats:                          # the game draws its water tiles plain in infrared
				wm.set_shader_parameter("plain", ir_on)
			if oldschool_rect != null:
				(oldschool_rect.material as ShaderMaterial).set_shader_parameter("ir", ir_on)
			RenderingServer.global_shader_parameter_set("tn_ir", 1.0 if ir_on else 0.0)
		elif q.size() >= 5 and q.slice(0, 4).get_string_from_ascii() == "SUBV":
			_sub_views(q)
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "FX29" and q.size() == 6 + 5 * q.decode_u16(4):
			fx29.clear()                                    # the 6/29 that are not a shot's dust (live_bridge.py)
			for k in q.decode_u16(4):
				fx29[q.decode_s32(6 + 5 * k)] = q[10 + 5 * k]
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "BOLT" and q.size() == 6 + 25 * mini(q.decode_u16(4), 2000):
			_live_bolts(q)                                  # the SIR's lightning (live_bridge.py eclairs)
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "ANIM" and q.size() == 6 + 5 * q.decode_u16(4):
			anim_frames.clear()                             # the animated effects' frames in the game (live_bridge.py animations)
			for k in q.decode_u16(4):
				anim_frames[q.decode_s32(6 + 5 * k)] = q[10 + 5 * k]
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "PART" and q.size() == 6 + 14 * q.decode_u16(4):
			_live_parts(q)                                  # the shots' dust, particle by particle (live_bridge.py poussieres)
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "DEBR" and q.size() == 6 + 22 * q.decode_u16(4):
			shards.clear()                                  # a blown-up building's pieces (live_bridge.py debris)
			for k in q.decode_u16(4):
				var o := 6 + 22 * k
				shards[q.decode_s32(o)] = [q.decode_s32(o + 4), q.decode_float(o + 8), q.decode_float(o + 12),
						q.decode_u16(o + 16), q.decode_u16(o + 18), q.decode_u16(o + 20)]
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "BEAM" and q.size() == 6 + 29 * q.decode_u16(4):
			beams.clear()                                   # the game's beams, their two ends (live_bridge.py rayons)
			beam_mode = true
			for k in q.decode_u16(4):
				var o := 6 + 29 * k
				beams[q.decode_s32(o)] = [Vector3(q.decode_float(o + 4), q.decode_float(o + 12), q.decode_float(o + 8)),
						Vector3(q.decode_float(o + 16), q.decode_float(o + 24), q.decode_float(o + 20)), q[o + 28]]
				_beam_flash_note(q.decode_s32(o))
		elif q.size() >= 5 and q.slice(0, 4).get_string_from_ascii() == "SMKC" and _smoke_packet_ok(q):
			_live_smoke(q)                                  # smoke grenades' clouds (live_bridge.py, fumees)
		elif q.size() == 16 and q.slice(0, 4).get_string_from_ascii() == "WTHR":
			_live_weather(q)                                # snow / rain (live_bridge.py, meteo)
		elif q.size() > 6 and q.slice(0, 4).get_string_from_ascii() == "TEXL":
			_live_tiles(q)                                  # the ground tiles as the game holds them (its snow)
		elif q.size() == 8 and q.slice(0, 4).get_string_from_ascii() == "HAZE":
			_haze_fog(q.decode_float(4))                   # the haze the game draws with (live_bridge.py, hazing.py)
		elif (q.size() == 12 or q.size() == 16) and q.slice(0, 4).get_string_from_ascii() == "WAYP":
			if q.size() == 16:                              # the game's angle word (12 bytes: an older bridge, none)
				_waypoint_word(q.decode_u32(12) & 0xFFFF)
			_live_waypoint(Vector2(q.decode_float(4), q.decode_float(8)))
		elif q.size() >= 12 and q.slice(0, 4).get_string_from_ascii() == "SKYO":
			cloud_base = Vector2(q.decode_float(4), q.decode_float(8))   # the game's wind offset of its clouds
			if q.size() >= 16:
				cloud_sway = q.decode_u32(12)            # its cloud sway's phase ([0x427DB0], +193 a tick)
			cloud_live_t = Time.get_ticks_msec()
		else:
			pk = q
	if pk.size() < 24:
		_live_smooth()
		return
	var h := pk.decode_float(12)
	# game heading 0 = +x, then towards +y (Godot +z)
	_cam_target(Vector3(pk.decode_float(0), pk.decode_float(8), pk.decode_float(4)), atan2(-cos(h), -sin(h)), pk.decode_float(16))
	camera.keep_aspect = Camera3D.KEEP_WIDTH        # the game gives its horizontal field of view
	camera.fov = pk.decode_float(20)
	_live_smooth()
	if hud or hud_win.size.y > 0:                     # coop guest: its cockpit's window (coop_hud.gd)
		_hud_camera(camera.fov)
	live_seen += 1
	if play and OS.has_environment("TN_PLAYTEST") and (live_seen == 100 or live_seen == 220):
		var ev := InputEventKey.new()          # tests: Forward held for 120 frames, as if typed in the window
		ev.physical_keycode = KEY_W
		ev.pressed = live_seen == 100
		Input.parse_input_event(ev)
	if pk.size() >= 32 and not current.is_empty() and game_fade < 0.7:
		pass                                            # (the game fading out: its scene kept as it was; it empties
		# its entities once black, so a third of the way is soon enough, and a short dim (a flash) stops nothing)
	elif pk.size() >= 32 and not current.is_empty():
		_live_units(pk)
		_smooth_capture()
		live_units_seen += 1
	if live_shot != "" and live_seen == live_shot_frame:
		_screenshot(live_shot)


# The player's waypoint (a click on the cockpit's map; live_bridge.py 'WAYP', x = 0: none). The game draws it in its
# own 3D, which this view replaces: a purple wire pyramid turning on itself, its middle 1 above the ground (apex 1
# up, three base points 0.5 down and 1 around: its drawobj.c), seen through the hills, and next to it its distance
# in the game's metres (6 to a unit). Lines and letters keep their size on the screen whatever the distance, as the
# game's do (a line: about a pixel of its 848 x 400 picture; waypoint.gdshader). The HUD's side views show the
# pyramid too, without the distance (letters that size are too small there).
const WAYPOINT_COLOUR := 0x9C                    # its colour in the game's palette
const WAYPOINT_POINTS := [Vector3(0, 1, 0), Vector3(-1, -0.5, 0), Vector3(0.5, -0.5, 0.855), Vector3(0.5, -0.5, -0.855)]
# its turn: the game's own angle word (sent by the bridge), heading as the units' (-word turns about up; these points
# stand 90 degrees off the game's model axes), followed between packets at its last rate. Without it (an older
# bridge): about the game's rate, 1/256 of a turn with each 3D view it draws (~64 a second; twice that with a camera
# panel open), the same way
const WAYPOINT_TURN := 0.25                      # turns a second (an approximation: see above)
var wp_word := -1.0                              # its last angle word (-1: none came), the time it came, its rate
var wp_t := 0.0
var wp_rate := 0.0
const WAYPOINT_LINE := 1.25                      # its lines' width, in rows of the game's picture
const WAYPOINT_TEXT := 9.5                       # its letters' size, the same (capitals 7 rows high)
var waypoint: Node3D
var waypoint_at := Vector2.ZERO
var live_me := -1                                # the player's entity (live): the waypoint's distance is from his suit


func _live_waypoint(at: Vector2) -> void:
	waypoint_at = at
	if at.x == 0.0 or current.is_empty():
		if waypoint != null:
			waypoint.visible = false
		return
	if waypoint == null:
		waypoint = Node3D.new()
		var wm := ShaderMaterial.new()
		wm.shader = WAYPOINT
		wm.render_priority = 10
		var rod := CylinderMesh.new()               # one for all its lines: 1 long, 1 thick (the shader sizes it)
		rod.top_radius = 1.0
		rod.bottom_radius = 1.0
		rod.height = 1.0
		rod.radial_segments = 6
		rod.rings = 0
		var spin := Node3D.new()
		spin.name = "spin"
		waypoint.add_child(spin)
		for e in [[0, 1], [0, 2], [0, 3], [1, 2], [2, 3], [3, 1]]:
			var a: Vector3 = WAYPOINT_POINTS[e[0]]
			var b: Vector3 = WAYPOINT_POINTS[e[1]]
			var up := (b - a).normalized()
			var side := up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT).normalized()
			var mi := MeshInstance3D.new()
			mi.mesh = rod
			mi.material_override = wm
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.position = (a + b) * 0.5
			mi.basis = Basis(side, up * (b - a).length(), side.cross(up))
			mi.extra_cull_margin = 2.0                  # (thicker than its mesh when seen from far)
			spin.add_child(mi)
		var l := Label3D.new()
		l.name = "label"
		l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		l.fixed_size = true
		l.no_depth_test = true
		l.shaded = false
		l.render_priority = 11
		l.outline_size = 5                          # (thick strokes, as the game's small letters)
		l.font_size = 48
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		l.vertical_alignment = VERTICAL_ALIGNMENT_TOP
		l.layers = SUB_HIDE_LAYER                   # (the main view only)
		waypoint.add_child(l)
		waypoint.set_meta("mat", wm)
		add_child(waypoint)
	var col: Color = hud_pal_img.get_pixel(WAYPOINT_COLOUR, 0) if hud_pal_img != null and hud_version > 0 else (
			pal[WAYPOINT_COLOUR] if pal.size() > WAYPOINT_COLOUR else Color(0.47, 0.0, 0.72))
	(waypoint.get_meta("mat") as ShaderMaterial).set_shader_parameter("colour", col)
	(waypoint.get_node("label") as Label3D).modulate = col
	(waypoint.get_node("label") as Label3D).outline_modulate = col
	waypoint.position = Vector3(at.x, TNData.height_at(current["map"], at.x, at.y) + 1.0, at.y)
	waypoint.visible = true
	_waypoint_update(0.0)


func _waypoint_word(w: int) -> void:
	var now := Time.get_ticks_usec() / 1e6
	var dt := now - wp_t
	if wp_word < 0.0 or dt > 0.5:
		wp_rate = 0.0                                   # (the first, or after a gap: no rate from stale data)
	elif dt > 0.0:
		wp_rate = fposmod(float(w) - wp_word, 65536.0) / dt
	wp_word = float(w)
	wp_t = now


func _waypoint_update(delta: float) -> void:
	if waypoint == null or not waypoint.visible:
		return
	var spin := waypoint.get_node("spin") as Node3D
	if wp_word >= 0.0:
		var wd := wp_word + wp_rate * minf(Time.get_ticks_usec() / 1e6 - wp_t, 0.25)
		spin.rotation.y = fposmod(-wd / 65536.0 * TAU - PI / 2.0, TAU)
	else:
		spin.rotation.y = fposmod(spin.rotation.y - TAU * WAYPOINT_TURN * delta, TAU)
	var vs := get_viewport().get_visible_rect().size
	(waypoint.get_meta("mat") as ShaderMaterial).set_shader_parameter("width", WAYPOINT_LINE * vs.y / 400.0)
	# the letters: what a window pixel is worth one unit away (the field of view is the game's horizontal one, zoom
	# included)
	var px := 2.0 * tan(deg_to_rad(camera.fov) * 0.5) / vs.x
	var l := waypoint.get_node("label") as Label3D
	l.pixel_size = WAYPOINT_TEXT * vs.y / 400.0 * px / l.font_size
	# the game writes it 15 columns right of the pyramid's middle and from 3 rows above it (of its 848 x 400 picture)
	l.offset = Vector2(15.0 * vs.x / 848.0, 3.0 * vs.y / 400.0) * px / l.pixel_size
	# from the player's suit, as the game measures it (the eye stands a little ahead of the suit: from the camera it
	# read a metre short)
	var from := Vector2(camera.position.x, camera.position.z)
	var me: Array = live_ents.get(live_me, [])
	if me.size() >= 5:
		from = Vector2(me[3], me[4])
	l.text = "%d M" % int(6.0 * (from - waypoint_at).length())


# Game entities after the camera: count, player index, then 32 bytes each: index, class, type, active (int32),
# x, y, z (game units), heading (radians). The mission file's entities are a run of the game's table (in the same
# order, after the player): found once by their class / type, then moved, turned, hidden when gone. A destroyed
# entity's slot is reused (shots, sparks), so the run is the best match, not a perfect one.
# After them: the soldiers' joints, the articulated parts, then the entity the view is seen from: the player, or his
# drone while he looks through it (its view swapped with the HUD's: "DRONE VIEW").
# an effect's node can be freed by another path (an animation that ended, a node replaced by another kind) while
# its dictionary still holds it: dropped here before anything touches it
func _drop_freed(d: Dictionary) -> void:
	for idx in d.keys():
		if not is_instance_valid(d[idx]):
			d.erase(idx)


func _live_units(pk: PackedByteArray) -> void:
	var n := pk.decode_s32(24)
	var player := pk.decode_s32(28)
	live_me = player
	var body := player                                 # whose body the view hides: the one it is seen from
	var tail := 32 + 32 * n
	if pk.size() >= tail + 4:
		tail += 4 + 200 * pk.decode_s32(tail)
		if pk.size() >= tail + 4:
			tail += 4 + 8 * pk.decode_s32(tail)
			if pk.size() >= tail + 4:
				body = pk.decode_s32(tail)
				if pk.size() >= tail + 8:
					_live_alarm(pk.decode_s32(tail + 4) != 0)   # (after the body: the alarm, newer bridges)
				live_refs.clear()
				if pk.size() >= tail + 12:                # (then the suits' limb reference vectors: _game_views)
					var o := tail + 12
					for k in pk.decode_s32(tail + 8):
						if o + 68 > pk.size():
							break
						var rv := [pk.decode_float(o + 4)]
						for c in 5:
							rv.append(Vector3(pk.decode_float(o + 8 + 12 * c), pk.decode_float(o + 12 + 12 * c), pk.decode_float(o + 16 + 12 * c)))
						live_refs[pk.decode_s32(o)] = rv
						o += 68
	# the view's own body hides (coop: the guest's window changes suit, or watched the host's until it had one: the
	# old body shows again). A teammate is one of the mission's units (live_nodes, placed once live_off is found),
	# not only an extra: looked for again each time, else the guest saw his own suit around his eyes
	var pn: Node3D = _live_node(body) if body >= 0 else null
	if body != live_player or pn != live_player_node:
		var was: Node3D = live_player_node
		if was != null and is_instance_valid(was) and was != pn:
			was.remove_meta("player_body")
			_sub_hide(was, false, PLAYER_LAYER)
			was.remove_meta("player_body")
		if pn != null:
			_sub_hide(pn, true, PLAYER_LAYER)
		live_player = body
		live_player_node = pn
	var ents := {}
	live_ents = ents
	for k in n:
		var o := 32 + 32 * k
		if o + 32 > pk.size():
			break
		ents[pk.decode_s32(o)] = [pk.decode_s32(o + 4), pk.decode_s32(o + 8), pk.decode_s32(o + 12),
			pk.decode_float(o + 16), pk.decode_float(o + 20), pk.decode_float(o + 24), pk.decode_float(o + 28)]
	var joints := {}                                   # game index -> 16 joints (after the entities)
	var feet := {}                                     # game index -> height of its lowest foot
	var jo := 32 + 32 * n
	if pk.size() >= jo + 4:
		var nj := pk.decode_s32(jo)
		jo += 4
		for k in nj:
			if jo + 200 > pk.size():
				break
			var jp: Array[Vector3] = []
			for q in 16:
				jp.append(Vector3(pk.decode_float(jo + 8 + 12 * q), pk.decode_float(jo + 12 + 12 * q), pk.decode_float(jo + 16 + 12 * q)))
			joints[pk.decode_s32(jo)] = jp
			feet[pk.decode_s32(jo)] = pk.decode_float(jo + 4)
			jo += 200
		if pk.size() >= jo + 4:
			_live_arts(pk, jo)
	var mis: Array = current["mission"]["entities"]
	if live_off < 0 and not mis.is_empty():         # (the start-up flat map has none: searched once a mission loads)
		var best_n := 0
		for off in 64:
			var hits := 0
			for k in mis.size():
				var e = ents.get(off + k)
				if e != null and e[0] == mis[k]["cls"] and e[1] == mis[k]["sub"]:
					hits += 1
			if hits > best_n:
				best_n = hits
				live_off = off
		if best_n < mini(3, mis.size()):
			live_off = -1                               # not found yet: units still drawn where the file puts them
			# (a few survivors in place pin it: late in a mission most of the file's units are dead and their slots
			# reused, and the run is still at the same index)
		else:
			print("live: mission entities at game index ", live_off, " (", best_n, " / ", mis.size(), " in place)")
	var m: Dictionary = current["map"]
	if live_off >= 0:
		for k in live_nodes.size():
			var e = ents.get(live_off + k)
			if e != null and (e[0] != mis[k]["cls"] or e[1] != mis[k]["sub"]):
				e = null                                # its slot holds something else now: it was destroyed
			var node: Node3D = live_nodes[k]
			if node.has_meta("corpse"):
				if e == null or e[2] == 0:
					continue
				node.remove_meta("corpse")              # active again in its own slot: the mission was restarted
				node.set_meta("alive", false)           # (killed units stayed hidden after "Retry the mission")
			if e == null and node.get_meta("alive", false) and (node.has_meta("soldier") or node.has_meta("mech")):
				_make_corpse(node, m)                    # killed, and its slot already reused
				continue
			_live_place(node, e, m)
			if e != null and e[2] != 0:
				node.set_meta("alive", true)
	for d in [live_fx, live_piles, live_extra]:
		_drop_freed(d)
		for idx in d:
			d[idx].visible = false
	puff_units.clear()
	if ents.has(player):                             # the player's own jetpack only: around the other soldiers the
		var u = ents[player]                         # weapons' dust settles at their feet too (thousands of 6/29 in a
		puff_units.append(Vector3(u[3], u[5], u[4]))  # fight), which made puffs fill the screen; the game shows none
	_pulsar_trails(ents)
	_beam_flashes()
	for idx in ents:
		var e = ents[idx]
		if (e[0] == 5 or e[0] == 6) and e[2] != 0:
			_live_fx(idx, e)
			if live_shot != "" and OS.has_environment("TN_FXSHOT") and live_shot_frame > live_seen + 20:
				live_shot_frame = live_seen + 20           # tests: capture as soon as a shot flies
			continue
		var k: int = idx - live_off
		var mine: bool = live_off >= 0 and k >= 0 and k < mis.size() and e[0] == mis[k]["cls"] and e[1] == mis[k]["sub"]
		if mine or e[0] > 4:
			continue                                    # units, vehicles, probes, buildings set up in play (turrets),
		# and decor: when a tree or bush is hit, the game empties its vegetation cell and makes every plant of the
		# cell a decor entity, intact (drawn like the plant); hit once, its picture is its burnt stump (the bridge:
		# bit 1 of active), a destroyed one leaves the table, its ground burnt. (A mission's own plants keep the
		# state of the file: the only ones, MISS13's, start burnt and the game never puts one back)
		var ct := Vector3i(e[0], e[1], (int(e[2]) >> 1) & 1 if e[0] == 0 else 0)
		if live_extra.has(idx) and live_extra[idx].get_meta("ct") != ct:
			var old: Node3D = live_extra[idx]           # slot reused by another unit
			if old.has_meta("soldier") or old.has_meta("mech"):
				_make_corpse(old, m)                    # the soldier that was there died: its body stays
			else:
				old.queue_free()
			live_extra.erase(idx)
		if not live_extra.has(idx) and e[2] != 0:
			live_extra[idx] = _add_object(m, e[0], e[1], e[3], e[4], e[6], "", false, 0.0, 0, 0.0, ct.z)
			live_extra[idx].set_meta("ct", ct)
			if idx == body:
				_sub_hide(live_extra[idx], true, PLAYER_LAYER)
		if live_extra.has(idx):
			_live_place(live_extra[idx], e, m)
	if draw_distance and not live_drawn.is_empty() and not free_look:
		# as in the game (its distances per type, see the bridge's DRAW): hidden, not freed (a suit keeps its steps)
		for idx in ents:
			if idx >> 3 >= live_drawn.size() or live_drawn[idx >> 3] & (1 << (idx & 7)) or idx == body:
				continue
			for hid in [_live_node(idx), live_fx.get(idx), live_piles.get(idx)]:
				if hid != null and is_instance_valid(hid):
					hid.visible = false
	for idx in live_sizes:                             # each soldier's own lengths (the bridge's SLEN): for the game's
		var se = ents.get(idx)                         # poses and for its own steps alike (_gait: the far ones, the
		if se == null or se[0] != 1:                   # player's own body)
			continue
		var sn := _live_node(idx)
		if sn != null and sn.has_meta("soldier") and sn.get_meta("size", []) != live_sizes[idx]:
			_live_size(sn, live_sizes[idx])
	for idx in joints:                                 # soldiers the game draws: its own animation
		var node: Node3D = live_extra.get(idx)
		if node == null and live_off >= 0 and idx - live_off >= 0 and idx - live_off < live_nodes.size():
			node = live_nodes[idx - live_off]
		if node != null and node.visible and node.has_meta("soldier"):
			var now_ms := Time.get_ticks_msec()
			# a pose read half written (_arms_off) is left out: the suit keeps its last one, and with none for
			# GAIT_STALE (a far suit the game no longer animates) walks on its own steps. (Each one put the suit on its own
			# steps for 3 s: one the game drew in all but 2 frames in 760 walked on them most of the time, its feet on
			# the map's ground, strides narrower than the game's, a leg straight on a step)
			# Nor one with a bone too long to draw (_pose_soldier left the suit in its last pose, for as long as they came)
			if not _bones_long(node, joints[idx]) and not _arms_off(joints[idx]):
				if now_ms - int(node.get_meta("jt", -100000)) > GAIT_STALE:
					node.set_meta("jt0", now_ms)            # its poses again after a while without (GAIT_BACK)
				node.set_meta("jt", now_ms)
				if not _gait_wanted(node, now_ms):
					if live_refs.has(idx):
						node.set_meta("refs", live_refs[idx])
					_pose_suit(node, joints[idx], false)
			if not node.has_meta("corpse") and not node.has_meta("gait"):
				node.position.y = feet[idx]              # on its lowest foot (the entity minus GAME_Z left suits
				# ~0.06 above the game's, seen up close)
				node.set_meta("feet_off", feet[idx] - float(node.get_meta("ez", feet[idx])))
		elif node != null and node.visible and node.has_meta("mech"):
			_pose_mech(node, joints[idx])
			node.set_meta("mech_pose", joints[idx])
			node.position.y = feet[idx]              # on its feet: the walker's entity is 0.23 to 0.39 above them
			# as it walks (a suit's: 0.15), so GAME_Z left it floating
			node.set_meta("feet_off", feet[idx] - float(node.get_meta("ez", feet[idx])))


# The HUD's side views: each one a small viewport sharing the world, its camera where the game puts it (the unit's
# position, from the shared viewpoint the game draws them with) facing the unit's heading, laid over the game's own
# small view in the HUD. Hidden when the bridge stops seeing it (button off, probe recalled) or on the game's screens.
func _sub_views(q: PackedByteArray) -> void:
	var now := Time.get_ticks_msec()
	var vs := get_viewport().get_visible_rect().size
	var k := vs / Vector2(320, 400)
	if sub_layer == null:
		sub_layer = CanvasLayer.new()
		sub_layer.layer = 2                          # over the HUD, under the game's screens
		add_child(sub_layer)
	var n := q[4]
	for j in n:
		var o := 5 + 37 * j
		if o + 37 > q.size():
			break
		var panel := q[o]
		if not SUB_RECTS.has(panel):
			continue
		var sv: Dictionary = sub_views.get(panel, {})
		if sv.is_empty():
			var vp := SubViewport.new()
			vp.world_3d = get_viewport().world_3d
			vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			var cam := Camera3D.new()
			cam.keep_aspect = Camera3D.KEEP_WIDTH
			cam.fov = SUB_FOV
			cam.near = 0.05
			cam.far = camera.far
			cam.cull_mask = 0xFFFFF & ~SUB_HIDE_LAYER
			vp.add_child(cam)
			add_child(vp)
			var tr := TextureRect.new()
			tr.texture = vp.get_texture()
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var sm := ShaderMaterial.new()
			sm.shader = SUBVIEW
			tr.material = sm
			sub_layer.add_child(tr)
			sv = {"vp": vp, "cam": cam, "rect": tr, "seen": 0, "node": null}
			sub_views[panel] = sv
		# its frame in the cockpit (sent by the bridge: they move from one suit to another), less the name under the
		# squadmate's picture and the button bar under the probe's (measured on two cockpits; the target camera has
		# neither: cut the same, its bottom 17 rows showed the game's own picture); the probe's compass labels are let
		# through by the shader
		var x0 := q.decode_s16(o + 29)
		var y0 := q.decode_s16(o + 31)
		var x1 := q.decode_s16(o + 33)
		var y1 := q.decode_s16(o + 35)
		# (the 360 view's and the map panel's, 5 to 8: the whole frame, as the target camera's)
		var r := Rect2(x0, y0, x1 - x0, y1 - y0 - 16) if panel in [3, 4] else (Rect2(x0, y0 + 1, x1 - x0, y1 - y0 - 1)
				if panel != 1 else Rect2(x0, y0 + 1, x1 - x0, y1 - y0 - 17))
		var tr: TextureRect = sv["rect"]
		tr.position = r.position * k
		tr.size = r.size * k
		# rendered 1.2 x taller, then squeezed into the frame: the game's 3D library draws with a vertical scale of
		# 0.833 (its pixel ratio, as the main view): same width of view, more of it up and down
		var px := Vector2i(maxi(16, roundi(tr.size.x)), maxi(16, roundi(tr.size.y * 1.2)))
		if (sv["vp"] as SubViewport).size != px:
			(sv["vp"] as SubViewport).size = px
		(tr.material as ShaderMaterial).set_shader_parameter("ir", ir_on)
		(tr.material as ShaderMaterial).set_shader_parameter("hud", hud_tex)
		(tr.material as ShaderMaterial).set_shader_parameter("frame", Vector4(r.position.x, r.position.y, r.size.x, r.size.y))
		# the game's labels over its small view: the probe's compass (lavender, dark blue outline), the target camera's
		# name (red), and its red messages anywhere in the panel (an ID lock: "SENDING" under the name while the
		# game sends the target's identity, MISS8; drawn by the game in the same red, index 68, they were hidden)
		(tr.material as ShaderMaterial).set_shader_parameter("label_rows", 16.0 if panel in [3, 4] else (r.size.y if panel == 2 else 0.0))
		(tr.material as ShaderMaterial).set_shader_parameter("label_a", 47.0 if panel in [3, 4] else 68.0)
		(tr.material as ShaderMaterial).set_shader_parameter("label_b", 59.0 if panel in [3, 4] else 68.0)
		# the 360 view's panels are mirrors: what is on the player's left is on the left of the one behind him, and the
		# three read as one strip from his left shoulder round his back to his right one (the game turns each row of
		# their picture over once drawn: its panels' flag 0x40, set with these three views only)
		(tr.material as ShaderMaterial).set_shader_parameter("mirror", panel in [5, 6, 7])
		var old := oldschool_rect != null and oldschool_rect.visible    # F12: the side views follow the main view
		(tr.material as ShaderMaterial).set_shader_parameter("old", old)
		if old:
			(tr.material as ShaderMaterial).set_shader_parameter("pal_tex",
					(oldschool_rect.material as ShaderMaterial).get_shader_parameter("pal_tex"))
			(tr.material as ShaderMaterial).set_shader_parameter("first_index", pal_first)
			(tr.material as ShaderMaterial).set_shader_parameter("grid",
					tr.size if old_sharp <= 0 else (r.size * old_sharp).min(tr.size))   # (as the main view's, _old_grid)
		var idx := q.decode_s32(o + 1)
		var cam: Camera3D = sv["cam"]
		# the panel camera's zoom (the target camera: its distance to the target, 1 to 16), as the main view's
		var zoom: float = maxf(0.2, q.decode_float(o + 25))
		var field := SUB_FOV_PROBE if panel == 3 else (SUB_FOV_SELF if panel in [4, 8] else (SUB_FOV_AROUND if panel >= 5 else SUB_FOV))
		cam.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(field) / 2.0) / zoom))
		var h := q.decode_float(o + 17)
		var want_pos := Vector3(q.decode_float(o + 5), q.decode_float(o + 13), q.decode_float(o + 9))
		# the probe's pitch in the viewpoint (~11 deg down) is drawn much flatter by the game: a third of it puts the
		# ridge where the game has it (measured with an undamaged suit: damage scrambles the game's own views); the
		# squadmate's and the target camera's are drawn as given
		var tilt := q.decode_float(o + 21) * (PROBE_TILT if panel == 3 else 1.0)
		var want_rot := Vector3(tilt, atan2(-cos(h), -sin(h)), 0.0)
		# eased over a few readings: the target camera's angles change a few tenths of a degree from one to the next,
		# and through its zoom (up to 16 x: a field of a few degrees) the picture shook; a jump (another target, a
		# teleport) is taken at once
		var was_pos: Vector3 = sv.get("pos", want_pos)
		var was_rot: Vector3 = sv.get("rot", want_rot)
		if was_pos.distance_to(want_pos) < 1.0 and absf(angle_difference(was_rot.y, want_rot.y)) < 0.35:
			want_pos = was_pos.lerp(want_pos, SUB_EASE)
			want_rot = Vector3(lerp_angle(was_rot.x, want_rot.x, SUB_EASE), lerp_angle(was_rot.y, want_rot.y, SUB_EASE), 0.0)
		sv["pos"] = want_pos
		sv["rot"] = want_rot
		cam.position = want_pos
		cam.rotation = want_rot
		var node: Node3D = _live_node(idx)
		if node != sv["node"]:
			_sub_hide(sv["node"], false)
			_sub_hide(node, true)
			sv["node"] = node
		# from the player's own suit (the target camera): without its body, which the other side views show (walking,
		# its head and arms came in front of the lens: the picture went black)
		cam.cull_mask = 0xFFFFF & ~SUB_HIDE_LAYER & (~PLAYER_LAYER if node != null and node.has_meta("player_body") else 0xFFFFF)
		sv["seen"] = now
	for panel in sub_views:
		var sv: Dictionary = sub_views[panel]
		# kept half a second without news (the bridge catches their viewpoint when it can); the 360 view's, which it
		# sends every time while they are there: a tenth
		var on: bool = now - int(sv["seen"]) < (100 if panel in [5, 6, 7] else 500) and not menu_mode
		if on and int(sv["seen"]) != now:                # not in this packet: off at once if another one, which is, has
			for other in sub_views:                      # its place (a panel shows one view at a time)
				var so: Dictionary = sub_views[other]
				if int(so["seen"]) == now and (so["rect"] as TextureRect).get_rect().intersects((sv["rect"] as TextureRect).get_rect()):
					on = false
		(sv["rect"] as TextureRect).visible = on
		(sv["vp"] as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
		if not on and sv["node"] != null:
			_sub_hide(sv["node"], false)
			sv["node"] = null
	_map_cursor(sub_views.has(8) and (sub_views[8]["rect"] as TextureRect).visible)


# The game's full screen map (M, or its button under the cockpit's map): the map takes the HUD's view, which goes to a
# panel (8). It is used with the cursor (waypoints, the squad's orders): the mouse goes to the game's cursor by itself
# while it is shown, and back to looking around when it closes (only if it was taken for the map: a player already
# in the cursor mode stays in it).
var map_freed := false

func _map_cursor(on: bool) -> void:
	if not play or guest_win:
		return
	if on and not map_freed and play_started and not menu_mode and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_look_swap()
		map_freed = true
	elif not on and map_freed:
		map_freed = false
		if play_started and not menu_mode and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


# The objects' articulated parts (the dropship's door, turrets): after the joints, a count then for each object its
# game index and the two angle words the game draws it with (65536 = a full turn). Its mesh is rebuilt when they
# change, to 1/256 of a turn (the models are cached by pose).
func _live_arts(pk: PackedByteArray, at: int) -> void:
	var na := pk.decode_s32(at)
	for k in na:
		var o := at + 4 + 8 * k
		if o + 8 > pk.size():
			break
		var mi := _live_node(pk.decode_s32(o)) as MeshInstance3D
		if mi == null or not mi.has_meta("art_ref"):
			continue
		var pr := PackedByteArray()
		pr.resize(8)
		pr.encode_u16(0, pk.decode_u16(o + 4) & 0xFF00)
		pr.encode_u16(4, pk.decode_u16(o + 6) & 0xFF00)
		if mi.get_meta("art_pose", PackedByteArray()) == pr:
			continue
		mi.set_meta("art_pose", pr)
		var lp: Array = mi.get_meta("lamp", [])
		var lamp := TNObjects.lamp_state(lp[1], lp[2], live_alarm) if not lp.is_empty() else TNObjects.LAMP_NONE
		var md: Dictionary = objects.model(mi.get_meta("art_ref"), pal, pal_key, pr, lamp)
		if not md.is_empty():
			mi.mesh = md["mesh"]


# The alarm went on (it stays on until the next mission): the type-57 lamps light up, as the game's 0x29B4D0 sees it.
func _live_alarm(on: bool) -> void:
	if on == live_alarm:
		return
	live_alarm = on
	for n in get_tree().get_nodes_in_group("lamps"):
		var mi := n as MeshInstance3D
		var lp: Array = mi.get_meta("lamp")
		var md: Dictionary = objects.model(lp[0], pal, pal_key, mi.get_meta("art_pose", PackedByteArray()),
				TNObjects.lamp_state(lp[1], lp[2], on))
		if not md.is_empty():
			mi.mesh = md["mesh"]


# Smooth motion. The game moves the camera and the units once per frame of its own (often 25-40 a second) while
# Uplink draws up to a few hundred: shown as they come, they moved by jerks. Each new game state is reached in one
# game frame (its length measured), from where it was drawn: one game frame later, but without the steps. Jumps
# of more than SMOOTH_JUMP units (a teleport, a new mission) are not eased.
const SMOOTH_JUMP := 4.0
var smooth := OS.get_environment("TN_SMOOTH") == "1"   # off by default for now (tried by players: the view felt wrong)
var sm_int := 33.0                                   # ms between two game states (measured, eased)
var sm_last := 0                                     # when the camera last changed
var cam_from := [Vector3.ZERO, 0.0, 0.0]             # camera: where its easing started (position, yaw, pitch)
var cam_to := [Vector3.ZERO, 0.0, 0.0]               # ... and the game's newest state
var cam_t := -100000

func _cam_target(p: Vector3, y: float, pt: float) -> void:
	var to: Vector3 = cam_to[0]
	if p.is_equal_approx(to) and is_equal_approx(y, cam_to[1]) and is_equal_approx(pt, cam_to[2]):
		return
	var now := Time.get_ticks_msec()
	var gap := now - sm_last
	if gap > 4 and gap < 200:
		sm_int = lerpf(sm_int, float(gap), 0.1)
	sm_last = now
	cam_from = [camera.position, yaw, pitch] if smooth and p.distance_to(to) < SMOOTH_JUMP else [p, y, pt]
	cam_to = [p, y, pt]
	cam_t = now


func _live_smooth() -> void:
	var now := Time.get_ticks_msec()
	var a := clampf(float(now - cam_t) / sm_int, 0.0, 1.0)
	camera.position = (cam_from[0] as Vector3).lerp(cam_to[0], a)
	yaw = lerp_angle(cam_from[1], cam_to[1], a)
	pitch = lerpf(cam_from[2], cam_to[2], a)
	camera.rotation = Vector3(pitch + look_off.y, yaw + look_off.x, 0)
	for node in smooth_nodes:
		if is_instance_valid(node):
			_unit_smooth(node, now)


# The units, eased (on unless TN_UNIT_SMOOTH=0; the camera stays the game's, TN_SMOOTH): the game moves each one
# once per frame of its own (a suit it poses: once per picture the bridge reads between two, often fewer), Uplink
# draws many more; shown as they came, they moved by jerks. Each new state of a unit (its place, its turn, the game's
# pose of a suit, the walker's) is reached in the time its states come apart (measured per unit, UNIT_GAP), from
# where it is drawn: a little behind, without the steps. A suit's place and pose come from the same picture of the
# game (the bridge): eased together, its planted feet stay put. Jumps of more than SMOOTH_JUMP are taken at once.
var unit_smooth := OS.get_environment("TN_UNIT_SMOOTH") != "0"
const UNIT_GAP := Vector2(8.0, 90.0)              # ms: the shortest and longest easing
var smooth_nodes: Array[Node3D] = []
var sm_n := 0                                     # the units' captures so far (one a packet)

# after the units are placed (their game positions): each one eased from where it is drawn to there
func _smooth_capture() -> void:
	var now := Time.get_ticks_msec()
	smooth_nodes.clear()
	if not (smooth or unit_smooth):
		return
	sm_n += 1
	for idx in live_ents:
		var cls: int = live_ents[idx][0]
		if cls < 1 or cls > 4:
			continue
		var node := _live_node(idx)
		if node == null or not is_instance_valid(node) or not node.visible or node.has_meta("corpse") \
				or node.has_meta("player_body"):
			continue                                     # (the view's own body: with the camera, the game's)
		var gait := node.has_meta("gait")
		var to := [node.position, node.quaternion, null, float(node.get_meta("ez", node.position.y))]
		if node.has_meta("soldier") and not gait and node.has_meta("pose_last") and not node.get_meta("own", false):
			to[2] = node.get_meta("pose_last")
		elif node.has_meta("mech") and node.has_meta("mech_pose"):
			to[2] = node.get_meta("mech_pose")
		var sm: Array = node.get_meta("sm", [])
		if sm.is_empty() or int(node.get_meta("sm_n", -1)) != sm_n - 1 or (to[0] as Vector3).distance_to(sm[1][0]) >= SMOOTH_JUMP:
			sm = [to, to, now, float(node.get_meta("sm_gap", 33.0)), gait, now]    # new, shown again, jumped: at once
		elif not ((to[0] as Vector3).is_equal_approx(sm[1][0]) and (to[1] as Quaternion).is_equal_approx(sm[1][1])
				and to[2] == sm[1][2] and is_equal_approx(to[3], sm[1][3])):
			var gap := float(node.get_meta("sm_gap", 33.0))
			var dt := float(now - int(sm[5]))           # since its last new state
			if dt > 0.0 and dt < 200.0:
				gap = lerpf(gap, clampf(dt, UNIT_GAP.x, UNIT_GAP.y), 0.25)
				node.set_meta("sm_gap", gap)
			var from := _unit_drawn(sm, now)
			if bool(sm[4]) and not gait:              # back on the game's pose from its own steps: its height eased
				from = from.duplicate()                  # apart, over the pose's cross-fade (_y_ease)
				var p0: Vector3 = from[0]
				p0.y = (to[0] as Vector3).y
				from[0] = p0
				node.set_meta("y_off", [float(node.get_meta("gait_y", (to[0] as Vector3).y)) - (to[0] as Vector3).y, now])
			sm = [from, to, now, gap, gait, now]
		node.set_meta("sm", sm)
		node.set_meta("sm_n", sm_n)
		smooth_nodes.append(node)
	_live_smooth()                                   # drawn eased from this frame on


# a suit's height between the game's pose and its own steps (each puts its feet a little differently): the step
# between the two eased away over POSE_FADE
func _y_ease(node: Node3D, now: int) -> float:
	if not node.has_meta("y_off"):
		return 0.0
	var yo: Array = node.get_meta("y_off")
	var k := (now - int(yo[1])) / POSE_FADE
	if k >= 1.0 or absf(float(yo[0])) > 1.0:
		node.remove_meta("y_off")
		return 0.0
	return float(yo[0]) * (1.0 - k * k * (3.0 - 2.0 * k))


# where a unit is drawn now: [position, turn, pose or null, height of its entity], from sm's two states
func _unit_drawn(sm: Array, now: int) -> Array:
	var a := clampf(float(now - int(sm[2])) / float(sm[3]), 0.0, 1.0)
	var f: Array = sm[0]
	var t: Array = sm[1]
	if a >= 1.0:
		return t
	var q = null
	if t[2] != null and f[2] != null and (t[2] as Array).size() == (f[2] as Array).size():
		q = []
		for j in (t[2] as Array).size():
			q.append((f[2][j] as Vector3).lerp(t[2][j], a))
	elif t[2] != null:
		q = t[2]
	return [(f[0] as Vector3).lerp(t[0], a), (f[1] as Quaternion).slerp(t[1], a), q, lerpf(f[3], t[3], a)]


func _unit_smooth(node: Node3D, now: int) -> void:
	var sm: Array = node.get_meta("sm")
	var gait := node.has_meta("gait")
	if int(node.get_meta("sm_done", -1)) == int(sm[2]) and (gait or not node.has_meta("y_off")):
		return                                       # (reached: left where it is, a suit's own steps move it)
	var d := _unit_drawn(sm, now)
	if now - int(sm[2]) >= int(sm[3]):
		node.set_meta("sm_done", int(sm[2]))
	var p: Vector3 = d[0]
	if gait:
		p.y = node.position.y                        # (a suit on its own steps: its height from the ground, _gait)
		node.set_meta("ez_s", d[3])
	else:
		p.y += _y_ease(node, now)
	node.position = p
	node.quaternion = d[1]
	if d[2] != null:
		if node.has_meta("mech"):
			_pose_mech(node, d[2])
		else:
			_pose_soldier(node, d[2])


func _live_node(idx: int) -> Node3D:
	if live_extra.has(idx):
		return live_extra[idx]
	if live_off >= 0 and idx - live_off >= 0 and idx - live_off < live_nodes.size():
		return live_nodes[idx - live_off]
	return null


func _sub_hide(node: Node3D, hide: bool, layer: int = SUB_HIDE_LAYER) -> void:
	if node == null or not is_instance_valid(node) or (node.has_meta("player_body") and layer != PLAYER_LAYER):
		return
	if layer == PLAYER_LAYER:
		node.set_meta("player_body", true)
	var stack: Array = [node]
	while not stack.is_empty():
		var nd = stack.pop_back()
		if nd.has_meta("shadow_twin"):
			continue
		if nd is VisualInstance3D:
			(nd as VisualInstance3D).layers = layer if hide else 1
			if layer == PLAYER_LAYER and hide and nd is MeshInstance3D and not nd.has_meta("twinned"):
				_shadow_twin(nd)
		stack.append_array(nd.get_children())


# The player's body is on a layer the main camera does not draw, and Godot only casts the shadows of what the camera
# draws: each of its pieces gets a twin on the main layer that only casts the shadow (a child: it follows the piece).
func _shadow_twin(mi: MeshInstance3D) -> void:
	mi.set_meta("twinned", true)
	if mi.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		return
	var tw := MeshInstance3D.new()
	tw.set_meta("shadow_twin", true)
	tw.mesh = mi.mesh
	tw.material_override = mi.material_override
	tw.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	tw.extra_cull_margin = mi.extra_cull_margin
	mi.add_child(tw)


# The same environment without its fog, for the cameras high above the map (the coop's maps): the live view's depth
# fog begins 35 units away
var env_nofog_cache: Environment


func env_nofog() -> Environment:
	if env_nofog_cache == null:
		env_nofog_cache = env.duplicate()
		env_nofog_cache.fog_enabled = false
	return env_nofog_cache


# A burst suit (6/33): one entity, drawn by the game as a pile of the suit's armour pieces (its limb sprites: torso,
# thighs, shins, arms, feet) lying flat every which way around it, ~0.6 unit across (seen on the running game).
# The entity is thrown up when the soldier dies and bounces to rest (its height: the whole pile follows it). Where
# each piece lies is not decoded: spread from the entity's number. The suit is the game's own, from its burst record
# (the bridge puts it in the heading; -1, not known: the nearest death seen here).
const PILE_RADIUS := 0.3                      # (measured: a compact pile, ~0.5 unit across)
const PILE_SHADE := 0.8                       # lighter than the standing suits (their light grey, on the game)
const PILE_SCALE := 0.0027                    # world units per sprite pixel (measured: smaller than standing suits')


func _live_debris(idx: int, e) -> void:
	var holder: Node3D = live_piles.get(idx)
	var game_suit := int(round(e[6]))
	# the armour the bridge names comes and goes (the dead soldier's record found or not as the entities near the
	# player change: the pile was rebuilt as the default suit, the player's own): a pile keeps the first one named, and
	# one built without (guessed) takes it when it comes; a slot taken by a pile elsewhere starts again
	if holder != null and Vector2(holder.position.x, holder.position.z).distance_to(Vector2(e[3], e[4])) < 1.5:
		var had := int(holder.get_meta("suit_src", -1))
		if had >= 0 or game_suit < 0:
			game_suit = had
	var key := "pile%d" % game_suit
	var m: Dictionary = current["map"]
	if holder == null or holder.get_meta("kind", "") != key:
		if holder != null:
			holder.queue_free()
		var suit := game_suit if game_suit >= 0 and game_suit < TNObjects.MECH_SUIT else 1
		var best := 4.0 if game_suit < 0 else 0.0
		for d in dead_suits:
			var dd: float = Vector2(d[0].x, d[0].z).distance_to(Vector2(e[3], e[4]))
			if dd < best:
				best = dd
				suit = d[1]
		holder = Node3D.new()
		holder.set_meta("kind", key)
		holder.set_meta("suit_src", game_suit)
		world.add_child(holder)
		live_piles[idx] = holder
		var g0 := TNData.height_at(m, e[3], e[4])
		var segs: Array = objects.skeleton(suit) if objects_ok else []
		var k := 0
		for sg in segs:
			var part: int = sg[2]
			var ld: Dictionary = objects.limb(suit, part, pal, pal_key)
			if ld.is_empty():
				continue
			var h1 := float(((idx + 1) * 2654435761 + k * 40503) % 100000) / 100000.0
			var h2 := float(((idx + 7) * 1103515245 + k * 12345) % 100000) / 100000.0
			var h3 := float(((idx + 3) * 69069 + k * 2891336453) % 100000) / 100000.0
			k += 1
			if part != 5 and fmod(h1 * 13.7 + h2 * 5.3, 1.0) > 0.62:
				continue                                     # ~7 pieces, like the game's piles
			var r := PILE_RADIUS * (0.2 + 0.8 * sqrt(h1)) * (0.5 if part == 5 else 1.0)    # the torso nearer the middle
			var a := TAU * h2
			var off := Vector3(r * cos(a), 0.0, r * sin(a))
			var yaw := TAU * h3
			var dir := Vector3(cos(yaw), 0.0, sin(yaw))                   # the piece's bone, lying flat
			var half: float = float(ld["len"]) * PILE_SCALE * 0.5
			var ground := TNData.height_at(m, e[3] + off.x, e[4] + off.z) - g0
			var seg := MeshInstance3D.new()
			seg.mesh = _limb_quad(ld)
			seg.material_override = _limb_mat(suit, part, ld, PILE_SHADE)
			seg.extra_cull_margin = 1.0
			# Y = the bone (lying), X = its front (up: seen from above), from joint a: the piece centred on its spot
			seg.transform = Transform3D(Basis(Vector3.UP * PILE_SCALE, dir * PILE_SCALE, Vector3.UP.cross(dir) * PILE_SCALE),
					off - dir * half + Vector3(0.0, ground + 0.03, 0.0))
			# lying: across the screen, tilted up to ~45 deg either way
			var tilt := (fmod(h1 * 7.31 + h3 * 3.17, 1.0) - 0.5) * 1.6
			var spin0 := (PI * 0.5 if h2 < 0.5 else PI * 1.5) + tilt
			seg.set_instance_shader_parameter("spin", spin0)
			seg.set_meta("rest", seg.position)
			seg.set_meta("spin0", spin0)
			seg.set_meta("fly", Vector3(off.x * 0.5, 0.05 + 0.2 * h3, off.z * 0.5))   # its own flight off the pile
			seg.set_meta("turn", (h1 - 0.5) * 14.0)                               # radians per second, in the air
			holder.add_child(seg)
	# the pile follows its entity: thrown up, then at rest on the ground. In the air (seen on the running game) its
	# pieces fly apart, higher and wider, turning, and fall back together onto the pile. In the air: while its height
	# changes (at rest the game's ground and this one can differ by a few hundredths: a pile left that much above it
	# was taken for flying, its pieces turned for ever)
	var gc := TNData.height_at(m, e[3], e[4])
	var t := Time.get_ticks_msec() / 1000.0
	if absf(float(e[5]) - float(holder.get_meta("z", e[5]))) > 0.003:
		holder.set_meta("z_t", t)
	holder.set_meta("z", e[5])
	var flying: bool = t - float(holder.get_meta("z_t", -10.0)) < 0.3
	var lift := maxf(0.0, e[5] - GAME_Z - gc + 0.12) if flying else 0.0
	holder.position = Vector3(e[3], gc + lift, e[4])
	var k2 := clampf(lift / 0.3, 0.0, 1.0)
	for seg in holder.get_children():
		if not seg.has_meta("rest"):
			continue
		var rest: Vector3 = seg.get_meta("rest")
		var fly: Vector3 = seg.get_meta("fly")
		seg.position = rest + fly * k2
		var spin: float = seg.get_meta("spin0")
		if k2 > 0.02:                                   # turning while in the air, keeping its last angle on landing
			spin += float(seg.get_meta("turn")) * (t - float(seg.get_meta("t", t)))
			seg.set_meta("spin0", spin)
		seg.set_meta("t", t)
		(seg as MeshInstance3D).set_instance_shader_parameter("spin", fposmod(spin, TAU))
	holder.visible = true


# A dead soldier: the game does not keep a body, the suit bursts into pieces lying around (type 6/33, see
# _live_debris). The soldier is hidden; where it fell and its suit are kept, for the pieces.
func _make_corpse(node: Node3D, m: Dictionary) -> void:
	node.visible = false
	if node.has_meta("corpse"):
		return
	node.set_meta("corpse", true)
	if node.has_meta("suit"):
		dead_suits.append([node.position, int(node.get_meta("suit"))])


# The game's vegetation map, as it is now: a tree or bush hit empties its whole 4 x 4 cell (measured: shot tree ->
# its cell's value 3 -> 0), its plants become decor entities (drawn as such). The plants of a cell emptied in the
# game are hidden here.
func _live_vegetation(game_map: PackedByteArray) -> void:
	if veg_values.size() != game_map.size():
		return
	for i in game_map.size():
		if game_map[i] == veg_values[i]:
			continue
		veg_values[i] = game_map[i]
		for it in veg_cells.get(i, []):                 # emptied: hidden; filled again (mission restarted): back
			var mm: MultiMesh = it[0]
			var t0: Transform3D = it[2]
			mm.set_instance_transform(it[1], t0 if game_map[i] != 0 else Transform3D(Basis.IDENTITY.scaled(Vector3.ZERO), t0.origin))


# Burnt ground: the game sets bit 0x40 of a vertex's tile where a tree was destroyed or a blast hit (its ground map
# in memory, read by the bridge) and stamps one of its four burn pictures (RESTNOBJ 1164, pictures 1 to 4: black and
# brown, ragged) over the whole ground square of the burnt point (its routine 0x2AC650), lit and hazed with the ground.
# Drawn so here, by the ground's shader (burn_map: one texel per point, 1 + its picture; burn_idx: the pictures' palette
# indices), through the same light and haze rows as the tiles. (They were decals: on a ground drawn in its own colours
# (emission) they no longer showed, and they painted their brown and orange on whatever stood on them, a stump, a
# soldier, a corpse.) Packet: count, then vertex indices (y * 513 + x, game y = Godot z).
var burn_img: Image
var burn_tex: ImageTexture
var burn_pics: Texture2DArray


func _burn_pictures() -> Texture2DArray:
	if burn_pics != null or not objects_ok:
		return burn_pics
	var imgs: Array[Image] = []
	for k in 4:
		var im: Image = objects.sprite_idx(Vector2i(1164, 1 + k))
		if im == null:
			return null
		im.resize(64, 64, Image.INTERPOLATE_NEAREST)
		imgs.append(im)
	burn_pics = Texture2DArray.new()
	burn_pics.create_from_images(imgs)
	return burn_pics


func _live_scorch(pk: PackedByteArray) -> void:
	if current.is_empty() or pk == scorch_prev:
		return
	scorch_prev = pk
	var pics := _burn_pictures()
	if pics == null:
		return
	if burn_img == null:
		burn_img = Image.create(513, 513, false, Image.FORMAT_R8)
	burn_img.fill(Color(0, 0, 0))
	var n := mini(pk.decode_u32(0), (pk.size() - 4) / 4)
	for k in n:
		var v := pk.decode_u32(4 + 4 * k)
		if v < 513 * 513:
			burn_img.set_pixel(v % 513, v / 513, Color8(1 + v % 4, 0, 0))
	if burn_tex == null:
		burn_tex = ImageTexture.create_from_image(burn_img)
	else:
		burn_tex.update(burn_img)
	var fp: PackedColorArray = (current["map"]["planet_data"] as Dictionary).get("palette", PackedColorArray())
	for sm in ground_mats:
		if (sm as ShaderMaterial).shader != GROUND or float((sm as ShaderMaterial).get_shader_parameter("grid_n")) != 513.0:
			continue                                    # (the detailed map only: the outer grid's points are 4 apart)
		if (sm as ShaderMaterial).get_shader_parameter("burn_pal") == null and fp.size() >= 256:
			var pimg := Image.create(256, 1, false, Image.FORMAT_RGB8)
			for i in 256:
				pimg.set_pixel(i, 0, fp[i])
			(sm as ShaderMaterial).set_shader_parameter("burn_pal", ImageTexture.create_from_image(pimg))
		(sm as ShaderMaterial).set_shader_parameter("burn_map", burn_tex)
		(sm as ShaderMaterial).set_shader_parameter("burn_idx", pics)
		(sm as ShaderMaterial).set_shader_parameter("has_burn", n > 0)


# Shots (class 5) and their effects (class 6), which the game keeps a fraction of a second in its entity table, at
# their real position (no ground snapping). The laser (5/4) is a bolt flying ~55 u/s straight at the crosshair from
# 1 unit in front of the eye; the game draws it as a red beam from the gun to the bolt. For the player's own shots
# the gun is beside the head, on the side the bolt starts (left for weapons 1-2, right for 3-4); for the others it
# is where the bolt was first seen. Types 28 / 29 are the beam's trail, barely visible in the game (drawn, they were
# a cloud of orange balls); the other class 6 types are the impacts' sparks.
const MUZZLE := Vector3(0.417, -0.089, -0.3)   # camera space, x to the side of the hand that fired (fitted on the game's beam)
const MUZZLE_W := 0.0167                       # half width of the player's beam at the gun and at the bolt (world units)
const BOLT_W := 0.0053
const DUST_DOTS := 20                          # dots drawn for each dust particle, scattered DUST_SPREAD across and
const DUST_SPREAD := 0.04                      # DUST_DROP up and down, most near the middle (radians from the camera:
const DUST_DROP := 0.024                       # measured on the game's HD picture, a laser's impact on the ground is ~100
                                               # dark red pixels in a 40 x 25 pixel cloud from its 8 particles 6/29)
const DUST_PX := 0.0019                        # dust radius per unit of distance: ~2 pixels of the game's HD picture
const DUST_HALO := 0.3                         # share of the dots in the sparse halo, 3 times as wide (its picture)
const SPARK_DOTS := 6                          # the impact's spark (6/8): a few salmon pixels in the cloud's middle
const STREAK := 1.5                            # length of a laser bolt in flight
const FLASH_MS := 25                           # the beam from the gun, as the bolt leaves (the game: 1 frame)
func _live_fx(idx: int, e) -> void:
	var cls: int = e[0]
	var typ: int = e[1]
	var pos0 := Vector3(e[3], e[5] - GAME_Z, e[4])
	if cls == 6 and typ == 29 and smoke_clouds.has(idx):
		return                                          # a smoke grenade's cloud: drawn by _live_smoke
	if cls == 6 and typ == 29 and fx29.get(idx, 7) == 8:
		return                                          # the same smoke from a blown-up tree: its column is drawn
	if cls == 6 and typ == 29 and fx29.get(idx, 7) == 9:
		if fx29.get(-1, 0) == 9:
			return                                      # a jetpack's trail: the game's own particles (_live_parts)
		if puff_seen.get(idx, -10) != live_seen - 1:
			_spawn_puff(pos0, 1.0, 0.0, Vector3.ZERO, 1.0, 1.0, true)   # (an older bridge: a puff, not a shot's red dust)
		puff_seen[idx] = live_seen
		return
	# (an older bridge, which does not say what a 6/29 is: one at the player's feet is taken for his jetpack's smoke.
	# With the particles' kinds known this took the dust that settles at his feet, and a trail's first picture, for
	# his jetpack: puffs born against the camera, a grey veil over the view as soon as he stepped back)
	if cls == 6 and typ == 29 and not part_mode and _live_puff(idx, pos0, e):
		return
	if cls == 6 and typ == 29 and part_mode:
		return                                          # a shot's dust: its own particles (_live_parts)
	if cls == 6 and typ == 33:
		_live_debris(idx, e)
		return
	if cls == 6 and typ == 32:
		if shards.has(idx):
			_live_shard(idx, e, shards[idx])            # a piece of a blown-up building
		elif live_fx.has(idx):
			live_fx[idx].visible = false
		return                                          # (never the default orange ball: the yellow circles of #12)
	if cls == 6 and typ == 31 and bolt_mode:
		return                                          # the SIR's lightning: its own lines (_live_bolts)
	if cls == 5 and typ != 10 and beam_mode:
		if SHOT_BALLS.has(typ):
			_live_ball(idx, e)                          # the game's one sprite for these shots
		return                                          # (the others: only what they leave behind them)
	if cls == 5 and typ == 5:
		_live_pulsar(idx, e)
		return
	if cls == 6 and typ == 28 and beam_mode:
		if beams.has(idx):
			_live_beam(idx, beams[idx])                 # the game's own line, from its two ends
		return
	if cls == 6 and typ == 28 and pulsar_dust.has(idx):
		return                                          # a pulsar bolt's trail: drawn with its bolt
	if cls == 6 and _fx_anim(typ):
		_live_anim(idx, typ, Vector3(e[3], e[5], e[4]))
		return
	# kinds: 0 other shot, 1 red beam (laser 5/4), 2 orange spark, 3 red dust (6/29), 4 blue beam (5/11),
	# 5 blue dust (6/28), 6 missile (5/10), 7 red particle shot (5/6), 8 green plasma (5/22 the enemies' slow
	# green streak ~0.35 unit long along its flight, in the planet palette's green; 5/25 its spray), 9 tracer
	# (5/23 machine gun bullet, and 6/7 its fading streak: a thin white line ~0.25 unit long along its flight),
	# 12 grenade (5/2, smoke or blast: thrown in an arc, 0.7-2 s and 3-8 units; was not drawn, only its smoke seen:
	# drawn as the weapon panel shows it, _grenade_mesh, along its flight),
	# matched on the running game
	var kind: int = 0
	if cls == 5:
		kind = {4: 1, 11: 4, 10: 6, 6: 7, 22: 8, 25: 8, 23: 9, 2: 12}.get(typ, 0)
		if kind == 0:
			return                                      # other shots (5/24, 5/26, 5/27 on the hover tanks, 5/29...):
			# nothing the game draws, at most a dot (a 0.8 unit glowing ball hid the walkers in a fight)
		if beam_mode and (kind == 1 or kind == 4):
			return                                      # its beam is the game's own line (6/28, _live_beam)
	else:
		kind = {29: 3, 28: 5, 7: 9, 5: 10, 8: 11}.get(typ, 2)
	var beam := kind == 1 or kind == 4
	var dust := kind == 3 or kind == 5 or kind == 11
	var mi: MeshInstance3D = live_fx.get(idx)
	if mi == null:
		mi = MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		world.add_child(mi)
		live_fx[idx] = mi
	if mi.get_meta("kind", -1) != kind:
		mi.transform = Transform3D.IDENTITY             # the slot may have held a stretched beam
		if beam:
			mi.mesh = ImmediateMesh.new()               # a ribbon rebuilt every frame from the gun to the bolt
		elif dust:
			mi.mesh = ImmediateMesh.new()               # dust: its scattered dots, rebuilt every frame
		elif kind == 12:
			mi.mesh = _grenade_mesh()                   # its own colours (the material below left off)
		elif kind == 6:
			# the missile: the game's own model (RESTNOBJ 1343 item 1, a dart 0.12 long and 0.014 thick; the only
			# shot it draws as a model: its routine 0x29ACA8). Before: a cone 0.32 long and 0.09 thick
			var md: Dictionary = objects.model(Vector2i(1343, 1), pal, pal_key) if objects_ok else {}
			mi.set_meta("model", not md.is_empty())
			if not md.is_empty():
				mi.mesh = md["mesh"]
			else:
				var cn := CylinderMesh.new()            # (no such model in the files: a little cone, nose ahead)
				cn.top_radius = 0.0
				cn.bottom_radius = 0.007
				cn.height = 0.12
				cn.radial_segments = 6
				cn.rings = 1
				mi.mesh = cn
		else:
			var sp := SphereMesh.new()
			sp.radius = {0: 0.2, 2: 0.05, 3: 0.014, 5: 0.014, 7: 0.02, 8: 0.045, 9: 0.008, 10: 0.02, 12: 0.05}[kind]
			sp.height = sp.radius * {0: 4.0, 8: 8.0, 9: 32.0}.get(kind, 2.0)
			sp.radial_segments = 4 if kind == 3 or kind == 5 else 8
			sp.rings = 2 if kind == 3 or kind == 5 else 4
			mi.mesh = sp
		if beam and not fx_mats.has(kind):
			var bm := ShaderMaterial.new()
			bm.shader = BEAM
			if kind == 4:                               # the ion rifle's blue beam
				bm.set_shader_parameter("core", Color(0.45, 0.6, 1.0))
				bm.set_shader_parameter("edge", Color(0.06, 0.12, 0.45))
			fx_mats[kind] = bm
		if not fx_mats.has(kind):
			var m := StandardMaterial3D.new()
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			var green := pal[137] if pal.size() > 137 else Color(0.1, 0.8, 0.1)
			m.albedo_color = [Color(1.0, 0.85, 0.6), Color(1.0, 0.12, 0.08), Color(1.0, 0.75, 0.3), Color(1.0, 0.25, 0.15),
					Color(0.15, 0.3, 1.0), Color(0.3, 0.45, 1.0), Color(1.0, 0.72, 0.15), Color(1.0, 0.2, 0.12), green,
					Color(1.0, 0.97, 0.85), Color(0.99, 0.25, 0.25), Color(0.93, 0.6, 0.5), Color(0.2, 0.22, 0.18)][kind]
			m.emission_enabled = kind != 12                 # (the grenade: a dark casing, no glow)
			m.emission = m.albedo_color
			m.emission_energy_multiplier = [4.0, 3.5, 2.5, 3.0, 3.0, 3.0, 2.0, 3.0, 1.3, 2.0, 1.0, 1.0, 0.0][kind]
			if dust:                                    # dust: plain dots of the game's red / blue / salmon, no glow
				m.emission_enabled = false
				m.albedo_color = {3: Color(0.62, 0.0, 0.0), 5: Color(0.3, 0.42, 0.95)}.get(kind, m.albedo_color)
				m.cull_mode = BaseMaterial3D.CULL_DISABLED  # (its dots are quads facing the camera)
			m.disable_fog = true
			fx_mats[kind] = m
		mi.material_override = null if kind == 12 or (kind == 6 and mi.get_meta("model", false)) else fx_mats[kind]
		mi.set_meta("kind", kind)
	# shots, dust and sparks at their true height (the camera is the player's height + the eye's, like the game's
	# view): the units' offset (GAME_Z, their feet below their entity) put a laser's dust trail below its path, a
	# second laser going askew from under the crosshair
	var pos := Vector3(e[3], e[5], e[4])
	var fresh: bool = mi.get_meta("seen", -10) != live_seen - 1    # a new shot in this slot
	mi.set_meta("seen", live_seen)
	if beam:
		var cam := camera.global_transform
		# a new bolt: a new slot, or this one taken again by the next bolt (it jumps back towards the gun)
		var near := pos.distance_to(cam.origin)
		if fresh or not mi.has_meta("tail") or near < float(mi.get_meta("near", 0.0)) - 1.0:
			var rel := cam.affine_inverse() * pos       # where the bolt starts, in camera space
			mi.set_meta("mine", rel.length() < 2.5)
			mi.set_meta("side", -1.0 if rel.x < 0.0 else 1.0)
			mi.set_meta("tail", pos)
			mi.set_meta("born", Time.get_ticks_msec())
		mi.set_meta("near", near)
		# the player's own bolt: like the game, one beam from the gun to the bolt for a single game frame as it
		# leaves, then nothing (the bolt flies unseen to its impact; a held trigger fires every 0.125 s and the
		# streak drawn after the flash made two lasers in the air). Others' bolts: a short streak flying on
		var tail: Vector3 = mi.get_meta("tail")
		var w_tail := 0.004
		var w_bolt := 0.004
		if mi.get_meta("mine"):
			if Time.get_ticks_msec() - int(mi.get_meta("born")) >= FLASH_MS:
				mi.visible = false
				return
			tail = cam * Vector3(MUZZLE.x * float(mi.get_meta("side")), MUZZLE.y, MUZZLE.z)
			w_tail = MUZZLE_W                           # (fitted on the game's beam: 34 pixels wide at the edge of
			w_bolt = BOLT_W                             # the view, 4 at the bolt, a straight taper)
		elif pos.distance_to(tail) > STREAK:
			tail = pos + (tail - pos).normalized() * STREAK
		var seg := pos - tail
		if seg.length() < 0.05:
			mi.visible = false
			return
		# a ribbon facing the camera, as wide as the game's at both ends
		var across := seg.cross(cam.origin - (tail + pos) * 0.5).normalized()
		var im := mi.mesh as ImmediateMesh
		im.clear_surfaces()
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, fx_mats[kind])
		var corners := [[tail - across * w_tail, 0.0], [tail + across * w_tail, 1.0], [pos + across * w_bolt, 1.0],
				[tail - across * w_tail, 0.0], [pos + across * w_bolt, 1.0], [pos - across * w_bolt, 0.0]]
		for c in corners:
			im.surface_set_uv(Vector2(0.0, c[1]))
			im.surface_add_vertex(c[0])
		im.surface_end()
		mi.global_transform = Transform3D.IDENTITY
		mi.extra_cull_margin = 4.0
		mi.visible = true
		return
	if pos.distance_to(camera.position) < (0.3 if dust else 0.05 if kind == 6 and part_mode else 1.5):   # at the gun: inside the cockpit
		mi.visible = false
		return
	if kind == 6 and not part_mode:
		_spawn_puff(pos, 1.4, 0.0, Vector3.ZERO, 1.0, 1.0, true)   # missile: its thick grey smoke trail (the game's own: _live_parts)
	if dust:
		if mi.get_meta("dust_pos", Vector3.INF) != pos:   # a new particle (they do not move): drawn by _dust_update
			mi.set_meta("dust_pos", pos)
			mi.set_meta("dust_born", Time.get_ticks_msec())
		mi.global_transform = Transform3D.IDENTITY
		mi.extra_cull_margin = 2.0
	elif kind == 2 or kind == 7 or kind == 10:
		mi.transform = Transform3D(Basis.IDENTITY, pos)
	elif kind == 6:
		# the missile as the game draws it (0x29b3ac): its heading (+0x1B, set once at launch along its horizontal
		# velocity), level for its whole flight (+0x1D stays 0, no roll), from its first frame on
		var yawed := Basis(Vector3.UP, -float(e[6]))
		mi.transform = Transform3D(yawed if mi.get_meta("model", false) else yawed * Basis(Vector3(0, 0, 1), -PI / 2), pos)
	else:                                           # other shots: a bolt along its flight
		var dir := Vector3.ZERO
		if not fresh:
			var prev: Vector3 = mi.get_meta("prev", pos)
			if prev.distance_to(pos) > 0.01 and prev.distance_to(pos) < 20.0:
				dir = (pos - prev).normalized()
		if dir == Vector3.ZERO:
			dir = -camera.global_transform.basis.z
		mi.look_at_from_position(pos, pos + dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
		mi.rotate_object_local(Vector3.RIGHT, PI / 2)   # long axis along the flight
	mi.set_meta("prev", pos)
	mi.visible = true


# The grenade (5/2) as the game's weapon panel shows it: a whitish grey capsule girded with a green band (its long
# axis Y: set along the flight like the other shots)
var grenade_mesh: ArrayMesh


func _grenade_mesh() -> ArrayMesh:
	if grenade_mesh != null:
		return grenade_mesh
	var body := CapsuleMesh.new()
	body.radius = 0.04
	body.height = 0.13
	body.radial_segments = 12
	body.rings = 4
	var band := TorusMesh.new()
	band.inner_radius = 0.036
	band.outer_radius = 0.05
	band.rings = 16
	band.ring_segments = 6
	grenade_mesh = ArrayMesh.new()
	for part in [[body, Color(0.82, 0.83, 0.8)], [band, Color(0.15, 0.62, 0.2)]]:
		grenade_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, (part[0] as PrimitiveMesh).get_mesh_arrays())
		var m := StandardMaterial3D.new()
		m.albedo_color = part[1]
		m.roughness = 0.6
		grenade_mesh.surface_set_material(grenade_mesh.get_surface_count() - 1, m)
	return grenade_mesh


# Dust (6/29, 6/28) and sparks (6/8), every frame. The game draws a dust particle (it does not move) as dots of a
# pixel scattered around it, mostly below, drawn again elsewhere when it draws a new random number: near the camera
# they spread over the view's lower left, far away they make a dense cloud at the impact (measured on the game's
# picture; dots right on the particles made a thin second laser along the shot). Scattered again at the game's own
# rate (~30 a second) they moved by jerks next to the view, and kept as long as the game keeps the particle they stayed
# on screen well after a short shot: scattered DUST_HZ times a second here, fewer and fewer over DUST_LIFE seconds.
const DUST_HZ := 60.0
const DUST_LIFE := 0.3


func _dust_update() -> void:
	var now := Time.get_ticks_msec()
	var tick := int(now * DUST_HZ / 1000.0)
	var cb := camera.global_transform.basis
	for idx in live_fx:
		var any = live_fx[idx]
		if not is_instance_valid(any):
			continue
		var mi: MeshInstance3D = any
		if mi == null or not mi.visible or not mi.has_meta("dust_pos"):
			continue
		var kind: int = mi.get_meta("kind", -1)
		if not (kind == 3 or kind == 5 or kind == 11) or not mi.mesh is ImmediateMesh:
			continue
		var left := 1.0 - (now - int(mi.get_meta("dust_born"))) / 1000.0 / DUST_LIFE
		if left <= 0.0:
			mi.visible = false                       # (shown again by its next update: hidden again here)
			continue
		var pos: Vector3 = mi.get_meta("dust_pos")
		var d := pos.distance_to(camera.position)
		var hs := d * DUST_PX
		var im := mi.mesh as ImmediateMesh
		im.clear_surfaces()
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, fx_mats[kind])
		var tight := 0.35 if kind == 11 else 1.0        # the spark: its few pixels in the middle
		for j in ceili({11: SPARK_DOTS, 5: 3}.get(kind, DUST_DOTS) * left):   # (the ion beam's blue trail: barely seen)
			var r1 := float(((idx + 1) * 2654435761 + tick * 40503 + j * 7919) % 100000) / 100000.0
			var r2 := float(((idx + 3) * 1103515245 + tick * 12345 + j * 104729) % 100000) / 100000.0
			var r3 := float(((idx + 7) * 69069 + tick * 2891 + j * 31337) % 100000) / 100000.0
			# (a spread of a few pixels of the game whatever the distance: wider than tall, a little below)
			var c := pos + (cb.x * (r1 - 0.5) * 2.0 * DUST_SPREAD + cb.y * ((r2 - 0.55) * 2.0 * DUST_DROP)) * d * (0.25 + 0.75 * r3) * tight * (3.0 if kind == 3 and j % 10 < int(DUST_HALO * 10) else 1.0)
			var q := [c - cb.x * hs - cb.y * hs, c + cb.x * hs - cb.y * hs, c + cb.x * hs + cb.y * hs,
					c - cb.x * hs - cb.y * hs, c + cb.x * hs + cb.y * hs, c - cb.x * hs + cb.y * hs]
			for v in q:
				im.surface_add_vertex(v)
		im.surface_end()


# A shot in flight (class 5). The game has one sprite for all of them (RESTNOBJ 1164 picture 0: a grey ball with four
# yellow studs, 10 x 9 pixels, 0x1555 wide in its 16.16 units: 0.05 unit on its screen, a dot beyond a few units) and
# a model for the missile alone (its routine 0x29ACA8). Seen on the game, picture by picture: the ball is there for
# what is thrown or launched (grenades, shells: the weapons of its table that leave no trail, byte +2 = 0), not for
# the bolts of the weapons with a trail (laser, pulsars, particle beams, railguns, thermal disruptors, ion rifle),
# which show only by what they leave behind them: beams (_live_beam), dust (_live_parts). Before: shapes of Uplink's
# own (a capsule with a green band for a grenade, a red ball, a green streak, a white tracer, bars for the pulsar),
# fitted on pictures of the game when its beams were not read.
const SHOT_BALLS := [2, 3, 8, 13, 14, 17, 21, 28, 29, 30, 31, 32, 33]   # the weapons without a trail (10: the missile's model)
const SHOT_BALL_W := 0.05                        # 0x1555 / 65536 x the sprites' scale (1.2) / 2
var ball_mesh: QuadMesh
var ball_mat: StandardMaterial3D
var ball_key := ""


func _live_ball(idx: int, e) -> void:
	if ball_mesh == null or ball_key != pal_key:
		var sp: Dictionary = objects.sprite(Vector2i(1164, 0), pal, pal_key) if objects_ok else {}
		if sp.is_empty():
			return
		ball_key = pal_key
		ball_mesh = QuadMesh.new()
		ball_mesh.size = Vector2(SHOT_BALL_W, SHOT_BALL_W * sp["aspect"] * 1.2)   # (the game's pixels: 1.2 x taller than wide)
		ball_mat = StandardMaterial3D.new()
		ball_mat.albedo_texture = sp["texture"]
		ball_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		ball_mat.alpha_scissor_threshold = 0.5
		ball_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		ball_mat.billboard_keep_scale = true
		ball_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		ball_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		ball_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		ball_mat.disable_fog = true
	var mi: MeshInstance3D = live_fx.get(idx)
	if mi == null or mi.get_meta("kind", -1) != 14:
		if mi != null:
			mi.queue_free()
		mi = MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.layers = FX_LAYER
		mi.set_meta("kind", 14)
		world.add_child(mi)
		live_fx[idx] = mi
	mi.mesh = ball_mesh
	mi.material_override = ball_mat
	var pos := Vector3(e[3], e[5], e[4])
	mi.transform = Transform3D(Basis.IDENTITY, pos)
	mi.visible = pos.distance_to(camera.position) > 0.05    # (the game draws it from the gun on: huge for a picture)


# What a shot leaves behind it (class 6 type 29: a particle system of the game's engine): the game's own particles,
# where the game has them ('PART', live_bridge.py poussieres), drawn as the game plots each kind. Kind 7, a shot's
# dust (8 to 32 particles a system, 0.4 s): dots that keep their size on the screen, in the colour the game gives
# them (the dark reds of a laser, the dark blues of an ion rifle). Kinds 10 and 8, the thin smoke of a railgun and
# the puffs of a shell or a missile: flat see-through discs through one of the game's veils, which grow as they come
# near (dust.gdshader). Kind 9, a jetpack's trail: the same discs, 16 pixels of the game's picture wide at one unit
# and single pixels past 4 units (0x2A5A7C; before: smoke puffs of Uplink's own, up to 1.4 units wide, a grey veil
# over the view when the player's own trail was next to the camera). Kind 11, a thermal disruptor's haze: discs that
# warp what is behind them (haze.gdshader).
# Before: for each system red dots scattered at random around its entity whatever the weapon (_dust_update), and
# a shell's smoke taken for a smoke grenade's screen.
const PART_MAX := 1024                           # the game's engine holds no more particles
# a particle's kind -> its disc's width in world units (the game: a disc 40 pixels of its 848 wide at one unit for
# a shell's smoke, 4 for a railgun's, and 413 pixels to the radian; 0: a dot whatever the distance)
const PART_WIDTH := {7: 0.0, 8: 0.097, 9: 0.0388, 10: 0.0097}   # (9, a jetpack's trail: 16 pixels at one unit)
# how far a kind is still a disc: beyond, the game plots the particle as ONE pixel through its veil (0x2A59DC: kind 9
# past 4 units; a soldier's jetpack 5 units away drawn as discs was a grey cloud where the game shows a faint speckle)
const PART_FAR := {9: 4.0}
const HAZE_WIDTH := 0.24                         # a thermal disruptor's haze (100 pixels at one unit)
# how much of its veil a kind lays: a railgun's 64 particles a system pile up into a white bar at the veil's own
# strength, where the game shows a faint pale streak (seen side by side)
const PART_THIN := {10: 0.25}
# the particles' translucency tables (their "colours" 248 to 255, [0x423230] + 4 c, built at 0x28D4E8): the grey each
# one lays over the picture, and how much (as the code builds them: 248 a thin white veil ... 253 nearly black)
const PART_TINT := {248: Color(0.882, 0.882, 0.882, 0.200), 249: Color(0.813, 0.813, 0.813, 0.304),
		250: Color(0.682, 0.682, 0.682, 0.414), 251: Color(0.506, 0.506, 0.506, 0.349), 252: Color(0.394, 0.394, 0.394, 0.398),
		253: Color(0.098, 0.098, 0.098, 0.561), 254: Color(0.138, 0.138, 0.138, 0.340), 255: Color(0.050, 0.050, 0.050, 0.316)}
var part_mode := false                          # the bridge sends the particles (an older one: the dots, as before)
var part_node: MultiMeshInstance3D = null       # dots and see-through discs
var haze_node: MultiMeshInstance3D = null       # the thermal disruptor's
var part_px := 0.0019                           # a dot's half size per unit of distance (the lab can tune it)


func _part_cloud(shader: Shader) -> MultiMeshInstance3D:
	var node := MultiMeshInstance3D.new()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = QuadMesh.new()
	mm.instance_count = PART_MAX
	mm.visible_instance_count = 0
	node.multimesh = mm
	var sm := ShaderMaterial.new()
	sm.shader = shader
	node.material_override = sm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.layers = FX_LAYER
	node.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))   # (particles anywhere on the map)
	add_child(node)
	return node


func _live_parts(q: PackedByteArray) -> void:
	part_mode = true
	var n := mini(q.decode_u16(4), PART_MAX)
	if part_node == null:
		if n == 0:
			return
		part_node = _part_cloud(DUST)
		haze_node = _part_cloud(HAZE)
	(part_node.material_override as ShaderMaterial).set_shader_parameter("px", part_px)
	var buf := PackedFloat32Array()
	buf.resize(PART_MAX * 16)                        # per particle: a transform (12: its width, its place), a colour (4)
	var hbuf := PackedFloat32Array()
	hbuf.resize(PART_MAX * 16)
	var cols := {}
	var np := 0
	var nh := 0
	for k in n:
		var o := 6 + 14 * k
		var kind := q[o + 13]
		var haze := kind == 11
		var b := (nh if haze else np) * 16
		var w: float = HAZE_WIDTH if haze else maxf(PART_WIDTH.get(kind, 0.0), 0.00001)
		var into := hbuf if haze else buf
		into[b] = w
		into[b + 5] = w if haze else float(PART_FAR.get(kind, 1.0e6))   # (the discs' shader reads it there)
		into[b + 10] = w
		into[b + 3] = q.decode_float(o)
		into[b + 7] = q.decode_float(o + 8)          # (the game's z is up)
		into[b + 11] = q.decode_float(o + 4)
		if haze:
			nh += 1
			continue
		np += 1
		var ci := q[o + 12] + (0 if kind == 7 else 1000 * kind)
		if not cols.has(ci):
			var c: Color = _game_colour(ci) if kind == 7 else PART_TINT.get(q[o + 12], Color(0.6, 0.6, 0.6, 0.3))
			cols[ci] = Color(c.srgb_to_linear(), c.a * float(PART_THIN.get(kind, 1.0)))
		var cc: Color = cols[ci]
		buf[b + 12] = cc.r
		buf[b + 13] = cc.g
		buf[b + 14] = cc.b
		buf[b + 15] = cc.a
	part_node.multimesh.buffer = buf
	part_node.multimesh.visible_instance_count = np
	part_node.visible = np > 0
	haze_node.multimesh.buffer = hbuf
	haze_node.multimesh.visible_instance_count = nh
	haze_node.visible = nh > 0


# The SIR's lightning (class 6 type 31): the game's own forked lines from the gun ('BOLT', live_bridge.py eclairs:
# each stretch between two of its nodes and its colour, pale lilac fading to dark blue), each a line one pixel of
# the game's picture wide whatever the distance. Before: an orange ball at each of the six effects.
var bolt_mode := false                          # the bridge sends the lightning (an older one: nothing changes)
var bolt_node: MeshInstance3D = null
var bolt_mat: StandardMaterial3D
var bolt_px := 1.0                              # its lines' width, in pixels of the game's picture


func _live_bolts(q: PackedByteArray) -> void:
	bolt_mode = true
	var n := mini(q.decode_u16(4), 2000)
	if bolt_node == null:
		if n == 0:
			return
		bolt_node = MeshInstance3D.new()
		bolt_node.mesh = ImmediateMesh.new()
		bolt_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		bolt_node.layers = FX_LAYER
		bolt_node.extra_cull_margin = 16384.0
		bolt_mat = StandardMaterial3D.new()
		bolt_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		bolt_mat.vertex_color_use_as_albedo = true
		bolt_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		bolt_mat.disable_fog = true
		add_child(bolt_node)
	var im := bolt_node.mesh as ImmediateMesh
	im.clear_surfaces()
	bolt_node.visible = n > 0
	if n == 0:
		return
	var cam := camera.global_transform
	var px := tan(deg_to_rad(camera.fov) * 0.5) / 848.0 * bolt_px     # half a pixel of the game's picture, one unit away
	var cols := {}
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, bolt_mat)
	for k in n:
		var o := 6 + 25 * k
		var p0 := Vector3(q.decode_float(o), q.decode_float(o + 8), q.decode_float(o + 4))
		var p1 := Vector3(q.decode_float(o + 12), q.decode_float(o + 20), q.decode_float(o + 16))
		var across := (p1 - p0).cross(cam.origin - (p0 + p1) * 0.5)
		if across.length() < 1e-9:
			continue
		across = across.normalized()
		var a0: Vector3 = across * p0.distance_to(cam.origin) * px
		var a1: Vector3 = across * p1.distance_to(cam.origin) * px
		var ci := q[o + 24]
		if not cols.has(ci):
			cols[ci] = _game_colour(ci)
		im.surface_set_color(cols[ci])
		for v in [p0 - a0, p0 + a0, p1 + a1, p0 - a0, p1 + a1, p1 - a1]:
			im.surface_add_vertex(v)
	im.surface_end()


# A beam of the game (class 6 type 28: the laser's flash from the gun to its bolt, the ion rifle's, each bar of a
# pulsar's bolt): the game draws a line between the entity and a second point kept in its record, 0x200 wide in its
# 16.16 units, its core (0xC0) in a colour of its palette and the rest six colours further (colour 0x28: 0x20 inside
# 0x25, 0x50 inside 0xC0). On its screen the line is as wide as a sprite of that size (the same scale: 1.2), so it
# tapers with the distance: ~4 pixels of its 848 at a bolt one unit away, ~30 at the gun beside the eye. Here: a
# ribbon facing the camera between the two points the bridge reads ('BEAM', live_bridge.py rayons), in the game's
# own colours. Before: Uplink's own red and blue beams fitted on pictures, and dots for the rest.
const BEAM_W := 0.0078125                        # 0x200 / 65536
var beam_scale := 1.2                           # (the lab: the beams' width against the game's line)
var beam_min_px := 1.0                          # a beam's least width, in pixels of the game's picture
var beams := {}                                 # 6/28 entity -> [from, to, colour]


# A piece of a blown-up building (class 6 type 32, live_bridge.py debris). The game draws a small slab seen from both
# sides: a rectangle of one of its textures (the more of it the bigger the piece: an eighth of the picture per
# thirty-second of a unit), or its dark grey 0x25 when it has none. The game's rectangle (0x29B730: corners +/-a,
# +/-b in x, y and a fixed +/-0.25 in z, turned by heading +0x1B and pitch +0x1D only): 2a wide, always level and
# across the heading, 2 * sqrt(b^2 + 1/16) long (0.5 to 0.66), the pitch turning it about its width. The third angle
# (+0x1F) is sent but the game never uses it. Before: the default of an effect Uplink did not know, an orange ball
# (the yellow circles of ticket #12).
var shards := {}                                # 6/32 entity -> [texture, half width, b, heading, pitch, (unused)]
var shard_mesh: QuadMesh
var shard_mats := {}


func _shard_mat(tex_index: int, ka: int, kb: int) -> StandardMaterial3D:
	var key := "%d/%d/%d/%s" % [tex_index, ka, kb, pal_key]
	if shard_mats.has(key):
		return shard_mats[key]
	var m := StandardMaterial3D.new()
	m.roughness = 1.0
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	var tex: Texture2D = null
	if objects_ok and tex_index >= 0:
		# a piece of a tree or a bush has the plant's own picture, cut out (its colour 0 shows through); a piece of
		# a building one of the models' textures, whole
		var ref: Vector2i = objects.tex_ref.get(tex_index, Vector2i.ZERO)
		if TNObjects.is_sprite(ref):
			var sp: Dictionary = objects.sprite(ref, pal, pal_key)
			if not sp.is_empty():
				tex = sp["texture"]
				m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				m.alpha_scissor_threshold = 0.5
		else:
			tex = objects._texture(tex_index, pal, pal_key)
	if tex != null:
		m.albedo_texture = tex
		m.uv1_scale = Vector3(ka / 8.0, kb / 8.0, 1.0)
	else:
		m.albedo_color = pal[0x25] if pal.size() > 0x25 else Color(0.25, 0.25, 0.25)
	shard_mats[key] = m
	return m


func _live_shard(idx: int, e, d: Array) -> void:
	var a: float = d[1]
	var b: float = d[2]
	var mi: MeshInstance3D = live_fx.get(idx)
	if a <= 0.0:                                     # (no width: nothing to see; b = 0 is a 2a x 0.5 strip)
		if mi != null:
			mi.visible = false
		return
	if shard_mesh == null:
		shard_mesh = QuadMesh.new()
		shard_mesh.size = Vector2(1.0, 1.0)
	if mi == null or mi.get_meta("kind", -1) != 32:
		if mi != null:
			mi.queue_free()
		mi = MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("kind", 32)
		mi.mesh = shard_mesh
		world.add_child(mi)
		live_fx[idx] = mi
	mi.material_override = _shard_mat(int(d[0]), int(round(a * 32.0)), int(round(b * 32.0)))
	# the game's axes: x, y on the ground, z up (Uplink's: x, up, y). Its model axes turned by heading and pitch
	# (rotation order 1, no third angle): X across the heading, Y and Z in the vertical plane of the heading. The
	# corners: +/-U +/-V, U = a X (half width), V = b Y + 0.25 Z (half length); the texture's u across the width
	var h := TAU * float(d[3]) / 65536.0
	var p := TAU * float(d[4]) / 65536.0
	var gx := Vector3(-sin(h), cos(h), 0.0)
	var gy := Vector3(sin(p) * cos(h), sin(p) * sin(h), -cos(p))
	var gz := Vector3(cos(p) * cos(h), cos(p) * sin(h), sin(p))
	var u := gx * a
	var v := gy * b + gz * 0.25
	var c0 := Vector3(u.x, u.z, u.y) * -2.0
	var c1 := Vector3(v.x, v.z, v.y) * 2.0
	mi.transform = Transform3D(Basis(c0, c1, c0.cross(c1).normalized()), Vector3(e[3], e[5], e[4]))
	mi.visible = true
var beam_mode := false                          # the bridge sends the beams (an older one: Uplink's own, as before)
var beam_mats := {}
# A beam at the gun (the player's laser: the thick red line from the gun to the bolt) is in the game for ONE of its
# pictures, then the bolt is far and its line a few pixels. The bridge reads the game faster than Uplink draws: when
# that picture's beams and the next one's came between two of Uplink's views, only the next one's were drawn and the
# shot showed no beam at all. Each beam near the eye is noted as it comes and drawn in the next view if the game's
# state then no longer has it. TN_BEAM_HOLD (milliseconds, default 0: as the game) keeps it on screen that long, for
# those who find a sixtieth of a second too short (the game at its 1996 pace showed it for about 50).
const BEAM_FLASH_NEAR := 2.5                    # how near the eye (units)
const BEAM_FLASH_LONG := 0.05                   # not a pulsar bolt's bars (0.02 long, a chain of them)
var beam_hold := maxi(0, int(OS.get_environment("TN_BEAM_HOLD")))
var beam_flash := []                            # [6/28 entity, beam, msec it came, drawn]


func _beam_flash_note(idx: int) -> void:
	var b: Array = beams[idx]
	var eye := camera.global_position
	if (b[0] as Vector3).distance_to(b[1]) < BEAM_FLASH_LONG or 			minf((b[0] as Vector3).distance_to(eye), (b[1] as Vector3).distance_to(eye)) > BEAM_FLASH_NEAR:
		return
	for f in beam_flash:                                # (the same state, sent again while the game holds it)
		if f[0] == idx and (f[1][0] as Vector3) == (b[0] as Vector3) and (f[1][1] as Vector3) == (b[1] as Vector3):
			return
	if beam_flash.size() < 64:
		beam_flash.append([idx, b, Time.get_ticks_msec(), false])


# with each view: the noted beams the game's state no longer has, not drawn yet (or held: TN_BEAM_HOLD)
func _beam_flashes() -> void:
	var now := Time.get_ticks_msec()
	var keep := []
	for f in beam_flash:
		var b: Array = f[1]
		var cur = beams.get(f[0])
		if cur != null and (cur[0] as Vector3) == (b[0] as Vector3) and (cur[1] as Vector3) == (b[1] as Vector3):
			f[3] = true                                 # in this view as it is (_live_beam)
			keep.append(f)
		elif not f[3] or now - int(f[2]) < beam_hold:
			f[3] = true
			_live_beam(-1 - keep.size(), b)
			keep.append(f)
	beam_flash = keep


func _game_colour(i: int) -> Color:
	if hud_pal_img != null and hud_version > 0:
		return hud_pal_img.get_pixel(i & 0xFF, 0)
	return pal[i & 0xFF] if pal.size() > (i & 0xFF) else Color(1.0, 0.0, 0.0)


func _live_beam(idx: int, b: Array) -> void:
	var mi: MeshInstance3D = live_fx.get(idx)
	if mi == null or mi.get_meta("kind", -1) != 13:
		if mi != null:
			mi.queue_free()
		mi = MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.mesh = ImmediateMesh.new()
		mi.layers = FX_LAYER
		mi.set_meta("kind", 13)
		world.add_child(mi)
		live_fx[idx] = mi
	var col: int = b[2]
	if not beam_mats.has(col):
		var bm := ShaderMaterial.new()
		bm.shader = BEAM
		bm.set_shader_parameter("core_frac", 0x50 / float(0xC0) if col == 0x28 else 0xC0 / float(0x200))
		beam_mats[col] = bm
	var mat: ShaderMaterial = beam_mats[col]
	mat.set_shader_parameter("core", _game_colour(0x20 if col == 0x28 else col))
	mat.set_shader_parameter("edge", _game_colour(0x25 if col == 0x28 else col + 6))
	var hw := BEAM_W * (0xC0 / float(0x200) if col == 0x28 else 1.0) * beam_scale * 0.5
	var p0: Vector3 = b[0]
	var p1: Vector3 = b[1]
	var cam := camera.global_transform
	var seg := p1 - p0
	var across := seg.cross(cam.origin - (p0 + p1) * 0.5)
	if seg.length() < 0.001 or across.length() < 1e-9:  # no length (or seen end on): a dot of its width
		across = cam.basis.x
		p0 -= cam.basis.y * hw
		p1 = p0 + cam.basis.y * hw * 2.0
	across = across.normalized()
	# never thinner than a pixel of the game's picture (848 across its view): far away its line keeps that width
	var px := tan(deg_to_rad(camera.fov) * 0.5) / 848.0 * beam_min_px
	var a0: Vector3 = across * maxf(hw, p0.distance_to(cam.origin) * px)
	var a1: Vector3 = across * maxf(hw, p1.distance_to(cam.origin) * px)
	var im := mi.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, mat)
	for c in [[p0 - a0, 0.0], [p0 + a0, 1.0], [p1 + a1, 1.0], [p0 - a0, 0.0], [p1 + a1, 1.0], [p1 - a1, 0.0]]:
		im.surface_set_uv(Vector2(0.5, c[1]))
		im.surface_add_vertex(c[0])
	im.surface_end()
	mi.global_transform = Transform3D.IDENTITY
	mi.extra_cull_margin = 4.0
	mi.visible = true


# The pulsar (5/5): five bolts in a quincunx, each trailed by a few 6/28 particles flying with it (0.03-0.12 unit
# behind). The game draws the bolt and each of its particles as a small bar lying flat on the screen, a light red
# core (252,64,64) in a dark red outline (123,1,1), ~0.022 x 0.012 unit: each bolt makes a short chain of bars
# (measured on its picture). Its impacts (6/5): small light red marks.
const PULSAR_BAR := Vector2(0.011, 0.006)        # half size of a pulsar bar (world units)
var pulsar_parts := {}                          # pulsar bolt index -> its particles this frame (bolt first)
var pulsar_dust := {}                           # 6/28 particles trailing a pulsar bolt: not drawn as dust
var pulsar_mat: ShaderMaterial


func _pulsar_trails(ents: Dictionary) -> void:
	pulsar_parts.clear()
	pulsar_dust.clear()
	for idx in ents:
		var e = ents[idx]
		if e[0] == 5 and e[1] == 5 and e[2] != 0:
			pulsar_parts[idx] = [Vector3(e[3], e[5], e[4])]
	if pulsar_parts.is_empty() or beam_mode:            # (its 6/28 are the game's own lines then: _live_beam)
		return
	for idx in ents:
		var e = ents[idx]
		if not (e[0] == 6 and e[1] == 28 and e[2] != 0):
			continue
		var p := Vector3(e[3], e[5], e[4])
		var best := -1
		var bd := 0.4
		for b in pulsar_parts:
			var d: float = p.distance_to(pulsar_parts[b][0])
			if d < bd:
				bd = d
				best = b
		if best >= 0:
			pulsar_dust[idx] = true
			pulsar_parts[best].append(p)


func _live_pulsar(idx: int, e) -> void:
	var mi: MeshInstance3D = live_fx.get(idx)
	if mi == null or mi.get_meta("kind", -1) != 11:
		if mi != null:
			mi.queue_free()
		mi = MeshInstance3D.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.mesh = ImmediateMesh.new()
		mi.set_meta("kind", 11)
		world.add_child(mi)
		live_fx[idx] = mi
	if pulsar_mat == null:
		pulsar_mat = ShaderMaterial.new()
		pulsar_mat.shader = BEAM
		pulsar_mat.set_shader_parameter("core", Color(0.988, 0.251, 0.251))
		pulsar_mat.set_shader_parameter("edge", Color(0.482, 0.004, 0.004))
		pulsar_mat.set_shader_parameter("core_frac", 0.4)
		pulsar_mat.set_shader_parameter("core_frac_x", 0.75)
	var cam := camera.global_transform
	var bx := cam.basis.x * PULSAR_BAR.x
	var by := cam.basis.y * PULSAR_BAR.y
	var parts: Array = pulsar_parts.get(idx, [Vector3(e[3], e[5], e[4])]).filter(func(c): return c.distance_to(cam.origin) >= 0.25)
	if parts.is_empty():                              # all of it at the gun: nothing to draw (an empty surface is an error)
		mi.visible = false
		return
	var im := mi.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, pulsar_mat)
	for c in parts:
		for v in [[-1.0, -1.0], [1.0, -1.0], [1.0, 1.0], [-1.0, -1.0], [1.0, 1.0], [-1.0, 1.0]]:
			im.surface_set_uv(Vector2(v[0] * 0.5 + 0.5, v[1] * 0.5 + 0.5))
			im.surface_add_vertex(c + bx * v[0] + by * v[1])
	im.surface_end()
	mi.global_transform = Transform3D.IDENTITY
	mi.extra_cull_margin = 2.0
	mi.visible = true


# Type 6/29 is a smoke puff: the jetpack drops one at the player's feet every frame, the laser a few along its
# trail. The game keeps the entity only a moment, so each new one starts a puff that lives on its own here.
const PUFF_LIFE := 1.2
var puff_seen := {}

# Effects the game draws as an animation (class 6: impacts, sparks, splashes, blasts, flames): its own table, read
# in the player's files (tn_objects.gd, fx_def): for each type its animation, drawn as wide as the type's sprite
# whatever the bitmap's size and anchored on the entity, a frame's time, played once or looping. The game keeps the
# entity as long as its animation plays: here each new entity starts the animation, which plays on its own (a
# looping one lives and moves with its entity). 23 is also a tree blown up: its black smoke comes with it.
# (Before: four types fitted by eye, two of them on another type's animation and two half their size, the 24
# others a small orange ball.)
const FX_GAP_MS := 150           # an entity not seen for that long, then seen again in its slot: a new effect
var fx_scale := 1.0 / 1.1        # the effects' scale against their width (SPRITE_SCALE: the same routine draws them)
var anims := []                  # [node, start msec, duration in s (0: looping), its entity]
var smoke_pending := []          # blasts (6/23) waiting to know whether a suit burst there: [position, msec]
var anim_seen := {}              # entity -> [msec last seen, type, position, its looping node or null]
var anim_mats := {}              # type -> [material, mesh, duration]
var anim_frames := {}            # entity -> the frame the game shows of its animation ('ANIM'; none: Uplink's own clock)


func _fx_anim(typ: int) -> bool:
	return objects_ok and not objects.fx_def(typ).is_empty()


func _live_anim(idx: int, typ: int, pos: Vector3) -> void:
	var now := Time.get_ticks_msec()
	var seen = anim_seen.get(idx)
	var fresh: bool = seen == null or seen[1] != typ or now - int(seen[0]) > FX_GAP_MS or (seen[2] as Vector3).distance_to(pos) > 0.5
	var node: MeshInstance3D = null
	if not fresh and seen != null and is_instance_valid(seen[3]):   # (a looping node ended by _anims_update is freed)
		node = seen[3]
	if fresh:
		node = _spawn_anim(pos, typ, idx)
		if typ == 23 and not smoke_pending.any(func(s): return (s[0] as Vector3).distance_to(pos) < 0.5):
			smoke_pending.append([Vector3(pos.x, pos.y - GAME_Z, pos.z), now])   # a tree's black smoke, unless it was a soldier (see below)
	elif node != null and is_instance_valid(node):
		node.position = pos                             # (it moves with its entity: a blast's fireballs, flames)
	anim_seen[idx] = [now, typ, pos, node]


# Starts the animation of an effect; returns its node (it follows its entity: a blast's fireballs fly apart).
func _spawn_anim(pos: Vector3, typ: int, idx := -1) -> MeshInstance3D:
	var fd: Dictionary = objects.fx_def(typ) if objects_ok else {}
	if fd.is_empty():
		return null
	var ad: Dictionary = objects.anim(fd["res"], pal, pal_key)
	if ad.is_empty():
		return null
	if not anim_mats.has(typ):
		var am := ShaderMaterial.new()
		am.shader = ANIM_SOFT if ad.get("soft", false) else ANIM
		var frames: int = mini(ad["frames"], fd["frames"])
		var fps: float = 1000.0 / fd["ms"]
		am.set_shader_parameter("frames", ad["tex"])
		am.set_shader_parameter("frame_count", frames)
		am.set_shader_parameter("fps", fps)
		am.set_shader_parameter("loop", fd["loop"])
		var sc: float = fd["width"] * fx_scale / ad["size"].x     # world units per pixel of its bitmap
		var w: float = ad["size"].x * sc
		var h: float = ad["size"].y * sc
		var a: Vector2 = ad["anchor"] * sc
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for c in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
			st.set_uv(c)
			st.add_vertex(Vector3(c.x * w - a.x, a.y - c.y * h, 0.0))
		anim_mats[typ] = [am, st.commit(), 0.0 if fd["loop"] else frames / fps]
	var mi := MeshInstance3D.new()
	mi.mesh = anim_mats[typ][1]
	mi.material_override = anim_mats[typ][0]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.layers = FX_LAYER                             # (a burn mark under it darkened it)
	mi.extra_cull_margin = 2.0
	mi.position = pos
	world.add_child(mi)
	anims.append([mi, Time.get_ticks_msec(), anim_mats[typ][2], idx])
	return mi


# The black smoke a blown-up tree sends up as its fireball dies (the game's own is a swarm of class 6 particles,
# like a laser's trail, which this viewer draws as dust): dark puffs rising from it into a cloud.
func _smoke_column(pos: Vector3) -> void:
	for k in 22:
		var r := float((k * 7919 + int(pos.x * 100.0)) % 1000) / 1000.0
		var r2 := float((k * 104729 + int(pos.z * 100.0)) % 1000) / 1000.0
		var top := float(k) / 21.0                       # the later ones higher and spread wider: a cloud on top
		var off := Vector3((r - 0.5) * (0.3 + 1.2 * top), 0.5 + 1.6 * top, (r2 - 0.5) * (0.3 + 1.2 * top))
		var vel := Vector3((r2 - 0.5) * 0.6, 0.7 + 0.4 * r, (r - 0.5) * 0.6)
		_spawn_puff(pos + off, 0.45 + 0.3 * r, 0.5 + 0.035 * k, vel, 0.3, 2.2)


func _anims_update() -> void:
	var now := Time.get_ticks_msec()
	# a blast where a suit burst (its pile, 6/33, appears with it) has no smoke column: only a tree's has
	for k in range(smoke_pending.size() - 1, -1, -1):
		if now - int(smoke_pending[k][1]) < 250:
			continue
		var at: Vector3 = smoke_pending[k][0]
		var suit_there := false
		for idx in live_piles:
			var pl: Node3D = live_piles[idx]
			if pl.visible and Vector2(pl.position.x, pl.position.z).distance_to(Vector2(at.x, at.z)) < 2.0:
				suit_there = true
		if not suit_there:
			_smoke_column(at)
		smoke_pending.remove_at(k)
	for k in range(anims.size() - 1, -1, -1):
		var age := (now - int(anims[k][1])) / 1000.0
		var mi: MeshInstance3D = anims[k][0]
		var looping := float(anims[k][2]) <= 0.0
		var framed: bool = int(anims[k][3]) >= 0 and anim_frames.has(anims[k][3])   # the game says which frame
		var done := age >= float(anims[k][2]) and not looping and not framed
		if int(anims[k][3]) >= 0:                       # it lives as long as the game keeps its entity (a looping
			var seen = anim_seen.get(anims[k][3])       # one: only that long; a fireball that lands goes out)
			done = done or seen == null or seen[3] != mi or now - int(seen[0]) > FX_GAP_MS
		if done:
			mi.queue_free()
			anims.remove_at(k)
		else:
			mi.set_instance_shader_parameter("age", age)
			mi.set_instance_shader_parameter("frame", float(anim_frames[anims[k][3]]) if framed else -1.0)
var fps_label: Label
var dead_suits := []       # [position, suit] of the soldiers killed: their pieces of armour around
var puff_units := []      # positions of the units this update (jetpacks)
var fx29 := {}            # 6/29 entity -> its particles' kind when not a shot's dust: 8 smoke, 9 a jetpack's trail
func _live_puff(idx: int, pos: Vector3, e) -> bool:
	if not puff_units.any(func(u): return Vector2(u.x, u.z).distance_to(Vector2(e[3], e[4])) < 0.25):
		return false                                # not right under a unit: a weapon's red dust
	var fresh: bool = puff_seen.get(idx, -10) != live_seen - 1
	puff_seen[idx] = live_seen
	if fresh:
		_spawn_puff(pos, 1.0, 0.0, Vector3.ZERO, 1.0, 1.0, true)
	return true


# Smoke grenades (the game's 6/29 at the impact, alive ~17 s): their cloud is a particle system of the game's engine,
# sent by the bridge 20 times a second ('SMKC': per cloud its entity, centre and up to 160 particles, world position,
# size 24-127 growing as they rise, life left). The game draws each particle as a small faint grey puff (~190 at
# first, fewer and fewer, up to ~3.5 units high and 1-2 units around): here each update starts a few of the
# jetpack's puffs at some of its particles, bigger and denser, and a low wall around its foot while it is thick, so
# the cloud screens like a smoke grenade should.
const SMOKE_PUFFS := 8                         # puffs started at the cloud's particles per update (20 a second)
const SMOKE_BASE := 3                          # and around its foot, while the cloud is at its thickest
const SMOKE_FULL := 190.0                      # particles of a fresh cloud
const SMOKE_SIZE := 1.1                        # puff size for the game's biggest particle (127)
const SMOKE_DENSE := 1.7                       # puff opacity factor (the jetpack's: 1)
var smoke_clouds := {}                         # game entity index -> true, the clouds of the last update
var smoke_rng := RandomNumberGenerator.new()
# the screen outlasts the game's cloud (half its particles gone after 4 s, all of them at ~17-20 s, too short): puffs
# filling the same volume, thick for smoke_hold s, thinning out over smoke_fade s (vars: the lab can tune them)
var smoke_hold := 25.0
var smoke_fade := 15.0
var smoke_screens := {}                        # game entity index -> [centre, start msec]
var smoke_counts := {}                         # game entity index -> its particles in the last update
var smoke_linger_t := 0


func _smoke_packet_ok(q: PackedByteArray) -> bool:
	var o := 5
	for _c in q[4]:
		if o + 18 > q.size():
			return false
		o += 18 + 14 * q.decode_u16(o + 16)
	return o == q.size()


func _live_smoke(q: PackedByteArray) -> void:
	smoke_clouds.clear()
	smoke_counts.clear()
	var o := 5
	for _c in q[4]:
		var idx := q.decode_s32(o)
		var centre := Vector3(q.decode_float(o + 4), q.decode_float(o + 12), q.decode_float(o + 8))
		var n := q.decode_u16(o + 16)
		smoke_clouds[idx] = true
		smoke_counts[idx] = n
		if not smoke_screens.has(idx) or (smoke_screens[idx][0] as Vector3).distance_to(centre) > 1.0:
			smoke_screens[idx] = [centre, Time.get_ticks_msec()]     # (a new cloud, maybe in an old one's slot)
		var p0 := o + 18
		o = p0 + 14 * n
		if n == 0:
			continue
		for _k in mini(SMOKE_PUFFS, n):
			var po := p0 + 14 * smoke_rng.randi_range(0, n - 1)
			var pos := Vector3(q.decode_float(po), q.decode_float(po + 8), q.decode_float(po + 4))
			var grow := float(q[po + 12]) / 127.0
			var vel := Vector3(smoke_rng.randf_range(-0.15, 0.15), 0.2 + 0.2 * grow, smoke_rng.randf_range(-0.15, 0.15))
			_spawn_puff(pos, SMOKE_SIZE * (0.5 + 0.5 * grow), smoke_rng.randf_range(0.0, 0.05), vel, 0.95, SMOKE_DENSE)
		var thick := clampf(float(n) / SMOKE_FULL, 0.0, 1.0)
		for _k in SMOKE_BASE:                            # the foot of the screen, thinning out with the cloud
			if smoke_rng.randf() > thick:
				continue
			var a := smoke_rng.randf() * TAU
			var r := smoke_rng.randf_range(0.2, 1.3)
			var pos := centre + Vector3(cos(a) * r, smoke_rng.randf_range(0.1, 0.6), sin(a) * r)
			_spawn_puff(pos, 1.3, 0.0, Vector3(cos(a) * 0.2, 0.1, sin(a) * 0.2), 0.9, SMOKE_DENSE * thick)


# Weather ('WTHR', 10 times a second: kind 0 snow, 1 rain, 0xFF none; colour index; drift and fall ranges; the
# game's flake count and its view's area). The game's snow (missions 21 and 36, the ice planet's sky SKY1) is not in
# the world: ~1000 dots on the screen (1 pixel far, 3 x 3 crosses near) with a fake depth that only sets their speed
# and how far they slide when the camera moves, i.e. a shell ~1.6-3.2 units around the eye. Here: Uplink's own
# flakes in a box around the camera, as many per volume as the game's in that shell, falling at the game's speed.
const WEATHER_SHELL := 11.5                    # volume of the game's flakes in its view (units^3, ~100 deg x 40 deg)
const WEATHER_BOX := Vector3(7.0, 5.0, 7.0)
const WEATHER_FALL := 0.45                     # the game's fall step (1/16 px per depth per 32 ms) in units/s
var weather_scale := 0.8                       # flakes per volume against the game's (they are bigger and softer)
var weather_node: MultiMeshInstance3D = null
var weather_key := ""
var weather_off_t := 0
const WEATHER_OFF_MS := 700


# Snow settling on the ground (live). While it snows (weather kind 1: MISS17 and MISS30, the ice planet), the game
# whitens its ground tiles themselves: every 45-70 ticks of its clock (0x2B0358), on each of the 64 tiles, one texel
# at random takes a snow colour, palette 29-32 (and, 1 time in 16, one of the 16 x 16 copy too). Nothing undoes it:
# the longer the mission, the whiter its ground (a quarter of the texels, then two thirds, in the test game). Its far
# ground (the column rings, 0x2AC2B7) is drawn with the 16 x 16 copies, snowed at the same rate a texel: the mips of
# the same tiles here. The bridge sends the tiles from the game's memory ('TEXL': first tile, count, then the tiles'
# palette indices, deflated); the ground (detail and outer maps) is drawn with them. Up to the first snow nothing
# changes.
var snow_pl := {}                               # the map's planet (tn_data _read_planet)
var snow_mats := []                             # the ground's materials (detail and outer maps)
var snow_tex: Texture2DArray = null             # its tiles as the game holds them (null: the planet's own)
var snow_lit: Texture2DArray = null             # the same through the shade rows (TNData.lit_tiles)
var snow_idx: Texture2DArray = null             # and as palette indices (TNData.index_tiles)
var snow_raw := {}                              # tile -> the palette indices last laid on snow_tex


func _live_tiles(q: PackedByteArray) -> void:
	var first := q[4]
	var count := q[5]
	if snow_mats.is_empty() or not snow_pl.get("ok", false) or not snow_pl.has("raw") or count == 0:
		return
	var px := q.slice(6).decompress(count * 4096, FileAccess.COMPRESSION_DEFLATE)
	if px.size() != count * 4096:
		return
	var raw: PackedByteArray = snow_pl["raw"]
	var tex: Texture2DArray = snow_pl["textures"]
	var fp: PackedColorArray = snow_pl["palette"]
	var n: int = tex.get_layers()
	for k in count:
		var t := first + k
		if t >= n:
			break
		var p := px.slice(k * 4096, k * 4096 + 4096)
		var prev: PackedByteArray = snow_raw.get(t, raw.slice(t * 4096, t * 4096 + 4096))
		if p == prev:
			continue
		if snow_tex == null:                         # the first change: a copy of the planet's tiles (shared by its maps)
			var imgs: Array[Image] = []
			for i in n:
				imgs.append(tex.get_layer_data(i))
			snow_tex = Texture2DArray.new()
			snow_tex.create_from_images(imgs)
			for sm in snow_mats:
				for u in ["tiles", "tiles_soft", "tiles_wrap"]:
					(sm as ShaderMaterial).set_shader_parameter(u, snow_tex)
			if snow_pl.get("tiles_lit") != null:
				var lt: Texture2DArray = snow_pl["tiles_lit"]
				var limgs: Array[Image] = []
				for i in lt.get_layers():
					limgs.append(lt.get_layer_data(i))
				snow_lit = Texture2DArray.new()
				snow_lit.create_from_images(limgs)
				for sm in snow_mats:
					for u in ["tiles_lit", "tiles_lit_soft"]:
						(sm as ShaderMaterial).set_shader_parameter(u, snow_lit)
			if snow_pl.get("tiles_idx") != null:
				var it: Texture2DArray = snow_pl["tiles_idx"]
				var iimgs: Array[Image] = []
				for i in it.get_layers():
					iimgs.append(it.get_layer_data(i))
				snow_idx = Texture2DArray.new()
				snow_idx.create_from_images(iimgs)
				for sm in snow_mats:
					(sm as ShaderMaterial).set_shader_parameter("tiles_idx", snow_idx)
		var rgb := PackedByteArray()
		rgb.resize(4096 * 3)
		for i in 4096:
			var c: Color = fp[p[i]]
			rgb[3 * i] = c.r8
			rgb[3 * i + 1] = c.g8
			rgb[3 * i + 2] = c.b8
		var img := Image.create_from_data(64, 64, false, Image.FORMAT_RGB8, rgb)
		img.generate_mipmaps()
		snow_tex.update_layer(img, t)
		if snow_idx != null:
			snow_idx.update_layer(TNData.index_tile(p), t)
		if snow_lit != null:
			var luts: Array = snow_pl["shade_luts"]
			for row in luts.size():
				snow_lit.update_layer(TNData.lit_tile(p, luts[row]), row * n + t)
		snow_raw[t] = p


func _live_weather(q: PackedByteArray) -> void:
	var kind := q[4]
	var n := q.decode_u16(10)
	if kind == 0xFF or n == 0:
		# a single "none" now and then (the game's views rebuilt between two reads) blinked the snow off for a tenth
		# of a second: hidden only once it has said so for WEATHER_OFF_MS
		if weather_off_t == 0:
			weather_off_t = Time.get_ticks_msec()
		if weather_node != null and Time.get_ticks_msec() - weather_off_t >= WEATHER_OFF_MS:
			weather_node.visible = false
		return
	weather_off_t = 0
	if weather_node == null:
		weather_node = MultiMeshInstance3D.new()
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_custom_data = true
		mm.mesh = QuadMesh.new()
		weather_node.multimesh = mm
		var sm := ShaderMaterial.new()
		sm.shader = SNOW
		weather_node.material_override = sm
		weather_node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		weather_node.custom_aabb = AABB(Vector3(-1e5, -1e5, -1e5), Vector3(2e5, 2e5, 2e5))   # moved by the shader
		add_child(weather_node)
	var key := "%d/%d" % [kind, n]
	if key != weather_key:
		weather_key = key
		var vol := WEATHER_BOX.x * WEATHER_BOX.y * WEATHER_BOX.z
		var count := clampi(int(n / WEATHER_SHELL * vol * weather_scale), 0, 30000)
		var buf := PackedFloat32Array()
		buf.resize(count * 16)                     # per flake: identity transform (12), custom (4): seed, phase
		var rng := RandomNumberGenerator.new()
		rng.seed = 36
		for i in count:
			var o := i * 16
			buf[o] = 1.0
			buf[o + 5] = 1.0
			buf[o + 10] = 1.0
			for k in 4:
				buf[o + 12 + k] = rng.randf()
		weather_node.multimesh.instance_count = count
		weather_node.multimesh.buffer = buf
	var rain := kind == 1
	var fall := (q.decode_s8(8) + q.decode_s8(9)) * 0.5 * WEATHER_FALL
	var sm := weather_node.material_override as ShaderMaterial
	# rain: the game also moves its drops as if the camera went +x by 0x1249 (16.16) per 32 ms (wind towards -x)
	sm.set_shader_parameter("drift", Vector3(-2.2 if rain else 0.0, -fall, 0.0))
	sm.set_shader_parameter("sway", 0.0 if rain else 0.03 * (q.decode_s8(7) - q.decode_s8(6)))
	sm.set_shader_parameter("size", 0.012 if rain else 0.03)
	sm.set_shader_parameter("stretch", 6.0 if rain else 1.0)
	var c := pal[q[5]] if pal.size() > q[5] else Color(0.92, 0.95, 1.0)
	sm.set_shader_parameter("color", Color(c.r, c.g, c.b, 0.5 if rain else 0.9))
	weather_node.visible = true


# what the game's own particles no longer give, 20 times a second: puffs in its volume (up to ~3.5 above the ground,
# ~1.8 around), and at its foot
func _smoke_linger() -> void:
	var now := Time.get_ticks_msec()
	if now - smoke_linger_t < 50 or smoke_screens.is_empty():
		return
	smoke_linger_t = now
	for idx in smoke_screens.keys():
		var age := (now - int(smoke_screens[idx][1])) / 1000.0
		if age > smoke_hold + smoke_fade:
			smoke_screens.erase(idx)
			continue
		var fill := 1.0 - clampf((age - smoke_hold) / smoke_fade, 0.0, 1.0)
		var extra := fill - clampf(float(smoke_counts.get(idx, 0)) / SMOKE_FULL, 0.0, 1.0)
		if extra <= 0.0:
			continue
		var centre: Vector3 = smoke_screens[idx][0]
		var n := int(round(SMOKE_PUFFS * extra))
		if smoke_rng.randf() < SMOKE_PUFFS * extra - n:
			n += 1
		for _k in n:
			var a := smoke_rng.randf() * TAU
			var r := sqrt(smoke_rng.randf()) * 1.8
			var h := smoke_rng.randf_range(0.1, 3.5)
			var grow := h / 3.5
			var vel := Vector3(smoke_rng.randf_range(-0.15, 0.15), 0.15 + 0.15 * grow, smoke_rng.randf_range(-0.15, 0.15))
			_spawn_puff(centre + Vector3(cos(a) * r, h, sin(a) * r), SMOKE_SIZE * (0.5 + 0.5 * grow),
					smoke_rng.randf_range(0.0, 0.05), vel, 0.95, SMOKE_DENSE)
		for _k in SMOKE_BASE:
			if smoke_rng.randf() > extra:
				continue
			var a := smoke_rng.randf() * TAU
			var r := smoke_rng.randf_range(0.2, 1.3)
			_spawn_puff(centre + Vector3(cos(a) * r, smoke_rng.randf_range(0.1, 0.6), sin(a) * r), 1.3, 0.0,
					Vector3(cos(a) * 0.2, 0.1, sin(a) * 0.2), 0.9, SMOKE_DENSE * fill)


# trail: a puff of a trail (a jetpack's, a missile's with an older bridge), born next to who leaves it: it fades out
# as the camera comes near instead of veiling the view (the others, a smoke screen's, do screen it)
func _spawn_puff(pos: Vector3, size: float, delay := 0.0, vel := Vector3.ZERO, tint := 1.0, dense := 1.0, trail := false) -> void:
	if puff_mat == null:
		var sm: Dictionary = objects.smoke_anim(pal, pal_key) if objects_ok else {}
		if sm.is_empty():
			return
		puff_mat = ShaderMaterial.new()
		puff_mat.shader = PUFF
		puff_mat.set_shader_parameter("frames", sm["tex"])
		puff_mat.set_shader_parameter("frame_count", sm["frames"])
		puff_mat.set_shader_parameter("life", PUFF_LIFE)
		puff_mesh = QuadMesh.new()
		puff_mesh.size = Vector2(1.0, 1.0)
	var mi := MeshInstance3D.new()
	mi.mesh = puff_mesh
	mi.material_override = puff_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 2.0
	world.add_child(mi)
	mi.position = pos
	mi.visible = delay <= 0.0
	mi.set_instance_shader_parameter("size", size)
	mi.set_instance_shader_parameter("tint", tint)
	mi.set_instance_shader_parameter("dense", dense)
	mi.set_instance_shader_parameter("near_fade", 1.0 if trail else 0.0)
	puffs.append([mi, Time.get_ticks_msec() + int(delay * 1000.0), pos, vel])


func _puffs_update() -> void:
	var now := Time.get_ticks_msec()
	var keep := []
	for p in puffs:
		var age := (now - int(p[1])) / 1000.0
		if not is_instance_valid(p[0]):
			continue
		if age >= PUFF_LIFE:
			p[0].queue_free()
			continue
		keep.append(p)
		if age < 0.0:                                   # not started yet
			continue
		p[0].position = p[2] + p[3] * age
		p[0].set_instance_shader_parameter("age", age)
		p[0].visible = p[0].position.distance_to(camera.position) > 0.6   # not inside the cockpit
	puffs = keep


func _live_place(node: Node3D, e, m: Dictionary) -> void:
	if node == null:
		return
	if e == null or (e[2] == 0 and e[0] != 1):
		node.visible = false
		return
	node.visible = true
	if node.has_meta("deep_ok"):
		_apply_deep(node, m, e[3], e[4])
	if e[0] == 1 and e[2] == 0:
		_make_corpse(node, m)
		return
	if node.has_meta("corpse"):                      # alive again: the mission was restarted
		node.remove_meta("corpse")
	# units (classes 1-3) and buildings set up in play (a deployed turret, a mine): the game's own height, already
	# real (no extra lift: a probe hovers by itself), less the game's draw offset of its class and type (RESSIM.RES:
	# 0.146 for a suit or a vehicle, 0.3 the mech, 0.117 to 0.667 probes and ships, 0 a building; a picture, as the
	# camera probe, drawn at its z)
	if (e[0] >= 1 and e[0] <= 3) or (e[0] == 4 and not node.has_meta("mission")):
		# A picture (0x29BE78) is projected from the entity's raw z: an anchored one (a probe's disc) has its anchor on
		# that point (_sprite_quad), any other its foot
		var f := 0.0
		if objects_ok and not TNObjects.is_sprite(objects.ref_for(e[0], e[1])):
			f = objects.draw_offset(e[0], e[1])
		var y: float = e[5] - f
		if node.has_meta("foot"):
			y += _ship_lift(node, m, e[3], e[4], e[6])
		node.set_meta("ez", y)
		node.set_meta("pkt", Vector2(e[3], e[4]))
		if node.has_meta("gait"):
			y = node.position.y                          # (a suit on its own steps: on the ground, _gait)
		elif node.has_meta("feet_off") and absf(float(node.get_meta("feet_off"))) < 0.5:
			y += float(node.get_meta("feet_off"))        # (a suit on the game's pose, none in this packet: on its feet
			# as in the last one, not up and down by the entity's draw offset)
		node.position = Vector3(e[3], y, e[4])
	elif e[0] == 0 and not node.has_meta("mission"):
		node.position = Vector3(e[3], e[5], e[4])        # decor made in play (a hit plant, rubble): the game's height
		# (a rock left 0.13 above the map's ground there)
	else:
		node.position = Vector3(e[3], TNData.height_at(m, e[3], e[4]) + float(node.get_meta("lift", 0.0)), e[4])
	if e[0] != 2 and not (e[0] == 4 and e[1] == MINE_TYPE):
		node.basis = Basis(Vector3.UP, -e[6])           # (a body tipped over is set back up)
		return
	# vehicles and mines pitch with the ground along their heading as the game draws them (its entity has only a
	# heading): no roll, no easing, worked out again on every draw
	node.basis = Basis(Vector3.UP, -e[6]) * Basis(Vector3(0, 0, 1),
			_ground_pitch(m, e[3], e[4], e[6], float(node.get_meta("half", _half_len(e[0], e[1])))))


# The game's pitch of a vehicle (and of a mine) on the ground (0x29dd64 of the English exe): atan2(ground ahead -
# ground behind, its length), the ground taken half its model's length ahead of and behind its origin along its
# heading. Positive: the nose up (a turn about its sideways axis, local Z: its length is local X).
func _ground_pitch(m: Dictionary, x: float, y: float, heading: float, half: float) -> float:
	if half <= 0.0:
		return 0.0
	var c := half * cos(heading)
	var s := half * sin(heading)
	return atan2(TNData.height_at(m, x + c, y + s) - TNData.height_at(m, x - c, y - s), 2.0 * half)


# Landed ships (class 3, types 8 to 14: the dropships, the shuttles, the recon aircraft) on a slope. The game draws
# them level at z - 0.667 (0x29B3AC, no pitch for class 3) and, drawing its objects over its ground (no depth
# test between the two), shows the whole ship even where its hull goes below the slope. Here the ground hides what is
# under it: on a steep pickup point half the dropship sank into the hill. Raised so: level as the game has it, by
# what the ground under its lowest part (the bottom quarter of its height, measured on the model; sampled at its
# corners, edges and middle) rises above the ground under its origin; on flat ground nothing changes.
const SHIP_FIRST := 8
const SHIP_LAST := 14


func _foot_of(mesh: Mesh) -> Array:
	var bb := mesh.get_aabb()
	var lo := bb.position.y
	var cut := lo + 0.25 * bb.size.y
	var r := Rect2()
	var first := true
	for s in mesh.get_surface_count():
		var v: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		for p in v:
			if p.y <= cut:
				if first:
					r = Rect2(p.x, p.z, 0.0, 0.0)
					first = false
				else:
					r = r.expand(Vector2(p.x, p.z))
	return [lo, r]


func _ship_lift(node: Node3D, m: Dictionary, x: float, y: float, heading: float) -> float:
	var ft: Array = node.get_meta("foot")
	var r: Rect2 = ft[1]
	var c := cos(-heading)
	var s := sin(-heading)
	var top := -INF
	for k in 9:
		var lx := r.position.x + r.size.x * 0.5 * float(k % 3)
		var lz := r.position.y + r.size.y * 0.5 * float(k / 3)
		# (local to world as Basis(UP, -heading) turns it: x' = x cos + z sin, z' = -x sin + z cos)
		top = maxf(top, TNData.height_at(m, x + lx * c + lz * s, y - lx * s + lz * c))
	# (measured from the ground under its origin, not from its hull: the game itself draws it 0.133 into flat ground,
	# z - 0.667 with z 0.533 above it, MISS31's shuttle and cruiser; that is kept)
	return maxf(0.0, top - TNData.height_at(m, x, y))


# Half the model's length by class and type, when its node has none (no model in the data: a box).
func _half_len(cls: int, sub: int) -> float:
	if cls == 4:
		return 0.0798 if sub == MINE_TYPE else 0.0
	return float(VEHICLE_HALF[sub]) if cls == 2 and sub >= 0 and sub < VEHICLE_HALF.size() else 0.0


func _process(delta: float) -> void:
	if not live:
		_oldschool_palette()
	if guest_win and look_off != Vector2.ZERO:
		if not (free_look or Input.is_physical_key_pressed(KEY_ALT)):
			look_off = look_off.move_toward(Vector2.ZERO, delta * 6.0)   # back to the suit's view in ~0.3 s
		camera.rotation = Vector3(pitch + look_off.y, yaw + look_off.x, 0)
	if hd_movie_box != null and hd_movie_box.visible and hd_movie.get_video_texture() != null:
		var vsz := hd_movie.get_video_texture().get_size()
		if vsz.y > 0:
			hd_movie_box.ratio = vsz.x / vsz.y           # the video at its own proportions, black around
	_sync_sun_half()
	_clouds_update()
	_sky_items_place()
	sky_root.position = camera.position
	if live:
		_live_update()
		_dust_update()
		_gait_update(delta)
		_waypoint_update(delta)
		if hud:
			_compass_update()
		sky_root.position = camera.position
		return
	if list.has_focus() and not look:
		return
	var b := camera.global_transform.basis
	var move := Vector3.ZERO
	if Input.is_physical_key_pressed(KEY_W):
		move -= b.z
	if Input.is_physical_key_pressed(KEY_S):
		move += b.z
	if Input.is_physical_key_pressed(KEY_A):
		move -= b.x
	if Input.is_physical_key_pressed(KEY_D):
		move += b.x
	if Input.is_physical_key_pressed(KEY_SPACE):
		move += Vector3.UP
	if Input.is_physical_key_pressed(KEY_CTRL):
		move -= Vector3.UP
	if move != Vector3.ZERO:
		var fast := 4.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0
		camera.position += move.normalized() * speed * fast * delta
