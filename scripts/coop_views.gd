# The co-op guest's own views (his window; a child of coop_hud.gd), each his own whatever the host's:
# - the game's infrared view (I): viewer.gd _ir_set, as the host's bridge sets the host's ('IRVW', not relayed);
# - the game's full view (G): the 3D over the whole screen but a strip at the top, the cockpit gone; the game draws
#   its helmet's second picture over it (RESHLMH?.RES 751: the top bars, the weapon box at the bottom; 750 is the
#   cockpit), his compass lower, his armour indicator and the crosshair in the middle of that window;
# - the game's 360 view (B): the three bottom panels show what is left of him, behind him and right of him, mirrors
#   (the panels' flag 0x40), the player's view turned by each panel's heading (the bridge's 'SUBV' 5 to 7, made here
#   from his own camera: viewer.gd _sub_views). Not in the full view (the game draws none: the panels are under its 3D).
# The keys are the game's commands as his Controls page has them (data/controls.txt: ir, full, v360), turned by his
# key map (viewer.gd _play_scancode); they are not sent to the host's game. The helmet: the one whose cockpit picture
# (750) is the host's (the cockpit packet), read from his own game files.
extends Node

const LGRes = preload("res://scripts/lgres.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
const KEY_IR := 0x17
const KEY_FULL := 0x22
const KEY_AROUND := 0x30
const HELMETS := ["RESHLMHH.RES", "RESHLMHN.RES", "RESHLMHS.RES", "RESHLMHP.RES"]
# the game's 3D window in the full view (its window 0, 16, 320 x 383: the bridge's centre())
const FULL_WIN := Rect2(0, 16, 320, 383)
# where the game draws in the full view (measured on its screen, mission 30), from the 3D window's corner: the
# compass strip (its region in the full view: 70, 18 - 250, 34; 180 pixels for a turn where the cockpit's has 256)
# and the armour indicator (the cockpit's at 211, 144: coop_hud.gd INDICATOR_AT; here 244, 338 on the screen)
const FULL_COMPASS := Rect2(70, 2, 180, 16)
const FULL_INDICATOR := Vector2i(244, 322)
# the 360 view's panels, left to right (the game's panels 0, 1, 2: COMM, map, WEAPON), the heading each adds to the
# player's (word +0x28 of the panel, 65536 a turn: read in the game, 0xC000, 0x8000, 0x4000)
const AROUND_TURN := [0xC000, 0x8000, 0x4000]
const AROUND_SIZE := [Vector2(82, 104), Vector2(84, 108), Vector2(82, 104)]

var hud: Node                         # coop_hud.gd
var ir := false
var full := false
var around := false
var ir_t := -1.0
var around_sent := false
var shown := 0                        # the views applied: 1 full, 2 around
var cockpit_tex: Texture2D            # the cockpit picture as coop_hud.gd made it
var cockpit_rgba := PackedByteArray()
var cockpit_win := Rect2()
var holes_tex: Texture2D              # ... with the three bottom panels see-through (360)
var helmet := ""                      # the host's helmet file (matched on his cockpit picture)
var arts := {}                        # file -> [750 indices, 751 indices]
var full_tex: Texture2D               # the full view's picture (751), his bars put out
var full_left := Vector2.ZERO         # the full view's bars from the cockpit's (rows 30-33)
var full_right := Vector2.ZERO
var full_box := Rect2()               # the weapon box in the full view
var white: ImageTexture


func _ready() -> void:
	hud = get_parent()
	var w := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	w.fill(Color.WHITE)
	white = ImageTexture.create_from_image(w)


func _vp() -> Node:
	return hud.get_parent() if hud else null


# his key (the game's command, after his key map): true if it is one of these views'
func key(sc: int) -> bool:
	match sc:
		KEY_IR:
			ir = not ir
			ir_t = -1.0
		KEY_FULL:
			full = not full
			apply()
			_toast("Full view: " + ("on" if full else "off"))
		KEY_AROUND:
			around = not around
			apply()
			_toast("360 view: " + ("on" if around else "off"))
		_:
			return false
	return true


func _toast(text: String) -> void:
	var vp := _vp()
	if vp and vp.has_method("_mode_toast"):
		vp._mode_toast(text)                             # (the modes' notice, mode_toast.gd)


func full_on() -> bool:
	return full and full_tex != null and hud.state == 0


func around_on() -> bool:
	return around and not full_on() and holes_tex != null and hud.state == 0


# a cockpit packet's picture: false if it is not one to take (the host's own full view: his layout, not the guest's)
func take(win: Rect2) -> bool:
	return win.size.y < 300


# the cockpit's picture as coop_hud.gd made it (raw: index, alpha a pixel; rgba: its colours)
func cockpit(raw: PackedByteArray, rgba: PackedByteArray, tex: Texture2D, win: Rect2) -> void:
	cockpit_tex = tex
	cockpit_rgba = rgba
	cockpit_win = win
	if helmet == "" or _match(helmet, raw) < 0.9:
		var best := 0.0
		for f in HELMETS:
			var s := _match(f, raw)
			if s > best:
				best = s
				helmet = f
		if best < 0.6:
			helmet = ""
	_full_make()
	_holes_make()
	apply()


# the share of the helmet's cockpit picture (750) found on the host's, a pixel in 7
func _match(f: String, raw: PackedByteArray) -> float:
	var a := _art(f, 0)
	if a.size() != 320 * 400:
		return 0.0
	var n := 0
	var same := 0
	for p in range(0, 320 * 400, 7):
		if a[p] != 0 and raw[2 * p + 1] == 255:
			n += 1
			if raw[2 * p] == a[p]:
				same += 1
	return float(same) / n if n > 200 else 0.0


# a helmet's picture: k 0 the cockpit (750), 1 the full view (751); indices, 320 x 400 (empty: none)
func _art(f: String, k: int) -> PackedByteArray:
	if not arts.has(f):
		var got := [PackedByteArray(), PackedByteArray()]
		var vp := _vp()
		if vp and "data" in vp:
			var res = LGRes.open(vp.data.data_dir().path_join(f))
			for j in 2:
				if res and res.has(750 + j):
					var fr := LGRes.frames(res.data(750 + j))
					if fr.size() > 0 and (fr[0] as PackedByteArray).size() > 12 and (fr[0] as PackedByteArray).decode_u16(8) == 320 \
							and (fr[0] as PackedByteArray).decode_u16(10) == 400:
						got[j] = TNObjects._bitmap_idx(fr[0])
		arts[f] = got
	return arts[f][k]


# the first 4 x 4 led cell of a colour (the bars' first: 0x46 left, 0x83 right) in the top rows of a picture
func _cell(a: PackedByteArray, v: int, w: int) -> Vector2:
	for y in 60:
		for x in range(40, 280):
			var ok := true
			for dy in 4:
				for dx in w:
					if a[320 * (y + dy) + x + dx] != v:
						ok = false
						break
				if not ok:
					break
			if ok:
				return Vector2(x, y)
	return Vector2(-1, -1)


func _full_make() -> void:
	full_tex = null
	var a := _art(helmet, 1) if helmet != "" else PackedByteArray()
	var pal: PackedColorArray = hud.hud_pal
	if a.size() != 320 * 400 or pal.size() < 256:
		return
	var lf := _cell(a, 0x46, 4)
	var rf := _cell(a, 0x83, 3)
	if lf.x < 0 or rf.x < 0:
		return
	# the bars' cells: coop_hud.gd's (the usual cockpit's, rows 30-33, the left bar's second cell at 76, the right
	# bar's first at 165) moved to where this picture has its first ones; their leds put out (colour 0, as the game's
	# unlit ones), his lit again over them
	full_left = lf - Vector2(76, 30)
	full_right = rf - Vector2(165, 30)
	var idx := a.duplicate()
	for cells in [[hud.LEFT_LEDS, full_left], [hud.RIGHT_LEDS, full_right]]:
		var d: Vector2 = cells[1]
		for cl in cells[0]:
			for y in range(30, 34):
				for x in range(int(cl[0]), int(cl[1])):
					var p := 320 * (y + int(d.y)) + x + int(d.x)
					if p >= 0 and p < idx.size() and idx[p] != 0:
						idx[p] = 0
	# the weapon box: the one square of 26 x 26 of a single colour
	var boxes := {}
	for p in idx.size():
		var v := idx[p]
		if v == 0:
			continue
		var x := p % 320
		var y := p / 320
		if not boxes.has(v):
			boxes[v] = [x, y, x, y, 0]
		var b: Array = boxes[v]
		b[0] = mini(b[0], x)
		b[1] = mini(b[1], y)
		b[2] = maxi(b[2], x)
		b[3] = maxi(b[3], y)
		b[4] += 1
	full_box = Rect2()
	for v in boxes:
		var b: Array = boxes[v]
		if b[2] - b[0] == 25 and b[3] - b[1] == 25 and b[4] == 676:
			full_box = Rect2(b[0], b[1], 26, 26)
	var rgba := PackedByteArray()
	rgba.resize(320 * 400 * 4)
	var e: Rect2i = hud.ENERGY_E
	var eo := Vector2i(full_right)
	for p in idx.size():
		var col := pal[idx[p]]
		var x := p % 320
		var y := p / 320
		if Rect2i(e.position + eo, e.size).has_point(Vector2i(x, y)):
			var gr := col.g8                                  # the energy's "E" in the leds' orange, as the cockpit's
			if gr >= 96 and col.r8 * 2 < gr and col.b8 * 2 < gr:
				col = hud.ENERGY_DIM.lerp(hud.ENERGY_LIT, clampf((gr - 131.0) / 41.0, 0.0, 1.0))
		rgba[4 * p] = col.r8
		rgba[4 * p + 1] = col.g8
		rgba[4 * p + 2] = col.b8
		rgba[4 * p + 3] = 255 if a[p] != 0 else 0
	full_tex = ImageTexture.create_from_image(Image.create_from_data(320, 400, false, Image.FORMAT_RGBA8, rgba))


# the cockpit with the three bottom panels' frames see-through: the 360 view's cameras under it (viewer.gd sub_layer)
func _holes_make() -> void:
	holes_tex = null
	if cockpit_rgba.size() != 320 * 400 * 4:
		return
	var rgba := cockpit_rgba.duplicate()
	for k in 3:
		var r := _around_rect(k)
		for y in range(int(r.position.y), int(r.end.y)):
			for x in range(int(r.position.x), int(r.end.x)):
				if x >= 0 and x < 320 and y >= 0 and y < 400:
					rgba[4 * (320 * y + x) + 3] = 0
	holes_tex = ImageTexture.create_from_image(Image.create_from_data(320, 400, false, Image.FORMAT_RGBA8, rgba))


# panel k's camera picture (the game's: the whole frame but its top row; viewer.gd _sub_views)
func _around_rect(k: int) -> Rect2:
	var at: Vector2 = hud.REG_HOME[k] + hud.reg_move[k]
	return Rect2(at.x, at.y + 1, AROUND_SIZE[k].x, AROUND_SIZE[k].y - 1)


# the picture and the 3D window for the view he has
func apply() -> void:
	if hud == null or cockpit_tex == null:
		return
	var vp := _vp()
	if full_on():
		hud.cockpit.texture = full_tex
		hud.win = FULL_WIN
	else:
		hud.cockpit.texture = holes_tex if around_on() else cockpit_tex
		hud.win = cockpit_win
	if vp and "hud_win" in vp:
		vp.hud_win = Rect2i(hud.win)
	hud.map_dirty = true


func _process(delta: float) -> void:
	var vp := _vp()
	if vp == null:
		return
	var mode := (1 if full_on() else 0) + (2 if around_on() else 0)
	if mode != shown:                                 # (his suit down, back: the views follow)
		shown = mode
		apply()
	ir_t -= delta
	if ir_t < 0.0 and vp.has_method("_ir_set"):     # (again now and then: water, the old school look, as the bridge's)
		ir_t = 0.1
		vp._ir_set(ir)
	var on: bool = around_on() and hud.root.visible and hud.cockpit.visible
	if on and vp.has_method("_sub_views") and "camera" in vp and vp.camera != null:
		var cam: Camera3D = vp.camera
		var q := "SUBV".to_ascii_buffer()
		q.append(3)
		var h: float = -float(vp.yaw) - PI / 2.0              # the game's heading of his view (viewer.gd: yaw = -h - pi / 2)
		for k in 3:
			var r := _around_rect(k)
			var e := PackedByteArray()
			e.resize(37)
			e[0] = 5 + k
			e.encode_s32(1, hud.entity)
			e.encode_float(5, cam.position.x)
			e.encode_float(9, cam.position.z)
			e.encode_float(13, cam.position.y)
			e.encode_float(17, h + AROUND_TURN[k] / 65536.0 * TAU)
			e.encode_float(21, float(vp.pitch))
			e.encode_float(25, 1.0)
			e.encode_s16(29, int(r.position.x))
			e.encode_s16(31, int(r.position.y) - 1)
			e.encode_s16(33, int(r.end.x))
			e.encode_s16(35, int(r.end.y))
			q.append_array(e)
		vp._sub_views(q)
		for k in [5, 6, 7]:                              # (no game screen under them: nothing of it let through)
			var sv: Dictionary = vp.sub_views.get(k, {})
			if not sv.is_empty():
				((sv["rect"] as TextureRect).material as ShaderMaterial).set_shader_parameter("hud", white)
		around_sent = true
	elif around_sent and vp.has_method("_sub_views"):
		# none, each frame until the viewer has taken them off (it keeps a view 0.1 s after its last news)
		var q := "SUBV".to_ascii_buffer()
		q.append(0)
		vp._sub_views(q)
		around_sent = false
		for k in [5, 6, 7]:
			var sv: Dictionary = vp.sub_views.get(k, {})
			if not sv.is_empty() and (sv["rect"] as TextureRect).visible:
				around_sent = true
