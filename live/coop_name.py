# Coop: the guest's name on the host's HUD (COMM / STAT panels) in place of his teammate's pilot name (English exe).
# The game's pilots: 4 records of 0x32 bytes at 0x391e50 (+0 in use, +2 entity, +6 name index); the names are the
# strings of resource 364 (RESGAME.RES): index k = last name (COMM panel), k + 33 = nickname, k + 65 = full name
# (STAT). The guest's pilot gets the index of a pilot who is not in the mission, whose strings get the guest's name
# (cut to their length: the strings stay in place). Everything is put back when the guest leaves that suit.
import struct

PORTRAIT = bytes.fromhex('02000000' '15001b00' '1500')   # 33 pilot portraits, 21 x 27, one after the other
PW, PH, P_STEP, P_DATA = 21, 27, 0x253, 0x18         # record step; pixels from the header's type word
PAL = 0x44AE90                                        # the game screen's palette (English exe)

PILOTS, PILOT_N, PILOT_END = 0x391e50, 0x32, 0x391f18
FIRST = b'N. ap Io\x00B. ap Io\x00'          # the first strings of resource 364
NAMES = 33                                   # last names 0..32, nicknames +33, full names +65


class NameTag:
    def __init__(self, g):
        self.g, self.strings, self.saved, self.faces = g, None, None, None

    def _table(self):
        """(base, offsets) of resource 364 in memory, found again when it moved (a new mission loads it again)"""
        if self.strings:
            base, offs = self.strings
            if self.g.read(base + offs[0], len(FIRST)) == FIRST:
                return self.strings
        self.strings = None
        for chunk in range(0x400000, 0x1000000, 0x100000):
            m = self.g.read(chunk, 0x100000)
            i = m.find(FIRST) if m else -1
            if i < 0:
                continue
            base = chunk + i - 0x3a2                         # u16 count, count + 1 offsets, then the strings
            n = struct.unpack('<H', self.g.read(base, 2))[0]
            offs = struct.unpack('<%dI' % (n + 1), self.g.read(base + 2, 4 * (n + 1)))
            if n > 65 + NAMES and offs[0] == 0x3a2:
                self.strings = (base, offs)
                return self.strings
        return None

    def _faces(self):
        """address of portrait 0 (the type word of its header), found again when it moved"""
        if self.faces and self.g.read(self.faces, len(PORTRAIT)) == PORTRAIT:
            return self.faces
        self.faces = None
        for chunk in range(0x400000, 0x2000000, 0x100000):
            m = self.g.read(chunk, 0x100000)
            i = m.find(PORTRAIT) if m else -1
            if i >= 0 and all(self.g.read(chunk + i + k * P_STEP, len(PORTRAIT)) == PORTRAIT for k in (1, 32)):
                self.faces = chunk + i
                return self.faces
        return None

    def _face(self, rgb):
        """21 x 27 RGB -> the game's colours (those the portraits use, so no HUD colour that blinks)"""
        pal = self.g.read(PAL, 768)
        f = self._faces()
        used = set(range(256))
        if f:
            used = set()
            for k in range(33):
                used |= set(self.g.read(f + k * P_STEP + P_DATA, PW * PH))
        cols = [(i, pal[3 * i], pal[3 * i + 1], pal[3 * i + 2]) for i in sorted(used)]
        out, memo = bytearray(), {}
        for j in range(PW * PH):
            c = tuple(rgb[3 * j:3 * j + 3])
            if c not in memo:
                memo[c] = min(cols, key=lambda q: (q[1] - c[0]) ** 2 * 3 + (q[2] - c[1]) ** 2 * 4 + (q[3] - c[2]) ** 2 * 2)[0]
            out.append(memo[c])
        return bytes(out)

    def _pilot(self, gid):
        for a in range(PILOTS, PILOT_END, PILOT_N):
            r = self.g.read(a, 8)
            if r[0] | r[1] and struct.unpack_from('<H', r, 2)[0] == gid:
                return a
        return 0

    def put(self, gid, name, face=None):
        """the guest's name (and face: 21 x 27 RGB, his Steam avatar) on suit gid (restores the previous one first)"""
        self.restore()
        name = ''.join(c for c in name if 32 <= ord(c) < 127).strip()
        t = self._table()
        rec = self._pilot(gid) if gid else 0
        if not (name and t and rec):
            return False
        base, offs = t
        size = lambda k: offs[k + 1] - offs[k] - 1
        used = {self.g.read(a + 6, 1)[0] for a in range(PILOTS, PILOT_END, PILOT_N) if self.g.read(a, 2) != b'\0\0'}
        free = [k for k in range(NAMES) if k not in used]
        if not free:
            return False
        k = max(free, key=size)                              # the longest last name nobody uses here
        keep = [(base + offs[j], self.g.read(base + offs[j], size(j))) for j in (k, k + 33, k + 65)]
        fa = self._faces() if face and len(face) == PW * PH * 3 else None
        if fa:                                               # his avatar in place of that pilot's portrait
            pa = fa + k * P_STEP + P_DATA
            keep.append((pa, self.g.read(pa, PW * PH)))
            self.g.write(pa, self._face(face))
        self.saved = (rec, self.g.read(rec + 6, 1), keep, base)
        for j, (a, old) in zip((k, k + 33, k + 65), keep):
            text = (name if j != k + 33 else '"%s"' % name)[:len(old)].encode()
            self.g.write(a, text + b'\0' * (len(old) - len(text)))
        self.g.write(rec + 6, bytes([k]))
        return True

    def restore(self):
        if not self.saved:
            return
        rec, idx, keep, base = self.saved
        self.saved = None
        t = self._table()
        if t and t[0] == base:                               # same resource still loaded: put the strings back
            for a, old in keep:
                self.g.write(a, old)
        if self.g.read(rec + 6, 1) != idx:
            self.g.write(rec + 6, idx)
