# The co-op guest's aim point: what is under his crosshair, as the game aims its own player's shot at the point
# under its cursor (the click on the 3D view). The cave fires his suit's weapon from its mount (0x28A6F0: a hand's
# width ahead, 0.125 to the side, 0.17 above the hips) at the point the bridge gives (G_TGT). That point used to be
# 30 units along his view: the shot crossed his line of sight at 30 units only, and passed under / beside anything
# nearer (up to 0.2 units low at 5 units) and over / beside anything further (0.2 units at 60): a suit at 40 units
# was missed with the crosshair on it. Here: the first thing his view's line meets, a unit (its upright body) or the
# ground (the game's height map, cut as the game cuts its cells), else a point at his weapon's range: the shot from
# the mount converges there, at any distance.
import math, struct
import numpy as np

UNIT_BODY = {1: (0.30, 0.0, 0.75), 2: (0.55, 0.0, 0.6)}   # class: radius, bottom, top (units, from the entity's z)
STEP = 0.25                                                  # the ground: a test every this many units along the line
FAR = 150.0                                                  # no weapon range known: this far
HMAP, HMAP_N = 0x36F50A, 513                                 # the game's height map (as coop_guest.py)
MAP_TTL = 10.0                                               # the height map read again after this many seconds


class GuestAim:
    def __init__(self, cg):
        self.cg = cg
        self.hmap, self.hbase, self.ht = None, 0, -1e9
        self.last = None                                     # (what was hit, distance) of the last fire: the logs

    def heights(self, now):
        """the game's height map (heights in units, [y, x]), read once in a while"""
        g = self.cg.g
        base = struct.unpack('<I', g.read(HMAP, 4))[0]
        if not 0x100000 <= base < 0x2000000:
            self.hmap = None
            return None
        if self.hmap is None or base != self.hbase or now - self.ht > MAP_TTL:
            raw = np.frombuffer(g.read(base, 3 * HMAP_N * HMAP_N), np.uint8).reshape(HMAP_N, HMAP_N, 3)
            self.hmap = ((raw[:, :, 1].astype(np.int16) | (raw[:, :, 2].astype(np.int16) << 8)) >> 4) / 24.0
            self.hbase, self.ht = base, now
        return self.hmap

    @staticmethod
    def ground_at(hm, x, y):
        """the terrain's height under x, y as coop_guest.ground (the game's 0x2949C4), from the map read"""
        n = hm.shape[0]
        ix, iy = min(n - 2, max(0, int(x))), min(n - 2, max(0, int(y)))
        fx, fy = min(1.0, max(0.0, x - ix)), min(1.0, max(0.0, y - iy))
        h00, h10, h01, h11 = hm[iy, ix], hm[iy, ix + 1], hm[iy + 1, ix], hm[iy + 1, ix + 1]
        if (ix + iy) & 1 == 0:
            if fx > fy:
                h01 = h00 + h11 - h10
            else:
                h10 = h00 + h11 - h01
        elif fx + fy >= 1.0:
            h00 = h10 + h01 - h11
        return h00 + fx * (h10 - h00) + fy * (h01 - h00)

    def ground_hit(self, hm, eye, view, reach):
        """the distance along the line where it first goes under the ground (bisected to 1 cm), or None"""
        t0, above = 0.0, True
        t = STEP
        while t <= reach:
            x, y, z = (e + v * t for e, v in zip(eye, view))
            if not (0.0 <= x < hm.shape[1] - 1 and 0.0 <= y < hm.shape[0] - 1):
                return None
            if z < self.ground_at(hm, x, y):
                above = False
                break
            t0, t = t, t + STEP
        if above:
            return None
        lo, hi = t0, t
        while hi - lo > 0.01:
            m = (lo + hi) * 0.5
            x, y, z = (e + v * m for e, v in zip(eye, view))
            lo, hi = (m, hi) if z >= self.ground_at(hm, x, y) else (lo, m)
        return hi

    def unit_hit(self, eye, view, reach, skip):
        """the nearest unit (suit or vehicle, alive) the line passes through: (distance, entity) or None. Each one an
        upright cylinder (UNIT_BODY) around its entity"""
        cg = self.cg
        tab = cg.g.read(cg.master, 0x25 * cg.nent)
        best = None
        vh = math.hypot(view[0], view[1])
        for i in range(1, cg.nent):
            b = tab[0x25 * i:0x25 * i + 0x1B]
            if not b[0] or b[1] not in UNIT_BODY or i in skip:
                continue
            if b[1] == 1 and struct.unpack_from('<H', b, 3)[0] > 200:
                continue                                     # (no suit record: not a living suit)
            r, lo, hi = UNIT_BODY[b[1]]
            ux, uy, uz = (v / 65536 for v in struct.unpack_from('<3i', b, 0x0F))
            dx, dy = ux - eye[0], uy - eye[1]
            if vh < 1e-6:
                continue
            # where the line comes nearest the upright axis (in the ground plane), then the circle's entry
            th = (dx * view[0] + dy * view[1]) / (vh * vh)
            px, py = eye[0] + view[0] * th - ux, eye[1] + view[1] * th - uy
            d2 = px * px + py * py
            if d2 > r * r:
                continue
            t = th - math.sqrt(r * r - d2) / vh
            if t < 0.3 or t > reach:
                continue
            z = eye[2] + view[2] * t
            if not uz + lo <= z <= uz + hi:                  # (enters the side above or below: the top / bottom)
                tz = ((uz + hi if z > uz + hi else uz + lo) - eye[2]) / view[2] if abs(view[2]) > 1e-6 else -1
                if not 0.3 < tz <= reach:
                    continue
                qx, qy = eye[0] + view[0] * tz - ux, eye[1] + view[1] * tz - uy
                if qx * qx + qy * qy > r * r:
                    continue
                t = tz
            if best is None or t < best[0]:
                best = (t, i)
        return best

    def point(self, eye, view, reach, skip, now):
        """the point his crosshair is on: (x, y, z), and what it is ('unit N' / 'ground' / 'far')"""
        reach = max(5.0, min(FAR, reach or FAR))
        u = self.unit_hit(eye, view, reach, skip)
        hm = self.heights(now)
        gt = self.ground_hit(hm, eye, view, u[0] if u else reach) if hm is not None else None
        if gt is not None and (u is None or gt < u[0]):
            t, what = gt, 'ground'
        elif u is not None:
            t, what = u[0], 'unit %d' % u[1]
        else:
            t, what = reach, 'far'
        self.last = (what, t)
        return tuple(e + v * t for e, v in zip(eye, view)), what
