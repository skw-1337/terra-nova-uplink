# The co-op guest's shots on the unit he aims at. The TN+ Coop cave fires his weapon through the game's own fire
# (0x28A878) with no target entity (it pushes 0): measured on 2026-11-18 (Aegis, fusion rifle), his bolts then fly
# through the enemy under his crosshair (0.05-0.4 units from its middle) and on to their range, and its armour never
# drops, in every aim mode. The player's own shots carry the unit under his click (0x269F28 -> 0x262D4C), the AI's its
# target. So, as versus mode does for the host (coop_guest.versus_hits): the unit his shot was aimed at (his window's
# pick, the bridge's cast, his lock) is remembered with each of his projectiles, and when one crosses that unit's body
# where it is NOW on the host, the game is handed the hit (G_HIT mailbox: the game's damage queue, 0x2D64E8: damage by
# weapon, side, shield, armour, death) and the projectile is retired, as a hit ends it. Only that unit: like the
# game's own shots, his pass through the others. TN_COOP_UNIT_HITS=0: off (the shots as before).
import os, struct, time
from coop_aim import UNIT_BODY

ON = os.environ.get('TN_COOP_UNIT_HITS') != '0'
G_HIT = 0x46C200                  # (coop_guest.py) 1 = a hit to take, +2 the entity hit, +6 the projectile
PROJ, PROJ_N = 0x39BDF0, 0x1E      # projectile records: +6 the shooter, +0x16 range left
FRESH = 0.4                        # a projectile of his that appears this long after his fire is that shot's (s)
SLACK = 0.05                       # (the body a little wider than the cast's: the projectile's steps are long)


def crosses(a, b, c, r, lo, hi):
    """the step a -> b passes through the upright cylinder at c (radius r, from c.z + lo to c.z + hi)"""
    dx, dy = b[0] - a[0], b[1] - a[1]
    n = dx * dx + dy * dy
    t = 0.0 if n < 1e-9 else max(0.0, min(1.0, ((c[0] - a[0]) * dx + (c[1] - a[1]) * dy) / n))
    x, y, z = (u + (v - u) * t for u, v in zip(a, b))
    return (x - c[0]) ** 2 + (y - c[1]) ** 2 < (r + SLACK) ** 2 and c[2] + lo - SLACK < z < c[2] + hi + SLACK


class UnitHits:
    def __init__(self, guest):
        self.cg = guest
        self.fired = (0.0, 0)          # (when, the entity his shot was aimed at; 0: none)
        self.shots = {}                # his projectile -> [its target, its last place] ('done': hit or spent)
        self.queue, self.retire = [], []
        self.n = 0
        self.on = ON

    def aimed(self, what):
        """his fire this frame, aimed as the bridge's aim line says ('pick unit N', 'unit N', 'lock N')"""
        w = what.split()
        ent = int(w[-1]) if len(w) >= 2 and w[-2] in ('unit', 'lock') and w[-1].isdigit() else 0
        self.fired = (time.time(), ent)

    def tick(self):
        if not self.on:
            return
        cg = self.cg
        g, M, gid = cg.g, cg.master, cg.gid
        if g.read(G_HIT, 1)[0] == 0:                          # the game took the last hit: retire it, send the next
            for i in self.retire:
                rec = struct.unpack('<h', g.read(M + 0x25 * i + 3, 2))[0]
                g.write(PROJ + PROJ_N * rec + 0x16, struct.pack('<i', -1))
            self.retire = []
            if self.queue:
                i, e = self.queue.pop(0)
                g.write(G_HIT + 2, struct.pack('<HHH', e, 0, i))
                g.write(G_HIT, b'\x01')
                self.retire.append(i)
                self.n += 1
                print('guest: hit on %d (his shot %d)' % (e, i), flush=True)
        if not gid:
            return
        tab = g.read(M, 0x25 * cg.nent)
        now = time.time()
        seen = {}
        for i in range(1, cg.nent):
            b = tab[0x25 * i:0x25 * i + 0x1B]
            if not (b[0] and b[1] == 5):
                continue
            rec = g.read(PROJ + PROJ_N * struct.unpack_from('<h', b, 3)[0], PROJ_N)
            if struct.unpack_from('<h', rec, 6)[0] != gid:
                continue
            p = tuple(v / 65536 for v in struct.unpack_from('<3i', b, 0x0F))
            s = self.shots.get(i)
            if s is None:                                     # new: the shot of his last fire, if recent
                s = [self.fired[1] if now - self.fired[0] < FRESH else 0, p]
            if s == 'done' or not s[0]:
                seen[i] = s
                continue
            e = s[0]
            u = tab[0x25 * e:0x25 * e + 0x1B]
            if u[0] and u[1] in UNIT_BODY:
                r, lo, hi = UNIT_BODY[u[1]]
                c = tuple(v / 65536 for v in struct.unpack_from('<3i', u, 0x0F))
                if crosses(s[1], p, c, r, lo, hi):
                    self.queue.append((i, e))
                    seen[i] = 'done'
                    continue
            s[1] = p
            seen[i] = s
        self.shots = seen
