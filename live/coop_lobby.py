# Coop lobby on the game's Mission Outfitting screen (English exe): the guest takes a teammate's column (2 to 4),
# picks its pilot and loadout from his window, the host sees it at once on his screen and can lock the column.
# Found 20-21/10/2026 (TerraNovaCoop/re/NOTES.md, "Mission Outfitting screen"):
#   squad columns   0x391E50 + c * 0x32: +6 pilot id, +8 suit, +9..+0xC weapons (left 1, left 2, right 1, right 2;
#                   a two-slot weapon leaves 0 in the second), +0xD ASF
#   pilot rows      0x390348 + r * 494: +0 pilot id (name: RESGAME 0x16C), +5 specialty; id -> row: 0x391F4D + id
#   list            rows shown 0x43D2FC.. (count: word 0x43D468), status byte 0x43E61D + row
#                   (0 available, 1 injured, 2 away; in a column: ready)
#   mission items   suits 0x4412BC (count 0x35D0F2), weapons 0x4412BF (0x35D0F0), ASF 0x4412B0 (0x35D0F1; the
#                   first two, Demolition / Repair pack, come with the specialty), two-slot flag 0x395111 + w * 0x24
#   suit rules      RESMISS 0x6B4 (weapons) / 0x6B5 (ASF): high byte of word [id] = the suits allowed (bit = suit)
#   specs           weapon w: range word 0x39511E + w * 0x24 (x 6 m), shots word 0x39511A (shown when > 1), damage
#                   RESPTERM 0x5AB string 0x149 + w; suit s: speed 0x170 + s, visuals 0x174 + s, weapon slots
#                   0x178 + s, jets 0x17C + s, sensors words 0x395BEB / 0x395BE7 + s * 70
#   mission         number dword 0x359708 (its file MISSn.RES), name RESMISS 0x6AA string [n - 1], note 0x428BF0
#   redraw          the screen's task [0x36F4B4] waits for event 0x101: posting 0x0B there (as 0x2E809C does)
#                   redraws every column, no click; the column the host clicked last: byte 0x35CF20
#   host's screen   the guest's name: resource 364's offset for his pilot pointed at a string of ours (the coop
#                   data page, 0x46C400); his face: RESBASE 215 (64 x 64 portraits, in memory while the screen is
#                   up) offset for his pilot pointed at a raw 64 x 64 picture written over two portraits no
#                   campaign pilot has (31, 32). Both put back when he leaves, the mission starts or the bridge ends.
import atexit, base64, json, os, struct, time

SQUAD, SQUAD_N = 0x391E50, 0x32
ROWS, ROW_N, ID2ROW = 0x390348, 494, 0x391F4D
LIST, LIST_COUNT, STATUS = 0x43D2FC, 0x43D468, 0x43E61D
SUITS, WEAPONS, ASFS = 0x4412BC, 0x4412BF, 0x4412B0
N_SUITS, N_WEAPONS, N_ASF = 0x35D0F2, 0x35D0F0, 0x35D0F1
TWO_SLOT, ASF_DEFAULT, ASF_OVERRIDE = 0x395111, 0x390328, 0x43D2F8
W_TABLE, W_N = 0x395110, 0x24
SUIT_SENSE, SUIT_N = 0x395BE7, 70
MISSION_NO, NOTE = 0x359708, 0x428BF0
TASK, WAKE, REDRAW = 0x36F4B4, 0x101, 0x0B
HOST_COL = 0x35CF20
OUTFIT_SIG = bytes.fromhex('9b1a14')   # the task's script position (+0x10) while the outfitting screen waits
LASER = 4
PALETTE = 0x44AE90                 # the game's 256 colours (8 bits each): the portraits' on the outfitting screen
NAME_AT = 0x46C400                 # the coop data page (TN+ Coop exe): the guest's name for the host's screen
SPARE_FACES = (31, 32)             # RESBASE 215 portraits no campaign pilot has: room for his face
SPECS = {1: 'Recon', 2: 'Weapons', 3: 'Demolitions', 4: 'Electronics', 5: 'Repair'}
STATUS_NAMES = ['Available', 'Injured', 'Away on Mission', 'Ready']
UNDO = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logs', 'coop_lobby_undo.json')


class Lobby:
    def __init__(self, g, data_dir=None):
        self.g = g
        self.col = 0                     # the guest's column (1-3), 0 none
        self.locked = False              # the host locked it: the guest can't change it any more
        self.ready = False               # the guest said he is ready
        self.chat = []                   # [[n, 'host' / 'guest', text]], the last ones
        self.chat_n = 0
        self.guest_name, self.guest_face = 'Player 2', None   # his Steam name, his avatar (64 x 64 RGB)
        self.dirty = False               # a redraw to post as soon as the screen waits for it
        self.pal, self.pal_t = b'', 0.0   # the palette last sent (again every 5 s, his window may have restarted)
        self.was_outfit, self.note = False, ''
        self.names, self.wnames, self.snames, self.anames, self.opnames = {}, {}, {}, {}, []
        self.wmask, self.amask, self.outfit_str = {}, {}, []
        self.faces_file = b''            # RESBASE 215 as on disk: where it is in memory, its offsets
        self.tag = None                  # what the host's screen shows of the guest: (pilot, name, ready, face)
        self.face_done, self.face_t = False, 0.0   # his face put on that screen (RESBASE 215 is not always loaded)
        self.outfit_t = 0.0              # the outfitting screen last seen: a redraw makes it busy for a moment
        self.undo = []                   # [(address, old bytes, new bytes)]
        self._load(data_dir)
        self._undo_old_run()
        atexit.register(self.untag)

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
            self.outfit_str = lgres.strings(term[0x5AB][2])
            self.snames = {i: self.outfit_str[0x110 + i] for i in range(4)}
            miss = lgres.load(os.path.join(d, 'RESMISS.RES'))
            for rid, out in ((0x6B4, self.wmask), (0x6B5, self.amask)):
                fr = lgres.frames(miss[rid][2])[0]
                for i in range(len(fr) // 2):
                    out[i] = fr[2 * i + 1]
            self.opnames = lgres.strings(miss[0x6AA][2])
            self.faces_file = lgres.load(os.path.join(d, 'RESBASE.RES'))[215][2]
        except (OSError, KeyError, IndexError, struct.error):
            pass

    def u8(self, a):
        return self.g.read(a, 1)[0]

    def u16(self, a):
        return struct.unpack('<H', self.g.read(a, 2))[0]

    # ---- reading
    def column(self, c):
        r = self.g.read(SQUAD + SQUAD_N * c, SQUAD_N)
        return {'on': r[0], 'pilot': r[6], 'suit': r[8], 'w': list(r[9:13]), 'asf': r[13]}   # on 0: no such slot here

    def pilots(self):
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

    def _s(self, i):
        return self.outfit_str[i] if i < len(self.outfit_str) else ''

    def weapon_spec(self, w):
        """the game's Weapon Specs panel (0x2B8200): range, damage, arm slots, shots"""
        rng = self.u16(W_TABLE + W_N * w + 0xE) * 6
        shots = self.u16(W_TABLE + W_N * w + 0xA)
        out = ['Range %dm' % rng, 'Damage %s' % (self._s(0x149 + w) or '?'), 'Arm slots %d' % (2 if self.two_slot(w) else 1)]
        if shots > 1:
            out.append('Shots %d' % shots)
        return '  ·  '.join(out)

    def suit_spec(self, s):
        """the game's Suit Specs panel (0x2B88F3): speed, sensors, visuals, weapon slots, jets"""
        far, near = self.u16(SUIT_SENSE + 4 + SUIT_N * s), self.u16(SUIT_SENSE + SUIT_N * s)
        return '  ·  '.join(['Speed %s kph' % self._s(0x170 + s), 'Sensors %d/%dm' % (far, near),
                             'Visuals %s' % self._s(0x174 + s), 'Weapon slots %s' % self._s(0x178 + s),
                             'Jets %s' % self._s(0x17C + s)])

    def state(self, in_mission):
        suits, weapons, asf = self.items()
        cols = []
        for c in range(4):
            col = self.column(c)
            pid = col['pilot']
            spec = self.u8(ROWS + ROW_N * self.u8(ID2ROW + pid) + 5)
            cols.append(dict(col, name=self.names.get(pid, '#%d' % pid), spec=SPECS.get(spec, ''),
                             who='host' if c == 0 else 'guest' if c == self.col else 'ai'))
        outfit = self.outfit_up(in_mission)
        extra = {}
        if outfit:                                     # the portraits' colours, when they changed or every 5 s
            pal = self.g.read(PALETTE, 768)
            if pal != self.pal or time.time() - self.pal_t > 5.0:
                self.pal, self.pal_t = pal, time.time()
                extra['pal'] = base64.b64encode(pal).decode('ascii')
            if not self.was_outfit:                    # just came in: the screen's note
                self.note = (self.g.read(NOTE, 600) or b'').split(b'\0')[0].replace(b'\x01', b'\n').decode('cp850', 'replace')
        self.was_outfit = outfit
        no = struct.unpack('<I', self.g.read(MISSION_NO, 4))[0]
        return {**extra, 'outfit': outfit, 'mission': in_mission, 'col': self.col,
                'locked': self.locked, 'ready': self.ready, 'host_col': self.u8(HOST_COL) & 3,
                'op': self.opnames[no - 1] if 0 < no <= len(self.opnames) else '', 'note': self.note,
                'msnfile': 'MISS%d.RES' % no if 0 < no < 100 else '', 'chat': self.chat[-12:],
                'cols': cols, 'pilots': self.pilots(),
                'suits': [[s, self.snames.get(s, 'Suit %d' % s), self.suit_spec(s)] for s in suits],
                'weapons': [[w, self.wnames.get(w, '#%d' % w), self.wmask.get(w, 0xFF), 1 if self.two_slot(w) else 0,
                             self.weapon_spec(w)] for w in weapons],
                'asf': [[a, self.anames.get(a, '#%d' % a), self.amask.get(a, 0xFF)] for a in asf],
                'fixed_asf': {'Demolitions': self.anames.get(0, ''), 'Repair': self.anames.get(1, '')}}

    def packet(self, in_mission):
        return b'GLB' + json.dumps(self.state(in_mission), separators=(',', ':')).encode('utf-8')

    def say(self, who, text):
        text = ''.join(c for c in str(text) if c >= ' ')[:120].strip()
        if text:
            self.chat_n += 1
            self.chat = (self.chat + [[self.chat_n, who, text]])[-30:]

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

    def outfit_up(self, in_mission):
        """the outfitting screen is up (seen waiting in the last 3 s: our own redraw keeps it busy a moment)"""
        if in_mission:
            self.outfit_t = 0.0
            return False
        if self.on_screen():
            self.outfit_t = time.time()
        return time.time() - self.outfit_t < 3.0

    def tick(self, in_mission):
        """the guest on the host's screen (his name and face on his column), kept up to date; and the redraw"""
        want = None
        if self.col and self.outfit_up(in_mission):
            want = (self.column(self.col)['pilot'], self.guest_name, self.ready, self.guest_face)
        if want != self.tag:
            self.untag()
            if want:
                self._put_tag(*want)
            self.tag = want
            self.redraw()
        elif want and want[3] and not self.face_done and time.time() - self.face_t > 1.0:
            self.face_t = time.time()                  # his face: the portraits were not loaded, again
            if self._put_face(want[0], want[3]):
                self.redraw()
        if self.dirty:
            self.redraw()

    # ---- the host's screen: the guest's name and face on his column
    def _write(self, a, data):
        self.undo.append((a, self.g.read(a, len(data)), data))
        self.g.write(a, data)

    def _put_tag(self, pilot, name, ready, face):
        name = ''.join(c for c in name if 32 <= ord(c) < 127).strip()[:20] or 'Player 2'
        names = self._find_names()
        if names:
            self.g.write(NAME_AT, (name + ('  READY' if ready else '')).encode('ascii') + b'\0')
            self._write(names + 2 + 4 * pilot, struct.pack('<I', (NAME_AT - names) & 0xFFFFFFFF))
        self.face_done = False
        if face:
            self._put_face(pilot, face)
        self._undo_save()

    def _put_face(self, pilot, face):
        faces = self._find_faces() if len(face) == 64 * 64 * 3 else 0
        if not faces:
            return False
        offs = struct.unpack_from('<34I', self.faces_file, 2)
        spare = offs[SPARE_FACES[0]]
        if offs[SPARE_FACES[1] + 1] - spare < 0x1C + 4096:
            return False
        self._write(faces + spare, self._face_frame(face))
        self._write(faces + 2 + 4 * pilot, struct.pack('<I', spare))
        self._undo_save()
        self.face_done = True
        return True

    def untag(self):
        """puts back what _put_tag changed (only where memory still holds what it wrote: the screen may be gone)"""
        for a, old, new in reversed(self.undo):
            if self.g.read(a, len(new)) == new:
                self.g.write(a, old)
        self.undo = []
        self.tag = None
        self.face_done = False
        self._undo_save()

    def _find_names(self):
        """resource 364 (pilot names) in memory: the start of its strings, as coop_name.py finds it"""
        first = b'N. ap Io\x00B. ap Io\x00'
        for chunk in range(0x400000, 0x1000000, 0x100000):
            m = self.g.read(chunk, 0x100000 + 32)
            i = m.find(first) if m else -1
            if i >= 0:
                base = chunk + i - 0x3A2
                if self.u16(base) > 230 and struct.unpack('<I', self.g.read(base + 2, 4))[0] == 0x3A2:
                    return base
        return 0

    def _find_faces(self):
        """RESBASE 215 in memory (loaded while the outfitting screen is up), by its first bytes on disk"""
        if len(self.faces_file) < 64:
            return 0
        for chunk in range(0x400000, 0x2000000, 0x100000):
            m = self.g.read(chunk, 0x100000 + 64)
            i = m.find(self.faces_file[:64]) if m else -1
            if i >= 0:
                return chunk + i
        return 0

    def _face_frame(self, rgb):
        """his avatar as a raw 64 x 64 portrait in the screen's colours (those the portraits use), with the blue
        frame the game's portraits have"""
        import lgres
        pal = self.g.read(PALETTE, 768)
        used = set()
        for f in lgres.frames(self.faces_file)[:15]:   # the colours of the campaign pilots' portraits
            used |= set(f[0x1C:])
        cols = [(i, pal[3 * i], pal[3 * i + 1], pal[3 * i + 2]) for i in sorted(used) if i]
        frame_col = min(range(256), key=lambda i: (pal[3 * i] - 16) ** 2 + (pal[3 * i + 1] - 32) ** 2 + (pal[3 * i + 2] - 200) ** 2)
        out, memo = bytearray(), {}
        for y in range(64):
            for x in range(64):
                if x < 2 or y < 2 or x > 61 or y > 61:
                    out.append(frame_col)
                    continue
                j = 3 * (y * 64 + x)
                c = tuple(rgb[j:j + 3])
                if c not in memo:
                    memo[c] = min(cols, key=lambda q: (q[1] - c[0]) ** 2 * 3 + (q[2] - c[1]) ** 2 * 4 + (q[3] - c[2]) ** 2 * 2)[0]
                out.append(memo[c])
        hdr = bytearray(0x1C)
        hdr[4] = 2                                   # raw pixels
        struct.pack_into('<HHHBB', hdr, 8, 64, 64, 64, 6, 6)
        return bytes(hdr) + bytes(out)

    def _undo_save(self):
        try:
            if not self.undo:
                if os.path.exists(UNDO):
                    os.remove(UNDO)
                return
            os.makedirs(os.path.dirname(UNDO), exist_ok=True)
            json.dump([(a, old.hex(), new.hex()) for a, old, new in self.undo], open(UNDO, 'w'))
        except OSError:
            pass

    def _undo_old_run(self):
        """a bridge closed hard left the guest's name / face pointers in the game: put back (if still there)"""
        try:
            u = json.load(open(UNDO))
        except (OSError, ValueError):
            return
        self.undo = [(a, bytes.fromhex(o), bytes.fromhex(n)) for a, o, n in u]
        self.untag()
        print('lobby: the guest\'s name and face from a closed session put back', flush=True)

    # ---- the guest's requests ('L' + JSON)
    def request(self, msg, in_mission):
        """returns a short text for the log, or None"""
        act = msg.get('act')
        if act == 'chat':
            self.say('guest', msg.get('text', ''))
            return 'chat'
        if in_mission:
            return None
        if act == 'ready':
            self.ready = bool(msg.get('on')) and self.col > 0
            return 'ready' if self.ready else 'not ready'
        if act == 'join':
            c = int(msg.get('col', 0))
            if c not in (1, 2, 3) or not self.column(c)['on']:
                return None
            if self.locked and self.col:
                return 'join refused: locked'
            self.col, self.ready = c, False
            return 'joined column %d' % (c + 1)
        if act == 'leave':
            if self.locked:
                return 'leave refused: locked'
            self.col, self.ready = 0, False
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
