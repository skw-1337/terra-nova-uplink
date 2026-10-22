# Coop (TN+ Coop build only): a second player drives a teammate and sees through his eyes in a second Uplink window.
# TN+ Coop puts the coop code in the game at the main menu (code 0x46B040); this module picks the teammate, sends the
# guest's commands, aim and fire to the game (data page 0x46C000) and the guest's camera to his window (port 47831).
# Input: an XInput gamepad (left stick move / strafe, right stick look, right trigger fire) or the guest window
# itself (W/S/A/D, mouse, left button, F8 = next teammate), on port 47834. Online (--guest-remote) the local pad is not
# read: the guest window's coop_net.gd sends its own gamepad as 'P' packets (lx, ly, rx, ry int8 with XInput signs,
# fire 0 / 1), used only while fresh (0.3 s). The guest window's HUD gets 'GHD' packets (coop_hud.gd). Online the
# view goes as coop_view.py messages (keyframes, deltas, decor), view_hz a second; 'R' from the guest: decor again.
import builtins, ctypes, json, math, os, socket, struct, time, zlib
import coop_lobby, coop_view
from coop_name import NameTag

CAVE = 0x46B040
G_ON, G_FIRE, G_ID, G_TIM, G_CTRL, G_TGT = 0x46C000, 0x46C001, 0x46C002, 0x46C010, 0x46C020, 0x46C048
G_HIT = 0x46C200                  # 1v1 hit mailbox (TN+ Coop coop3): 1, +2 entity hit, +6 the guest's projectile that hit it
# versus: the guest's shots never collide with the host, so the bridge watches them (projectile entities: class 5, record
# 0x39BDF0 + n*0x1E, +6 the shooter, +0x16 range left) and sends the game a hit for one that crosses the host's body; the
# game then does the rest (damage by weapon, side hit, shield, armour, death). Spent ones (range 0) are retired (range -1)
# or they pile up and the guest cannot fire any more
PROJ, PROJ_N = 0x39BDF0, 0x1E
HIT_R, HIT_Z = 0.9, (-0.2, 2.6)    # the host's body: radius, height from his feet
G_JUMP, G_JV = 0x46C004, 0x46C120  # jump mailbox (TN+ Coop 1.2.2-coop2 and later): 1 = jump with speed G_JV (16.16)
SHIFT = {0x2A, 0x36}              # Shift + a direction key: the game's directional jump
JUMP_DIR = {0x11: 0.0, 0x1F: math.pi, 0x1E: math.pi / 2, 0x20: -math.pi / 2}   # W S A D: angle from the heading
HEAT = 0x3C8                      # suit record: the game jumps only while this is under 0x30000
# Lock (right button, gamepad RB): the unit nearest the middle of his view (within 12 degrees, 250 units), not one
# of the squad; while it stays within 30 degrees of his view his shots aim at its middle. Right button again: off.
LOCK_PICK, LOCK_KEEP, LOCK_RANGE = math.radians(12), math.radians(30), 120.0   # range: 1.2 km (2.5 km picked targets out of sight)
# side angle as above; up / down much wider: the guest rarely aims his pitch at a unit on another level (the arena's
# terraces put the host 30 degrees below him at 8 units)
LOCK_PICK_V, LOCK_KEEP_V = math.radians(45), math.radians(60)
LIVE_PORT, PLAY_PORT = 47831, 47834
REMOTE_VIEW = 47841           # online guest (--guest-remote): the host window's coop_net.gd sends it over Steam
KEYS = {0x11, 0x1F, 0x1E, 0x20, 0x39}   # the only keys a guest can hold: W S A D, Space (network input is filtered)
JET_ACC, JET_DRAIN = float(os.environ.get('TN_JET_ACC', '1600')), 1000   # Space held: the jets' push (speed units/s
                                  # per s) and their energy cost per s, the host's (his 1250 last 1.25 s)
JUMP_ACC = [float(v) for v in os.environ.get('TN_JUMP_ACC', '2000,4500').split(',')]   # a jump's push: flat, up
JUMP_T, JUMP_COST = 0.3, 150      # for 0.3 s, and its energy
F8 = 0x42                     # next teammate
DROPSHIP = 0x1C               # Enter: the game's "Call dropship" key, posted to the host's game (the mission's end)
WEAPON_KEYS = {0x02: 0, 0x03: 1, 0x04: 2, 0x05: 3}   # 1-4: weapon slot (suit record +0xCE, the fire uses it)
SEL, SLOTS, SLOT_N = 0xCE, 0x45, 0xF                # selected slot, 4 weapon slots (+0 type: weapon names 1-17)
HUD_PORT = 47832              # the guest window's coop_hud.gd: 'GHD' state, armour, max, entity (online: via 47841)
PBA, PBA_N, ENERGY = 0x3A5608, 0x582, 0x88   # English exe: suit records, the energy word (shots draw from it)
PARTS = [(0x15 + 7 * k, 0x17 + 7 * k) for k in range(4)]   # the armour: 4 parts (+0x14 + 7k: flag, current, max, current)
SQUAD_R = 25.0                # suits this close to the player at mission start = his squad (the guest's choices)
OK, DOWN, SPECTATE = 0, 1, 2
# The guest's cockpit (coop_hud.gd) is the host's game screen (320 x 400, palette indices + alpha, see live_bridge.py
# send_hud) with what is the host's own emptied: his panels' contents, compass, bars, rear view, and anything drawn in
# the 3D window away from its frame (crosshair, target box). 'GCK' + palette + zlib(index, alpha), every 10 s.
CLEAR = [((30, 276, 108, 376), 60, 255),     # COMM panel (the guest's window draws the host's name and avatar)
         ((211, 276, 292, 376), 60, 255),    # WEAPON panel (his weapon)
         ((118, 260, 202, 368), 0, 255),     # map (his own, from above)
         ((30, 0, 290, 21), 0, 255),         # compass strip (his heading)
         ((72, 25, 162, 34), 0x28, 255),     # armour bar (his armour)
         ((162, 22, 262, 36), 0x28, 255),    # the other bar
         ((146, 222, 175, 252), 0, 255)]     # rear view


_LOG = None


def print(*a, **k):                                   # coop messages: the console and live/logs/coop_host_<date>.log
    global _LOG
    builtins.print(*a, **k)
    try:
        if _LOG is None:
            d = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logs')
            os.makedirs(d, exist_ok=True)
            _LOG = open(os.path.join(d, time.strftime('coop_host_%Y-%m-%d_%H-%M-%S.log')), 'a', encoding='utf-8')
        _LOG.write(time.strftime('[%H:%M:%S] ') + ' '.join(map(str, a)) + '\n'); _LOG.flush()
    except OSError:
        pass


class XState(ctypes.Structure):
    _fields_ = [('packet', ctypes.c_uint), ('buttons', ctypes.c_ushort), ('lt', ctypes.c_ubyte), ('rt', ctypes.c_ubyte),
                ('lx', ctypes.c_short), ('ly', ctypes.c_short), ('rx', ctypes.c_short), ('ry', ctypes.c_short)]


try:
    _xinput = ctypes.windll.xinput1_4
except OSError:
    _xinput = None


def pad():
    if not _xinput:
        return None
    s = XState()
    return s if _xinput.XInputGetState(0, ctypes.byref(s)) == 0 else None


def axis(v, dead=7849):
    if abs(v) < dead:
        return 0.0
    return max(-1.0, min(1.0, (v - math.copysign(dead, v)) / (32767 - dead)))


def launch(godot, vpath, mission):
    import subprocess
    return subprocess.Popen([godot, '--path', vpath, '--resolution', os.environ.get('TN_GUEST_RES', '1280x720')] +
                            (['--position', os.environ['TN_GUEST_POS']] if 'TN_GUEST_POS' in os.environ else []) +
                            ['--', '--live', '--live-port', str(LIVE_PORT), '--play', '--play-port', str(PLAY_PORT), '--coop-hud'] +
                            (['--coop-preview'] if os.environ.get('TN_COOP_PREVIEW') else []) +   # Steam name / avatar
                            (['--mission', mission] if mission else []))


class Guest:
    def __init__(self, g, master, pid_addr, nent, eye, sens_x, fov_now, sock, remote=False, view_hz=20.0, versus=False):
        # versus (1v1, experimental): the guest drives a suit of the other side instead of a teammate, its AI off, and
        # fights the host (his shots come from the enemy side, so they hurt); his "squad" is the enemy suits
        self.versus = versus or bool(os.environ.get('TN_COOP_VERSUS'))
        self.remote, self.sent_t, self.view_hz = remote, 0.0, max(1.0, view_hz)
        self.smoke_t, self.smoke_on = 0.0, False
        self.weather_pk, self.weather_t = b'', 0.0
        self.fx_pk, self.fx_sent, self.fx_t = b'', b'', 0.0
        self.joined = not remote                               # online: once his window speaks (coop_net.gd's 'R' / 'N')
        self.enc, self.resync_t = coop_view.Encoder() if remote else None, 0.0
        self.g, self.master, self.pid_addr, self.nent, self.eye, self.sens_x = g, master, pid_addr, nent, eye, sens_x
        self.fov_now, self.s = fov_now, sock
        self.rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rx.bind(('127.0.0.1', PLAY_PORT)); self.rx.setblocking(False)
        self.keys, self.gid, self.pitch, self.fire = set(), 0, 0.0, False
        self.rpad, self.rpad_t = None, 0.0                    # online: the guest's gamepad (lx, ly, rx, ry, fire, jets)
        self.shift, self.jump_t, self.pad_jump, self.jet_t, self.burst = False, 0.0, False, 0.0, None
        self.lock, self.lock_req, self.pad_lock = 0, False, False
        self.shots, self.hits, self.retire = {}, [], []      # versus: the guest's projectiles (last spot), hits to send
        self.amax0 = {}                                       # each teammate's armour when first seen (100 %)
        self.squad, self.state, self.down_t, self.hud_t, self.amax, self.next = [], OK, 0.0, 0.0, 1, False
        self.emax = 1
        self.tag, self.name = NameTag(g), os.environ.get('TN_GUEST_NAME', 'Player 2')   # his name on the host's HUD
        self.face = None                                      # and his Steam avatar (21 x 27 RGB) as the portrait
        self.post_key, self.drop_t = None, 0.0                   # the bridge's key poster (DOSBox window)
        self.hud_src, self.tpl_t, self.taken_t = None, 0.0, 0.0   # the bridge's last game screen, for his cockpit
        # the Mission Outfitting lobby (his column, pilot, loadout)
        self.lobby, self.lobby_t, self.lobby_msgs = coop_lobby.Lobby(g, coop_lobby.find_data(g)), 0.0, []
        self.anim = None
        try:
            from host_anim import HostAnim
            self.anim = HostAnim()
        except Exception:
            pass
        self.ready = g.read(CAVE, 4) != bytes(4)
        print('coop :', 'code in place' if self.ready else 'NOT in place (start the game with TN+ Coop, English game)', flush=True)

    def u16(self, a):
        return struct.unpack('<H', self.g.read(a, 2))[0]

    def i32(self, a):
        return struct.unpack('<i', self.g.read(a, 4))[0]

    def pilots(self):
        """entities with a pilot record (0x391e50, 4 x 0x32: the player and his squad): the player's side"""
        out = set()
        for a in range(0x391e50, 0x391f18, 0x32):
            r = self.g.read(a, 4)
            if r[0] | r[1]:
                out.add(struct.unpack_from('<H', r, 2)[0])
        return out

    def suits(self, me, enemy=False):
        """living suits but the player's, nearest first: [(distance, entity)]"""
        mx, my = struct.unpack('<ii', self.g.read(self.master + 0x25 * me + 0x0F, 8))
        tab = self.g.read(self.master, 0x25 * self.nent)
        out = []
        for i in range(1, self.nent):
            b = tab[0x25 * i:0x25 * i + 0x17]
            if b[0] and b[1] == 1 and (enemy or b[2] < 8) and i != me:
                x, y = struct.unpack_from('<ii', b, 0x0F)
                out.append((math.hypot(x - mx, y - my) / 65536, i))
        return sorted(out)

    def squad_info(self, me):
        """the guest's COMM panel: the host first, then his other living teammates: entity, armour %, pilot (name and
        portrait index in the game's tables, 255 = none)"""
        out = []
        for e in [me] + [i for i in self.squad if i != self.gid]:
            if not self.alive(e):
                continue
            full = self.amax0.setdefault(e, self.armour_max(e))
            pilot = 255
            for a in range(0x391e50, 0x391f18, 0x32):
                r = self.g.read(a, 8)
                if r[0] | r[1] and struct.unpack_from('<H', r, 2)[0] == e:
                    pilot = r[6]
            out.append(struct.pack('<HBB', e, max(0, min(100, self.armour(e) * 100 // full)), pilot))
        out = out[:3]
        # then his 4 weapon slots' types (the STATUS page) and whether a jump is allowed now (1 s apart)
        slots = bytes(self.g.read(self.suit(self.gid) + SLOTS + SLOT_N * k, 1)[0] for k in range(4)) if self.gid else bytes(4)
        en = 0
        if self.gid:                                           # then his energy, % of what he had at pickup
            en = max(0, min(100, self.energy(self.gid) * 100 // max(1, self.emax)))
        return bytes([len(out)]) + b''.join(out) + slots + bytes([1 if time.time() - self.jump_t >= 1.0 else 0, en])

    def versus_hits(self, me):
        g, M = self.g, self.master
        if g.read(G_HIT, 1)[0] == 0:                         # the cave took the last hit: retire, send the next
            for i in self.retire:
                if g.read(M + 0x25 * i, 2) != b'':      # gone already
                    continue
                rec = struct.unpack('<h', g.read(M + 0x25 * i + 3, 2))[0]
                g.write(PROJ + PROJ_N * rec + 0x16, struct.pack('<i', -1))
            self.retire = []
            if self.hits:
                i = self.hits.pop(0)
                g.write(G_HIT + 2, struct.pack('<HHH', me, 0, i))
                g.write(G_HIT, b'\x01')
                self.retire.append(i)
                print('versus: hit on the host', flush=True)
        hx, hy, hz = (self.i32(M + me * 0x25 + o) / 65536 for o in (0x0F, 0x13, 0x17))
        tab = g.read(M, 0x25 * self.nent)
        seen = {}
        for i in range(1, self.nent):
            b = tab[0x25 * i:0x25 * i + 0x1B]
            if not (b[0] and b[1] == 5):
                continue
            rec = g.read(PROJ + PROJ_N * struct.unpack_from('<h', b, 3)[0], PROJ_N)
            if struct.unpack_from('<h', rec, 6)[0] != self.gid:
                continue
            p = tuple(v / 65536 for v in struct.unpack_from('<3i', b, 0x0F))
            last = self.shots.get(i)
            if last == 'done' or i in self.hits or i in self.retire:
                seen[i] = 'done'
                continue
            seen[i] = p
            if self.crosses(last or p, p, (hx, hy, hz)):
                self.hits.append(i)
                seen[i] = 'done'
            elif struct.unpack_from('<i', rec, 0x16)[0] == 0 and i not in self.retire:
                self.retire.append(i)                         # spent (hit the ground): free its slot
                seen[i] = 'done'
        self.shots = seen

    @staticmethod
    def crosses(a, b, host):
        """the shot's last step a -> b passes through the host's body (an upright cylinder)"""
        hx, hy, hz = host
        dx, dy = b[0] - a[0], b[1] - a[1]
        n = dx * dx + dy * dy
        t = 0.0 if n < 1e-9 else max(0.0, min(1.0, ((hx - a[0]) * dx + (hy - a[1]) * dy) / n))
        x, y, z = (u + (v - u) * t for u, v in zip(a, b))
        return math.hypot(x - hx, y - hy) < HIT_R and hz + HIT_Z[0] < z < hz + HIT_Z[1]

    def target_pos(self, e):
        """middle of a living unit (classes 1-3), or None"""
        b = self.g.read(self.master + 0x25 * e, 0x1B)
        if not b[0] or not 1 <= b[1] <= 3:
            return None
        x, y, z = (v / 65536 for v in struct.unpack_from('<3i', b, 0x0F))
        return (x, y, z + 0.35)

    @staticmethod
    def off_aim(eye, view, t):
        """(side, up / down) angles between the view and the direction to t"""
        d = [a - b for a, b in zip(t, eye)]
        side = abs((math.atan2(d[1], d[0]) - math.atan2(view[1], view[0]) + math.pi) % (2 * math.pi) - math.pi)
        up = abs(math.atan2(d[2], math.hypot(d[0], d[1])) - math.asin(max(-1.0, min(1.0, view[2]))))
        return side, up

    def pick_target(self, me, eye, view):
        best, pick = None, 0
        for i in range(1, self.nent):
            if i == self.gid or (i == me and not self.versus) or i in self.squad:
                continue
            t = self.target_pos(i)
            if t is None or math.dist(t[:2], eye[:2]) > LOCK_RANGE:
                continue
            side, up = self.off_aim(eye, view, t)
            score = side + up * 0.25 + math.dist(t[:2], eye[:2]) * 0.0005   # nearest the crosshair; near ones first (100 u = 3 deg)
            if side < LOCK_PICK and up < LOCK_PICK_V and (best is None or score < best):
                best, pick = score, i
        print('guest: lock', pick or 'nothing', flush=True)
        return pick

    def jump(self, angle):
        """a jump toward the heading + angle: a short push (one impulse is lost on the ground), once a second, paid in
        energy, not while the jets are hot"""
        if not self.gid or time.time() - self.jump_t < 1.0 or self.energy(self.gid) < JUMP_COST:
            return
        if struct.unpack('<i', self.g.read(self.suit(self.gid) + HEAT, 4))[0] >= 0x30000:
            return
        self.jump_t = time.time()
        self.g.write(self.suit(self.gid) + ENERGY, struct.pack('<h', self.energy(self.gid) - JUMP_COST))
        h = self.u16(self.master + 0x25 * self.gid + 0x1B) / 65536 * 2 * math.pi + angle
        self.burst = (math.cos(h) * JUMP_ACC[0], math.sin(h) * JUMP_ACC[0], JUMP_ACC[1], self.jump_t + JUMP_T)

    def push(self, dt, jets):
        """this tick's push through the jump mailbox (it adds to the body's speed): a jump's burst, and the jets while
        Space is held, paid in energy (too little left: nothing until it comes back, the host's jets sputter the same)"""
        vx = vy = vz = 0.0
        if self.burst and time.time() < self.burst[3]:
            vx, vy, vz = (v * dt for v in self.burst[:3])
        if jets:
            cost = int(JET_DRAIN * dt)
            en = self.energy(self.gid)
            if en >= max(1, cost):
                self.g.write(self.suit(self.gid) + ENERGY, struct.pack('<h', en - cost))
                vz += JET_ACC * dt
        if vx or vy or vz:
            self.g.write(G_JV, struct.pack('<3i', int(vx * 65536), int(vy * 65536), int(vz * 65536)))
            self.g.write(G_JUMP, b'\x01')

    def call_dropship(self):
        """the guest's "Call dropship": Enter in the host's game, as if the host pressed it; once in 5 s, said in the chat"""
        if not self.post_key or time.time() - self.drop_t < 5.0:
            return
        self.drop_t = time.time()
        self.post_key(DROPSHIP, True)
        self.post_key(DROPSHIP, False)
        self.lobby.say('guest', '* called the dropship *')
        print('guest: dropship called', flush=True)

    def suit(self, e):
        return PBA + PBA_N * self.u16(self.master + 0x25 * e + 3)

    def armour(self, e):
        """the suit's armour: its 4 parts' current values (hits take them down; a shot takes the energy, not this)"""
        r = self.g.read(self.suit(e), 0x30)
        return sum(max(0, struct.unpack_from('<h', r, c)[0]) for c, _ in PARTS)

    def armour_max(self, e):
        r = self.g.read(self.suit(e), 0x30)
        return max(1, sum(max(0, struct.unpack_from('<h', r, m)[0]) for _, m in PARTS))

    def energy(self, e):
        return struct.unpack('<h', self.g.read(self.suit(e) + ENERGY, 2))[0]

    def alive(self, e):
        return e and self.g.read(self.master + 0x25 * e, 2) == b'\x01\x01' and self.armour(e) > 0

    def pick(self, me, after=0):
        """a living suit of the player's squad: the nearest, or the next one after `after` (F8); TN_GUEST_ID wins"""
        if os.environ.get('TN_GUEST_ID'):
            gid = int(os.environ['TN_GUEST_ID'])
            return gid if self.alive(gid) else 0
        if self.lobby.col and not after:                       # the column he took on the outfitting screen
            gid = struct.unpack('<H', self.g.read(coop_lobby.SQUAD + coop_lobby.SQUAD_N * self.lobby.col + 2, 2))[0]
            if gid and self.alive(gid):
                return gid
        near = self.suits(me, enemy=self.versus)
        if not self.squad:                                     # mission start: the suits around the player
            if self.versus:                                    # versus: every suit of the other side (no pilot record)
                side = self.pilots()
                self.squad = [i for d, i in near if i not in side]
            else:
                self.squad = [i for d, i in near if d < SQUAD_R] or [i for d, i in near[:1]]
            if self.squad:
                print('guest: squad', self.squad, flush=True)
        live = [i for i in self.squad if self.alive(i)]
        if not live:
            return 0
        if after in live:
            return live[(live.index(after) + 1) % len(live)]
        return min(live, key=lambda i: next((d for d, j in near if j == i), 1e9))

    def take(self, gid):
        g = self.g
        g.write(G_ON, b'\x00')
        self.gid = gid
        if gid:
            g.write(G_TIM, bytes(16)); g.write(G_CTRL, bytes(0x28)); g.write(G_ID, struct.pack('<H', gid)); g.write(G_ON, b'\x01')
            self.amax, self.state, self.taken_t = self.armour_max(gid), OK, time.time()
            self.emax = max(1, self.energy(gid))
            print('guest: entity %d' % gid, flush=True)
            self.tag.put(gid, self.name, self.face)
        else:
            self.tag.restore()

    def lobby_step(self, in_mission):
        """his requests, the redraw the outfitting screen waits for, and the lobby state for his window (twice a
        second in the menus, every 3 s in a mission: there it only tells his window to hide the lobby)"""
        for m in self.lobby_msgs:
            r = self.lobby.request(m, in_mission)
            if r:
                print('lobby:', r, flush=True)
                self.lobby_t = 0.0
        self.lobby_msgs = []
        self.lobby.guest_name = self.name
        self.lobby.tick(in_mission)
        if time.time() - self.lobby_t >= (3.0 if in_mission else 0.5):
            self.lobby_t = time.time()
            self.s.sendto(self.lobby.packet(in_mission), ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))

    def hud(self):
        if time.time() - self.hud_t < 0.1:
            return
        self.hud_t = time.time()
        a = self.armour(self.gid) if self.gid else 0
        sel, wtype = 0, 0
        if self.gid:
            p = self.suit(self.gid)
            sel = self.g.read(p + SEL, 1)[0] & 3
            wtype = self.g.read(p + SLOTS + SLOT_N * sel, 1)[0]
        head = self.u16(self.master + 0x25 * self.gid + 0x1B) if self.gid else 0
        # then: his lock (entity, middle; 0 = none), his suit's and the host's positions (the name markers)
        lt = self.target_pos(self.lock) if self.lock else None
        mine = self.target_pos(self.gid) if self.gid else None
        me = self.u16(self.pid_addr + 2)
        host = tuple(self.i32(self.master + 0x25 * me + o) / 65536 for o in (0x0F, 0x13, 0x17))
        pk = b'GHD' + struct.pack('<BhhHBBH', self.state, max(0, a), self.amax, self.gid, sel, wtype, head) + \
            struct.pack('<H3f', self.lock if lt else 0, *(lt or (0, 0, 0))) + struct.pack('<3f', *(mine or (0, 0, 0))) + \
            struct.pack('<3f', *host) + self.squad_info(me) + struct.pack('<H', me)   # the host's entity: his name follows his drawn suit
        self.s.sendto(pk, ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))
        # the cockpit: every 2 s for 20 s after a teammate is taken (his window may still be starting), then every 15 s
        if time.time() - self.tpl_t > (2.0 if time.time() - self.taken_t < 20.0 else 15.0):
            self.cockpit()

    def cockpit(self):
        src = self.hud_src() if self.hud_src else None
        if not src:
            return
        import numpy as np
        scr, alpha, (fx0, fy0, fw, fh), pal = src
        if fw < 100 or fh < 100:                               # the game's map or a menu: not the cockpit
            return
        self.tpl_t = time.time()
        scr, alpha = scr.copy(), alpha.copy()
        m = 16                                                 # the 3D window: only its frame stays
        alpha[fy0 + m:fy0 + fh - m, fx0 + m:fx0 + fw - m] = 0
        for (x0, y0, x1, y1), c, a in CLEAR:
            scr[y0:y1, x0:x1] = c
            alpha[y0:y1, x0:x1] = a
        pk = b'GCK' + struct.pack('<4h', fx0, fy0, fw, fh) + pal + zlib.compress(np.dstack([scr, alpha]).tobytes(), 6)
        if len(pk) < 60000:
            self.s.sendto(pk, ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))

    def step(self, body, joints, arts=()):
        g, M = self.g, self.master
        if not self.ready:
            self.ready = g.read(CAVE, 4) != bytes(4)
            if not self.ready:
                return
        me = self.u16(self.pid_addr + 2)
        if g.read(M + me * 0x25, 2) != b'\x01\x01':          # not in a mission
            if self.gid:
                self.take(0)
            self.squad, self.state, self.amax0 = [], OK, {}
            self.read_input(False)                             # no stale look / F8 at the next mission start
            self.lobby_step(False)
            return
        if not self.joined:                                    # online, nobody joined (or he left): the squad stays the
            if self.gid:                                       # game's (a teammate held for "Player 2" stood still)
                self.take(0)
                self.state = OK
            self.read_input(False)
            return
        if self.state == OK and not self.alive(self.gid):
            if self.gid:                                       # his suit is destroyed: a few seconds, then the next one
                self.take(0)
                self.state, self.down_t = DOWN, time.time()
                print('guest: suit destroyed', flush=True)
            else:
                self.take(self.pick(me))
                if not self.gid:                               # no teammate yet: the host's view, try again
                    self.state, self.down_t = SPECTATE, time.time() - 3.0
        if self.state != OK and time.time() - self.down_t > 3.0:
            gid = self.pick(me)
            if gid:
                self.take(gid)
            else:
                self.state = SPECTATE                          # no teammate left: the host's view
        if self.next and self.state == OK:
            self.next = False
            gid = self.pick(me, self.gid)
            if gid and gid != self.gid:
                self.take(gid)
        self.next = False
        self.hud()
        self.tag.retry()
        self.lobby_step(True)
        if self.versus and self.state == OK:
            self.versus_hits(me)
        turn = self.read_input(self.state == OK)
        if self.state != OK:                                   # the guest watches through the host's eyes
            ex, ey, ez = (self.i32(M + me * 0x25 + o) / 65536 for o in (0x0F, 0x13, 0x17))
            eh = self.u16(M + me * 0x25 + 0x1B) / 65536 * 2 * math.pi
            self.send(struct.pack('<6f2i', ex, ey, ez + self.eye, eh, 0.0, self.fov_now(), len(body), me) +
                      b''.join(body) + struct.pack('<i', len(joints)) + b''.join(joints) +
                      struct.pack('<i', len(arts)) + b''.join(arts))
            return
        eg = M + self.gid * 0x25
        k = lambda sc: 1 if sc in self.keys else 0
        fwd, side, fire = k(0x11) - k(0x1F), k(0x20) - k(0x1E), self.fire
        p = None if self.remote else pad()        # online: the guest's own window only
        if p:                                                  # gamepad
            fwd = max(-1.0, min(1.0, fwd + axis(p.ly)))
            side = max(-1.0, min(1.0, side + axis(p.lx)))
            turn += axis(p.rx) * 600
            self.pitch = max(-0.9, min(0.9, self.pitch + axis(p.ry) * 0.03))
            fire = fire or p.rt > 64
        pad_jets = False
        if self.remote and self.rpad and time.time() - self.rpad_t < 0.3:   # online gamepad, same as the local one
            lx, ly, rx, ry, pf, pj = self.rpad
            fwd = max(-1.0, min(1.0, fwd + ly))
            side = max(-1.0, min(1.0, side + lx))
            turn += rx * 600
            self.pitch = max(-0.9, min(0.9, self.pitch + ry * 0.03))
            fire = fire or pf
            pad_jets = pj
        if turn:
            g.write(eg + 0x1B, struct.pack('<H', (self.u16(eg + 0x1B) + int(turn)) & 0xffff))
        c = bytearray(0x28)
        struct.pack_into('<ii', c, 0, int(fwd * 0x10000), int(side * 0x10000))
        g.write(G_CTRL, bytes(c))
        now = time.time()
        self.push(min(0.1, now - self.jet_t), 0x39 in self.keys or bool(p and p.lt > 64) or pad_jets)   # Space / left trigger
        self.jet_t = now
        gx, gy, gz = (self.i32(eg + o) / 65536 for o in (0x0F, 0x13, 0x17))
        gh = self.u16(eg + 0x1B) / 65536 * 2 * math.pi
        # aim: 30 units along the guest's view, or his locked target; held = a request every frame (the weapon's
        # reload sets the pace)
        eye = (gx, gy, gz + self.eye)
        view = (math.cos(gh) * math.cos(self.pitch), math.sin(gh) * math.cos(self.pitch), math.sin(self.pitch))
        if self.lock_req:
            self.lock_req = False
            self.lock = 0 if self.lock else self.pick_target(me, eye, view)
        aim = None
        if self.lock:
            t = self.target_pos(self.lock)
            if t is None:
                self.lock = 0
            else:
                side, up = self.off_aim(eye, view, t)
                if side < LOCK_KEEP and up < LOCK_KEEP_V:
                    aim = t
        if aim is None:
            aim = tuple(e + v * 30 for e, v in zip(eye, view))
        g.write(G_TGT, struct.pack('<3i', *(int(v * 65536) for v in aim)))
        if fire:
            g.write(G_FIRE, b'\x01')
        # the host's suit: the game never poses it in the cockpit view, its joints there are stale (they folded it
        # out of sight): left out; the learnt walk / rest pose instead, else the viewer's default pose
        joints = [j for j in joints if struct.unpack_from('<i', j)[0] != me]
        if self.anim:
            now = time.time()
            top = lambda j: max(struct.unpack_from('<48f', j, 8)[1::3])   # record: index, foot height, 48 floats
            hmax = max(map(top, joints)) if joints else 0
            up = {struct.unpack_from('<i', j)[0]: struct.unpack_from('<48f', j, 8) for j in joints if top(j) > 0.8 * hmax}
            where = lambda i: (self.i32(M + 0x25 * i + 0x0F) / 65536, self.i32(M + 0x25 * i + 0x13) / 65536,
                               self.u16(M + 0x25 * i + 0x1B) / 65536 * 2 * math.pi)
            self.anim.learn(up, where, now)
            pose = self.anim.host(*where(me), now)
            if pose:
                # after the index: the height of the feet in the world (the game's entity height minus its 0.12)
                joints = joints + [struct.pack('<if', me, self.i32(M + 0x25 * me + 0x17) / 65536 - 0.12) + pose]
        view = (struct.pack('<6f2i', gx, gy, gz + self.eye, gh, self.pitch, self.fov_now(), len(body), self.gid) +
                b''.join(body) + struct.pack('<i', len(joints)) + b''.join(joints) +
                struct.pack('<i', len(arts)) + b''.join(arts))
        self.send(view)

    def resync(self, pk):
        # 'R': the guest's decor table is not ours (it joined late), or it just connected (coop_net.gd)
        if pk[:1] == b'R' and self.enc and time.time() - self.resync_t > 0.5:
            self.resync_t = time.time()
            self.enc.resync()
            self.taken_t = time.time()                     # and his cockpit again

    def read_input(self, active):
        """the guest window: keys, mouse, buttons, online gamepad; returns the turn. Key and button releases count
        even while he has no suit (else a key let go while down stays held on the next teammate); look and F8 do not"""
        turn = 0
        for _ in range(512):
            try:
                pk, _ = self.rx.recvfrom(16384)
            except BlockingIOError:
                break
            except OSError:                                    # a datagram over 16 KB (WSAEMSGSIZE): dropped
                continue
            if pk == b'X':                                     # he left (coop_net.gd): his teammate back to the game
                if self.joined:
                    self.joined = False
                    print('guest: left', flush=True)
                continue
            if not self.joined:
                self.joined = True
                print('guest: joined', flush=True)
            self.resync(pk)
            if pk[:1] == b'K' and len(pk) >= 4:
                sc, down = struct.unpack('<HB', pk[1:4])
                if sc == F8 and down and active:
                    self.next = True
                if sc in WEAPON_KEYS and down and active and self.gid:
                    self.g.write(self.suit(self.gid) + SEL, bytes([WEAPON_KEYS[sc]]))
                if sc == DROPSHIP and down and active:
                    self.call_dropship()
                if sc in SHIFT:
                    self.shift = bool(down)
                elif sc in JUMP_DIR and down and active and self.shift:
                    self.jump(JUMP_DIR[sc])
                if sc in KEYS:
                    (self.keys.add if down else self.keys.discard)(sc)
            elif pk[:1] == b'M' and len(pk) >= 5:
                if active:
                    dx, dy = (max(-200, min(200, v)) for v in struct.unpack('<hh', pk[1:5]))
                    turn += dx * self.sens_x
                    self.pitch = max(-0.9, min(0.9, self.pitch - dy * 0.003))
            elif pk[:1] == b'B' and len(pk) >= 3 and pk[1] == 2:
                if pk[2] and active:
                    self.lock_req = True
            elif pk[:1] == b'B' and len(pk) >= 3 and pk[1] == 1:
                self.fire = bool(pk[2])
            elif pk[:1] == b'N' and len(pk) > 1:                 # his Steam name (host coop_net.gd): on the host's HUD
                name = pk[1:33].decode('utf-8', 'ignore')
                if name != self.name:
                    self.name = name
                    if self.gid and self.state == OK:
                        self.tag.put(self.gid, name, self.face)
            elif pk[:1] == b'A' and len(pk) == 1 + 21 * 27 * 3 and pk[1:] != self.face:   # his avatar (coop_net.gd)
                self.face = pk[1:]
                if self.gid and self.state == OK:
                    self.tag.put(self.gid, self.name, self.face)
            elif pk[:1] == b'Q' and len(pk) == 1 + 64 * 64 * 3:     # his avatar, 64 x 64 (host coop_net.gd): the lobby
                self.lobby.guest_face = pk[1:]
            elif pk[:1] == b'L' and len(pk) > 1:                 # lobby request (his window's coop_hud.gd): JSON
                try:
                    self.lobby_msgs.append(json.loads(pk[1:].decode('utf-8')))
                except ValueError:
                    pass
            elif pk[:1] == b'P' and len(pk) >= 6 and self.remote:   # online gamepad (coop_net.gd)
                lx, ly, rx, ry, f = struct.unpack('<bbbbB', pk[1:6])
                self.rpad = tuple(max(-1.0, min(1.0, v / 127)) for v in (lx, ly, rx, ry)) + (bool(f & 1), bool(f & 8))
                if f & 2 and not self.pad_jump and active:      # button A: jump where the left stick points
                    self.jump(math.atan2(-self.rpad[0], self.rpad[1]) if abs(self.rpad[0]) + abs(self.rpad[1]) > 0.3 else 0.0)
                self.pad_jump = bool(f & 2)
                if f & 4 and not self.pad_lock and active:
                    self.lock_req = True
                self.pad_lock = bool(f & 4)
                self.rpad_t = time.time()
        return turn

    def smoke(self, clouds):
        """Smoke grenades' clouds (live_bridge.py fumees) for the guest's window: at most 40 particles a cloud. Local:
        'SMKC' as the bridge sends it, 20 a second. Online: 'SMK' + zlib, 5 a second (his viewer keeps the screen
        thick by itself between them); one empty message when they are over."""
        if not clouds and not self.smoke_on:
            return
        now = time.time()
        if self.remote and clouds and now - self.smoke_t < 0.2:
            return
        self.smoke_t, self.smoke_on = now, bool(clouds)
        out = []
        for c in clouds:
            n = struct.unpack_from('<H', c, 16)[0]
            keep = range(0, n, max(1, -(-n // 40)))
            out.append(c[:16] + struct.pack('<H', len(keep)) + b''.join(c[18 + 14 * k:32 + 14 * k] for k in keep))
        body = bytes([len(out)]) + b''.join(out)
        if self.remote:
            self.s.sendto(b'SMK' + zlib.compress(body, 6), ('127.0.0.1', REMOTE_VIEW))
        else:
            self.s.sendto(b'SMKC' + body, ('127.0.0.1', LIVE_PORT))

    def weather(self, pk):
        """The weather ('WTHR', live_bridge.py meteo) for the guest's window: local as it is; online 'WTH' when it
        changes, else every 2 s (a joining guest gets it)."""
        if not self.remote:
            self.s.sendto(pk, ('127.0.0.1', LIVE_PORT))
            return
        if pk != self.weather_pk or time.time() - self.weather_t > 2.0:
            self.weather_pk, self.weather_t = pk, time.time()
            self.s.sendto(b'WTH' + pk[4:], ('127.0.0.1', REMOTE_VIEW))

    def fx29(self, pk=None):
        """What each 6/29 is when not a shot's dust ('FX29', live_bridge.py sortes_29: a jetpack's trail, a tree's
        smoke) for the guest's window: local as it is; online 'FXS', reliable, at most 20 a second (his views come at
        that rate), the last one once it is due. pk None: only what is due (called with each view)."""
        if pk is not None:
            self.fx_pk = pk
        if not self.remote:
            if pk is not None:
                self.s.sendto(pk, ('127.0.0.1', LIVE_PORT))
            return
        now = time.time()
        if self.fx_pk != self.fx_sent and now - self.fx_t >= 0.05:
            self.fx_sent, self.fx_t = self.fx_pk, now
            self.s.sendto(b'FXS' + self.fx_pk[4:], ('127.0.0.1', REMOTE_VIEW))

    def send(self, view):
        if not self.remote:
            self.s.sendto(view, ('127.0.0.1', LIVE_PORT))
            return
        now = time.time()
        if now - self.sent_t < 1 / self.view_hz:              # online: view_hz views a second (--view-hz)
            return
        self.sent_t = max(self.sent_t + 1 / self.view_hz, now - 1 / self.view_hz)   # on the beat, not the bridge's frames
        self.fx29()                                           # a 6/29 sort held back by the 20 a second
        for m in self.enc.encode(view, now):
            self.s.sendto(m, ('127.0.0.1', REMOTE_VIEW))
