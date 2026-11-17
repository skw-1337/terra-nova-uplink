# Terra Nova Uplink: terrain, water, mission entities, named script zones, free camera.
extends Node3D

const TNData = preload("res://scripts/tn_data.gd")
const Terrain = preload("res://scripts/terrain.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
const SuitGait = preload("res://scripts/suit_gait.gd")
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
var live_ents := {}               # coop guest's map: the last live entities (index -> class, type, active, x, y, z, h),
                                  # but the shots and effects (classes 5 and 6: _live_units)
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
var zone_nodes := {}             # zone number -> its post (the mission editor moves them)
var editor: Node                 # the mission editor (map viewer, F6)
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
var live_gaits := {}          # game entity index -> its soldier's walk in the game (the bridge's GAIT, _gait_game)
var live_gaits_new := false
var live_lod := 272.0         # a unit's height in the game's pixels at 1 unit (the bridge's GAIT; TN+ HD 848 x 480: 272)
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
# Uplink's own colours on the game's cockpit, as on the co-op guest's (coop_hud.gd): the energy bar's leds and its "E"
# in orange where the game has its green ramp (palette 0x83 to 0x8B), and the whole parts of the armour indicator
# (the game's green, 0x84) in light blue; its damaged parts keep the game's yellow and red. Only inside those two
# places, which the bridge tells with the palette (their rectangles on the game's screen, live_bridge.py hud_places):
# nothing else that is green changes. TN_HUD_COLOURS=0: the game's colours.
var hud_colours := OS.get_environment("TN_HUD_COLOURS") != "0"
var hud_places := PackedByteArray()
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


# Uplink's clock for all it animates by itself (the units' easing, puffs, flashes, the effects' pictures): the
# engine's, less the time spent with the scene frozen (the photo mode, _photo_set): on leaving, everything goes on
# from where it stood. The shaders' time is the same (tn_time, set each frame: the water's waves freeze too).
# Everything in this file that times something reads _ticks(), never the engine's clock: the two are apart by
# clock_lag after a photo mode. (The engine's own is read only here, for the clouds' refresh and by the photo mode.)
var clock_lag := 0                 # msec spent frozen so far
var clock_stop := -1               # the engine's msec when the scene froze (-1: it runs)
var scene_t := 0.0                 # the shaders' seconds (as their TIME: back to 0 every hour)
var weather_t := 0.0               # the snow's and the rain's own (they may go on falling over a frozen scene)


func _ticks() -> int:
	return (clock_stop if clock_stop >= 0 else Time.get_ticks_msec()) - clock_lag


func _ticks_usec() -> int:
	return (clock_stop * 1000 if clock_stop >= 0 else Time.get_ticks_usec()) - clock_lag * 1000


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
	_extras()
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
	if not live and (OS.get_environment("TN_EDITOR") == "1" or "--editor" in args):
		editor = load("res://scripts/mission_editor.gd").new()   # the mission editor: an option, off unless asked for
		add_child(editor)
		status.text += "   F6 or the EDIT MISSION button: mission editor"
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
	if editor and not editor.allow_load(index):   # (unsaved changes in the mission editor: asked first)
		return
	var entry: Dictionary = missions[index]
	info.text = "Loading %s..." % entry["label"]
	await get_tree().process_frame
	await get_tree().process_frame
	if entry.get("gallery", false):
		_load_gallery()
		return
	var t0 := _ticks()
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
	snow_px.clear()
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
	live_gaits.clear()
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
	zone_nodes.clear()
	for z in mis["zones"]:
		zone_nodes[int(z.get("index", zone_nodes.size()))] = _add_zone(m, z)
	current = {"map": m, "mission": mis, "entry": entry}
	_sync_sun_half()
	_place_camera(m, mis)
	info.text = "%s\nmap %s (%s), %d objects, %d named zones, %d plants%s\nloaded in %.1f s" % [
		entry["label"], mis["map"], m["planet"], mis["entities"].size(), mis["zones"].size(), nveg, note,
		(_ticks() - t0) / 1000.0]
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
	sm.set_shader_parameter("cliffs", OS.get_environment("TN_FX_CLIFFS") == "1")   # (an extra: steep faces textured from the side)
	sm.set_shader_parameter("origin", origin)
	sm.set_shader_parameter("step_size", step)
	sm.set_shader_parameter("grid_n", float(grid["n"]))
	var rows: PackedFloat32Array = pl.get("rows", PackedFloat32Array())
	if rows.size() == 16:
		sm.set_shader_parameter("light_rows", rows)
	sm.set_shader_parameter("ground_light", Vector3(ground_light.r, ground_light.g, ground_light.b))
	var t0 := _ticks()
	sm.set_shader_parameter("relief", ImageTexture.create_from_image(_relief_image(grid["h"], grid["n"], step)))
	sm.set_shader_parameter("has_relief", true)
	print("relief %dx%d : %d ms" % [grid["n"], grid["n"], _ticks() - t0])
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
	if fx_cloud_shadows:                              # (an extra: the clouds' shadows on the ground, _cloud_cover)
		sm.set_shader_parameter("cloud_shadows", cloud_cover != null)
		if cloud_cover != null:
			sm.set_shader_parameter("cloud_cover", cloud_cover)
			sm.set_shader_parameter("cloud_sun", Vector4(sun_to.x, maxf(sun_to.y, 0.15), sun_to.z,
					sky_ref_y + 0.0478 * (float(mis_params.get("cloud_h", 1024)) - 8.0 * sky_ref_y)))


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
	if fx_stars and px > 0.0:                         # (an extra: sharp stars, sky.gdshader star_scale)
		# pixels of the picture (the old school's own, when it is on) per pixel of the game's star map (TAU / 4 / 512)
		var wide := _old_grid(old_sharp).x if oldschool_rect != null and oldschool_rect.visible else get_viewport().get_visible_rect().size.x
		sm.set_shader_parameter("star_scale", (TAU / 2048.0) / (2.0 / (px * maxf(wide, 1.0))))


func _clouds_update() -> void:
	if mis_params.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0        # (the engine's own: their size follows the camera in photo mode too)
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


# A suit's limbs for the pose loop (_pose_apply, _bones_long: run for every suit, every frame): its "soldier" parts as
# typed arrays, and what each limb was last given (its view, its cull margin) so that only what changes is sent on.
class SuitParts:
	var segs: Array[MeshInstance3D] = []
	var ja := PackedInt32Array()            # the limb's two joints
	var jb := PackedInt32Array()
	var chain := PackedInt32Array()         # its chain (the game's reference vector for its view)
	var blen := PackedFloat64Array()        # its sprite's pixels between the two joints
	var sizex := PackedFloat64Array()       # its sprite's width
	var long_lim := PackedFloat64Array()    # the bone length past which a pose is not drawn (_bones_long)
	var mirror := PackedByteArray()         # 1: a left limb, drawn mirrored
	var views9 := PackedByteArray()         # 1: a 9-view part (torso)
	var gv := PackedVector2Array()          # the view last given to the limb (limb.gdshader game_view)
	var margin := PackedFloat64Array()      # its cull margin, the same


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
	var sp := SuitParts.new()
	for part in parts:
		sp.segs.append(part[0])
		sp.ja.append(part[1])
		sp.jb.append(part[2])
		sp.chain.append(part[6])
		sp.blen.append(part[3])
		sp.sizex.append(part[4])
		sp.long_lim.append(BONE_LONG * float(part[3]) / 256.0 * float(part[5]))
		sp.mirror.append(1 if float((part[0] as MeshInstance3D).get_instance_shader_parameter("mirror")) > 0.5 else 0)
		var pm := (part[0] as MeshInstance3D).material_override as ShaderMaterial
		sp.views9.append(1 if pm != null and int(pm.get_shader_parameter("view_count")) < 16 else 0)
		sp.gv.append(Vector2(-9.0, -9.0))       # (none given yet)
		sp.margin.append(-1.0)
	holder.set_meta("sp", sp)
	pose_pending.erase(holder)
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
# (right, up, forward), a turn of the game's: the same cross products; refs[0] = -1 when it is upside down), in
# _pose_apply; without refs every limb takes the view of its front (limb.gdshader).
# The eye in the suit's frame, where it is now (null without refs).
func _pose_eye(holder: Node3D, refs: Array) -> Variant:
	if refs.size() != 6:
		return null
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return null
	var e := _node_axes(holder.global_transform.affine_inverse() * cam.global_position)
	e.y /= SUIT_SQUASH
	return e


# Poses given but not yet put on the limbs (_pose_later): holder -> [joints, refs, eye]. Live, a suit is given the
# game's pose (_live_units) and, right after, its eased one (_unit_smooth): the first one never showed and cost as
# much as the second. It now waits here: thrown away when another pose takes its place, put on the limbs otherwise
# (_pose_flush_all, before anything reads or draws them).
var pose_pending := {}


# Puts a soldier's limbs on its 16 joints, (right, up, forward) from the ground under it: its pose at load, then
# in live mode the game's own joints every frame (walking, arms, aiming). Returns the highest joint.
func _pose_soldier(holder: Node3D, p: Array, knees_given := false) -> float:
	if holder.has_meta("leg_rest") and not holder.has_meta("corpse") and not knees_given:
		p = _leg_lengths(p, holder.get_meta("leg_rest"))
	# last guard: a bone far longer than its limb (joints the game left where it last drew the suit) is not drawn, the
	# suit keeps its previous pose (each sprite is scaled by its bone: such a limb came out several times too big)
	if _bones_long(holder, p):
		_pose_flush(holder)
		return -1.0
	pose_pending.erase(holder)
	var refs: Array = holder.get_meta("refs", [])
	holder.remove_meta("refs")
	return _pose_apply(holder, p, refs, _pose_eye(holder, refs))


# The same, put on the limbs later (_pose_flush_all) unless another pose comes first.
func _pose_later(holder: Node3D, p: Array, knees_given := false) -> void:
	if holder.has_meta("leg_rest") and not holder.has_meta("corpse") and not knees_given:
		p = _leg_lengths(p, holder.get_meta("leg_rest"))
	if _bones_long(holder, p):
		_pose_flush(holder)
		return
	var refs: Array = holder.get_meta("refs", [])
	holder.remove_meta("refs")
	pose_pending[holder] = [p, refs, _pose_eye(holder, refs)]


func _pose_flush(holder: Node3D) -> void:
	if pose_pending.is_empty():
		return
	var pd = pose_pending.get(holder)
	if pd != null:
		pose_pending.erase(holder)
		_pose_apply(holder, pd[0], pd[1], pd[2])


func _pose_flush_all() -> void:
	if pose_pending.is_empty():
		return
	for holder in pose_pending:
		if is_instance_valid(holder):
			var pd: Array = pose_pending[holder]
			_pose_apply(holder, pd[0], pd[1], pd[2])
	pose_pending.clear()


func _pose_apply(holder: Node3D, p: Array, refs: Array, eye) -> float:
	var sp: SuitParts = holder.get_meta("sp")
	var segs := sp.segs
	var ja := sp.ja
	var jb := sp.jb
	var chain := sp.chain
	var blen := sp.blen
	var sizex := sp.sizex
	var mirror := sp.mirror
	var views9 := sp.views9
	var gvl := sp.gv
	var marg := sp.margin
	var changed := false
	var top := 0.0
	# the body's right, which sets each limb's front (the views turn around the bone): the hips' line for the legs
	# and feet, the shoulders' for the torso and arms (joints 6 / 7 hips, 10 / 11 shoulders). Front = right x bone:
	# a leg hanging down faces forward, a foot (the same leg turned forward at the ankle) faces up
	var d_hips: Vector3 = p[7] - p[6]
	var d_top: Vector3 = p[11] - p[10]
	var r_hips := Vector3(d_hips.z, d_hips.y, d_hips.x)      # (pose axes -> node axes: _node_axes)
	var r_top := Vector3(d_top.z, d_top.y, d_top.x)
	# live, a pose the game drew: each limb's view picked as the game does, from its chain's reference vector (above);
	# the suit's own steps and the map viewer: from the limb's front below (limb.gdshader)
	var views: bool = eye != null
	var e := Vector3.ZERO
	var hand := 0.0
	if views:
		e = eye
		hand = -float(refs[0])
	for i in segs.size():
		var ai := ja[i]
		var bi := jb[i]
		var a: Vector3 = p[ai]
		var b: Vector3 = p[bi]
		var ab := b - a
		var gview := Vector2(-1.0, 1.0)
		if views and chain[i] < 5:
			var v := a - e
			var nn := v.cross(ab)
			var rv: Vector3 = refs[1 + chain[i]]
			var c := 0.0 if nn.length() < 1e-6 else hand * nn.normalized().dot(rv)
			var q := asin(floorf(clampf(c, -1.0, 1.0) * 64.0) / 64.0) / (PI / 2.0)
			var psi := 4.0 - 4.0 * q if v.dot(rv) > 0.0 else 12.0 + 4.0 * q
			var vw := int(floorf(psi + 0.5)) & 15
			var f := 1.0
			if mirror[i] != 0:
				vw = (16 - vw) & 15
				f = -1.0
			if views9[i] != 0 and vw > 8:
				vw = 16 - vw
				f = -f
			gview = Vector2(vw, f)
		var ga := Vector3(a.z, a.y, a.x) * Vector3(1.0, SUIT_SQUASH, 1.0)
		var gb := Vector3(b.z, b.y, b.x) * Vector3(1.0, SUIT_SQUASH, 1.0)
		var dir := Vector3(ab.z, ab.y, ab.x)             # (scale from the true bone)
		var dl := dir.length()
		var sc: float = maxf(dl, 0.001) / blen[i]
		var yn := dir.normalized() if dl > 0.0001 else Vector3.DOWN
		var r: Vector3 = r_hips if maxi(ai, bi) <= 8 else r_top
		var side := r - yn * r.dot(yn)
		if side.length() < 0.2 * r.length():             # bone along the body's right (arm held out sideways):
			side = (Vector3.UP - yn * yn.y) * signf(r.dot(yn))   # its front is still the body's forward
		side = side.normalized()
		var xn := side.cross(yn).normalized()
		var seg := segs[i]
		# across the bone: the game's fixed 1/256 unit a sprite pixel (limb.gdshader), not the bone's scale
		var xf := Transform3D(Basis(xn * LIMB_WPX, yn * sc, xn.cross(yn) * LIMB_WPX), ga)
		if seg.transform != xf:
			seg.transform = xf
		if gvl[i] != gview:
			seg.set_instance_shader_parameter("game_view", gview)
			gvl[i] = gview
			changed = true
		var cm := maxf(sizex[i] * LIMB_WPX, blen[i] * sc)
		if marg[i] != cm:
			seg.extra_cull_margin = cm
			marg[i] = cm
			changed = true
		top = maxf(top, maxf(ga.y, gb.y))
	if changed:
		sp.gv = gvl
		sp.margin = marg
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
	var q := p                                       # (copied when a knee is put back: most poses come as they are)
	var copied := false
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
		if not copied:
			q = p.duplicate()
			copied = true
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
const GAIT_STALE_MOVING := 100                 # the same for a suit that moves (it slides, its legs still, meanwhile; a
										# suit the game draws has a pose under 40 ms old 98.7 % of the time)
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
	var sp: SuitParts = node.get_meta("sp")
	var ja := sp.ja
	var jb := sp.jb
	var lim := sp.long_lim                           # (BONE_LONG x the sprite's pixels / 256 x the suit's size)
	for i in ja.size():
		if ((p[jb[i]] as Vector3) - (p[ja[i]] as Vector3)).length() > lim[i]:
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
			now - int(node.get_meta("jt", -100000)) > _gait_stale(node, now) or now - int(node.get_meta("jt0", -100000)) < GAIT_BACK


# how long without a pose from the game before a suit takes its own steps: sooner when it moves (the game's walk
# goes on from its last pose, _gait_game)
func _gait_stale(node: Node3D, now: int) -> int:
	if game_gait and node.has_meta("gk") and _unit_velocity(node, now).length() > 0.3:
		return GAIT_STALE_MOVING
	return GAIT_STALE


# A soldier's moves of the last 90 ms (each packet that moves it), for its speed whether the game poses it or not:
# the walk taken over from the game's pose needs it at once (_gait_game), and a suit that moves leaves the game's
# pose sooner (_gait_stale). No move for 120 ms: stopped (a late picture of the game: not yet).
func _note_move(node: Node3D, p2: Vector2) -> void:
	var now := _ticks()
	if not node.has_meta("mv"):
		node.set_meta("mv", [[now, p2]])
		return
	var mv: Array = node.get_meta("mv")
	if (mv[-1][1] as Vector2) == p2:
		return
	if (mv[-1][1] as Vector2).distance_to(p2) > 1.0 or now - int(mv[-1][0]) > 120:
		mv.clear()                                   # (put elsewhere, or moving again)
	mv.append([now, p2])
	while mv.size() > 2 and now - int(mv[1][0]) >= 90:   # (150 ms: a suit slowing down or speeding up was 0.3 units a
		mv.pop_front()                                   # second off, its steps a pace too long or short)


func _unit_velocity(node: Node3D, now: int) -> Vector2:
	var mv: Array = node.get_meta("mv", [])
	if mv.size() < 2 or now - int(mv[-1][0]) > 120:
		return Vector2.ZERO
	var v: Vector2 = ((mv[-1][1] as Vector2) - (mv[0][1] as Vector2)) / maxf((int(mv[-1][0]) - int(mv[0][0])) / 1000.0, 0.001)
	return v if v.length() < 20.0 else Vector2.ZERO


# every frame (after the game's state): the suits walking on their own steps take theirs
func _gait_update(dt: float) -> void:
	if current.is_empty() or dt <= 0.0:
		return
	var m: Dictionary = current["map"]
	var now := _ticks()
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
		if game_gait and node.has_meta("gk"):
			_gait_game(node, m, minf(acc, 0.25))
		else:
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
func _pose_suit(node: Node3D, q: Array, own: bool, later := false) -> void:
	var now := _ticks()
	if bool(node.get_meta("own", own)) != own and node.has_meta("pose_last"):
		var last: Array = node.get_meta("pose_last")
		node.set_meta("fade_t", now)
		node.set_meta("fade_from", last)
		if node.has_meta("fade_off"):
			node.remove_meta("fade_off")
		if own and node.has_meta("took") and last.size() == q.size():
			# its steps going on from the game's pose (_gait_game): what differs at the start fades out on top of the
			# steps. (Faded from the pose itself, which stands still, the legs were held back a moment, then sprang
			# forward: joints at 6 units a second for 2 on the game's pose)
			var off := []
			for j in q.size():
				off.append((last[j] as Vector3) - (q[j] as Vector3))
			node.set_meta("fade_off", off)
	node.set_meta("own", own)
	if own and node.has_meta("refs_eased"):
		node.remove_meta("refs_eased")               # (its own steps: the game's reference vectors no longer hold)
	var game := q                                    # (the pose given, before the fade)
	var wf := 1.0
	if node.has_meta("fade_t"):
		var w := clampf((now - int(node.get_meta("fade_t"))) / POSE_FADE, 0.0, 1.0)
		wf = w * w * (3.0 - 2.0 * w)
		if w >= 1.0:
			node.remove_meta("fade_t")
			node.remove_meta("fade_from")
			if node.has_meta("fade_off"):
				node.remove_meta("fade_off")
		else:
			w = w * w * (3.0 - 2.0 * w)
			var b := []
			if node.has_meta("fade_off"):
				var off: Array = node.get_meta("fade_off")
				for j in q.size():
					b.append((q[j] as Vector3) + (off[j] as Vector3) * (1.0 - w))
			else:
				var from: Array = node.get_meta("fade_from")
				for j in q.size():
					b.append((from[j] as Vector3).lerp(q[j], w))
			q = b
	node.set_meta("pose_last", q)
	if own or not node.has_meta("leg_rest") or node.has_meta("corpse"):
		if later:
			_pose_later(node, q)
		else:
			_pose_soldier(node, q)
		return
	# the game's pose: its knees where the game has them, the thigh and shin stretched or squeezed between the hip and
	# the ankle as it draws them (put back at the suit's standing lengths, _leg_lengths, a crouching suit's knees
	# stuck out); from its own steps, from those knees to the game's over the fade
	var g := q
	if wf < 1.0:
		g = q.duplicate()
		var solved := _leg_lengths(q, node.get_meta("leg_rest"))
		for k in [4, 5]:
			g[k] = (solved[k] as Vector3).lerp(game[k], wf)
	if later:
		_pose_later(node, g, true)
	else:
		_pose_soldier(node, g, true)


# where the suit's joints are drawn now (world), from its limbs
func _joints_now(node: Node3D) -> Dictionary:
	_pose_flush(node)
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
	var now := _ticks()
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


# A suit on its own steps, the game's own walk (suit_gait.gd: its code ported) run on the suit's moves, with the
# soldier's values from its game record (the bridge's GAIT: bones, paces, stance): the same stride, cadence, knees,
# arms and lean as the game gives a suit it draws. (The steps above, _gait, were Uplink's own: a fixed cadence and
# stride, straighter legs, arms eased after the legs; kept for a bridge that sends no GAIT, and TN_GAIT=old.)
# The suit's speed from its moves of the last 90 ms (_unit_velocity; the game's: from one picture to the next; here
# they come eased and by packets). Taken over from a pose of the game (it stopped drawing the suit): the walk goes on from that pose,
# the feet where they are, a foot in the air carried on (take_over), under the poses' cross-fade (_pose_suit).
var game_gait := OS.get_environment("TN_GAIT") != "old"
var gait_full := OS.get_environment("TN_GAIT_DETAIL") == "full"


func _gait_game(node: Node3D, m: Dictionary, dt: float) -> void:
	var gk: Array = node.get_meta("gk")
	var now := _ticks()
	var st: Dictionary = node.get_meta("gait", {})
	var sg: RefCounted = st.get("sg")
	var fresh := sg == null
	var ground := TNData.height_at(m, node.position.x, node.position.z)
	if fresh:
		sg = SuitGait.new()
		sg.ground = func(x: float, y: float) -> float: return TNData.height_at(m, x, y)
		st = {"sg": sg, "hist": [], "vel": _unit_velocity(node, now), "arms": [0.0, 0.0], "t": 0.0, "gk": null}
		node.set_meta("gait", st)
	if not is_same(st["gk"], gk):
		st["gk"] = gk
		sg.setup(gk[0], gk[1], gk[2], node.has_meta("player_body"))
	# as detailed as the game draws a suit of that size on its screen (suit_gait.gd detail): far ones with stiff legs
	# and still arms, as the suits it poses beside them (TN_GAIT_DETAIL=full: always all of it)
	if gait_full:
		sg.detail = 99
	else:
		var far := maxf(node.global_position.distance_to(camera.global_position), 0.5)
		sg.detail = roundi(live_lod * (float(sg.torso) + float(sg.legtot)) / far)
	var v2 := _unit_velocity(node, now)
	var vel: Vector2 = (st["vel"] as Vector2).lerp(v2, 1.0 - exp(-dt * 30.0))
	if v2 == Vector2.ZERO and vel.length() < 0.02:
		vel = Vector2.ZERO
	st["vel"] = vel
	var t: float = float(st["t"]) + dt
	st["t"] = t
	var h := -node.rotation.y
	var ez: float = st.get("ez", node.get_meta("ez", ground))
	if fresh and not bool(node.get_meta("own", true)) and now - int(node.get_meta("jt", -100000)) < 1500:
		var jn := _joints_now(node)                      # the game's pose as it is drawn: the walk goes on from it
		if jn.size() == 16:
			var arr := []
			for j in 16:
				var w: Vector3 = jn[j]
				arr.append(Vector3(w.x, w.z, w.y))
			sg.take_over(arr, h, t - dt, vel, gk[3], gk[4], gk[5])
			sg.aim = (gk[6] as PackedFloat32Array).duplicate()   # (its arms as the game had them, at once)
			node.set_meta("took", true)                  # (what differs fades out on top of the steps, _pose_suit)
	if not fresh and node.has_meta("took"):
		node.remove_meta("took")
	# the arms' aim, eased (it comes 4 times a second): turn and pitch by the shortest way, the share straight
	var am: PackedFloat32Array = sg.aim
	var ak := 1.0 - exp(-dt * 12.0)
	for a in 6:
		am[a] = lerpf(am[a], gk[6][a], ak) if a % 3 == 2 else lerp_angle(am[a], gk[6][a], ak)
	sg.aim = am
	sg.stand = gk[7]
	sg.step(node.position.x, node.position.z, ez + float(sg.zoff), h, dt, t, gk[3], gk[4], gk[5], vel)
	sg.pose()
	# the suit on its lowest toe (as with the game's poses), the joints from there (right, up, forward)
	var jj: Array[Vector3] = sg.J
	var base := minf(jj[0].z, jj[1].z)
	if fresh and absf(node.position.y - base) < 1.0:
		node.set_meta("y_off", [node.position.y - base, now])   # (from the game's pose: its height eased, _y_ease)
	node.set_meta("gait_y", base)
	var xf := node.global_transform
	xf.origin.y = base
	var inv := xf.affine_inverse()
	var q := []
	for j in 16:
		var l: Vector3 = inv * Vector3(jj[j].x, jj[j].z, jj[j].y)
		q.append(Vector3(l.z, l.y / SUIT_SQUASH, l.x))
	node.position.y = base + _y_ease(node, now)
	# each limb's view picked as the game does, from the reference vectors its walk gives (_game_views)
	var rf: Array = [-1.0]
	for v in sg.refs():
		var lv: Vector3 = inv.basis * Vector3(v.x, v.z, v.y)
		rf.append(Vector3(lv.z, lv.y, lv.x))
	node.set_meta("refs", rf)
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
		_mech_ir(part, 877 + int(sg[2]))
		holder.add_child(part)
		parts.append([part, sg[0], sg[1]])
	holder.set_meta("mech", parts)
	return _pose_mech(holder, p) + 0.1


# Infrared: the walker is drawn by the soldier draw, which swaps the view's remap for table 62 around the whole unit
# (0x29C96E), its 3D parts included: their materials' twins with that table (live, model.gdshader).
func _mech_ir(part: MeshInstance3D, rid: int) -> void:
	if not live or part.mesh == null:
		return
	for s in part.mesh.get_surface_count():
		var sm := part.mesh.surface_get_material(s) as ShaderMaterial
		if sm == null or sm.shader != TNObjects.MODEL_SHADER or not sm.get_shader_parameter("has_ir"):
			continue
		var k := "mechir%d/%d/%s" % [rid, s, pal_key]
		if not mats.has(k):
			var tw := sm.duplicate() as ShaderMaterial
			tw.set_shader_parameter("ir_table", 3)
			mats[k] = tw
		part.set_surface_override_material(s, mats[k])


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
	if live and cur_ir.has(62) and objects_ok:      # infrared: the suits and their pieces through table 62
		var ti := objects.limb_ir(suit, part, pal_key, 62, cur_ir[62])
		if ti != null:
			sm.set_shader_parameter("views_ir", ti)
			sm.set_shader_parameter("has_ir", true)
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


func _add_zone(m: Dictionary, z: Dictionary) -> MeshInstance3D:
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
	return mi


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
			KEY_F6:
				if editor:
					editor.toggle()


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
	cloud_cover = null
	if sk.is_empty():
		var sm := ProceduralSkyMaterial.new()
		sm.sky_top_color = Color(0.32, 0.5, 0.78)
		sm.sky_horizon_color = Color(0.72, 0.78, 0.86)
		sm.ground_horizon_color = Color(0.72, 0.78, 0.86)
		env.sky.sky_material = sm
		env.fog_light_color = Color(0.7, 0.76, 0.84)
		_haze_globals()
		for gm in ground_mats:
			gm.set_shader_parameter("cloud_shadows", false)
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
	cloud_cover = _cloud_cover(sk["clouds"]) if fx_cloud_shadows else null
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
uniform vec4 energy = vec4(0.0);   // the energy bar on the game's screen: x0, y0, x1, y1 (none: zeros)
uniform vec4 armour = vec4(0.0);   // the armour indicator
const vec3 LIT = vec3(255.0, 165.0, 40.0) / 255.0;
const vec3 DIM = vec3(170.0, 95.0, 25.0) / 255.0;
const vec3 BLUE = vec3(135.0, 200.0, 255.0) / 255.0;
bool inside(vec2 p, vec4 r) { return p.x >= r.x && p.x < r.z && p.y >= r.y && p.y < r.w; }
void fragment() {
	vec4 t = texture(TEXTURE, UV);
	float i = floor(t.r * 255.0 + 0.5);
	vec3 c = texture(pal, vec2((i + 0.5) / 256.0, 0.5)).rgb;
	vec2 p = UV * vec2(320.0, 400.0);
	if (i >= 131.0 && i <= 139.0 && energy.z > energy.x) {
		if (inside(p, energy)) {            // the leds, from the brightest (0x83) to the dimmest (0x8B)
			c = mix(LIT, DIM, (i - 131.0) / 8.0);
		} else if (inside(p, vec4(energy.x - 9.0, energy.y - 6.0, energy.x - 1.0, energy.y + 8.0))) {
			c = mix(LIT, DIM, clamp((i - 136.0) / 3.0, 0.0, 1.0));   // the "E" left of them: its two greens, 0x88 and 0x8B
		}
	}
	if (i == 132.0 && inside(p, armour)) {
		c = BLUE;
	}
	COLOR = vec4(c, t.g);
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
	var now := _ticks()
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
			game_fade_t = _ticks()
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
					play_cur_t = _ticks()
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
			var screen := pk[7] == 1
			if screen and menu_frame.x < 640 and ((photo_on and photo_freeze) or Time.get_ticks_msec() - photo_end_t < 1500):
				screen = false                              # (the mission paused for the photo mode, or just resumed)
			_set_menu_mode(screen)
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
		var places := last_pal.slice(15 + 768, 15 + 768 + 16)
		if hud_colours and places.size() == 16 and places != hud_places:
			hud_places = places
			var m := hud_rect.material as ShaderMaterial
			m.set_shader_parameter("energy", Vector4(places.decode_s16(0), places.decode_s16(2), places.decode_s16(4), places.decode_s16(6)))
			m.set_shader_parameter("armour", Vector4(places.decode_s16(8), places.decode_s16(10), places.decode_s16(12), places.decode_s16(14)))
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
	var now := _ticks()
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


# ------------------------------------------------------------------ the order wheel
# Squad orders on one button (the launcher's "Order wheel": TN_ORDER_WHEEL = 1; off unless asked). The button is the
# middle one unless the player chose another (TN_ORDER_KEY: MID, M4, M5, or a key as TN+ writes its own, a PC scancode
# in hex after SHIFT+, CTRL+ or ALT+ if any); with the wheel on it is Uplink's, no longer one of TN+'s second binds.
# A short press: the obvious order at once (an enemy under the crosshair: attack it; the ground: go there). Held: the
# wheel opens on the middle of the view (order_wheel.gd), nothing picked; the mouse then picks a pane instead of
# turning the view, the mouse wheel changes who gets the order (the entire squad, then each squadmate), let go on a
# pane: sent; let go in the middle, or the right button: nothing. What is aimed at is kept from the press: the enemy
# nearest the crosshair (those the bridge names, 'ORDS': the game's units of another side, in sight), else the point
# of the ground under it. The bridge gives the order to the game with the game's own keys (live_bridge.py 'O',
# orders.py) and says whether it took it ('ORDR'). Not on a game screen, not without a squad, not for a coop guest.
const OrderWheel = preload("res://scripts/order_wheel.gd")
const LGRes = preload("res://scripts/lgres.gd")
const ORDER_TAP_MS := 200                # held less: the obvious order, no wheel
const ORDER_SHOW_MS := 2000              # the marker and the line stay that long after an order
const ORDER_DEAD := 48.0                 # the hand within that of where it was (pixels of a 1080-row window): no pane
const ORDER_REACH := 150.0               # ... and it counts no further than that (a quick way back)
var order_on := OS.get_environment("TN_ORDER_WHEEL") == "1"
var order_key := _order_key()            # [mouse button (0: a key), physical key, modifiers]
var order_state := 0                     # 0 nothing, 1 the button is down (wheel not open yet), 2 the wheel, 3 cancelled
var order_t := 0                         # when the button went down
var order_ptr := Vector2.ZERO            # how far the hand went since
var order_aim := {}                      # what was aimed at then: "ent" (-1: none), "point" (game x, y; null: none)
var order_who := 0                       # 0 the entire squad, else the place in order_mates + 1
var order_mates := []                    # the squadmates, from the bridge: [the game's F key number, entity, pilot]
var order_can := false                   # the bridge: there is a squad to give orders to
var order_lock := 0                      # the player's locked target (0: none)
var order_enemies := PackedInt32Array()  # the entities an attack can be ordered on
var order_news := -100000                # when the bridge last said so
var order_n := 0                         # the last order's number (the bridge answers with it)
var order_rmb := false                   # the right button that cancelled is still down (its release is not the game's)
var order_mouse := Vector2.ZERO          # where the mouse last was in the window (the cursor mode's aim)
var order_mark := {}                     # the last order's target, shown until order_mark_end
var order_mark_end := 0
var order_line := ""                     # ... and its line
var order_line_bad := false
var order_wheel: OrderWheel
var order_names := PackedStringArray()   # the pilots' names (RESGAME.RES 364: the COMM panel's)
var order_names_read := false


static func _order_key() -> Array:
	var spec := OS.get_environment("TN_ORDER_KEY").strip_edges().to_upper()
	var b: int = {"": MOUSE_BUTTON_MIDDLE, "MID": MOUSE_BUTTON_MIDDLE, "M4": MOUSE_BUTTON_XBUTTON1, "M5": MOUSE_BUTTON_XBUTTON2}.get(spec, 0)
	if b != 0:
		return [b, KEY_NONE, 0]
	var k := _own_key(spec)
	return [0, k[0], k[1]] if not k.is_empty() else [MOUSE_BUTTON_MIDDLE, KEY_NONE, 0]


# an order can be given now: in a mission, its map loaded, with a squad (the bridge's news, fresh), the mouse not
# dragging a map
func _order_ready() -> bool:
	if not (order_on and play and play_started and not menu_mode and not guest_win and not play_hold and order_can) \
			or current.is_empty() or _ticks() - order_news >= 1500:
		return false
	# (the mission's own map is the one loaded: the aim is taken on its ground)
	return live_mis_name == "" or str(current["entry"]["file"]).get_file().to_upper() == live_mis_name


# the bridge's 'ORDS': a squad to order (bit 0), its count, the player's lock, three squadmates (in use, entity,
# pilot), then the entities that can be attacked
func _order_status(q: PackedByteArray) -> void:
	if q.size() < 22:
		return
	order_news = _ticks()
	order_can = q[4] & 1 == 1
	order_lock = q.decode_u16(6)
	order_mates.clear()
	for k in 3:
		if q[8 + 4 * k] != 0:
			order_mates.append([k + 1, q.decode_u16(9 + 4 * k), q[11 + 4 * k]])
	var n := mini(q.decode_u16(20), (q.size() - 22) / 2)
	order_enemies.resize(n)
	for i in n:
		order_enemies[i] = q.decode_u16(22 + 2 * i)


# the bridge's 'ORDR': the last order's number, 0 if the game took it
func _order_result(q: PackedByteArray) -> void:
	if q.size() >= 8 and q[4] == order_n and q[5] != 0:
		order_line = "ORDER NOT SENT"
		order_line_bad = true
		order_mark = {}
		order_mark_end = _ticks() + ORDER_SHOW_MS


func _order_name(mate: Array) -> String:
	if not order_names_read:
		order_names_read = true
		var res = LGRes.open(data.data_dir().path_join("RESGAME.RES"))
		if res and res.has(364):
			order_names = res.strings(364)
	var pilot: int = mate[2]
	if pilot < 33 and pilot < order_names.size() and order_names[pilot].strip_edges() != "":
		return order_names[pilot].strip_edges().to_upper()
	return "SQUADMATE %d" % int(mate[0])


func _order_who_name() -> String:
	if order_who <= 0 or order_who > order_mates.size():
		return "ENTIRE SQUAD"
	return _order_name(order_mates[order_who - 1])


# The ray of the view through a pixel of the window, and the pixel a point of the world is seen at. Not Camera3D's
# own (project_ray_normal, unproject_position): with the HUD's camera (_hud_camera: a frustum as wide as the window,
# its centre where the game's 3D window has it) they take the view's centre for the window's and the frustum's size
# for its height (measured: a point seen 512 pixels left of the middle was given 288 pixels left of it).
func _order_ray(at: Vector2) -> Vector3:
	var vs := get_viewport().get_visible_rect().size
	if camera.projection != Camera3D.PROJECTION_FRUSTUM:
		return camera.project_ray_normal(at)
	var f := vs.x * 0.5 / tan(deg_to_rad(camera.fov) * 0.5)
	var yc := vs.y * 0.5 + camera.frustum_offset.y / camera.size * vs.x
	return (camera.global_transform.basis * Vector3(at.x - vs.x * 0.5, yc - at.y, -f)).normalized()


func _order_pixel(p: Vector3) -> Vector2:
	if camera.projection != Camera3D.PROJECTION_FRUSTUM:
		return camera.unproject_position(p)
	var vs := get_viewport().get_visible_rect().size
	var l := camera.global_transform.affine_inverse() * p
	var f := vs.x * 0.5 / tan(deg_to_rad(camera.fov) * 0.5)
	var yc := vs.y * 0.5 + camera.frustum_offset.y / camera.size * vs.x
	return Vector2(vs.x * 0.5 + l.x / maxf(-l.z, 0.001) * f, yc - l.y / maxf(-l.z, 0.001) * f)


# nothing of the ground between the eye and a unit (it is not ordered through a hill)
func _order_sight(m: Dictionary, from: Vector3, to: Vector3) -> bool:
	var n := clampi(int(from.distance_to(to) * 2.0), 8, 96)
	for i in range(1, n):
		var q := from.lerp(to, float(i) / n)
		if TNData.height_at(m, q.x, q.z) > q.y + 0.3:
			return false
	return true


# what the player aims at: the crosshair (the look mode; the game's cursor on the 3D view in the cursor mode); with
# the game's map in the HUD, what its cursor is on there (_map_pick)
func _order_pick() -> Dictionary:
	var vs := get_viewport().get_visible_rect().size
	var at := (Vector2(_cross_pixel()) + Vector2(0.5, 0.5)) / Vector2(320.0, 400.0) * vs
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		if hud_win.size.y > 0 and hud_win.has_point(_play_game_pos(order_mouse)):
			at = order_mouse
	if _map_on():                                          # (the cursor's, wherever it is: off the map, nothing)
		var on_map := {} if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED else _map_pick(order_mouse)
		if on_map.is_empty():
			return {"ent": -1, "point": null}
		order_centre = order_mouse                         # (the wheel opens there)
		return on_map
	var m: Dictionary = current["map"]
	var from := camera.global_position
	var dir := _order_ray(at)
	var ent := -1
	var best := 1.0
	for id in order_enemies:                               # the enemy nearest the ray, within 1.6 degrees or its own size
		var e = live_ents.get(id)
		if e == null or int(e[2]) & 1 == 0:
			continue
		var p := Vector3(e[3], e[5] + 0.2, e[4])
		var d := from.distance_to(p)
		if d < 0.3:
			continue
		var r := dir.angle_to(p - from) / maxf(deg_to_rad(1.6), atan(0.7 / d))
		if r < best and _order_sight(m, from, p + Vector3(0, 0.3, 0)):   # (its head in sight is enough)
			best = r
			ent = id
	var point = null                                       # the ground under the ray, inside the map
	var t := 0.0
	while t < 300.0 and dir.y < 0.3:
		var step := maxf(0.25, t * 0.02)
		var q := from + dir * (t + step)
		if q.x < 0.0 or q.z < 0.0 or q.x >= 512.0 or q.z >= 512.0:
			break
		if q.y <= TNData.height_at(m, q.x, q.z):
			var lo := t
			var hi := t + step
			for i in 14:
				var mid := (lo + hi) * 0.5
				var c := from + dir * mid
				if c.y <= TNData.height_at(m, c.x, c.z):
					hi = mid
				else:
					lo = mid
			q = from + dir * hi
			if q.x >= 10.0 and q.z >= 10.0 and q.x <= 502.0 and q.z <= 502.0:
				point = Vector2(q.x, q.z)
			break
		t += step
	return {"ent": ent, "point": point}


# where an order of that kind would go, of what is aimed at: [1, the ground's point] or [2, the entity], [0] nothing
func _order_target(order: int) -> Array:
	var ent: int = order_aim.get("ent", -1)
	var point = order_aim.get("point")
	if order == 1:                                         # move there: the ground, else where the enemy stands
		if point != null:
			return [1, point]
		var e = live_ents.get(ent)
		return [1, Vector2(e[3], e[4])] if e != null else [0]
	if ent >= 0:
		return [2, ent]
	if order == 0:                                         # attack with nothing aimed at: the player's own lock
		return [2, order_lock] if order_lock != 0 else [0]
	return [1, point] if point != null else [0]


# the order's button, down or up
func _order_button(down: bool) -> void:
	if down:
		if order_state != 0 or not _order_ready():
			return
		order_centre = null
		order_aim = _order_pick()
		order_t = _ticks()
		order_ptr = Vector2.ZERO
		order_who = 0
		order_state = 1
		return
	var was := order_state
	order_state = 0
	if was == 1:                                           # a short press: the obvious order
		if int(order_aim.get("ent", -1)) >= 0:
			_order_send(0, 0)
		elif order_aim.get("point") != null:
			_order_send(1, 0)
	elif was == 2:
		var pane := OrderWheel.pane_at(order_ptr, ORDER_DEAD * _order_scale())
		if pane >= 0 and not _order_off().has(pane):
			_order_send(pane, order_who)


func _order_scale() -> float:
	return get_viewport().get_visible_rect().size.y / 1080.0


# the panes that cannot be picked now
func _order_off() -> Dictionary:
	var off := {}
	if _order_target(0)[0] == 0:
		off[0] = "NO TARGET"
	if _order_target(1)[0] == 0:
		off[1] = "NO GROUND"
	return off


# the mouse wheel while the button is held: who gets the order
func _order_turn(step: int) -> void:
	order_state = 2                                        # (the wheel at once: who is written under it)
	order_who = posmod(order_who + step, order_mates.size() + 1)


func _order_cancel() -> void:
	if order_state != 0:
		order_state = 3                                    # (until the button is let go)


func _order_send(order: int, who: int) -> void:
	var tg := _order_target(order)
	var kind := 0
	var ent := 0
	var pt := Vector2.ZERO
	if order == 0 and int(order_aim.get("ent", -1)) >= 0:
		kind = 1
		ent = int(order_aim["ent"])
	elif order == 1:
		if tg[0] == 0:
			return
		kind = 2
		pt = tg[1]
	elif order == 0 and tg[0] == 0:
		return
	var mate := 0
	var to := "ENTIRE SQUAD"
	if who > 0 and who <= order_mates.size():
		mate = int(order_mates[who - 1][0])
		to = _order_name(order_mates[who - 1])
	order_n = (order_n + 1) & 0xFF
	var b := PackedByteArray()
	b.resize(15)
	b[0] = 0x4F
	b[1] = order_n
	b[2] = order
	b[3] = mate
	b[4] = kind
	b.encode_u16(5, ent)
	b.encode_float(7, pt.x)
	b.encode_float(11, pt.y)
	_play_send(b)
	order_line = "ORDER: %s > %s" % [OrderWheel.LABELS[order], to]
	order_line_bad = false
	order_mark = {"at": tg} if order <= 1 else {}
	order_mark_end = _ticks() + ORDER_SHOW_MS


# where a target is on the screen: [1 the ground / 2 an enemy / 0 not in view, its pixel]
func _order_on_screen(tg: Array) -> Array:
	if tg.is_empty() or int(tg[0]) == 0 or current.is_empty():
		return [0, Vector2.ZERO]
	if _map_on():                                          # the game's map in the HUD: where the map has it
		var w: Vector2 = tg[1] if int(tg[0]) == 1 else Vector2.ZERO
		if int(tg[0]) == 2:
			var u = live_ents.get(int(tg[1]))
			if u == null:
				return [0, Vector2.ZERO]
			w = Vector2(u[3], u[4])
		var px := _map_pixel(w)
		return [int(tg[0]), px] if _map_rect().has_point(px) else [0, Vector2.ZERO]
	var p: Vector3
	if int(tg[0]) == 2:
		var e = live_ents.get(int(tg[1]))
		if e == null:
			return [0, Vector2.ZERO]
		p = Vector3(e[3], e[5] + 0.2, e[4])
	else:
		var g: Vector2 = tg[1]
		p = Vector3(g.x, TNData.height_at(current["map"], g.x, g.y), g.y)
	if camera.is_position_behind(p):
		return [0, Vector2.ZERO]
	return [int(tg[0]), _order_pixel(p)]


# each frame: the wheel opens once the button has been held long enough, its picture follows
func _order_update() -> void:
	if not order_on:
		return
	var now := _ticks()
	if order_state != 0 and not _order_ready():
		order_state = 3                                    # (a game screen came, the squad is gone)
	if order_state == 1 and now - order_t >= ORDER_TAP_MS:
		order_state = 2
	if now >= order_mark_end:
		order_line = ""
		order_mark = {}
	if order_wheel == null:
		if order_state != 2 and order_line == "" and order_mark.is_empty():
			return
		var ol := CanvasLayer.new()
		ol.layer = 5                                       # over the game's HUD and the old school look, under its screens
		add_child(ol)
		order_wheel = OrderWheel.new()
		ol.add_child(order_wheel)
	var w := order_wheel
	var vs := get_viewport().get_visible_rect().size
	w.k = _order_scale()
	w.centre = ((Vector2(_cross_pixel()) + Vector2(0.5, 0.5)) / Vector2(320.0, 400.0) * vs).round()
	if order_state == 2 and order_centre != null:          # on the map: at the cursor, the whole wheel in the window
		var room := Vector2(OrderWheel.RF + 8.0, OrderWheel.RF + 8.0) * w.k
		var low := vs - Vector2(OrderWheel.RF + 8.0, OrderWheel.RF + 72.0) * w.k
		w.centre = (order_centre as Vector2).clamp(room, low.max(room)).round()
	w.marker_k = 0.5 if _map_on() else 1.0
	w.shown = order_state == 2
	var mark := [0, Vector2.ZERO]
	if order_state == 2:
		w.off = _order_off()
		var pane := OrderWheel.pane_at(order_ptr, ORDER_DEAD * w.k)
		w.picked = -1 if w.off.has(pane) else pane
		w.who = _order_who_name()
		# the mark in the middle: where the pane under the hand would send them, else what is aimed at
		mark = _order_on_screen(_order_target(w.picked if w.picked == 0 or w.picked == 1 else -1))
		if mark[0] == 0 and w.picked < 0:
			mark = _order_on_screen(_order_target(0))
	elif not order_mark.is_empty() and not menu_mode:
		mark = _order_on_screen(order_mark["at"])
	w.marker = mark[0]
	w.marker_at = mark[1]
	w.line = "" if menu_mode else order_line
	w.line_bad = order_line_bad
	w.visible = w.shown or w.marker != 0 or w.line != ""
	w.queue_redraw()


# the order wheel's own inputs, before anything else gets them: true if the event was its
func _order_input(event: InputEvent) -> bool:
	if not order_on or guest_win:
		return false
	if event is InputEventMouse:
		order_mouse = event.position
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and _map_click(event):
		return true
	if event is InputEventMouseButton:
		if int(order_key[0]) != 0 and event.button_index == int(order_key[0]):
			_order_button(event.pressed)
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT and order_rmb and not event.pressed:
			order_rmb = false
			return true
		if order_state == 0:
			return false
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			if event.pressed and order_state != 3:
				_order_turn(1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1)
			return true
		if event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
			order_rmb = true
			_order_cancel()
			return true
		return false
	if event is InputEventMouseMotion:
		if order_state != 1 and order_state != 2:          # (cancelled: the mouse turns the view again at once)
			return false
		order_ptr = (order_ptr + event.relative).limit_length(ORDER_REACH * _order_scale())
		return true                                        # (the view does not turn meanwhile)
	if event is InputEventKey and int(order_key[0]) == 0 and event.physical_keycode == int(order_key[1]):
		if not event.pressed:
			if order_state == 0:
				return false
			_order_button(false)
			return true
		if event.echo:
			return order_state != 0
		var mods := (KEY_MASK_SHIFT if event.shift_pressed else 0) | (KEY_MASK_CTRL if event.ctrl_pressed else 0) | \
				(KEY_MASK_ALT if event.alt_pressed else 0)
		if mods != int(order_key[2]):
			return false
		_order_button(true)
		return true
	return false


# ------------------------------------------------------------------ orders on the map
# With the order wheel on, the game's map shown in the HUD (its full screen map: key M, the MAP button) takes orders
# too. A click on it sends the entire squad to that place (MOVE THERE), a click on an enemy's mark orders the attack
# on it (ATTACK TARGET; the units the map shows and the game lets be attacked: the bridge's 'MAPV' and 'ORDS'). The
# wheel's button held on the map opens the wheel at the cursor, on that place or unit (who gets the order: the mouse
# wheel, as ever); a short press is the click. The order's mark is drawn on the map. A click with Shift, Ctrl or Alt
# held is the game's own, as without the option (it puts the player's nav marker there), and so are a click on the
# map's box of switches and any click while the game itself waits for one on its map (an order of its COMM menu that
# asks for a place or a target).
const MAP_NEAR := 5.0                    # an enemy's mark is clicked within that of it (pixels of the game's screen)
var map_news := -100000                  # when the bridge last said the map is in the HUD
var map_wait := false                    # the game itself waits for a click on its map
var map_box := Rect2()                   # the map on the game's 320 x 400 screen
var map_origin := Vector2.ZERO           # the world's x, y at its top left corner
var map_step := Vector2.ONE              # the world's length of one of its columns, of one of its rows
var map_keys := Rect2()                  # its box of switches (the game's own: what the map shows), on the game's screen
var map_ents := {}                       # the units it shows (the game's contacts)
var map_click := false                   # the left button went down on it for an order
var order_centre = null                  # the wheel's middle when it opened on the map (else: the crosshair)


# the bridge's 'MAPV': flags, the map's rectangle, its corner in the world, a column's and a row's length, its box of
# switches, the contacts
func _map_status(q: PackedByteArray) -> void:
	if q.size() < 39:
		return
	if q[4] & 1 == 0:
		map_news = -100000
		return
	map_news = Time.get_ticks_msec()
	map_wait = q[4] & 2 != 0
	map_box = Rect2(q.decode_s16(5), q.decode_s16(7), q.decode_s16(9) - q.decode_s16(5), q.decode_s16(11) - q.decode_s16(7))
	map_origin = Vector2(q.decode_float(13), q.decode_float(17))
	map_step = Vector2(maxf(q.decode_float(21), 0.0001), maxf(q.decode_float(25), 0.0001))
	map_keys = Rect2(q.decode_s16(29), q.decode_s16(31), q.decode_s16(33) - q.decode_s16(29), q.decode_s16(35) - q.decode_s16(31))
	map_ents.clear()
	for i in mini(q.decode_u16(37), (q.size() - 39) / 2):
		map_ents[q.decode_u16(39 + 2 * i)] = true


# the game's map is in the HUD and orders can be given on it
func _map_on() -> bool:
	return order_on and Time.get_ticks_msec() - map_news < 600 and not menu_mode and map_box.size.x > 0.0


# the map in the window
func _map_rect() -> Rect2:
	var s := get_viewport().get_visible_rect().size / Vector2(320.0, 400.0)
	return Rect2(map_box.position * s, map_box.size * s)


# a place of the world -> where the map shows it in the window, and back
func _map_pixel(w: Vector2) -> Vector2:
	var s := get_viewport().get_visible_rect().size / Vector2(320.0, 400.0)
	return (map_box.position + (w - map_origin) / map_step) * s


func _map_world(at: Vector2) -> Vector2:
	var s := get_viewport().get_visible_rect().size / Vector2(320.0, 400.0)
	return map_origin + (at / s - map_box.position) * map_step


# what a point of the window is on, on the map: the enemy whose mark is nearest within MAP_NEAR, else the place (a
# point of the world inside the mission's ground). Empty: not on the map.
func _map_pick(at: Vector2) -> Dictionary:
	if not _map_rect().has_point(at):
		return {}
	var s := get_viewport().get_visible_rect().size / Vector2(320.0, 400.0)
	if map_keys.has_point(at / s):
		return {}                                          # (its box of switches: the game's)
	var ent := -1
	var best := MAP_NEAR
	for id in order_enemies:
		var e = live_ents.get(id)
		if e == null or int(e[2]) & 1 == 0 or not map_ents.has(id):
			continue
		var d := ((_map_pixel(Vector2(e[3], e[4])) - at) / s).length()
		if d <= best:
			best = d
			ent = id
	var w := _map_world(at)
	var point = w if w.x >= 10.0 and w.y >= 10.0 and w.x <= 502.0 and w.y <= 502.0 else null
	return {"ent": ent, "point": point}


# the left button on the map: an order for the entire squad when it is let go (true: the click was the order's)
func _map_click(event: InputEventMouseButton) -> bool:
	if not event.pressed:
		if not map_click:
			return false
		map_click = false
		if order_state == 0 and _order_ready() and _map_on():
			if int(order_aim.get("ent", -1)) >= 0:
				_order_send(0, 0)
			elif order_aim.get("point") != null:
				_order_send(1, 0)
		return true
	if order_state != 0 or play_hold or map_wait or not _map_on() or not _order_ready() \
			or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or event.shift_pressed or event.ctrl_pressed or event.alt_pressed:
		return false
	var aim := _map_pick(event.position)
	if aim.is_empty():
		return false
	order_aim = aim
	map_click = true
	return true


# ------------------------------------------------------------------ the squadmates' subtitles
# What a squadmate says, written (the launcher's "Subtitles": TN_SUBTITLES = 1; off unless asked). The game plays a
# voice clip and shows nothing; the bridge says who plays which clip and what it means (live_bridge.py 'SUBT',
# subtitles.py: the game's own reply texts where it has them), again every fifth of a second while the clip plays.
# One line a speaker (subtitles.gd), kept as long as he speaks and no less than SUBS_MIN_MS. Not on a game screen,
# not for a coop guest.
const Subtitles = preload("res://scripts/subtitles.gd")
const SUBS_MIN_MS := 1500                # a line stays at least that long (a one-word answer lasts half a second)
const SUBS_LATE_MS := 450                # no news of a clip for that long: it is over
var subs_on := OS.get_environment("TN_SUBTITLES") == "1"
var subs := {}                           # squadmate (1-3) -> {n, pilot, text, since, seen, playing, ms, clip, event}
var subs_view: Subtitles


# the bridge's 'SUBT': number, squadmate, pilot, event, flags (bit 0: playing), clip, length (ms), text
func _subs_packet(q: PackedByteArray) -> void:
	if not subs_on or q.size() < 13 or guest_win:
		return
	var mate := int(q[5])
	var now := Time.get_ticks_msec()
	var s = subs.get(mate)
	if s == null or int(s["n"]) != int(q[4]):
		if q[8] & 1 == 0:
			return                                         # (the end of a line never shown)
		s = {"n": int(q[4]), "pilot": int(q[6]), "event": int(q[7]), "clip": q.decode_u16(9), "ms": q.decode_u16(11),
				"text": q.slice(13).get_string_from_utf8(), "since": now}
		subs[mate] = s
	s["seen"] = now
	s["playing"] = q[8] & 1 == 1


func _subs_update() -> void:
	if not subs_on:
		return
	var now := Time.get_ticks_msec()
	var shown := []
	for mate in subs.keys():
		var s: Dictionary = subs[mate]
		var end := int(s["seen"]) + (SUBS_LATE_MS if bool(s["playing"]) else 0)
		if now >= maxi(end, int(s["since"]) + SUBS_MIN_MS):
			subs.erase(mate)
		else:
			shown.append([int(s["since"]), mate])
	if subs_view == null:
		if shown.is_empty():
			return
		var sl := CanvasLayer.new()
		sl.layer = 4                                       # over the game's HUD and the old school look, under the order wheel
		add_child(sl)
		subs_view = Subtitles.new()
		sl.add_child(subs_view)
	shown.sort()                                           # the newest line lowest
	var lines := []
	for it in shown:
		var s: Dictionary = subs[it[1]]
		var text := str(s["text"])
		lines.append([_order_name([it[1], 0, int(s["pilot"])]), it[1], text, text.begins_with("[")])
	var vs := get_viewport().get_visible_rect().size
	var v := subs_view
	v.k = vs.y / 1080.0
	# at the bottom of the game's 3D window (its cockpit's dashboard rises in the middle), far under the crosshair
	var win := Rect2(hud_win) if hud_win.size.y > 0 else Rect2(11, 42, 298, 199)
	v.foot = Vector2((win.position.x + win.size.x * 0.5) / 320.0 * vs.x, (win.position.y + win.size.y * 0.89) / 400.0 * vs.y).round()
	v.lines = lines
	v.visible = not lines.is_empty() and not menu_mode
	v.queue_redraw()


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
	if photo_on:                                          # (the photo mode's own capture: without its help line)
		_photo_shot()
		return
	var path := _shot_path()
	var dir := path.get_base_dir()
	var img := get_viewport().get_texture().get_image()
	if img != null and img.save_png(path) == OK:
		_note("Screenshot saved: " + path)
	else:
		_note("The screenshot could not be saved in " + dir)


# the folder (made if it is not there) and the name of a new picture; tag: added to the name
func _shot_path(tag := "") -> String:
	var dir := OS.get_environment("TN_SHOT_DIR")
	if dir == "":
		dir = OS.get_system_dir(OS.SYSTEM_DIR_PICTURES).path_join("Terra Nova Uplink")
	DirAccess.make_dir_recursive_absolute(dir)
	var t := Time.get_datetime_dict_from_system()
	return dir.path_join("uplink_%04d-%02d-%02d_%02d-%02d-%02d%s.png" % [t.year, t.month, t.day, t.hour, t.minute, t.second, tag])


func _fps_toggle() -> void:
	if fps_label != null:
		fps_label.visible = not fps_label.visible


# its name on the player's keyboard (the key at that place: Y is Z on a German one)
func look_key_name() -> String:
	var s := OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(look_key))
	return s if s != "" else OS.get_keycode_string(look_key)


# ------------------------------------------------------------------ photo mode
# A key of Uplink's window, in a mission (O unless the player chose another in the launcher: TN_KEY_PHOTO, a PC
# scancode in hex after SHIFT+, CTRL+ or ALT+ if any, as Uplink's other keys). Nothing of it runs until the key is
# pressed. Then:
# - the game is paused, by its own Pause command: the bridge presses the game's key for it and watches the game's
#   pause flag ('X' + 1 / 0 on the play port, live_bridge.py photo_step; its news: 'PHOT'). The game's own screen of
#   a paused mission is not shown: Uplink goes on drawing the scene as it stood, its own clock stopped (_ticks), so
#   that puffs, flashes, animations, the units' easing, the water and (unless asked) the snow hold still;
# - nothing goes to the game any more: the keys and buttons held are let go there first, then the mouse and the keys
#   are the camera's until the mode is left;
# - the camera is free: the mouse turns it (as far as straight up and down), the map viewer's keys fly it (W A S D,
#   Space / Ctrl up / down, Shift four times faster, the wheel sets the speed), Q / E roll it, Z / C narrow and widen
#   the field of view, R puts it back in the player's eyes;
# - the cockpit and the HUD are hidden (H shows them), the old school look stays as it was (its own key switches it),
#   the weather holds still (T lets it fall); the player's own suit, which the main view never draws, is drawn once
#   the camera has left it;
# - Enter (or the screenshot key) saves the picture as a PNG in the screenshots' folder, without the help line or
#   any note; 2 switches to pictures twice the window's size (the whole view drawn at that size for the capture).
# The key again, or Esc: the camera back in the player's view, the field, the look and the mouse as they were, the
# game resumed. Not on the game's screens (a menu, a paused mission: the key is the game's there) and not in a coop
# guest's window (he cannot pause the host's game).
const PHOTO_LOOK := 0.003                # radians a pixel of mouse (the map viewer's camera)
const PHOTO_BODY := 0.35                 # the player's own suit is drawn once the camera is that far from his eyes
var photo_key := _photo_key()            # [physical key, modifiers]
var photo_key_held := false              # (its release is the photo mode's too)
var photo_on := false
var photo_freeze := false                # the game is paused for it, the scene holds still
var photo_pos := Vector3.ZERO
var photo_yaw := 0.0
var photo_pitch := 0.0
var photo_roll := 0.0
var photo_fov := 90.0                    # horizontal, degrees
var photo_speed := 6.0                   # units a second
var photo_hud := false                   # the cockpit and the HUD shown
var photo_still := true                  # the weather's flakes held in place
var photo_big := false                   # pictures twice the window's size
var photo_game_fov := 90.0               # the game's own field meanwhile (the way back)
var photo_was := {}                      # what is put back on leaving
var photo_held := {}                     # its keys that are down
var photo_up := {}                       # those still down when it was left: their release is not the game's either
var photo_state := 0                     # the bridge's news: 0 the game runs, 1 its key is going, 2 paused, 3 it would not pause
var photo_sent_t := 0                    # when the bridge was last told (the engine's msec)
var photo_again := 0                     # left: told that many times more
var photo_end_t := -100000               # when it was left
var photo_last := 0                      # the last frame (the engine's usec: its own clock is stopped)
var photo_t0 := 0                        # when it was entered (the engine's msec)
var photo_busy := false                  # a picture is being taken
var photo_help: Label
var photo_help_key := ""


static func _photo_key() -> Array:
	var k := _own_key(OS.get_environment("TN_KEY_PHOTO"))
	return k if not k.is_empty() else [KEY_O, 0]


# in a mission that is being played, on Uplink's own view
func _photo_can() -> bool:
	if not (live and play) or guest_win or menu_mode or start_hold or current.is_empty() or live_units_seen < 2:
		return false
	if game_fade < 0.999:                                 # (the mission ends: the game is fading out)
		return false
	for n in get_children():                             # (typing in the coop chat: a letter of his message)
		if n.has_method("wants_keys") and n.wants_keys():
			return false
	return true


func _photo_hides() -> bool:
	return photo_on and not photo_hud


# the photo mode's key, and everything while it is on: true if the event was its
func _photo_input(event: InputEvent) -> bool:
	var pk := int(photo_key[0])
	if event is InputEventKey and pk != KEY_NONE and event.physical_keycode == pk:
		if not event.pressed:
			if photo_key_held:
				photo_key_held = false
				return true
		elif event.echo:
			if photo_key_held:
				return true
		else:
			# (a Shift held on top of it is the run's or the fast flight's, not another key: the mode is entered in the
			# middle of a sprint and left in the middle of a fast flight)
			var want := int(photo_key[1])
			var mods := (KEY_MASK_SHIFT if event.shift_pressed and want & KEY_MASK_SHIFT else 0) | \
					(KEY_MASK_CTRL if event.ctrl_pressed else 0) | (KEY_MASK_ALT if event.alt_pressed else 0)
			if mods == want and not photo_busy and (photo_on or _photo_can()):
				photo_key_held = true
				_photo_set(not photo_on)
				return true
	if not photo_on:
		if event is InputEventKey and not photo_up.is_empty() and not event.echo and photo_up.erase(event.physical_keycode):
			return not event.pressed                    # (let go after the way out; pressed again: the game's)
		return false
	if event is InputEventMouseMotion:
		if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			photo_yaw = wrapf(photo_yaw - event.relative.x * PHOTO_LOOK, -PI, PI)
			photo_pitch = clampf(photo_pitch - event.relative.y * PHOTO_LOOK, -1.55, 1.55)
	elif event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_UP:
			photo_speed = minf(photo_speed * 1.25, 400.0)
		elif event.pressed and event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			photo_speed = maxf(photo_speed / 1.25, 0.25)
		elif event.pressed and event.button_index == MOUSE_BUTTON_LEFT and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED    # (the window was left: this click takes the mouse again)
	elif event is InputEventKey:
		var k: int = event.physical_keycode
		if _look_keys(event):                               # the look's own keys: old school on / off, its grid, a picture
			pass
		elif not event.pressed:
			photo_held.erase(k)
		elif not event.echo:
			photo_held[k] = true
			match k:
				KEY_ESCAPE:
					_photo_set(false)
				KEY_ENTER, KEY_KP_ENTER:
					_photo_shot()
				KEY_H:
					photo_hud = not photo_hud
				KEY_T:
					photo_still = not photo_still
				KEY_2:
					photo_big = not photo_big
				KEY_R:
					photo_pos = cam_to[0]
					photo_yaw = cam_to[1]
					photo_pitch = cam_to[2]
					photo_roll = 0.0
					photo_fov = photo_game_fov
	return true


# what the game holds of the player's is let go: his keys, the second binds', the order wheel, the buttons
func _photo_release() -> void:
	_play_hold_end()                                      # (the right button held on a map)
	for sc in play_held.keys():
		_play_key(sc, false)
	key_holders.clear()
	bind_down.clear()
	bind_taps.clear()
	bind_tap = ""
	order_state = 0
	order_rmb = false
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:     # (the look mode: a shot being fired, a lock being taken)
		for bt in [1, 2]:
			_play_send(PackedByteArray([0x42, bt, 0]))
	elif play_started and play_cursor.x >= 0:             # (the cursor mode: the left button, where the cursor is)
		var lb := PackedByteArray([0x43, 1, 0, 0, 0, 0, 0])
		lb.encode_s16(3, play_cursor.x)
		lb.encode_s16(5, play_cursor.y)
		_play_send(lb)
	play_dx = 0.0
	play_dy = 0.0
	free_look = false


# the bridge is told (twice a second while it lasts): the game paused for the photo mode, or resumed
func _photo_tell() -> void:
	photo_sent_t = Time.get_ticks_msec()
	_play_send(PackedByteArray([0x58, 1 if photo_on and photo_freeze else 0]))


func _photo_set(on: bool) -> void:
	if on == photo_on:
		return
	var real := Time.get_ticks_msec()
	if on:
		_photo_release()
		photo_was = {"mouse": Input.mouse_mode, "started": play_started,
				"old": oldschool_rect != null and oldschool_rect.visible, "mask": camera.cull_mask,
				"proj": camera.projection, "near": camera.near, "size": camera.size, "off": camera.frustum_offset,
				"keep": camera.keep_aspect}
		photo_on = true
		photo_freeze = not guest_win
		photo_pos = camera.position
		photo_yaw = camera.rotation.y
		photo_pitch = camera.rotation.x
		photo_roll = 0.0
		photo_fov = camera.fov
		photo_game_fov = camera.fov
		photo_hud = false
		photo_still = true
		photo_held.clear()
		photo_up.clear()
		photo_state = 0
		photo_again = 0
		photo_last = Time.get_ticks_usec()
		photo_t0 = real
		Input.set_custom_mouse_cursor(null)
		play_cur_set = ""                                 # (the game's cursor is set again afterwards, _play_cursor)
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	else:
		photo_on = false
		photo_up = photo_held.duplicate()
		photo_held.clear()
		if clock_stop >= 0:
			clock_lag += real - clock_stop
			clock_stop = -1
		photo_end_t = real
		photo_again = 3
		camera.cull_mask = int(photo_was["mask"])
		camera.projection = int(photo_was["proj"]) as Camera3D.ProjectionType
		camera.near = float(photo_was["near"])
		camera.size = float(photo_was["size"])
		camera.frustum_offset = photo_was["off"]
		camera.keep_aspect = int(photo_was["keep"]) as Camera3D.KeepAspect
		camera.fov = photo_game_fov
		if hud or hud_win.size.y > 0:
			_hud_camera(camera.fov)
		_live_smooth()                                    # the camera in the player's eyes again, where the game has them
		if oldschool_rect != null and oldschool_key != "" and oldschool_rect.visible != bool(photo_was["old"]):
			_oldschool_toggle()
		# the mouse as it was: the look mode's, or the cursor's (shown by _play_cursor), or free (the window was left);
		# on one of the game's screens: its arrow
		if menu_mode:
			play_started = true
			_menu_cursor_apply()
		elif int(photo_was["mouse"]) == Input.MOUSE_MODE_CAPTURED:
			play_started = true
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif bool(photo_was["started"]):
			play_started = true
			Input.mouse_mode = Input.MOUSE_MODE_HIDDEN
		else:
			play_started = false
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_photo_tell()
	_photo_show()


# each frame while it is on: the camera flown, its picture set up
func _photo_update() -> void:
	var us := Time.get_ticks_usec()
	var dt := clampf((us - photo_last) / 1e6, 0.0, 0.1)
	photo_last = us
	if menu_mode or current.is_empty():                   # one of the game's screens came
		_photo_set(false)
		return
	if photo_freeze:
		var real := Time.get_ticks_msec()
		if photo_state == 2 and clock_stop < 0:
			clock_stop = real                             # the game is paused: the scene holds still from here
		elif photo_state == 3 or (clock_stop < 0 and real - photo_t0 > 2500):
			_photo_set(false)                             # (no pause: no bridge for it, or the game would not take its key)
			_note("Photo mode: the game would not pause")
			return
		if real - photo_sent_t > 500:
			_photo_tell()
	var b := Basis.from_euler(Vector3(photo_pitch, photo_yaw, 0.0))
	var move := Vector3.ZERO
	if photo_held.has(KEY_W):
		move -= b.z
	if photo_held.has(KEY_S):
		move += b.z
	if photo_held.has(KEY_A):
		move -= b.x
	if photo_held.has(KEY_D):
		move += b.x
	if photo_held.has(KEY_SPACE):
		move += Vector3.UP
	if photo_held.has(KEY_CTRL):
		move -= Vector3.UP
	if move != Vector3.ZERO:
		photo_pos += move.normalized() * photo_speed * (4.0 if photo_held.has(KEY_SHIFT) else 1.0) * dt
	photo_roll = wrapf(photo_roll + (float(photo_held.has(KEY_Q)) - float(photo_held.has(KEY_E))) * 0.9 * dt, -PI, PI)
	photo_fov = clampf(photo_fov + (float(photo_held.has(KEY_C)) - float(photo_held.has(KEY_Z))) * 40.0 * dt, 8.0, 150.0)
	camera.position = photo_pos
	camera.rotation = Vector3(photo_pitch, photo_yaw, photo_roll)
	camera.fov = photo_fov                               # (what the rest reads: the waypoint's letters)
	if photo_hud and (hud or hud_win.size.y > 0):
		_hud_camera(photo_fov)                           # in the game's 3D window, as the cockpit frames it
	else:
		var near := 0.05
		camera.projection = Camera3D.PROJECTION_FRUSTUM
		camera.keep_aspect = Camera3D.KEEP_WIDTH
		camera.near = near
		camera.size = 2.0 * near * tan(deg_to_rad(photo_fov) / 2.0)
		camera.frustum_offset = Vector2.ZERO
		for sm in water_mats:                             # (the water mirrors over the whole window)
			(sm as ShaderMaterial).set_shader_parameter("view_top", 0.0)
			(sm as ShaderMaterial).set_shader_parameter("view_bottom", 1.0)
	var mask := int(photo_was["mask"])
	camera.cull_mask = mask | PLAYER_LAYER if photo_pos.distance_to(cam_to[0]) > PHOTO_BODY else mask
	_photo_show()


# what the photo mode hides and shows: the cockpit, the HUD and what Uplink draws for it; its help line
func _photo_show() -> void:
	var show := not _photo_hides()
	if hud_rect != null:
		hud_rect.visible = show
	if sub_layer != null:
		sub_layer.visible = show
	if compass_rect != null and not show:
		compass_rect.visible = false
	if waypoint != null:
		waypoint.visible = show and waypoint_at.x != 0.0 and not current.is_empty()
	if photo_on:
		if order_wheel != null:
			order_wheel.visible = false
		if cross_dot != null:
			cross_dot.visible = false
		if drag_cur != null:
			drag_cur.visible = false
	if not photo_on:
		if photo_help != null:
			photo_help.visible = false
		return
	if photo_help == null:
		var hl := CanvasLayer.new()
		hl.layer = 20                                     # over the game's HUD
		add_child(hl)
		photo_help = Label.new()
		photo_help.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		photo_help.grow_vertical = Control.GROW_DIRECTION_BEGIN
		photo_help.offset_left = 12
		photo_help.offset_right = -12
		photo_help.offset_bottom = -6
		photo_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		photo_help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		photo_help.mouse_filter = Control.MOUSE_FILTER_IGNORE
		photo_help.add_theme_color_override("font_color", Color(1, 1, 1, 0.8))
		photo_help.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
		photo_help.add_theme_constant_override("outline_size", 4)
		hl.add_child(photo_help)
	var vs := get_viewport().get_visible_rect().size
	var key := "%s %s %s %d" % [photo_big, photo_freeze, clock_stop >= 0, int(vs.y)]
	if key != photo_help_key:
		photo_help_key = key
		var n := func(k: int) -> String: return _photo_key_name([k, 0])
		var parts := ["PHOTO MODE" + ("" if not photo_freeze or clock_stop >= 0 else " (pausing the game...)"),
				"mouse: look", "%s %s %s %s: move" % [n.call(KEY_W), n.call(KEY_A), n.call(KEY_S), n.call(KEY_D)],
				"Space / Ctrl: up / down", "Shift: fast", "wheel: speed", "%s / %s: roll" % [n.call(KEY_Q), n.call(KEY_E)],
				"%s / %s: zoom" % [n.call(KEY_Z), n.call(KEY_C)], "%s: reset" % n.call(KEY_R),
				"%s: cockpit" % n.call(KEY_H)]
		if oldschool_rect != null and int(own_keys[0][0]) != KEY_NONE:
			parts.append("%s: old school" % _photo_key_name(own_keys[0]))
		if photo_freeze:
			parts.append("%s: weather still / falling" % n.call(KEY_T))
		parts.append("%s: picture size (now x%d)" % [n.call(KEY_2), 2 if photo_big else 1])
		parts.append("Enter: take the picture")
		parts.append("%s: leave" % _photo_key_name(photo_key))
		photo_help.text = "   ".join(parts)
		photo_help.add_theme_font_size_override("font_size", clampi(roundi(vs.y / 72.0), 11, 28))
	photo_help.visible = not photo_busy                   # (not in its pictures)


# a key as this keyboard prints it, with its Shift, Ctrl or Alt ([physical key, modifiers])
func _photo_key_name(k: Array) -> String:
	var s := OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(int(k[0])))
	if s == "":
		s = OS.get_keycode_string(int(k[0]))
	var m := int(k[1])
	return ("Ctrl+" if m & KEY_MASK_CTRL else "") + ("Shift+" if m & KEY_MASK_SHIFT else "") + ("Alt+" if m & KEY_MASK_ALT else "") + s


# The picture: the window as it is drawn, less the help line, the notes and Uplink's own marks; at twice its size
# when asked (the whole view is drawn at that size for the capture: the window's own picture is that one, scaled
# down, for those few frames). Saved where the screenshots go.
func _photo_shot() -> void:
	if photo_busy or not photo_on:
		return
	photo_busy = true
	var hidden := []
	photo_help.visible = false
	var marks: Array = [note_label, fps_label, host_btn, versus_btn]
	for n in get_children():                              # (the coop's own panels and chat)
		if n is CanvasLayer and n.has_method("wants_keys"):
			marks.append(n)
	for c in marks:
		if c != null and is_instance_valid(c) and c.visible:
			c.visible = false
			hidden.append(c)
	var win := get_window()
	var big := photo_big and maxi(win.size.x, win.size.y) * 2 <= 16384
	var was := [win.content_scale_mode, win.content_scale_aspect, win.content_scale_size]
	if big:
		win.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
		win.content_scale_size = win.size * 2
		win.content_scale_mode = Window.CONTENT_SCALE_MODE_VIEWPORT
	for i in (4 if big else 2):                           # (drawn without them, at the new size)
		await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if big:
		win.content_scale_mode = was[0]
		win.content_scale_aspect = was[1]
		win.content_scale_size = was[2]
	for c in hidden:
		if is_instance_valid(c):
			c.visible = true
	var path := _shot_path("_photo")
	var k := 2
	while FileAccess.file_exists(path):                   # (several in the same second)
		path = _shot_path("_photo_%d" % k)
		k += 1
	photo_help_key = ""                                   # (its help line shown again by the next frame)
	if img != null and img.save_png(path) == OK:
		_note("Picture saved: %s  (%d x %d)  in %s" % [path.get_file(), img.get_width(), img.get_height(), path.get_base_dir()])
	else:
		_note("The picture could not be saved in " + path.get_base_dir())
	photo_busy = false


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
	order_state = 0                                      # (the order wheel closes, nothing sent)
	order_rmb = false
	map_click = false
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
		start_hold_t = _ticks()
		live_units_seen = 0
	if on:
		menu_fresh = false                              # its picture: one taken from now on (the last one is an old screen)
		menu_mode_t = _ticks()
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
	var now := _ticks()
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
	if menu_mode and menu_tex != null and (menu_fresh or _ticks() - menu_mode_t > 600):
		want = 1.0
	var step := get_process_delta_time() / MENU_FADE_S
	var now := _ticks()
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
	if _photo_input(event):                                # the photo mode: its key, and every input while it is on
		get_viewport().set_input_as_handled()
		return
	# Two modes, swapped by the freelook key (Y unless the player changed it, see look_key) or Pause, which stay in
	# the viewer: look (mouse captured, it turns the view, clicks at the view's centre) and cursor (the game's own
	# cursor follows the mouse, clicks where it is: the HUD's buttons, the map, free aiming).
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if _order_input(event):                                # the order wheel: its button, and the mouse while it is held
		get_viewport().set_input_as_handled()
		return
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
			var down: float = event.relative.y * mouse_sens * (-1.0 if invert_y else 1.0)
			play_dy += look_dn.take(down) if look_dn != null else down   # (past the game's limit: look_down.gd)
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
		if photo_on:                                       # (the mouse is free: a click in the window takes it again,
			photo_held.clear()                             # and it stays free on leaving the photo mode)
			photo_was["mouse"] = Input.MOUSE_MODE_VISIBLE
			photo_was["started"] = false


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
		if look_dn != null:
			look_dn.sent(dy)
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
	if play and not photo_on:
		_play_cursor()
		_bind_taps()
		_order_update()
		_subs_update()
	if play and not photo_on and photo_again > 0 and Time.get_ticks_msec() - photo_sent_t > 300:
		_photo_tell()                                      # (left: said again, a lost packet would leave the game paused)
		photo_again -= 1
	if host_btn:
		host_btn.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED and not photo_busy
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
		elif q.size() >= 10 and q.slice(0, 4).get_string_from_ascii() == "GAIT" and q.size() == 10 + 128 * q.decode_u16(4):
			if q.decode_float(q.size() - 4) > 1.0:
				live_lod = q.decode_float(q.size() - 4)
			for k in q.decode_u16(4):                       # each soldier's walk as its game record has it: 20 constants
				var o := 6 + 128 * k                        # (suit_gait.gd setup), knee side, flat feet, then what the
				live_gaits[q.decode_s32(o)] = [q.slice(o + 8, o + 88).to_float32_array(), q.decode_s8(o + 4),   # game's AI
						q[o + 5] != 0, q.decode_float(o + 88), q.decode_float(o + 92), int(q[o + 6]),   # sets: height, lean, stance,
						q.slice(o + 96, o + 120).to_float32_array(),                             # each arm's aim, the height
						Vector2(q.decode_float(o + 120), q.decode_float(o + 124))]                # and lean it stood with
			live_gaits_new = true
		elif q.size() >= 6 and q.slice(0, 4).get_string_from_ascii() == "ARMS" and q.size() == 6 + 5 * q.decode_u16(4):
			for k in q.decode_u16(4):
				_live_arms(q.decode_s32(6 + 5 * k), q[10 + 5 * k])
		elif q.size() >= 22 and q.slice(0, 4).get_string_from_ascii() == "ORDS":
			_order_status(q)                                # the squad and who can be attacked (live_bridge.py, orders.py)
		elif q.size() == 8 and q.slice(0, 4).get_string_from_ascii() == "ORDR":
			_order_result(q)
		elif q.size() >= 39 and q.slice(0, 4).get_string_from_ascii() == "MAPV":
			_map_status(q)                                  # the game's map in the HUD, for the orders given on it
		elif q.size() >= 13 and q.slice(0, 4).get_string_from_ascii() == "SUBT":
			_subs_packet(q)                                 # a squadmate speaks (live_bridge.py, subtitles.py)
		elif q.size() == 5 and q.slice(0, 4).get_string_from_ascii() == "PHOT":
			photo_state = q[4]                              # the photo mode's pause, as the bridge has it (_photo_update)
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
		elif q.size() == 6 and q.slice(0, 4).get_string_from_ascii() == "HPIT":
			if look_dn != null:
				look_dn.head_is(q.decode_s16(4))            # the game's head pitch (look_down.gd)
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
			cloud_live_t = _ticks()
		else:
			pk = q
	if pk.size() < 24:
		_live_smooth()
		return
	var h := pk.decode_float(12)
	# game heading 0 = +x, then towards +y (Godot +z)
	_cam_target(Vector3(pk.decode_float(0), pk.decode_float(8), pk.decode_float(4)), atan2(-cos(h), -sin(h)), pk.decode_float(16))
	if photo_on:                                    # (the photo mode's camera is its own: the game's field is kept
		photo_game_fov = pk.decode_float(20)        # for the way back)
	else:
		camera.keep_aspect = Camera3D.KEEP_WIDTH    # the game gives its horizontal field of view
		camera.fov = pk.decode_float(20)
	_live_smooth()
	if not photo_on and (hud or hud_win.size.y > 0):  # coop guest: its cockpit's window (coop_hud.gd)
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
		_pose_flush_all()
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
	waypoint.visible = not _photo_hides()
	_waypoint_update(0.0)


func _waypoint_word(w: int) -> void:
	var now := _ticks_usec() / 1e6
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
		var wd := wp_word + wp_rate * minf(_ticks_usec() / 1e6 - wp_t, 0.25)
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
				if pk.size() >= tail + 12:                # (then the suits' limb reference vectors: _pose_apply)
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
	# the entities, 32 bytes each (index, class, type, active, x, y, z, heading), read in one go as whole numbers and
	# as decimals. The shots and effects (classes 5 and 6: in a fight, thousands of dust particles) are not put in the
	# table, where nothing looks for them: their places in the packet are kept, in its order (fx_at), for _live_fx
	var ents := {}
	live_ents = ents
	var ne := clampi(mini(n, (pk.size() - 32) / 32), 0, 1 << 20)
	var eblock := pk.slice(32, 32 + 32 * ne)
	var ei := eblock.to_int32_array()
	var ef := eblock.to_float32_array()
	var fx_at := PackedInt32Array()
	if fx_shots != null:
		fx_shots.ents = {}
	for k in ne:
		var o := 8 * k
		var cls := ei[o + 1]
		if cls == 5 or cls == 6:
			fx_at.append(o)
			# (the extras that follow the shots, fx_shots.gd: the shots and the game's animated effects, not the dust)
			if fx_shots != null and ei[o + 3] != 0 and (cls == 5 or not FX_NOT_FOLLOWED.has(ei[o + 2])):
				fx_shots.ents[ei[o]] = [cls, ei[o + 2], ei[o + 3], ef[o + 4], ef[o + 5], ef[o + 6], ef[o + 7]]
		else:
			ents[ei[o]] = [cls, ei[o + 2], ei[o + 3], ef[o + 4], ef[o + 5], ef[o + 6], ef[o + 7]]
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
	_pulsar_trails(ei, ef, fx_at)
	_beam_flashes()
	var fx_any := false
	var no_clouds := smoke_clouds.is_empty()
	var no_29 := fx29.is_empty()
	for en in ne:                                       # (in the packet's order, shots, effects and units together)
		var o := 8 * en
		var idx := ei[o]
		var ecls := ei[o + 1]
		if ecls == 5 or ecls == 6:
			if ei[o + 3] == 0:
				continue
			if not fx_any:
				fx_any = true
				if live_shot != "" and OS.has_environment("TN_FXSHOT") and live_shot_frame > live_seen + 20:
					live_shot_frame = live_seen + 20       # tests: capture as soon as a shot flies
			if ecls == 6 and ei[o + 2] == 29:
				# a shot's dust, by far the most of them: _live_fx has nothing to do for one that is no smoke cloud, no
				# smoke of a tree or jetpack (fx29), not under the player (_live_puff), when the bridge sends the
				# particles themselves (part_mode); the same tests as there, without building its entry
				if not no_clouds and smoke_clouds.has(idx):
					continue
				var k29: int = 7 if no_29 else int(fx29.get(idx, 7))
				if k29 == 8:
					continue
				if k29 != 9 and part_mode:
					var under := false
					var fxy := Vector2(ef[o + 4], ef[o + 5])
					for u in puff_units:
						if Vector2(u.x, u.z).distance_to(fxy) < 0.25:
							under = true
							break
					if not under:
						continue
			_live_fx(idx, [ecls, ei[o + 2], ei[o + 3], ef[o + 4], ef[o + 5], ef[o + 6], ef[o + 7]])
			continue
		var e = ents[idx]
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
	if draw_distance and not live_drawn.is_empty() and not free_look and not photo_on:
		# as in the game (its distances per type, see the bridge's DRAW): hidden, not freed (a suit keeps its steps)
		var all_idx: Array = ents.keys()
		for o in fx_at:
			all_idx.append(ei[o])
		for idx in all_idx:
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
	if live_gaits_new:
		live_gaits_new = false
		for idx in live_gaits:
			var ge = ents.get(idx)
			var gn := _live_node(idx) if ge != null and ge[0] == 1 else null
			if gn != null and gn.has_meta("soldier"):
				gn.set_meta("gk", live_gaits[idx])
	for idx in joints:                                 # soldiers the game draws: its own animation
		var node: Node3D = live_extra.get(idx)
		if node == null and live_off >= 0 and idx - live_off >= 0 and idx - live_off < live_nodes.size():
			node = live_nodes[idx - live_off]
		if node != null and node.visible and node.has_meta("soldier"):
			var now_ms := _ticks()
			# a pose read half written (_arms_off) is left out: the suit keeps its last one, and with none for
			# GAIT_STALE (a far suit the game no longer animates) walks on its own steps. (Each one put the suit on its own
			# steps for 3 s: one the game drew in all but 2 frames in 760 walked on them most of the time, its feet on
			# the map's ground, strides narrower than the game's, a leg straight on a step)
			# Nor one with a bone too long to draw (_pose_soldier left the suit in its last pose, for as long as they came)
			if not _bones_long(node, joints[idx]) and not _arms_off(joints[idx]):
				if now_ms - int(node.get_meta("jt", -100000)) > GAIT_STALE:
					node.set_meta("jt0", now_ms)            # its poses again after a while without (GAIT_BACK; after a
					# shorter gap, GAIT_STALE_MOVING, the game never stopped posing it: back on its pose at once)
				node.set_meta("jt", now_ms)
				if not _gait_wanted(node, now_ms):
					if live_refs.has(idx):
						node.set_meta("refs", live_refs[idx])
						node.set_meta("refs_eased", live_refs[idx])   # (for its eased poses, _unit_smooth)
					_pose_suit(node, joints[idx], false, true)   # (put on its limbs after the easing, _pose_flush_all)
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
	var now := _ticks()
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
		# game sends the target's identity, MISS8; hidden under the 3D view). The name is index 68, SENDING the next,
		# darker red, 69 (read on the game's screen: 232, 0, 0 and 205, 0, 0)
		(tr.material as ShaderMaterial).set_shader_parameter("label_rows", 16.0 if panel in [3, 4] else (r.size.y if panel == 2 else 0.0))
		(tr.material as ShaderMaterial).set_shader_parameter("label_a", 47.0 if panel in [3, 4] else 68.0)
		(tr.material as ShaderMaterial).set_shader_parameter("label_b", 59.0 if panel in [3, 4] else 69.0)
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
	var now := _ticks()
	var gap := now - sm_last
	if gap > 4 and gap < 200:
		sm_int = lerpf(sm_int, float(gap), 0.1)
	sm_last = now
	cam_from = [camera.position, yaw, pitch] if smooth and not photo_on and p.distance_to(to) < SMOOTH_JUMP else [p, y, pt]
	cam_to = [p, y, pt]
	cam_t = now


func _live_smooth() -> void:
	var now := _ticks()
	var a := clampf(float(now - cam_t) / sm_int, 0.0, 1.0)
	yaw = lerp_angle(cam_from[1], cam_to[1], a)
	pitch = lerpf(cam_from[2], cam_to[2], a)
	if not photo_on:                                  # (the photo mode flies its own camera, _photo_update)
		camera.position = (cam_from[0] as Vector3).lerp(cam_to[0], a)
		camera.rotation = Vector3(pitch + look_off.y + (look_dn.extra if look_dn != null else 0.0), yaw + look_off.x, 0)
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
	var now := _ticks()
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
			# the game's pose eased keeps the game's limb views (its reference vectors are taken once by the pose they
			# came with, _game_views: the eased pose that follows every frame had none and fell back on Uplink's own
			# choice of views, 19 frames in 20)
			if node.has_meta("refs_eased") and not bool(node.get_meta("own", false)):
				node.set_meta("refs", node.get_meta("refs_eased"))
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
	var t := _ticks() / 1000.0
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
			mi.set_meta("born", _ticks())
		mi.set_meta("near", near)
		# the player's own bolt: like the game, one beam from the gun to the bolt for a single game frame as it
		# leaves, then nothing (the bolt flies unseen to its impact; a held trigger fires every 0.125 s and the
		# streak drawn after the flash made two lasers in the air). Others' bolts: a short streak flying on
		var tail: Vector3 = mi.get_meta("tail")
		var w_tail := 0.004
		var w_bolt := 0.004
		if mi.get_meta("mine"):
			if _ticks() - int(mi.get_meta("born")) >= FLASH_MS:
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
			mi.set_meta("dust_born", _ticks())
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
	var now := _ticks()
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
		beam_flash.append([idx, b, _ticks(), false])


# with each view: the noted beams the game's state no longer has, not drawn yet (or held: TN_BEAM_HOLD)
func _beam_flashes() -> void:
	var now := _ticks()
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


func _pulsar_trails(ei: PackedInt32Array, ef: PackedFloat32Array, fx_at: PackedInt32Array) -> void:
	pulsar_parts.clear()
	pulsar_dust.clear()
	for o in fx_at:                                     # (the packet's shots and effects: _live_units)
		if ei[o + 1] == 5 and ei[o + 2] == 5 and ei[o + 3] != 0:
			pulsar_parts[ei[o]] = [Vector3(ef[o + 4], ef[o + 6], ef[o + 5])]
	if pulsar_parts.is_empty() or beam_mode:            # (its 6/28 are the game's own lines then: _live_beam)
		return
	for o in fx_at:
		if not (ei[o + 1] == 6 and ei[o + 2] == 28 and ei[o + 3] != 0):
			continue
		var idx := ei[o]
		var p := Vector3(ef[o + 4], ef[o + 6], ef[o + 5])
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
	var now := _ticks()
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
	anims.append([mi, _ticks(), anim_mats[typ][2], idx])
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
	var now := _ticks()
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
			smoke_screens[idx] = [centre, _ticks()]     # (a new cloud, maybe in an old one's slot)
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
var snow_px := {}                               # tile -> [its colours, its colours through each shade row] as laid


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
		# The snow comes a few dozen texels at a time on every tile, each tile every few seconds: the first time a tile
		# changes its colours are worked out whole (its 4096 texels, as they are and through each of the 16 shade rows)
		# and kept; after that only the texels that changed are put in them (the same bytes as worked out whole, for a
		# hundredth of the work: it was 5 ms a tile, 10 times a second)
		var luts: Array = snow_pl["shade_luts"] if snow_lit != null else []
		var rgb: PackedByteArray
		var lit: Array[PackedByteArray] = []
		if snow_px.has(t) and (snow_px[t][1] as Array).size() == luts.size():
			rgb = snow_px[t][0]
			lit = snow_px[t][1]
			for i in 4096:
				var pi := p[i]
				if pi == prev[i]:
					continue
				var c: Color = fp[pi]
				rgb[3 * i] = c.r8
				rgb[3 * i + 1] = c.g8
				rgb[3 * i + 2] = c.b8
				for row in lit.size():
					var lut: PackedByteArray = luts[row]
					var lb := lit[row]
					lb[3 * i] = lut[3 * pi]
					lb[3 * i + 1] = lut[3 * pi + 1]
					lb[3 * i + 2] = lut[3 * pi + 2]
		else:
			rgb.resize(4096 * 3)
			for i in 4096:
				var c: Color = fp[p[i]]
				rgb[3 * i] = c.r8
				rgb[3 * i + 1] = c.g8
				rgb[3 * i + 2] = c.b8
			for row in luts.size():
				lit.append(TNData.lit_tile(p, luts[row]).get_data().slice(0, 4096 * 3))   # (its full-size level)
		var img := Image.create_from_data(64, 64, false, Image.FORMAT_RGB8, rgb)
		img.generate_mipmaps()
		snow_tex.update_layer(img, t)
		if snow_idx != null:
			snow_idx.update_layer(TNData.index_tile(p), t)
		for row in lit.size():
			var limg := Image.create_from_data(64, 64, false, Image.FORMAT_RGB8, lit[row])
			limg.generate_mipmaps()
			snow_lit.update_layer(limg, row * n + t)
		snow_px[t] = [rgb, lit]
		snow_raw[t] = p


func _live_weather(q: PackedByteArray) -> void:
	var kind := q[4]
	var n := q.decode_u16(10)
	if kind == 0xFF or n == 0:
		# a single "none" now and then (the game's views rebuilt between two reads) blinked the snow off for a tenth
		# of a second: hidden only once it has said so for WEATHER_OFF_MS
		if weather_off_t == 0:
			weather_off_t = _ticks()
		if weather_node != null and _ticks() - weather_off_t >= WEATHER_OFF_MS:
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
	var now := _ticks()
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
	puffs.append([mi, _ticks() + int(delay * 1000.0), pos, vel])


func _puffs_update() -> void:
	var now := _ticks()
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
		if e[0] == 1 and node.has_meta("soldier"):
			_note_move(node, Vector2(e[3], e[4]))
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
		if not photo_on:
			camera.rotation = Vector3(pitch + look_off.y, yaw + look_off.x, 0)
	if hd_movie_box != null and hd_movie_box.visible and hd_movie.get_video_texture() != null:
		var vsz := hd_movie.get_video_texture().get_size()
		if vsz.y > 0:
			hd_movie_box.ratio = vsz.x / vsz.y           # the video at its own proportions, black around
	# the shaders' time (tn_time: the water, a disruptor's haze) and the weather's: Uplink's own, stopped with its clock
	var still := clock_stop >= 0
	if not still:
		scene_t = fmod(scene_t + delta, 3600.0)
		RenderingServer.global_shader_parameter_set("tn_time", scene_t)
	if weather_node != null and not (still and photo_still):
		weather_t = fmod(weather_t + delta, 3600.0)
		(weather_node.material_override as ShaderMaterial).set_shader_parameter("now", weather_t)
	_sync_sun_half()
	_clouds_update()
	_sky_items_place()
	sky_root.position = camera.position
	if live:
		_live_update()
		if photo_on:
			_photo_update()
		_dust_update()
		_gait_update(0.0 if still else delta)
		_waypoint_update(0.0 if still else delta)
		if hud and not _photo_hides():
			_compass_update()
		sky_root.position = camera.position
		return
	if (list.has_focus() or get_viewport().gui_get_focus_owner() is LineEdit) and not look:
		return
	if editor and editor.active and editor.ctrl_chord:
		return                                    # (the editor's Ctrl+S / Ctrl+Z: no flying down until Ctrl is up)
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


# ------------------------------------------------------------------ optional extras
# Novelties on top of the game's look, each off unless asked for (the launcher's "In game" switches, or the
# environment), each in its own script, nothing of them made when off:
# TN_FX_MARKS=1    impact marks where the shots hit the ground (fx_marks.gd)
# TN_FX_LIGHTS=1   light from the shots: gun flashes, flying bolts, blasts (fx_lights.gd)
# TN_FX_CLOUD_SHADOWS=1  the sky's clouds cast drifting shadows on the ground (_cloud_cover, terrain.gdshader)
# TN_FX_LOOK_DOWN=1 the view turns on down past the game's 45 degrees, onto the player's own legs (look_down.gd)
# TN_FX_CLIFFS=1    steep faces textured along the slope instead of stretched tiles (terrain.gdshader cliffs)
# TN_FX_STARS=1     the space skies' stars as sharp points at the window's resolution (sky.gdshader star_scale)
var fx_shots: Node               # the game's shots followed (fx_shots.gd), for the extras that need them
var look_dn: Node                # looking down past the game's limit (look_down.gd), null: off
const FX_NOT_FOLLOWED := [28, 29, 31, 32, 33]   # class 6: beams, particles, lightning, debris, burst suits


func _extras() -> void:
	if live and not guest_win and OS.get_environment("TN_FX_MARKS") == "1":
		var mk: Node = load("res://scripts/fx_marks.gd").new()
		mk.v = self
		mk.shots = _fx_shots()
		add_child(mk)
	if live and not guest_win and OS.get_environment("TN_FX_LIGHTS") == "1":
		var lt: Node = load("res://scripts/fx_lights.gd").new()
		lt.v = self
		lt.shots = _fx_shots()
		add_child(lt)
	if live and not guest_win and OS.get_environment("TN_FX_LOOK_DOWN") == "1":
		look_dn = load("res://scripts/look_down.gd").new()
		look_dn.v = self
		add_child(look_dn)


func _fx_shots() -> Node:
	if fx_shots == null:
		fx_shots = load("res://scripts/fx_shots.gd").new()
		fx_shots.v = self
		add_child(fx_shots)
	return fx_shots


# Cloud shadows (TN_FX_CLOUD_SHADOWS=1): how thick the sky's cloud layer is, texel by texel, for the ground's shader
# (terrain.gdshader cloud_shadows), which looks it up where the sun's ray from the ground meets the cloud ceiling
# (the height the sky is drawn with at the drop zone: 0.0478 x (the mission's cloud height - 8 x the eye's), _sky_to)
# and darkens by rows of the planet's light table. The sky's wind offset moves it (_clouds_update gives the ground's
# materials the sky's cloud_off): the shadows drift with the clouds. On the planets' skies the clouds are the light,
# pale texels on a deeper sky (thick = light); a storm sky is grey all over, its darker texels the thicker cloud,
# and shades half as much. No clouds (the space skies): no shadows.
var fx_cloud_shadows := OS.get_environment("TN_FX_CLOUD_SHADOWS") == "1"
var fx_stars := OS.get_environment("TN_FX_STARS") == "1"
var cloud_cover: ImageTexture


func _cloud_cover(clouds: Texture2D) -> ImageTexture:
	if clouds == null:
		return null
	var img := clouds.get_image()
	if img == null or img.get_width() != 256 or img.get_height() != 256:
		return null
	img.convert(Image.FORMAT_RGB8)
	var d := img.get_data()
	var lum := PackedFloat32Array()
	lum.resize(65536)
	var sat := 0.0
	for i in 65536:
		var r := d[3 * i] / 255.0
		var g := d[3 * i + 1] / 255.0
		var b := d[3 * i + 2] / 255.0
		lum[i] = 0.3 * r + 0.59 * g + 0.11 * b
		sat += maxf(r, maxf(g, b)) - minf(r, minf(g, b))
	var sorted := lum.duplicate()
	sorted.sort()
	var lo: float = sorted[6553]
	var hi: float = sorted[58982]
	if hi - lo < 0.02:
		return null                                     # (a plain sky: nothing to cast)
	var grey := sat / 65536.0 < 0.04                    # a storm's ceiling
	lum = _box_blur(lum, 256, 2)
	var out := PackedByteArray()
	out.resize(65536)
	for i in 65536:
		var c := clampf((lum[i] - lo) / (hi - lo), 0.0, 1.0)
		out[i] = int((0.4 + 0.25 * (1.0 - c) if grey else c) * 255.0)   # (a storm: 0.4 to 0.65, a row at most)
	return ImageTexture.create_from_image(Image.create_from_data(256, 256, false, Image.FORMAT_R8, out))
