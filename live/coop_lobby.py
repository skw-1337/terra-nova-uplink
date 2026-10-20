# Coop lobby on the game's Mission Outfitting screen (English exe): the guest takes a teammate's column (2 to 4),
# picks its pilot and loadout from his window, the host sees it at once on his screen and can lock the column.
# Found 20/10/2026 (TerraNovaCoop/re/NOTES.md, "Mission Outfitting screen"):
#   squad columns   0x391E50 + c * 0x32: +6 pilot id, +8 suit, +9..+0xC weapons (left 1, left 2, right 1, right 2;
#                   a two-slot weapon leaves 0 in the second), +0xD ASF
#   pilot rows      0x390348 + r * 494: +0 pilot id (name: RESGAME 0x16C), +5 specialty; id -> row: 0x391F4D + id
#   list            rows shown 0x43D2FC.. (count: word 0x43D468), status byte 0x43E61D + row
#                   (0 available, 1 injured, 2 away; in a column: ready)
#   mission items   suits 0x4412BC (count 0x35D0F2), weapons 0x4412BF (0x35D0F0), ASF 0x4412B0 (0x35D0F1; the
#                   first two, Demolition / Repair pack, come with the specialty), two-slot flag 0x395111 + w * 0x24
#   suit rules      RESMISS 0x6B4 (weapons) / 0x6B5 (ASF): high byte of word [id] = the suits allowed (bit = suit)
#   redraw          the screen's task [0x36F4B4] waits for event 0x101: posting 0x0B there (as 0x2E809C does)
#                   redraws every column, no click
import json, os, struct

SQUAD, SQUAD_N = 0x391E50, 0x32
ROWS, ROW_N, ID2ROW = 0x390348, 494, 0x391F4D
LIST, LIST_COUNT, STATUS = 0x43D2FC, 0x43D468, 0x43E61D
SUITS, WEAPONS, ASFS = 0x4412BC, 0x4412BF, 0x4412B0
N_SUITS, N_WEAPONS, N_ASF = 0x35D0F2, 0x35D0F0, 0x35D0F1
TWO_SLOT, ASF_DEFAULT, ASF_OVERRIDE = 0x395111, 0x390328, 0x43D2F8
TASK, WAKE, REDRAW = 0x36F4B4, 0x101, 0x0B
OUTFIT_SIG = bytes.fromhex('9b1a14')   # the task's script position (+0x10) while the outfitting screen waits
LASER = 4
SPECS = {1: 'Recon', 2: 'Weapons', 3: 'Demolitions', 4: 'Electronics', 5: 'Repair'}
STATUS_NAMES = ['Available', 'Injured', 'Away on Mission', 'Ready']


class Lobby:
    def __init__(self, g, data_dir=None):
        self.g = g
        self.col = 0                     # the guest's column (1-3), 0 none
        self.locked = False              # the host locked it: the guest can't change it any more
        self.dirty = False               # a redraw to post as soon as the screen waits for it
        self.names, self.wnames, self.snames, self.anames = {}, {}, {}, {}
        self.wmask, self.amask = {}, {}
        self._load(data_dir)

    def _load(self, d):
        import lgres
        if not d or not os.path.isdir(d):
            return
        try:
            game = lgres.load(os.path.join(d, 'RESGAME.RES'))
            pilots = lgres.strings(game[0x16C][2])
            items = lgres.strings(game[0x16E][2])
            self.names = dict(enumerate(pilots))
            self.wnames = {i: s for i, s in enumerate(items[:0x30]) if s}
            self.anames = {i - 0x30: s for i, s in enumerate(items) if i >= 0x30 and s}
            term = lgres.load(os.path.join(d, 'RESPTERM.RES'))
            outfit = lgres.strings(term[0x5AB][2])
            self.snames = {i: outfit[0x110 + i] for i in range(4)}
            miss = lgres.load(os.path.join(d, 'RESMISS.RES'))
            for rid, out in ((0x6B4, self.wmask), (0x6B5, self.amask)):
                fr = lgres.frames(miss[rid][2])[0]
                for i in range(len(fr) // 2):
                    out[i] = fr[2 * i + 1]
        except (OSError, KeyError, IndexError, struct.error):
            pass

    def u8(self, a):
        return self.g.read(a, 1)[0]

    # ---- reading
    def column(self, c):
        r = self.g.read(SQUAD + SQUAD_N * c, SQUAD_N)
        return {'pilot': r[6], 'suit': r[8], 'w': list(r[9:13]), 'asf': r[13]}

    def pilots(self):
        n = struct.unpack('<H', self.g.read(LIST_COUNT, 2))[0]
        rows = self.g.read(LIST, 16)
        used = {self.u8(ID2ROW + self.column(c)['pilot']) for c in range(4)}
        out = []
        for row in rows[:12]:
            pid = self.u8(ROWS + ROW_N * row)
            spec = self.u8(ROWS + ROW_N * row + 5)
            st = 3 if row in used else self.u8(STATUS + row)
            out.append({'row': row, 'id': pid, 'name': self.names.get(pid, '#%d' % pid), 'spec': SPECS.get(spec, ''),
                        'status': st, 'status_name': STATUS_NAMES[st] if st < 4 else '?'})
        return out

    def items(self):
        g = self.g
        suits = list(g.read(SUITS, self.u8(N_SUITS)))
        weapons = list(g.read(WEAPONS, self.u8(N_WEAPONS)))
        asf = list(g.read(ASFS, self.u8(N_ASF)))[2:]
        return suits, weapons, asf

    def two_slot(self, w):
        return w and self.u8(TWO_SLOT + w * 0x24) != 0

    def allowed(self, mask, item, suit):
        return (mask.get(item, 0xFF) >> suit) & 1 == 1

    def state(self, in_mission):
        suits, weapons, asf = self.items()
        cols = []
        for c in range(4):
            col = self.column(c)
            pid = col['pilot']
            spec = self.u8(ROWS + ROW_N * self.u8(ID2ROW + pid) + 5)
            cols.append(dict(col, name=self.names.get(pid, '#%d' % pid), spec=SPECS.get(spec, ''),
                             who='host' if c == 0 else 'guest' if c == self.col else 'ai'))
        return {'outfit': self.on_screen() and not in_mission, 'mission': in_mission, 'col': self.col,
                'locked': self.locked, 'cols': cols, 'pilots': self.pilots(),
                'suits': [[s, self.snames.get(s, 'Suit %d' % s)] for s in suits],
                'weapons': [[w, self.wnames.get(w, '#%d' % w), self.wmask.get(w, 0xFF), 1 if self.two_slot(w) else 0]
                            for w in weapons],
                'asf': [[a, self.anames.get(a, '#%d' % a), self.amask.get(a, 0xFF)] for a in asf],
                'fixed_asf': {'Demolitions': self.anames.get(0, ''), 'Repair': self.anames.get(1, '')}}

    def packet(self, in_mission):
        return b'GLB' + json.dumps(self.state(in_mission), separators=(',', ':')).encode('utf-8')

    # ---- the outfitting screen
    def task(self):
        return struct.unpack('<I', self.g.read(TASK, 4))[0]

    def on_screen(self):
        t = self.task()
        if not t or struct.unpack('<H', self.g.read(t + 0x24, 2))[0] != WAKE:
            return False
        return self.g.read(t + 0x10, 3) == OUTFIT_SIG    # another screen waiting for 0x101 never gets our event

    def redraw(self):
        """posts the redraw (0x0B) to the outfitting task when it waits for it, else keeps it for later"""
        self.dirty = True
        t = self.task()
        if not t or not self.on_screen():
            return False
        o = self.g.read(t, 0x84)
        i = struct.unpack_from('<i', o, 0x7E)[0] >> 16
        self.g.write(t + 0x30 + 4 * i, struct.pack('<I', REDRAW))
        self.g.write(t + 0x70 + i, b'\x00')
        self.g.write(t + 0x80, struct.pack('<H', (struct.unpack_from('<H', o, 0x80)[0] + 1) & 0xFFFF))
        self.g.write(t + 0x24, b'\x00\x00')          # last: the task wakes up and draws
        self.dirty = False
        return True

    def tick(self):
        if self.dirty:
            self.redraw()

    # ---- the guest's requests ('L' + JSON)
    def request(self, msg, in_mission):
        """returns a short text for the log, or None"""
        if in_mission:
            return None
        act = msg.get('act')
        if act == 'join':
            c = int(msg.get('col', 0))
            if c not in (1, 2, 3):
                return None
            if self.locked and self.col:
                return 'join refused: locked'
            self.col = c
            return 'joined column %d' % (c + 1)
        if act == 'leave':
            if self.locked:
                return 'leave refused: locked'
            self.col = 0
            return 'left the squad'
        if not self.col or self.locked:
            return None
        base = SQUAD + SQUAD_N * self.col
        col = self.column(self.col)
        suits, weapons, asf = self.items()
        if act == 'pilot':
            row = int(msg.get('row', -1))
            if row not in [p['row'] for p in self.pilots() if p['status'] == 0]:
                return 'pilot refused'
            pid = self.u8(ROWS + ROW_N * row)
            self.g.write(base + 6, bytes([pid]))
            self._asf_for_pilot(row)
        elif act == 'suit':
            s = int(msg.get('id', -1))
            if s not in suits:
                return 'suit refused'
            self.g.write(base + 8, bytes([s]))
            self._fit_suit(s)
        elif act == 'weapon':
            slot, w = int(msg.get('slot', -1)), int(msg.get('id', -1))
            if slot not in range(4) or w not in weapons or not self.allowed(self.wmask, w, col['suit']):
                return 'weapon refused'
            if self.two_slot(w) and col['suit'] == 0:
                return 'weapon refused'
            arm = slot // 2 * 2
            ws = col['w']
            if self.two_slot(w):
                ws[arm], ws[arm + 1] = w, 0
            else:
                if self.two_slot(ws[arm]):           # was a two-slot weapon: the other half gets a laser
                    ws[arm], ws[arm + 1] = LASER, LASER
                ws[slot] = w
            self.g.write(base + 9, bytes(ws))
        elif act == 'asf':
            a = int(msg.get('id', -1))
            if col['asf'] < 2 or a not in asf or not self.allowed(self.amask, a, col['suit']):
                return 'ASF refused'
            self.g.write(base + 0xD, bytes([a]))
        else:
            return None
        self.redraw()
        return '%s %s' % (act, msg.get('id', msg.get('row', '')))

    def _asf_for_pilot(self, row):
        """the game's rule (0x2B9AC4): Demolitions -> Demolition Pack, Repair -> Repair Pack, else the column's
        override or the specialty's default when it had one of those two"""
        base = SQUAD + SQUAD_N * self.col
        spec = self.u8(ROWS + ROW_N * row + 5)
        cur = self.u8(base + 0xD)
        if spec == 3:
            a = 0
        elif spec == 5:
            a = 1
        elif cur >= 2:
            return
        else:
            a = self.u8(ASF_OVERRIDE + self.col) or self.u8(ASF_DEFAULT + spec * 6)
        self.g.write(base + 0xD, bytes([a]))

    def _fit_suit(self, s):
        """weapons and ASF the new suit can't carry become lasers / the first allowed ASF"""
        base = SQUAD + SQUAD_N * self.col
        col = self.column(self.col)
        ws = col['w']
        for arm in (0, 2):
            if s == 0 and self.two_slot(ws[arm]):
                ws[arm], ws[arm + 1] = LASER, LASER
            for k in (arm, arm + 1):
                if ws[k] and not self.allowed(self.wmask, ws[k], s):
                    if self.two_slot(ws[k]):
                        ws[arm], ws[arm + 1] = LASER, LASER
                    else:
                        ws[k] = LASER
        self.g.write(base + 9, bytes(ws))
        if col['asf'] >= 2 and not self.allowed(self.amask, col['asf'], s):
            ok = [a for a in self.items()[2] if self.allowed(self.amask, a, s)]
            if ok:
                self.g.write(base + 0xD, bytes([ok[0]]))


def find_data(g):
    """the game's TNOVA/DATA: TN_GAME_DATA, else from the DOSBox executable (its folder or a parent), else the usual
    Steam and GOG folders"""
    if os.environ.get('TN_GAME_DATA'):
        return os.environ['TN_GAME_DATA']
    cands = []
    try:
        import ctypes
        k32 = ctypes.windll.kernel32
        h = k32.OpenProcess(0x1000, False, g.pid)
        buf = ctypes.create_unicode_buffer(1024); n = ctypes.c_ulong(1024)
        if k32.QueryFullProcessImageNameW(h, 0, buf, ctypes.byref(n)):
            d = os.path.dirname(buf.value)
            for _ in range(3):
                cands.append(d)
                d = os.path.dirname(d)
        k32.CloseHandle(h)
    except (AttributeError, OSError):
        pass
    pf = os.environ.get('ProgramFiles(x86)', r'C:\Program Files (x86)')
    cands += [os.path.join(pf, 'Steam', 'steamapps', 'common', 'Terra Nova Strike Force Centauri'),
              os.path.join(pf, 'GOG Galaxy', 'Games', 'Terra Nova Strike Force Centauri')]
    for d in cands:
        if os.path.isfile(os.path.join(d, 'TNOVA', 'DATA', 'RESMISS.RES')):
            return os.path.join(d, 'TNOVA', 'DATA')
    return None
