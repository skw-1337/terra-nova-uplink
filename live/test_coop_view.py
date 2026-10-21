# Test of the online coop view (coop_view.py): synthetic missions of 150 and 400 entities (decor, suits walking,
# vehicles, shots and debris coming and going, a building destroyed, a class 4 entity that moves, one entity off the
# map), encoded at 20 views a second and decoded; every rebuilt view must be the host's view to the quantization
# (positions 1/128 unit, joints 1/4096 unit, the rest exact). Then the same with lost deltas and a guest joining
# late (it asks for the decor, 'R'). Prints the bytes a second before (30 zlib views a second) and after.
# With Godot (GODOT, or godot on the PATH) the guest's decoder, scripts/coop_view.gd, is run on the same messages and
# must give the same bytes as Decoder here.
#   python live/test_coop_view.py [--seconds 10] [--no-godot]
import math, os, random, shutil, struct, subprocess, sys, tempfile, zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import coop_view as cv

HERE = os.path.dirname(os.path.abspath(__file__))
SECONDS = float(sys.argv[sys.argv.index('--seconds') + 1]) if '--seconds' in sys.argv else 10.0
OLD_HZ, NEW_HZ = 30, 20
f32 = lambda v: struct.unpack('<f', struct.pack('<f', v))[0]


def angle(u):                                  # the bridge's heading: the game's u16 angle word
    return (u & 0xffff) / 65536 * 2 * math.pi


class Mission:
    """A synthetic game table, stepped in time. Counts: decor (class 0 / 4), suits (class 1, `posed` of them with
    joints), vehicles (2), probes (3), shots (5) and debris (6) about `fx` at a time."""

    def __init__(self, seed, decor, suits, posed, vehicles, probes, fx):
        self.r = r = random.Random(seed)
        self.ents = {}                         # index -> [class, type, active, x, y, z, heading word or float, extra]
        i = 0
        for k in range(decor):
            cls = 4 if k % 4 == 0 else 0
            self.ents[i] = [cls, r.randrange(40), 1, r.uniform(10, 500), r.uniform(10, 500), r.uniform(0, 30), r.randrange(65536), None]
            i += 1
        self.building = i - 4                  # a class 4 entity destroyed at 1/3 of the run
        self.lift = i - 8                      # a class 4 entity that moves after 1/2 of the run
        self.ents[self.building][0] = self.ents[self.lift][0] = 4
        self.suits = []
        for k in range(suits):
            self.ents[i] = [1, r.randrange(10), 1, r.uniform(100, 400), r.uniform(100, 400), r.uniform(0, 30), r.randrange(65536),
                            {'walk': r.random() < 0.6, 'phase': r.uniform(0, 6), 'posed': k < posed, 'turn': r.uniform(-300, 300)}]
            self.suits.append(i)
            i += 1
        self.ents[self.suits[-1]][2] = 0       # a dead one
        for k in range(vehicles + probes):
            self.ents[i] = [2 if k < vehicles else 3, r.randrange(20), 1, r.uniform(50, 450), r.uniform(50, 450),
                            r.uniform(0, 40), r.randrange(65536), {'v': r.uniform(0, 6) if r.random() < 0.5 else 0.0}]
            i += 1
        self.ents[i] = [2, 3, 1, 900.0, -300.0, 12.5, 0, None]   # off the map: float32 positions
        i += 1
        self.fx_from, self.fx = i, fx
        self.free = list(range(i, 300))
        self.t = 0.0

    def step(self, dt):
        r, self.t = self.r, self.t + dt
        if self.building in self.ents and self.t > SECONDS / 3:
            self.ents[self.building][1:3] = [41, 0]               # destroyed: another type, inactive
        if self.t > SECONDS / 2:
            e = self.ents[self.lift]
            e[5] += 0.4 * dt                                      # moves up: leaves the decor
        for i in self.suits:
            e = self.ents[i]
            s = e[7]
            if s['walk'] and e[2]:
                e[6] = (e[6] + int(s['turn'] * dt * 60)) & 0xffff
                h = angle(e[6])
                e[3] += math.cos(h) * 1.8 * dt
                e[4] += math.sin(h) * 1.8 * dt
                s['phase'] += dt * 7
        for i, e in self.ents.items():
            if e[0] in (2, 3) and e[7] and e[7]['v']:
                h = angle(e[6])
                e[3] += math.cos(h) * e[7]['v'] * dt
                e[4] += math.sin(h) * e[7]['v'] * dt
                e[6] = (e[6] + 40) & 0xffff
        live = [i for i in self.ents if i >= self.fx_from and self.ents[i][0] >= 5]
        for i in live:
            e = self.ents[i]
            e[7]['life'] -= dt
            if e[7]['life'] <= 0:
                del self.ents[i]
                self.free.append(i)
                continue
            e[3] += e[7]['vx'] * dt
            e[4] += e[7]['vy'] * dt
            e[5] += e[7]['vz'] * dt
        while len(live) < self.fx and self.free and r.random() < 0.5:
            i = self.free.pop(r.randrange(len(self.free)))
            shot = r.random() < 0.5
            typ = r.randrange(27) if shot else r.choice([1, 2, 28, 29, 33])
            head = r.randrange(65536)
            if not shot and typ in (28, 29):
                head = float(r.randrange(65536))                  # dust: a number in the heading
            elif not shot and typ == 33:
                head = float(r.choice([-1, 1100, 1000, 7]))       # armour debris: the suit's armour
            sp = 60 if shot else 2
            self.ents[i] = [5 if shot else 6, typ, 1, r.uniform(80, 420), r.uniform(80, 420), r.uniform(0, 30), head,
                            {'life': r.uniform(0.2, 1.5) if shot else r.uniform(1, 4), 'vx': r.uniform(-sp, sp),
                             'vy': r.uniform(-sp, sp), 'vz': r.uniform(-1, 1)}]
            live.append(i)

    def view(self, me):
        p = self.ents[me]
        cam = struct.pack('<6f2i', p[3], p[4], p[5] + 0.32, angle(p[6]), 0.1 * math.sin(self.t), 91.5, 0, me)
        body, joints = [], []
        for i in sorted(self.ents):
            e = self.ents[i]
            h = e[6] if isinstance(e[6], float) else angle(e[6])
            body.append(struct.pack('<4i4f', i, e[0], e[1], e[2], e[3], e[4], e[5], h))
            if e[0] == 1 and e[2] and e[7]['posed']:
                ph = e[7]['phase']
                pts = []
                for j in range(16):                               # right, up, forward; ground at 0
                    sw = math.sin(ph + j * 0.7) * 0.18 if e[7]['walk'] else 0.0
                    pts += [((j % 4) - 1.5) * 0.08, 0.1 * j + 0.02 * math.cos(ph * 2) * e[7]['walk'], sw]
                joints.append(struct.pack('<if48f', i, e[5], *pts))
        door = int(self.t * 9000) & 0xffff                     # an articulated part turning (the dropship's door)
        arts = struct.pack('<iiHH', 1, 5, door, 0)
        return (cam[:24] + struct.pack('<i', len(body)) + cam[28:] + b''.join(body) + struct.pack('<i', len(joints)) +
                b''.join(joints) + arts)


def same(a, b):
    """The rebuilt view b is the host's view a, to the quantization: '' if so, else what differs."""
    ca, ea, ja, aa = cv.parse(a)
    cb, eb, jb, ab = cv.parse(b)
    if ca[:24] != cb[:24] or ca[28:] != cb[28:]:
        return 'camera'
    if aa != ab:
        return 'articulated parts'
    if list(ea) != list(eb) or list(ja) != list(jb):
        return 'indices %s / %s, joints %s / %s' % (sorted(set(ea) ^ set(eb))[:8], len(eb), sorted(set(ja) ^ set(jb))[:8], len(jb))
    pt = cv.POS_STEP / 2 + 1e-4
    for i in ea:
        x, y = ea[i], eb[i]
        if x[:12] != y[:12] or x[24:] != y[24:]:
            return 'entity %d: class / type / active / heading' % i
        if any(abs(u - v) > pt for u, v in zip(struct.unpack_from('<3f', x, 12), struct.unpack_from('<3f', y, 12))):
            return 'entity %d: position %s / %s' % (i, struct.unpack_from('<3f', x, 12), struct.unpack_from('<3f', y, 12))
    jt = cv.JOINT_STEP / 2 + 1e-6
    for i in ja:
        x, y = ja[i], jb[i]
        if x[:4] != y[:4] or any(abs(u - v) > jt for u, v in zip(struct.unpack_from('<48f', x, 4), struct.unpack_from('<48f', y, 4))):
            return 'joints %d' % i
    return ''


def run(name, mission_args, loss=0.0, join_at=None, seed=1):
    m = Mission(seed, *mission_args)
    me = m.suits[0]
    old_bytes = n_old = 0
    enc, dec = cv.Encoder(), cv.Decoder() if join_at is None else None
    lose = random.Random(seed + 7)
    sizes = {'VKF': 0, 'VDC': 0, 'VDL': 0, 'VDP': 0}
    big_delta = n_delta = split = most_parts = 0
    checked, bad, messages, outputs = 0, [], [], []
    t, dt = 0.0, 1 / (OLD_HZ * NEW_HZ // math.gcd(OLD_HZ, NEW_HZ))  # 60 steps a second: both rates on the grid
    k, n_ents = 0, []
    while t < SECONDS:
        m.step(dt)
        t, k = t + dt, k + 1
        view = m.view(me)
        if k % (60 // OLD_HZ) == 0:
            old_bytes += len(zlib.compress(view, 6))              # before: the whole view, zlib 6, 30 a second
            n_old += 1
        if k % (60 // NEW_HZ):
            continue
        n_ents.append(struct.unpack_from('<i', view, 24)[0])
        if dec is None and t >= join_at:
            dec = cv.Decoder()                                    # the guest joins now: it missed the first decor
        msgs = enc.encode(view, t)
        delta = [msg for msg in msgs if msg[:3] in (b'VDL', b'VDP')]
        if delta:
            n_delta += 1
            big_delta = max(big_delta, sum(map(len, delta)))
            split += len(delta) > 1
            most_parts = max(most_parts, len(delta))
        for msg in msgs:
            sizes[msg[:3].decode()] += len(msg)
            assert len(msg) <= cv.MAX_PACKET or msg[:3] not in (b'VDL', b'VDP')
            if msg[:3] in (b'VDL', b'VDP') and lose.random() < loss:
                continue                                          # lost on the way (unreliable, each packet)
            if dec is None:
                continue
            messages.append(msg)
            out = dec.feed(msg)
            outputs.append(out or b'')
            if out is not None:
                checked += 1
                why = same(view, out)
                if why:
                    bad.append('t=%.2f %s' % (t, why))
        if dec is not None and dec.waiting_decor():
            enc.resync()                                          # 'R' (the host bridge applies it to the next view)
    new_bytes = sum(sizes.values())
    print('%s: %d-%d entities, %d suits posed' % (name, min(n_ents), max(n_ents), mission_args[2]))
    print('  before: %6.0f B/s  (%d views/s, %.0f B a view)' % (old_bytes / SECONDS, OLD_HZ, old_bytes / n_old))
    print('  after : %6.0f B/s  (%d views/s: keyframes %.0f, deltas %.0f, decor %.0f B/s)'
          % (new_bytes / SECONDS, NEW_HZ, sizes['VKF'] / SECONDS, (sizes['VDL'] + sizes['VDP']) / SECONDS, sizes['VDC'] / SECONDS))
    print('          biggest delta %d B; %d / %d deltas in parts (at most %d packets of %d B)'
          % (big_delta, split, n_delta, most_parts, cv.MAX_PACKET))
    print('  %.1fx less;  %d views rebuilt and checked%s%s' % (old_bytes / new_bytes, checked,
          ', %d%% of the delta packets lost' % (loss * 100) if loss else '', ', guest joined at %.1f s' % join_at if join_at else ''))
    return bad, checked, messages, outputs


GD_CHECK = '''extends SceneTree
func _init() -> void:
	var CoopView = load("res://coop_view.gd")
	var dec = CoopView.new()
	var f := FileAccess.open("res://messages.bin", FileAccess.READ)
	var out := FileAccess.open("res://outputs.bin", FileAccess.WRITE)
	while f.get_position() < f.get_length():
		var msg := f.get_buffer(f.get_32())
		if msg.is_empty():
			dec = CoopView.new()                  # next run: a new guest
			continue
		var v: PackedByteArray = dec.feed(msg)
		out.store_32(v.size())
		out.store_buffer(v)
	out.close()
	quit()
'''


def godot_check(messages, outputs):
    exe = os.environ.get('GODOT') or shutil.which('godot') or shutil.which('godot4')
    if not exe:
        return 'skipped (no Godot: set GODOT)'
    d = tempfile.mkdtemp()
    try:
        open(os.path.join(d, 'project.godot'), 'w').write('config_version=5\n')
        shutil.copy(os.path.join(HERE, '..', 'scripts', 'coop_view.gd'), d)
        open(os.path.join(d, 'check.gd'), 'w').write(GD_CHECK)
        with open(os.path.join(d, 'messages.bin'), 'wb') as f:
            for msg in messages:                    # (empty: a new decoder)
                f.write(struct.pack('<I', len(msg)) + msg)
        p = subprocess.run([exe, '--headless', '--path', d, '--script', 'res://check.gd'], capture_output=True, text=True, timeout=300)
        path = os.path.join(d, 'outputs.bin')
        if not os.path.exists(path):
            return 'FAILED: Godot wrote nothing\n' + p.stdout[-2000:] + p.stderr[-2000:]
        raw, got, o = open(path, 'rb').read(), [], 0
        while o < len(raw):
            n = struct.unpack_from('<I', raw, o)[0]
            got.append(raw[o + 4:o + 4 + n])
            o += 4 + n
        if len(got) != len(outputs):
            return 'FAILED: %d outputs from Godot, %d from Python' % (len(got), len(outputs))
        diff = [k for k, (a, b) in enumerate(zip(got, outputs)) if a != b]
        if diff:
            return 'FAILED: %d of %d outputs differ (first: message %d)' % (len(diff), len(got), diff[0])
        return 'same bytes as Python on %d messages (%d views)' % (len(got), sum(1 for v in got if v))
    finally:
        shutil.rmtree(d, ignore_errors=True)


if __name__ == '__main__':
    SMALL = (70, 15, 10, 8, 3, 25)              # decor, suits, posed, vehicles, probes, shots + debris: ~150
    LARGE = (200, 40, 30, 25, 10, 90)           # ~400
    failed = False
    all_msgs, all_outs = [], []
    for name, args, loss, join in [('150 entities', SMALL, 0.0, None), ('400 entities', LARGE, 0.0, None),
                                   ('150 entities, lossy', SMALL, 0.25, None), ('400 entities, late guest', LARGE, 0.1, 3.3)]:
        bad, checked, msgs, outs = run(name, args, loss, join)
        all_msgs += [b''] + msgs
        all_outs += outs
        if bad or checked < NEW_HZ * SECONDS * (1 - loss) * 0.5:
            failed = True
            print('  FAILED: %d views differ, %d checked\n   ' % (len(bad), checked), '\n    '.join(bad[:10]))
        print()
    if '--no-godot' not in sys.argv:
        r = godot_check(all_msgs, all_outs)
        print('Godot decoder (scripts/coop_view.gd):', r)
        failed |= r.startswith('FAILED')
    print('FAILED' if failed else 'OK')
    sys.exit(1 if failed else 0)
