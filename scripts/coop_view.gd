# Online coop view (COOP_VERSION 3), the guest's side: the host's keyframes (VKF), deltas (VDL, or VDP: in parts)
# and decor messages (VDC) turned back into the viewer's full live packet (camera, 32 bytes per entity, 200 bytes per posed suit), the
# packet the local coop sends to port 47831, so viewer.gd reads it as before. Formats: live/coop_view.py (its Decoder
# is this file's twin, checked byte for byte by live/test_coop_view.py).
extends RefCounted

const POS_STEP := 1.0 / 64.0
const OX := 256.0                    # POS_ORIGIN (doubles: a Vector3 would round them to float32)
const OY := 256.0
const OZ := 0.0
const JOINT_STEP := 1.0 / 2048.0
const ACTIVE := 1
const POS_F32 := 2
const HEAD_F32 := 4
const RAW := 8
const JOINT_F32 := 1

var decor := {}                      # index -> 32-byte entity, as in the view
var decor_seq := 0
var decor_ok := false
var kf_seq := -1
var kf_ents := {}
var kf_joints := {}                  # index -> 200-byte joint block, as in the view
var seen_any := false
var part_id := -1                    # VDP: the delta in parts being rebuilt
var parts := {}


# true: our decor table is not the host's (joined late): ask for it again ('R')
func waiting_decor() -> bool:
	return seen_any and not decor_ok


# a VKF / VDL / VDP / VDC packet -> the full view packet, or empty
func feed(msg: PackedByteArray) -> PackedByteArray:
	var none := PackedByteArray()
	if msg.size() < 4:
		return none
	var tag := msg.slice(0, 3).get_string_from_ascii()
	if tag == "VDP":
		if msg.size() < 8:
			return none
		if msg.decode_u16(3) != part_id:                    # a new delta: the parts of the last one are dropped
			part_id = msg.decode_u16(3)
			parts = {}
		parts[int(msg[5])] = msg.slice(7)
		var n := int(msg[6])
		if parts.size() < n:
			return none
		msg = "VDL".to_ascii_buffer()
		for k in n:
			msg.append_array(parts.get(k, PackedByteArray()))
		parts = {}
		tag = "VDL"
	var b := msg.slice(3).decompress_dynamic(-1, FileAccess.COMPRESSION_DEFLATE)
	if b.size() < 2:
		return none
	seen_any = true
	if tag == "VDC":
		var seq := b.decode_u32(0)
		var reset := b[4] != 0
		if not reset and not (decor_ok and seq == decor_seq + 1):
			decor_ok = false                                # one missed: wait for a full table
			return none
		if reset:
			decor = {}
		var o := _records(b, 5, decor, false)
		for i in _gone(b, o):
			decor.erase(i)
		decor_seq = seq
		decor_ok = true
		return none
	if tag == "VKF":
		kf_seq = b.decode_u16(0)
		if b.decode_u32(2) != decor_seq:
			decor_ok = false
		kf_ents = {}
		kf_joints = {}
		var o := _records(b, 38, kf_ents, false)
		o = _records(b, o, kf_joints, true)
		if not decor_ok:
			return none
		return _build(b.slice(6, 38), kf_ents, kf_joints, b.slice(o))
	if tag == "VDL":
		if b.decode_u16(0) != kf_seq or not decor_ok:
			return none
		var ents := kf_ents.duplicate()
		var joints := kf_joints.duplicate()
		var o := _records(b, 34, ents, false)
		var gone := _gone(b, o)
		for i in gone:
			ents.erase(i)
		o += 2 + 2 * gone.size()
		o = _records(b, o, joints, true)
		var jgone := _gone(b, o)
		for i in jgone:
			joints.erase(i)
		return _build(b.slice(2, 34), ents, joints, b.slice(o + 2 + 2 * jgone.size()))
	return none


func _records(b: PackedByteArray, o: int, into: Dictionary, joint: bool) -> int:
	var n := b.decode_u16(o)
	o += 2
	for k in n:
		var i := b.decode_u16(o)
		var f := b[o + 2]
		o += 3
		var r := PackedByteArray()
		r.resize(4)
		r.encode_s32(0, i)
		if joint:
			if f & JOINT_F32:
				r.append_array(b.slice(o, o + 196))
				o += 196
			else:
				r.append_array(b.slice(o, o + 4))           # feet height
				r.resize(200)
				for q in 48:
					r.encode_float(8 + 4 * q, b.decode_s16(o + 4 + 2 * q) * JOINT_STEP)
				o += 100
		elif f & RAW:
			r.append_array(b.slice(o, o + 28))
			o += 28
		else:
			r.resize(32)
			r.encode_s32(4, b[o])
			r.encode_s32(8, b[o + 1])
			r.encode_s32(12, f & ACTIVE)
			o += 2
			if f & POS_F32:
				for q in 12:
					r[16 + q] = b[o + q]
				o += 12
			else:
				r.encode_float(16, OX + b.decode_s16(o) * POS_STEP)
				r.encode_float(20, OY + b.decode_s16(o + 2) * POS_STEP)
				r.encode_float(24, OZ + b.decode_s16(o + 4) * POS_STEP)
				o += 6
			if f & HEAD_F32:
				for q in 4:
					r[28 + q] = b[o + q]
				o += 4
			else:
				r.encode_float(28, b.decode_u16(o) / 65536.0 * 2.0 * PI)   # the game's angle word, as the host computes it
				o += 2
		into[i] = r
	return o


func _gone(b: PackedByteArray, o: int) -> Array[int]:
	var out: Array[int] = []
	for k in b.decode_u16(o):
		out.append(b.decode_u16(o + 2 + 2 * k))
	return out


# camera, then the decor and the keyframe / delta entities (these win), the joints, indices in order, and the
# articulated parts' angles (arts: u16 n, then u16 index, u16, u16; empty from an older host)
func _build(cam: PackedByteArray, ents: Dictionary, joints: Dictionary, arts := PackedByteArray()) -> PackedByteArray:
	var all := decor.duplicate()
	all.merge(ents, true)
	var keys := all.keys()
	keys.sort()
	var pk := cam.duplicate()
	pk.encode_s32(24, keys.size())
	for i in keys:
		pk.append_array(all[i])
	var jk := joints.keys()
	jk.sort()
	var n := PackedByteArray()
	n.resize(4)
	n.encode_s32(0, jk.size())
	pk.append_array(n)
	for i in jk:
		pk.append_array(joints[i])
	var na := arts.decode_u16(0) if arts.size() >= 2 else 0
	if na > 0 and arts.size() >= 2 + 6 * na:
		var a := PackedByteArray()
		a.resize(4 + 8 * na)
		a.encode_s32(0, na)
		for k in na:
			a.encode_s32(4 + 8 * k, arts.decode_u16(2 + 6 * k))
			a.encode_u16(8 + 8 * k, arts.decode_u16(4 + 6 * k))
			a.encode_u16(10 + 8 * k, arts.decode_u16(6 + 6 * k))
		pk.append_array(a)
	return pk
