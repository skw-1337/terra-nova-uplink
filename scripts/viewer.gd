# Terra Nova Uplink: terrain, water, mission entities, named script zones, free camera.
extends Node3D

const TNData = preload("res://scripts/tn_data.gd")
const Terrain = preload("res://scripts/terrain.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
const GROUND = preload("res://terrain.gdshader")
const LIMB = preload("res://limb.gdshader")
const OLDSCHOOL = preload("res://oldschool.gdshader")
const INFRARED = preload("res://infrared.gdshader")
const SUBVIEW = preload("res://subview.gdshader")
const SMOKE = preload("res://smoke.gdshader")
const PUFF = preload("res://puff.gdshader")
const ANIM = preload("res://anim.gdshader")
const BEAM = preload("res://beam.gdshader")
const WATER = preload("res://water.gdshader")
const SKY_SHADER = preload("res://sky.gdshader")
const SKY_DISTANCE := 2400.0             # sky sprites: far away, following the camera
const SKY_PIXEL := 0.0024                # their angular size per image pixel (radians)
const DEFAULT_SUN := Vector3(-52, -35, 0)
const SMOKE_WIDTH := 1.4                # world width of a smoke column
const POSES_FILE := "res://data/soldier_poses.json"   # real poses read from the running game
# Standing pose computed by the game for a Hog scout (suit 4), read in a RAM snapshot:
# joints (right, up, forward) in world units, ground at 0. Other suits get the same joint
# directions with their own bone lengths (sprite pixel length / 256 x 1.09, the scout's own size).
const TEMPLATE_POSE := [Vector3(-0.0378, 0.0, 0.0329), Vector3(0.0378, 0.0, 0.0329),
		Vector3(-0.0279, 0.0422, -0.0169), Vector3(0.0279, 0.0422, -0.0169),
		Vector3(-0.0203, 0.1445, 0.0034), Vector3(0.0388, 0.1445, 0.0035),
		Vector3(-0.0312, 0.2494, 0.0), Vector3(0.0312, 0.2494, -0.0), Vector3(0.0, 0.2494, 0.0),
		Vector3(0.0, 0.4043, 0.0), Vector3(-0.0689, 0.3826, 0.0117), Vector3(0.0874, 0.3826, 0.012),
		Vector3(-0.0695, 0.322, 0.061), Vector3(0.0932, 0.3227, 0.0609),
		Vector3(-0.0714, 0.3061, 0.1374), Vector3(0.111, 0.3112, 0.136)]
const TEMPLATE_SUIT := 4
const BODY_SCALE := 1.09
const CFG := "user://viewer.cfg"

var data = TNData.new()
var objects = TNObjects.new()
var objects_ok := false
var pal := PackedColorArray()   # 256-color palette of the current planet
var pal_key := ""
var world: Node3D
var camera: Camera3D
var ui: CanvasLayer
var oldschool_rect: ColorRect      # live mode, "old school": the game's pixels and palette over the 3D view (F12)
var ir_rect: ColorRect            # live mode: the game's infrared view (its orange ramp), under the HUD
var ir_on := false
# The HUD's side views (live mode): the selected squadmate's camera (bottom left, button VUE) and the probe's (right),
# drawn here by Godot over the game's own small views (panels 1 = squadmate, 2 = target camera, 3 = probe).
const SUB_RECTS := {1: true, 2: true, 3: true}
const SUB_FOV_PROBE := 78.0      # the probe's: its compass labels (45 deg apart) seen at 340 of its 670 pixels
const PROBE_TILT := 0.3
const SUB_FOV := 100.0            # horizontal, degrees
const SUB_HIDE_LAYER := 1 << 19   # the unit carrying a side view's camera: hidden from that view only
const PLAYER_LAYER := 1 << 18     # the player's own body: seen only in the side views (the main view is its eyes)
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
const GAME_Z := 0.12          # the game's heights are this much above the ground (units, shots)
var live := false
var udp: PacketPeerUDP
var live_seen := 0
var live_shot := ""
var live_shot_frame := 60
var live_nodes := []          # one node per mission entity, in file order
var live_off := -1            # game entity table index of the first mission entity
var live_extra := {}          # game entity index -> node, for units not in the mission file (squadmates...)
var live_fx := {}             # game entity index -> glowing sprite: shots (class 5) and their sparks (class 6)
var live_piles := {}          # game entity index -> pile of armour pieces of a burst suit (6/33)
var fx_mats := {}
var puffs := []               # live smoke puffs: [node, start msec]; type 6/29 (jetpack exhaust, laser trail)
var puff_mat: ShaderMaterial
var puff_mesh: QuadMesh
var veg_cells := {}           # vegetation cell (cx * 128 + cy) -> [[multimesh, instance]]: what to hide when it goes
var veg_values := PackedByteArray()
var scorch_decals := {}         # live mode: burnt ground vertex (y * 513 + x) -> its decal (destroyed tree, blast)
var scorch_prev := PackedByteArray()
var ground_mats := []        # ground materials of the map, for the sky they mirror
var sky_clouds: Texture2D
var sky_haze := Color(0.7, 0.76, 0.84)
var sky_light := Color(0.91, 0.94, 0.97)     # the lightest cloud colour (the horizon)
var sun_to := Vector3(0, 0.7, 0.7)           # towards the sun (the map's light direction)
# --hud: the game's own screen (cockpit, HUD) over the view, its 3D window transparent (port 47823: 'PAL' palette +
# 3D window, then one 'HUZ' packet: the 320 x 400 screen as (palette index, alpha), deflated); the camera is then
# off-centre like the game's, whose view centre (the crosshair) is 51 % down its 3D window
const HUD_PORT := 47823
const SUN_AZ_OFFSET := 315.0  # see _set_sky
const LIVE_LIGHT := 0.73       # sun in live mode, and the sky's share of the ambient light: the game's ground is
const LIVE_SUIT_SHADE := 0.5   # suits in live mode: the game's are dark and shaded
const SUIT_SQUASH := 1.0       # suits: height of the joints (0.75 was measured while the live view was zoomed in)
const LIVE_AMBIENT := 0.28     # darker (measured on the same view against the running game)
const LIVE_FOG_BEGIN := 250.0   # live mode: depth fog from here to there (game units), like the game's haze
const LIVE_FOG_END := 700.0
const LIVE_SKY := 1.0          # its sky as is (1.5 was brighter than the game once the bloom was off)
const VIEW_CENTRE := 0.51        # the view's centre (the crosshair, screen row 144) in the 3D window, measured on lock boxes
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
var invert_y := OS.get_environment("TN_INVERT_Y") == "1"    # Terra Nova Coop's settings (the launcher's environment)
var play_held := {}
var play_started := false        # the first click in the window only takes the mouse
# live mode without coop: "Host online" (top left, while the mouse is free) turns this game into an online coop host,
# as Coop online - host.bat does: coop_net.gd opens the Steam lobby, the bridge ('HOST') starts its coop module
var host_btn: Button
var versus_btn: Button           # "1v1 (versus)": the same, the guest drives a suit of the other side (experimental)
# the game's own screen when it is not in its 3D (menus, death screen, briefing, video, pause): the bridge captures
# the DOSBox window and sends it (see live_bridge.py menu_loop); shown over everything, the mouse goes to the game
var menu_mode := false
var menu_rect: TextureRect
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
	_build_scene()
	_build_ui()
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	var given := OS.get_environment("TN_GAME_DIR").replace("\\", "/")   # Terra Nova Coop (the launcher): its game
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
		var rl := CanvasLayer.new()                     # old school mode: the game's look over the 3D view, under its HUD (F12)
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
		# no cast shadows: the game has none (seen beside it: hills and units darkened ground the game leaves lit, and
		# the sprites, drawn unlit like the game's, stood bright inside them)
		sun.shadow_enabled = false
		env.ambient_light_sky_contribution = LIVE_AMBIENT
		env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		env.adjustment_enabled = true
		env.adjustment_saturation = 1.4
		# the game's view ends in its haze: depth fog (its colour is the planet's haze, set with the sky)
		env.fog_mode = Environment.FOG_MODE_DEPTH
		env.fog_depth_begin = LIVE_FOG_BEGIN
		env.fog_depth_end = LIVE_FOG_END
		env.fog_density = 1.0
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
		if not ("--coop-host" in args or "--coop-guest" in args or "--coop-hud" in args):
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
	env.ambient_light_energy = 0.35
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.76, 0.84)
	env.fog_density = 0.0005
	env.fog_sky_affect = 0.3
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = DEFAULT_SUN
	sun.light_energy = 1.0
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 250.0
	add_child(sun)
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
	var det_mat: Material = mats["terrain"]
	var out_mat: Material = mats["terrain"]
	if pl["ok"]:                          # real ground textures (else: average colors)
		det_mat = _ground_mat(pl, m["detail"], Vector2(0, 0), 1.0)
		if not m["outer"].is_empty():
			out_mat = _ground_mat(pl, m["outer"], Vector2(-256, -256), 4.0)
	Terrain.build(world, m["detail"], 1.0, Vector2(0, 0), Rect2i(), det_mat)
	if not m["outer"].is_empty():
		Terrain.build(world, m["outer"], 4.0, Vector2(-256, -256), Rect2i(64, 64, 128, 128), out_mat)
	var wl := Terrain.water_level(m["detail"])
	if not is_nan(wl):
		var plane := MeshInstance3D.new()
		var pm := PlaneMesh.new()
		pm.size = Vector2(1024, 1024)
		plane.mesh = pm
		plane.material_override = mats["water"]
		plane.position = Vector3(256, wl - 0.05, 256)     # under the water tiles: 0.12 above them it rose up the
		# river banks, wider than the game's river (its tiles, with their own far colour, are the game's water)
		world.add_child(plane)
	pal = pl["palette"] if pl.has("palette") else data.full_palette(PackedByteArray())
	pal_key = m["planet"]
	_set_sky(data.resolve(entry["file"], mis.get("sky", "")) if mis.get("sky", "") != "" else "", m["light"])
	var nveg := _add_vegetation(m)
	var counts := {}
	live_nodes.clear()
	live_off = -1
	live_extra.clear()
	live_fx.clear()
	live_piles.clear()
	scorch_decals.clear()                     # (their nodes went with the old world)
	scorch_prev = PackedByteArray()
	anims.clear()
	smoke_pending.clear()
	for e in mis["entities"]:
		live_nodes.append(_add_object(m, e["cls"], e["sub"], e["x"], e["y"], e["heading"], e["group"], true, e["z"]))
		live_nodes[-1].set_meta("mission", true)       # placed from the file: buildings stay on the ground
		counts[e["cls"]] = counts.get(e["cls"], 0) + 1
	for z in mis["zones"]:
		_add_zone(m, z)
	current = {"map": m, "mission": mis, "entry": entry}
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
		var ref: Vector2i = objects.ref_for(key.x, key.y) if objects_ok else Vector2i.ZERO
		if OS.has_environment("TN_DEBUG"):
			print("vegetation %s ref %s %s x%d largeur %.3f" % [key, ref, data.type_name(key.x, key.y), groups[key].size(), objects.sprite_width(key.x, key.y)])
		if TNObjects.is_sprite(ref):
			var sp: Dictionary = objects.sprite(ref, pal, pal_key)
			if not sp.is_empty():
				var low: String = data.type_name(key.x, key.y).to_lower()
				var rock := low.contains("roch") or low.contains("rock")
				mesh = _sprite_quad(sp, objects.sprite_width(key.x, key.y) * (ROCK_SCALE if rock else 1.0), ROCK_TALL if rock else 1.0)
				mat = _sprite_mat(ref, sp)
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
		mm.mesh = mesh
		var trs: Array = groups[key]
		mm.instance_count = trs.size()
		for i in trs.size():
			mm.set_instance_transform(i, trs[i][0])
			var cell: int = trs[i][1]
			if not veg_cells.has(cell):
				veg_cells[cell] = []
			veg_cells[cell].append([mm, i, trs[i][0]])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		if mat != null:
			mmi.material_override = mat
		mmi.add_to_group("vegetation")
		mmi.visible = veg_on
		world.add_child(mmi)
	return n


# Rocks are drawn a little wider than their radius by the game ("width = radius" was measured on a tree; a decor rock
# seen at 1.5 and 5 units: 1.2 x, the same at both distances). Trees and bushes not checked again (few on Panama).
const ROCK_SCALE := 1.2
const ROCK_TALL := 1.5     # and 1.5 x taller than their picture's proportions (same rock, both distances)


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


# Sprite (tree, bush, rock, probe): upright quad turning to face the camera, base on the ground.
func _sprite_quad(sp: Dictionary, width: float, tall: float = 1.0) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(width, width * sp["aspect"] * tall)
	q.center_offset = Vector3(0, q.size.y * 0.5, 0)
	return q


func _sprite_mat(key: Vector2i, sp: Dictionary) -> StandardMaterial3D:
	var k := "sprite%s" % key
	if mats.has(k):
		return mats[k]
	var sm := StandardMaterial3D.new()
	sm.albedo_texture = sp["texture"]
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	sm.alpha_scissor_threshold = 0.5
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y
	sm.billboard_keep_scale = true
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED   # the game draws sprites unlit
	sm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	mats[k] = sm
	return sm


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


func _ground_mat(pl: Dictionary, grid: Dictionary, origin: Vector2, step: float) -> ShaderMaterial:
	var sm := ShaderMaterial.new()
	sm.shader = GROUND
	sm.set_shader_parameter("tiles", pl["textures"])
	sm.set_shader_parameter("tiles_soft", pl["textures"])
	sm.set_shader_parameter("tiles_wrap", pl["textures"])
	sm.set_shader_parameter("tilemap", ImageTexture.create_from_image(grid["tilemap"]))
	sm.set_shader_parameter("origin", origin)
	sm.set_shader_parameter("step_size", step)
	sm.set_shader_parameter("grid_n", float(grid["n"]))
	# water tiles: the bluish ones of the planet's set (their mean colour)
	var wt := Image.create(64, 1, false, Image.FORMAT_R8)
	var tc: PackedColorArray = pl["tile_color"]
	var wsum := Color(0, 0, 0)
	var wn := 0
	for i in mini(64, tc.size()):
		var c := tc[i]
		if c.b > c.r * 1.25 and c.b > c.g * 1.02 and c.b > 0.25:
			wt.set_pixel(i, 0, Color(1, 0, 0))
			wsum += c
			wn += 1
	sm.set_shader_parameter("water_tiles", ImageTexture.create_from_image(wt))
	if wn > 0:                                # the game's far water: the mean colour of these tiles, flat
		var far := Color(wsum.r / wn, wsum.g / wn, wsum.b / wn)
		sm.set_shader_parameter("water_far", far)
		mats["water"].set_shader_parameter("far_tint", far)
		print("far water %d tiles: %s" % [wn, far.to_html(false)])
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
	if sky_clouds != null:
		sm.set_shader_parameter("clouds", sky_clouds)
	sm.set_shader_parameter("haze", Vector3(sky_haze.r, sky_haze.g, sky_haze.b))
	sm.set_shader_parameter("reflect_gain", 0.8)
	if sky_clouds != null:
		sm.set_shader_parameter("clouds_soft", sky_clouds)
	sm.set_shader_parameter("light", Vector3(sky_light.r, sky_light.g, sky_light.b))
	sm.set_shader_parameter("sun_dir", sun_to)
	sm.set_shader_parameter("desat", 1.0 / env.adjustment_saturation if live and env.adjustment_enabled else 1.0)
	sm.set_shader_parameter("modern", _is_modern())


# Old school off (F12, and the map viewer): the modern sky and water (sky_common.gdshaderinc); on: the game's.
func _is_modern() -> bool:
	return oldschool_rect == null or not oldschool_rect.visible


func _apply_look() -> void:
	var m := _is_modern()
	if env.sky.sky_material is ShaderMaterial:
		(env.sky.sky_material as ShaderMaterial).set_shader_parameter("modern", m)
	for sm in ground_mats + [mats["water"]]:
		sm.set_shader_parameter("modern", m)


func _add_object(m: Dictionary, cls: int, sub: int, x: float, y: float, heading: float, group: String,
		label: bool, z: float = 0.0) -> MeshInstance3D:
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
	var ref: Vector2i = objects.ref_for(cls, sub) if objects_ok else Vector2i.ZERO
	var soldier := false
	if cls == 1 and objects_ok:
		var suit := TNObjects.suit_of(sub)
		top = _add_mech(mi) if suit == TNObjects.MECH_SUIT else _add_soldier(mi, suit)   # parts = children
		soldier = top > 0.0
	if cls == 4 and sub == TNObjects.SMOKE_TYPE and objects_ok:
		var sm: Dictionary = objects.smoke_anim(pal, pal_key)
		if not sm.is_empty():
			var q := QuadMesh.new()
			q.size = Vector2(SMOKE_WIDTH, SMOKE_WIDTH * sm["aspect"])
			q.center_offset = Vector3(0, q.size.y * 0.5, 0)
			mi.mesh = q
			var smat := ShaderMaterial.new()
			smat.shader = SMOKE
			smat.set_shader_parameter("frames", sm["tex"])
			smat.set_shader_parameter("frame_count", sm["frames"])
			mi.material_override = smat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.extra_cull_margin = SMOKE_WIDTH
			top = q.size.y
	if soldier or mi.mesh != null:
		pass
	elif TNObjects.is_model(ref):
		var md: Dictionary = objects.model(ref, pal, pal_key)
		if not md.is_empty():
			mi.mesh = md["mesh"]
			top = md["height"]
			if md["params"] > 0:
				mi.set_meta("art_ref", ref)              # articulated parts: posed by the live game (_live_arts)
	elif TNObjects.is_sprite(ref):
		var sp: Dictionary = objects.sprite(ref, pal, pal_key)
		if not sp.is_empty():
			var rock := low.contains("roch") or low.contains("rock")
			var q := _sprite_quad(sp, objects.sprite_width(cls, sub) * (ROCK_SCALE if rock else 1.0), ROCK_TALL if rock else 1.0)
			mi.mesh = q
			mi.material_override = _sprite_mat(ref, sp)
			top = q.size.y
	if mi.mesh == null and not soldier:   # nothing usable in the data (e.g. the biped mech)
		var box := BoxMesh.new()
		match cls:
			0:
				box.size = Vector3(1.2, 1.2, 1.2)
				mi.material_override = mats["decor"]
			1:
				box.size = Vector3(0.5, 1.4, 0.5)
				mi.material_override = mats["friend"] if data.is_friendly(name) else mats["enemy"]
			2, 3:
				box.size = Vector3(1.4, 0.8, 1.4)
				mi.material_override = mats["friend"] if data.is_friendly(name) else mats["enemy"]
			_:
				box.size = Vector3(4, 3, 4)
				mi.material_override = mats["building"]
		mi.mesh = box
		top = box.size.y
		lift += box.size.y * 0.5
		top -= box.size.y * 0.5
	mi.position = Vector3(x, ground + lift, y)
	mi.rotation.y = -heading
	mi.set_meta("lift", lift)
	world.add_child(mi)
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


# Power suit in its standing pose (see TEMPLATE_POSE); the limbs become children of holder.
# Joints of skeletons 884 / 885: 0/1 toes, 2/3 ankles, 4/5 knees, 6/7 hips, 8 pelvis, 9 neck,
# 10/11 shoulders, 12/13 elbows, 14/15 hands. Returns the suit height (0 when it has no sprites).
func _add_soldier(holder: Node3D, suit: int) -> float:
	var segs: Array = objects.skeleton(suit)
	var limbs := {}
	for sg in segs:
		var ld: Dictionary = objects.limb(suit, sg[2], pal, pal_key)
		if ld.is_empty():
			return 0.0
		limbs[sg[2]] = ld
	var p := _soldier_pose(suit, segs, limbs)
	var parts := []
	for sg in segs:
		var ld: Dictionary = limbs[sg[2]]
		var seg := MeshInstance3D.new()
		seg.mesh = _limb_quad(ld)
		seg.material_override = _limb_mat(suit, sg[2], ld)
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(seg)
		parts.append([seg, sg[0], sg[1], float(ld["len"]), float(ld["size"].x)])
	holder.set_meta("soldier", parts)
	holder.set_meta("suit", suit)
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


# Puts a soldier's limbs on its 16 joints, (right, up, forward) from the ground under it: its pose at load, then
# in live mode the game's own joints every frame (walking, arms, aiming). Returns the highest joint.
func _pose_soldier(holder: Node3D, p: Array) -> float:
	var top := 0.0
	# the body's right, which sets each limb's front (the views turn around the bone): the hips' line for the legs
	# and feet, the shoulders' for the torso and arms (joints 6 / 7 hips, 10 / 11 shoulders). Front = right x bone:
	# a leg hanging down faces forward, a foot (the same leg turned forward at the ankle) faces up
	var r_hips := _node_axes(p[7] - p[6])
	var r_top := _node_axes(p[11] - p[10])
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
		seg.transform = Transform3D(Basis(xn * sc, yn * sc, xn.cross(yn) * sc), ga)
		seg.extra_cull_margin = part[4] * sc
		top = maxf(top, maxf(ga.y, gb.y))
	return top


# (right, up, forward) -> node axes (forward = +X, up = +Y, right = +Z)
func _node_axes(v: Vector3) -> Vector3:
	return Vector3(v.z, v.y, v.x)


var captured_poses = null


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
	var length := func(part: int) -> float:
		return limbs[part]["len"] / 256.0 * BODY_SCALE if limbs.has(part) else 0.08
	# free joints (pelvis, hips, shoulders) keep their place relative to the pelvis / neck,
	# scaled with the torso; every limb keeps its direction and takes this suit's length
	var k_torso: float = length.call(5) / t[8].distance_to(t[9])
	p[8] = t[8]
	p[9] = p[8] + (t[9] - t[8]).normalized() * length.call(5)
	for i in 2:
		p[6 + i] = p[8] + (t[6 + i] - t[8]) * k_torso
		p[10 + i] = p[9] + (t[10 + i] - t[9]) * k_torso
	for chain in [[6, 4, 2, 0], [7, 5, 3, 1], [10, 12, 14], [11, 13, 15]]:
		for c in range(1, chain.size()):
			var a: int = chain[c - 1]
			var b: int = chain[c]
			var part := -1
			for sg in segs:
				if (sg[0] == a and sg[1] == b) or (sg[0] == b and sg[1] == a):
					part = sg[2]
			p[b] = p[a] + (t[b] - t[a]).normalized() * length.call(part)
	var ground := minf(minf(p[0].y, p[1].y), minf(p[2].y, p[3].y))
	for k in 16:
		p[k].y -= ground
	return p


# Biped mech (skeleton 886): legs and body are small 3D models (RESTNOBJ 877-883, "pbmb00-06"),
# each hanging from its first joint with its y axis along the segment. Rest pose in world units.
# Joints: 0/1 toes, 2/3 ankles, 4/5 knees, 6/7 hips, 8 body bottom, 9 body top.
func _add_mech(holder: Node3D) -> float:
	var segs: Array = objects.skeleton(TNObjects.MECH_SUIT)
	var p: Array[Vector3] = []                     # (right, up, forward)
	p.resize(16)
	var ankle := 0.1
	var knee_y := ankle + 0.39
	var hip_y := knee_y + 0.28
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		p[i] = Vector3(side * 0.3, 0.0, 0.24)
		p[2 + i] = Vector3(side * 0.3, ankle, 0.0)
		p[4 + i] = Vector3(side * 0.3, knee_y, 0.04)
		p[6 + i] = Vector3(side * 0.3, hip_y, 0.0)
	p[9] = Vector3(0.0, hip_y + 0.3, 0.0)
	p[8] = Vector3(0.0, hip_y - 0.08, 0.0)
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
		if part[2] <= 1:                            # a foot (ankle -> toe): a flat pad, its y along the segment laid
			# level, its x up (it hangs below the ankle), its sole on the toe's level (laid along the slanting segment
			# it was a big tilted block)
			var flat := Vector3(d.x, 0.0, d.z)
			var yf := -(flat.normalized() if flat.length() > 0.0001 else f_hips)
			var sole: float = node.mesh.get_aabb().position.x
			node.transform = Transform3D(Basis(Vector3.UP, yf, Vector3.UP.cross(yf)), Vector3(ga.x, gb.y - sole, ga.z))
			continue
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
	sm.set_shader_parameter("shade", shade if shade >= 0.0 else (LIVE_SUIT_SHADE if live else 1.0))
	mats[k] = sm
	return sm


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


func _place_camera(m: Dictionary, mis: Dictionary) -> void:
	var target := Vector2(256, 256)
	for z in mis["zones"]:
		if z["name"].to_lower().contains("drop"):
			target = Vector2(z["x"], z["y"])
			break
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
			KEY_F12:
				_oldschool_toggle()


func _oldschool_toggle() -> void:
	if oldschool_rect != null and oldschool_key != "":
		oldschool_rect.visible = not oldschool_rect.visible
		_apply_look()


# The mission's sky (see TNObjects.load_sky): shader sky with the cloud texture and the haze color
# (also the fog color), sprites placed by azimuth / elevation, the moon and the sunlight in the
# map's light direction (map resource 82).
func _set_sky(path: String, light: Vector2) -> void:
	for c in sky_root.get_children():
		c.queue_free()
	var sk: Dictionary = objects.load_sky(path, pal) if objects_ok and path != "" else {}
	# the map's light direction (azimuth, elevation; game y axis = Godot z)
	# the game's azimuth 0 is not this viewer's +x: on the running game (MAP23, azimuth 0, height 45) the slopes it
	# lights brightest face ~315 deg (heading convention), measured on a full turn against the game's terrain
	var laz: float = light.x + deg_to_rad(SUN_AZ_OFFSET)
	var to_light := Vector3(cos(light.y) * cos(laz), sin(light.y), cos(light.y) * sin(laz))
	sun.look_at_from_position(Vector3.ZERO, -to_light, Vector3.UP if absf(to_light.y) < 0.99 else Vector3.FORWARD)
	sun_to = to_light
	if sk.is_empty():
		var sm := ProceduralSkyMaterial.new()
		sm.sky_top_color = Color(0.32, 0.5, 0.78)
		sm.sky_horizon_color = Color(0.72, 0.78, 0.86)
		sm.ground_horizon_color = Color(0.72, 0.78, 0.86)
		env.sky.sky_material = sm
		env.fog_light_color = Color(0.7, 0.76, 0.84)
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
	var haze: Color = sk["haze"]
	mat.set_shader_parameter("haze", Vector3(haze.r, haze.g, haze.b))
	env.sky.sky_material = mat
	env.fog_light_color = haze
	mat.set_shader_parameter("gain", LIVE_SKY if live else 1.0)
	mat.set_shader_parameter("desat", 1.0 / env.adjustment_saturation if live and env.adjustment_enabled else 1.0)
	if sk.get("light") != null:                         # the clouds lighten towards the horizon
		var lt: Color = sk["light"]
		mat.set_shader_parameter("light", Vector3(lt.r, lt.g, lt.b))
		sky_light = lt
	sky_clouds = sk["clouds"]
	sky_haze = haze
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
	menu_rect = TextureRect.new()
	menu_rect.stretch_mode = TextureRect.STRETCH_SCALE
	menu_rect.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	# the game's own pixels (640 x 480 in its menus) blown up crisp: each pixel flat, only its edges blended over one
	# window pixel ("sharp bilinear"), so that uneven scales do not give uneven pixels
	var msh := Shader.new()
	msh.code = """shader_type canvas_item;
void fragment() {
	vec2 src = vec2(textureSize(TEXTURE, 0));
	vec2 t = UV * src;
	vec2 sc = 1.0 / max(fwidth(t), vec2(1e-4));
	vec2 c = fract(t) - 0.5;
	vec2 r = max(0.5 - 0.5 / sc, vec2(0.0));
	vec2 f = (c - clamp(c, -r, r)) * sc + 0.5;
	COLOR = texture(TEXTURE, (floor(t) + f) / src);
}"""
	var mmat := ShaderMaterial.new()
	mmat.shader = msh
	menu_rect.material = mmat
	menu_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	menu_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	menu_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
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
		if tag == "MIS":                                 # back in the game's 3D: another mission?
			var mf := pk.slice(7).get_string_from_ascii().to_upper()
			if not current.is_empty() and current["entry"]["file"].get_file().to_upper() != mf:
				_load_by_label(mf)
			continue
		if tag == "CUR" and pk.size() >= 15:
			var cw := pk.decode_s16(7)
			var ch := pk.decode_s16(9)
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
						menu_rect.visible = menu_mode
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


# The game's 3D window (in its 320 x 400 screen, stretched over the window) with the view centre 36 % down it:
# off-centre frustum, the horizontal field of view over the whole width (true 16:9: the 3D spans the screen).
func _hud_camera(fov: float) -> void:
	if hud_win.size.y <= 0:
		return
	var vs := get_viewport().get_visible_rect().size
	var near := 0.05
	var w := 2.0 * near * tan(deg_to_rad(fov) / 2.0)
	var yc := (hud_win.position.y + VIEW_CENTRE * hud_win.size.y) / 400.0 * vs.y
	camera.projection = Camera3D.PROJECTION_FRUSTUM
	camera.keep_aspect = Camera3D.KEEP_WIDTH
	camera.near = near
	camera.size = w
	camera.frustum_offset = Vector2(0, (yc - vs.y / 2.0) / vs.x * w)


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
	if menu_rect != null:
		menu_rect.visible = on and menu_tex != null
	if not play:
		return
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
	var vs := get_viewport().get_visible_rect().size
	var k := Vector2(clampf(vs.x / menu_frame.x, 1.0, 4.0), clampf(vs.y / menu_frame.y, 1.0, 4.0))
	var im := menu_cursor.duplicate() as Image
	im.resize(maxi(1, roundi(im.get_width() * k.x)), maxi(1, roundi(im.get_height() * k.y)), Image.INTERPOLATE_NEAREST)
	var hot := (Vector2(menu_cursor_hot) * k).floor()
	hot = hot.clamp(Vector2.ZERO, Vector2(im.get_width() - 1, im.get_height() - 1))
	Input.set_custom_mouse_cursor(im, Input.CURSOR_ARROW, hot)
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


# Window position -> the game's mouse range on its own screen (menus), the picture stretched over the window.
func _menu_game_pos(p: Vector2) -> Vector2i:
	var vs := get_viewport().get_visible_rect().size
	return Vector2i(clampi(int(p.x / vs.x * menu_frame.x), 0, menu_frame.x - 1),
			clampi(int(p.y / vs.y * menu_frame.y), 0, menu_frame.y - 1))


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
	# Two modes, swapped by Y (the freelook key) or Pause, which stay in the viewer: look (mouse captured, it turns
	# the view, clicks at the view's centre) and cursor (the game's own cursor follows the mouse, clicks where it
	# is: the HUD's buttons, the map, free aiming).
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
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
			var b := PackedByteArray([0x43, 1 if event.button_index == MOUSE_BUTTON_LEFT else 2, 1 if event.pressed else 0, 0, 0, 0, 0])
			b.encode_s16(3, mp.x)
			b.encode_s16(5, mp.y)
			_play_send(b)
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
			for n in get_children():                     # coop guest: the cockpit's MAP / STATUS buttons, mouse free (Y)
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
		if event.physical_keycode == KEY_F12:           # the viewer's own: old school mode on / off
			if event.pressed and not event.echo:
				_oldschool_toggle()
		elif event.physical_keycode == KEY_PAUSE or event.physical_keycode == KEY_Y:
			if event.pressed and not event.echo and play_started:
				if captured:                                # cursor mode, starting on the view's centre
					Input.mouse_mode = Input.MOUSE_MODE_HIDDEN   # the game draws its own cursor
					var vs := get_viewport().get_visible_rect().size
					Input.warp_mouse(Vector2(vs.x * 0.5, vs.y * (hud_win.position.y + VIEW_CENTRE * hud_win.size.y) / 400.0))
				else:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		elif not event.echo:
			var sc := _play_scancode(event)
			if sc != 0:
				_play_key(sc, event.pressed)
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if play and what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_play_release_all()


func _live_update() -> void:
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
	if host_btn:
		host_btn.visible = Input.mouse_mode != Input.MOUSE_MODE_CAPTURED
		if versus_btn:
			versus_btn.visible = host_btn.visible
	if hud:
		_hud_update()
	_puffs_update()
	_anims_update()
	if fps_label != null:
		fps_label.text = "%d fps" % Engine.get_frames_per_second()
	if oldschool_rect != null and pal_key != oldschool_key and pal.size() >= 256:
		var pimg := Image.create(256, 1, false, Image.FORMAT_RGB8)
		for i in 256:
			pimg.set_pixel(i, 0, pal[i])
		(oldschool_rect.material as ShaderMaterial).set_shader_parameter("pal_tex", ImageTexture.create_from_image(pimg))
		if oldschool_key == "":
			oldschool_rect.visible = not ("--smooth" in OS.get_cmdline_user_args())
			_apply_look()
		oldschool_key = pal_key
	var pk := PackedByteArray()
	while udp.get_available_packet_count() > 0:
		var q := udp.get_packet()
		if q.size() == 4 + 128 * 128 and q.slice(0, 4).get_string_from_ascii() == "VEGM":
			_live_vegetation(q.slice(4))
		elif q.size() >= 8 and q.slice(0, 4).get_string_from_ascii() == "SCOR":
			_live_scorch(q.slice(4))
		elif q.size() == 5 and q.slice(0, 4).get_string_from_ascii() == "IRVW":
			ir_on = q[4] == 1                               # the game's infrared view (key I)
			var old := oldschool_rect != null and oldschool_rect.visible
			if ir_rect != null:
				ir_rect.visible = ir_on and not old             # (the old school mode reads the view itself: it tints)
			if oldschool_rect != null:
				(oldschool_rect.material as ShaderMaterial).set_shader_parameter("ir", ir_on)
		elif q.size() >= 5 and q.slice(0, 4).get_string_from_ascii() == "SUBV":
			_sub_views(q)
		elif q.size() == 12 and q.slice(0, 4).get_string_from_ascii() == "SKYO":
			if env.sky.sky_material is ShaderMaterial:      # the game's wind offset of its clouds
				(env.sky.sky_material as ShaderMaterial).set_shader_parameter("cloud_off",
						Vector2(q.decode_float(4), q.decode_float(8)))
			for sm in ground_mats + [mats["water"]]:          # the water mirrors the same clouds
				sm.set_shader_parameter("cloud_off", Vector2(q.decode_float(4), q.decode_float(8)))
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
	if pk.size() >= 32 and not current.is_empty():
		_live_units(pk)
		_smooth_capture()
	if live_shot != "" and live_seen == live_shot_frame:
		_screenshot(live_shot)


# Game entities after the camera: count, player index, then 32 bytes each: index, class, type, active (int32),
# x, y, z (game units), heading (radians). The mission file's entities are a run of the game's table (in the same
# order, after the player): found once by their class / type, then moved, turned, hidden when gone. A destroyed
# entity's slot is reused (shots, sparks), so the run is the best match, not a perfect one.
func _live_units(pk: PackedByteArray) -> void:
	var n := pk.decode_s32(24)
	var player := pk.decode_s32(28)
	# the view's own body hides (coop: the guest's window changes suit, or watched the host's until it had one: the
	# old body shows again). A teammate is one of the mission's units (live_nodes, placed once live_off is found),
	# not only an extra: looked for again each time, else the guest saw his own suit around his eyes
	var pn: Node3D = _live_node(player) if player >= 0 else null
	if player != live_player or pn != live_player_node:
		var was: Node3D = live_player_node
		if was != null and is_instance_valid(was) and was != pn:
			was.remove_meta("player_body")
			_sub_hide(was, false, PLAYER_LAYER)
			was.remove_meta("player_body")
		if pn != null:
			_sub_hide(pn, true, PLAYER_LAYER)
		live_player = player
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
	if live_off < 0:
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
	for idx in live_fx:
		live_fx[idx].visible = false
	for idx in live_piles:
		live_piles[idx].visible = false
	for idx in live_extra:
		live_extra[idx].visible = false
	puff_units.clear()
	if ents.has(player):                             # the player's own jetpack only: around the other soldiers the
		var u = ents[player]                         # weapons' dust settles at their feet too (thousands of 6/29 in a
		puff_units.append(Vector3(u[3], u[5], u[4]))  # fight), which made puffs fill the screen; the game shows none
	_pulsar_trails(ents)
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
		# cell a decor entity, intact (drawn like the plant); a destroyed one leaves the table, its ground burnt
		var ct := Vector2i(e[0], e[1])
		if live_extra.has(idx) and live_extra[idx].get_meta("ct") != ct:
			var old: Node3D = live_extra[idx]           # slot reused by another unit
			if old.has_meta("soldier") or old.has_meta("mech"):
				_make_corpse(old, m)                    # the soldier that was there died: its body stays
			else:
				old.queue_free()
			live_extra.erase(idx)
		if not live_extra.has(idx) and e[2] != 0:
			live_extra[idx] = _add_object(m, e[0], e[1], e[3], e[4], e[6], "", false, 0.0)
			live_extra[idx].set_meta("ct", ct)
			if idx == player:
				_sub_hide(live_extra[idx], true, PLAYER_LAYER)
		if live_extra.has(idx):
			_live_place(live_extra[idx], e, m)
	for idx in joints:                                 # soldiers the game draws: its own animation
		var node: Node3D = live_extra.get(idx)
		if node == null and live_off >= 0 and idx - live_off >= 0 and idx - live_off < live_nodes.size():
			node = live_nodes[idx - live_off]
		if node != null and node.visible and node.has_meta("soldier"):
			_pose_soldier(node, joints[idx])
			if not node.has_meta("corpse"):
				node.position.y = feet[idx]              # on its lowest foot (the entity minus GAME_Z left suits
				# ~0.06 above the game's, seen up close)
		elif node != null and node.visible and node.has_meta("mech"):
			_pose_mech(node, joints[idx])
			node.position.y = feet[idx]              # on its feet: the walker's entity is 0.23 to 0.39 above them
			# as it walks (a suit's: 0.15), so GAME_Z left it floating


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
		# squadmate's picture and the button bar under the probe's (measured on two cockpits); the probe's compass
		# labels are let through by the shader
		var x0 := q.decode_s16(o + 29)
		var y0 := q.decode_s16(o + 31)
		var x1 := q.decode_s16(o + 33)
		var y1 := q.decode_s16(o + 35)
		var r := Rect2(x0, y0, x1 - x0, y1 - y0 - 16) if panel == 3 else Rect2(x0, y0 + 1, x1 - x0, y1 - y0 - 17)
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
		# name (red)
		(tr.material as ShaderMaterial).set_shader_parameter("label_rows", 16.0 if panel == 3 else (18.0 if panel == 2 else 0.0))
		(tr.material as ShaderMaterial).set_shader_parameter("label_a", 47.0 if panel == 3 else 68.0)
		(tr.material as ShaderMaterial).set_shader_parameter("label_b", 59.0 if panel == 3 else 68.0)
		var old := oldschool_rect != null and oldschool_rect.visible    # F12: the side views follow the main view
		(tr.material as ShaderMaterial).set_shader_parameter("old", old)
		if old:
			(tr.material as ShaderMaterial).set_shader_parameter("pal_tex",
					(oldschool_rect.material as ShaderMaterial).get_shader_parameter("pal_tex"))
		var idx := q.decode_s32(o + 1)
		var cam: Camera3D = sv["cam"]
		# the panel camera's zoom (the target camera: its distance to the target, 1 to 16), as the main view's
		var zoom: float = maxf(0.2, q.decode_float(o + 25))
		cam.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(SUB_FOV_PROBE if panel == 3 else SUB_FOV) / 2.0) / zoom))
		var h := q.decode_float(o + 17)
		cam.position = Vector3(q.decode_float(o + 5), q.decode_float(o + 13), q.decode_float(o + 9))
		# the probe's pitch in the viewpoint (~11 deg down) is drawn much flatter by the game: a third of it puts the
		# ridge where the game has it (measured with an undamaged suit: damage scrambles the game's own views); the
		# squadmate's and the target camera's are drawn as given
		var tilt := q.decode_float(o + 21) * (PROBE_TILT if panel == 3 else 1.0)
		cam.rotation = Vector3(tilt, atan2(-cos(h), -sin(h)), 0.0)
		var node: Node3D = _live_node(idx)
		if node != sv["node"]:
			_sub_hide(sv["node"], false)
			_sub_hide(node, true)
			sv["node"] = node
		sv["seen"] = now
	for panel in sub_views:
		var sv: Dictionary = sub_views[panel]
		var on: bool = now - int(sv["seen"]) < 500 and not menu_mode
		(sv["rect"] as TextureRect).visible = on
		(sv["vp"] as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
		if not on and sv["node"] != null:
			_sub_hide(sv["node"], false)
			sv["node"] = null


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
		var md: Dictionary = objects.model(mi.get_meta("art_ref"), pal, pal_key, pr)
		if not md.is_empty():
			mi.mesh = md["mesh"]


# Smooth motion. The game moves the camera and the units once per frame of its own (often 25-40 a second) while
# Uplink draws up to a few hundred: shown as they come, they moved by jerks. Each new game state is reached in one
# game frame (its length measured), from where it was drawn: one game frame later, but without the steps. Jumps
# of more than SMOOTH_JUMP units (a teleport, a new mission) are not eased.
const SMOOTH_JUMP := 4.0
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
	cam_from = [camera.position, yaw, pitch] if p.distance_to(to) < SMOOTH_JUMP else [p, y, pt]
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
		if not is_instance_valid(node):
			continue
		var sm: Array = node.get_meta("sm")
		node.position = (sm[0] as Vector3).lerp(sm[1], clampf(float(now - int(sm[2])) / sm_int, 0.0, 1.0))


# after the units are placed (their game positions): each one eased from where it is drawn to there
var smooth_nodes: Array[Node3D] = []

func _smooth_capture() -> void:
	var now := Time.get_ticks_msec()
	smooth_nodes.clear()
	for node in live_nodes + live_extra.values():
		if node == null or not is_instance_valid(node) or not node.visible or node.has_meta("corpse"):
			continue
		var to: Vector3 = node.position
		var sm: Array = node.get_meta("sm", [])
		if sm.is_empty() or not node.get_meta("sm_vis", false) or to.distance_to(sm[1]) >= SMOOTH_JUMP:
			sm = [to, to, now]                       # new, shown again or jumped: no easing
		elif not to.is_equal_approx(sm[1]):
			var drawn: Vector3 = (sm[0] as Vector3).lerp(sm[1], clampf(float(now - int(sm[2])) / sm_int, 0.0, 1.0))
			sm = [drawn, to, now]
		node.set_meta("sm", sm)
		node.set_meta("sm_vis", true)
		smooth_nodes.append(node)
	for node in live_nodes + live_extra.values():
		if node != null and is_instance_valid(node) and not node.visible:
			node.set_meta("sm_vis", false)
	_live_smooth()                                   # drawn eased from this frame on


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
		if nd is VisualInstance3D:
			(nd as VisualInstance3D).layers = layer if hide else 1
		stack.append_array(nd.get_children())


# A burst suit (6/33): one entity, drawn by the game as a pile of the suit's armour pieces (its limb sprites: torso,
# thighs, shins, arms, feet) lying flat every which way around it, ~0.6 unit across (seen on the running game).
# The entity is thrown up when the soldier dies and bounces to rest (its height: the whole pile follows it). Where
# each piece lies is not decoded: spread from the entity's number. The suit is the one of the soldier killed there
# (the bridge puts it in the heading; else the nearest death seen here).
const PILE_RADIUS := 0.3                      # (measured: a compact pile, ~0.5 unit across)
const PILE_SHADE := 0.8                       # lighter than the standing suits (their light grey, on the game)
const PILE_SCALE := 0.0027                    # world units per sprite pixel (measured: smaller than standing suits')


func _live_debris(idx: int, e) -> void:
	var holder: Node3D = live_piles.get(idx)
	var game_suit := int(round(e[6]))
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
			seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
	# pieces fly apart, higher and wider, turning, and fall back together onto the pile
	var gc := TNData.height_at(m, e[3], e[4])
	var lift := maxf(0.0, e[5] - GAME_Z - gc + 0.12)
	holder.position = Vector3(e[3], gc + lift, e[4])
	var k2 := clampf(lift / 0.3, 0.0, 1.0)
	var t := Time.get_ticks_msec() / 1000.0
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
# in memory, read by the bridge), and draws it as a black patch ~1.5 units wide (seen after a grenade). Here a soft
# round dark blotch as a decal on the ground, turned at random (the burnt tree picture laid flat, used before, made
# long tree-shaped streaks). Packet: count, then vertex indices (y * 513 + x, game y = Godot z).
const SCORCH_WIDTH := 1.6
const SCORCH_TINT := Color(0.13, 0.1, 0.08)
var scorch_tex: ImageTexture


func _scorch_texture() -> ImageTexture:
	if scorch_tex != null:
		return scorch_tex
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var noise := FastNoiseLite.new()
	noise.frequency = 0.12
	for y in n:
		for x in n:
			var d := Vector2(x - n / 2.0 + 0.5, y - n / 2.0 + 0.5).length() / (n / 2.0)
			var edge := 0.72 + 0.3 * noise.get_noise_2d(x, y)          # a ragged rim
			var a := clampf((edge - d) / 0.08, 0.0, 1.0)
			var g := 0.6 + 0.4 * noise.get_noise_2d(x * 3.0 + 100.0, y * 3.0)
			img.set_pixel(x, y, Color(g, g, g, a))
	img.generate_mipmaps()
	scorch_tex = ImageTexture.create_from_image(img)
	return scorch_tex


func _live_scorch(pk: PackedByteArray) -> void:
	if current.is_empty() or pk == scorch_prev:
		return
	scorch_prev = pk
	var now := {}
	var n := mini(pk.decode_u32(0), (pk.size() - 4) / 4)
	for k in n:
		now[pk.decode_u32(4 + 4 * k)] = true
	for v in scorch_decals.keys():
		if not now.has(v):
			scorch_decals[v].queue_free()
			scorch_decals.erase(v)
	var m: Dictionary = current["map"]
	for v in now:
		if scorch_decals.has(v):
			continue
		var x := float(v % 513)
		var y := float(v / 513)
		var dc := Decal.new()
		dc.texture_albedo = _scorch_texture()
		dc.size = Vector3(SCORCH_WIDTH, 1.2, SCORCH_WIDTH)
		dc.modulate = SCORCH_TINT
		dc.position = Vector3(x, TNData.height_at(m, x, y) + 0.3, y)
		dc.rotation.y = float((v * 2654435761) % 6283) / 1000.0
		dc.cull_mask = 1
		world.add_child(dc)
		scorch_decals[v] = dc


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
	if cls == 6 and typ == 29 and _live_puff(idx, pos0, e):
		return                                          # at a unit's feet: its jetpack's smoke
	if cls == 6 and typ == 33:
		_live_debris(idx, e)
		return
	if cls == 5 and typ == 5:
		_live_pulsar(idx, e)
		return
	if cls == 6 and typ == 28 and pulsar_dust.has(idx):
		return                                          # a pulsar bolt's trail: drawn with its bolt
	if cls == 6 and FX_ANIMS.has(typ):
		var now := Time.get_ticks_msec()
		if typ == 20:                                   # a blast's billows: the game scatters its 6/20 (up to 8 at
			if now - int(anim_seen.get(idx, -100000)) > 400:   # one spot) around it, each its own fireball
				var rng := RandomNumberGenerator.new()
				rng.seed = idx * 7919 + now
				_spawn_anim(pos0 + Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(0.0, 0.3), rng.randf_range(-1.2, 1.2)), FX_ANIMS[typ])
			anim_seen[idx] = now
			return
		if now - int(anim_seen.get(idx, -100000)) > 400 and not _anim_near(pos0, now):
			_spawn_anim(pos0, FX_ANIMS[typ])            # plays once, longer than the entity lives
			if typ == 23:
				smoke_pending.append([pos0, now])        # a tree's black smoke, unless it was a soldier (see below)
		anim_seen[idx] = now
		return
	if cls == 6 and typ == 25:
		if puff_seen.get(idx, -10) != live_seen - 1:
			_spawn_puff(pos0, 3.5)                        # explosion (missile impact): a big grey puff
		puff_seen[idx] = live_seen
		return
	# kinds: 0 other shot, 1 red beam (laser 5/4), 2 orange spark, 3 red dust (6/29), 4 blue beam (5/11),
	# 5 blue dust (6/28), 6 missile (5/10), 7 red particle shot (5/6), 8 green plasma (5/22 the enemies' slow
	# green streak ~0.35 unit long along its flight, in the planet palette's green; 5/25 its spray), 9 tracer
	# (5/23 machine gun bullet, and 6/7 its fading streak: a thin white line ~0.25 unit long along its flight),
	# matched on the running game
	var kind: int = 0
	if cls == 5:
		kind = {4: 1, 11: 4, 10: 6, 6: 7, 22: 8, 25: 8, 23: 9}.get(typ, 0)
		if kind == 0:
			return                                      # other shots (5/24, 5/26, 5/27 on the hover tanks, 5/29...):
			# nothing the game draws, at most a dot (a 0.8 unit glowing ball hid the walkers in a fight)
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
		elif kind == 6:
			var cn := CylinderMesh.new()                # missile: a little cone, nose ahead
			cn.top_radius = 0.0
			cn.bottom_radius = 0.045
			cn.height = 0.32
			cn.radial_segments = 6
			cn.rings = 1
			mi.mesh = cn
		else:
			var sp := SphereMesh.new()
			sp.radius = {0: 0.2, 2: 0.05, 3: 0.014, 5: 0.014, 7: 0.02, 8: 0.045, 9: 0.008, 10: 0.02}[kind]
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
					Color(1.0, 0.97, 0.85), Color(0.99, 0.25, 0.25), Color(0.93, 0.6, 0.5)][kind]
			m.emission_enabled = true
			m.emission = m.albedo_color
			m.emission_energy_multiplier = [4.0, 3.5, 2.5, 3.0, 3.0, 3.0, 2.0, 3.0, 1.3, 2.0, 1.0, 1.0][kind]
			if dust:                                    # dust: plain dots of the game's red / blue / salmon, no glow
				m.emission_enabled = false
				m.albedo_color = {3: Color(0.62, 0.0, 0.0), 5: Color(0.3, 0.42, 0.95)}.get(kind, m.albedo_color)
				m.cull_mode = BaseMaterial3D.CULL_DISABLED  # (its dots are quads facing the camera)
			m.disable_fog = true
			fx_mats[kind] = m
		mi.material_override = fx_mats[kind]
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
	if pos.distance_to(camera.position) < (0.3 if dust else 1.5):   # at the gun: inside the cockpit
		mi.visible = false
		return
	if kind == 6:
		_spawn_puff(pos, 1.4)                          # missile: its thick grey smoke trail
	if dust:
		# the game draws a dust particle (it does not move) as dots of a pixel scattered around it, mostly below,
		# drawn again elsewhere when it draws a new random number (the bridge sends it in the heading): near the
		# camera they spread over the view's lower left, far away they make a dense cloud at the impact (measured on
		# the game's picture; dots right on the particles made a thin second laser along the shot)
		var d := pos.distance_to(camera.position)
		var hs := d * DUST_PX
		var cb := camera.global_transform.basis
		var im := mi.mesh as ImmediateMesh
		im.clear_surfaces()
		im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, fx_mats[kind])
		var rnd := int(e[6])
		var tight := 0.35 if kind == 11 else 1.0        # the spark: its few pixels in the middle
		for j in {11: SPARK_DOTS, 5: 3}.get(kind, DUST_DOTS):   # (the ion beam's blue trail: barely seen)
			var r1 := float(((idx + 1) * 2654435761 + rnd * 40503 + j * 7919) % 100000) / 100000.0
			var r2 := float(((idx + 3) * 1103515245 + rnd * 12345 + j * 104729) % 100000) / 100000.0
			var r3 := float(((idx + 7) * 69069 + rnd * 2891 + j * 31337) % 100000) / 100000.0
			# (a spread of a few pixels of the game whatever the distance: wider than tall, a little below)
			var c := pos + (cb.x * (r1 - 0.5) * 2.0 * DUST_SPREAD + cb.y * ((r2 - 0.55) * 2.0 * DUST_DROP)) * d * (0.25 + 0.75 * r3) * tight * (3.0 if kind == 3 and j % 10 < int(DUST_HALO * 10) else 1.0)
			var q := [c - cb.x * hs - cb.y * hs, c + cb.x * hs - cb.y * hs, c + cb.x * hs + cb.y * hs,
					c - cb.x * hs - cb.y * hs, c + cb.x * hs + cb.y * hs, c - cb.x * hs + cb.y * hs]
			for v in q:
				im.surface_add_vertex(v)
		im.surface_end()
		mi.global_transform = Transform3D.IDENTITY
		mi.extra_cull_margin = 2.0
	elif kind == 2 or kind == 7 or kind == 10:
		mi.transform = Transform3D(Basis.IDENTITY, pos)
	else:                                           # other shots: a bolt along its flight
		var dir := Vector3.ZERO
		if not fresh:
			var prev: Vector3 = mi.get_meta("prev", pos)
			if prev.distance_to(pos) > 0.01 and prev.distance_to(pos) < 20.0:
				dir = (pos - prev).normalized()
		if dir == Vector3.ZERO:
			dir = -camera.global_transform.basis.z
		mi.look_at_from_position(pos, pos + dir, Vector3.UP if absf(dir.y) < 0.99 else Vector3.FORWARD)
		mi.rotate_object_local(Vector3.RIGHT, -PI / 2 if kind == 6 else PI / 2)   # long axis along the flight, nose ahead
	mi.set_meta("prev", pos)
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
	if pulsar_parts.is_empty():
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
	var im := mi.mesh as ImmediateMesh
	im.clear_surfaces()
	im.surface_begin(Mesh.PRIMITIVE_TRIANGLES, pulsar_mat)
	for c in pulsar_parts.get(idx, [Vector3(e[3], e[5], e[4])]):
		if c.distance_to(cam.origin) < 0.25:
			continue
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

# Effects the game draws as an animation (class 6 type -> RESTNOBJ resource, world units per pixel, frames per
# second), matched on the running game: 23 = a tree blown up (a fireball as big as the tree, turning to brown
# smoke, ~0.9 s); 20 = the orange-brown billows of a grenade or missile blast (several at one spot, about a walker's
# body wide), with the grey puff of 6/25.
# 19 = a big red burst (a walker or a vehicle hit hard; ~0.5 unit wide at its height), 10 = the red spray of an impact
# on a unit (its dots spreading ~0.35 unit), sizes read on the running game.
const FX_ANIMS := {23: [1193, 0.012, 16.0], 20: [1177, 0.006, 12.0], 19: [1176, 0.003, 14.0], 10: [1168, 0.0017, 14.0]}
var anims := []                  # [node, start msec, duration]
var smoke_pending := []          # blasts (6/23) waiting to know whether a suit burst there: [position, msec]
var anim_seen := {}
var anim_mats := {}


func _spawn_anim(pos: Vector3, fx: Array) -> void:
	var rid: int = fx[0]
	var ad: Dictionary = objects.anim(rid, pal, pal_key) if objects_ok else {}
	if ad.is_empty():
		return
	var sc: float = fx[1]
	if not anim_mats.has(rid):
		var am := ShaderMaterial.new()
		am.shader = ANIM
		am.set_shader_parameter("frames", ad["tex"])
		am.set_shader_parameter("frame_count", ad["frames"])
		am.set_shader_parameter("fps", fx[2])
		var w: float = ad["size"].x * sc
		var h: float = ad["size"].y * sc
		var a: Vector2 = ad["anchor"] * sc
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for c in [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 0), Vector2(1, 1), Vector2(0, 1)]:
			st.set_uv(c)
			st.add_vertex(Vector3(c.x * w - a.x, a.y - c.y * h, 0.0))
		anim_mats[rid] = [am, st.commit(), float(ad["frames"]) / fx[2]]
	var mi := MeshInstance3D.new()
	mi.mesh = anim_mats[rid][1]
	mi.material_override = anim_mats[rid][0]
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.extra_cull_margin = 2.0
	mi.position = pos
	world.add_child(mi)
	anims.append([mi, Time.get_ticks_msec(), anim_mats[rid][2]])


# The game makes two effects of a blown-up tree at the same spot, drawn as one fireball: one animation per spot.
func _anim_near(pos: Vector3, now: int) -> bool:
	for an in anims:
		if now - int(an[1]) < 1000 and (an[0] as Node3D).position.distance_to(pos) < 1.0:
			return true
	return false


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
		if age >= float(anims[k][2]):
			mi.queue_free()
			anims.remove_at(k)
		else:
			mi.set_instance_shader_parameter("age", age)
var fps_label: Label
var dead_suits := []       # [position, suit] of the soldiers killed: their pieces of armour around
var puff_units := []      # positions of the units this update (jetpacks)
func _live_puff(idx: int, pos: Vector3, e) -> bool:
	if not puff_units.any(func(u): return Vector2(u.x, u.z).distance_to(Vector2(e[3], e[4])) < 0.25):
		return false                                # not right under a unit: a weapon's red dust
	var fresh: bool = puff_seen.get(idx, -10) != live_seen - 1
	puff_seen[idx] = live_seen
	if fresh:
		_spawn_puff(pos, 1.0)
	return true


func _spawn_puff(pos: Vector3, size: float, delay := 0.0, vel := Vector3.ZERO, tint := 1.0, dense := 1.0) -> void:
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
	puffs.append([mi, Time.get_ticks_msec() + int(delay * 1000.0), pos, vel])


func _puffs_update() -> void:
	var now := Time.get_ticks_msec()
	var keep := []
	for p in puffs:
		var age := (now - int(p[1])) / 1000.0
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
	if e[0] == 1 and e[2] == 0:
		_make_corpse(node, m)
		return
	if node.has_meta("corpse"):                      # alive again: the mission was restarted
		node.remove_meta("corpse")
	# units (classes 1-3) and buildings set up in play (a deployed turret): the game's own height, already real
	# (no extra lift: a probe hovers by itself)
	if (e[0] >= 1 and e[0] <= 3) or (e[0] == 4 and not node.has_meta("mission")):
		node.position = Vector3(e[3], e[5] - GAME_Z, e[4])
	elif e[0] == 0 and not node.has_meta("mission"):
		node.position = Vector3(e[3], e[5], e[4])        # decor made in play (a hit plant, rubble): the game's height
		# (a rock left 0.13 above the map's ground there)
	else:
		node.position = Vector3(e[3], TNData.height_at(m, e[3], e[4]) + float(node.get_meta("lift", 0.0)), e[4])
	if e[0] != 2:
		node.basis = Basis(Vector3.UP, -e[6])           # (a body tipped over is set back up)
		return
	# vehicles lie on the ground like the game draws them (its entity has only a heading): the slope under them,
	# eased so that bumps do not shake them
	var x: float = e[3]
	var y: float = e[4]
	var n := Vector3(TNData.height_at(m, x - 0.6, y) - TNData.height_at(m, x + 0.6, y), 1.2,
			TNData.height_at(m, x, y - 0.6) - TNData.height_at(m, x, y + 0.6)).normalized()
	var up: Vector3 = node.get_meta("up", n)
	up = up.lerp(n, 0.2).normalized()
	node.set_meta("up", up)
	var yawed := Basis(Vector3.UP, -e[6])
	node.basis = Basis(Quaternion(Vector3.UP, up)) * yawed


func _process(delta: float) -> void:
	if guest_win and look_off != Vector2.ZERO:
		if not (free_look or Input.is_physical_key_pressed(KEY_ALT)):
			look_off = look_off.move_toward(Vector2.ZERO, delta * 6.0)   # back to the suit's view in ~0.3 s
		camera.rotation = Vector3(pitch + look_off.y, yaw + look_off.x, 0)
	if hd_movie_box != null and hd_movie_box.visible and hd_movie.get_video_texture() != null:
		var vsz := hd_movie.get_video_texture().get_size()
		if vsz.y > 0:
			hd_movie_box.ratio = vsz.x / vsz.y           # the video at its own proportions, black around
	sky_root.position = camera.position
	if live:
		_live_update()
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
