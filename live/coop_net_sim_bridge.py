# The host bridge's online side, simulated for live/test_coop_net.gd: a synthetic mission (test_coop_view.Mission,
# ~150 entities) encoded by coop_view.Encoder at 20 views a second and sent to the host window's coop_net.gd
# (127.0.0.1:47841), with a 'GHD' HUD packet every 0.5 s. 'R' on the control port (the test relays what coop_net.gd
# sends to the bridge's coop port): decor and keyframe again; 'Q': stop. A lossless coop_view.Decoder follows every
# message: the views a guest may rebuild are written to --out as 'V <md5>' lines, the HUD packets as 'H <hex>'.
#   python live/coop_net_sim_bridge.py --out FILE [--seconds 60] [--view-port 47841] [--ctl 47851]
import hashlib, os, socket, struct, sys, time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import coop_view as cv
from test_coop_view import Mission


def arg(name, default):
    return type(default)(sys.argv[sys.argv.index(name) + 1]) if name in sys.argv else default


OUT = arg('--out', '')
SECONDS = arg('--seconds', 60.0)
VIEW_PORT = arg('--view-port', 47841)
CTL = arg('--ctl', 47851)
HZ = 20

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ctl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
ctl.bind(('127.0.0.1', CTL))
ctl.setblocking(False)
out = open(OUT, 'w') if OUT else sys.stdout
m = Mission(1, 70, 15, 10, 8, 3, 25)
me = m.suits[0]
enc, ref = cv.Encoder(), cv.Decoder()
t0 = time.time()
step, resyncs, msgs, hud_t, state = 0, 0, 0, 0.0, 0
while time.time() - t0 < SECONDS:
    quit_ = False
    while True:
        try:
            pk, _ = ctl.recvfrom(64)
        except (BlockingIOError, OSError):
            break
        if pk[:1] == b'R':
            enc.resync()
            resyncs += 1
        elif pk[:1] == b'Q':
            quit_ = True
    if quit_:
        break
    step += 1
    m.step(1 / 60)
    if step % 3 == 0:
        t = time.time() - t0
        for msg in enc.encode(m.view(me), t):
            s.sendto(msg, ('127.0.0.1', VIEW_PORT))
            msgs += 1
            v = ref.feed(msg)
            if v is not None:
                out.write('V %s\n' % hashlib.md5(v).hexdigest())
        if t - hud_t >= 0.5:
            hud_t, state = t, state + 1
            pk = b'GHD' + struct.pack('<BhhH', state & 3, 1000 - state, 1100, me)
            s.sendto(pk, ('127.0.0.1', VIEW_PORT))
            out.write('H %s\n' % pk.hex())
        out.flush()
    time.sleep(max(0.0, t0 + step / 60 - time.time()))
out.write('END messages %d resyncs %d\n' % (msgs, resyncs))
out.close()
