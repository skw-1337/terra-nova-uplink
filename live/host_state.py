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
# An older guest drops what it does not know; an older host sends none (the guest's window then says nothing).
import re, struct, time

TASK, MISSION, RSB = 0x36F4B4, 0x359708, 0x35CD9C
NONE, INTRO, MENU, SAVES, LOADING, BASE, BRIEFING, OUTFIT, LAUNCH, MISSION_ON, PAUSED, AFTER = range(12)
# the script's position where a screen waits -> the state (main menu, the saves list, a save loading, the base's
# hall and its briefing room, Mission Outfitting)
SCRIPT = {0x269B: MENU, 0x017A: SAVES, 0x207D: LOADING, 0x0720: BASE, 0x0975: BASE, 0x1A9B: OUTFIT}
SEND_EVERY = 0.5


class HostState:
    def __init__(self, g, master, pid_addr, send):
        """g: the game's memory; send(packet): to the guest's window (the bridge's own way: local or through Steam)"""
        self.g, self.master, self.pid_addr, self.send = g, master, pid_addr, send
        self.state, self.last_t, self.was_in, self.seen_t = NONE, 0.0, False, 0.0
        self.said = None

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
            self.was_in = True
        elif pos in SCRIPT:                             # (first: the last video's name stays after it ended)
            st = SCRIPT[pos]
            if st in (MENU, SAVES, BASE):
                self.was_in = False
        elif movie.startswith('BRIEF'):
            st = BRIEFING
        elif movie in ('LGA', 'OPENERA'):
            st = INTRO
        elif self.was_in:
            st = AFTER                                  # the mission over: its end, the debriefing, back to the base
        elif self.state in (OUTFIT, LAUNCH):
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
        key = (st, mission, movie)
        if key != self.said or now - self.seen_t > SEND_EVERY:
            if key != self.said and st != self.state:
                print('host state: %d mission %d video %r' % (st, mission, movie), flush=True)
            self.said, self.seen_t, self.state = key, now, st
            custom = 2 if self._u32(RSB) else 0
            self.send(b'HST' + struct.pack('<BBH8sB', 1, st, mission, movie.encode('ascii', 'replace')[:8], custom))


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
