# The guest's beam from his gun. The game draws a beam weapon's shot (laser, ionic fusion rifle, multipulsar, pulsar,
# flare...) as a chain of 6/28 segments behind the bolt, over what it flew in each of its pictures. The player's shot
# leaves the gun at 0.04 forward, 0.12 to the side of the firing arm, 0.01 up from the eye (measured 18/11/2026 for the
# host and for the guest alike, coop_shot_log.py), and its first picture's chain starts at the gun: the thick line from
# the side of his view. The guest's shot is fired by the TN+ cave after the game moved its shots for that picture: the
# bolt is one step further when it is first drawn (laser: 1.9 forward instead of 1.2), and its first chain starts about
# 1 unit ahead, 0.12 aside: a short line near the middle of his view ("my laser is in the middle", the owner).
# For his window only, the missing piece is added to the beams of that moment: from the gun to the nearest end of his
# chain, on the same line, in its colour, entity GUN_ID + n (no entity of the game: his window draws it for one view as
# the game's own gun beam, viewer.gd _beam_flashes). The host's window gets the game's beams as they are.
import math, os, struct, time

ON = os.environ.get('TN_COOP_GUN_FLASH') != '0'   # TN_COOP_GUN_FLASH=0: off (his beams as the game has them)

GUN_ID = 0x10000
GUN_F = 0.04                       # the gun, forward of his eye (units)
NEAR = (0.12, 1.7)                 # his chain's nearest end, forward from his eye (units): its first picture
SIDE = (0.07, 0.17)                # ... aside (the arm's 0.12)
UP = 0.08
ONCE = 0.09                        # one picture of the game: a side's gun beam lasts this long (s), sent again with
                                   # each packet meanwhile, no new one on that side
_last = {}
LONG = 0.1                         # a chain's segment (laser, ionic rifle: 0.14-0.27); the pulsars' and the flare's
                                   # bars (0.02-0.06) start at his gun already: nothing added to them


def add(pk, eye, heading, pitch):
    """the 'BEAM' packet with his gun's segments added (eye: x, y, z; heading, pitch in radians, + up)"""
    if len(pk) < 6:
        return pk
    n = struct.unpack_from('<H', pk, 4)[0]
    if len(pk) != 6 + 29 * n:
        return pk
    f = (math.cos(heading) * math.cos(pitch), math.sin(heading) * math.cos(pitch), math.sin(pitch))
    r = (math.sin(heading), -math.cos(heading), 0.0)
    u = (f[1] * r[2] - f[2] * r[1], f[2] * r[0] - f[0] * r[2], f[0] * r[1] - f[1] * r[0])
    dot = lambda a, b: a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
    rel = lambda p: (dot([p[i] - eye[i] for i in range(3)], f), dot([p[i] - eye[i] for i in range(3)], r),
                     dot([p[i] - eye[i] for i in range(3)], u))
    best = {}                      # side (+1 / -1) -> (forward of the near end, near end, far end, colour)
    gun_there = set()
    for k in range(n):
        o = 6 + 29 * k
        _, x0, y0, z0, x1, y1, z1, col = struct.unpack_from('<i6fB', pk, o)
        a, b = (x0, y0, z0), (x1, y1, z1)
        ra, rb = rel(a), rel(b)
        near, far, rn = (a, b, ra) if ra[0] <= rb[0] else (b, a, rb)
        if abs(rn[2]) > UP or not SIDE[0] <= abs(rn[1]) <= SIDE[1] or math.dist(a, b) < LONG:
            continue
        s = 1 if rn[1] > 0 else -1
        if rn[0] < NEAR[0]:
            gun_there.add(s)       # (a chain from his gun already: nothing to add)
        elif rn[0] <= NEAR[1] and (s not in best or rn[0] < best[s][0]):
            best[s] = (rn[0], near, far, col)
    add_ = []
    now = time.time()
    for s in list(_last):                  # (sent with every packet while it lasts: online his view goes with the
        if now - _last[s][0] < ONCE:       # beams of its moment only; his window draws it once)
            add_.append(_last[s][1])
            best.pop(s, None)
        else:
            del _last[s]
    for s, (fw, near, far, col) in best.items():
        if s in gun_there:
            continue
        d = [near[i] - far[i] for i in range(3)]
        ln = math.sqrt(dot(d, d))
        if ln < 1e-4:
            continue
        d = [v / ln for v in d]
        back = -dot(d, f)          # how fast the line comes back towards his eye
        if back < 0.5:
            continue
        gun = [near[i] + d[i] * (fw - GUN_F) / back for i in range(3)]
        add_.append(struct.pack('<i6fB', GUN_ID + (1 if s > 0 else 2), *gun, *near, col))
        _last[s] = (now, add_[-1])
    if not add_:
        return pk
    return b'BEAM' + struct.pack('<H', n + len(add_)) + pk[6:] + b''.join(add_)
