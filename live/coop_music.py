# The game's music for the co-op guest's window ('MUS' packets; scripts/coop_music.gd plays it from his own files).
# The game (English exe, read 18/11/2026) plays its music through its MIDI driver (Miles), XMIDI sequences of
# RESSOUND.RES 2205-2221 picked by its music cues (RESSOUND.RES 2222: 10 bytes a cue, the FM arrangement's resource,
# the General MIDI one's, the sequence, its volume, the cue that follows, a fade). Its music library keeps 8 slots
# (count [0x44B950]) of 0x1D bytes at 0x44B800: +0 the volume asked, +7 the cue, +0xB the XMIDI file, +0x13 the
# sequence, +0x17 in use; their Miles sequences' handles at 0x44B8E8. A Miles sequence: +4 status (4 playing, 2 done),
# +0x10 the EVNT chunk (its 8-byte header), +0x14 the next event to play, +0x30 the intervals (1/120 s) still to wait
# before it, +0x34 the intervals played, +0x38 its volume now (fades). The game's settings: [0x35982E] the music driver
# (low 4 bits: music on; bit 4: General MIDI, else FM), [0x359832] its music volume (0-127, Miles' master volume).
#   'MUS' + version (1) + music volume + flags (1 on, 2 General MIDI) + count, then per slot playing:
#   slot (u8), cue (u16), resource (u16), sequence (u8), status (u8), volume (u8), offset in EVNT (u32), wait (u16),
#   intervals played (u16)
# Sent when what plays changes (a sequence starting, ending, its volume), and twice a second (the guest keeps its
# place on them: an older guest drops the packet, an older host sends none).
import struct, time, os

SLOTS, SLOT_N, SLOT_LEN, HANDLES = 0x44B800, 0x44B950, 0x1D, 0x44B8E8
DRIVER, MUSIC_VOL = 0x35982E, 0x359832
CUES = 2222
EVERY = 0.5
POLL = 0.05


class HostMusic:
    def __init__(self, g, data_dir, send):
        self.g, self.send = g, send
        self.cues = []
        try:
            import lgres
            r = lgres.load(os.path.join(data_dir or '', 'RESSOUND.RES')).get(CUES)
            if r:
                self.cues = [struct.unpack_from('<HH', f) for f in lgres.frames(r[2]) if len(f) >= 4]
        except (OSError, struct.error, ImportError):
            pass
        self.poll_t, self.sent_t, self.said, self.what = 0.0, 0.0, None, None

    def read(self):
        g = self.g
        drv = g.read(DRIVER, 1)[0]
        vol = g.read(MUSIC_VOL, 1)[0]
        n = min(struct.unpack('<I', g.read(SLOT_N, 4))[0], 8)
        slots = g.read(SLOTS, SLOT_LEN * n) if n else b''
        hs = struct.unpack('<%dI' % n, g.read(HANDLES, 4 * n)) if n else ()
        rows = []
        gm = 1 if drv & 0x10 else 0
        for i in range(n):
            s = slots[SLOT_LEN * i: SLOT_LEN * (i + 1)]
            h = hs[i]
            if not (0 < h < 0x4000000):
                continue
            q = g.read(h, 0x3C)
            if not q or len(q) < 0x3C:
                continue
            status, evnt, ptr = struct.unpack_from('<I', q, 4)[0], *struct.unpack_from('<II', q, 0x10)
            if status != 4 or not evnt:
                continue
            wait, played, svol = struct.unpack_from('<iii', q, 0x30)
            cue, seq = struct.unpack_from('<i', s, 7)[0], struct.unpack_from('<i', s, 0x13)[0]
            rid = self.cues[cue][gm] if 0 <= cue < len(self.cues) else 0
            rows.append((i, cue & 0xFFFF, rid, seq & 0xFF, status, max(0, min(127, svol)),
                         max(0, ptr - evnt - 8), max(0, min(0xFFFF, wait)), played & 0xFFFF))
        flags = (1 if drv & 0x0F else 0) | (2 if gm else 0)
        return vol, flags, rows

    def step(self):
        now = time.time()
        if now - self.poll_t < POLL:
            return
        self.poll_t = now
        try:
            vol, flags, rows = self.read()
        except (OSError, struct.error, TypeError):
            return
        playing = [r for r in rows if r[4] == 4]
        key = (vol, flags, tuple(r[:6] for r in playing))
        if key != self.said or now - self.sent_t > EVERY:
            what = tuple(r[1:4] for r in playing)
            if what != self.what:
                self.what = what
                print('music: %s' % (', '.join('cue %d res %d seq %d' % w for w in what) or 'none'), flush=True)
            self.said, self.sent_t = key, now
            self.send(b'MUS' + bytes([1, vol, flags, len(playing)]) +
                      b''.join(struct.pack('<BHHBBBIHH', *r) for r in playing))


def tick(guest):
    """coop_guest.py's step, each pass: the game's music state sent to his window (made at the first call)"""
    hm = getattr(guest, 'host_music', None)
    if hm is None:
        import coop_guest
        to = ('127.0.0.1', coop_guest.REMOTE_VIEW if guest.remote else coop_guest.HUD_PORT)
        hm = guest.host_music = HostMusic(guest.g, getattr(guest, 'data_dir', None), lambda pk: guest.s.sendto(pk, to))
    hm.step()
