# Every script and scene of the project loads (no parse error, no missing script or resource): the stable channel's
# first check (.github/workflows/stable.yml). Shaders are not compiled here (the headless run has no renderer).
#   godot --headless --path . --import ; godot --headless --path . --script res://tools/check_project.gd
extends SceneTree

const SKIP := ["res://.godot", "res://addons", "res://export", "res://movies_hd"]


func _initialize() -> void:
	var files := []
	_walk("res://", files)
	var bad := 0
	for f in files:
		var r: Resource = load(f)
		var ok := r != null
		if ok and r is GDScript:
			ok = (r as GDScript).can_instantiate()
		if not ok:
			bad += 1
			print("  FAIL  ", f)
	print("%d / %d scripts and scenes load" % [files.size() - bad, files.size()])
	quit(1 if bad or files.is_empty() else 0)


func _walk(dir: String, out: Array) -> void:
	for d in DirAccess.get_directories_at(dir):
		var p := dir.path_join(d)
		if not SKIP.has(p) and not d.begins_with("."):
			_walk(p, out)
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd") or f.ends_with(".tscn"):
			out.append(dir.path_join(f))
