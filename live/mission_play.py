# "Play this mission": the game started at a given mission, a campaign one or a new one in slot 18 / 28.
#
# How (both ways replayed in a hidden game on 17/11/2026, into the new missions 18 and 28):
#   1. a SAVE. The mission a save resumes at is in its header (resource 1776: +4 the mission's number, the n of
#      MISSn.RES, +8 the campaign position + 3); the game copies it into its "current mission" (dword 0x359708)
#      when the save is loaded. make_save() copies the player's most advanced save (pilots, equipment, progress)
#      into a free slot under our own name with the header set on the wanted mission. The player's saves are
#      never written: only a free slot, or the slot of an earlier save of ours. This alone is enough: the player
#      loads the save and starts the briefing himself. It is the way to prefer (nothing is written in memory).
#   2. the menus. start() takes the running game from its main menu into the mission: Load Game, the save's row,
#      Enter Base, Start Mission Briefing, the text briefing's Exit, Outfit Complete; the keys go to the game's
#      window as messages and the clicks into the game's own mouse queue (no focus taken, the real pointer never
#      moves). With poke_only the mission's number is written at 0x359708 instead, on any save: it must be there
#      before the briefing starts (written once the outfitting screen is up, the game has already loaded the
#      save's own mission and only the script changes: a broken mix).
# The squad: the game decides it from the mission's number when the outfitting screen comes up. For the new
# missions 18 and 28 that is the player alone, in a standard suit, whatever save is used (seen in game).
#
#   python mission_play.py --game "C:\...\Terra Nova Strike Force Centauri" --mission 18            the save only
#   python mission_play.py --game ... --mission 18 --start [--pid DOSBOX_PID]                        and the menus
#   python mission_play.py --game ... --list
# From the launcher or the bridge:  import mission_play; label, path = mission_play.make_save(tnova_dir, 18)
#                                   mission_play.start(18, row=mission_play.slot_of(path))
# Every failure is a PlayError whose text can be shown as it is.
import os
import re
import struct
import sys
import time

import lgres

CAMPAIGN = [37, 38, 1, 2, 3, 4, 5, 6, 7, 8, 9, 32, 33, 10, 11, 12, 13, 34, 29, 15, 17, 16, 36,
            14, 20, 39, 21, 35, 22, 23, 19, 24, 27, 25, 26, 30, 31]
NEW_SLOTS = (18, 28)                       # missions the game has no file for: the editor's new missions
PREFIX = 'UPLINK Mission '
OURS = ('UPLINK Mission ', 'COOP Mission ', 'LAB Mission ')
MAGIC = 0x06EF0018                         # a save's header starts with it
A_MISSION = 0x359708                       # the current mission's number
A_ENTITIES = 0x3C3240                      # the entity table (0x25 bytes each): a mission is loaded when it has any
A_FRAMES = 0x466124                        # counts the mission's pictures: it grows while the mission runs


class PlayError(Exception):
    pass


# ---------------------------------------------------------------- the save
def _raw(path):
    """An LG Res file as stored: [[id, flags, type, unpacked size, stored bytes]] (a packed resource stays packed)."""
    d = open(path, 'rb').read()
    if d[:14] != b'LG Res File v2':
        raise PlayError('%s is not one of the game\'s files.' % os.path.basename(path))
    diro = struct.unpack_from('<I', d, 0x7C)[0]
    n, off = struct.unpack_from('<HI', d, diro)
    out = []
    for i in range(n):
        rid, x, y = struct.unpack_from('<HII', d, diro + 6 + 10 * i)
        flags, size = x >> 24, x & 0xFFFFFF
        stored = (y & 0xFFFFFF) if flags & 1 else size
        out.append([rid, flags, y >> 24, size, d[off:off + stored]])
        off += (stored + 3) & ~3
    return out


def _raw_write(path, entries):
    out = bytearray(b'LG Res File v2\r\n\x1a'.ljust(0x80, b'\0'))
    for e in entries:
        out += e[4] + b'\0' * (-len(e[4]) % 4)
    diro = len(out)
    struct.pack_into('<I', out, 0x7C, diro)
    out += struct.pack('<HI', len(entries), 0x80)
    for rid, flags, typ, size, data in entries:
        out += struct.pack('<HII', rid, size | (flags << 24), len(data) | (typ << 24))
    tmp = path + '.tmp'
    with open(tmp, 'wb') as f:
        f.write(out)
    if open(tmp, 'rb').read() != bytes(out):
        os.remove(tmp)
        raise PlayError('%s could not be written whole (disk full?)' % os.path.basename(path))
    os.replace(tmp, path)


def _raw_set(entries, rid, data):
    for e in entries:
        if e[0] == rid:
            if e[1] & 1:
                raise PlayError('Resource %d of the save is packed: it cannot be changed.' % rid)
            e[3], e[4] = len(data), bytes(data)
            return
    raise PlayError('The save has no resource %d.' % rid)


def saves(tnova_dir):
    """The nine save slots: [{slot, path, name, mission, position, ours}] for the ones in use."""
    out = []
    for slot in range(1, 10):
        p = os.path.join(tnova_dir, 'SAVE%02d.RES' % slot)
        if not os.path.exists(p):
            continue
        try:
            r = lgres.load(p)
            h = r[1776][2]
            name = r[1775][2].split(b'\0')[0].decode('ascii', 'replace')
            if struct.unpack_from('<I', h, 0)[0] != MAGIC:
                continue
            out.append({'slot': slot, 'path': p, 'name': name, 'mission': struct.unpack_from('<i', h, 4)[0],
                        'position': struct.unpack_from('<i', h, 8)[0], 'ours': name.startswith(OURS)})
        except (KeyError, OSError, struct.error):
            continue
    return out


def slot_of(path):
    return int(os.path.basename(path)[4:6])


def make_save(tnova_dir, mission, out_dir=None, prefix=PREFIX, data_dir=None):
    """A save of ours that resumes at `mission`, made from the player's most advanced save. Returns (its name in
    the game's list, its path). out_dir: where it is written (the game's TNOVA folder by default; a test gives its
    own folder, where the slot's file name is still the one the game will look for)."""
    mission = int(mission)
    data_dir = data_dir or os.path.join(tnova_dir, 'DATA')
    if mission not in CAMPAIGN and mission not in NEW_SLOTS and mission not in (46, 47):
        raise PlayError('Mission %d cannot be started this way.' % mission)
    if not os.path.exists(os.path.join(data_dir, 'MISS%d.RES' % mission)):
        raise PlayError('MISS%d.RES is not in the game: %s' % (mission, 'install the new mission first.'
                        if mission in NEW_SLOTS else 'the game is incomplete.'))
    found = saves(tnova_dir)
    mine = [s for s in found if not s['ours']]
    if not mine:
        raise PlayError('To start at a mission, the game needs at least one save of yours (play the first mission and save).')
    best = max(mine, key=lambda s: s['position'])
    used = {s['slot'] for s in found}
    out_dir = out_dir or tnova_dir
    if out_dir != tnova_dir:                         # (a test's folder laid over the game's: its saves count too)
        used |= {s['slot'] for s in saves(out_dir) if not s['name'].startswith(prefix)}
        ours = [s['slot'] for s in saves(out_dir) if s['name'].startswith(prefix)]
    else:
        ours = [s['slot'] for s in found if s['name'].startswith(prefix)]
    free = [n for n in range(1, 10) if n not in used]
    if not ours and not free:
        raise PlayError('The 9 save slots are all used: free one (Saves in the launcher), or start from the game\'s menus.')
    target = ours[0] if ours else free[0]
    entries = _raw(best['path'])
    head = bytearray(lgres.load(best['path'])[1776][2])
    struct.pack_into('<i', head, 4, mission)
    if mission in CAMPAIGN:
        index = CAMPAIGN.index(mission)
        struct.pack_into('<i', head, 8, index + 3)
        label = '%s%02d' % (prefix, index + 1)
    else:                                            # (not a campaign mission: the base save's position stays)
        label = '%s%s%d' % (prefix, 'new ' if mission in NEW_SLOTS else 'MISS', mission)
    _raw_set(entries, 1776, head)
    _raw_set(entries, 1775, label.encode('ascii') + b'\0')
    path = os.path.join(out_dir, 'SAVE%02d.RES' % target)
    if os.path.exists(path):
        old = lgres.load(path)
        if not old.get(1775, (0, 0, b''))[2].startswith(prefix.encode()):
            raise PlayError('Slot %d holds a save that is not ours: nothing written.' % target)
    _raw_write(path, entries)
    return label, path


# ---------------------------------------------------------------- the running game
class Game:
    """The running game's memory, keys and menu clicks (tnre.py; TNRE_PID picks the DOSBox when several run)."""

    def __init__(self, pid=None):
        if pid:
            os.environ['TNRE_PID'] = str(pid)
        os.environ['TNRE_POST'] = '1'               # keys as window messages: no focus taken
        import tnre
        self.tnre = tnre
        try:
            self.g = tnre.Guest()
        except SystemExit as e:
            raise PlayError('The game is not running (%s).' % e)
        self._mouse = None

    def dword(self, a):
        return struct.unpack('<I', self.g.read(a, 4))[0]

    def code_loaded(self):
        try:
            return any(self.g.read(0x29E746, 4))
        except SystemExit:
            return False

    def mission(self):
        return self.dword(A_MISSION)

    def set_mission(self, n):
        self.g.write(A_MISSION, struct.pack('<I', n))

    def loaded(self):
        return self.g.read(A_ENTITIES + 0x25, 1)[0] != 0

    def running(self):
        a = self.dword(A_FRAMES)
        time.sleep(0.4)
        return self.dword(A_FRAMES) > a

    def keys(self, seq):
        try:
            self.tnre.keys(seq)
        except SystemExit as e:
            raise PlayError('The game\'s window was not found (%s).' % e)

    def _mouse_addresses(self):
        """The game's mouse library, found by its code (the same in the English and French exes): the cursor and
        its "placed by hand" byte, and its event queue (write index, entries, size, clock)."""
        if self._mouse:
            return self._mouse
        code = self.g.read(0x244000, 0x111000)       # the game's code (0x244000 - 0x355000)
        m = re.search(re.escape(bytes.fromhex('84d20f85')) + b'....' + re.escape(bytes.fromhex('803d')) + b'(....)'
                      + re.escape(bytes.fromhex('0074238b15')) + b'(....)', code, re.S)
        q = re.search(rb'\x0f\xbf\x35(....)\xc1\xe6\x04\x8d\xb6(....)', code, re.S)
        s = re.search(rb'\x0f\xbf\x3d(....)\xa1(....)\x47\xc1\xf8\x10', code, re.S)
        c = re.search(rb'\x8b\x0d(....)\x8b\x09\x89\x8e', code, re.S)
        if not (m and q and s and c):
            raise PlayError('The game\'s menus are not ready (its mouse code was not found).')
        u = lambda b: struct.unpack('<I', b)[0]
        self._mouse = (u(m.group(1)), u(m.group(2)), u(q.group(1)) - 4, u(q.group(2)), u(s.group(2)) + 2, u(c.group(1)))
        return self._mouse

    def click(self, x, y, after=1.0):
        """A left click at (x, y) of the menus' 640 x 480, put in the game's own mouse queue."""
        warp, cursor, wr, queue, size, clock = self._mouse_addresses()
        for _ in range(5):
            self.g.write(cursor, struct.pack('<hh', x, y))
            self.g.write(warp, b'\x01')
            time.sleep(0.03)
        w = struct.unpack('<H', self.g.read(wr, 2))[0]
        n = struct.unpack('<H', self.g.read(size, 2))[0] or 1
        t = self.dword(self.dword(clock))
        for ev, bt in ((2, 1), (4, 0)):
            self.g.write(queue + 16 * w, struct.pack('<hhBIB', x, y, ev, t & 0xFFFFFFFF, bt).ljust(16, b'\0'))
            w = (w + 1) % n
        self.g.write(wr, struct.pack('<H', w))
        time.sleep(0.6 + after)


ROW_Y = lambda slot: int(round(232 + (slot - 5) * 40.33))      # the Load Game list: one row a slot


def start(mission, row, game=None, poke_only=False, log=None, wait_menu=None, poke=None, watch=None):
    """From the game's main menu into the mission's drop. row: the save slot (1-9) to load: the save made by
    make_save(), or with poke_only any save (the mission is then picked by writing its number).
    wait_menu: a function that returns once the main menu is up (default: the intro is skipped and 4 s waited).
    poke: "auto" (the number is written as well, the default), "only" (= poke_only), "never" (the save alone).
    watch: called with a word after each step (a test's pictures). Returns the mission number the game runs."""
    mission = int(mission)
    poke = poke or ('only' if poke_only else 'auto')
    say = log or (lambda s: None)
    seen = watch or (lambda tag: None)
    gm = game or Game()
    put = (lambda: None) if poke == 'never' else (lambda: gm.set_mission(mission))
    for _ in range(120):
        if gm.code_loaded():
            break
        time.sleep(0.5)
    else:
        raise PlayError('The game did not finish loading.')
    if gm.loaded() and gm.running():
        raise PlayError('A mission is already running in the game: finish or leave it first.')
    if wait_menu:
        wait_menu(gm)
    else:
        time.sleep(2.5)
        gm.keys('esc,wait:0.6,esc,wait:0.8')
        time.sleep(4)
    for attempt in range(2):
        seen('menu')
        gm.click(185, 397, 1.5)                      # Load Game
        seen('list')
        gm.click(300, ROW_Y(row), 1.5)               # the save's row
        seen('loaded')
        gm.click(445, 260, 1.5)                      # Enter Base (the door)
        got = gm.mission()
        if got == 0xFFFFFFFF or got == 0:
            # (no save was loaded: the game is not at its main menu. Seen when the game stays on a black screen at
            # start because its TNOVA folder holds the statistics files up to MSTAT777.RES: it finds no free name)
            raise PlayError('The game did not load the save: it is not at its main menu (start it and wait for the menu).')
        say('save loaded: the game is at mission %d' % got)
        if got != mission:
            if poke == 'auto':
                say('the save did not set mission %d: writing it' % mission)
            put()
        gm.keys('esc,wait:2')
        seen('base')
        gm.click(340, 285, 1.0)                      # Start Mission Briefing
        gm.keys('esc,wait:2.5')                      # (its film)
        for k in range(3):                           # the text briefing's Exit, then Outfit Complete
            put()
            seen('outfit%d' % k)
            gm.click(315, 430, 1.0)
            put()
            gm.click(515, 445, 1.5)
            if gm.loaded():
                break
        gm.keys('esc')                               # (the drop's film)
        for _ in range(40):
            if gm.loaded() and gm.running():
                time.sleep(3)
                if gm.mission() != mission:
                    raise PlayError('The game started mission %d instead of %d.' % (gm.mission(), mission))
                say('in mission %d' % mission)
                return mission
            time.sleep(0.5)
        say('the mission did not start, once more')
        gm.keys('esc,wait:1,esc,wait:1,esc,wait:1.5')
    raise PlayError('The mission did not start: the game\'s menus were not where they were expected '
                    '(start it from the game: Load Game, then the save "%s...").' % PREFIX)


def main(argv):
    def opt(name, default=None):
        return argv[argv.index(name) + 1] if name in argv and argv.index(name) + 1 < len(argv) else default
    game_dir = opt('--game')
    if not game_dir:
        print(__doc__ or 'usage: mission_play.py --game DIR --mission N [--start] [--pid PID] | --list')
        return 2
    tnova = os.path.join(game_dir, 'TNOVA')
    try:
        if '--list' in argv:
            for s in saves(tnova):
                print('%d  %-24s mission %-3d position %-3d %s' % (s['slot'], s['name'], s['mission'], s['position'],
                                                                 '(ours)' if s['ours'] else ''))
            return 0
        mission = int(opt('--mission', '0'))
        label, path = make_save(tnova, mission, out_dir=opt('--out'))
        print('save "%s" written: %s' % (label, path))
        if '--start' in argv:
            start(mission, slot_of(path), Game(opt('--pid')), log=print)
        else:
            print('In the game: Load Game, then "%s".' % label)
        return 0
    except PlayError as e:
        print('ERROR: %s' % e)
        return 1


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
