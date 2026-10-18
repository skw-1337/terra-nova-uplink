# Online coop view (COOP_VERSION 3): the host's view packet (the viewer's live format: camera, then 32 bytes per
# entity, then 200 bytes per posed suit) turned into small messages for Steam, and back. scripts/coop_view.gd is the
# guest's decoder (same formats); Decoder here is its twin, for the tests (live/test_coop_view.py).
# Messages: a 3-byte tag, then zlib:
#   VKF keyframe (reliable, every KEY_EVERY s): u16 seq, u32 decor seq, camera (32 bytes as in the view), u16 n,
#       entity records, u16 nj, joint records. Holds every entity except the static decor.
#   VDL delta (unreliable): u16 keyframe seq, camera, u16 n, entity records that
#       differ from that keyframe (or are new), u16 n, indices gone since it, then the same for the joints. Always
#       against the LAST KEYFRAME, never the previous view: a lost delta breaks nothing.
#   VDP a delta too big for one unreliable Steam packet (MAX_PACKET), in parts: u16 id, u8 part, u8 parts, then that
#       part of the VDL's zlib data (no zlib of its own). The guest rebuilds the view once it has every part; a view
#       with a part lost is skipped.
#   VDC decor (reliable): u32 seq, u8 reset (1 = clear the table first), u16 n, entity records, u16 n, indices gone.
#       Decor = class 0 / 4 entities unchanged for STILL s: sent once, then only when they change.
# Entity record: u16 index, u8 flags, then (RAW) the view's 28 bytes, or u8 class, u8 type, position (int16 x, y, z
# in POS_STEP around POS_ORIGIN, or POS_F32: 3 float32), heading (u16 = the game's own angle word, or HEAD_F32:
# float32: dust and armour debris carry a number there). Joint record: u16 index, u8 flags, float32 feet height,
# 48 int16 in JOINT_STEP (or JOINT_F32: 48 float32): the 16 joints in the suit's frame, as in the view.
# A guest whose decor table does not match the keyframe's decor seq (it joined late) sends 'R': full decor again.
import math, struct, zlib

POS_STEP = 1 / 64                  # entity positions: +-512 units around the map centre, 1/64 unit steps
POS_ORIGIN = (256.0, 256.0, 0.0)
JOINT_STEP = 1 / 2048              # joints (suit frame, ground at 0): +-16 units, 1/2048 unit steps
KEY_EVERY = 1.0                    # s between keyframes
STILL = 0.5                        # s a class 0 / 4 entity stays unchanged before it goes to the decor
DECOR = (0, 4)
ACTIVE, POS_F32, HEAD_F32, RAW = 1, 2, 4, 8
JOINT_F32 = 1
LEVEL = 6
MAX_PACKET = 1200                  # Steam P2P: the biggest unreliable packet


def parse(view):
    """The view packet -> (camera 32 bytes, {index: 28 bytes}, {index: 196 bytes}), in the packet's order."""
    n = struct.unpack_from('<i', view, 24)[0]
    ents = {}
    for k in range(n):
        o = 32 + 32 * k
        ents[struct.unpack_from('<i', view, o)[0]] = view[o + 4:o + 32]
    jo = 32 + 32 * n
    joints = {}
    for k in range(struct.unpack_from('<i', view, jo)[0] if len(view) >= jo + 4 else 0):
        o = jo + 4 + 200 * k
        joints[struct.unpack_from('<i', view, o)[0]] = view[o + 4:o + 200]
    return view[:32], ents, joints


def build(cam, ents, joints):
    """parse() backwards, indices in order (the host sends them in table order)."""
    return (cam[:24] + struct.pack('<i', len(ents)) + cam[28:32] +
            b''.join(struct.pack('<i', i) + ents[i] for i in sorted(ents)) +
            struct.pack('<i', len(joints)) + b''.join(struct.pack('<i', i) + joints[i] for i in sorted(joints)))


def f32(v):
    return struct.pack('<f', v)


def q_ent(i, rec):
    cls, typ, act = struct.unpack_from('<3i', rec)
    x, y, z, h = struct.unpack_from('<4f', rec, 12)
    if not (0 <= cls < 256 and 0 <= typ < 256 and act in (0, 1)) or not all(map(math.isfinite, (x, y, z, h))):
        return struct.pack('<HB', i, RAW) + rec
    flags = ACTIVE if act else 0
    q = [round((v - c) / POS_STEP) for v, c in zip((x, y, z), POS_ORIGIN)]
    if all(-32768 <= v < 32768 for v in q):
        pos = struct.pack('<3h', *q)
    else:
        flags |= POS_F32
        pos = rec[12:24]
    u = round(h / (2 * math.pi) * 65536)
    if 0 <= u < 65536 and f32(u / 65536 * 2 * math.pi) == rec[24:28]:
        head = struct.pack('<H', u)
    else:
        flags |= HEAD_F32
        head = rec[24:28]
    return struct.pack('<HBBB', i, flags, cls, typ) + pos + head


def q_joint(i, rec):
    v = struct.unpack_from('<48f', rec, 4)
    q = [round(c / JOINT_STEP) if math.isfinite(c) else 1 << 20 for c in v]
    if all(-32768 <= c < 32768 for c in q):
        return struct.pack('<HB', i, 0) + rec[:4] + struct.pack('<48h', *q)
    return struct.pack('<HB', i, JOINT_F32) + rec


def d_ent(b, o):
    """An entity record at b[o:] -> (index, the view's 28 bytes, next offset)."""
    i, flags = struct.unpack_from('<HB', b, o)
    o += 3
    if flags & RAW:
        return i, bytes(b[o:o + 28]), o + 28
    cls, typ = b[o], b[o + 1]
    o += 2
    if flags & POS_F32:
        pos = bytes(b[o:o + 12])
        o += 12
    else:
        pos = b''.join(f32(c + q * POS_STEP) for c, q in zip(POS_ORIGIN, struct.unpack_from('<3h', b, o)))
        o += 6
    if flags & HEAD_F32:
        head = bytes(b[o:o + 4])
        o += 4
    else:
        head = f32(struct.unpack_from('<H', b, o)[0] / 65536 * 2 * math.pi)
        o += 2
    return i, struct.pack('<3i', cls, typ, flags & ACTIVE) + pos + head, o


def d_joint(b, o):
    i, flags = struct.unpack_from('<HB', b, o)
    o += 3
    if flags & JOINT_F32:
        return i, bytes(b[o:o + 196]), o + 196
    return i, bytes(b[o:o + 4]) + struct.pack('<48f', *(q * JOINT_STEP for q in struct.unpack_from('<48h', b, o + 4))), o + 100


def _list(recs):
    return struct.pack('<H', len(recs)) + b''.join(recs)


def _gone(idx):
    return struct.pack('<H%dH' % len(idx), len(idx), *sorted(idx))


class Encoder:
    """Host side: encode(view, t) -> the messages to send for this view (decor first, then the keyframe or delta)."""

    def __init__(self, key_every=KEY_EVERY):
        self.key_every = key_every
        self.decor = {}                # index -> record, as the guest has it
        self.seen = {}                 # class 0 / 4 index -> [record, unchanged since]
        self.decor_seq = 0
        self.reset = True              # the first decor message clears the guest's table (the bridge restarted)
        self.kf = None                 # (seq, t, {index: record}, {index: joint record})
        self.kf_seq = 0
        self.part_id = 0

    def resync(self):                  # 'R' from the guest: full decor, then a keyframe
        self.reset = True

    def encode(self, view, t):
        cam, ents, joints = parse(view)
        recs = {i: q_ent(i, r) for i, r in ents.items() if 0 <= i < 65536}
        jrecs = {i: q_joint(i, r) for i, r in joints.items() if 0 <= i < 65536}
        decor = {}
        for i, r in recs.items():
            if struct.unpack_from('<i', ents[i])[0] not in DECOR:
                continue
            s = self.seen.get(i)
            if s is None or s[0] != r:
                self.seen[i] = s = [r, t]
            if t - s[1] >= STILL:
                decor[i] = r
        for i in [i for i in self.seen if i not in recs or struct.unpack_from('<i', ents[i])[0] not in DECOR]:
            del self.seen[i]
        out = []
        if self.reset:
            self.decor_seq += 1
            out.append(b'VDC' + zlib.compress(struct.pack('<IB', self.decor_seq, 1) + _list(list(decor.values())) +
                                              _gone([]), LEVEL))
        else:
            up = [r for i, r in decor.items() if self.decor.get(i) != r]
            gone = [i for i in self.decor if i not in decor]
            if up or gone:
                self.decor_seq += 1
                out.append(b'VDC' + zlib.compress(struct.pack('<IB', self.decor_seq, 0) + _list(up) + _gone(gone), LEVEL))
        self.decor = decor
        dyn = {i: r for i, r in recs.items() if i not in decor}
        if self.reset or self.kf is None or t - self.kf[1] >= self.key_every:
            self.kf_seq = (self.kf_seq + 1) & 0xffff
            self.kf = (self.kf_seq, t, dyn, jrecs)
            out.append(b'VKF' + zlib.compress(struct.pack('<HI', self.kf_seq, self.decor_seq) + cam +
                                              _list([dyn[i] for i in sorted(dyn)]) +
                                              _list([jrecs[i] for i in sorted(jrecs)]), LEVEL))
        else:
            seq, _, kd, kj = self.kf
            z = zlib.compress(
                struct.pack('<H', seq) + cam +
                _list([r for i, r in sorted(dyn.items()) if kd.get(i) != r]) + _gone([i for i in kd if i not in dyn]) +
                _list([r for i, r in sorted(jrecs.items()) if kj.get(i) != r]) + _gone([i for i in kj if i not in jrecs]),
                LEVEL)
            if 3 + len(z) <= MAX_PACKET:
                out.append(b'VDL' + z)
            else:
                self.part_id = (self.part_id + 1) & 0xffff
                step = MAX_PACKET - 7
                n = (len(z) + step - 1) // step
                out += [b'VDP' + struct.pack('<HBB', self.part_id, k, n) + z[k * step:(k + 1) * step] for k in range(n)]
        self.reset = False
        return out


class Decoder:
    """Guest side (the twin of scripts/coop_view.gd): feed(message) -> the full view packet, or None."""

    def __init__(self):
        self.decor, self.decor_seq, self.decor_ok = {}, 0, False
        self.kf = None                 # (seq, {index: 28 bytes}, {index: 196 bytes})
        self.seen_any = False
        self.part_id, self.parts = -1, {}

    def waiting_decor(self):           # True: ask the host for the decor again ('R')
        return self.seen_any and not self.decor_ok

    def feed(self, msg):
        tag = msg[:3]
        if tag == b'VDP':
            pid, k, n = struct.unpack_from('<HBB', msg, 3)
            if pid != self.part_id:    # a new delta: the parts of the last one are dropped
                self.part_id, self.parts = pid, {}
            self.parts[k] = msg[7:]
            if len(self.parts) < n:
                return None
            msg, self.parts = b'VDL' + b''.join(self.parts.get(j, b'') for j in range(n)), {}
            tag = b'VDL'
        b = zlib.decompress(msg[3:])
        self.seen_any = True
        if tag == b'VDC':
            seq, reset = struct.unpack_from('<IB', b)
            if not reset and not (self.decor_ok and seq == self.decor_seq + 1):
                self.decor_ok = False  # one missed (joined late): wait for a full table
                return None
            if reset:
                self.decor = {}
            o = self._records(b, 5, self.decor, d_ent)
            for i in self._gone(b, o)[0]:
                self.decor.pop(i, None)
            self.decor_seq, self.decor_ok = seq, True
            return None
        if tag == b'VKF':
            seq, dseq = struct.unpack_from('<HI', b)
            if dseq != self.decor_seq:
                self.decor_ok = False
            cam, ents, joints = b[6:38], {}, {}
            o = self._records(b, 38, ents, d_ent)
            self._records(b, o, joints, d_joint)
            self.kf = (seq, ents, joints)
            return build(cam, {**self.decor, **ents}, joints) if self.decor_ok else None
        if tag == b'VDL':
            seq = struct.unpack_from('<H', b)[0]
            if self.kf is None or self.kf[0] != seq or not self.decor_ok:
                return None
            cam, ents, joints = b[2:34], dict(self.kf[1]), dict(self.kf[2])
            o = self._records(b, 34, ents, d_ent)
            gone, o = self._gone(b, o)
            for i in gone:
                ents.pop(i, None)
            o = self._records(b, o, joints, d_joint)
            for i in self._gone(b, o)[0]:
                joints.pop(i, None)
            return build(cam, {**self.decor, **ents}, joints)
        return None

    @staticmethod
    def _records(b, o, into, dec):
        n = struct.unpack_from('<H', b, o)[0]
        o += 2
        for _ in range(n):
            i, r, o = dec(b, o)
            into[i] = r
        return o

    @staticmethod
    def _gone(b, o):
        n = struct.unpack_from('<H', b, o)[0]
        return struct.unpack_from('<%dH' % n, b, o + 2), o + 2 + 2 * n
