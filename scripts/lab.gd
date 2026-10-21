# Live graphics lab. TN_LAB names a folder whose effects are applied while Uplink runs, a fraction of a second after
# each save, without a restart: Claude edits them, the player watches. viewer.gd only adds this node when TN_LAB is set
# (the lab shortcut): players never have it.
#   lab.gd           func apply(lab), optional update(lab, delta) (each frame) and revert(lab); no class_name, no await
#   shaders/<name>   replaces the viewer's res://<name> (terrain.gdshader, sky_common.gdshaderinc...) while it is there
#   other files      lab.shader("x.gdshader") / lab.post("x.gdshader"): reloaded when they change
#   snap             a request: the picture on screen goes to shot.png, snap is removed
#   status.txt       written here: the version on screen or why the last one was refused, errors, lab.log() lines
# Each version starts again from the viewer's own settings (environment, sun, what lab.param / lab.prop changed, the
# lab's own nodes and tweens): a line taken out is undone. What the viewer sets meanwhile (a new mission's haze, its sun)
# becomes the base and the lab's values stay on top; a new mission applies the version again (its materials are new).
# A lab.gd or shader that does not compile is refused: the last good one stays on screen, the errors go to status.txt.
# Insert: the lab's effects off / on, to compare (a key the game does not use).
extends Node

const POLL := 0.15                    # seconds between looks at the folder
const TEMPLATE := "# Uplink lab: saved = applied. lab.v = the viewer; lab.env, lab.sun, lab.camera; lab.ground(), lab.water(),\n" + \
	"# lab.sky() materials; lab.param(mat, name, value), lab.prop(obj, name, value), lab.add(node), lab.tween(),\n" + \
	"# lab.post(\"x.gdshader\"), lab.shader(\"x.gdshader\"), lab.log(text)\n\nfunc apply(lab) -> void:\n\tpass\n"


class Catch extends Logger:           # errors (scripts, shaders) for status.txt; they can come from other threads
	var mutex := Mutex.new()
	var got := []                     # [time, text]

	func _log_error(_function, file, line, code, rationale, _notify, _type, _backtrace) -> void:
		if str(rationale).begins_with("Shader compilation failed"):   # (after each shader error: nothing more)
			return
		var f := str(file)
		if f.begins_with("gdscript://"):            # the lab's script, compiled from its text
			f = "lab.gd"
		var s := str(code) + (" - " + str(rationale) if str(rationale) != "" else "") + \
			(" (%s:%d)" % [f, line] if f != "" else "")
		mutex.lock()
		got.append([Time.get_time_string_from_system(), s.replace("\n", " ")])
		mutex.unlock()

	func count() -> int:
		mutex.lock()
		var n := got.size()
		mutex.unlock()
		return n


var dir := ""
var v: Node3D                         # the viewer: v.env, v.sun, v.camera, v.mats, v.ground_mats, v.sky_root, v.current
var env: Environment
var sun: DirectionalLight3D
var camera: Camera3D
var root3d: Node3D                    # the lab's 3D nodes (lab.add, lab.tween), freed with each version
var canvas: CanvasLayer               # its 2D ones (lab.post): over the 3D view, under old school (-1) and the HUD
var fx = null                         # the running lab.gd
var fx_text := ""
var version := 0                      # last lab.gd read
var on_screen := 0                    # the version in use
var refused := 0                      # the last one refused, while it is the latest
var applied_at := ""
var applied_bad := false
var enabled := true                   # Insert
var applied := false
var tracked := []                     # [object, {property: viewer's value}, {property: value after the lab}]
var changed := []                     # lab.param / lab.prop: [object, key, viewer's value, lab's value, is a parameter]
var replaced := {}                    # shaders/<name>: res path -> [Shader or ShaderInclude, good code, lab text, note]
var followed := {}                    # lab.shader(): file -> [Shader, text read, good code]
var posts := {}                       # lab.post(): file -> its rects (shown once the shader compiles)
var gen := ""                         # the mission's materials
var errors := []                      # since the last change in the folder: [time, text, times seen]
var cleared := false                  # (once per look at the folder: files saved together keep each other's errors)
var lines: Array[String] = []         # lab.log()
var shot := ""
var dirty := true
var label: Label
var catch := Catch.new()
var t := 0.0


func _ready() -> void:
	v = get_parent()
	env = v.env
	sun = v.sun
	camera = v.camera
	dir = OS.get_environment("TN_LAB").replace("\\", "/").trim_suffix("/")
	DirAccess.make_dir_recursive_absolute(dir + "/shaders")
	if not DirAccess.dir_exists_absolute(dir):
		push_warning("lab: TN_LAB is not a folder that can be used: " + dir)
		queue_free()
		return
	if not FileAccess.file_exists(dir + "/lab.gd"):
		_write("lab.gd", TEMPLATE)
	OS.add_logger(catch)
	root3d = Node3D.new()
	add_child(root3d)
	canvas = CanvasLayer.new()
	canvas.layer = -3
	add_child(canvas)
	var ll := CanvasLayer.new()                    # top right, under the frames per second
	ll.layer = 20
	add_child(ll)
	label = Label.new()
	label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	label.offset_left = -420
	label.offset_right = -8
	label.offset_top = 30
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.add_theme_font_size_override("font_size", 15)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 4)
	ll.add_child(label)
	_track(env, _props(["Environment"]))
	_track(sun, _props(["Light3D", "DirectionalLight3D"]) + [&"rotation", &"visible"])
	get_tree().process_frame.connect(_frame_start)
	_poll()


func _exit_tree() -> void:
	if root3d != null:                             # (not when TN_LAB could not be used)
		OS.remove_logger(catch)
	if get_tree().process_frame.is_connected(_frame_start):
		get_tree().process_frame.disconnect(_frame_start)


# ------------------------------------------------------------------ what lab.gd calls

func ground() -> Array:
	return v.ground_mats


func water() -> ShaderMaterial:
	return v.mats["water"]


func sky() -> Material:
	return env.sky.sky_material if env.sky != null else null


func param(mat: ShaderMaterial, key: String, value) -> void:
	_change(mat, key, value, true)


func prop(obj: Object, key: String, value) -> void:
	_change(obj, key, value, false)


func add(node: Node) -> Node:
	(canvas if node is CanvasItem else root3d).add_child(node)
	return node


# a tween that ends with this version
func tween() -> Tween:
	var n := Node.new()
	root3d.add_child(n)
	return n.create_tween()


# a shader read from the lab folder, its code replaced whenever the file changes (and compiles)
func shader(file: String) -> Shader:
	if not followed.has(file):
		followed[file] = [Shader.new(), "", ""]
	_follow(file)
	return followed[file][0]


# a full screen pass over the 3D view (canvas_item shader, hint_screen_texture), under old school and the HUD; shown
# once its shader compiles (a ColorRect without one would be white)
func post(file: String) -> ShaderMaterial:
	var b := BackBufferCopy.new()                  # each pass reads the picture as the one before left it
	b.copy_mode = BackBufferCopy.COPY_MODE_VIEWPORT
	canvas.add_child(b)
	var r := ColorRect.new()
	r.set_anchors_preset(Control.PRESET_FULL_RECT)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var m := ShaderMaterial.new()
	m.shader = shader(file)
	r.material = m
	r.visible = followed[file][2] != ""
	canvas.add_child(r)
	if not posts.has(file):
		posts[file] = []
	posts[file].append(r)
	return m


func log(text) -> void:
	lines.append(Time.get_time_string_from_system() + "  " + str(text))
	if lines.size() > 30:
		lines.remove_at(0)
	dirty = true


# ------------------------------------------------------------------ running

func _process(delta: float) -> void:
	_sync()
	if fx != null and applied and fx.has_method("update"):
		fx.update(self, delta)
		_settle()
	t += delta
	if t >= POLL:
		t = 0.0
		_poll()


# a new frame (before the viewer's processing and the missions it loads): what the last one left, the lab's own nodes
# and tweens included, is the lab's; what differs at _sync, after the viewer's _process, was set by the viewer
func _frame_start() -> void:
	if applied:
		_settle()


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.physical_keycode == KEY_INSERT:   # (before the viewer: it would go to the game)
		if event.pressed and not event.echo:
			enabled = not enabled
			_revert()
			if enabled and fx != null:
				_apply()
			dirty = true
		get_viewport().set_input_as_handled()


func _poll() -> void:
	cleared = false
	_shaders()                                     # (first: a lab.gd saved with its shaders finds them in place)
	for file in followed:
		_follow(file)
	var text := _read("lab.gd")
	if text != "" and text != fx_text:             # (empty: being written)
		fx_text = text
		_fresh()
		_load_fx(text)
	if _gen() != gen and applied:                  # a new mission: its own settings, then the lab's on top
		_revert()
		_apply()
	if FileAccess.file_exists(dir + "/snap"):
		DirAccess.remove_absolute(dir + "/snap")
		_snap()
	catch.mutex.lock()
	for e in catch.got:
		if not errors.is_empty() and errors[-1][1] == e[1]:
			errors[-1][2] += 1                     # (the same one each frame: counted)
		else:
			errors.append([e[0], e[1], 1])
		dirty = true
	catch.got.clear()
	catch.mutex.unlock()
	errors = errors.slice(-15)
	if dirty:
		dirty = false
		_status()


# something changed in the folder: the errors shown are the new state's (once per look: several files saved together
# keep each other's)
func _fresh() -> void:
	dirty = true
	if cleared:
		return
	cleared = true
	catch.mutex.lock()
	catch.got.clear()
	catch.mutex.unlock()
	errors.clear()


func _load_fx(text: String) -> void:
	version += 1
	var s := GDScript.new()
	s.source_code = text
	var err := s.reload()
	var inst = s.new() if err == OK and s.can_instantiate() else null
	if inst == null:
		refused = version
		return
	refused = 0
	_revert()
	if fx is Node:
		remove_child(fx)
		fx.queue_free()
	fx = inst
	if fx is Node:
		fx.process_mode = Node.PROCESS_MODE_DISABLED   # (runs only while applied)
		add_child(fx)
	on_screen = version
	applied_at = ""
	if enabled:
		_apply()


func _apply() -> void:
	var n := catch.count()
	if fx.has_method("apply"):
		fx.apply(self)
	if fx is Node:
		fx.process_mode = Node.PROCESS_MODE_INHERIT
	applied = true
	_settle()
	gen = _gen()                                   # (what is on screen now, the lab's own sky material included)
	if applied_at == "":                           # (the time of the edit, not of a re-apply)
		applied_at = Time.get_time_string_from_system()
		applied_bad = catch.count() > n
	dirty = true


# back to the viewer's own settings: lab.gd's revert(), the parameters and properties it changed, its nodes and tweens,
# the environment and the sun
func _revert() -> void:
	if applied and fx != null and fx.has_method("revert"):
		fx.revert(self)
	if fx is Node:
		fx.process_mode = Node.PROCESS_MODE_DISABLED
	applied = false
	for i in range(changed.size() - 1, -1, -1):
		_put(changed[i], changed[i][2])
	changed.clear()
	for n in root3d.get_children() + canvas.get_children():
		n.get_parent().remove_child(n)
		n.queue_free()
	posts.clear()
	for tr in tracked:
		for k in tr[1]:
			if _differs(tr[0].get(k), tr[1][k]):
				tr[0].set(k, tr[1][k])
		tr[2] = tr[1].duplicate()


func _track(obj: Object, names: Array) -> void:
	var base := {}
	for k in names:
		base[k] = obj.get(k)
	tracked.append([obj, base, base.duplicate()])


func _props(classes: Array) -> Array:
	var out := []
	for c in classes:
		for p in ClassDB.class_get_property_list(c, true):
			if p["usage"] & PROPERTY_USAGE_STORAGE and not (p["usage"] & PROPERTY_USAGE_READ_ONLY):
				out.append(StringName(p["name"]))
	return out


# the environment and sun values the lab left (lab.param / lab.prop keep theirs when called)
func _settle() -> void:
	for tr in tracked:
		for k in tr[2]:
			tr[2][k] = tr[0].get(k)


# what the viewer set since the lab ran: its value is the new base (restored when the lab goes), the lab's stays on top
func _sync() -> void:
	for tr in tracked:
		var base: Dictionary = tr[1]
		var after: Dictionary = tr[2]
		for k in after:
			var now = tr[0].get(k)
			if _differs(now, after[k]):
				var ours: bool = applied and _differs(after[k], base[k])
				base[k] = now
				if ours:
					tr[0].set(k, after[k])
				else:
					after[k] = now
	for c in changed:
		var now = _take(c)
		if _differs(now, c[3]):
			c[2] = now
			_put(c, c[3])


# (!= between some types is an error, Color and Vector3 for one: a shader parameter can be set as either)
func _differs(a, b) -> bool:
	return typeof(a) != typeof(b) or a != b


func _change(o: Object, key: String, value, is_param: bool) -> void:
	for c in changed:
		if c[0] == o and c[1] == key:
			_put(c, value)
			c[3] = _take(c)
			return
	var c := [o, key, null, value, is_param]
	c[2] = _take(c)
	changed.append(c)
	_put(c, value)
	c[3] = _take(c)


func _take(c: Array):
	if not is_instance_valid(c[0]):
		return c[3]
	return c[0].get_shader_parameter(c[1]) if c[4] else c[0].get(c[1])


func _put(c: Array, value) -> void:
	if not is_instance_valid(c[0]):
		return
	if c[4]:
		c[0].set_shader_parameter(c[1], value)
	else:
		c[0].set(c[1], value)


# the mission's materials: the sky's and the ground's are new with each mission
func _gen() -> String:
	var s = sky()
	var gm: Array = v.ground_mats
	return "%d/%d/%d/%d" % [s.get_instance_id() if s != null else 0, gm.size(),
		gm[0].get_instance_id() if gm.size() else 0, gm[-1].get_instance_id() if gm.size() else 0]


# new code for a shader or an include, kept only if it compiles (the shaders using an include compile again right
# away): otherwise the last good one goes back
func _code(res, text: String, good: String) -> bool:
	var n := catch.count()
	res.code = text
	if catch.count() == n:
		return true
	if good != "":
		res.code = good
	return false


# shaders/<name>: the viewer's own shader of that name runs the lab's code while the file is there. Includes first when
# set, last when given back
func _shaders() -> void:
	var seen := {}
	var files := Array(DirAccess.get_files_at(dir + "/shaders")) if DirAccess.dir_exists_absolute(dir + "/shaders") else []
	files.sort_custom(func(a, b): return a.ends_with("inc") and not b.ends_with("inc"))
	for f in files:
		if not (f.ends_with(".gdshader") or f.ends_with(".gdshaderinc")):
			continue
		var path: String = "res://" + f
		if not ResourceLoader.exists(path):
			continue
		seen[path] = true
		var text := _read("shaders/" + f)
		if text == "":
			continue
		if not replaced.has(path):
			var r = load(path)
			replaced[path] = [r, r.code, "", "", r.code]   # [resource, good code, lab text, note, its own code]
		var e: Array = replaced[path]
		if e[2] != text:
			_fresh()
			e[2] = text
			if _code(e[0], text, e[1]):
				e[1] = text
				e[3] = Time.get_time_string_from_system()
			else:
				e[3] = "refused " + Time.get_time_string_from_system() + ", the previous code stays"
	var gone := replaced.keys().filter(func(p): return not seen.has(p))
	gone.sort_custom(func(a, b): return b.ends_with("inc") and not a.ends_with("inc"))
	for path in gone:                              # taken away: the viewer's own code again
		_fresh()
		replaced[path][0].code = replaced[path][4]
		replaced.erase(path)


func _follow(file: String) -> void:
	var text := _read(file)
	var e: Array = followed[file]
	if text == "" or text == e[1]:
		return
	if e[1] != "":
		_fresh()
	e[1] = text
	if _code(e[0], text, e[2]):
		e[2] = text
	for r in posts.get(file, []):
		if is_instance_valid(r):
			r.visible = e[2] != ""
	dirty = true


func _snap() -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	if img == null or img.is_empty():
		shot = "no picture (no screen)"
	else:
		img.save_png(dir + "/shot.png")
		shot = "shot.png " + Time.get_time_string_from_system()
	dirty = true


func _status() -> void:
	var cur: Dictionary = v.current
	var st := "waiting for a lab.gd that compiles"
	if not enabled:
		st = "lab off (Insert), lab.gd v%d waiting" % on_screen
	elif applied:
		st = "lab.gd v%d applied %s%s" % [on_screen, applied_at, " WITH ERRORS (below)" if applied_bad else ""]
	if refused:
		st += ", v%d refused (error below)%s" % [refused, ", v%d stays" % on_screen if on_screen else ""]
	var out := [st,
		"mission: " + (str(cur["entry"]["file"]).get_file() if not cur.is_empty() else "none"),
		"look: " + ("modern" if v._is_modern() else "old school (F12 for the smooth look)"),
		"shaders replaced: " + ", ".join(replaced.keys().map(func(p): return "%s (%s)" % [p.get_file(), replaced[p][3]])),
		"files followed: " + ", ".join(followed.keys()),
		"snap: " + shot, "", "errors since the last change (newest last):"]
	for e in errors:
		out.append("%s  %s%s" % [e[0], e[1], " (x%d)" % e[2] if e[2] > 1 else ""])
	if errors.is_empty():
		out.append("none")
	out.append_array(["", "lab.log:"])
	out.append_array(lines)
	_write("status.txt", "\n".join(out) + "\n")
	var bad := not errors.is_empty()
	label.text = ("LAB off (Insert)" if not enabled else "LAB v%d" % on_screen) + \
		("  (v%d refused)" % refused if refused else "") + ("  errors: status.txt" if bad else "")
	label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6) if not enabled else
		(Color(1, 0.4, 0.3) if bad else Color(0.5, 1, 0.6)))


func _read(file: String) -> String:
	var f := FileAccess.open(dir + "/" + file, FileAccess.READ)  # (no error printed when it is being written)
	return f.get_as_text() if f != null else ""


func _write(file: String, text: String) -> void:
	var f := FileAccess.open(dir + "/" + file, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
