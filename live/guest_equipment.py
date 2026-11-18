# Co-op: the guest's DRONE and A.S.F. (the suit's auxiliary device), worked for his own suit as the game works the
# player's (English exe, TN+ Coop build with the call mailbox G_CALL: TerraNovaCoop coop_cave.py). Off unless
# TN_COOP_EQUIP=1 (the host's bridge).
#
# The game (found 18/11/2026 in the English exe):
#   drones        one per squad slot: word 0x396868 + 2 x slot = the drone's entity (0: none), slot = byte +7 of the
#                 suit's pilot record (0x391E50 + 0x32 k, entity at +2; 0x2665E8). The player's is slot 0. A drone
#                 entity is class 3; its type (byte +2): 0 the suit's own drone (DRONE panel), 1 the A.S.F.'s
#                 Explod-O-Drone. Launch: 0x2837B4 (al 0 / 1 the type, dx the suit's entity; it refuses while the
#                 slot has one) puts it at the suit, with the speed of the player's body (0x44134E): called with the
#                 guest's suit as the player's. The player's own launch (0x283A94, the LAUNCH DRONE button) then takes
#                 one from the suit (byte +0xDC of the suit record: drones left). A drone flies by its AI brain (entity
#                 +0x21; brain 0x3832F0 + 0x14E b): byte +0x14D = 1 lets it move (0x24BB1C), and the map's SELECT
#                 DESTINATION click (0x273347) sends it the game's move order (0x266618: eax = brain +6, edx = x | y << 16,
#                 world units, ebx = the brain's number). RECALL (Ctrl+Home, 0x283AFC) only knows the player's (slot 0,
#                 the flag 0x3968B4: the drone flies back to 0x441350 and is put away, 0x2894A0 (drone, 1), +0xDC + 1,
#                 0x283FD8): for the guest's, a move order to his suit, then the same put-away at his suit. The
#                 Explod-O-Drone flies at the entity in word 0x397C90 + 2 x slot and blows up near it (0x283FD8 on).
#                 A drone's view (the main view's entity 0x38FBE0 = the drone): its x, y, z, heading +0x1B and pitch
#                 +0x1D (positive = down; 0x26952F, live_bridge.py's sonde).
#   A.S.F.        suit record +9 how many left (dword), +0xD the device (0 Demolition pack, 1 Repair pack, 2 Auto-Doc,
#                 3 Dynamo, 4 Jump jets, 5 Backup system, 6 EM emitter, 7 Minelayer, 8 Personal shield, 9 Autoturret,
#                 10 Explod-O-Drone, 11 Dentonium: RESGAME 0x16E strings 0x30 on), +0x11 on / off, +0x12 0 = not
#                 usable. The A.S.F. button and key 5 (0x272239, 0x2761FC): a device of the one-shot mask (dword
#                 0x35BF60) is used by 0x292248 (ax the suit's entity), one of the mask 0x35BF64 is not clickable
#                 (always working), the others are switched on / off by 0x292970 (ax the entity, dl 1 on / 0 off).
#                 Both serve any suit (the AI calls them for its squadmates, 0x24AE4C); only the player's gets the
#                 computer's voice and a 0.75 s wait (0x397C98), the guest's here as a squadmate's (no voice on the
#                 host's speakers) with the same wait.
#
# The bridge (coop_guest.py) hands this module the guest window's messages ('E' + action) and keys (5 = A.S.F., Ctrl+
# Home = recall) and asks it each update for the camera (the drone's view) and a 'GEQ' state packet for his window
# (scripts/guest_equipment.gd):
#   'GEQ' + version 1 (u8) + drone entity (u16, 0 none) + its type (u8, 255 none) + drones left (u8) + drone state
#   (u8: 0 none, 1 hovering, 2 going to a point, 3 coming back) + his view through it (u8) + select destination (u8)
#   + A.S.F. device (u8, 255 none) + on (u8) + usable (u8) + kind (u8: 0 always on, 1 one-shot, 2 on / off) + the
#   panels' big layout (u8: byte 0x35A540 >> 1, the game's panel drawers' test) + left (i32) + the device's full
#   charge (i32: dword 0x442870 + 12 x device, the shield's bar 0x2725C2) + the drone's x, y, z, heading, pitch (f32,
#   game units, radians, pitch up) + the Explod-O-Drone's target (u16) + the A.S.F. message (u8, see MSG) + its time
#   left (u8, tenths of a second) + the drone panel's camera when his view is through the drone: his own eye's x, y,
#   z, heading, pitch (f32)
# His window's actions ('E' + u8, then the payload):
#   1 launch the drone  2 recall it  3 send it to x, y (2 x f32, game units)  4 view through it on / off (u8)
#   5 the A.S.F. (as the button / key 5)  6 select destination on / off (u8)
import math, os, struct, time

ENABLED = os.environ.get('TN_COOP_EQUIP') == '1'
G_ON, G_ID = 0x46C000, 0x46C002
G_CALL = 0x46C300                     # +0 1 = call, +1 as the player, +4 routine, +8 eax, +0xC edx, +0x10 ebx, +0x14 ecx,
                                      # +0x18 eax back, +0x1C calls done (u8)
CAVE_CALL_SIG = bytes.fromhex('803d00c3460000')   # "cmp byte ptr [0x46C300], 0" in the cave: the build has the mailbox
CAVE, CAVE_END = 0x46B040, 0x46C000
M, ENT = 0x3C3240, 0x25
PBA, PBA_N = 0x3A5608, 0x582
PILOTS, PILOT_N = 0x391E50, 0x32
DRONES, DRONE_TGT = 0x396868, 0x397C90
BRAINS, BRAIN_N, BRAIN_GO, BRAIN_ID = 0x3832F0, 0x14E, 0x14D, 6
ONE_SHOT, NO_CLICK = 0x35BF60, 0x35BF64
BIG_PANELS, ASF_FULL = 0x35A540, 0x442870
CLOCK = 0x446AE8
LAUNCH, MOVE, PUT_AWAY, ASF_USE, ASF_SWITCH = 0x2837B4, 0x266618, 0x2894A0, 0x292248, 0x292970
DRONES_LEFT, ASF_N, ASF_TYPE, ASF_ON, ASF_OK = 0xDC, 0x09, 0x0D, 0x11, 0x12
ASF_WAIT = 750                        # ms (the game's 0x2EE for its player)
EXPLODO = 10
HOME_AT = 5.0                         # a recalled drone this near his suit (units, flat) is put away (its AI
                                      # circles a point 3.5 to 4 units off, measured in mission 30)
KEY_5, CTRL, CTRL_R, HOME = 0x06, 0x1D, 0xE01D, 0xE047
# A.S.F. messages for his panel (the game's RESGAME 0x16E strings, 0x30 + n: his window reads them in his language)
MSG = {'used': 1, 'on': 2, 'off': 3, 'none_left': 4, 'not_now': 5, 'drone_out': 6}


def _safe(f):
    """a memory read that fails (the game ending, a stale entity) leaves the bridge running"""
    def w(*a, **k):
        try:
            return f(*a, **k)
        except (OSError, struct.error, IndexError, TypeError, ValueError):
            return None
    return w


class GuestEquipment:
    def __init__(self, guest):
        self.q = guest
        self.calls = []                   # [(routine, eax, edx, ebx, ecx, as_player, then)] waiting for the mailbox
        self.busy_t = 0.0                 # when the mailbox was last filled (a cave that never answers: dropped)
        self.ctrl = False
        self.view = False                 # his view through his drone
        self.select = False               # his next map click sends the drone there
        self.going = None                 # (x, y) the drone was sent to
        self.recall_t = 0.0               # coming back: the move order to his suit, renewed every second
        self.recalling = False
        self.asf_t = 0                    # the game clock before which his A.S.F. waits
        self.msg, self.msg_t = 0, 0.0
        self.said = None
        self.ok = None                    # the TN+ build has the call mailbox (None: not looked yet)
        self.gid = 0
        self.after = None                 # (follow-up, the calls counter when sent) of the call in the mailbox
        self.own = (0.0, 0.0, 0.0, 0.0, 0.0)   # his own eye's view (x, y, z, heading, pitch), from the bridge's step

    # ---- the game's memory
    def g(self):
        return self.q.g

    def u8(self, a):
        return self.q.g.read(a, 1)[0]

    def u16(self, a):
        return self.q.u16(a)

    def i32(self, a):
        return self.q.i32(a)

    def say(self, *a):
        self.q_print('guest equipment:', *a)

    def q_print(self, *a):
        try:
            import coop_guest
            coop_guest.print(*a, flush=True)
        except Exception:
            print(*a, flush=True)

    def suit(self, e):
        return PBA + PBA_N * struct.unpack('<h', self.q.g.read(M + ENT * e + 3, 2))[0]

    def slot(self, e):
        for k in range(4):
            r = self.q.g.read(PILOTS + PILOT_N * k, 8)
            if (r[0] | r[1]) and struct.unpack_from('<H', r, 2)[0] == e:
                return r[7] if r[7] < 4 else None
        return None

    def drone(self, e):
        """his drone's entity (0: none) and its type"""
        k = self.slot(e)
        if k is None:
            return 0, 255
        d = self.u16(DRONES + 2 * k)
        if not 0 < d < self.q.nent:
            return 0, 255
        r = self.q.g.read(M + ENT * d, 3)
        if not r[0] or r[1] != 3:
            return 0, 255
        return d, r[2]

    def pos(self, e):
        return tuple(self.i32(M + ENT * e + o) / 65536 for o in (0x0F, 0x13, 0x17))

    def have_mailbox(self):
        if self.ok is None:
            code = self.q.g.read(CAVE, CAVE_END - CAVE) or b''
            self.ok = CAVE_CALL_SIG in code
            if not self.ok:
                self.say('this TN+ Coop build has no call mailbox (G_CALL): drone and A.S.F. off for the guest')
        return self.ok

    # ---- the mailbox
    def call(self, routine, eax=0, edx=0, ebx=0, ecx=0, as_player=False, then=None):
        self.calls.append((routine, eax, edx, ebx, ecx, as_player, then))

    def pump(self):
        g = self.q.g
        if not self.calls:
            return
        if g.read(G_CALL, 1)[0] or self.after:
            if time.time() - self.busy_t > 2.0:            # the cave did not run (no guest pass): forget it
                g.write(G_CALL, b'\x00')
                self.say('call not taken by the cave')
                self.after = None
            return
        routine, eax, edx, ebx, ecx, as_player, then = self.calls.pop(0)
        g.write(G_CALL + 1, bytes([1 if as_player else 0]) + bytes(2) +
                struct.pack('<5I', routine, eax & 0xFFFFFFFF, edx & 0xFFFFFFFF, ebx & 0xFFFFFFFF, ecx & 0xFFFFFFFF))
        self.after = (then, g.read(G_CALL + 0x1C, 1)[0])
        g.write(G_CALL, b'\x01')
        self.busy_t = time.time()

    def answered(self):
        """the last call's own follow-up, once the cave has done it"""
        a, g = self.after, self.q.g
        if a and g.read(G_CALL, 1)[0] == 0 and g.read(G_CALL + 0x1C, 1)[0] != a[1]:
            self.after = None
            if a[0]:
                a[0](struct.unpack('<I', g.read(G_CALL + 0x18, 4))[0])

    # ---- the guest's actions
    @_safe
    def key(self, sc, down, active):
        if not ENABLED:
            return False
        if sc in (CTRL, CTRL_R):
            self.ctrl = bool(down)
            return False
        if not (down and active and self.q.gid):
            return False
        if sc == KEY_5:
            self.asf()
            return True
        if sc == HOME and self.ctrl:
            self.recall()
            return True
        return False

    @_safe
    def message(self, pk, active):
        """'E' + action from his window"""
        if not ENABLED or len(pk) < 2 or not active or not self.q.gid:
            return
        a = pk[1]
        if a == 1:
            self.launch()
        elif a == 2:
            self.recall()
        elif a == 3 and len(pk) >= 10:
            x, y = struct.unpack_from('<2f', pk, 2)
            self.send_to(x, y)
        elif a == 4 and len(pk) >= 3:
            self.view = bool(pk[2]) and self.drone(self.q.gid)[0] != 0
        elif a == 5:
            self.asf()
        elif a == 6 and len(pk) >= 3:
            self.select = bool(pk[2]) and self.drone(self.q.gid)[0] != 0

    def launch(self):
        e = self.q.gid
        if not self.have_mailbox():
            return
        d, t = self.drone(e)
        p = self.suit(e)
        if d:
            self.say('a drone is out already (%d, type %d)' % (d, t))
            return
        if self.u8(p + DRONES_LEFT) == 0:
            self.say('no drone left')
            return

        def done(r):
            if r & 0xFF:
                left = self.u8(p + DRONES_LEFT)
                self.q.g.write(p + DRONES_LEFT, bytes([max(0, left - 1)]))
                self.select, self.going, self.recalling = True, None, False
                self.say('drone launched (%d), %d left' % (self.drone(e)[0], max(0, left - 1)))
            else:
                self.say('drone launch refused by the game')
        self.call(LAUNCH, 0, e, as_player=True, then=done)

    def brain(self, d):
        return self.u8(M + ENT * d + 0x21)

    def go(self, d, x, y):
        b = self.brain(d)
        if not b:
            return False
        self.q.g.write(BRAINS + BRAIN_N * b + BRAIN_GO, b'\x01')   # (0x24BB1C: the brain may move it)
        xi, yi = max(1, min(511, int(x))), max(1, min(511, int(y)))
        self.call(MOVE, self.u8(BRAINS + BRAIN_N * b + BRAIN_ID), xi | yi << 16, b)
        return True

    def send_to(self, x, y):
        d, t = self.drone(self.q.gid)
        if not d or t != 0 or not self.have_mailbox():
            return
        if self.go(d, x, y):
            self.going, self.select, self.recalling = (x, y), False, False
            self.say('drone %d sent to %.0f, %.0f' % (d, x, y))

    def recall(self):
        d, t = self.drone(self.q.gid)
        if not d or t != 0 or not self.have_mailbox():
            return
        self.recalling, self.recall_t, self.select, self.going = True, 0.0, False, None
        self.say('drone %d recalled' % d)

    def asf(self):
        e = self.q.gid
        if not self.have_mailbox():
            return
        p = self.suit(e)
        n = self.i32(p + ASF_N)
        t = self.i32(p + ASF_TYPE)
        if t < 0 or t > 31:
            return
        if n == 0:
            self.note('none_left')
            return
        clk = self.i32(CLOCK)
        if clk < self.asf_t:
            return
        bit = 1 << t
        if self.i32(ONE_SHOT) & bit:
            def done(r):
                if r & 0xFF:
                    self.asf_t = self.i32(CLOCK) + ASF_WAIT
                    self.note('used')
                    self.say('A.S.F. %d used, %d left' % (t, self.i32(p + ASF_N)))
                else:
                    self.note('drone_out' if t == EXPLODO and self.drone(e)[0] else 'not_now')
                    self.say('A.S.F. %d refused by the game' % t)
            self.call(ASF_USE, e, then=done)
        elif not self.u16(NO_CLICK) & bit:
            on = 0 if self.u8(p + ASF_ON) else 1

            def done(r):
                if r & 0xFF:
                    self.note('on' if on else 'off')
                    self.say('A.S.F. %d %s' % (t, 'on' if on else 'off'))
            self.call(ASF_SWITCH, e, on, then=done)

    def note(self, m):
        self.msg, self.msg_t = MSG[m], time.time()

    # ---- each update
    @_safe
    def tick(self, active):
        if not ENABLED:
            return
        e = self.q.gid
        if e != self.gid:                                  # another suit: nothing of the last one's
            self.gid, self.view, self.select, self.going, self.recalling = e, False, False, None, False
            self.calls = []
        if not active or not e:
            self.view = False
            return
        if self.ok is None and not self.have_mailbox():
            return
        if not self.ok:
            return
        self.answered()
        d, t = self.drone(e)
        if not d:
            self.view = self.select = self.recalling = False
            self.going = None
        elif t == 0 and self.recalling and time.time() - self.recall_t > 1.0 and not self.calls:
            self.recall_t = time.time()
            dx, dy, _ = self.pos(d)
            gx, gy, _ = self.pos(e)
            if math.hypot(dx - gx, dy - gy) < HOME_AT:
                p = self.suit(e)

                def done(_r, p=p, d=d):
                    if not self.drone(e)[0]:
                        self.q.g.write(p + DRONES_LEFT, bytes([min(255, self.u8(p + DRONES_LEFT) + 1)]))
                        self.say('drone %d back in the suit' % d)
                self.call(PUT_AWAY, d, 1, then=done)
                self.recalling = False
            else:
                self.go(d, gx, gy)
        elif t == 1:
            k = self.slot(e)
            if k is not None and not self.u16(DRONE_TGT + 2 * k) and self.q.lock:
                self.q.g.write(DRONE_TGT + 2 * k, struct.pack('<H', self.q.lock))   # (the game's 0x273252 for its player)
                self.say('Explod-O-Drone %d goes for %d' % (d, self.q.lock))
        self.pump()

    @_safe
    def camera(self, own=None):
        """his view through his drone: (x, y, z, heading, pitch, the drone) or None; own: his own eye's view (the drone
        panel shows it meanwhile)"""
        if own:
            self.own = own
        if not (ENABLED and self.view and self.q.gid):
            return None
        d, _ = self.drone(self.q.gid)
        if not d:
            self.view = False
            return None
        r = self.q.g.read(M + ENT * d + 0x0F, 0x10)
        x, y, z = (v / 65536 for v in struct.unpack_from('<3i', r, 0))
        h = struct.unpack_from('<H', r, 0x0C)[0] / 65536 * 2 * math.pi
        p = -struct.unpack_from('<h', r, 0x0E)[0] / 65536 * 2 * math.pi
        return x, y, z, h, p, d

    @_safe
    def packet(self):
        if not (ENABLED and self.q.gid):
            return None
        e = self.q.gid
        p = self.suit(e)
        d, t = self.drone(e)
        st = 0 if not d else 3 if self.recalling else 2 if self.going else 1
        at = (0.0,) * 5
        if d:
            r = self.q.g.read(M + ENT * d + 0x0F, 0x10)
            at = tuple(v / 65536 for v in struct.unpack_from('<3i', r, 0)) + (
                struct.unpack_from('<H', r, 0x0C)[0] / 65536 * 2 * math.pi, -struct.unpack_from('<h', r, 0x0E)[0] / 65536 * 2 * math.pi)
        k = self.slot(e)
        tgt = self.u16(DRONE_TGT + 2 * k) if d and t == 1 and k is not None else 0
        n, at_ = self.i32(p + ASF_N), self.i32(p + ASF_TYPE)
        kind, full = 0, 0
        if 0 <= at_ < 32:
            kind = 1 if self.i32(ONE_SHOT) & (1 << at_) else 0 if self.u16(NO_CLICK) & (1 << at_) else 2
            full = self.i32(ASF_FULL + 12 * at_) if at_ < 12 else 0
        msg_left = max(0.0, 2.5 - (time.time() - self.msg_t)) if self.msg else 0.0
        return b'GEQ' + struct.pack('<BHBBBBBBBBBBii5fHBB5f', 1, d, t if d else 255, self.u8(p + DRONES_LEFT), st,
                                    1 if self.view else 0, 1 if self.select else 0, at_ if 0 <= at_ < 255 else 255,
                                    self.u8(p + ASF_ON), self.u8(p + ASF_OK), kind, 1 if self.u8(BIG_PANELS) >> 1 else 0,
                                    n, full, *at, tgt, self.msg if msg_left else 0, int(msg_left * 10), *self.own)
