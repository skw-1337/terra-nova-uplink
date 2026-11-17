# Squadmates' subtitles (the launcher's "Subtitles", TN_SUBTITLES = 1; off unless asked). The game only plays a voice
# clip when a squadmate answers an order or reports; the bridge tells the viewer who speaks and what the clip means
# (packet 'SUBT', see live_bridge.py), the viewer writes it in the cockpit's style for as long as the clip plays.
#
# What the game has (English exe; the French one has the same code, its data elsewhere: found by code signatures):
# - one talker slot per squadmate, 0x28 bytes: +0 the pilot, +1 the handle of the clip it plays (-1: silent), +6 when
#   it started (the game's clock). A squadmate's slot: byte +7 of his pilot record (1 to 3; the player has none).
# - the sound library's channels, 0x4F bytes each: +0x18 the sound a channel plays. A talker's handle is its channel.
# - a pilot's clips: sound 0xBEA + (voice - 1) * 275 + clip, clip 0 to 264 (SPEECH\RESBRKnn.RES, one file a voice;
#   pilots 16 to 23 share voice 16, 24 to 31 voice 17, 32 has voice 18).
# - the clips are the takes of 94 events (table 0x8AF of RESSOUND.RES: first clip, number of takes): the game picks
#   one of an event's takes, among those it played least. Each voice has its own words for a take, so the subtitle is
#   what the EVENT means, not the words of the take: the game's own reply texts where it has one (strings 79 to 115
#   of resource 367 of RESGAME.RES, written for these replies and never shown: English, and French for the French
#   game), a short line of ours otherwise (0 in the table's string column). What raises each event was read in the
#   game's code (0x24A6A0 for the squad's AI, 0x2CE620 for the rest). Events the game never raises are left out.
import os, re, struct

# event, first clip, takes, the game's string (0: our own line), English, French
EVENTS = (
    (0x01,   0, 10,   0, 'Roger.', 'Reçu.'),                                           # plain acknowledgement
    (0x02,  10, 10,   0, 'Copy that.', 'Bien reçu.'),                                  # ... its second set
    (0x03,  20,  2,  80, 'Hey, watch it, Nik!', 'Hé, attention, Nik!'),                # hit by the player, once
    (0x04,  22,  2,  81, 'Are you trying to kill me?', 'Tu veux me tuer?'),            # ... twice
    (0x05,  24,  1,  82, "One more shot and I'm shooting back!", 'Encore un et je tire!'),
    (0x06,  25,  3,  83, "I'm on my way!", "J'y vais!"),                               # move order accepted
    (0x07,  28,  2,  84, "I'm in the middle of a fight - later!", 'Je suis en plein combat - plus tard!'),
    (0x08,  30,  1,  85, 'All done, heading out.', "C'est fini, on y va."),            # fight over, back to the move
    (0x09,  31,  3,  86, 'In position!', 'En position!'),                              # arrived (alone)
    (0x0a,  34,  2,  86, 'In position!', 'En position!'),                              # arrived (a group)
    (0x0b,  36,  1,  87, "Can't reach it!", 'Impossible à atteindre!'),                # no path, no nav point
    (0x0c,  37,  3,  90, "I can't detect!", 'Impossible à détecter!'),                 # no target
    (0x0d,  40,  2,  88, "Ok, I'll hold where I am.", 'OK, je reste où je suis.'),     # stop and wait accepted
    (0x0e,  42,  5,  89, "Ok, I'll attack!", 'OK, je vais attaquer!'),                 # attack accepted
    (0x0f,  47,  1,  91, "Nik, I can't hit a squadmate!", 'Nik, je ne peux pas tirer sur un des nôtres!'),
    (0x10,  48,  2,  92, 'We defeated this group!', 'Nous les avons vaincus!'),
    (0x11,  50,  2,  92, 'We defeated this group!', 'Nous les avons vaincus!'),
    (0x12,  52,  4,  94, 'Following you.', 'Je te suis.'),                             # follow me accepted
    (0x13,  56,  1,  95, 'Stopped following you.', 'Je ne te suis plus.'),
    (0x14,  57,  2,  96, "Ok, I'll engage the enemy.", "OK, j'engage l'ennemi."),      # attack tactic accepted
    (0x15,  59,  2,  97, "Ok, I'll try to avoid it.", "OK, je vais essayer de l'éviter."),
    (0x16,  61,  3,  98, 'Joining.', 'Je vous rejoins.'),                              # join accepted
    (0x17,  64,  1, 100, "I can't join the enemy!", "Impossible de rejoindre l'ennemi!"),
    (0x18,  65,  2, 101, "Ok, I'll split.", 'OK, je me détache.'),                     # split off accepted
    (0x19,  67,  1, 102, 'I am already alone.', 'Je suis déjà en solo.'),
    # a remark at the mission's start, on the planet or the weather: what is said is not known, only its subject
    (0x1a,  68,  3,   0, '[Remark about the planet]', '[Remarque sur la planète]'),
    (0x1b,  71,  3,   0, '[Remark about the planet]', '[Remarque sur la planète]'),
    (0x1c,  74,  3,   0, '[Remark about the planet]', '[Remarque sur la planète]'),
    (0x1d,  77,  3,   0, '[Remark about the planet]', '[Remarque sur la planète]'),
    (0x1e,  80,  3,   0, '[Remark about the clear weather]', '[Remarque sur le beau temps]'),
    (0x1f,  83,  3,   0, '[Remark about the rain]', '[Remarque sur la pluie]'),
    (0x20,  86,  3,   0, '[Remark about the snow]', '[Remarque sur la neige]'),
    (0x21,  89,  2,   0, '[Remark about the dark]', "[Remarque sur l'obscurité]"),
    (0x22,  91,  5, 110, 'Enemy detected!', 'Ennemi détecté!'),                        # first contact
    (0x23,  96,  7,  79, 'Under attack!', 'Attaque en cours!'),                        # first hit taken
    (0x24, 103,  2,   0, 'One enemy.', 'Un ennemi.'),                                  # the count of enemies seen
    (0x25, 105,  2,   0, 'Two enemies.', 'Deux ennemis.'),
    (0x26, 107,  4,   0, 'Three enemies.', 'Trois ennemis.'),
    (0x27, 111,  4,   0, 'Four enemies.', 'Quatre ennemis.'),
    (0x28, 115,  2,   0, 'Five enemies.', 'Cinq ennemis.'),
    (0x29, 117,  3,   0, 'Drone spotted!', 'Drone repéré!'),
    (0x2a, 120,  3,   0, 'Drone down!', 'Drone abattu!'),
    (0x2b, 123,  2,   0, 'Drones are gone.', 'Plus de drones.'),
    (0x2c, 125,  2,   0, 'Engaging!', "J'engage!"),                                    # first shot (alone)
    (0x2d, 127,  4, 107, 'At moderate damage.', 'Dégâts modérés.'),
    (0x2e, 131,  3,   0, "We're engaging!", 'On engage!'),                             # first shot (a group)
    (0x30, 137,  5,   0, "We're taking damage.", 'On prend des dégâts.'),
    (0x31, 142,  5,   0, "We're badly damaged!", 'On est gravement touchés!'),
    (0x32, 147,  4, 107, 'At moderate damage.', 'Dégâts modérés.'),
    (0x33, 151,  3, 108, 'At heavy damage!', 'Dégâts importants!'),
    (0x34, 154,  2, 111, 'HELP! Suit critical.', "A L'AIDE! Combi dans le noir."),
    (0x35, 156,  2,   0, "I'm down!", 'Je suis à terre!'),                             # his suit is destroyed
    (0x36, 158,  3, 114, "We're winning this fight!", 'Nous avons gagné ce combat!'),
    (0x37, 161,  2,   0, "I'm winning this fight!", 'Je gagne ce combat!'),
    (0x38, 163,  3, 115, 'Situation is rough.', 'La situation se corse.'),
    (0x39, 166,  2, 112, 'EVAC!', 'EVAC!'),                                            # the group pulls back
    (0x3b, 171,  7, 109, 'Bogey down!', 'Bandit abattu!'),                             # he destroyed an enemy
    (0x3e, 183,  3,   0, 'All clear.', 'Zone dégagée.'),                               # no enemy left in sight
    (0x3f, 186,  4,   0, 'At light damage.', 'Dégâts légers.'),                        # status report
    (0x40, 190,  4, 107, 'At moderate damage.', 'Dégâts modérés.'),
    (0x41, 194,  3, 108, 'At heavy damage!', 'Dégâts importants!'),
    (0x49, 212,  4,   0, 'Repairs complete.', 'Réparation terminée.'),
    (0x4c, 221,  1,   0, 'PBA rebooted.', 'PBA réamorcé.'),                            # the missions' own tasks
    (0x4d, 222,  1,   0, 'Cannon is ready.', 'Canon prêt.'),
    (0x4e, 223,  1,   0, 'Station reprogrammed.', 'Station reprogrammée.'),
    (0x4f, 224,  1,   0, 'Station reprogrammed.', 'Station reprogrammée.'),
    (0x50, 225,  1,   0, 'Spacecraft repaired.', 'Vaisseau réparé.'),
    (0x51, 226,  1,   0, 'Telescope rewired.', 'Télescope réarmé.'),
    (0x53, 231,  3,   0, "Can't rewire that.", 'Impossible de réarmer ça.'),
    (0x54, 234,  5,   0, 'Turret rewired.', 'Tourelle réarmée.'),
    (0x56, 243,  4,   0, 'Charge placed.', 'Explosifs posés.'),
    (0x58, 250,  1,   0, 'Placing charge.', 'Je pose les explosifs.'),                 # (one clip a fuse)
    (0x59, 251,  1,   0, 'Placing charge.', 'Je pose les explosifs.'),
    (0x5a, 252,  1,   0, 'Placing charge.', 'Je pose les explosifs.'),
    (0x5c, 258,  6,   0, 'Negative.', 'Négatif.'),                                     # order refused
    (0x5d, 264,  1,   0, 'The telescope blew up!', 'Le télescope a explosé!'),
)
SOUND0, PER_VOICE, CLIPS = 0xBEA, 275, 265
SLOT, CHANNEL = 0x28, 0x4F


def voice(pilot):
    """the voice of a pilot (the game's 0x2CDC34)"""
    if pilot < 0x10: return pilot
    return 0x10 + (1 if pilot >= 0x18 else 0) + (1 if pilot == 0x20 else 0)


def event_of(clip):
    """(event, the game's string or 0, English, French) of a clip, None if it is none's"""
    for ev, first, takes, string, en, fr in EVENTS:
        if first <= clip < first + takes: return (ev, string, en, fr)
    return None


def _find(code, *parts):
    pat = b''.join(b'(....)' if p is None else p if isinstance(p, bytes) else re.escape(bytes.fromhex(p)) for p in parts)
    for m in re.finditer(pat, code, re.S):
        v = [struct.unpack('<I', b)[0] for b in m.groups()]
        if all(0x300000 <= a < 0x500000 for a in v): return v
    return None


def clip_lengths(game_dir):
    """{sound: seconds} of the voice clips (Creative Voice files, 8 bits; the files' directories only are read)"""
    out = {}
    d = os.path.join(game_dir or '', 'TNOVA', 'SPEECH')
    try:
        names = [n for n in os.listdir(d) if re.fullmatch(r'(?i)RESBRK\d\d\.RES', n)]
    except OSError:
        return out
    for n in names:
        try:
            with open(os.path.join(d, n), 'rb') as f:
                if f.read(14) != b'LG Res File v2': continue
                f.seek(0x7C); diro = struct.unpack('<I', f.read(4))[0]
                f.seek(diro); count, off = struct.unpack('<HI', f.read(6))
                rows = f.read(10 * count)
                for k in range(count):
                    rid, a, b = struct.unpack_from('<HII', rows, 10 * k)
                    size = a & 0xFFFFFF
                    f.seek(off); head = f.read(36)
                    off += (((b & 0xFFFFFF) if (a >> 24) & 1 else size) + 3) & ~3
                    # header (26 bytes), then a block of type 1: its length (3 bytes), the rate's byte (1 000 000 /
                    # (256 - r)); or of type 9: its length, the rate (4 bytes), 8 more bytes. (A line a voice does not
                    # have is a clip of 6 samples.)
                    if head[:19] != b'Creative Voice File' or len(head) < 36: continue
                    n_bytes = int.from_bytes(head[27:30], 'little')
                    if head[26] == 1:
                        out[rid] = max(0, n_bytes - 2) * max(1, 256 - head[30]) / 1000000.0
                    elif head[26] == 9:
                        out[rid] = max(0, n_bytes - 12) / max(1.0, float(struct.unpack_from('<I', head, 30)[0] & 0xFFFF))
        except (OSError, struct.error):
            pass
    return out


class Subtitles:
    def __init__(self, g, code, french=False, game_dir=None, log=print):
        """g: the game's memory; code: its code as read at 0x200000; french: the French game (its own strings);
        game_dir: the game's folder (the clips' lengths)"""
        self.g, self.french, self.log = g, french, log
        # the four pilot records, 0x32 bytes each, the player first (+0 in use, +2 entity, +6 pilot, +7 talker slot):
        # mov edx, 0x32 / cmp word [edx + pilots], 0 / je / mov ebx, [edx + pilots + 4] / sar ebx, 0x18
        v = _find(code, 'ba320000006683ba', None, '0074', b'.', '8b9a', None, 'c1fb18')
        self.pilots = v[0] if v and v[1] == v[0] + 4 else None
        # lea eax, [edx * 4] / add eax, edx / mov dword [eax * 8 + slots + 1], -1   (a clip's end: the slot is silent)
        v = _find(code, '01d0c704c5', None, 'ffffffff')
        self.slots = v[0] - 1 if v else None
        # lea ecx, [esi * 4] / add ecx, esi / shl ecx, 4 / sub ecx, esi / add ecx, channels / mov al, [esp + 0xc]
        v = _find(code, '8d0cb50000000001f1c1e10429f181c1', None, '8a44240c896901')
        self.channels = v[0] if v else None
        self.ok = None not in (self.pilots, self.slots, self.channels)
        self.lengths = clip_lengths(game_dir) if self.ok else {}
        self.said = {}                        # slot -> [(handle, start), its number, the packet's body, since when]
        self.n = 0
        log('subtitles: pilots %s, talkers %s, sound channels %s, %d clip lengths' % (tuple(
            '%#x' % a if a else 'not found' for a in (self.pilots, self.slots, self.channels)) + (len(self.lengths),)))

    def poll(self, now, in_mission=True):
        """the 'SUBT' packets to send now: one when a squadmate starts a clip, again every fifth of a second while it
        plays (its last one says it is over).
        'SUBT' + number (u8), squadmate 1-3 (u8), pilot (u8), event (u8), bit 0 playing / bit 1 a line of ours (u8),
        the clip (u16), its length in ms (u16, 0: not known), the text (UTF-8)"""
        if not self.ok: return []
        out = []
        g = self.g
        rec = g.read(self.pilots, 0x32 * 4)
        slots = g.read(self.slots, SLOT * 4)
        for k in (1, 2, 3):
            r = rec[0x32 * k:0x32 * k + 8]
            s = r[7]
            was = self.said.get(k)
            handle = -1
            if in_mission and r[0] and 1 <= s <= 3:
                handle, start = struct.unpack_from('<iI', slots, SLOT * s + 1)[0], struct.unpack_from('<I', slots, SLOT * s + 6)[0]
            if handle < 0 or handle > 63:
                if was:                       # over: said once more, not playing
                    if was[2]: out.append(b'SUBT' + bytes([was[1]]) + was[2][:3] + bytes([was[2][3] & ~1]) + was[2][4:])
                    del self.said[k]
                continue
            if was and was[0] == (handle, start):
                if was[2] and now - was[3] >= 0.2:
                    was[3] = now
                    out.append(b'SUBT' + bytes([was[1]]) + was[2])
                continue
            pilot = slots[SLOT * s]
            sound = struct.unpack('<H', g.read(self.channels + CHANNEL * handle + 0x18, 2))[0]
            # (read again: the slot still plays that clip, the channel was not given to another sound meanwhile)
            if struct.unpack('<i', g.read(self.slots + SLOT * s + 1, 4))[0] != handle: continue
            clip = sound - SOUND0 - (voice(pilot) - 1) * PER_VOICE
            ev = event_of(clip) if 0 <= clip < CLIPS else None
            if self.lengths.get(sound, 1.0) < 0.1: ev = None        # (a line this voice does not have: an empty clip)
            if ev is None:
                self.said[k] = [(handle, start), 0, None, now]      # (nothing to show for it)
                self.log('subtitles: squadmate %d, pilot %d, sound %d (clip %d): no line' % (k, pilot, sound, clip))
                continue
            self.n = self.n % 255 + 1
            text = ev[3] if self.french else ev[2]
            ms = min(65535, int(self.lengths.get(sound, 0) * 1000))
            body = bytes([k, pilot, ev[0], 1 | (0 if ev[1] else 2)]) + struct.pack('<HH', clip, ms) + text.encode('utf-8')
            self.said[k] = [(handle, start), self.n, body, now]
            out.append(b'SUBT' + bytes([self.n]) + body)
            self.log('subtitle %d: squadmate %d (pilot %d) sound %d clip %d event %#x "%s" %d ms' % (
                self.n, k, pilot, sound, clip, ev[0], text, ms))
        return out
