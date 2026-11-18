# Test log of the shots (TN_COOP_SHOTLOG=<file>, co-op bridge only; off by default): every new projectile (class 5) and
# every beam segment (6/28, the bridge's BEAM packet) as the game makes it, with the host's view and the guest's view
# of that moment, each point also given in both views' own frames (forward, right, up from the eye). It compares where
# the host's shots leave and land in his view with where the guest's do in his (coop item "his own beam starts in the
# middle", 18/11/2026).
import json, math, os, struct, time

PATH = os.environ.get('TN_COOP_SHOTLOG', '')
PROJ, PROJ_N = 0x39BDF0, 0x1E
_seen = {}                         # entity -> [key, samples]
_f = None
_views = {}


def _out(row):
    global _f
    if _f is None:
        _f = open(PATH, 'a', encoding='utf-8')
    _f.write(json.dumps(row) + '\n')
    _f.flush()


def frame(view, p):
    """p in a view's frame: (forward, right, up) from its eye; view = (x, y, z, heading rad, pitch rad, + up)"""
    x, y, z, h, pt = view[:5]
    d = (p[0] - x, p[1] - y, p[2] - z)
    f = (math.cos(h) * math.cos(pt), math.sin(h) * math.cos(pt), math.sin(pt))
    r = (math.sin(h), -math.cos(h), 0.0)
    u = (f[1] * r[2] - f[2] * r[1], f[2] * r[0] - f[0] * r[2], f[0] * r[1] - f[1] * r[0])
    dot = lambda a, b: sum(i * j for i, j in zip(a, b))
    return [round(dot(d, f), 3), round(dot(d, r), 3), round(dot(d, u), 3)]


def views(host, guest):
    _views['host'], _views['guest'] = tuple(host) if host else None, tuple(guest) if guest else None


def _rel(p):
    return {k: frame(v, p) for k, v in _views.items() if v}


def tick(cg, me):
    if not PATH:
        return
    g, M = cg.g, cg.master
    tab = g.read(M, 0x25 * cg.nent)
    now = time.time()
    live = set()
    for i in range(1, cg.nent):
        b = tab[0x25 * i:0x25 * i + 0x1B]
        if not (b[0] and b[1] == 5):
            continue
        rec = struct.unpack_from('<h', b, 3)[0]
        key = (b[2], rec)
        p = tuple(round(v / 65536, 3) for v in struct.unpack_from('<3i', b, 0x0F))
        live.add(i)
        s = _seen.get(i)
        if s is None or s[0] != key:
            who = struct.unpack_from('<h', g.read(PROJ + PROJ_N * rec, 8), 6)[0] if 0 <= rec < 400 else -1
            s = _seen[i] = [key, who, []]
        if len(s[2]) < 4 or now - s[2][-1][0] > 0.25:
            if len(s[2]) < 40 and (not s[2] or s[2][-1][1] != p):
                s[2].append((now, p))
                _out(dict(t=now, kind='shot', ent=i, type=b[2], shooter=s[1], host=me, guest=cg.gid, n=len(s[2]), p=p,
                          rel=_rel(p), views=_views))
    for i in [k for k in _seen if k not in live]:
        s = _seen.pop(i)
        if s[2]:
            _out(dict(t=now, kind='end', ent=i, type=s[0][0], shooter=s[1], host=me, guest=cg.gid, p=s[2][-1][1],
                      rel=_rel(s[2][-1][1]), views=_views))


def beams(pk):
    if not PATH or len(pk) < 6:
        return
    n = struct.unpack_from('<H', pk, 4)[0]
    now = time.time()
    for k in range(n):
        o = 6 + 29 * k
        if o + 29 > len(pk):
            break
        e, x0, y0, z0, x1, y1, z1, col = struct.unpack_from('<i6fB', pk, o)
        a, b = (round(x0, 3), round(y0, 3), round(z0, 3)), (round(x1, 3), round(y1, 3), round(z1, 3))
        _out(dict(t=now, kind='beam', ent=e, col=col, a=a, b=b, rel_a=_rel(a), rel_b=_rel(b), views=_views))
