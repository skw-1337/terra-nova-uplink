# Coop guest: the game's sounds, heard at his own suit. The host's bridge tells which sounds the game starts and ends
# ('SND' packets, live/coop_guest.py sounds); this plays the same ones from his own game files (RESSOUND.RES, the
# game's VOC samples), with the game's own law for a sound placed in the world (its 0x247A08 / 0x2471B0), computed from
# his suit instead of the host's: the distance in units (none past 31 on any axis) gives a volume from the game's table,
# the side a pan (64 + 63 x sine of the angle from where he faces), a sound to a side a little softer, one behind 3/4,
# then the sound's own volume (RESSOUND.RES 2204, sounds 1900-2129) and the game's sound volume. A sound the game
# plays as its player's own (a shot) is placed at the suit that fired it. A sound placed nowhere (a radio call) is
# played as the game does, at its volume. Nothing while his window is minimised. The game's music (MIDI through the
# card's driver) is not played: Godot has no MIDI synthesizer.
extends Node

const LGRes = preload("res://scripts/lgres.gd")
const DIST := [100, 80, 64, 54, 46, 40, 34, 30, 26, 23, 21, 18, 16, 14, 13, 12, 11, 10, 9, 8, 7, 6, 6, 5, 5, 4, 3, 3, 2, 2, 1, 1]
const SIDE := [128, 128, 128, 128, 128, 128, 127, 127, 127, 127, 126, 126, 126, 125, 125, 125, 124, 124, 123, 122, 122, 121,
	121, 120, 120, 120, 119, 118, 117, 116, 116, 115, 115, 114, 113, 112, 111, 111, 110, 109, 109, 108, 107, 106, 106, 105,
	104, 103, 102, 102, 101, 100, 99, 99, 98, 97, 96, 96, 95, 94, 94, 93, 92, 91]
const VOICES := 16
const OWN_VOL := 2204                    # RESSOUND.RES: one byte a sound, for 1900 + n
const OWN_FIRST := 1900

var res = null                           # RESSOUND.RES
var own_vol := PackedByteArray()
var streams := {}                        # sound -> AudioStreamWAV (null: not in his files)
var voices := []                         # slot -> {player, bus, sound, kind, ent, at, vol, once}
var master := 101                        # the game's sound volume (0-127)
var log_to: FileAccess                   # TN_SOUND_LOG: what is played, for tests (no sound card needed)
var t0 := 0
var own_voice := {}


func _ready() -> void:
	for k in VOICES:
		var name := "CoopSound%d" % k
		var b := AudioServer.get_bus_index(name)
		if b < 0:
			AudioServer.add_bus()
			b = AudioServer.bus_count - 1
			AudioServer.set_bus_name(b, name)
			AudioServer.set_bus_send(b, "Master")
			AudioServer.add_bus_effect(b, AudioEffectPanner.new())
		var p := AudioStreamPlayer.new()
		p.bus = name
		add_child(p)
		voices.append({"player": p, "bus": b, "sound": 0})
	var lf := OS.get_environment("TN_SOUND_LOG")
	if lf != "":
		log_to = FileAccess.open(lf, FileAccess.WRITE)
	t0 = Time.get_ticks_msec()


func _hud() -> Node:
	return get_parent()


func _viewer() -> Node:
	var h := _hud()
	return h.get_parent() if h else null


# 'SND' + the game's sound volume + count, then 'S' (voice, sound, kind, once, volume, entity, x, y, z) or 'E' (voice)
func feed(pk: PackedByteArray) -> void:
	if pk.size() < 5:
		return
	master = pk[3]
	var p := 5
	for i in pk[4]:
		if p >= pk.size():
			break
		if pk[p] == 0x45 and p + 2 <= pk.size():
			_stop(pk[p + 1])
			p += 2
		elif pk[p] == 0x53 and p + 21 <= pk.size():
			_start(pk[p + 1], pk.decode_u16(p + 2), pk[p + 4], pk[p + 5], pk[p + 6], pk.decode_u16(p + 7),
					Vector3(pk.decode_float(p + 9), pk.decode_float(p + 13), pk.decode_float(p + 17)))
			p += 21
		else:
			break


func _start(k: int, sound: int, kind: int, once: int, vol: int, ent: int, at: Vector3) -> void:
	if k >= VOICES:
		return
	var v: Dictionary = voices[k]
	var s := _stream(sound, once == 0)
	v["sound"] = sound
	v["kind"] = kind
	v["ent"] = ent
	v["at"] = at
	v["vol"] = vol
	v["once"] = once
	(v["player"] as AudioStreamPlayer).stop()
	if s == null:
		v["sound"] = 0
		return
	_place(v)
	(v["player"] as AudioStreamPlayer).stream = s
	(v["player"] as AudioStreamPlayer).play()
	if log_to:
		log_to.store_line("%d start voice %d sound %d kind %d entity %d once %d volume %d pan %d" % [_now(), k, sound,
				kind, ent, once, v.get("out_vol", 0), v.get("out_pan", 64)])
		log_to.flush()


# a sound of his own window (his lock), on a voice of its own, not placed, at a volume of the game's (0-127)
func play_own(sound: int, vol: int) -> void:
	var v: Dictionary = own_voice
	if v.is_empty():
		var p := AudioStreamPlayer.new()
		add_child(p)
		v = {"player": p}
		own_voice = v
	var s := _stream(sound, false)
	if s == null:
		return
	var pl := v["player"] as AudioStreamPlayer
	pl.stream = s
	pl.volume_db = linear_to_db(clampi(vol * master >> 7, 1, 127) / 127.0)
	pl.play()
	if log_to:
		log_to.store_line("%d own sound %d volume %d" % [_now(), sound, vol])
		log_to.flush()


func _now() -> int:
	return int(Time.get_unix_time_from_system() * 1000.0) % 100000000


func _stop(k: int) -> void:
	if k >= VOICES:
		return
	var v: Dictionary = voices[k]
	if v["sound"] != 0 and log_to:
		log_to.store_line("%d stop voice %d sound %d" % [_now(), k, v["sound"]])
		log_to.flush()
	v["sound"] = 0
	(v["player"] as AudioStreamPlayer).stop()


func _process(_delta: float) -> void:
	var minimised := get_window().mode == Window.MODE_MINIMIZED
	for v in voices:
		if v["sound"] == 0:
			continue
		var pl := v["player"] as AudioStreamPlayer
		if not pl.playing:
			v["sound"] = 0
			continue
		_place(v)
		if minimised:
			pl.volume_db = -80.0


# where the sound comes from, as the game would hear it at his suit: volume (0-127) and pan (1-127)
func _place(v: Dictionary) -> void:
	var vol: int = v["vol"]
	var pan := 64
	var src = null
	if v["kind"] == 1:
		src = v["at"]
	elif v["ent"] > 0:
		src = _ent_pos(v["ent"])
		if src == null and v["at"] != Vector3.ZERO:
			src = v["at"]                                  # (a shot or a blast: not among his units, where it started)
	if src != null or v["kind"] in [1, 2, 5]:
		vol = 0
		var me = _listener()
		if src != null and me != null:
			var d: Vector3 = src - me[0]
			if absf(d.x) <= 31.0 and absf(d.y) <= 31.0 and absf(d.z) <= 31.0 and d.length() < 32.0:
				vol = DIST[int(d.length())]
				if Vector2(d.x, d.y).length() > 0.01:
					var rel := fposmod(atan2(d.y, d.x) - float(me[1]), TAU)
					pan = 64 + int(sin(rel) * 63.0)
					vol = vol * SIDE[mini(pan, 127 - pan)] >> 7
					if rel > PI / 2.0 and rel < PI * 1.5:
						vol = vol * 3 / 4
				vol = vol * _own_vol(v["sound"]) >> 6
	vol = clampi(vol * master >> 7, 0, 127)
	v["out_vol"] = vol
	v["out_pan"] = pan
	var pl := v["player"] as AudioStreamPlayer
	pl.volume_db = linear_to_db(vol / 127.0) if vol > 0 else -80.0
	var pe := AudioServer.get_bus_effect(v["bus"], 0) as AudioEffectPanner
	if pe:
		pe.pan = clampf((pan - 64) / 63.0, -1.0, 1.0)


# his suit (or, without one, the host's): its place (game x, y, z) and heading (radians)
func _listener():
	var h := _hud()
	var e: int = h.entity if h and h.state == 0 and h.entity > 0 else (h.host_ent if h else 0)
	var vp := _viewer()
	if vp == null or not ("live_ents" in vp) or not vp.live_ents.has(e):
		return null
	var a: Array = vp.live_ents[e]
	return [Vector3(a[3], a[4], a[5]), a[6]]


func _ent_pos(e: int):
	var vp := _viewer()
	if vp == null or not ("live_ents" in vp) or not vp.live_ents.has(e):
		return null
	var a: Array = vp.live_ents[e]
	return Vector3(a[3], a[4], a[5])


func _own_vol(sound: int) -> int:
	if own_vol.is_empty():
		_open()
	var i := sound - OWN_FIRST
	if i < 0 or i >= own_vol.size():
		return 0                                           # (the game: none for another sound placed in the world)
	var b := own_vol[i]
	return b - 256 if b >= 128 else b


func _open() -> void:
	if res != null:
		return
	var vp := _viewer()
	if vp and "data" in vp:
		res = LGRes.open(vp.data.data_dir().path_join("RESSOUND.RES"))
	own_vol = PackedByteArray([0])
	if res and res.has(OWN_VOL):
		var fr: Array = LGRes.frames(res.data(OWN_VOL))
		own_vol = PackedByteArray()
		for f in fr:
			own_vol.append((f as PackedByteArray)[0] if (f as PackedByteArray).size() > 0 else 0)


# the game's VOC sample (8-bit unsigned PCM blocks), looped for a sound the game plays until it stops it
func _stream(sound: int, loop: bool) -> AudioStreamWAV:
	var key := sound * 2 + (1 if loop else 0)
	if streams.has(key):
		return streams[key]
	_open()
	var s: AudioStreamWAV = null
	if res and res.has(sound):
		var d: PackedByteArray = res.data(sound)
		if d.size() >= 0x20 and d.slice(0, 19).get_string_from_ascii() == "Creative Voice File":
			var p := d.decode_u16(0x14)
			var pcm := PackedByteArray()
			var rate := 11025
			while p + 4 <= d.size():
				var typ := d[p]
				if typ == 0:
					break
				var n := d[p + 1] | (d[p + 2] << 8) | (d[p + 3] << 16)
				if typ == 1 and n > 2:
					rate = int(1000000.0 / (256 - d[p + 4]))
					pcm.append_array(d.slice(p + 6, p + 4 + n))
				elif typ == 2:
					pcm.append_array(d.slice(p + 4, p + 4 + n))
				p += 4 + n
			for i in pcm.size():
				pcm[i] = (pcm[i] - 128) & 0xFF
			s = AudioStreamWAV.new()
			s.format = AudioStreamWAV.FORMAT_8_BITS
			s.mix_rate = rate
			s.data = pcm
			if loop and pcm.size() > 0:
				s.loop_mode = AudioStreamWAV.LOOP_FORWARD
				s.loop_begin = 0
				s.loop_end = pcm.size()
	streams[key] = s
	return s
