# The guest's own cockpit sounds, for his window (coop_guest.py sounds, scripts/coop_sound.gd).
# The game plays its player's cockpit sounds (kind 0, not placed) for the host only; the guest's suit is a squadmate's
# to it, and the bridge, not the game, moves it for his jets, Bound and weapon keys. What the host hears as his own in
# the game (measured on the game's voice table, 2026-11-18, mission 30; Uplink_audit_captures/81_sons_invite):
#   - a shot: the weapon's sound (table 0x395128 + 0x24 x type, word +2), kind 0, at its own volume (RESSOUND 2204:
#     2053 -> 110); the laser's (2046) looped while the fire is held. The guest's shots are played by the game as a
#     squadmate's: with TN+ coop's sound piece the squadmates' variant (+13, 0x290694) placed at his suit (kind 2),
#     with older builds the player's (kind 0, his suit's voice +0x82). Both become the player's sound, not placed.
#   - the jets: 1940 each time their thrust starts in the air (0x289241: the player's suit only; ground kicks none),
#     twice in a 2 s burst (take-off, then when they start to cost energy). Landing: no sound of its own.
#   - a weapon key: 2023, then the new weapon's selection sound (table word +0), when the slot changes (0x28aa30).
# These go to his window on voices 20-23 (an older window ignores them) with volume 255: "the sound's own volume".
import struct

W_SOUNDS, W_REC, W_TYPES = 0x395128, 0x24, 18          # weapon types 1-17: +0 selection sound, +2 shot sound
MATE = 13                                               # the squadmates' variant of a shot sound (0x290694)
JET_SOUND, SELECT_SOUND = 1940, 2023
OWN_VOICE0, OWN_VOICES = 20, 4
OWN_VOL = 255


class OwnSounds:
    def __init__(self, g):
        self.g = g
        self.shots = None                               # sound the game plays for his shot -> the player's sound
        self.select = {}                                # weapon type -> its selection sound
        self.queue = []
        self.n = 0

    def _table(self):
        if self.shots is None:
            self.shots = {}
            r = self.g.read(W_SOUNDS, W_REC * W_TYPES)
            for t in range(1, W_TYPES):
                sel, shot = struct.unpack_from('<2H', r, W_REC * t)
                if 1900 <= shot < 2300:
                    self.shots[shot] = shot
                    self.shots[shot + MATE] = shot
                if 1900 <= sel < 2300:
                    self.select[t] = sel
        return self.shots

    def shot(self, sound, kind, ent, gid, owned):
        """a voice of the game that is his own shot: the player's sound for it, else None. owned: the voice is his
        suit's (+0x82, older TN+ coop builds, kind 0)"""
        if not gid:
            return None
        if kind == 0 and owned:
            return self._table().get(sound, sound)
        if kind in (2, 5) and ent == gid:
            return self._table().get(sound)
        return None

    def jets(self):
        self.queue.append(JET_SOUND)

    def selected(self, wtype):
        self._table()
        self.queue.append(SELECT_SOUND)
        if wtype in self.select:
            self.queue.append(self.select[wtype])

    def packets(self):
        """'S' starts for the sounds made since the last update (not placed, own volume, played once)"""
        out = []
        for sound in self.queue:
            out.append(b'S' + struct.pack('<BHBBBH3f', OWN_VOICE0 + self.n % OWN_VOICES, sound, 0, 1, OWN_VOL, 0,
                                          0.0, 0.0, 0.0))
            self.n += 1
        self.queue = []
        return out
