# Co-op guest: the game's music, heard in his window as the host's game plays it. The game plays its music through the
# sound card's MIDI driver (Miles, XMIDI sequences in RESSOUND.RES 2205-2221, picked by its music cues, table 2222);
# the host's bridge (live/coop_music.py) reads which sequences the driver plays and where ('MUS' packets) and this
# plays the same ones from his own game files, at the same place, with his own General MIDI synthesizer: the Roland
# GS sound set Windows has (System32\drivers\gm.dls, the bank of the "Microsoft GS Wavetable Synth" a host with
# Music = Roland hears) played by Godot as samples (pitch, loops, the DLS envelopes, vibrato, pan, the channels'
# volume, expression and pitch bend). Volume: the game's music volume and the sequence's (Miles scales the channels'
# volume by both), then his own (Options, Music: 100 % by default, the game's own level; 0 = off, nothing loaded).
# A host playing with TN+'s AWE32 bank (Music = AWE32: FluidSynth in his DOSBox, flag 4) is heard with the same bank when
# this PC has it: TNPlus_awe32.sf2, which TN+ builds next to its TNPlus.exe from the game's FF.SBK and the AWE32 ROM
# the player brings (components	nplus_coop or tnplus of the Uplink launcher, or TN_MUSIC_SF2); without it, the GS set.
#   'MUS' + version (1) + the game's music volume (0-127) + flags (1: music on, 2: the General MIDI arrangement,
#   4: the host plays it with TN+'s AWE32 bank, 8: the host's synthesizer known)
#   + count, then per sequence playing: slot (u8), cue (u16), resource (u16), sequence (u8), status (u8),
#   volume (u8, the sequence's now), byte offset in its EVNT (u32), intervals to wait (u16)
extends Node

const LGRes = preload("res://scripts/lgres.gd")
const CFG := "user://viewer.cfg"
const TICK := 120.0                  # Miles plays XMIDI at 120 intervals a second
const CUES := 2222                   # RESSOUND.RES: the music cues, 10 bytes each (res FM/GM arrangement, seq, volume...)
const POLY := 64
const PANS := 9                      # pan buses, left to right
const RESYNC := 30                   # intervals off the host before jumping to his place (1/4 s)
const TRIM := 0.003                  # tempo nudge an interval off (at most 2 %: not heard)
const TRIM_MAX := 0.02
const FOR_NEST := 4
const PLAYING := 4                   # Miles SEQ_PLAYING

var res = null                       # RESSOUND.RES
var cues := []                       # cue -> [res A, res B, seq]
var parsed := {}                     # res * 256 + seq -> sequence (see _parse)
var dls := {}                        # instruments, waves (see _dls_open)
var dls_ok := false
var sf2 := {}                        # TN+'s AWE32 bank: presets, instruments, samples (see _sf2_open)
var sf2_tried := false
var awe := false                     # the host plays with the AWE32 bank, and this PC has it: notes from sf2
var streams := {}                    # wave index -> AudioStreamWAV
var player: AudioStreamPlayer
var pb: AudioStreamPlaybackPolyphonic
var slots := {}                      # host slot -> playing sequence (see _start)
var voices := []                     # notes sounding: {id, slot, ch, key, ...}
var master := 100                    # the game's music volume (0-127)
var music_on := true
var gm := true                       # the host plays the General MIDI arrangement
var last_pk := PackedByteArray()
var user_pct := 0.0
var log_to: FileAccess               # TN_MUSIC_LOG: what is played, for tests
var notes_n := 0
var clock := 0.0
var rec: AudioEffectRecord           # TN_MUSIC_REC: his window's sound (the master bus) saved every 20 s, numbered
var rec_to := ""
var rec_t := 0.0
var rec_n := 0


static func user_volume() -> float:
	var env := OS.get_environment("TN_COOP_MUSIC")
	if env != "":
		return clampf(float(env), 0.0, 100.0)
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	return clampf(float(cfg.get_value("sound", "guest_music", 100.0)), 0.0, 100.0)   # (no key: on)


# the Options' Music slider (uplink_menu.gd): kept in viewer.cfg [sound] guest_music, applied at once
static func set_user_volume(tree: SceneTree, x: float) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	cfg.set_value("sound", "guest_music", roundf(x))
	cfg.save(CFG)
	if tree:
		tree.call_group("coop_music", "_set_user", x)


func _ready() -> void:
	add_to_group("coop_music")
	var lf := OS.get_environment("TN_MUSIC_LOG")
	if lf != "":
		log_to = FileAccess.open(lf, FileAccess.WRITE)
	rec_to = OS.get_environment("TN_MUSIC_REC")
	if rec_to != "":
		rec = AudioEffectRecord.new()
		AudioServer.add_bus_effect(0, rec)
		rec.set_recording_active(true)
		_log("recording %s_%03d.wav" % [rec_to.get_basename(), rec_n])
	_set_user(user_volume())


func _rec_save() -> void:
	var w := rec.get_recording()
	rec.set_recording_active(false)
	rec.set_recording_active(true)
	if w:
		w.save_to_wav("%s_%03d.wav" % [rec_to.get_basename(), rec_n])
	rec_n += 1
	_log("recording %s_%03d.wav" % [rec_to.get_basename(), rec_n])


func _exit_tree() -> void:
	if rec:
		_rec_save()


func _log(s: String) -> void:
	if log_to:
		log_to.store_line("%d %s" % [int(Time.get_unix_time_from_system() * 1000.0) % 100000000, s])
		log_to.flush()


func _set_user(x: float) -> void:
	user_pct = x
	if x <= 0.5:
		_stop_all()
		if player:
			AudioServer.set_bus_mute(AudioServer.get_bus_index("CoopMusic"), true)
		return
	if not _setup():
		return
	var b := AudioServer.get_bus_index("CoopMusic")
	AudioServer.set_bus_mute(b, false)
	AudioServer.set_bus_volume_db(b, linear_to_db(x / 100.0))
	if not last_pk.is_empty() and slots.is_empty():
		feed(last_pk)                                  # (turned on while the host plays: from where he is)


# the buses (a panner each, into one with the volume, a little reverb as the GS synth's and a limiter) and the player
func _setup() -> bool:
	if player:
		return dls_ok
	var mix := AudioServer.get_bus_index("CoopMusic")
	if mix < 0:
		AudioServer.add_bus()
		mix = AudioServer.bus_count - 1
		AudioServer.set_bus_name(mix, "CoopMusic")
		AudioServer.set_bus_send(mix, "Master")
		var rv := AudioEffectReverb.new()
		rv.room_size = 0.5
		rv.damping = 0.6
		rv.dry = 1.0
		rv.wet = 0.12
		AudioServer.add_bus_effect(mix, rv)
		var lim := AudioEffectHardLimiter.new()
		lim.ceiling_db = -0.5
		AudioServer.add_bus_effect(mix, lim)
	for k in PANS:
		var name := "CoopMusicP%d" % k
		if AudioServer.get_bus_index(name) < 0:
			AudioServer.add_bus()
			var b := AudioServer.bus_count - 1
			AudioServer.set_bus_name(b, name)
			AudioServer.set_bus_send(b, "CoopMusic")
			var pn := AudioEffectPanner.new()
			pn.pan = -1.0 + 2.0 * k / (PANS - 1)
			AudioServer.add_bus_effect(b, pn)
	player = AudioStreamPlayer.new()
	var poly := AudioStreamPolyphonic.new()
	poly.polyphony = POLY
	player.stream = poly
	player.bus = "CoopMusic"
	add_child(player)
	player.play()
	pb = player.get_stream_playback() as AudioStreamPlaybackPolyphonic
	var t0 := Time.get_ticks_usec()
	_open()
	_dls_open()
	_log("setup: game files %s, gm.dls %s (%d instruments), %.0f ms" % [res != null, dls_ok, dls.get("ins", {}).size(),
			(Time.get_ticks_usec() - t0) / 1000.0])
	return dls_ok


func _hud() -> Node:
	return get_parent()


func _viewer() -> Node:
	var h := _hud()
	return h.get_parent() if h else null


func _open() -> void:
	if res != null:
		return
	var vp := _viewer()
	var path := OS.get_environment("TN_MUSIC_RES")              # (tests without a viewer)
	if path == "" and vp and "data" in vp:
		path = vp.data.data_dir().path_join("RESSOUND.RES")
	if path != "":
		res = LGRes.open(path)
	if res and res.has(CUES):
		for f in LGRes.frames(res.data(CUES)):
			var b := f as PackedByteArray
			cues.append([b.decode_u16(0), b.decode_u16(2), b[4]] if b.size() >= 5 else [0, 0, 0])


# ---------------------------------------------------------------- the host's state
func feed(pk: PackedByteArray) -> void:
	if pk.size() < 7 or pk[3] != 1:
		return
	last_pk = pk
	master = pk[4]
	music_on = (pk[5] & 1) != 0
	gm = (pk[5] & 2) != 0
	if user_pct <= 0.5 or not _setup():
		return
	var want_awe := (pk[5] & 4) != 0 and _sf2_open()
	if want_awe != awe:                                        # (another synthesizer: the notes again from the host's place)
		_log("bank: %s" % ("TN+'s AWE32 bank %s" % sf2.get("path", "") if want_awe else "the GS set (gm.dls)"))
		_stop_all()
		awe = want_awe
	var seen := {}
	var p := 7
	for i in pk[6]:
		if p + 16 > pk.size():
			break
		var slot := pk[p]
		var cue := pk.decode_u16(p + 1)
		var rid := pk.decode_u16(p + 3)
		var seq := pk[p + 5]
		var status := pk[p + 6]
		var vol := pk[p + 7]
		var off := pk.decode_u32(p + 8)
		var wait := pk.decode_u16(p + 12)
		p += 16
		if status != PLAYING or not music_on:
			continue
		seen[slot] = true
		_follow(slot, cue, rid, seq, vol, off, wait)
	for slot in slots.keys():
		if not seen.has(slot):
			_end(slot)


# the sequence the host's slot plays: started or moved to his place when it is another one or too far off
func _follow(slot: int, cue: int, rid: int, seq: int, vol: int, off: int, wait: int) -> void:
	var host_seq := _parse(rid, seq)
	if host_seq.is_empty():
		return
	var at := _tick_at(host_seq, off, wait)                    # where the host is, in intervals from the start
	var mine := rid                                            # what this synthesizer plays: the GM arrangement
	if not gm and cue > 0 and cue < cues.size() and cues[cue][0] == rid and cues[cue][1] > 0:
		mine = cues[cue][1]                                    # (the host plays the FM one: the same piece for GM)
	var s: Dictionary = slots.get(slot, {})
	if s.is_empty() or s["rid"] != mine or s["seq"] != seq:
		if not s.is_empty():
			_end(slot)
		var sq := _parse(mine, seq)
		if sq.is_empty():
			return
		s = {"rid": mine, "seq": seq, "sq": sq, "idx": 0, "wait": 0.0, "pt": 0.0, "vol": vol, "vol_now": float(vol),
				"chans": [], "loops": [], "offs": [], "cue": cue}
		slots[slot] = s
		_seek(slot, s, at, mini(at, 60))
		_log("start slot %d cue %d res %d seq %d at %d (host res %d offset %d wait %d) volume %d" % [slot, cue, mine,
				seq, at, rid, off, wait, vol])
		return
	s["vol"] = vol
	var mine_at: int = int(s["sq"]["abs"][mini(s["idx"], s["sq"]["abs"].size() - 1)]) - int(s["wait"])
	if log_to:
		_log("at slot %d res %d seq %d: mine %d host %d (%+d intervals) volume %d/%d" % [slot, mine, seq, mine_at, at,
				mine_at - at, vol, master])
	s["trim"] = clampf(-(mine_at - at) * TRIM, -TRIM_MAX, TRIM_MAX)    # (a clock a little faster or slower than the
	if absi(mine_at - at) > RESYNC:                                    # game's: its tempo nudged, no jump)
		_log("resync slot %d res %d seq %d: mine %d host %d" % [slot, mine, seq, mine_at, at])
		_seek(slot, s, at, mini(at, 60) if at < 120 else 0)            # (his sequence started again: from its start)
		s["trim"] = 0.0


# the host's position: the interval of the event at that offset less the intervals still to wait before it
func _tick_at(sq: Dictionary, off: int, wait: int) -> int:
	var offs: PackedInt32Array = sq["off"]
	var i := offs.bsearch(off)
	if i >= offs.size():
		return int(sq["end"])
	return maxi(0, int(sq["abs"][i]) - wait)


# to interval 'at' of its sequence: the channels as the events before it leave them (programs, controllers), no notes;
# 'late' intervals before it played at once (a sequence just started: its first notes, a little late, not lost)
func _seek(slot: int, s: Dictionary, at: int, late := 0) -> void:
	_notes_off(slot, true)
	var sq: Dictionary = s["sq"]
	var chans := []
	for c in 16:
		chans.append({"prog": 0, "bank": 0, "vol": 100, "expr": 127, "pan": 64, "bend": 0.0, "range": 2.0, "mod": 0,
				"rpn": 16383, "sus": false})
	s["chans"] = chans
	s["loops"] = []
	var st: PackedByteArray = sq["st"]
	var abs_t: PackedInt32Array = sq["abs"]
	var i := 0
	while i < st.size() and abs_t[i] < at - late:
		var hi := st[i] & 0xF0
		if hi == 0xB0 or hi == 0xC0 or hi == 0xE0:
			_event(slot, s, i, false)
		i += 1
	s["idx"] = i
	s["wait"] = float(abs_t[i] - at) if i < st.size() else 0.0


func _end(slot: int) -> void:
	if slots.has(slot):
		_log("end slot %d res %d seq %d" % [slot, slots[slot]["rid"], slots[slot]["seq"]])
	_notes_off(slot, false)
	slots.erase(slot)


func _stop_all() -> void:
	for slot in slots.keys():
		_end(slot)
	if pb:
		for v in voices:
			pb.stop_stream(v["id"])
	voices.clear()


# ---------------------------------------------------------------- XMIDI
# a sequence's events: delay (intervals before it), status, data, note length, byte offset, interval from the start
func _parse(rid: int, seq: int) -> Dictionary:
	var key := rid * 256 + seq
	if parsed.has(key):
		return parsed[key]
	var out := {}
	_open()
	if res and res.has(rid):
		var ev := _evnt(res.data(rid), seq)
		if not ev.is_empty():
			out = _events(ev)
	parsed[key] = out
	return out


static func _evnt(b: PackedByteArray, want: int) -> PackedByteArray:
	var found := [0]
	var out := [PackedByteArray()]
	_iff_walk(b, 0, b.size(), want, found, out)
	return out[0]


static func _iff_walk(b: PackedByteArray, p: int, end: int, want: int, found: Array, out: Array) -> void:
	while p + 8 <= end and out[0].is_empty():
		var id := b.slice(p, p + 4).get_string_from_ascii()
		var n := (b[p + 4] << 24) | (b[p + 5] << 16) | (b[p + 6] << 8) | b[p + 7]
		var o := p + 8
		if id == "FORM" or id == "CAT ":
			var typ := b.slice(o, o + 4).get_string_from_ascii()
			if id == "FORM" and typ == "XMID":
				if found[0] == want:
					var q := o + 4
					while q + 8 <= o + n:
						var cid := b.slice(q, q + 4).get_string_from_ascii()
						var cn := (b[q + 4] << 24) | (b[q + 5] << 16) | (b[q + 6] << 8) | b[q + 7]
						if cid == "EVNT":
							out[0] = b.slice(q + 8, q + 8 + cn)
							return
						q += 8 + cn + (cn & 1)
				found[0] += 1
			elif typ != "XDIR":
				_iff_walk(b, o + 4, o + n, want, found, out)
		p = o + n + (n & 1)


static func _vlq(ev: PackedByteArray, p: Array) -> int:
	var v := 0
	while p[0] < ev.size():
		var x: int = ev[p[0]]
		p[0] += 1
		v = (v << 7) | (x & 0x7F)
		if x < 0x80:
			break
	return v


static func _events(ev: PackedByteArray) -> Dictionary:
	var dt := PackedInt32Array()
	var st := PackedByteArray()
	var d1 := PackedByteArray()
	var d2 := PackedByteArray()
	var dur := PackedInt32Array()
	var offs := PackedInt32Array()
	var abs_t := PackedInt32Array()
	var p := [0]
	var t := 0
	var wait := 0
	while p[0] < ev.size():
		var c: int = ev[p[0]]
		if c < 0x80:
			wait += c
			p[0] += 1
			continue
		var at: int = p[0]
		var hi := c & 0xF0
		var a := 0
		var b2 := 0
		var ln := 0
		if hi == 0x90:
			a = ev[p[0] + 1]
			b2 = ev[p[0] + 2]
			p[0] += 3
			ln = _vlq(ev, p)
		elif hi == 0x80 or hi == 0xA0 or hi == 0xB0 or hi == 0xE0:
			a = ev[p[0] + 1]
			b2 = ev[p[0] + 2]
			p[0] += 3
		elif hi == 0xC0 or hi == 0xD0:
			a = ev[p[0] + 1]
			p[0] += 2
		elif c == 0xFF:
			var typ: int = ev[p[0] + 1]
			p[0] += 2
			var n := _vlq(ev, p)
			p[0] += n
			if typ != 0x2F:
				continue                                      # (tempo, texts: Miles times XMIDI by intervals)
			a = 0x2F
		elif c == 0xF0 or c == 0xF7:
			p[0] += 1
			p[0] += _vlq(ev, p)
			continue
		else:
			break
		t += wait
		dt.append(wait)
		wait = 0
		st.append(c)
		d1.append(a)
		d2.append(b2)
		dur.append(ln)
		offs.append(at)
		abs_t.append(t)
		if c == 0xFF:
			break
	return {"dt": dt, "st": st, "d1": d1, "d2": d2, "dur": dur, "off": offs, "abs": abs_t, "end": t}


func _process(delta: float) -> void:
	clock += delta
	if rec:
		rec_t += delta
		if rec_t >= 20.0:
			rec_t = 0.0
			_rec_save()
	if slots.is_empty() and voices.is_empty():
		return
	var mute := get_window().mode == Window.MODE_MINIMIZED and DisplayServer.get_name() != "headless"
	var b := AudioServer.get_bus_index("CoopMusic")
	if b >= 0 and AudioServer.is_bus_mute(b) != (mute or user_pct <= 0.5):
		AudioServer.set_bus_mute(b, mute or user_pct <= 0.5)
	for slot in slots.keys():
		_run(slot, slots[slot], delta * TICK)
	_voices(delta)


# its events up to now; the note offs at their intervals
func _run(slot: int, s: Dictionary, ticks: float) -> void:
	ticks *= 1.0 + float(s.get("trim", 0.0))
	var sq: Dictionary = s["sq"]
	var st: PackedByteArray = sq["st"]
	var dt: PackedInt32Array = sq["dt"]
	s["pt"] = float(s["pt"]) + ticks
	var vn: float = s["vol_now"]
	var vt := float(s["vol"])
	s["vol_now"] = vt if absf(vt - vn) < 1.0 else vn + clampf(vt - vn, -ticks * 2.0, ticks * 2.0)   # (between packets)
	var w := float(s["wait"]) - ticks
	var i: int = s["idx"]
	var n := 0
	while w <= 0.0 and i < st.size() and n < 4000:
		_event(slot, s, i, true)
		i = int(s["idx"])                                       # (a loop jumps back)
		if st[i] == 0xFF:
			break
		i += 1
		s["idx"] = i
		if i < st.size():
			w += float(dt[i])
		n += 1
	s["wait"] = w
	var offs: Array = s["offs"]
	var pt: float = s["pt"]
	var k := 0
	while k < offs.size():
		if float(offs[k][0]) <= pt:
			_note_off(slot, offs[k][1], offs[k][2])
			offs.remove_at(k)
		else:
			k += 1


func _event(slot: int, s: Dictionary, i: int, live: bool) -> void:
	var sq: Dictionary = s["sq"]
	var c: int = sq["st"][i]
	var hi := c & 0xF0
	var ch := c & 15
	var a: int = sq["d1"][i]
	var v: int = sq["d2"][i]
	var cs: Dictionary = s["chans"][ch]
	if hi == 0x90 and live:
		if v > 0:
			_note_on(slot, s, ch, a, v)
			(s["offs"] as Array).append([float(s["pt"]) + float(sq["dur"][i]), ch, a])
	elif hi == 0x80 and live:
		_note_off(slot, ch, a)
	elif hi == 0xC0:
		cs["prog"] = a
	elif hi == 0xE0:
		cs["bend"] = (((v << 7) | a) - 8192) / 8192.0 * float(cs["range"])
		if live:
			_retune(slot, ch)
	elif hi == 0xB0:
		match a:
			0:
				cs["bank"] = v
			1:
				cs["mod"] = v
			6:
				if int(cs["rpn"]) == 0:
					cs["range"] = float(v)
			7:
				cs["vol"] = v
			10:
				cs["pan"] = v
			11:
				cs["expr"] = v
			64:
				cs["sus"] = v >= 64
				if not cs["sus"] and live:
					_release_held(slot, ch)
			100:
				cs["rpn"] = (int(cs["rpn"]) & 0x3F80) | v
			101:
				cs["rpn"] = (int(cs["rpn"]) & 0x7F) | (v << 7)
			116:                                                  # Miles FOR: loop from here, v times (0: always)
				var lp: Array = s["loops"]
				if lp.size() < FOR_NEST:
					lp.append([i, v])
			117:                                                  # Miles NEXT: back to the FOR
				var lp2: Array = s["loops"]
				if v >= 64 and not lp2.is_empty():
					var top: Array = lp2[lp2.size() - 1]
					if int(top[1]) == 0 or int(top[1]) > 1:
						if int(top[1]) > 1:
							top[1] = int(top[1]) - 1
						s["idx"] = int(top[0])
					else:
						lp2.pop_back()
			121:
				cs["mod"] = 0
				cs["expr"] = 127
				cs["bend"] = 0.0
				cs["sus"] = false
			120, 123:
				if live:
					_notes_off_ch(slot, ch)


# ---------------------------------------------------------------- the GS sound set (gm.dls)
func _dls_open() -> void:
	if dls_ok:
		return
	var path := OS.get_environment("TN_MUSIC_DLS")
	if path == "":
		path = OS.get_environment("WINDIR").path_join("System32/drivers/gm.dls")
	if not FileAccess.file_exists(path):
		_log("no gm.dls at %s: no music" % path)
		return
	var d := FileAccess.get_file_as_bytes(path)
	if d.size() < 12 or d.slice(0, 4).get_string_from_ascii() != "RIFF" or d.slice(8, 12).get_string_from_ascii() != "DLS ":
		return
	var ins := {}
	var cues_t := PackedInt32Array()
	var wvpl := -1
	var p := 12
	while p + 8 <= d.size():
		var id := d.slice(p, p + 4).get_string_from_ascii()
		var n := d.decode_u32(p + 4)
		var o := p + 8
		if id == "LIST" and d.slice(o, o + 4).get_string_from_ascii() == "lins":
			_lins(d, o + 4, o + n, ins)
		elif id == "LIST" and d.slice(o, o + 4).get_string_from_ascii() == "wvpl":
			wvpl = o + 4
		elif id == "ptbl":
			var cb := d.decode_u32(o)
			for k in d.decode_u32(o + 4):
				cues_t.append(d.decode_u32(o + cb + 4 * k))
		p = o + n + (n & 1)
	if ins.is_empty() or wvpl < 0:
		return
	dls = {"d": d, "ins": ins, "cues": cues_t, "wvpl": wvpl}
	dls_ok = true


static func _chunks(d: PackedByteArray, p: int, end: int) -> Array:
	var out := []
	while p + 8 <= end:
		var n := d.decode_u32(p + 4)
		out.append([d.slice(p, p + 4).get_string_from_ascii(), p + 8, n])
		p += 8 + n + (n & 1)
	return out


# instruments: (drum ? 0x10000 : 0) + bank MSB * 128 + program -> {regions, art}
func _lins(d: PackedByteArray, p: int, end: int, ins: Dictionary) -> void:
	for c in _chunks(d, p, end):
		if c[0] != "LIST":
			continue
		var bank := 0
		var prog := 0
		var regs := []
		var art := {}
		for c2 in _chunks(d, c[1] + 4, c[1] + c[2]):
			if c2[0] == "insh":
				bank = d.decode_u32(c2[1] + 4)
				prog = d.decode_u32(c2[1] + 8)
			elif c2[0] == "LIST" and d.slice(c2[1], c2[1] + 4).get_string_from_ascii() == "lart":
				art = _art(d, c2[1] + 4, c2[1] + c2[2])
			elif c2[0] == "LIST" and d.slice(c2[1], c2[1] + 4).get_string_from_ascii() == "lrgn":
				for r in _chunks(d, c2[1] + 4, c2[1] + c2[2]):
					var rg := {"lo": 0, "hi": 127, "group": 0, "wave": -1, "smp": {}}
					for c3 in _chunks(d, r[1] + 4, r[1] + r[2]):
						if c3[0] == "rgnh":
							rg["lo"] = d.decode_u16(c3[1])
							rg["hi"] = d.decode_u16(c3[1] + 2)
							rg["group"] = d.decode_u16(c3[1] + 10)
						elif c3[0] == "wsmp":
							rg["smp"] = _wsmp(d, c3[1])
						elif c3[0] == "wlnk":
							rg["wave"] = d.decode_u32(c3[1] + 8)
						elif c3[0] == "LIST" and d.slice(c3[1], c3[1] + 4).get_string_from_ascii() == "lart":
							rg["art"] = _art(d, c3[1] + 4, c3[1] + c3[2])
					regs.append(rg)
		var key := (0x10000 if bank & 0x80000000 else 0) + ((bank >> 8) & 0x7F) * 128 + (prog & 0x7F)
		ins[key] = {"regs": regs, "art": art}


static func _wsmp(d: PackedByteArray, o: int) -> Dictionary:
	var cb := d.decode_u32(o)
	var w := {"unity": d.decode_u16(o + 4), "fine": d.decode_s16(o + 6), "atten": d.decode_s32(o + 8) / 655360.0,
			"loop": false}
	if d.decode_u32(o + 16) > 0:
		var lo := o + cb
		w["loop"] = true
		w["ls"] = d.decode_u32(lo + 8)
		w["ll"] = d.decode_u32(lo + 12)
	return w


# the articulation's connections DLS 1 knows, in seconds, dB, cents (absent: the format's defaults)
static func _art(d: PackedByteArray, p: int, end: int) -> Dictionary:
	var a := {}
	for c in _chunks(d, p, end):
		if c[0] != "art1":
			continue
		var cb := d.decode_u32(c[1])
		for k in d.decode_u32(c[1] + 4):
			var q: int = c[1] + cb + 12 * k
			var src := d.decode_u16(q)
			var ctl := d.decode_u16(q + 2)
			var dst := d.decode_u16(q + 4)
			var v := d.decode_s32(q + 8) / 65536.0
			a["%x:%x:%x" % [src, ctl, dst]] = v
	return a


static func _tc(v) -> float:                            # time cents -> seconds (the lowest: none)
	return 0.0 if v == null or float(v) <= -32000.0 else pow(2.0, float(v) / 1200.0)


func _stream(wi: int, smp: Dictionary) -> AudioStreamWAV:
	var key := wi * 2 + (1 if smp.get("loop", false) else 0)
	if streams.has(key):
		return streams[key]
	var s: AudioStreamWAV = null
	var cues_t: PackedInt32Array = dls["cues"]
	if wi >= 0 and wi < cues_t.size():
		var d: PackedByteArray = dls["d"]
		var p: int = int(dls["wvpl"]) + cues_t[wi]
		if d.slice(p, p + 4).get_string_from_ascii() == "LIST":
			var rate := 22050
			var bits := 16
			var chn := 1
			var pcm := PackedByteArray()
			for c in _chunks(d, p + 12, p + 8 + d.decode_u32(p + 4)):
				if c[0] == "fmt ":
					chn = d.decode_u16(c[1] + 2)
					rate = d.decode_u32(c[1] + 4)
					bits = d.decode_u16(c[1] + 14)
				elif c[0] == "data":
					pcm = d.slice(c[1], c[1] + c[2])
			if chn == 1 and not pcm.is_empty():
				s = AudioStreamWAV.new()
				s.mix_rate = rate
				if bits == 8:
					for k in pcm.size():
						pcm[k] = (pcm[k] + 128) & 0xFF                 # (unsigned 8 bits -> Godot's signed)
					s.format = AudioStreamWAV.FORMAT_8_BITS
				else:
					s.format = AudioStreamWAV.FORMAT_16_BITS
				s.data = pcm
				if smp.get("loop", false):
					s.loop_mode = AudioStreamWAV.LOOP_FORWARD
					s.loop_begin = int(smp["ls"])
					s.loop_end = int(smp["ls"]) + int(smp["ll"])
	streams[key] = s
	return s


func _wave_smp(wi: int) -> Dictionary:
	var cues_t: PackedInt32Array = dls["cues"]
	if wi < 0 or wi >= cues_t.size():
		return {}
	var d: PackedByteArray = dls["d"]
	var p: int = int(dls["wvpl"]) + cues_t[wi]
	for c in _chunks(d, p + 12, p + 8 + d.decode_u32(p + 4)):
		if c[0] == "wsmp":
			return _wsmp(d, c[1])
	return {}


# ---------------------------------------------------------------- notes
func _instrument(cs: Dictionary, ch: int) -> Dictionary:
	var ins: Dictionary = dls["ins"]
	if ch == 9:
		return ins.get(0x10000 + int(cs["prog"]), ins.get(0x10000, {}))
	return ins.get(int(cs["bank"]) * 128 + int(cs["prog"]), ins.get(int(cs["prog"]), {}))


func _note_on(slot: int, s: Dictionary, ch: int, key: int, vel: int) -> void:
	var cs: Dictionary = s["chans"][ch]
	var specs := _specs_sf2(cs, ch, key, vel) if awe else _specs_dls(cs, ch, key, vel)
	for sp in specs:
		if int(sp["group"]) != 0:                                 # (a drum group: the open hi-hat cut by the closed)
			for v in voices:
				if v["slot"] == slot and v["ch"] == ch and v["group"] == int(sp["group"]) and not v["rel"]:
					_release(v, 0.03)
	for sp in specs:
		var pan := clampf((int(cs["pan"]) - 64) / 64.0 + float(sp["pan"]), -1.0, 1.0)
		var bus := "CoopMusicP%d" % int(roundf((pan + 1.0) * 0.5 * (PANS - 1)))
		var v: Dictionary = sp.duplicate()
		v.merge({"slot": slot, "ch": ch, "key": key, "vel": vel, "t": 0.0, "rel": false, "held": false, "rel_db": 0.0,
				"env": -96.0 if float(sp["atk"]) > 0.0 or float(sp["dly"]) > 0.0 else 0.0}, true)
		v.erase("stream")
		var db := _gain(v, s)
		var pitch := _pitch(v, cs)
		if voices.size() >= POLY:                                  # (all voices taken: the oldest released one, or the oldest)
			var victim: Dictionary = voices[0]
			for o in voices:
				if o["rel"]:
					victim = o
					break
			pb.stop_stream(victim["id"])
			voices.erase(victim)
		v["id"] = pb.play_stream(sp["stream"], 0.0, db, pitch, AudioServer.PLAYBACK_TYPE_DEFAULT, bus)
		voices.append(v)
	notes_n += 1
	if log_to and notes_n % 200 == 1:
		_log("notes %d (slot %d ch %d prog %d key %d vel %d, %d sounding, %s)" % [notes_n, slot, ch, cs["prog"], key, vel,
				voices.size(), "AWE32" if awe else "GS"])


# what a note plays, from either bank: its sample (stream), pitch from it (base, cents), level (atten, dB), pan (-1..1),
# volume envelope (dly, atk, hold, dcy, sus_db, rel_t: seconds, dB), vibrato LFO (lfo_hz, lfo_delay, vib, vib_mod:
# cents), modulation LFO (mlfo_hz, mlfo_delay, mvib cents, trem dB), pitch envelope (eg2 cents, eg2_atk, eg2_dcy,
# eg2_sus), exclusive group
static func _spec() -> Dictionary:
	return {"base": 0.0, "atten": 0.0, "pan": 0.0, "dly": 0.0, "atk": 0.0, "hold": 0.0, "dcy": 0.001, "sus_db": 0.0,
			"rel_t": 0.02, "lfo_hz": 5.0, "lfo_delay": 0.0, "vib": 0.0, "vib_mod": 0.0, "mlfo_hz": 5.0, "mlfo_delay": 0.0,
			"mvib": 0.0, "trem": 0.0, "eg2": 0.0, "eg2_atk": 0.0, "eg2_dcy": 0.0, "eg2_sus": 1.0, "group": 0}


func _specs_dls(cs: Dictionary, ch: int, key: int, vel: int) -> Array:
	var inst := _instrument(cs, ch)
	if inst.is_empty():
		return []
	var rg: Dictionary = {}
	for r in inst["regs"]:
		if key >= int(r["lo"]) and key <= int(r["hi"]):
			rg = r
			break
	if rg.is_empty():
		return []
	var smp: Dictionary = rg["smp"] if not (rg["smp"] as Dictionary).is_empty() else _wave_smp(int(rg["wave"]))
	if smp.is_empty():
		return []
	var stream := _stream(int(rg["wave"]), smp)
	if stream == null:
		return []
	var art: Dictionary = rg.get("art", inst["art"])
	# envelope 1 (volume): attack (velocity scales it), decay (the key scales it) to the sustain, release
	var atk := _tc(art.get("0:0:206"))
	if art.has("2:0:206"):
		atk = _tc(float(art.get("0:0:206", -32768.0)) + float(art["2:0:206"]) * vel / 128.0)
	var dcy := _tc(art.get("0:0:207"))
	if art.has("3:0:207"):
		dcy = _tc(float(art.get("0:0:207", -32768.0)) + float(art["3:0:207"]) * key / 128.0)
	var sus := clampf(float(art.get("0:0:20a", 1000.0)) / 1000.0, 0.0, 1.0)
	var sp := _spec()
	sp.merge({"stream": stream, "group": int(rg["group"]), "atk": atk, "dcy": maxf(dcy, 0.001), "sus_db": -96.0 * (1.0 - sus),
			"rel_t": maxf(_tc(art.get("0:0:209")), 0.02), "atten": float(smp["atten"]), "pan": float(art.get("0:0:4", 0.0)) / 500.0,
			"base": float(key - int(smp["unity"])) * 100.0 + float(smp["fine"]),
			"lfo_hz": 440.0 * pow(2.0, (float(art.get("0:0:104", -851.0)) - 6900.0) / 1200.0),
			"lfo_delay": _tc(art.get("0:0:105")), "vib": float(art.get("1:0:3", 0.0)),
			"vib_mod": float(art.get("1:81:3", 0.0)), "trem": float(art.get("1:0:1", 0.0)),
			"eg2": float(art.get("5:0:3", 0.0)), "eg2_atk": _tc(art.get("0:0:30a")), "eg2_dcy": _tc(art.get("0:0:30b")),
			"eg2_sus": clampf(float(art.get("0:0:30e", 1000.0)) / 1000.0, 0.0, 1.0)}, true)
	return [sp]


# ---------------------------------------------------------------- TN+'s AWE32 bank (SoundFont 2)
static func sf2_path() -> String:
	var env := OS.get_environment("TN_MUSIC_SF2")
	if env != "":
		return env if FileAccess.file_exists(env) else ""
	var comp := ProjectSettings.globalize_path("res://").trim_suffix("/").get_base_dir()   # the launcher's components
	for d in ["tnplus_coop", "tnplus"]:
		var f := comp.path_join(d).path_join("TNPlus_awe32.sf2")
		if FileAccess.file_exists(f):
			return f
	return ""


func _sf2_open() -> bool:
	if sf2_tried:
		return not sf2.is_empty()
	sf2_tried = true
	var path := sf2_path()
	if path == "":
		_log("AWE32 bank: no TNPlus_awe32.sf2 here, the GS set plays")
		return false
	var t0 := Time.get_ticks_usec()
	var d := FileAccess.get_file_as_bytes(path)
	if d.size() < 12 or d.slice(0, 4).get_string_from_ascii() != "RIFF" or d.slice(8, 12).get_string_from_ascii() != "sfbk":
		return false
	var c := {}
	var smpl := -1
	for top in _chunks(d, 12, d.size()):
		if top[0] != "LIST":
			continue
		for c2 in _chunks(d, top[1] + 4, top[1] + top[2]):
			if c2[0] == "smpl":
				smpl = c2[1]
			else:
				c[c2[0]] = [c2[1], c2[2]]
	for k in ["phdr", "pbag", "pgen", "inst", "ibag", "igen", "shdr"]:
		if not c.has(k):
			return false
	if smpl < 0:
		return false
	var shdr := []
	for i in int(c["shdr"][1]) / 46:
		var o: int = c["shdr"][0] + 46 * i
		shdr.append({"start": d.decode_u32(o + 20), "end": d.decode_u32(o + 24), "ls": d.decode_u32(o + 28),
				"le": d.decode_u32(o + 32), "rate": d.decode_u32(o + 36), "root": d[o + 40], "corr": d.decode_s8(o + 41)})
	var insts := []
	var n_inst: int = int(c["inst"][1]) / 22
	for i in n_inst - 1:
		var b0 := d.decode_u16(c["inst"][0] + 22 * i + 20)
		var b1 := d.decode_u16(c["inst"][0] + 22 * (i + 1) + 20)
		insts.append(_sf2_zones(d, c["ibag"][0], c["igen"][0], b0, b1, 53))
	var presets := {}
	var n_ph: int = int(c["phdr"][1]) / 38
	for i in n_ph - 1:
		var o: int = c["phdr"][0] + 38 * i
		var b0 := d.decode_u16(o + 24)
		var b1 := d.decode_u16(o + 38 + 24)
		var key := d.decode_u16(o + 22) * 128 + d.decode_u16(o + 20)
		if not presets.has(key):
			presets[key] = _sf2_zones(d, c["pbag"][0], c["pgen"][0], b0, b1, 41)
		if i == 0:
			presets[-1] = presets[key]                             # (a program the bank lacks: its first, as the card)
	sf2 = {"d": d, "smpl": smpl, "shdr": shdr, "inst": insts, "presets": presets, "path": path}
	_log("AWE32 bank: %s, %d presets, %d instruments, %d samples, %.0f ms" % [path, presets.size() - 1, insts.size(),
			shdr.size(), (Time.get_ticks_usec() - t0) / 1000.0])
	return true


# the zones of an instrument (last = 53, its sample) or a preset (41, its instrument): [global gens, [zone gens...]]
static func _sf2_zones(d: PackedByteArray, bag: int, gen: int, b0: int, b1: int, last: int) -> Array:
	var glob := {}
	var zones := []
	for b in range(b0, b1):
		var g0 := d.decode_u16(bag + 4 * b)
		var g1 := d.decode_u16(bag + 4 * (b + 1))
		var z := {}
		for g in range(g0, g1):
			z[d.decode_u16(gen + 4 * g)] = d.decode_s16(gen + 4 * g + 2)
		if z.has(last):
			zones.append(z)
		elif b == b0:
			glob = z
	return [glob, zones]


static func _in_range(z: Dictionary, op: int, x: int) -> bool:
	if not z.has(op):
		return true
	var r: int = int(z[op]) & 0xFFFF
	return x >= (r & 0xFF) and x <= (r >> 8)


func _specs_sf2(cs: Dictionary, ch: int, key: int, vel: int) -> Array:
	var presets: Dictionary = sf2["presets"]
	var pr: Array = []
	if ch == 9:
		pr = presets.get(128 * 128 + int(cs["prog"]), presets.get(128 * 128, []))
	else:
		pr = presets.get(int(cs["bank"]) * 128 + int(cs["prog"]), presets.get(int(cs["prog"]), presets.get(-1, [])))
	var out := []
	if pr.is_empty():
		return out
	for pz in pr[1]:
		var pzone: Dictionary = (pr[0] as Dictionary).merged(pz, true)
		if not _in_range(pzone, 43, key) or not _in_range(pzone, 44, vel):
			continue
		var ii := int(pzone[41])
		if ii < 0 or ii >= sf2["inst"].size():
			continue
		var inst: Array = sf2["inst"][ii]
		for iz in inst[1]:
			var g: Dictionary = (inst[0] as Dictionary).merged(iz, true)
			if not _in_range(g, 43, key) or not _in_range(g, 44, vel):
				continue
			for op in pzone:                                           # (a preset's generators add to the instrument's)
				if op not in [41, 43, 44]:
					g[op] = int(g.get(op, _sf2_default(op))) + int(pzone[op])
			var sp := _sf2_spec(g, key)
			if not sp.is_empty():
				out.append(sp)
			if out.size() >= 4:
				return out
	return out


static func _sf2_default(op: int) -> int:
	match op:
		8:
			return 13500
		21, 23, 25, 26, 27, 28, 30, 33, 34, 35, 36, 38:
			return -12000
		56:
			return 100
		58:
			return -1
	return 0


func _gv(g: Dictionary, op: int) -> int:
	return int(g.get(op, _sf2_default(op)))


func _tcg(g: Dictionary, op: int, add := 0) -> float:                  # time cents (the lowest: none)
	return pow(2.0, (_gv(g, op) + add) / 1200.0) if _gv(g, op) > -12000 else 0.0


func _sf2_spec(g: Dictionary, key: int) -> Dictionary:
	var si := _gv(g, 53)
	if si < 0 or si >= sf2["shdr"].size():
		return {}
	var h: Dictionary = sf2["shdr"][si]
	var start: int = int(h["start"]) + _gv(g, 0) + 32768 * _gv(g, 4)
	var end: int = int(h["end"]) + _gv(g, 1) + 32768 * _gv(g, 12)
	var ls: int = int(h["ls"]) + _gv(g, 2) + 32768 * _gv(g, 45)
	var le: int = int(h["le"]) + _gv(g, 3) + 32768 * _gv(g, 50)
	var loop := (_gv(g, 54) & 1) != 0 and le > ls
	if end <= start:
		return {}
	var skey := "sf:%d:%d:%d:%d:%d" % [start, end, ls, le, 1 if loop else 0]
	var stream: AudioStreamWAV = streams.get(skey)
	if stream == null:
		var d: PackedByteArray = sf2["d"]
		var o: int = sf2["smpl"]
		stream = AudioStreamWAV.new()
		stream.format = AudioStreamWAV.FORMAT_16_BITS
		stream.mix_rate = maxi(int(h["rate"]), 1000)
		stream.data = d.slice(o + 2 * start, o + 2 * end)
		if loop:
			stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
			stream.loop_begin = clampi(ls - start, 0, end - start - 1)
			stream.loop_end = clampi(le - start, 1, end - start)
		streams[skey] = stream
	var root: int = _gv(g, 58) if _gv(g, 58) >= 0 else int(h["root"])
	var sp := _spec()
	sp.merge({"stream": stream, "group": _gv(g, 57),
			"base": float(key - root) * _gv(g, 56) + _gv(g, 51) * 100.0 + _gv(g, 52) + int(h["corr"]),
			"atten": -0.4 * _gv(g, 48) / 10.0,                     # (FluidSynth's attenuation, as the EMU8000's)
			"pan": clampf(_gv(g, 17) / 500.0, -1.0, 1.0),
			"dly": _tcg(g, 33), "atk": _tcg(g, 34), "hold": _tcg(g, 35, _gv(g, 39) * (60 - key)),
			"dcy": maxf(pow(2.0, (_gv(g, 36) + _gv(g, 40) * (60 - key)) / 1200.0), 0.001),
			"sus_db": -clampf(_gv(g, 37), 0, 1440) / 10.0, "rel_t": maxf(_tcg(g, 38), 0.02),
			"lfo_hz": 8.176 * pow(2.0, _gv(g, 24) / 1200.0), "lfo_delay": _tcg(g, 23), "vib": float(_gv(g, 6)),
			"vib_mod": 50.0, "mlfo_hz": 8.176 * pow(2.0, _gv(g, 22) / 1200.0), "mlfo_delay": _tcg(g, 21),
			"mvib": float(_gv(g, 5)), "trem": -_gv(g, 13) / 10.0,
			"eg2": float(_gv(g, 7)), "eg2_atk": _tcg(g, 26), "eg2_dcy": _tcg(g, 28),
			"eg2_sus": 1.0 - clampf(_gv(g, 29), 0, 1000) / 1000.0}, true)
	return sp


# a note's level: velocity, the channel's volume x the sequence's x the game's (as Miles sends it), expression, the
# sample's own attenuation, its envelope (40 log10 of each 0-127 value), tremolo
func _gain(v: Dictionary, s: Dictionary) -> float:
	var cs: Dictionary = s["chans"][v["ch"]]
	var vol := float(cs["vol"]) * float(s["vol_now"]) * float(master) / (127.0 * 127.0)
	var g := _cb(v["vel"]) + _cb(vol) + _cb(cs["expr"]) + float(v["atten"]) + float(v["env"])
	var t: float = v["t"]
	if float(v["trem"]) != 0.0 and t > float(v["mlfo_delay"]):
		g += float(v["trem"]) * sin(TAU * float(v["mlfo_hz"]) * (t - float(v["mlfo_delay"])))
	return g


static func _cb(x) -> float:
	return -96.0 if float(x) < 0.5 else 40.0 * log(float(x) / 127.0) / log(10.0)


func _pitch(v: Dictionary, cs: Dictionary) -> float:
	var cents := float(v["base"]) + float(cs["bend"]) * 100.0
	var t: float = v["t"]
	var vib := float(v["vib"]) + float(v["vib_mod"]) * int(cs["mod"]) / 127.0
	if vib != 0.0 and t > float(v["lfo_delay"]):
		cents += vib * sin(TAU * float(v["lfo_hz"]) * (t - float(v["lfo_delay"])))
	if float(v["mvib"]) != 0.0 and t > float(v["mlfo_delay"]):
		cents += float(v["mvib"]) * sin(TAU * float(v["mlfo_hz"]) * (t - float(v["mlfo_delay"])))
	if float(v["eg2"]) != 0.0:
		var e := 1.0
		if t < float(v["eg2_atk"]):
			e = t / float(v["eg2_atk"])
		elif float(v["eg2_dcy"]) > 0.0:
			e = maxf(float(v["eg2_sus"]), 1.0 - (t - float(v["eg2_atk"])) / float(v["eg2_dcy"]))
		else:
			e = float(v["eg2_sus"])
		cents += float(v["eg2"]) * e
	return pow(2.0, cents / 1200.0)


func _note_off(slot: int, ch: int, key: int) -> void:
	var s: Dictionary = slots.get(slot, {})
	var sus: bool = not s.is_empty() and s["chans"][ch]["sus"]
	for v in voices:
		if v["slot"] == slot and v["ch"] == ch and v["key"] == key and not v["rel"] and not v["held"]:
			if sus:
				v["held"] = true
			else:
				_release(v, float(v["rel_t"]))


func _release_held(slot: int, ch: int) -> void:
	for v in voices:
		if v["slot"] == slot and v["ch"] == ch and v["held"] and not v["rel"]:
			_release(v, float(v["rel_t"]))


func _release(v: Dictionary, t: float) -> void:
	v["rel"] = true
	v["rel_db"] = float(v["env"])
	v["rel_rate"] = 96.0 / maxf(t, 0.01)


func _notes_off_ch(slot: int, ch: int) -> void:
	for v in voices:
		if v["slot"] == slot and v["ch"] == ch and not v["rel"]:
			_release(v, float(v["rel_t"]))


func _notes_off(slot: int, now: bool) -> void:
	for v in voices.duplicate():
		if v["slot"] == slot:
			if now:
				pb.stop_stream(v["id"])
				voices.erase(v)
			elif not v["rel"]:
				_release(v, float(v["rel_t"]))
	if slots.has(slot):
		(slots[slot]["offs"] as Array).clear()


func _retune(slot: int, ch: int) -> void:
	var s: Dictionary = slots.get(slot, {})
	if s.is_empty():
		return
	var cs: Dictionary = s["chans"][ch]
	for v in voices:
		if v["slot"] == slot and v["ch"] == ch:
			pb.set_stream_pitch_scale(v["id"], _pitch(v, cs))


# the envelopes, once a frame; a voice done (its release down to silence, or its sample ended) freed
func _voices(delta: float) -> void:
	var k := 0
	while k < voices.size():
		var v: Dictionary = voices[k]
		v["t"] = float(v["t"]) + delta
		var t: float = v["t"]
		var te: float = t - float(v["dly"])
		if v["rel"]:
			v["env"] = float(v["env"]) - float(v["rel_rate"]) * delta
		elif te < 0.0:
			v["env"] = -96.0
		elif te < float(v["atk"]):
			v["env"] = maxf(-96.0, 20.0 * log(maxf(te / float(v["atk"]), 0.0001)) / log(10.0))
		elif te < float(v["atk"]) + float(v["hold"]):
			v["env"] = 0.0
		else:
			v["env"] = maxf(float(v["sus_db"]), -96.0 * (te - float(v["atk"]) - float(v["hold"])) / float(v["dcy"]))
		var s: Dictionary = slots.get(v["slot"], {})
		if s.is_empty() and not v["rel"]:
			_release(v, 0.3)                                       # (its sequence ended: faded out)
		var ended := t > 0.2 and not pb.is_stream_playing(v["id"])  # (a sample played once, done)
		if float(v["env"]) <= -95.0 or ended:
			pb.stop_stream(v["id"])
			voices.remove_at(k)
			continue
		if not s.is_empty():                                       # (the level but its envelope, kept for after)
			v["g0"] = _gain(v, s) - float(v["env"])
		pb.set_stream_volume(v["id"], maxf(float(v.get("g0", -20.0)) + float(v["env"]), -96.0))
		if not s.is_empty() and (float(v["vib"]) != 0.0 or float(v["vib_mod"]) != 0.0 or float(v["eg2"]) != 0.0
				or float(v["mvib"]) != 0.0):
			pb.set_stream_pitch_scale(v["id"], _pitch(v, s["chans"][v["ch"]]))
		k += 1
