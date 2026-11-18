# The guest's HUD packet ('GHD', coop_guest.py hud) kept under Steam's fast path. Online, a packet over 1200 bytes leaves
# the unreliable path (coop_net.gd UNRELIABLE_MAX) and waits behind the big reliable ones. Its map block grows during a
# mission: the squad's contacts pile up (every unit any suit of the squad has seen, buildings drawn as their outlines,
# up to 16 corners each), and every 5 s the weapon box's two colour tables (512 bytes) ride along. Measured on the real
# session of 18/11/2026: 903 bytes at the start (map block 794), 1124 bytes three minutes later.
# Here: when the whole packet would pass BUDGET, the tables and then the first marks (the map's notes and the
# oldest contacts; himself, drawn last, stays in 'GHD') go into 'GMK' packets, each under BUDGET:
#   'GMK' + seq, part, parts (3 bytes) + a map block as 'GHD' has it ('M', flags, state, ammo, number of marks,
#   the tables when flag bit 0, the marks)
# and the 'GHD' map block says so in its flags: bit 1 = marks before these in 'GMK' number seq (bits 2-7). His window
# (coop_hud.gd) draws the 'GMK' marks of the last complete seq, then the 'GHD' ones. An older window reads bit 0 only:
# it draws the 'GHD' marks (the newest), the rest of his map is missing there until both sides are up to date.
import os, struct

BUDGET = int(os.environ.get('TN_COOP_HUD_BUDGET') or 1100)   # bytes (Steam's 1200 less a margin for the relay;
                                                              # tests: lower, to split all the time)


def marks_of(block):
    """(flags, state, ammo, tables, [marks as bytes]) of a map block; None if it is not one"""
    if len(block) < 6 or block[0] != 0x4D:
        return None
    flags, state, ammo, n = struct.unpack_from('<BBHB', block, 1)
    p = 6
    tables = b''
    if flags & 1:
        tables, p = block[p:p + 512], p + 512
    out = []
    for _ in range(n):
        if p + 3 > len(block) or p + 3 + block[p + 2] > len(block):
            break
        out.append(block[p:p + 3 + block[p + 2]])
        p += 3 + block[p + 2]
    return flags, state, ammo, tables, out


def block_of(flags, state, ammo, tables, marks):
    return b'M' + struct.pack('<BBHB', flags | (1 if tables else 0), state, ammo, len(marks)) + tables + b''.join(marks)


def split(head, block, tail, seq, budget=BUDGET):
    """head + block + tail as one 'GHD' if it fits, else ('GHD' with the newest marks, ['GMK' parts]); seq 0-63"""
    whole = head + block + tail
    if len(whole) <= budget:
        return whole, []
    got = marks_of(block)
    if got is None:
        return whole, []
    _, state, ammo, tables, marks = got
    room = budget - len(head) - len(tail) - 6
    keep, size = [], 0
    for m in reversed(marks):                               # the newest (himself last) stay in 'GHD'
        if size + len(m) > room:
            break
        keep.insert(0, m)
        size += len(m)
    rest = marks[:len(marks) - len(keep)]
    parts, cur, cur_n = [], [], 6 + len(tables)
    for m in rest:
        if cur and cur_n + len(m) > budget - 6:
            parts.append(cur)
            cur, cur_n = [], 6
        cur.append(m)
        cur_n += len(m)
    if cur or tables:
        parts.append(cur)
    parts = parts[:255]
    seq &= 63
    out = []
    for k, ms in enumerate(parts):
        out.append(b'GMK' + bytes([seq, k, len(parts)]) + block_of(0, state, ammo, tables if k == 0 else b'', ms))
    return head + block_of(2 | (seq << 2), state, ammo, b'', keep) + tail, out
