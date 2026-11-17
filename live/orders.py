# Squad orders for Uplink's order wheel (the launcher's "Order wheel", TN_ORDER_WHEEL): the viewer says which order,
# for whom and on what (packet 'O', see live_bridge.py), the bridge gives it to the running game with the game's own
# keys, as the player would: the COMM menu's F keys.
#
# What the game has (English exe; the French one has the same code, its data elsewhere: all found by code signatures):
# - the COMM menu: F4 the entire squad (F1 / F2 / F3: one squadmate), then F1 MOVEMENT (F2 follow me, F4 go to nav
#   point), F2 TACTICS (F4 take cover, F5 retreat, F6 assume formation, F7 stay at location) or F3 ENGAGEMENT (F1
#   attack my target). A byte tells it is open, a dword which menu it shows; Esc closes it.
# - one order block: word +0 the order's code, +2 flags, +4 who, +8 the target, +0xC a parameter. The code stays there
#   after the order is sent: emptied before the keys, it tells that the game took them. The tactics are one code,
#   0x0A, with a parameter (4 take cover, 5 retreat, 6 formation, 7 stay at location); follow me is 0x07.
# - ATTACK MY TARGET (code 0x13) reads the player's lock (a word: the entity, 0 none); GO TO NAV POINT (code 0x0D)
#   reads the nav marker (x, y as 16.16, 0 = not placed). To send the squad on what the player aims at, the lock or
#   the marker is set to it for the time of the keys (about 50 ms), then put back as it was.
# - the Alt hotkeys (Alt+M follow me...) are NOT used: they go to the group of the squadmate last picked in the COMM
#   panel only. Once a squadmate has been given an order of his own he is a group of his own, and "the entire squad"
#   by hotkey no longer reached him (seen: one of three left behind). F4 reaches every group.
# The keys are the game's own (US positions). Terra Nova Plus lets the player move them: its table in the game says
# which key he must press for each (128 keys x none / Shift / Ctrl / Alt), read here before each order.
import re, struct, threading, time

ATTACK, MOVE, COVER, RETREAT, FOLLOW, HOLD, FORM = range(7)       # (FORM: assume formation, the bridge's own use)
NAMES = ('attack target', 'move there', 'take cover', 'retreat', 'follow me', 'hold position')
F1, F2, F3, F4, F5, F6, F7, ESC = 0x3B, 0x3C, 0x3D, 0x3E, 0x3F, 0x40, 0x41, 0x01
SHIFT, CTRL, ALT = 1, 2, 3
MOD_KEY = {SHIFT: 0x2A, CTRL: 0x1D, ALT: 0x38}
# the COMM menu's two keys, after the one that names who (F4 the entire squad, F1 - F3 a squadmate)
MENU = {ATTACK: (F3, F1), MOVE: (F1, F4), COVER: (F2, F4), RETREAT: (F2, F5), FOLLOW: (F1, F2), HOLD: (F2, F7),
        FORM: (F2, F6)}
# what the order block shows once the game has taken it: code, parameter (None: any)
TAKEN = {ATTACK: (0x13, None), MOVE: (0x0D, None), COVER: (0x0A, 4), RETREAT: (0x0A, 5), FOLLOW: (0x07, None),
         HOLD: (0x0A, 7), FORM: (0x0A, 6)}
OK, BUSY, NO_SQUAD, NO_TARGET, NO_KEY, NOT_TAKEN, NO_GAME = range(7)
WHY = ('sent', 'another order is being sent', 'no squad', 'no target', 'a key of it has no place on the keyboard',
       'the game did not take it', 'the game\'s order code was not found')
KB_ACTIVE, KB_MAP = 0x469A10, 0x469B30       # Terra Nova Plus's key table in the game (TNPlusKeys.cs)
TAP = (0.015, 0.4)                           # a key is held until the game has taken it: at least, at most (seconds)


def _find(code, *parts):
    """the addresses a code pattern holds (None: an address), from the match where they are the game's data"""
    pat = b''.join(b'(....)' if p is None else p if isinstance(p, bytes) else re.escape(bytes.fromhex(p)) for p in parts)
    for m in re.finditer(pat, code, re.S):
        v = [struct.unpack('<I', b)[0] for b in m.groups()]
        if all(0x300000 <= a < 0x500000 for a in v): return v
    return None


class Orders:
    def __init__(self, g, code, master, pid, post_key, tnp_keys=lambda: False, mods=None, log=print):
        """g: the game's memory; code: its code as read at 0x200000; master: its entity table; pid: the dword whose
        high word is the player's entity; post_key(scancode, down): a key to the game; tnp_keys(): Terra Nova Plus's
        key translation is in place; mods(): the Shift, Ctrl and Alt the player holds are let go in the game, their
        list returned; mods(list): those he still holds are pressed again"""
        self.g, self.master, self.pid, self.post_key, self.tnp_keys, self.log = g, master, pid, post_key, tnp_keys, log
        self.mods = mods
        self.busy = threading.Lock()
        self.typing = False                   # its keys are going: the bridge repeats no held key meanwhile
        self.kept = None                      # (address, bytes) written again whenever the game changes them, while an order goes
        self.rewrites = 0
        self.nav_set = False                  # the nav marker is the order's for a moment: not the player's
        # mov ax, [lock] / mov bl, bh / mov [ecx + 8], ax / and ebx, 0xff
        v = _find(code, '66a1', None, '88fb6689410881e3ff000000')
        self.lock = v[0] if v else None
        # mov ax, [esi + 0xc] / mov [order], ax / mov ax, [who] / mov [order + 4], ax / mov ax, [group]
        v = _find(code, '668b460c66a3', None, '66a1', None, '66a3', None, '66a1', None)
        self.order = v[0] if v and v[2] == v[0] + 4 else None
        # mov ah, 1 / xor edx, edx / mov [comm open], ah / mov [order + 2], dx / mov edx, [squad count]
        v = _find(code, 'b40131d28825', None, '668915', None, '8b15', None)
        self.comm, self.count = (v[0], v[2]) if v and v[1] == (self.order or 0) + 2 else (None, None)
        # mov edx, [nav x] / mov [squad count], esi / test edx, edx / je / mov edi, [nav y] / test edi, edi
        v = _find(code, '8b15', None, '8935', None, '85d27451', '8b3d', None, '85ff')
        self.nav = v[0] if v and v[2] == v[0] + 4 else None
        # imul eax, r, 0x14e / cmp byte [eax + AI records], 0 / je / cmp byte [eax + AI records + 5], 1 or 2
        v = _find(code, '69', b'[\xc0-\xc7]', '4e01000080b8', None, '0074', b'.', '80b8', None, b'[\x01\x02]')
        self.ai = v[0] if v and v[1] == v[0] + 5 else None
        self.ok = None not in (self.lock, self.order, self.comm, self.count, self.nav, self.ai)
        # the AI groups, 0x170 bytes each (+0xCB: the tactic in force, 9 = retreat): imul eax, eax, 0x170 /
        # cmp byte [eax + groups + 0xCB], 4. A squadmate's group: byte +6 of his AI record. (Not found: see _send, MOVE)
        v = _find(code, '69c07001000080b8', None, '04')
        self.groups = v[0] - 0xCB if v else None
        # the lock's own test, at each of the game's pictures: the target within the sensor range of the suit the
        # player drives (a dword of its record, in metres as 16.16; 6 metres to a unit), else the lock is dropped:
        # mov edx, [player] / sar edx, 16 / imul edx, 0x582 / mov ecx, eax / mov eax, [edx + range] / mov edx, eax /
        # mov esi, 6. (Not found: the lock is only written again each time it is dropped, see _send)
        v = _find(code, '8b15', None, 'c1fa1069d28205000089c18b82', None, '89c2be06000000')
        self.suit, self.range = (v[0] + 2, v[1]) if v else (None, None)
        self.pilots = (self.count or 0) + 4   # 4 records of 0x32 bytes: +0 in use, +2 entity, +6 the pilot's name
        log('orders: lock %s, order %s, COMM %s, squad %s, nav %s, AI %s' % tuple(
            '%#x' % a if a else 'not found' for a in (self.lock, self.order, self.comm, self.count, self.nav, self.ai)))

    # ------------------------------------------------------------------ reading
    def u8(self, a): return self.g.read(a, 1)[0]
    def u16(self, a): return struct.unpack('<H', self.g.read(a, 2))[0]
    def u32(self, a): return struct.unpack('<I', self.g.read(a, 4))[0]

    def squad(self):
        """(the squad's count, the player included; his squadmates: [k, entity, pilot's name] for the game's F<k>)"""
        n = self.u32(self.count)
        if not 1 < n <= 4: return (n if 0 <= n <= 4 else 0, [])
        rec = self.g.read(self.pilots, 0x32 * 4)
        return (n, [(k, struct.unpack_from('<H', rec, 0x32 * k + 2)[0], rec[0x32 * k + 6]) for k in range(1, n)
                    if rec[0x32 * k]])

    def tactic(self, ent):
        """the tactic in force for a squadmate's group (None: not known)"""
        if self.groups is None: return None
        b = self.u8(self.master + 0x25 * ent + 0x21)
        return self.u8(self.groups + 0x170 * self.u8(self.ai + 0x14E * b + 6) + 0xCB) if b else None

    def enemies(self, tab, nent):
        """the entities an order can be given on: alive, with an AI record that is not on the player's side"""
        ai = self.g.read(self.ai, 0x14E * 256)
        me = self.u16(self.pid + 2)
        mine = ai[0x14E * tab[0x25 * me + 0x21] + 5] if me < nent and tab[0x25 * me + 0x21] else 1
        out = []
        for i in range(nent):
            b = tab[0x25 * i + 0x21]
            if tab[0x25 * i] and b and tab[0x25 * i + 1] <= 4 and ai[0x14E * b] and ai[0x14E * b + 5] != mine:
                out.append(i)
        return out

    def status(self, tab, nent, in_mission):
        """the viewer's 'ORDS' packet: can an order be given (bit 0), the squad's count, the player's lock, his three
        squadmates (in use, entity, pilot's name), then the entities that can be attacked"""
        if not self.ok: return b'ORDS' + bytes(18)
        n, mates = self.squad() if in_mission else (0, [])
        by_k = {k: (e, p) for k, e, p in mates}
        en = self.enemies(tab, nent) if in_mission and n > 1 else []
        lock = self.u16(self.lock) if in_mission else 0
        pk = struct.pack('<BBH', 1 if n > 1 and mates else 0, n, lock)
        for k in (1, 2, 3):
            e, p = by_k.get(k, (0, 0))
            pk += struct.pack('<BHB', 1 if k in by_k else 0, e, p)
        return b'ORDS' + pk + struct.pack('<H%dH' % len(en), len(en), *en)

    # ------------------------------------------------------------------ keys
    def key_for(self, sc, mod):
        """the key (scancode, modifier) the player's keyboard has for the game's (sc, mod): his own when Terra Nova
        Plus moved it (its table: key * 4 + modifier -> 0x8000 | the game's key | its modifier << 8; 0x80FF: a key
        that gives nothing any more). None: the game's key has no place left"""
        try:
            if not self.tnp_keys() or not self.u32(KB_ACTIVE): return (sc, mod)
            tb = struct.unpack('<512H', self.g.read(KB_MAP, 1024))
        except BaseException:
            return (sc, mod)
        want = 0x8000 | sc | (mod << 8)
        for i, w in enumerate(tb):
            if w == want: return (i >> 2, i & 3)
        return (sc, mod) if tb[sc * 4 + mod] == 0 else None

    def tap(self, sc, mod, taken=lambda: False):
        """the game's key (sc, mod) pressed, held until taken() (the game has seen it: 5 to 15 ms; the COMM menu is on
        the centre panel for as short as can be), and let go, with its modifier if the player gave it one (his own
        Shift, Ctrl and Alt are up meanwhile: see _send). None: the key has no place on the keyboard; else whether
        the game took it"""
        k = self.key_for(sc, mod)
        if k is None: return None
        mk = MOD_KEY.get(k[1], 0)
        if mk: self.post_key(mk, True)
        self.post_key(k[0], True)
        t0 = time.time()
        ok = self.wait(taken, TAP[1])
        self.wait(lambda: False, TAP[0] - (time.time() - t0))
        self.post_key(k[0], False)
        if mk: self.post_key(mk, False)
        return ok

    def wait(self, test, s):
        """until test() or s seconds; meanwhile what is kept (the lock given to the game) is written again as soon as
        the game changes it"""
        end = time.time() + s
        while time.time() < end:
            if self.kept is not None:
                if self.g.read(self.kept[0], len(self.kept[1])) != self.kept[1]:
                    self.g.write(*self.kept); self.rewrites += 1
                if test(): return True
                time.sleep(0)
            else:
                if test(): return True
                time.sleep(0.004)
        return test()

    # ------------------------------------------------------------------ sending
    def target_ok(self, ent, nent=300):
        tab = self.g.read(self.master, 0x25 * nent)
        return 0 < ent < nent and ent in self.enemies(tab, nent)

    def send(self, order, who=0, kind=0, ent=0, x=0.0, y=0.0, done=None):
        """an order on its way (a thread of its own: up to half a second). who: 0 the entire squad, 1-3 squadmate k;
        kind: 1 on the entity ent, 2 on the point x, y, 0 on nothing (attack: the player's own lock).
        done(result, the order block's code)"""
        def run():
            res, code = BUSY, 0
            if self.busy.acquire(False):
                try:
                    res, code = self._send(order, who, kind, ent, x, y)
                except BaseException as ex:
                    res = NOT_TAKEN
                    self.log('orders: %r' % (ex,))
                finally:
                    self.busy.release()
            self.log('order %s to %s: %s (code %#x)' % (NAMES[order] if 0 <= order < 6 else order,
                                                        'squadmate %d' % who if who else 'the squad', WHY[res], code))
            if done: done(res, code)
        threading.Thread(target=run, daemon=True).start()

    def _keys(self, order, who):
        """the keys of one order, and whether the game's order block then shows it"""
        g = self.g
        g.write(self.order, bytes(2))
        taken = lambda: self.u16(self.order) != 0
        if self.u8(self.comm):                           # the COMM menu is open: closed first (its keys are the menu's)
            if not self.tap(ESC, 0, lambda: not self.u8(self.comm)): return NOT_TAKEN
        for i, sc in enumerate((F1 + who - 1 if who else F4,) + MENU[order]):
            was = g.read(self.comm, 11)                  # (open, who, group, the menu shown)
            ok = self.tap(sc, 0, taken if i == 2 else lambda: g.read(self.comm, 11) != was and self.u8(self.comm))
            if ok is None: return NO_KEY
            if not ok: break                             # (a menu left half way is closed below)
        # (the game writes the block's code first, then who and what, then sends it and closes the menu: read once it
        # has closed, a moment later; the lock is still kept meanwhile)
        self.wait(lambda: not self.u8(self.comm), 0.2)
        self.wait(lambda: False, 0.01)
        code, par = self.u16(self.order), self.u16(self.order + 0xC)
        want = TAKEN[order]
        if code != want[0] or (want[1] is not None and par != want[1]):
            if self.u8(self.comm):                       # (a menu left half way)
                self.tap(ESC, 0, lambda: not self.u8(self.comm))
            return NOT_TAKEN
        return OK

    def _send(self, order, who, kind, ent, x, y):
        g = self.g
        if not self.ok: return (NO_GAME, 0)
        if not 0 <= order <= HOLD: return (NOT_TAKEN, 0)
        n, mates = self.squad()
        if n <= 1 or (who and who not in [m[0] for m in mates]): return (NO_SQUAD, 0)
        put_back = []                                    # (address, the bytes that were there)
        # the Shift, Ctrl and Alt the player holds (the run's Shift with a move key, an Alt of his own: F4 would be
        # Alt + F4) are up in the game for the time of the keys, and no held key is repeated meanwhile
        self.typing = True
        away = self.mods() if self.mods else []
        try:
            if order == ATTACK:
                if kind == 1:
                    if not self.target_ok(ent): return (NO_TARGET, 0)
                    # The game drops, at each of its pictures, a lock that is not within the suit's sensor range (140 m,
                    # 23 units) or among its known contacts. For the time of the keys the range is as wide as the map
                    # (nothing else reads it but the list of who shoots at the player), and the lock is written again
                    # should the game still drop it.
                    if self.range is not None:
                        a = self.range + 0x582 * self.u16(self.suit)
                        put_back.append((a, g.read(a, 4)))
                        g.write(a, struct.pack('<i', 0x7FFF0000))
                    put_back.insert(0, (self.lock, g.read(self.lock, 2)))    # (put back first, the range after it)
                    self.kept = (self.lock, struct.pack('<H', ent))
                    g.write(*self.kept)
                elif not self.u16(self.lock): return (NO_TARGET, 0)
            if order == MOVE:
                if kind != 2 or not (10 <= x <= 502 and 10 <= y <= 502): return (NO_TARGET, 0)
                put_back.append((self.nav, g.read(self.nav, 8)))
                self.nav_set = True
                g.write(self.nav, struct.pack('<2i', (int(x) << 16) + 0x8000, (int(y) << 16) + 0x8000))
            # Told to retreat, a squad sent to a point stops after a few steps (measured: 6 units short, back near
            # the player; from any other tactic the game itself turns them to "aggressive" and they go). They are
            # first told to assume formation, from which the order to go is taken as usual.
            if order == MOVE and any(self.tactic(e) == 9 for k, e, p in mates if who in (0, k)):
                r = self._keys(FORM, who)
                if r != OK: return (r, self.u16(self.order))
            r = self._keys(order, who)
            if r != OK: return (r, self.u16(self.order))
            if order == ATTACK and kind == 1 and self.u16(self.order + 8) != ent:
                r = self._keys(order, who)               # (taken while the lock was dropped: given once more)
                if r != OK: return (r, self.u16(self.order))
            code = self.u16(self.order)
            on = struct.unpack('<2H', g.read(self.order + 8, 4))
            if (order == ATTACK and kind == 1 and on[0] != ent) or (order == MOVE and on != (int(x), int(y))):
                return (NOT_TAKEN, code)
            return (OK, code)
        finally:
            self.kept = None
            for a, b in put_back: g.write(a, b)
            self.nav_set = False
            if self.mods: self.mods(away)
            self.typing = False
