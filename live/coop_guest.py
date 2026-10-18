# Coop (TN+ Coop build only): a second player drives a teammate and sees through his eyes in a second Uplink window.
# TN+ Coop puts the coop code in the game at the main menu (code 0x46B040); this module picks the teammate, sends the
# guest's commands, aim and fire to the game (data page 0x46C000) and the guest's camera to his window (port 47831).
# Input: an XInput gamepad (left stick move / strafe, right stick look, right trigger fire) or the guest window
# itself (W/S/A/D, mouse, left button, F8 = next teammate), on port 47834. Online (--guest-remote) the local pad is not
# read: the guest window's coop_net.gd sends its own gamepad as 'P' packets (lx, ly, rx, ry int8 with XInput signs,
# fire 0 / 1), used only while fresh (0.3 s). The guest window's HUD gets 'GHD' packets (coop_hud.gd). Online the
# view goes as coop_view.py messages (keyframes, deltas, decor), view_hz a second; 'R' from the guest: decor again.
import ctypes, math, os, socket, struct, time
import coop_view
from coop_name import NameTag

CAVE = 0x46B040
G_ON, G_FIRE, G_ID, G_TIM, G_CTRL, G_TGT = 0x46C000, 0x46C001, 0x46C002, 0x46C010, 0x46C020, 0x46C048
LIVE_PORT, PLAY_PORT = 47831, 47834
REMOTE_VIEW = 47841           # online guest (--guest-remote): the host window's coop_net.gd sends it over Steam
KEYS = {0x11, 0x1F, 0x1E, 0x20}   # the only keys a guest can hold: W S A D (input from the network is filtered)
F8 = 0x42                     # next teammate
HUD_PORT = 47832              # the guest window's coop_hud.gd: 'GHD' state, armour, max, entity (online: via 47841)
PBA, PBA_N, ARMOUR = 0x3A5608, 0x582, 0x88   # English exe: suit records, armour word (our suits 1100, enemies 1000)
SQUAD_R = 25.0                # suits this close to the player at mission start = his squad (the guest's choices)
OK, DOWN, SPECTATE = 0, 1, 2


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
                            (['--mission', mission] if mission else []))


class Guest:
    def __init__(self, g, master, pid_addr, nent, eye, sens_x, fov_now, sock, remote=False, view_hz=20.0):
        self.remote, self.sent_t, self.view_hz = remote, 0.0, max(1.0, view_hz)
        self.enc, self.resync_t = coop_view.Encoder() if remote else None, 0.0
        self.g, self.master, self.pid_addr, self.nent, self.eye, self.sens_x = g, master, pid_addr, nent, eye, sens_x
        self.fov_now, self.s = fov_now, sock
        self.rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rx.bind(('127.0.0.1', PLAY_PORT)); self.rx.setblocking(False)
        self.keys, self.gid, self.pitch, self.fire = set(), 0, 0.0, False
        self.rpad, self.rpad_t = None, 0.0                    # online: the guest's gamepad (lx, ly, rx, ry, fire)
        self.squad, self.state, self.down_t, self.hud_t, self.amax, self.next = [], OK, 0.0, 0.0, 1, False
        self.tag, self.name = NameTag(g), os.environ.get('TN_GUEST_NAME', 'Player 2')   # his name on the host's HUD
        self.face = None                                      # and his Steam avatar (21 x 27 RGB) as the portrait
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

    def suits(self, me):
        """living suits but the player's, nearest first: [(distance, entity)]"""
        mx, my = struct.unpack('<ii', self.g.read(self.master + 0x25 * me + 0x0F, 8))
        tab = self.g.read(self.master, 0x25 * self.nent)
        out = []
        for i in range(1, self.nent):
            b = tab[0x25 * i:0x25 * i + 0x17]
            if b[0] and b[1] == 1 and b[2] < 8 and i != me:
                x, y = struct.unpack_from('<ii', b, 0x0F)
                out.append((math.hypot(x - mx, y - my) / 65536, i))
        return sorted(out)

    def armour(self, e):
        return struct.unpack('<h', self.g.read(PBA + PBA_N * self.u16(self.master + 0x25 * e + 3) + ARMOUR, 2))[0]

    def alive(self, e):
        return e and self.g.read(self.master + 0x25 * e, 2) == b'\x01\x01' and self.armour(e) > 0

    def pick(self, me, after=0):
        """a living suit of the player's squad: the nearest, or the next one after `after` (F8); TN_GUEST_ID wins"""
        if os.environ.get('TN_GUEST_ID'):
            gid = int(os.environ['TN_GUEST_ID'])
            return gid if self.alive(gid) else 0
        near = self.suits(me)
        if not self.squad:                                     # mission start: the suits around the player
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
            self.amax, self.state = max(1, self.armour(gid)), OK
            print('guest: entity %d' % gid, flush=True)
            self.tag.put(gid, self.name, self.face)
        else:
            self.tag.restore()

    def hud(self):
        if time.time() - self.hud_t < 0.1:
            return
        self.hud_t = time.time()
        a = self.armour(self.gid) if self.gid else 0
        pk = b'GHD' + struct.pack('<BhhH', self.state, max(0, a), self.amax, self.gid)
        self.s.sendto(pk, ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))

    def step(self, body, joints):
        g, M = self.g, self.master
        if not self.ready:
            self.ready = g.read(CAVE, 4) != bytes(4)
            if not self.ready:
                return
        me = self.u16(self.pid_addr + 2)
        if g.read(M + me * 0x25, 2) != b'\x01\x01':          # not in a mission
            if self.gid:
                self.take(0)
            self.squad, self.state = [], OK
            self.read_input(False)                             # no stale look / F8 at the next mission start
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
        turn = self.read_input(self.state == OK)
        if self.state != OK:                                   # the guest watches through the host's eyes
            ex, ey, ez = (self.i32(M + me * 0x25 + o) / 65536 for o in (0x0F, 0x13, 0x17))
            eh = self.u16(M + me * 0x25 + 0x1B) / 65536 * 2 * math.pi
            self.send(struct.pack('<6f2i', ex, ey, ez + self.eye, eh, 0.0, self.fov_now(), len(body), me) +
                      b''.join(body) + struct.pack('<i', len(joints)) + b''.join(joints))
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
        if self.remote and self.rpad and time.time() - self.rpad_t < 0.3:   # online gamepad, same as the local one
            lx, ly, rx, ry, pf = self.rpad
            fwd = max(-1.0, min(1.0, fwd + ly))
            side = max(-1.0, min(1.0, side + lx))
            turn += rx * 600
            self.pitch = max(-0.9, min(0.9, self.pitch + ry * 0.03))
            fire = fire or pf
        if turn:
            g.write(eg + 0x1B, struct.pack('<H', (self.u16(eg + 0x1B) + int(turn)) & 0xffff))
        c = bytearray(0x28)
        struct.pack_into('<ii', c, 0, int(fwd * 0x10000), int(side * 0x10000))
        g.write(G_CTRL, bytes(c))
        gx, gy, gz = (self.i32(eg + o) / 65536 for o in (0x0F, 0x13, 0x17))
        gh = self.u16(eg + 0x1B) / 65536 * 2 * math.pi
        # aim: 30 units along the guest's view; held = a request every frame (the weapon's reload sets the pace)
        ca = math.cos(self.pitch) * 30
        g.write(G_TGT, struct.pack('<3i', int((gx + math.cos(gh) * ca) * 65536), int((gy + math.sin(gh) * ca) * 65536),
                                   int((gz + self.eye + math.sin(self.pitch) * 30) * 65536)))
        if fire:
            g.write(G_FIRE, b'\x01')
        if self.anim:                                          # the host's suit, never posed by the game (cockpit view)
            now = time.time()
            top = lambda j: max(struct.unpack_from('<48f', j, 8)[1::3])   # record: index, foot height, 48 floats
            hmax = max(map(top, joints)) if joints else 0
            up = {struct.unpack_from('<i', j)[0]: struct.unpack_from('<48f', j, 8) for j in joints if top(j) > 0.8 * hmax}
            where = lambda i: (self.i32(M + 0x25 * i + 0x0F) / 65536, self.i32(M + 0x25 * i + 0x13) / 65536,
                               self.u16(M + 0x25 * i + 0x1B) / 65536 * 2 * math.pi)
            self.anim.learn(up, where, now)
            pose = self.anim.host(*where(me), now)
            if pose:
                joints = joints + [struct.pack('<if', me, min(struct.unpack('<48f', pose)[1::3])) + pose]
        view = (struct.pack('<6f2i', gx, gy, gz + self.eye, gh, self.pitch, self.fov_now(), len(body), self.gid) +
                b''.join(body) + struct.pack('<i', len(joints)) + b''.join(joints))
        self.send(view)

    def resync(self, pk):
        # 'R': the guest's decor table is not ours (it joined late), or it just connected (coop_net.gd)
        if pk[:1] == b'R' and self.enc and time.time() - self.resync_t > 0.5:
            self.resync_t = time.time()
            self.enc.resync()

    def read_input(self, active):
        """the guest window: keys, mouse, buttons, online gamepad; returns the turn. Key and button releases count
        even while he has no suit (else a key let go while down stays held on the next teammate); look and F8 do not"""
        turn = 0
        for _ in range(512):
            try:
                pk, _ = self.rx.recvfrom(2048)
            except BlockingIOError:
                break
            except OSError:                                    # a datagram over 2 KB (WSAEMSGSIZE): dropped
                continue
            self.resync(pk)
            if pk[:1] == b'K' and len(pk) >= 4:
                sc, down = struct.unpack('<HB', pk[1:4])
                if sc == F8 and down and active:
                    self.next = True
                if sc in KEYS:
                    (self.keys.add if down else self.keys.discard)(sc)
            elif pk[:1] == b'M' and len(pk) >= 5:
                if active:
                    dx, dy = (max(-200, min(200, v)) for v in struct.unpack('<hh', pk[1:5]))
                    turn += dx * self.sens_x
                    self.pitch = max(-0.9, min(0.9, self.pitch - dy * 0.003))
            elif pk[:1] == b'B' and len(pk) >= 3 and pk[1] == 1:
                self.fire = bool(pk[2])
            elif pk[:1] == b'N' and len(pk) > 1:                 # his Steam name (host coop_net.gd): on the host's HUD
                name = pk[1:33].decode('utf-8', 'ignore')
                if name != self.name:
                    self.name = name
                    if self.gid and self.state == OK:
                        self.tag.put(self.gid, name, self.face)
            elif pk[:1] == b'A' and len(pk) == 1 + 21 * 27 * 3:      # his avatar (host coop_net.gd)
                self.face = pk[1:]
                if self.gid and self.state == OK:
                    self.tag.put(self.gid, self.name, self.face)
            elif pk[:1] == b'P' and len(pk) >= 6 and self.remote:   # online gamepad (coop_net.gd)
                lx, ly, rx, ry, f = struct.unpack('<bbbbB', pk[1:6])
                self.rpad = tuple(max(-1.0, min(1.0, v / 127)) for v in (lx, ly, rx, ry)) + (f != 0,)
                self.rpad_t = time.time()
        return turn

    def send(self, view):
        if not self.remote:
            self.s.sendto(view, ('127.0.0.1', LIVE_PORT))
            return
        now = time.time()
        if now - self.sent_t < 1 / self.view_hz:              # online: view_hz views a second (--view-hz)
            return
        self.sent_t = max(self.sent_t + 1 / self.view_hz, now - 1 / self.view_hz)   # on the beat, not the bridge's frames
        for m in self.enc.encode(view, now):
            self.s.sendto(m, ('127.0.0.1', REMOTE_VIEW))
