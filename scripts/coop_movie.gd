# Co-op guest: the game's videos (the mission briefings, the launch cinematics, the others) shown and heard in his
# window while the host's game plays them, in step with it. The host's bridge says which video plays and its frame
# (live/host_state.py, 'HST': the .SMK DOS opened last, the frame the game's Smacker player is on); the guest decodes
# the same video from his own game files (TNOVA\MOVIE\*.SMK) with live/smkplay/smkdec.exe (Godot plays no Smacker:
# a small C# decoder, built on his PC the first time with the C# compiler that comes with Windows), into
# user://smkplay/NAME.tnv (each frame's palette and pixels, then the sound), and plays that: the frames through a
# palette shader, the sound as an AudioStreamWAV on the master bus (his "Game sound" volume) at the game's sound volume.
# Shown as the game shows it (measured on its screen, 18/11/2026): a briefing (320 x 240) at its size in the middle of
# a 640 x 480 screen; a launch video (320 x 160) on a 320 x 200 screen, 20 lines down; that screen as a 4:3 picture in
# the middle of the window, black around. Off unless asked for (TN_COOP_VIDEOS = 1, or the guest's Options: "Briefing videos"); without it, or
# while the video is not ready, or with an older host that does not say the frame, host_state.gd's text briefing.
# Times here are the engine's own clock: the video follows the host's game in real time, never Uplink's frozen scene.
extends Node

const CFG := "user://viewer.cfg"
const DIR := "user://smkplay"
const KEEP := 2                                     # decoded videos kept (about 90 MB for a briefing, 350 MB the longest)
const SHADER := """
shader_type canvas_item;
uniform sampler2D pal : filter_nearest;
void fragment() {
	int i = int(texture(TEXTURE, UV).r * 255.0 + 0.5);
	COLOR = vec4(texelFetch(pal, ivec2(i, 0), 0).rgb, 1.0);
}
"""

var v: Node
var on := false
var layer: CanvasLayer
var screen: Control
var pic: TextureRect
var idx_tex: ImageTexture
var pal_tex: ImageTexture
var last_pal := PackedByteArray()
var audio: AudioStreamPlayer
var volume := 1.0                                   # the game's sound volume (0-1), as coop_sound.gd has it

var movie_dir := ""
var exe := ""
var worker: Thread
var jobs: Array[String] = []                        # videos to decode, in order
var ready_ok := {}                                  # name -> true once its .tnv is there
var failed := {}                                    # name -> true: no file, or the decoder failed (text instead)
var busy := ""

var want := ""                                      # the video the host's game plays now ("" none)
var want_frame := -1                                # its frame as the host said (-1: not said, an older host)
var start_us := -1                                  # engine usec when the host's game showed frame 0
var first_seen_us := 0
var marks := []                                     # [engine usec, frame] of the host's last packets
var held := false                                   # the host's game said its frame 0 (or not yet known): shown still
var cur := ""                                       # the video loaded
var file: FileAccess
var w := 0
var h := 0
var frames := 0
var period := 1.0 / 15.0
var rec := 0
var foff := 0
var shown := -1
var playing := false
var log_to: FileAccess                              # TN_COOP_VIDEO_LOG: each frame shown, with the system's time (tests)


func _ready() -> void:
	if v == null:
		v = get_parent().get("v")
	on = OS.get_environment("TN_COOP_VIDEOS") == "1"
	var cfg := ConfigFile.new()
	if cfg.load(CFG) == OK and cfg.has_section_key("launcher", "coop_videos"):
		on = str(cfg.get_value("launcher", "coop_videos", "0")) == "1"
	layer = CanvasLayer.new()
	layer.layer = 27                                # over the HUD and host_state.gd's panels, under Uplink's menu
	layer.visible = false
	add_child(layer)
	var back := ColorRect.new()
	back.color = Color.BLACK
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(back)
	screen = Control.new()
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(screen)
	pic = TextureRect.new()
	pic.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	pic.stretch_mode = TextureRect.STRETCH_SCALE
	pic.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	pic.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sh := Shader.new()
	sh.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = sh
	pic.material = mat
	screen.add_child(pic)
	audio = AudioStreamPlayer.new()
	add_child(audio)
	if OS.get_environment("TN_COOP_VIDEO_LOG") != "":
		log_to = FileAccess.open(OS.get_environment("TN_COOP_VIDEO_LOG"), FileAccess.WRITE)


func set_on(x: bool) -> void:
	on = x
	if not on:
		_stop()


func is_playing() -> bool:
	return playing


# ---------------------------------------------------------------- from host_state.gd, each 'HST' packet
# state: the host's (host_state.gd's enum); movie: the .SMK playing ("" none); frame: the frame the game shows (-1 not
# said: an older host; -2 no video plays; -3 not known yet); mission: the MISSn number (its briefing decoded ahead)
# The game holds the first frame a moment (half a second for a briefing: its sound loading) before it goes on at 15 a
# second: the time is taken from frames 1 and later only. Each packet bounds when frame 0 would have been shown
# (frame k on screen at t: between t - (k + 1) / 15 s and t - k / 15 s); the bounds of the last 3 s, crossed, give it
# within a few ms; bounds that no longer meet (the host's game slowed, or the video started again): from the newest.
func host(state: int, movie: String, frame: int, mission: int, custom: bool) -> void:
	if not on:
		return
	if mission > 0 and not custom and state in [5, 6]:     # (BASE, BRIEFING) its briefing decoded before it is needed
		_prepare("BRIEF%02dA" % mission)
	var plays := movie != "" and frame != -2 and (frame >= 0 or state in [6, 8])   # (an older host: BRIEFING, LAUNCH)
	if movie == "HISPLASA" or state in [2, 3, 7, 9, 10]:      # (the main menu's own animation; menus, outfitting, mission)
		plays = false
	var now := Time.get_ticks_usec()
	if not plays:
		want = ""
		return
	if movie != want:
		want = movie
		start_us = -1
		marks.clear()
		first_seen_us = now
		held = false
		_prepare(movie)
	want_frame = frame
	if frame >= 1:
		marks.append([now, frame])
		while marks.size() > 1 and now - int(marks[0][0]) > 3000000:
			marks.remove_at(0)
		var p_us := period * 1e6
		var lo := -INF
		var hi := INF
		for m in marks:
			lo = maxf(lo, m[0] - (m[1] + 1) * p_us)
			hi = minf(hi, m[0] - m[1] * p_us)
		if lo > hi:
			marks = [marks.back()]
			lo = marks[0][0] - (marks[0][1] + 1) * p_us
			hi = marks[0][0] - marks[0][1] * p_us
		start_us = int((lo + hi) * 0.5)
	elif frame == 0 or frame == -3:
		held = true                                  # (on its first frame, or not known yet: frame 0 shown, waiting)
	elif start_us < 0:
		start_us = first_seen_us - 150000            # (an older host: seen up to 0.2 s after it began, at 0.5 s steps)


# ---------------------------------------------------------------- decoding (a thread: the C# decoder, run hidden)
func _prepare(name: String) -> void:
	if ready_ok.has(name) or failed.has(name) or name in jobs or busy == name:
		return
	jobs.append(name)


# one video at a time, on a thread of its own; its result taken here when it is over
func _pump() -> void:
	if worker != null and not worker.is_alive():
		var ok: bool = worker.wait_to_finish()
		if ok:
			ready_ok[busy] = true
		else:
			failed[busy] = true
		worker = null
		busy = ""
	if worker == null and not jobs.is_empty():
		busy = jobs.pop_front()
		worker = Thread.new()
		worker.start(_decode.bind(busy))

func _movie_path(name: String) -> String:
	if movie_dir == "":
		var root := ""
		if v != null and v.get("data") != null and v.data.get("root") != null:
			root = str(v.data.root)
		movie_dir = root.path_join("TNOVA/MOVIE")
	for n in [name + ".SMK", name + ".smk", name.to_lower() + ".smk"]:
		if FileAccess.file_exists(movie_dir.path_join(n)):
			return movie_dir.path_join(n)
	return ""


func _decode(name: String) -> bool:
	var src := _movie_path(name)
	if src == "":
		print("coop video: %s not in %s" % [name, movie_dir])
		return false
	var dir := ProjectSettings.globalize_path(DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var out := dir.path_join(name + ".tnv")
	if not _have_exe():                              # (first: a decoder built anew clears the videos of the one before)
		return false
	if FileAccess.file_exists(out):
		return true
	var t := Time.get_ticks_msec()
	var log := []
	var code := OS.execute(exe, [ProjectSettings.globalize_path(src).replace("/", "\\"), out.replace("/", "\\")], log, true)
	if code != 0 or not FileAccess.file_exists(out):
		print("coop video: decoding %s failed (%d) %s" % [name, code, str(log)])
		return false
	print("coop video: %s decoded in %d ms" % [name, Time.get_ticks_msec() - t])
	_prune(dir, name)
	return true


# the decoder: the one built in live/smkplay (build.bat), else built once into user://smkplay with Windows' own C#
# compiler (.NET Framework 4, in every Windows since 8)
func _have_exe() -> bool:
	if exe != "" and FileAccess.file_exists(exe):
		return true
	var src := ProjectSettings.globalize_path("res://live/smkplay/smkdec.cs")
	var dev := src.get_base_dir().path_join("smkdec.exe")
	var own := ProjectSettings.globalize_path(DIR).path_join("smkdec.exe")
	var stamp := ProjectSettings.globalize_path(DIR).path_join("smkdec.stamp")
	var src_t := FileAccess.get_modified_time(src)
	if FileAccess.file_exists(dev) and FileAccess.get_modified_time(dev) >= src_t:
		exe = dev
		return true
	if FileAccess.file_exists(own) and FileAccess.file_exists(stamp) and FileAccess.get_file_as_string(stamp) == str(src_t):
		exe = own
		return true
	var win := OS.get_environment("WINDIR")
	var csc := ""
	for fw in ["Framework64", "Framework"]:
		var c := win.path_join("Microsoft.NET").path_join(fw).path_join("v4.0.30319").path_join("csc.exe")
		if FileAccess.file_exists(c):
			csc = c
			break
	if csc == "" or not FileAccess.file_exists(src):
		print("coop video: no C# compiler (%s) or no decoder source" % win)
		return false
	DirAccess.make_dir_recursive_absolute(own.get_base_dir())
	var log := []
	# (Windows' paths: the compiler reads a forward slash as an option's)
	var code := OS.execute(csc, ["/nologo", "/optimize", "/target:exe", "/out:" + own.replace("/", "\\"), src.replace("/", "\\")], log, true)
	if code != 0 or not FileAccess.file_exists(own):
		print("coop video: building the decoder failed (%d) %s" % [code, str(log)])
		return false
	var f := FileAccess.open(stamp, FileAccess.WRITE)
	if f:
		f.store_string(str(src_t))
	exe = own
	var d := DirAccess.open(own.get_base_dir())
	if d:
		for old in d.get_files():                    # (videos decoded by the decoder before: decoded again)
			if old.ends_with(".tnv"):
				d.remove(old)
	print("coop video: decoder built")
	return true


func _prune(dir: String, keep_name: String) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	var list := []
	for f in d.get_files():
		if f.ends_with(".tnv") and f.get_basename() != keep_name and f.get_basename() != cur:
			list.append([FileAccess.get_modified_time(dir.path_join(f)), f])
	list.sort()
	while list.size() > KEEP - 1:
		var f: String = list.pop_front()[1]
		DirAccess.remove_absolute(dir.path_join(f))
		ready_ok.erase(f.get_basename())


# ---------------------------------------------------------------- playing
func _process(_delta: float) -> void:
	_pump()
	if not on or want == "" or (cur != "" and cur != want):
		if playing or cur != "":
			_stop()
		if not on or want == "":
			return
	if cur == "":
		if not ready_ok.has(want) or (start_us < 0 and not held):
			return
		if not _open(want):
			failed[want] = true
			want = ""
			return
	if start_us < 0:                                # the game on its first frame: the same, silent
		if not playing:
			playing = true
			layer.visible = true
		_layout()
		if shown != 0:
			_show(0)
		return
	var p := (Time.get_ticks_usec() - start_us) / 1e6
	var dur := frames * period
	if p >= dur + 0.3:
		_stop()
		want = ""
		return
	if p < 0.0:
		return
	if not playing:
		playing = true
		layer.visible = true
	_layout()
	# the sound and the picture at the host's time (its sound put back there when it drifts by more than 0.12 s)
	if audio.stream != null and p < dur - 0.05:
		volume = _game_volume()
		audio.volume_db = linear_to_db(maxf(volume, 0.001))
		if not audio.playing:
			audio.play(p)
		else:
			var ap := audio.get_playback_position() + AudioServer.get_time_since_last_mix() - AudioServer.get_output_latency()
			if absf(ap - p) > 0.12:
				audio.seek(p)
	var fr := clampi(int(p / period), 0, frames - 1)
	if fr != shown:
		_show(fr)


func _open(name: String) -> bool:
	file = FileAccess.open(ProjectSettings.globalize_path(DIR).path_join(name + ".tnv"), FileAccess.READ)
	if file == null or file.get_length() < 64:
		return false
	var hd := file.get_buffer(64)
	if hd.slice(0, 4).get_string_from_ascii() != "TNV1":
		return false
	w = hd.decode_u32(4)
	h = hd.decode_u32(8)
	frames = hd.decode_u32(12)
	period = hd.decode_u32(16) / 1e6
	var rate := hd.decode_u32(20)
	var chans := hd.decode_u32(24)
	var bits := hd.decode_u32(28)
	var alen := hd.decode_u32(32)
	var aoff := hd.decode_u32(36)
	foff = hd.decode_u32(40)
	rec = hd.decode_u32(44)
	if w <= 0 or h <= 0 or frames <= 0 or rec != 768 + w * h:
		return false
	audio.stream = null
	if rate > 0 and alen > 0:
		file.seek(aoff)
		var st := AudioStreamWAV.new()
		st.format = AudioStreamWAV.FORMAT_8_BITS if bits == 8 else AudioStreamWAV.FORMAT_16_BITS
		st.mix_rate = rate
		st.stereo = chans == 2
		st.data = file.get_buffer(alen)
		audio.stream = st
	idx_tex = ImageTexture.create_from_image(Image.create(w, h, false, Image.FORMAT_R8))
	pal_tex = ImageTexture.create_from_image(Image.create(256, 1, false, Image.FORMAT_RGB8))
	last_pal = PackedByteArray()
	pic.texture = idx_tex
	(pic.material as ShaderMaterial).set_shader_parameter("pal", pal_tex)
	cur = name
	shown = -1
	print("coop video: %s playing (%d x %d, %d frames)" % [name, w, h, frames])
	return true


func _show(fr: int) -> void:
	shown = fr
	if log_to:
		log_to.store_line("%.4f %s %d" % [Time.get_unix_time_from_system(), cur, fr])
		log_to.flush()
	file.seek(foff + fr * rec)
	var b := file.get_buffer(rec)
	if b.size() < rec:
		return
	var pal := b.slice(0, 768)
	if pal != last_pal:
		last_pal = pal
		pal_tex.update(Image.create_from_data(256, 1, false, Image.FORMAT_RGB8, pal))
	idx_tex.update(Image.create_from_data(w, h, false, Image.FORMAT_R8, b.slice(768)))


func _layout() -> void:
	var vs: Vector2 = get_viewport().get_visible_rect().size
	var box := Vector2(vs.y * 4.0 / 3.0, vs.y) if vs.x * 3.0 >= vs.y * 4.0 else Vector2(vs.x, vs.x * 0.75)
	screen.size = box
	screen.position = ((vs - box) * 0.5).round()
	# the game's screen mode for the video: 320 x 200 for one that fits (the launch videos), else 640 x 480
	var scr := Vector2(320, 200) if w <= 320 and h <= 200 else Vector2(maxi(640, w), maxi(480, h))
	var k := box / scr
	pic.position = (((scr - Vector2(w, h)) * 0.5).floor() * k).round()
	pic.size = (Vector2(w, h) * k).round()


func _game_volume() -> float:
	if v != null:
		for n in v.get_children():                  # coop_hud.gd's coop_sound.gd: the game's volume ('SND' packets)
			var cs = n.get("sound")
			if cs is Node and cs.get("master") != null:
				return clampf(float(cs.master) / 127.0, 0.0, 1.0)
	return 101.0 / 127.0


func _stop() -> void:
	if audio.playing:
		audio.stop()
	audio.stream = null
	file = null
	cur = ""
	shown = -1
	if playing:
		playing = false
		print("coop video: stopped")
	layer.visible = false


func _exit_tree() -> void:
	jobs.clear()
	if worker != null:
		worker.wait_to_finish()
		worker = null
