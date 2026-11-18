# The co-op guest's target camera: the game's left cockpit panel in its mode 0x15 (the lock light's button, 0x2644E4:
# with a target locked, a click puts the panel in that mode, another puts it back on COMM; the target lost, it goes
# back by itself, 0x262A88). Drawn as the game's routine 0x275260 places that camera, from his own suit:
# - at his suit's x, y and its z + the game's eye height [0x38FB1C] + 0.1875 (the host's bridge sends that height);
# - turned towards the target's entity (its x, y, z as they are: its feet), heading atan2(dy, dx), pitch
#   atan2(dz, the 3D distance);
# - zoomed by that distance in units, kept within 1 to 16 (its field: 2 atan(tan(84.55 / 2) / zoom), as the host's
#   own panel views in viewer.gd).
# Over the panel's frame (17, 277)-(99, 380) of the 320 x 400 screen, moved with the COMM panel; rendered 1.2 x taller
# and squeezed, as the game's 3D library draws (viewer.gd _sub_views). Over it, the panel's title (coop_hud.gd).
extends Node

const FIELD := 84.55
const FRAME := Rect2(17, 277, 82, 103)        # x0, y0 + 1, x1 - x0, y1 - y0 - 1 (the host's panel 2 in viewer.gd)

var vp: SubViewport
var cam: Camera3D
var rect: TextureRect
var on := false
var pos := Vector3.ZERO
var rot := Vector3.ZERO


func setup(parent: Control, world: World3D) -> void:
	vp = SubViewport.new()
	vp.world_3d = world
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.size = Vector2i(82, 124)
	add_child(vp)
	cam = Camera3D.new()
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.near = 0.05
	cam.far = 1200.0
	cam.cull_mask = 0xFFFFF & ~(1 << 18) & ~(1 << 19)     # not his own body (the viewer's PLAYER_LAYER, SUB_HIDE_LAYER)
	vp.add_child(cam)
	rect = TextureRect.new()
	rect.texture = vp.get_texture()
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_SCALE
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.visible = false
	parent.add_child(rect)


# me, target: the game's x, y, z of his suit and of the target; eye: the height the game adds; move: the COMM panel's
# offset in this cockpit; k: window pixels a game pixel
func show_view(me: Vector3, target: Vector3, eye: float, move: Vector2, k: Vector2) -> void:
	var from := Vector3(me.x, me.y, me.z + eye)
	var d := target - from
	var dist := d.length()
	var zoom := clampf(dist, 1.0, 16.0)
	var h := atan2(d.y, d.x)
	var want_pos := Vector3(from.x, from.z, from.y)              # Godot: x, up, y
	var want_rot := Vector3(atan2(d.z, maxf(dist, 0.001)), atan2(-cos(h), -sin(h)), 0.0)
	if on and pos.distance_to(want_pos) < 1.0 and absf(angle_difference(rot.y, want_rot.y)) < 0.35:
		want_pos = pos.lerp(want_pos, 0.2)                       # (eased as the host's panel views, SUB_EASE)
		want_rot = Vector3(lerp_angle(rot.x, want_rot.x, 0.2), lerp_angle(rot.y, want_rot.y, 0.2), 0.0)
	pos = want_pos
	rot = want_rot
	cam.position = pos
	cam.rotation = rot
	cam.fov = rad_to_deg(2.0 * atan(tan(deg_to_rad(FIELD) / 2.0) / zoom))
	var r := Rect2((FRAME.position + move) * k, FRAME.size * k)
	rect.position = r.position
	rect.size = r.size
	var px := Vector2i(maxi(16, roundi(r.size.x)), maxi(16, roundi(r.size.y * 1.2)))
	if vp.size != px:
		vp.size = px
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	rect.visible = true
	on = true


func hide_view() -> void:
	if not on:
		return
	on = false
	rect.visible = false
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
