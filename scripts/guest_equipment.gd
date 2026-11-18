# Co-op guest: his DRONE and A.S.F. (the suit's auxiliary device) in his cockpit's right panel, drawn as the game
# draws the player's, from the host bridge's 'GEQ' packets (live/guest_equipment.py, TN_COOP_EQUIP=1 on the host);
# his actions go back to the bridge as 'E' packets (that file says which). Created by coop_hud.gd, which hands it
# the 'GEQ' packets (feed) and calls draw() at the end of its panel drawing.
#
# The game's panels (English exe; the panel drawers read byte 0x35A540: its big layout, sent in the packet):
#   A.S.F. (mode 12, 0x2722E8)  the device's picture (RESHLMHI 523 + device) over the panel, its name (RESGAME 0x16E
#       string 0x30 + device) at 6, 4 in the HUD letters (RESHLMHI 503, colour 0x1D); a device of the one-shot mask:
#       "%2d LEFT" at 42, 64 (32 small); the shield: a red (0x26) bar 7-77, 66-78 filled with 0x1D as its charge /
#       its full charge; then, unless it is always on, the button 7-77, 82-102 (41-51 small) in 0x84 (red 0x26: the
#       Explod-O-Drone while a drone is out; 0x4E a moment after a use) with its label in the middle: string 0x54 +
#       device when none is left, 0x48 + device while on, else 0x3C + device.
#   DRONE (modes 16 to 20)  none out: LAUNCH DRONE (0x271C94: RESHLMHI 573 frame 8, "LAUNCH DRONE" / "NO DRONES LEFT"
#       at 4, 4, "%2d LEFT" at 50, 45), a click launches it and the panel turns to its map (SELECT DESTINATION, a click
#       there sends the drone, 0x273347); out: its camera with a bar of buttons in the bottom 16 rows (8 small):
#       RECALL 0-32, MAP 32-55, VIEW 55-82 (tables 0x35B2D0 and on: the Explod-O-Drone's TARGET, then TARGET LOCKED
#       and ABORT); VIEW swaps the drone's camera with the main view (the panel then shows his own view and one
#       button, SWAP WITH HUD); "DRONE / RECALLED" in red (0x44) at 24, 24 while it flies back.
#
# Hooks for the cockpit's buttons (the A.S.F. / DRONE buttons of his right panel, the clicks in his window):
#   show_page("asf" | "drone" | "")  what his right panel shows ("": his weapon, coop_hud.gd's own)
#   click(at) -> bool                a left click at (x, y) of the game's 320 x 400 screen: true if it was on one of
#                                    these panels' buttons (taken)
#   map_click(world) -> bool         a click on his map at world x, y: true if it sent his drone there (taken)
# Without those buttons: the drone's page shows while his drone is out, the A.S.F.'s a moment after he uses it (5),
# as the game turns a panel to them.
extends Node

const LGRes = preload("res://scripts/lgres.gd")
const TNObjects = preload("res://scripts/tn_objects.gd")
const ASF_PIC := 523
const LAUNCH_PIC := 573
const LAUNCH_FRAME := 8
const C_TEXT := 0x1D
const C_BUTTON := 0x84
const C_RED := 0x26
const C_LIT := 0x4E
const C_ALERT := 0x44
const ONE_SHOT := 1                 # the packet's kinds: 0 always on, 1 one-shot, 2 on / off
const SHIELD := 8
const EXPLODO := 10
const HOME := Vector2(217, 264)     # the right panel's corner in the usual cockpit (coop_hud.gd's reg_move[2] moves it)
const SIZE := Vector2(82, 104)
const BAR_ROWS := [16.0, 8.0]       # the drone panel's buttons: its bottom rows (big, small layout)
const PANEL_TILT := 0.3             # (viewer.gd's PROBE_TILT, SUB_FOV_PROBE, SUB_FOV_SELF)
const FOV_DRONE := 78.0
const FOV_SELF := 84.55
const HIDE_LAYER := 1 << 19         # (viewer.gd's SUB_HIDE_LAYER)

var hud                             # coop_hud.gd
var last := -100.0
var clock := 0.0
var s := {}                         # the last 'GEQ' state
var page := ""                      # his right panel: "", "asf", "drone" (show_page)
var page_set := false               # the page was chosen by a button (else: shown by events)
var asf_until := -100.0             # an A.S.F. event: its page until then
var last_msg := 0
var was_drone := 0
var texts := PackedStringArray()    # RESGAME 0x16E in his game's language
var pics := {}
var cam_vp: SubViewport             # the drone panel's camera (his own: over the cockpit, where the viewer's side views are not)
var cam: Camera3D
var hidden: Node3D                  # the drone's model, hidden from its own camera (viewer.gd's _sub_hide)
var hidden_e := 0


func _ready() -> void:
	if OS.get_environment("TN_GUEST_EQUIP_PAGE") != "":         # (tests: a page shown from the start)
		page = OS.get_environment("TN_GUEST_EQUIP_PAGE")
		page_set = true


func _process(delta: float) -> void:
	clock += delta
	_camera_follow()


func feed(pk: PackedByteArray) -> void:
	if pk.size() < 48 or pk[3] < 1:
		return
	var n := {
		"drone": pk.decode_u16(4), "dtype": pk[6], "left": pk[7], "dstate": pk[8], "view": pk[9] != 0,
		"select": pk[10] != 0, "asf": pk[11], "on": pk[12] != 0, "ok": pk[13] != 0, "kind": pk[14], "big": pk[15] != 0,
		"count": pk.decode_s32(16), "full": pk.decode_s32(20),
		"dpos": Vector3(pk.decode_float(24), pk.decode_float(28), pk.decode_float(32)),
		"dhead": pk.decode_float(36), "dpitch": pk.decode_float(40), "target": pk.decode_u16(44),
		"msg": pk[46], "msg_left": pk[47] / 10.0}
	n["own"] = [pk.decode_float(48), pk.decode_float(52), pk.decode_float(56), pk.decode_float(60), pk.decode_float(64)] \
		if pk.size() >= 68 else []
	if n["msg"] != 0 and n["msg"] != last_msg:
		asf_until = clock + 3.0                                    # (the game turns a panel to the A.S.F. when it is used)
	last_msg = n["msg"]
	if n["drone"] != 0 and was_drone == 0 and not page_set:
		page = "drone"
	if n["drone"] == 0 and was_drone != 0 and not page_set:
		page = ""
	was_drone = n["drone"]
	s = n
	last = clock


func show_page(which: String) -> void:
	page = which
	page_set = which != ""


func shown() -> String:
	if s.is_empty() or clock - last > 2.0:
		return ""
	if clock < asf_until and not page_set:
		return "asf"                                               # (the game turns a panel to it when it is used)
	return page


func _origin() -> Vector2:
	return HOME + (hud.reg_move[2] if hud and hud.reg_move.size() > 2 else Vector2.ZERO)


func _send(b: PackedByteArray) -> void:
	if hud and hud.lobby:
		hud.lobby.out.put_packet(b)


func _act(a: int, v := -1) -> void:
	var b := PackedByteArray([0x45, a])
	if v >= 0:
		b.append(v)
	_send(b)


# ---- clicks
func click(at: Vector2) -> bool:
	var which := shown()
	if which == "":
		return false
	var p := at - _origin()
	if p.x < 0 or p.y < 0 or p.x >= SIZE.x or p.y >= SIZE.y:
		return false
	var big: bool = s.get("big", true)
	if which == "asf":
		if s["kind"] == 0:
			return true
		var y0 := 82.0 if big else 41.0
		if p.x >= 7 and p.x < 77 and p.y >= y0 and p.y < y0 + (20.0 if big else 10.0):
			_act(5)
		return true
	if s["drone"] == 0:
		_act(1)                                                    # LAUNCH DRONE: a click on the panel
		return true
	if s["select"]:
		var w := _panel_map_world(p)
		if w.x > 0:
			return map_click(w)
		return true
	if p.y < SIZE.y - (BAR_ROWS[0] if big else BAR_ROWS[1]):
		return true
	if s["view"]:
		_act(4, 0)                                                 # SWAP WITH HUD: the main view back on him
	elif p.x < 32:
		if s["dtype"] == 0:
			_act(2)                                                # RECALL (the Explod-O-Drone's TARGET: his lock)
	elif p.x < 55:
		_act(6, 1)                                                 # MAP: SELECT DESTINATION
	else:
		_act(4, 1)                                                 # VIEW
	return true


func map_click(world: Vector2) -> bool:
	if s.is_empty() or not s["select"] or s["drone"] == 0 or s["dtype"] != 0:
		return false
	var b := PackedByteArray([0x45, 3, 0, 0, 0, 0, 0, 0, 0, 0])
	b.encode_float(2, world.x)
	b.encode_float(6, world.y)
	_send(b)
	return true


# his map (coop_hud.gd's picture) fitted in the drone's panel while it waits for a destination: a point of the panel
# -> the world (x = 0: off the map)
func _panel_map_world(p: Vector2) -> Vector2:
	if hud == null or hud.map_tex == null:
		return Vector2.ZERO
	var sz: Vector2 = hud.map_tex.get_size()
	var px := p / SIZE * sz
	return Vector2(hud.map_from) + Vector2(px.x, px.y / 2.0) * hud.map_step


# ---- drawing
func _col(i: int) -> Color:
	return hud.hud_pal[i] if hud.hud_pal.size() > i else Color.WHITE


func _str(i: int) -> String:
	if texts.is_empty():
		var vp: Node = hud.get_parent()
		if vp and "data" in vp:
			var r = LGRes.open(vp.data.data_dir().path_join("RESGAME.RES"))
			if r and r.has(0x16E):
				texts = r.strings(0x16E)
		if texts.is_empty():
			texts = PackedStringArray([""])
	return texts[i] if i < texts.size() else ""


func _pic(rid: int, frame := 0) -> Texture2D:
	var key := rid * 64 + frame
	if pics.has(key):
		return pics[key]
	var tex: Texture2D = null
	var fr: Array = hud._helmet_frames(rid)
	if frame < fr.size() and not hud.hud_pal.is_empty():
		var img: Image = TNObjects._bitmap(fr[frame], hud.hud_pal)
		if img:
			tex = ImageTexture.create_from_image(img)
	pics[key] = tex
	return tex


func _box(o: Vector2, x0: float, y0: float, x1: float, y1: float, c: Color) -> void:
	hud.panel.draw_rect(hud._grect(o.x + x0, o.y + y0, o.x + x1, o.y + y1), c)


func _write(o: Vector2, t: String, x: float, y: float, c: Color) -> void:
	var row := 0
	for line in t.split("\n"):
		var fh: float = (hud.big_font.decode_s16(82) + 1.0) if hud.big_font.size() >= 88 else 8.0
		hud._glyphs(line, o.x + x, o.y + y + fh * row, c)
		row += 1


func _width(t: String) -> float:
	var f: PackedByteArray = hud.big_font
	if f.size() < 88:
		return 4.0 * t.length()
	var first := f.decode_s16(36)
	var w := 0.0
	for ch in t.to_ascii_buffer():
		if ch >= first and ch <= f.decode_s16(38) and 88 + 2 * (ch - first) <= f.size():
			w += f.decode_s16(86 + 2 * (ch - first)) - f.decode_s16(84 + 2 * (ch - first))
	return w


func draw() -> void:
	var which := shown()
	if which == "" or hud == null or hud.hud_pal.is_empty():
		return
	var o := _origin()
	_box(o, 0, 0, SIZE.x, SIZE.y, Color.BLACK)
	if which == "asf":
		_draw_asf(o)
	else:
		_draw_drone(o)


func _draw_asf(o: Vector2) -> void:
	var t: int = s["asf"]
	if t > 11:
		_write(o, _str(0x5F), 6, 4, _col(C_TEXT))                  # (Not Available)
		return
	var pic := _pic(ASF_PIC + t)
	if pic:
		hud.panel.draw_texture_rect(pic, hud._grect(o.x, o.y, o.x + pic.get_width(), o.y + pic.get_height()), false)
	_write(o, _str(0x30 + t), 6, 4, _col(C_TEXT))
	if s["kind"] == 0:
		return
	var big: bool = s["big"]
	if s["kind"] == ONE_SHOT:
		_write(o, _str(0x6E).replace("%2d", "%2d" % s["count"]), 42, 64 if big else 32, _col(C_TEXT))
	elif t == SHIELD:
		var y := 66.0 if big else 33.0
		var h := 12.0 if big else 6.0
		_box(o, 7, y, 77, y + h, _col(C_RED))
		var w := 0.0
		if s["full"] > 0 and s["count"] > 0:
			w = maxf(1.0, 68.0 * s["count"] / s["full"])
		_box(o, 8, y + 1, 8 + minf(68.0, w), y + h - 1, _col(C_TEXT))
	var y0 := 82.0 if big else 41.0
	var bc := C_BUTTON
	if s["msg_left"] > 2.2:
		bc = C_LIT
	elif t == EXPLODO and s["drone"] != 0:
		bc = C_RED
	_box(o, 7, y0, 77, y0 + (20.0 if big else 10.0), _col(bc))
	var label := _str((0x54 if s["count"] == 0 else (0x48 if s["on"] else 0x3C)) + t)
	_write(o, label, 7.0 + floorf((70.0 - _width(label)) / 2.0), y0 + 2.0, _col(C_TEXT))


func _draw_drone(o: Vector2) -> void:
	var big: bool = s["big"]
	if s["drone"] == 0:
		var pic := _pic(LAUNCH_PIC, LAUNCH_FRAME)
		if pic:
			hud.panel.draw_texture_rect(pic, hud._grect(o.x, o.y, o.x + pic.get_width(), o.y + pic.get_height()), false)
		_write(o, _str(0x6F if s["left"] > 0 else 0x70), 4, 4, _col(C_TEXT))
		_write(o, _str(0x6E).replace("%2d", "%2d" % s["left"]), 50, 45, _col(C_TEXT))
		return
	if s["select"] and hud.map_tex:
		hud.panel.draw_texture_rect(hud.map_tex, hud._grect(o.x, o.y, o.x + SIZE.x, o.y + SIZE.y), false)
		_write(o, _str(0x73), 4, 4, _col(C_TEXT))
		return
	var bar: float = BAR_ROWS[0] if big else BAR_ROWS[1]
	if cam_vp:
		hud.panel.draw_texture_rect(cam_vp.get_texture(), hud._grect(o.x, o.y, o.x + SIZE.x, o.y + SIZE.y - bar), false)
	var y0 := SIZE.y - bar
	var buttons: Array
	if s["view"]:
		buttons = [[0x76, 0, 82, 20]]
	elif s["dtype"] == 0:
		buttons = [[0x72, 0, 32, 4], [0x73, 32, 55, 38], [0x74, 55, 82, 60]]
	elif s["target"] != 0:
		_write(o, _str(0x71), 15, 40, _col(C_ALERT))
		buttons = [[0x7A, 0, 82, 30]]
	else:
		buttons = [[0x75, 0, 32, 4], [0x73, 32, 55, 38], [0x74, 55, 82, 60]]
	if s["dstate"] == 3:
		_write(o, _str(0x77), 24, 24, _col(C_ALERT))
	for b in buttons:
		_box(o, b[1], y0, b[2], SIZE.y, _col(C_RED))
		_box(o, b[1] + 1, y0 + 1, b[2] - 1, SIZE.y - 1, Color.BLACK)
		_write(o, _str(b[0]), b[3], y0 + (4.0 if big else 0.0), _col(C_TEXT))


# the drone panel's camera: the drone's (its heading, a third of its pitch as the viewer's side views), or his own
# eye while the main view is the drone's
func _camera_follow() -> void:
	var on: bool = shown() == "drone" and not s.is_empty() and s["drone"] != 0 and not s["select"]
	if not on:
		if cam_vp:
			cam_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_hide(0)
		return
	if cam_vp == null:
		cam_vp = SubViewport.new()
		cam_vp.world_3d = get_viewport().world_3d
		cam_vp.size = Vector2i(246, 264)
		add_child(cam_vp)
		cam = Camera3D.new()
		cam.keep_aspect = Camera3D.KEEP_WIDTH
		cam.near = 0.05
		cam.far = 400.0
		cam_vp.add_child(cam)
	cam_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var pos: Vector3
	var h: float
	var tilt: float
	if s["view"] and s["own"].size() == 5:
		var e: Array = s["own"]
		pos = Vector3(e[0], e[2], e[1])
		h = e[3]
		tilt = e[4]
		cam.fov = FOV_SELF
		cam.cull_mask = 0xFFFFF & ~(1 << 18)                       # (not his own body: the viewer's PLAYER_LAYER)
	else:
		var d: Vector3 = s["dpos"]
		pos = Vector3(d.x, d.z + 0.1875, d.y)
		h = s["dhead"]
		tilt = s["dpitch"] * PANEL_TILT
		cam.fov = FOV_DRONE
		cam.cull_mask = 0xFFFFF & ~HIDE_LAYER                      # (not the drone itself: it carries the camera)
		_hide(s["drone"])
	cam.position = pos
	cam.rotation = Vector3(tilt, atan2(-cos(h), -sin(h)), 0.0)


func _hide(e: int) -> void:
	var vp: Node = hud.get_parent() if hud else null
	if vp == null or not vp.has_method("_live_node") or not vp.has_method("_sub_hide"):
		return
	var node: Node3D = vp._live_node(e) if e != 0 else null
	if node == hidden and e == hidden_e:
		return
	if hidden and is_instance_valid(hidden):
		vp._sub_hide(hidden, false)
	hidden = node
	hidden_e = e
	if node:
		vp._sub_hide(node, true, HIDE_LAYER)
