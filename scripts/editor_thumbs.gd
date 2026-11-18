# Thumbnails for the mission editor's spawn menu: each unit type drawn alone (the viewer's own model, sprite or
# soldier, in the current planet's colours) in a small viewport with a world of its own, from the front left and
# above, one a frame, and only while the menu is open (flying while they are drawn would stutter). Kept in
# user://editor_thumbs, by planet: pictures made from the player's own game files, on his PC only; the kept ones
# are loaded a few a frame.
extends Node

signal made(key: int, tex: Texture2D)

const SIZE := 128
const DIR := "user://editor_thumbs"
const AtomicFile = preload("res://scripts/atomic_file.gd")
const LOADS_PER_FRAME := 8

var viewer: Node
var vp: SubViewport
var cam: Camera3D
var holder: Node3D
var queue := []                 # [cls, sub] still to load or draw
var cache := {}                 # cls * 256 + sub -> Texture2D
var palette := ""               # the planet the cache is for
var running := false
var paused := true              # (the editor: while its spawn menu is closed)


func _ready() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.msaa_3d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(vp)
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1, 1, 1)
	env.ambient_light_energy = 0.6
	we.environment = env
	vp.add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation = Vector3(deg_to_rad(-50.0), deg_to_rad(40.0), 0.0)
	sun.light_energy = 1.1
	vp.add_child(sun)
	cam = Camera3D.new()
	cam.fov = 30.0
	cam.far = 4000.0
	vp.add_child(cam)
	holder = Node3D.new()
	vp.add_child(holder)


static func key_of(cls: int, sub: int) -> int:
	return cls * 256 + sub


func thumb(cls: int, sub: int) -> Texture2D:
	return cache.get(key_of(cls, sub))


# [[cls, sub]]: loaded or drawn in the background, made() for each
func request(items: Array) -> void:
	if viewer.pal_key != palette:
		palette = viewer.pal_key
		cache.clear()
		queue.clear()
	for it in items:
		if not cache.has(key_of(it[0], it[1])) and not queue.has(it):
			queue.append(it)
	if not running and not queue.is_empty():
		_run()


func _file(cls: int, sub: int) -> String:
	return "%s/%s_%d_%d.png" % [DIR, palette.get_basename().to_lower(), cls, sub]


func _from_disk(cls: int, sub: int) -> Texture2D:
	var p := _file(cls, sub)
	if not FileAccess.file_exists(p):
		return null
	var img := Image.load_from_file(ProjectSettings.globalize_path(p))
	return ImageTexture.create_from_image(img) if img != null and not img.is_empty() else null


func _run() -> void:
	running = true
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var loads := 0
	while not queue.is_empty():
		if viewer.current.is_empty() or viewer.pal_key != palette:
			break                                    # (another planet: its own request starts again)
		if paused:
			await get_tree().process_frame
			continue
		var it: Array = queue.pop_front()
		var k := key_of(it[0], it[1])
		var tex := _from_disk(it[0], it[1])
		if tex != null:
			cache[k] = tex
			made.emit(k, tex)
			loads += 1
			if loads % LOADS_PER_FRAME == 0:
				await get_tree().process_frame
			continue
		var drawn_for := palette
		var obj: Node3D = viewer._add_object(viewer.current["map"], it[0], it[1], 256.0, 256.0, 0.0, "", false, 0.0)
		obj.get_parent().remove_child(obj)
		holder.add_child(obj)
		obj.position = Vector3.ZERO
		obj.rotation = Vector3.ZERO
		_frame(obj)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
		await RenderingServer.frame_post_draw
		await RenderingServer.frame_post_draw
		var img := vp.get_texture().get_image()
		obj.queue_free()
		if drawn_for != palette or viewer.pal_key != palette:
			queue.push_front(it)                     # (drawn in another planet's colours: not kept)
			break
		if img == null or img.is_empty():
			continue
		tex = ImageTexture.create_from_image(img)
		cache[k] = tex
		var png := _file(it[0], it[1])                 # (written whole, then renamed: see atomic_file.gd)
		if img.save_png(AtomicFile.tmp_name(png)) == OK:
			AtomicFile.commit(AtomicFile.tmp_name(png), png)
		made.emit(k, tex)
	running = false


# the camera on the object's bounds (its model, or a soldier's limbs), the whole of it in view
func _frame(obj: Node3D) -> void:
	var box := AABB()
	var first := true
	var vis: Array = obj.find_children("*", "GeometryInstance3D", true, false)
	vis.append(obj)
	for v in vis:
		var g := v as GeometryInstance3D
		if g == null:
			continue
		var b: AABB = g.global_transform * g.get_aabb()
		if b.size == Vector3.ZERO:
			continue
		box = b if first else box.merge(b)
		first = false
	if first:
		box = AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1.0, 1.0, 1.0))
	var c := box.get_center()
	var r := maxf(box.size.length() * 0.5, 0.15)
	var dist := r / sin(deg_to_rad(cam.fov * 0.5)) * 1.02
	cam.near = maxf(0.005, dist * 0.02)
	cam.look_at_from_position(c + Vector3(0.85, 0.55, 0.65).normalized() * dist, c, Vector3.UP)
