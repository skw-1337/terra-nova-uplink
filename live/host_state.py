# Where the host's game is, for the co-op guest's window ('HST' packets; scripts/host_state.gd shows it): its own
# front end (main menu, a save being picked or loaded, the base, the briefing, Mission Outfitting), the mission
# being started, played (or on one of the game's screens over it: paused, options, map), and after it.
# Read in the game (English exe, measured 17/11/2026 on a campaign save, mission 30): the front end is a script the
# game runs in a task, its object at [0x36F4B4]; the script's position (word +0x10) says which screen waits, the
# word +0x24 what for. The video playing: the last .SMK file DOS opened (the bridge's own way, menu_step). In a
# mission: the player's entity record in use (as coop_guest.py). Over the mission, one of the game's screens: the
# bridge's own flag (its menu_step: the 3D stopped or a menu's mouse frame).
#   'HST' + version (1) + state (u8) + mission number (u16, the MISSn file; 0: not known) + video (8 bytes, ASCII,
#   zero-padded: the .SMK playing) + flags (u8: 1 the host is the one choosing, 2 the mission is a custom one)
#   then (a newer host) the frame of the video the game shows (u16; 0xFFFF: no video plays, 0xFFFE: not known), for
#   the guest's window to play the same video in step (scripts/coop_movie.gd)
# An older guest drops what it does not know; an older host sends none (the guest's window then says nothing).
# The video's frame: the game's Smacker player (RAD's library, in the exe at 0x300885) keeps its structure with the
# file's 104-byte header at its start ('SMK2', width, height, frames, rate...) and the next frame to show at +0x370;
# the game shows the one before. Closed (the video over or skipped), the structure is cleared. Measured 18/11/2026
# (English exe, BRIEF30A and SOPHTA): one structure, at 0x733BB8; the counter 15 a second; the frame shown on the
# game's screen = the counter - 1 (or - 2, the screen caught a little later). It holds the first frame about half a
# second (a briefing; its sound loading?) before it goes on.
import re, struct, time

TASK, MISSION, RSB = 0x36F4B4, 0x359708, 0x35CD9C
NONE, INTRO, MENU, SAVES, LOADING, BASE, BRIEFING, OUTFIT, LAUNCH, MISSION_ON, PAUSED, AFTER = range(12)
# the script's position where a screen waits -> the state (main menu, the saves list, a save loading, the base's
# hall and its briefing room, Mission Outfitting)
SCRIPT = {0x269B: MENU, 0x017A: SAVES, 0x207D: LOADING, 0x0720: BASE, 0x0975: BASE, 0x1A9B: OUTFIT}
SEND_EVERY = 0.5
SEND_EVERY_VIDEO = 0.25                 # (while a video plays: the guest's window keeps its step from these)
MEMSIZE = 29 * 1024 * 1024
FRAME_AT = 0x370


class MovieFrame:
    """the frame the game's video shows: its Smacker structure found once a video (where it was last, else searched)"""

    def __init__(self, g):
        self.g, self.addr, self.name, self.head, self.search_t, self.gave_up_t = g, 0x733BB8, '', b'', 0.0, 0.0

    def _ok(self, a):
        h = self.g.read(a, 24)
        if h[:4] != b'SMK2':
            return None
        w, hh, n = struct.unpack_from('<III', h, 4)
        return h if 0 < w <= 1280 and 0 < hh <= 1024 and 0 < n < 100000 and not (w | hh) & 3 else None

    def frame(self, name):
        if not name:
            self.name = ''
            return 0xFFFF
        now = time.time()
        if name != self.name:
            self.name, self.head, self.search_t, self.gave_up_t = name, b'', 0.0, now + 10.0
        try:
            if not self.head:
                h = self._ok(self.addr)
                if h is None and now - self.search_t > 0.5 and now < self.gave_up_t:
                    self.search_t = now
                    mem = self.g.read(0, MEMSIZE) or b''
                    i = mem.find(b'SMK2')
                    while i >= 0:
                        h = self._ok(i)
                        if h is not None and struct.unpack_from('<I', mem, i + FRAME_AT)[0] <= struct.unpack_from('<I', h, 12)[0]:
                            self.addr = i
                            break
                        h = None
                        i = mem.find(b'SMK2', i + 4)
                if h is None:
                    return 0xFFFE if now < self.gave_up_t else 0xFFFF
                self.head = h                              # (this video's: another one there is another video)
            h = self.g.read(self.addr, 24)
            if h != self.head:
                return 0xFFFF                              # closed: over or skipped
            n = struct.unpack('<I', self.g.read(self.addr + FRAME_AT, 4))[0]
            frames = struct.unpack_from('<I', h, 12)[0]
            return min(max(n - 1, 0), frames - 1)
        except (OSError, struct.error, TypeError):
            return 0xFFFE


class HostState:
    def __init__(self, g, master, pid_addr, send):
        """g: the game's memory; send(packet): to the guest's window (the bridge's own way: local or through Steam)"""
        self.g, self.master, self.pid_addr, self.send = g, master, pid_addr, send
        self.state, self.last_t, self.was_in, self.seen_t, self.outfitted = NONE, 0.0, False, 0.0, False
        self.said = None
        self.movie = MovieFrame(g)

    def _u16(self, a):
        return struct.unpack('<H', self.g.read(a, 2))[0]

    def _u32(self, a):
        return struct.unpack('<I', self.g.read(a, 4))[0]

    def read(self, menu_flag=False, movie=''):
        g = self.g
        me = self._u16(self.pid_addr + 2)
        in_mission = me < 0x1000 and g.read(self.master + me * 0x25, 2) == b'\x01\x01'
        t = self._u32(TASK)
        pos = self._u16(t + 0x10) if t else 0
        mission = self._u32(MISSION)
        mission = mission if 0 < mission < 0x10000 else 0
        if in_mission:
            st = PAUSED if menu_flag else MISSION_ON
            self.was_in, self.outfitted = True, False
        elif pos in SCRIPT:                             # (first: the last video's name stays after it ended)
            st = SCRIPT[pos]
            if st in (MENU, SAVES, BASE):
                self.was_in = self.outfitted = False
            if st == OUTFIT:
                self.outfitted = True
        elif movie.startswith('BRIEF'):
            st = BRIEFING
        elif movie in ('LGA', 'OPENERA'):
            st = INTRO
        elif self.was_in:
            st = AFTER                                  # the mission over: its end, the debriefing, back to the base
        elif self.outfitted:
            st = LAUNCH                                 # Outfit Complete: its video, the mission loading
        else:
            st = self.state if self.state != NONE else LOADING
        return st, mission, movie

    def step(self, menu_flag=False, movie=''):
        now = time.time()
        if now - self.last_t < 0.1:
            return
        try:
            st, mission, movie = self.read(menu_flag, movie)
        except (OSError, struct.error):
            return
        self.last_t = now
        fr = self.movie.frame(movie) if st not in (MISSION_ON, PAUSED) else 0xFFFF
        playing = fr < 0xFFFE
        key = (st, mission, movie, playing, 1 <= fr < 0xFFFE)   # (said at once when the game leaves its first frame)
        if key != self.said or now - self.seen_t > (SEND_EVERY_VIDEO if playing else SEND_EVERY):
            if key[:3] != (self.said or ())[:3] and st != self.state:
                print('host state: %d mission %d video %r' % (st, mission, movie), flush=True)
            self.said, self.seen_t, self.state = key, now, st
            custom = 2 if self._u32(RSB) else 0
            self.send(b'HST' + struct.pack('<BBH8sBH', 1, st, mission, movie.encode('ascii', 'replace')[:8], custom, fr))


def bridge_view():
    """what the bridge itself knows (it runs this module): a game screen over the mission, the video playing"""
    import sys
    m = sys.modules.get('__main__')
    cur = getattr(m, 'curseur', None) or {}
    ms = getattr(m, 'menu_step', None)
    return bool(cur.get('menu')), str(getattr(ms, 'mov', '') or '')


PORT = 47836                      # the guest window's host_state.gd (online: through the host window's coop_net.gd)


def tick(guest):
    """coop_guest.py's step, each pass: the host's state sent to his window (made at the first call)"""
    hs = getattr(guest, 'host_state', None)
    if hs is None:
        import coop_guest
        to = ('127.0.0.1', coop_guest.REMOTE_VIEW if guest.remote else PORT)
        hs = guest.host_state = HostState(guest.g, guest.master, guest.pid_addr, lambda pk: guest.s.sendto(pk, to))
    hs.step(*bridge_view())
