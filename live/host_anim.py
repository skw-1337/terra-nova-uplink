# Animation de l'armure de l'hote dans la vue de l'invite. Le jeu ne calcule les articulations que des armures qu'il
# affiche, jamais celle du joueur (vue cockpit). On apprend un cycle de marche sur une armure affichee qui avance,
# puis on le rejoue pour l'hote au rythme de la distance qu'il parcourt (a l'envers quand il recule), et une pose de
# repos a l'arret. Les poses sont celles du bridge : 16 articulations (droite, haut, avant), sol a 0.
import json, math, os
import numpy as np

CACHE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'host_anim.json')   # cycle appris (local)
NB = 24                        # images par cycle de marche


class HostAnim:
    def __init__(self):
        self.cycle, self.L, self.idle = None, 0.0, None
        self.track = {}            # entite -> [(t, distance cumulee, avance ?, pose, (x, y))] tant qu'elle est affichee
        self.phase, self.hist, self.walking = 0.0, [], False
        try:
            c = json.load(open(CACHE))
            self.cycle, self.L = np.array(c['cycle'], np.float32), c['L']
            self.idle = np.array(c['idle'], np.float32) if c.get('idle') else None
        except (OSError, ValueError, KeyError):
            pass

    def _save(self):
        json.dump({'L': self.L, 'cycle': self.cycle.round(4).tolist(),
                   'idle': self.idle.round(4).tolist() if self.idle is not None else None}, open(CACHE, 'w'))

    def learn(self, poses, where, now):
        """poses : {entite: pose (48 floats)} des armures debout affichees ; where(e) -> (x, y, cap en radians)"""
        for e in list(self.track):
            if e not in poses and now - self.track[e][-1][0] > 0.15:
                del self.track[e]                          # plus affichee : ses articulations ne suivent plus
        for e, p in poses.items():
            x, y, cap = where(e)
            tr = self.track.setdefault(e, [])
            if tr:
                px, py = tr[-1][4]
                step = math.dist((x, y), (px, py))
                avant = (x - px) * math.cos(cap) + (y - py) * math.sin(cap) >= 0.7 * step
                tr.append((now, tr[-1][1] + step, avant or step < 1e-6, p, (x, y)))
            else:
                tr.append((now, 0.0, True, p, (x, y)))
            while tr[0][0] < now - 3.0:
                tr.pop(0)
            recent = [q for q in tr if q[0] >= now - 0.5]
            if now - tr[0][0] > 0.4 and recent[-1][1] - recent[0][1] < 0.03:
                self.idle = np.asarray(p, np.float32)      # au repos depuis 0,5 s : pose d'attente
            if self.cycle is None:
                tail = self._walk_tail(tr)
                if tail and tail[-1][0] - tail[0][0] > 1.2:
                    self._fit(tail)

    @staticmethod
    def _walk_tail(tr):
        """fin de piste ou l'armure avance sans arret (plus de 0,8 unite/s sur chaque quart de seconde)"""
        t1 = tr[-1][0]
        while True:
            w = [q for q in tr if t1 - 0.25 <= q[0] <= t1]
            if len(w) < 2 or w[0][0] > t1 - 0.2 or (w[-1][1] - w[0][1]) / 0.25 < 0.8 or not all(q[2] for q in w):
                break
            t1 -= 0.25
        return [q for q in tr if q[0] >= t1]

    def _fit(self, tr):
        """periode par repliement : les poses de plusieurs cycles, rangees par phase (distance modulo L) dans NB cases,
        se superposent le mieux pour la bonne longueur L ; la moyenne par case donne un cycle propre (les articulations
        lues alternent d'une lecture a l'autre, le bruit s'annule)"""
        d = np.array([q[1] for q in tr]); X = np.array([q[3] for q in tr], np.float32)
        d -= d[0]
        if d[-1] < 2.5:                                   # au moins 2 a 3 cycles
            return
        tot = float(np.sum(np.var(X, 0)))
        res = {}
        for L in np.arange(0.5, 1.3, 0.01):
            b = ((d / L) % 1.0 * NB).astype(int)
            if np.bincount(b, minlength=NB).min() < 2:
                continue
            m = np.stack([X[b == k].mean(0) for k in range(NB)])
            res[round(float(L), 2)] = (float(np.sum(np.var(X - m[b], 0))) / tot, m)
        if not res:
            return
        lo = min(r[0] for r in res.values())
        L = min(l for l, r in res.items() if r[0] <= lo * 1.1)      # la plus courte (pas un multiple)
        err, m = res[L]
        if err < 0.5:
            m = (np.roll(m, 1, 0) + 2 * m + np.roll(m, -1, 0)) / 4      # leger lissage circulaire
            self.cycle, self.L = m.astype(np.float32), L
            self._save()
            print('hote : cycle de marche appris (%.2f unite par cycle, residu %.2f)' % (L, err), flush=True)

    def host(self, x, y, cap, now):
        """pose de l'hote (octets, 48 floats) ou None"""
        if self.hist:
            px, py = self.hist[-1][1:]
            step = math.dist((x, y), (px, py))
            recule = (x - px) * math.cos(cap) + (y - py) * math.sin(cap) < -0.5 * step
            self.phase += -step if recule else step
        self.hist.append((now, x, y))
        while self.hist[0][0] < now - 0.2:
            self.hist.pop(0)
        span = now - self.hist[0][0]
        v = math.dist(self.hist[0][1:], (x, y)) / span if span > 0.05 else 0.0
        self.walking = v > 0.5 if not self.walking else v > 0.2
        if self.walking and self.cycle is not None:
            n = len(self.cycle); f = (self.phase / self.L) % 1.0 * n; i = int(f) % n; a = f - int(f)
            pose = self.cycle[i] * (1 - a) + self.cycle[(i + 1) % n] * a
        elif self.idle is not None:
            pose = self.idle
        else:
            return None
        return np.asarray(pose, '<f4').tobytes()
