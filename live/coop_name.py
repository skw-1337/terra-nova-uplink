# Coop: the guest's name on the host's HUD (COMM / STAT panels) in place of his teammate's pilot name (English exe).
# The game's pilots: 4 records of 0x32 bytes at 0x391e50 (+0 in use, +2 entity, +6 name index); the names are the
# strings of resource 364 (RESGAME.RES): index k = last name (COMM panel), k + 33 = nickname, k + 65 = full name
# (STAT). The guest's pilot gets the index of a pilot who is not in the mission, whose strings get the guest's name
# (cut to their length: the strings stay in place). Everything is put back when the guest leaves that suit.
import struct

PILOTS, PILOT_N, PILOT_END = 0x391e50, 0x32, 0x391f18
FIRST = b'N. ap Io\x00B. ap Io\x00'          # the first strings of resource 364
NAMES = 33                                   # last names 0..32, nicknames +33, full names +65


class NameTag:
    def __init__(self, g):
        self.g, self.strings, self.saved = g, None, None

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

    def _pilot(self, gid):
        for a in range(PILOTS, PILOT_END, PILOT_N):
            r = self.g.read(a, 8)
            if r[0] | r[1] and struct.unpack_from('<H', r, 2)[0] == gid:
                return a
        return 0

    def put(self, gid, name):
        """the guest's name on suit gid (restores the previous one first)"""
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
