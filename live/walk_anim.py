# Marche des armures que le jeu n'anime pas. Le jeu ne calcule les 16 articulations que des armures qu'il dessine de
# pres ; plus loin elles restent figees (Uplink, plus net, le montrait). On apprend un cycle de marche par type d'unite
# sur celles qu'il anime (repliement de leurs poses par distance parcourue, comme host_anim.py en coop), puis on le
# rejoue pour les autres au rythme de la distance que chacune parcourt (a l'envers quand elle recule), et leur pose de
# repos a l'arret. Poses du bridge : 48 floats (16 articulations droite, haut, avant ; sol a 0).
import json, math, os
import numpy as np

NB = 24                        # images par cycle
CACHE = os.path.join(os.environ.get('APPDATA', os.path.dirname(os.path.abspath(__file__))),
                     'Godot', 'app_userdata', 'Terra Nova Uplink', 'walk_anim.json')   # appris une fois, garde aux mises a jour


class WalkAnim:
    def __init__(self):
        self.cycles = {}           # type -> (cycle NB x 48, longueur d'un cycle en unites)
        self.idles = {}            # type -> pose de repos
        self.track = {}            # entite animee par le jeu -> [(t, distance cumulee, avance ?, pose, (x, y))]
        self.rep = {}              # entite rejouee -> [phase, [(t, x, y)], marche ?]
        try:
            c = json.load(open(CACHE))
            for k, v in c.items():
                self.cycles[int(k)] = (np.array(v['cycle'], np.float32), v['L'])
                if v.get('idle'):
                    self.idles[int(k)] = np.array(v['idle'], np.float32)
        except (OSError, ValueError, KeyError):
            pass

    def _save(self):
        try:
            os.makedirs(os.path.dirname(CACHE), exist_ok=True)
            json.dump({str(k): {'L': L, 'cycle': c.round(4).tolist(),
                                'idle': self.idles[k].round(4).tolist() if k in self.idles else None}
                       for k, (c, L) in self.cycles.items()}, open(CACHE, 'w'))
        except OSError:
            pass

    def learn(self, poses, where, now):
        """poses : {entite: (type, 48 floats)} des armures debout que le jeu anime ; where(e) -> (x, y, cap)"""
        for e in list(self.track):
            if e not in poses and now - self.track[e][-1][0] > 0.15:
                del self.track[e]
        for e, (typ, p) in poses.items():
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
            if now - tr[0][0] > 0.4 and recent[-1][1] - recent[0][1] < 0.03 and typ not in self.idles:
                self.idles[typ] = np.asarray(p, np.float32)        # au repos depuis 0,5 s : sa pose d'attente
                if typ in self.cycles:
                    self._save()
            if typ not in self.cycles:
                tail = self._walk_tail(tr)
                if tail and tail[-1][0] - tail[0][0] > 1.2:
                    self._fit(typ, tail)

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

    def _fit(self, typ, tr):
        """periode par repliement (voir host_anim.py) : la longueur L ou les poses rangees par phase se superposent le mieux"""
        d = np.array([q[1] for q in tr]); X = np.array([q[3] for q in tr], np.float32)
        d -= d[0]
        if d[-1] < 2.5:
            return
        tot = float(np.sum(np.var(X, 0)))
        if tot <= 0:
            return
        res = {}
        for L in np.arange(0.5, 1.6, 0.01):
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
            m = (np.roll(m, 1, 0) + 2 * m + np.roll(m, -1, 0)) / 4
            self.cycles[typ] = (m.astype(np.float32), L)
            self._save()
            print('marche : cycle appris pour le type %d (%.2f unite par cycle, residu %.2f)' % (typ, L, err), flush=True)

    def pose(self, e, typ, x, y, cap, now, height=0.0):
        """pose rejouee pour l'entite e (octets, 48 floats), ou None si rien d'appris. Un type pas encore vu de pres
        prend le cycle d'un autre, a l'echelle de sa hauteur (height : celle de sa derniere pose du jeu, 0 = inconnue)"""
        st = self.rep.setdefault(e, [0.0, [], False])
        if st[1]:
            pt, px, py = st[1][-1]
            if now - pt > 1.0:
                st[1] = []                                   # pas vue depuis un moment : repart de la
            else:
                step = math.dist((x, y), (px, py))
                if step < 2.0:
                    recule = (x - px) * math.cos(cap) + (y - py) * math.sin(cap) < -0.5 * step
                    st[0] += -step if recule else step
        st[1].append((now, x, y))
        while st[1][0][0] < now - 0.3:
            st[1].pop(0)
        span = now - st[1][0][0]
        v = math.dist(st[1][0][1:], (x, y)) / span if span > 0.05 else 0.0
        st[2] = v > 0.5 if not st[2] else v > 0.2
        k, scale = typ, 1.0
        if typ not in self.cycles and self.cycles:
            k = next(iter(self.cycles))
            h0 = float(self.cycles[k][0][:, 1::3].max())
            scale = height / h0 if height > 0.2 and h0 > 0.2 else 1.0
        if st[2] and k in self.cycles:
            c, L = self.cycles[k]
            L *= scale
            n = len(c); f = (st[0] / L) % 1.0 * n; i = int(f) % n; a = f - int(f)
            p = (c[i] * (1 - a) + c[(i + 1) % n] * a) * scale
        elif typ in self.idles:
            p = self.idles[typ]
        elif k in self.idles:
            p = self.idles[k] * scale
        else:
            return None
        return np.asarray(p, '<f4').tobytes()

    def forget(self, alive):
        for e in [e for e in self.rep if e not in alive]:
            del self.rep[e]
