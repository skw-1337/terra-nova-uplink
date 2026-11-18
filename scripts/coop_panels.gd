# The co-op guest's cockpit buttons and map zoom (a part of coop_hud.gd, its child; the guest's window only). As the
# game's own, read in its code (English exe):
# - the cockpit's regions (table 0x389DF8 and the objects after it, 0x62 bytes: rectangle at +8, click handler at
#   +0x14, button id at +0x1D). The MFD buttons all go through 0x264498 -> 0x26C60C: a left click (event 1) on button
#   id i puts panel (i & 15) in mode table 0x35A9A9 [i >> 4] (if the panel allows it) with the button sound 2026:
#   COMM 0x00 (26, 258), STAT 0x10 (29, 384), VIEW 0x20 (56, 384), MAP 0x30 (82, 384) on the left MFD; WEAPON 0x42
#   (220, 246), STATUS 0x52 (217, 372), A.S.F. 0x62 (250, 372), DRONE 0x72 (238, 386) on the right one.
# - under the map: 360 view (111, 376; 0x264950), re-centre map (137, 380; 0x264840), full-screen map (161, 380;
#   0x2647d0 -> 0x2921A8) and MAP ZOOM, the "x2" (183, 376 - 210, 396; 0x264A68): a left click zooms the map in, a
#   right click (event 4) out, one level (0x264A84 -> 0x276BC8), sound 2017; also the keys . and , (manual p. 28).
#   The map's zoom levels 0-7 are its view's word +8; a pixel is (0x35B3BC dword z, 16.16) world units across:
#   4, 2.75, 2, 1.4375, 1, 0.734, 0.5, 0.359 (zoom 4: the panel's own, one unit a pixel), and a note shows at zoom z
#   when its byte +0xD has bit (0x35B3DC word z) set (4 3 3 2 2 1 1 0).
# - the left MFD (manual p. 20): COMM (the squad), STAT (a squadmate's PBA status), VIEW (through his helmet), MAP (a
#   map centred on him); the keys [ and 9 go round them, ] and 0 round the right MFD's pages.
# What the guest's buttons do here: his own panels (nothing of the shared game changes; the map's zoom and the pages
# are his window's). The squadmate of STAT / VIEW / MAP is the COMM row he last clicked (the host first).
# Left to other parts: A.S.F. and DRONE (the drone's own code), the 360 view, infrared and the helmet's buttons.
extends Node

const ZOOM_STEP: Array[float] = [4.0, 2.75, 2.0, 1.4375, 1.0, 0.734375, 0.5, 0.359375]
const NOTE_BIT: Array[int] = [4, 3, 3, 2, 2, 1, 1, 0]
const ZOOM_SOUND := 2017                      # 0x7E1: map zoom, full-screen map
const BUTTON_SOUND := 2026                    # 0x7EA: an MFD button
# the game's regions (the usual cockpit's; the panels' own move with them, coop_hud.gd reg_move)
const B_COMM := Rect2(26, 258, 27, 12)
const B_STAT := Rect2(29, 384, 23, 12)
const B_VIEW := Rect2(56, 384, 23, 12)
const B_MAP := Rect2(82, 384, 20, 12)
const B_WEAPON := Rect2(220, 246, 39, 12)
const B_STATUS := Rect2(217, 372, 29, 12)
const B_ASF := Rect2(250, 372, 23, 12)
const B_DRONE := Rect2(238, 386, 25, 12)
const B_RECENTRE := Rect2(137, 380, 21, 20)
const B_FULLMAP := Rect2(161, 380, 21, 20)
const B_ZOOM := Rect2(183, 376, 27, 20)
const B_DROPSHIP := Rect2(6, 354, 10, 20)
const LEFT_BOX := Rect2(17, 276, 82, 104)     # the left MFD (region 1: 17, 276 - 99, 380)
const RIGHT_BOX := Rect2(217, 264, 82, 104)
enum { COMM, STAT, VIEW, MAP }
# keys (the game's, as his window sends them: coop_hud.gd cockpit_key)
const K_MAPIN := 0x33                         # , : one level in, . : out (the game's, read in a live test; TN+ calls
const K_MAPOUT := 0x34                        # them mapout / mapin, data/controls.txt shows what they do)
const K_LEFT := [0x1A, 0x0A]                  # [ and 9
const K_RIGHT := [0x1B, 0x0B]                 # ] and 0
const K_HUDIN := 0x0D                         # helmet zoom: the map's while it is in the HUD (manual p. 21)
const K_HUDOUT := 0x0C

var hud: CanvasLayer                          # coop_hud.gd
var zoom := 4                                 # the map panel's zoom level
var big_zoom := 4                             # the map in the HUD's (M, the full-screen map button: the game's at 4 too)
var left_zoom := 4                            # the left MFD's map
var left_page := COMM
var sel_row := 0                              # the squadmate of STAT / VIEW / MAP: a COMM row (0 the host)
var left_img: ImageTexture
var left_t := -1.0
var view_port: SubViewport                    # VIEW: his squadmate's helmet camera
var view_cam: Camera3D
var view_node: Node3D                         # (the squadmate's body, hidden from it)
var status_n := 0                             # the STATUS page shown: 0 systems 1/2, 1 systems 2/2, 2 armour levels


func step() -> float:
	return ZOOM_STEP[big_zoom if hud.big_map else zoom]


func note_bit() -> int:
	return NOTE_BIT[big_zoom if hud.big_map else zoom]


func _sound(s: int) -> void:
	if hud.sound == null:
		hud.sound = preload("res://scripts/coop_sound.gd").new()
		hud.add_child(hud.sound)
	hud.sound.play_own(s, 64)


# one zoom level in (d = 1) or out (-1), as the game's button: nothing past 0 or 7 (and no sound)
func zoom_by(d: int) -> void:
	var z := clampi((big_zoom if hud.big_map else zoom) + d, 0, 7)
	if z == (big_zoom if hud.big_map else zoom):
		return
	if hud.big_map:
		big_zoom = z
	else:
		zoom = z
	hud.map_dirty = true
	_sound(ZOOM_SOUND)


func _in(r: Rect2, p: Vector2, move := Vector2.ZERO) -> bool:
	return Rect2(r.position + move, r.size).has_point(p)


# a click with his mouse free, at a place of the game's 320 x 400 screen: true if it was a cockpit button's
func click(p: Vector2, right: bool) -> bool:
	var lm: Vector2 = hud.reg_move[0]
	var wm: Vector2 = hud.reg_move[2]
	var mm: Vector2 = hud.reg_move[1]
	if _in(B_ZOOM, p, mm):
		zoom_by(-1 if right else 1)
		return true
	if right and not hud.status_page and _equip_page() == "" and _in(RIGHT_BOX, p, wm):
		_next_weapon(-1)                              # (the right button: the other way round, manual p. 29)
		return true
	if right:
		return false
	for b in [[B_COMM, COMM], [B_STAT, STAT], [B_VIEW, VIEW], [B_MAP, MAP]]:
		if _in(b[0], p, lm):
			_left(b[1])
			return true
	if _in(B_WEAPON, p, wm) or _in(B_STATUS, p, wm):
		_right(1 if _in(B_STATUS, p, wm) else 0)
		return true
	if _in(B_ASF, p, wm) or _in(B_DRONE, p, wm):
		_right(2 if _in(B_ASF, p, wm) else 3)   # (his drone / A.S.F.: guest_equipment.gd; nothing when it is off)
		return true
	if _equip_page() != "" and _in(RIGHT_BOX, p, wm):
		return hud.equip.click(p) or true           # (their own buttons)
	if _in(B_FULLMAP, p, mm):
		hud.toggle_map()
		_sound(ZOOM_SOUND)
		return true
	if _in(B_RECENTRE, p, mm):
		return true                                   # (his map is always centred on him)
	if _in(B_DROPSHIP, p):
		for d in [1, 0]:                              # the game's "Call dropship" key, as his Enter
			hud.lobby.out.put_packet(PackedByteArray([0x4B, 0x1C, 0, d]))
		return true
	if left_page == COMM and _in(LEFT_BOX, p, lm):      # a squadmate's row: his STAT / VIEW / MAP
		var k := int((p.y - 277.0 - lm.y) / 28.0)
		if k >= 0 and k < maxi(1, hud.squad.size()):
			sel_row = k
		return true
	if hud.status_page and _in(RIGHT_BOX, p, wm) and not sys().is_empty():
		status_n = (status_n + 1) % 3                 # the STATUS pages: systems 1/2, 2/2, armour levels
		return true
	if not hud.status_page and _in(RIGHT_BOX, p, wm):
		_next_weapon(1)                               # the WEAPON panel: the next weapon slot (as his keys 1-4)
		return true
	return false


# a left MFD button: its page; the button of the page shown takes the panel back to COMM (the game's STAT, live)
func _left(page: int) -> void:
	if page == left_page:
		page = COMM
	if page == left_page:
		return
	left_page = page
	left_t = -1.0
	_sound(BUTTON_SOUND)


# a key of his (the game's scancode, coop_hud.gd cockpit_key): true if it is the cockpit's
func key(sc: int, down: bool) -> bool:
	if sc in [K_MAPIN, K_MAPOUT] or sc in K_LEFT or sc in K_RIGHT or (hud.big_map and sc in [K_HUDIN, K_HUDOUT]):
		if down:
			if sc == K_MAPIN or sc == K_HUDIN:
				zoom_by(1)
			elif sc == K_MAPOUT or sc == K_HUDOUT:
				zoom_by(-1)
			elif sc in K_LEFT:
				_left((left_page + 1) % 4)
			else:
				var pages := 4 if _equip_on() else 2
				_right((_right_page() + 1) % pages)
		return true
	return false


# the wheel with his mouse free over a map (the panel's, the left MFD's or the one in the HUD): its zoom
func wheel(p: Vector2, up: bool) -> bool:
	var mm: Vector2 = hud.reg_move[1]
	var on_map: bool = Rect2(Vector2(hud.MAP_BOX.position) + mm, hud.MAP_BOX.size).has_point(p) or (hud.big_map and hud.win.has_point(p))
	if on_map:
		zoom_by(1 if up else -1)
		return true
	if left_page == MAP and _in(LEFT_BOX, p, hud.reg_move[0]):
		var z := clampi(left_zoom + (1 if up else -1), 0, 7)
		if z != left_zoom:
			left_zoom = z
			left_t = -1.0
			_sound(ZOOM_SOUND)
		return true
	return false


# the squadmate of STAT / VIEW / MAP: [entity, pilot] (the host's row first; none: [0, 255])
func mate() -> Array:
	var rows: Array = hud.squad
	if rows.is_empty():
		return [0, 255]
	var r: Array = rows[clampi(sel_row, 0, rows.size() - 1)]
	return [r[0], r[2]]


# where a unit is (game x, y, z and heading in radians) from his window's entities; empty: not there
func where(e: int) -> Array:
	var vp := hud.get_parent()
	if vp == null or not ("live_ents" in vp) or not vp.live_ents.has(e):
		return []
	var r: Array = vp.live_ents[e]
	return [r[3], r[4], r[5], r[6]]


# each frame while the cockpit is up: the VIEW page's camera, as the host's VIEW panel (viewer.gd _sub_views): at the
# squadmate's place, the unit's z + 0.1875 as the game puts its panel views (0x275260), along his heading, level,
# the game's panel field (84.55 degrees across, rendered 1.2 x taller and squeezed: its 0.833 pixel ratio), without
# his own body. Its own camera here, drawn in the panel (the viewer's side views lie under the guest's cockpit)
func update() -> void:
	var on: bool = left_page == VIEW and hud.state == 0 and hud.cockpit.visible and not hud.big_map
	var vp := hud.get_parent()
	var m := mate()
	var w: Array = where(int(m[0])) if on else []
	if w.is_empty() or vp == null or not ("camera" in vp):
		_view_off()
		return
	if view_port == null:
		view_port = SubViewport.new()
		view_port.world_3d = hud.get_viewport().world_3d
		view_port.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		view_cam = Camera3D.new()
		view_cam.keep_aspect = Camera3D.KEEP_WIDTH
		view_cam.fov = 84.55
		view_cam.near = 0.05
		view_port.add_child(view_cam)
		add_child(view_port)
	view_port.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var r: Rect2 = hud._grect(LEFT_BOX.position.x, LEFT_BOX.position.y + 1, LEFT_BOX.end.x, LEFT_BOX.end.y - 17)
	var px := Vector2i(maxi(16, roundi(r.size.x)), maxi(16, roundi(r.size.y * 1.2)))
	if view_port.size != px:
		view_port.size = px
	view_cam.far = vp.camera.far
	var h := float(w[3])
	view_cam.position = Vector3(float(w[0]), float(w[2]) + 0.1875, float(w[1]))
	view_cam.rotation = Vector3(0.0, atan2(-cos(h), -sin(h)), 0.0)
	var node: Node3D = vp._live_node(int(m[0])) if vp.has_method("_live_node") else null
	if node != view_node:
		if view_node != null and is_instance_valid(view_node):
			vp._sub_hide(view_node, false)
		if node != null:
			vp._sub_hide(node, true)
		view_node = node
	view_cam.cull_mask = 0xFFFFF & ~int(vp.SUB_HIDE_LAYER)


func _view_off() -> void:
	if view_port != null:
		view_port.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if view_node != null and is_instance_valid(view_node):
		var vp := hud.get_parent()
		if vp and vp.has_method("_sub_hide"):
			vp._sub_hide(view_node, false)
	view_node = null


# the left MFD when it is not COMM, drawn by coop_hud.gd _draw_panel in its place
func draw_left() -> void:
	var lm: Vector2 = hud.reg_move[0]
	var m := mate()
	var e := int(m[0])
	var nm: String = hud.mate_name if sel_row == 0 else hud._pilot_name(int(m[1]), e)
	var x0 := LEFT_BOX.position.x + lm.x
	var y0 := LEFT_BOX.position.y + lm.y
	match left_page:
		VIEW:
			if view_port != null and view_port.render_target_update_mode == SubViewport.UPDATE_ALWAYS:
				hud.panel.draw_texture_rect(view_port.get_texture(), hud._grect(x0, y0 + 1, x0 + LEFT_BOX.size.x, y0 + LEFT_BOX.size.y - 17), false)
			hud._text(nm.to_upper(), x0 + 41.0, y0 + 90.0, 10.0, Color(0.95, 0.95, 1.0), true)
		MAP:
			if hud.clock - left_t > 0.1:
				left_t = hud.clock
				var w := where(e)
				var c: Vector2 = Vector2(w[0], w[1]) if not w.is_empty() else hud.guest_xy
				var r: Array = hud._map_image(Vector2i(LEFT_BOX.size), ZOOM_STEP[left_zoom], c, NOTE_BIT[left_zoom])
				var img: Image = r[0]
				if left_img == null or Vector2i(left_img.get_size()) != img.get_size():
					left_img = ImageTexture.create_from_image(img)
				else:
					left_img.update(img)
			if left_img:
				hud.panel.draw_texture_rect(left_img, hud._grect(x0, y0, x0 + LEFT_BOX.size.x, y0 + LEFT_BOX.size.y), false)
		STAT:
			_draw_stat(e, nm, x0, y0)


# STAT, laid out as the game's (read live in mission 30): his specialty at the top (his name for an older host), the H
# bar (the pilot's health, in the game's red) and the E bar (the suit's energy, green) on the right, then what he is
# doing (the bridge's activity, coop_guest.py: "Following %s"...) and his armour.
func _draw_stat(e: int, nm: String, x0: float, y0: float) -> void:
	var white := Color(0.95, 0.95, 1.0)
	var row := clampi(sel_row, 0, maxi(0, hud.squad.size() - 1))
	var arm: int = hud.squad[row][1] if row < hud.squad.size() else 0
	var r := row_of(e)
	var hp: int = r[1] if not r.is_empty() else (hud.squad_health[row] if row < hud.squad_health.size() else 255)
	var spec: String = text(366, r[2]) if not r.is_empty() and r[2] > 0 else ""
	hud._text((spec if spec != "" else nm).to_upper(), x0 + 3.0, y0 + 3.0, 10.0, Color(0.95, 0.95, 1.0) if spec != "" else Color(1.0, 0.8, 0.2))
	if not r.is_empty() and r[3] > 0:
		var act := text(367, r[3])
		var who := _unit_name(r[4], r[5])
		act = act.replace("%s", who).strip_edges()
		hud._text(act.to_upper(), x0 + 3.0, y0 + 78.0, 10.0, Color(0.4, 1.0, 0.45))
	for k in 2:
		var v: int = hp if k == 0 else (r[0] if not r.is_empty() else 255)
		var y := y0 + 18.0 + 13.0 * k
		hud._text("H" if k == 0 else "E", x0 + 40.0, y - 2.0, 10.0, white)
		hud.panel.draw_rect(hud._grect(x0 + 47.0, y, x0 + 79.0, y + 6.0), Color(0.05, 0.05, 0.12))
		if v <= 100:
			hud.panel.draw_rect(hud._grect(x0 + 47.0, y, x0 + 47.0 + 32.0 * v / 100.0, y + 6.0),
					Color(0.9, 0.15, 0.1) if k == 0 else Color(0.2, 0.85, 0.25))
	hud._text("ARMOUR %d%%" % arm, x0 + 3.0, y0 + 50.0, 10.0, white)
	hud._text("FULLY OPERATIONAL" if arm > 50 else "DAMAGED", x0 + 3.0, y0 + 64.0, 10.0,
			white if arm > 50 else Color(1.0, 0.6, 0.2))


# the weapon slot after (d = 1) or before (-1) his selected one that holds a weapon: its key (1-4) to the host's bridge
func _next_weapon(d: int) -> void:
	for k in range(1, 4):
		var s := posmod(hud.weapon_slot + d * k, 4)
		if s < hud.slot_types.size() and hud.slot_types[s] != 0:
			for down in [1, 0]:
				hud.lobby.out.put_packet(PackedByteArray([0x4B, 0x02 + s, 0, down]))
			return


# his suit's systems from the host's bridge (coop_guest.py status_marks, M_SYS): sensors, targdisc, jumpjets, infrared,
# target, video, drone, power plant, armour front, left, back, right (%); empty: an older host
func sys() -> PackedByteArray:
	for m in hud.map_marks:
		if m[0] == hud.M_SYS and (m[2] as PackedByteArray).size() >= 12:
			return m[2]
	return PackedByteArray()


# a COMM row's entity: [energy %, pilot's health %] (M_ROW; empty: not sent)
func row_of(e: int) -> Array:
	for m in hud.map_marks:
		var d: PackedByteArray = m[2]
		if m[0] == hud.M_ROW and d.size() >= 4 and d.decode_u16(0) == e:
			if d.size() >= 9:                         # (and its specialty, activity, the unit it names and that one's label)
				return [d[2], d[3], d[4], d[5], d.decode_u16(6), d[8]]
			return [d[2], d[3], 0, 0, 0, 0]
	return []


# the game's texts in his own game files: RESGAME table rid, string k ("": none)
var texts := {}
func text(rid: int, k: int) -> String:
	if not texts.has(rid):
		texts[rid] = PackedStringArray()
		var vp := hud.get_parent()
		if vp and "data" in vp:
			var r = hud.LGRes.open(vp.data.data_dir().path_join("RESGAME.RES"))
			if r and r.has(rid):
				texts[rid] = r.strings(rid)
	var s: PackedStringArray = texts[rid]
	return s[k] if k >= 0 and k < s.size() else ""


# a unit as the game names it in a text (0x26a6d4): the host's name, a squad pilot's, else its label (RESGAME 375)
func _unit_name(e: int, label: int) -> String:
	if e == 0:
		return ""
	for i in hud.squad.size():
		if hud.squad[i][0] == e:
			return hud.mate_name if i == 0 else hud._pilot_name(hud.squad[i][2], e)
	if e == hud.entity:
		return "PLAYER 2"                             # (his own suit: the host's game names it so, "Player 2")
	return text(375, label) if label > 0 else ""


# his weapon panel's two lines as the game's (0x271e14): the slot's health %, then its state (RESGAME 367 string 71 +
# 0x28f024's result: fully operational, inoperable, out of ammo, not charged, overheated, loading); empty: older host
func weapon_lines() -> Array:
	for m in hud.map_marks:
		if m[0] == hud.M_WPN and (m[2] as PackedByteArray).size() >= 1:
			var st := text(367, 71 + clampi(hud.weapon_state, 0, 5))
			if hud.weapon_state == 0 and hud.weapon_ammo != 0xFFFF:   # (a weapon that counts it: its ammunition instead,
				st = text(369, 39).replace("%d", str(hud.weapon_ammo))   # "AMMO COUNT = %d", 0x271f4b)
			return ["%d%%" % m[2][0], st.to_upper() if st != "" else ("FULLY OPERATIONAL" if hud.weapon_state == 0 else "LOADING")]
	return []


# STATUS, as the game's (its pages, read live in mission 30): "SYSTEM STATUS 1/2" sensors, targdisc, jumpjets,
# infrared, target; "2/2" video, drone; the power plant under both; then "ARMOR LEVELS" front, left, back, right
func draw_status() -> bool:
	var s := sys()
	if s.is_empty():
		return false                                  # (an older host: coop_hud.gd's own page)
	var wm: Vector2 = hud.reg_move[2]
	var x0 := RIGHT_BOX.position.x + wm.x
	var y0 := RIGHT_BOX.position.y + wm.y
	var white := Color(0.95, 0.95, 1.0)
	var col := func(v: int) -> Color: return white if v >= 100 else (Color(1.0, 0.85, 0.3) if v > 50 else Color(1.0, 0.35, 0.3))
	if status_n == 2:
		var bg := _armour_pic()                     # the game's green suit behind the levels (RESHLMHI 537, frame 1)
		if bg:
			hud.panel.draw_texture_rect(bg, hud._grect(x0, y0, x0 + bg.get_width(), y0 + bg.get_height()), false)
		hud._text("ARMOR LEVELS", x0 + 41.0, y0 + 3.0, 10.0, Color(0.85, 1.0, 0.3), true)
		var names := ["FRONT", "LEFT", "BACK", "RIGHT"]
		for k in 4:
			hud._text(names[k], x0 + 6.0, y0 + 17.0 + 12.0 * k, 10.0, Color(0.6, 1.0, 0.4))
			hud._text("%d%%" % s[8 + k], x0 + 50.0, y0 + 17.0 + 12.0 * k, 10.0, col.call(s[8 + k]))
		return true
	hud._text("SYSTEM STATUS %d/2" % (status_n + 1), x0 + 41.0, y0 + 3.0, 10.0, white, true)
	var rows := [["SENSORS", 0], ["TARGDISC", 1], ["JUMPJETS", 2], ["INFRARED", 3], ["TARGET", 4]] if status_n == 0 			else [["VIDEO", 5], ["DRONE", 6]]
	for k in rows.size():
		hud._text(rows[k][0], x0 + 4.0, y0 + 17.0 + 12.0 * k, 10.0, white)
		hud._text("%d%%" % s[rows[k][1]], x0 + 52.0, y0 + 17.0 + 12.0 * k, 10.0, col.call(s[rows[k][1]]))
	hud._text("POWER PLANT: %d%%" % s[7], x0 + 4.0, y0 + 86.0, 10.0, col.call(s[7]))
	return true


# The MFD buttons lit as his own pages are (the cockpit picture has the host's): the game's pictures of its buttons,
# resource 752 of the cockpit's helmet file (0x26c72c: frame 1 + k as is, 0x0B + k lit, k = the button id >> 4),
# drawn on their regions. Which helmet file (RESHLMHH, N, P, S: one for each kind of cockpit): the one whose COMM
# button matches the cockpit picture; none (another cockpit, a file missing): nothing drawn
const BUTTON_RES := 752
const BUTTON_RECTS := [B_COMM, B_STAT, B_VIEW, B_MAP, B_WEAPON, B_STATUS, B_ASF, B_DRONE]
var buttons := []                             # [normal, lit] textures of buttons 0-5 (empty: not looked yet)
var buttons_of: Texture2D                     # (the cockpit picture they were matched on)


func _button_frames(file: String) -> Array:
	var vp := hud.get_parent()
	if hud.hud_pal.is_empty() or vp == null or not ("data" in vp):
		return []
	var r = hud.LGRes.open(vp.data.data_dir().path_join(file))
	if r == null or not r.has(BUTTON_RES):
		return []
	var fr: Array = hud.LGRes.frames(r.data(BUTTON_RES))
	if fr.size() < 0x0B + 8:
		return []
	var out := []
	for k in 8:
		var pair := []
		for f in [1 + k, 0x0B + k]:
			var img: Image = hud.TNObjects._bitmap(fr[f], hud.hud_pal)
			if img == null or img.get_size() != Vector2i(BUTTON_RECTS[k].size):
				return []
			pair.append(img)
		out.append(pair)
	return out


func _match_buttons() -> void:
	buttons_of = hud.cockpit.texture
	buttons = [null]
	var shot: Image = buttons_of.get_image() if buttons_of else null
	if shot == null:
		return
	var lm: Vector2 = hud.reg_move[0]
	var best := 0.6                               # (at least this share of the COMM button's pixels alike)
	for file in ["RESHLMHH.RES", "RESHLMHN.RES", "RESHLMHP.RES", "RESHLMHS.RES"]:
		var fr := _button_frames(file)
		if fr.is_empty():
			continue
		var at := Vector2i(B_COMM.position + lm)
		for img: Image in fr[0]:
			var same := 0
			var n := 0
			for y in img.get_height():
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					if c.a < 0.5:
						continue
					n += 1
					var d := shot.get_pixel(at.x + x, at.y + y)
					if absf(d.r - c.r) + absf(d.g - c.g) + absf(d.b - c.b) < 0.08:
						same += 1
			if n > 0 and float(same) / n > best:
				best = float(same) / n
				buttons = []
				for pair in fr:
					buttons.append([ImageTexture.create_from_image(pair[0]), ImageTexture.create_from_image(pair[1])])


func draw_buttons() -> void:
	if hud.cockpit.texture == null:
		return
	if hud.cockpit.texture != buttons_of:
		_match_buttons()
	if buttons.size() < 8:
		return
	var rp := _right_page()
	var on := [left_page == COMM, left_page == STAT, left_page == VIEW, left_page == MAP, rp == 0, rp == 1, rp == 2, rp == 3]
	for k in 8:
		var m: Vector2 = hud.reg_move[0] if k < 4 else hud.reg_move[2]
		var r: Rect2 = BUTTON_RECTS[k]
		var t: Texture2D = buttons[k][1 if on[k] else 0]
		hud.panel.draw_texture_rect(t, hud._grect(r.position.x + m.x, r.position.y + m.y, r.end.x + m.x, r.end.y + m.y), false)


# The map in the HUD (the full-screen map button, M): the game then shows the 3D view in the map's panel (read live).
# His own view there: a camera following his window's, drawn in the panel
var mid_port: SubViewport
var mid_cam: Camera3D


func update_mid() -> void:
	var on: bool = hud.big_map and hud.state == 0 and hud.cockpit.visible
	var vp := hud.get_parent()
	var main: Camera3D = vp.camera if vp != null and "camera" in vp else null
	if not on or main == null:
		if mid_port != null:
			mid_port.render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	if mid_port == null:
		mid_port = SubViewport.new()
		mid_port.world_3d = hud.get_viewport().world_3d
		mid_cam = Camera3D.new()
		mid_port.add_child(mid_cam)
		add_child(mid_port)
	mid_port.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var r: Rect2 = hud._grect(hud.MAP_BOX.position.x, hud.MAP_BOX.position.y, hud.MAP_BOX.end.x, hud.MAP_BOX.end.y)
	var px := Vector2i(maxi(16, roundi(r.size.x)), maxi(16, roundi(r.size.y * 1.2)))
	if mid_port.size != px:
		mid_port.size = px
	mid_cam.keep_aspect = Camera3D.KEEP_WIDTH
	mid_cam.fov = 84.55                           # (the game's panel field, as the VIEW page)
	mid_cam.near = main.near
	mid_cam.far = main.far
	mid_cam.cull_mask = main.cull_mask
	mid_cam.global_transform = main.global_transform


func draw_mid() -> void:
	if mid_port == null or mid_port.render_target_update_mode != SubViewport.UPDATE_ALWAYS:
		return
	var mm: Vector2 = hud.reg_move[1]
	var b: Rect2 = Rect2(Vector2(hud.MAP_BOX.position) + mm, hud.MAP_BOX.size)
	hud.panel.draw_texture_rect(mid_port.get_texture(), hud._grect(b.position.x, b.position.y, b.end.x, b.end.y), false)


var armour_pic: Texture2D
var armour_tried := false
func _armour_pic() -> Texture2D:
	if not armour_tried and not hud.hud_pal.is_empty():
		armour_tried = true
		var fr: Array = hud._helmet_frames(537)
		if fr.size() > 1:
			var img: Image = hud.TNObjects._bitmap(fr[1], hud.hud_pal)
			if img:
				armour_pic = ImageTexture.create_from_image(img)
	return armour_pic


# the right MFD's pages: 0 WEAPON, 1 STATUS (coop_hud.gd status_page), 2 A.S.F., 3 DRONE (guest_equipment.gd, only
# while the host's bridge sends them: its 'GEQ', TN_COOP_EQUIP=1)
func _equip_on() -> bool:
	return hud.equip != null and not (hud.equip.s as Dictionary).is_empty()


func _equip_page() -> String:
	return hud.equip.shown() if hud.equip != null else ""


func _right_page() -> int:
	match _equip_page():
		"asf":
			return 2
		"drone":
			return 3
	return 1 if hud.status_page else 0


func _right(page: int) -> void:
	if page >= 2 and not _equip_on():
		return                                        # (no drone / A.S.F. from this host: the button does nothing)
	if page == _right_page():
		return
	if hud.equip != null:
		hud.equip.show_page(["", "", "asf", "drone"][page])
	hud.status_page = page == 1
	status_n = 0
	_sound(BUTTON_SOUND)
