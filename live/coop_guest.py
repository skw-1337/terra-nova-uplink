# Coop (TN+ Coop build only): a second player drives a teammate and sees through his eyes in a second Uplink window.
# TN+ Coop puts the coop code in the game at the main menu (code 0x46B040); this module picks the teammate, sends the
# guest's commands, aim and fire to the game (data page 0x46C000) and the guest's camera to his window (port 47831).
# Input: an XInput gamepad (left stick move / strafe, right stick look, right trigger fire) or the guest window
# itself (W/S/A/D, mouse, left button, F8 = next teammate), on port 47834. Online (--guest-remote) the local pad is not
# read: the guest window's coop_net.gd sends its own gamepad as 'P' packets (lx, ly, rx, ry int8 with XInput signs,
# fire 0 / 1), used only while fresh (0.3 s). The guest window's HUD gets 'GHD' packets (coop_hud.gd). Online the
# view goes as coop_view.py messages (keyframes, deltas, decor), view_hz a second; 'R' from the guest: decor again.
import builtins, ctypes, json, math, os, socket, struct, time, zlib
import host_state
import coop_music
import coop_lobby, coop_view
from coop_name import NameTag
from guest_equipment import GuestEquipment
from coop_aim import GuestAim
# his shots at what his crosshair is on (coop_aim.py; TN_COOP_AIM=0: 30 units along his view, as before), and each
# shot's aim in the bridge's output (TN_COOP_AIMLOG=1)
AIM_ON = os.environ.get('TN_COOP_AIM') != '0'
AIM_LOG = os.environ.get('TN_COOP_AIMLOG') == '1'

CAVE = 0x46B040
CAVE_WAIT = 60                    # seconds the bridge waits for it before saying it is missing
G_ON, G_FIRE, G_ID, G_TIM, G_CTRL, G_TGT = 0x46C000, 0x46C001, 0x46C002, 0x46C010, 0x46C020, 0x46C048
G_HIT = 0x46C200                  # 1v1 hit mailbox (TN+ Coop coop3): 1, +2 entity hit, +6 the guest's projectile that hit it
# versus: the guest's shots never collide with the host, so the bridge watches them (projectile entities: class 5, record
# 0x39BDF0 + n*0x1E, +6 the shooter, +0x16 range left) and sends the game a hit for one that crosses the host's body; the
# game then does the rest (damage by weapon, side hit, shield, armour, death). Spent ones (range 0) are retired (range -1)
# or they pile up and the guest cannot fire any more
PROJ, PROJ_N = 0x39BDF0, 0x1E
HIT_R, HIT_Z = 0.9, (-0.2, 2.6)    # the host's body: radius, height from his feet
G_JUMP, G_JV = 0x46C004, 0x46C120  # jump mailbox (TN+ Coop 1.2.2-coop2 and later): 1 = add G_JV (16.16) to the body's
                                  # speed (0x2F0CA5); one slot: written only once the cave has taken the last one
SHIFT = {0x2A, 0x36}              # Shift + a direction key: the game's directional jump (Bound, 0x27681D)
# W S A D: angle from the heading. The game's offsets: +0x4000 for C / Alt+Right (right), +0x8000 X / Down, +0xC000 Z /
# Alt+Left (left); the guest's A / D walk left / right, his S is back
JUMP_DIR = {0x11: 0.0, 0x1F: math.pi, 0x1E: -math.pi / 2, 0x20: math.pi / 2}
JUMP_V, JUMP_WAIT = (120, 80), 0xFA   # the game's one kick (flat, up) and its wait on the game clock (ms)
BOUND_GATE = 0x3C8                # suit record: the game's Bound only while this (signed) is under 0x30000 (meaning unknown)
# The game's Bound is tried on each press the game sees of a move key while Shift is down (0x276849), the key's
# repeats included: a held key repeats as the PC keyboard does in DOSBox (typematic: after 0.5 s, 10.9 a second),
# whatever Windows sends it. His window sends a press once, so his held move keys repeat here the same way. It leaps
# only if 4 footsteps have gone by (0x441361: +1 at each plant of a foot, 0x27E5B8; back to 0 once the legs leave the
# ground, 0x27FFDC) and while no foot swings (0x441359, from the contact test 0x27EDA0): a try now and then lands in
# the short stance after a plant. Holding Shift + W, the host leaps once in 1.7 to 5.4 s (3.2 s on average, 0.15 of
# the plants that pass the other gates). The game counts the player's feet only; the guest's are counted from his
# suit's feet (state bytes FEET, 2 = planted: legs record suit +0xDE, foot n at +0x235 + n x 0x44 + 0x18, state at
# +0x28). The game moves them only while his suit is drawn on the host's screen; else they stay planted and each
# 0.29 s of walking (the stride, host and guest alike) counts as a footstep, with the stance after it as one game update
REPEAT = (0.5, 1 / 10.9)
FEET, STEPS, STRIDE, STILL, STANCE = (0x353, 0x397), 4, 290, 600, 16
CONTACT = ((0xE2, (1, 2)), (0x353, (1,)), (0x397, (1,)))   # suit bytes: any of these values = off the ground (0x27EDA0)
# Lock (right button, gamepad RB), as the game's for its player (a click in its 3D view, 0x269F28, or its next-target
# key, then 0x262D4C): of the units in his view (the game's list of those on its screen; here within his field of
# view, 84.5 degrees across, and 120 units), not one of the squad, the one nearest the middle; the game then plays its
# lock sound (2021, his window plays it) and keeps the target while it is on his screen or within his suit's sensor
# range (suit +0xB6, 16.16 metres: / 6 for units, 0x262B00), else drops it. While it stays within 30 degrees of his view
# his shots aim at its middle. Right button again: as the game's click (0x262D4C), the unit under it instead, or no
# target when nothing is under it. (It was the unit within 12 degrees of the middle only: a click a little off a
# target locked nothing.)
LOCK_PICK, LOCK_KEEP, LOCK_RANGE = math.radians(42.25), math.radians(30), 120.0
LOCK_PICK_V, LOCK_KEEP_V = math.radians(32), math.radians(60)   # (the view's height: 3/4 of its width)
SENSOR = 0xB6
PICK_HALF, PICK_GROW, PICK_SIZE, PICK_NEAR = 149.0, 20.0, 0.8, math.radians(8)   # (the game's 3D window's half width, its click margin, a unit's half size, the nearest's cone)
TARGET_KEYS = {0x14: 1, 0x15: -1}   # the game's next / previous target keys (T, Y; his own keys turned into them)
LIVE_PORT, PLAY_PORT = 47831, 47834
HOST_LIVE = 47821             # the host's own window (the guest's map marker for it: 'GNAV')
REMOTE_VIEW = 47841           # online guest (--guest-remote): the host window's coop_net.gd sends it over Steam
# online: the bridge's packets about the picture relayed to the guest (relay), and their least gap (s): the sky's
# drift 5 a second (it moves slowly), the waypoint (its angle word turns every frame) twice; the rest when it changes
RELAY_GAP = {b'SKYO': 0.2, b'WAYP': 0.5, b'HAZE': 0.25, b'SLEN': 0.25, b'ARMS': 0.25, b'GAIT': 0.5, b'DEBR': 0.1}
KEYS = {0x11, 0x1F, 0x1E, 0x20, 0x39}   # the only keys a guest can hold: W S A D, Space (network input is filtered)
# The jets (Space), as the game's 0x288EF0 / 0x288F78 for a suit: near the ground a kick of 150 up every 2nd game
# update, unpaid; in the air free for 200 ms, then each update pays energy dt x 2^32 / ((f + 0x20000) / 3) (16.16, f =
# 0x442439; 1.03 a ms) and fuel ((rating / 15 << 9) x dt >> 16) & 0xFF (halved if suit +0xD is 4, none in mission
# 0x2F), none of either: no lift. No jets in mission 0x2E. The game's lift in the air (thrust into the body's +0x44,
# 0x269CF4) only exists for the player's suit and how the body turns it into speed is not decoded: JET_ACC (speed
# units/s per s) stands for it, set against the host's own jets (MISS30, Space held 2 s from full energy: the host
# 5.3 units up when it runs out, 12.0 at the top; the guest with 750: 6.4 and 12.2; with 1600 he went to 30).
# Damage to the jets (sputter, 0x27DF14) is left out
JET_ACC = float(os.environ.get('TN_JET_ACC', '750'))
JET_KICK, JET_FREE, AIR = 150, 200, 0x4000   # the ground kick, free airtime (ms), "near the ground" (0.25, 0x28927C)
# The ground under him: the game's height map (English exe: pointer at 0x36F50A, 513 x 513 points of 3 bytes, the
# height s16 at +1, >> 4, / 24 units), each cell cut in two triangles as the game's 0x2949C4 does. His suit's contact
# bytes (CONTACT) are no help: the game keeps them for the player's suit only (in flight the host's +0xE2 reads 2,
# the guest's stays 0 even 100 units up), so both the Bound's "on the ground" and the jets' band are his height over
# this, as the game's 0x28927C measures it
HMAP, HMAP_N = 0x36F50A, 513
# The ceiling: the game keeps the player's suit within 30 units of the ground. After each physics step (0x2D3D29),
# for the entity of word 0x441350 only, a body higher than the ground (0x2949C4) + 0x1E0000 is put back at that
# height, its vertical speed at 0, the rest of its motion kept (0x2F09E3, 0x2F0BC8). His suit is not the player's:
# jets held, it went on up (121 units in a test), and the host's game stopped for good when it came down, at over
# 20 units a second. The same limit for it here, each tick: from 30 units it lands at 10 units a second. A body:
# the entity's byte +0x22 = its handle, dword 0x44B9E4 + 4 x handle = its slot (under 0x60), its state at
# 0x44E0DD + 0x30 x slot: for x, y, z (0x10 apart) the position (6 x the entity's, 16.16), the speed, the
# acceleration
CEILING = 0x1E0000
BODY, BODY_SLOT, BODY_STATE, BODY_N, BODY_Z = 0x22, 0x44B9E4, 0x44E0DD, 0x30, 0x20
MISSION, NO_JETS, NO_FUEL, ENERGY_F = 0x359708, 0x2E, 0x2F, 0x442439
J_RATING, J_FUEL, J_HALF = 0xA6, 0xAA, 0x0D   # suit record: jets' rating (word), fuel (word), dword 4 = half the fuel
F8 = 0x42                     # next teammate
DROPSHIP = 0x1C               # Enter: the game's "Call dropship" key, posted to the host's game (the mission's end)
WEAPON_KEYS = {0x02: 0, 0x03: 1, 0x04: 2, 0x05: 3}   # 1-4: weapon slot (suit record +0xCE, the fire uses it)
SEL, SLOTS, SLOT_N = 0xCE, 0x45, 0xF                # selected slot, 4 weapon slots (+0 type: weapon names 1-17)
# a weapon key as the game's cockpit handles it (0x2760d1, then 0x28ab1c): slot +0xA = its ready time (game clock
# 0x446AE8), suit byte +7, per weapon type t (0x24 bytes at 0x395100): 0x395111 its two-slot flag, 0x395124 its switch delay
SLOT_READY, SUIT_B7, CLOCK = 0x0A, 0x07, 0x446AE8
W_TWO, W_DELAY, W_N = 0x395111, 0x395124, 0x24
W_RANGE = 0x39511E               # (a weapon's range, units: the game's lock text 0x26AA49)
HUD_PORT = 47832              # the guest window's coop_hud.gd: 'GHD' state, armour, max, entity (online: via 47841)
PBA, PBA_N = 0x3A5608, 0x582     # English exe: suit records
# the suit's power plant, 16.16 dwords: +0x86 the energy (shots draw from it), +0x8A its maximum (a hit on the
# plant lowers it, 0x28b938); the game's panel bar is the one over the other (0x26d944)
EN_CUR, EN_MAX = 0x86, 0x8A
PARTS = [(0x15 + 7 * k, 0x17 + 7 * k) for k in range(4)]   # the armour: 4 parts (+0x14 + 7k: flag, current, max, current)
# the pilot's health, the red bar at the top of the helmet (manual p. 31: it only drops once a part of the suit is
# breached): the bar's routine (0x2652a0) follows the suit's pointer +0x9C to a record, max at +1 and current at +3
# (words); in a squadmate's suit record these are +0x32 / +0x34, what the armour indicator's middle reads (0x26355c)
HEALTH_PTR, HEALTH_MAX, HEALTH_CUR = 0x9C, 0x32, 0x34
# the armour indicator (RESHLMHI.RES 506, drawn by 0x2635c8): a level 0-6 for each part (0x26350c: (12 - 11 x lost /
# max) / 2), in the picture's order front, left, right, back = the suit's parts 0, 1, 3, 2, then the pilot's (0x26355c)
IND_RES, IND_PARTS, IND_EDGE = 506, (0, 1, 3, 2), 0x2A
PILOTS, PILOT_N = 0x391E50, 0x32   # pilot records (English exe), 4: +0 in use, +2 entity (record 0: the player, then his squad)
# a unit's side: entity byte +0x21 = its AI record (0: none), 0x3832F0 + 0x14E * a (French exe: +0xB0, as the master
# table), byte +5 = 1 the player's side, 2 the enemy (0x24a6c7, 0x24a90c). The in-use byte +0 is not a test: 0 for the player
AI_SIDE, AI_N, AI_MAX = 0x3832F5, 0x14E, 0x3C
# the coloured brackets the game draws on the units on its screen (0x26A188, after the 3D: every unit of its list of
# drawn boxes but the target, 0x26A380 at the box's middle) in the colour 0x27D458 gives: none for decor (class 0 / 4);
# a soldier with a pilot record (his squad) the squadmate's colour (0x2769E8: SQUAD_COL + the record's byte +7); any
# other unit only once it is among his suit's contacts (suit +0xB2, its list at +0xC: 6 bytes each, 0 ends it), then
# its colour: a soldier 0x44 (type 0xD: 0x6E), class 2 0x22 (type > 3: 0x44), class 3 0x63 (type 7: 0x50, more:
# 0x6E; the mission's special one, word OBJ_SPECIAL, 0x4B). All 0x36 while byte IFF_ALL is set
SQUAD_COL, IFF_ALL, OBJ_SPECIAL, CONTACTS, IFF_MAX = 0x35B3ED, 0x42015A, 0x396868, 0xB2, 48
OK, DOWN, SPECTATE = 0, 1, 2
# the eye, as the game's routine 0x27ec90 puts the main view: neck (joint 9, suit record +0x21B, 3 x 16.16 in the world)
# + k x (neck - joint 8, +0x20F), k by the suit's kind (+0xDE, jump table 0x27ec64); then the camera's own height
# (the bridge's OEIL, 0x38FB1C). Measured in mission 30: 0.35-0.40 above the entity for suits 2 and 7, 0.47 suit 8, 0.8 mechs
EYE_K, EYE_K_ELSE, J9, J8, SUIT_KIND = {0: 0x4D65, 1: 0x5D17, 2: 0x4771, 10: 0x50D7}, 0x5174, 0x21B, 0x20F, 0xDE
HEADYAW, HEADPITCH, SLOPE, SLOPE_OFF = 0x441355, 0x441357, 0x35AEB4, 0x35F544   # English exe: the main view's terms
# The guest's cockpit (coop_hud.gd) is the host's game screen (320 x 400, palette indices + alpha, see live_bridge.py
# send_hud) with what is the host's own emptied: his panels' contents, compass, bars, rear view, and anything drawn in
# the 3D window that is not its frame (crosshair, armour indicator, target box). 'GCK' + palette + zlib(index, alpha).
# The boxes are the game's own (measured on its screen: portraits at 18, 277 + 28 k, the weapon picture at 217, 264),
# so that nothing of the host's shows around what the guest's window draws there.
CLEAR = [((17, 277, 99, 380), 60, 255),      # COMM panel, ENTIRE SQUAD box included (the guest's squad)
         ((217, 266, 298, 368), 60, 255),    # WEAPON panel, its title included (his weapon)
         ((118, 264, 202, 372), 0, 255),     # map (his own; the game's panel: 84 wide)
         ((33, 6, 289, 22), 0, 255),         # compass strip (his heading)
         ((146, 226, 172, 252), 0, 255)]     # rear view
# the two top bars: only their leds are put out (colour 0, as the game's own unlit ones), their frame stays; the
# guest's window lights them again in the game's cells. Rows 30-33; left bar x 73-148 (separators every 5 from 75),
# right bar (energy) x 165-247 (separators every 4 from 168)
# The cockpit's own regions (the table 0x389DF8: 8 pointers, x0, y0, x1, y1 at +8, built by the game for the cockpit of
# the suit worn): the panels move with the cockpit (the training suit's: COMM, map and WEAPON panels 8 lower and the
# WEAPON panel 8 further left than the boxes above, measured on the game's usual one). The boxes above are for that
# usual cockpit (COMM 17, 276; map 118, 264; WEAPON 217, 264; compass 33, 6); each is moved by its region's corner
# from there, and the corners are sent after the picture ('RGN' + 4 x <2h: COMM, map, WEAPON, compass) for the
# guest's window to draw where they are (coop_hud.gd)
REGIONS = 0x389DF8
REG_HOME = ((17, 276), (118, 264), (217, 264), (33, 6))
BAR_ROWS = (30, 34)
BAR_LEDS = [x for x in range(73, 149) if (x - 75) % 5] + [x for x in range(165, 248) if (x - 165) % 4 != 3]
# His map panel and the small box over it (coop_hud.gd), as the game draws the host's. The box (the HUD's region at
# 146, 226; 0x265094): the selected weapon's picture, washed through one of two colour tables when the weapon cannot
# fire (0x28f024: 1 the slot is destroyed, 2 no ammunition, 5 not ready yet; pointers 0x389DD0 for 1 and 2, 0x389DC8
# for 5). The map's marks (0x276ef8, a panel's map: zoom 4, one world unit a pixel): the mission's map notes (list
# 0x39A510, those of its zoom and of the panel), the contacts of the whole squad (each suit's list, 0x27d158: 6 bytes
# a contact, the entity first; merged, in the entities' order), his locked target, himself, the squad's waypoints
# (0x392170, 4 x 10 x 12 bytes), the nav marker (0x38FFF0, x and y 16.16). A unit's colour: 0x2769e8.
TINT_BAD, TINT_WAIT = 0x389DD0, 0x389DC8
W_AMMO = 0x39511A                         # per weapon type (W_N bytes): over 1 = it counts its ammunition (slot +4)
NAV = 0x38FFF0
NOTES, NOTES_END, NOTE_ZOOM = 0x39A510, 0x39A518, 4   # (the panel's zoom 4: bit 2 of a note's byte +0xD; its panel: bit 0 of +0xE)
CONTACTS_AT = {1: (PBA, PBA_N, 0xB2), 2: (0x3A19E8, 0x128, 0x4D), 3: (0x39E590, 0x14F, 0x62)}
SQUAD_COLOURS, DRONE, FOOTPRINTS, WAYPOINTS = 0x35B3ED, 0x396868, 0x3C5DD0, 0x392170
WAYPOINT_COLOURS = (0x38, 0x3F, 0x7E, 0x84)
M_CROSS, M_SELF, M_SHAPE, M_WAYPOINT, M_NAV, M_RECT, M_ROUND, M_TEXT, M_MATE, M_NOTEZ, M_SYS, M_ROW, M_WPN = range(13)
AI_REC, GROUPS, SPECIALTY, PILOT_REC, W_HEALTH = 0x3832F0, 0x380599, 0x39034D, 0x391F4D, 0x39511C   # (English exe)
# M_NOTEZ: a map note of any zoom (the game draws a note on a map of zoom z when bit (word 0x35B3DC + 2 z) of its byte
# +0xD is set: zooms 0-7 -> bits 4 3 3 2 2 1 1 0, 0x2784ae); an older guest window ignores the kind
# The guest's laser on the host's speakers. The cave fires for him as the game does for its player (the player's
# entity word is his during his pass), so the shot's sound takes the player's path (0x290524): heard as the host's
# own, its voice kept in his suit (+0x82: a voice of the game's table 0x370738, 0x4F bytes each; byte 0 the sound
# driver's sample, +0x17: 1 = played once). The laser's (weapon 4) is the one sound started to go on: the game stops
# it when its player lets the fire button go (0x290858, the host's suit only), so the guest's went on for ever.
# Nothing of the bridge can call the game's stop; the driver's sample (Miles: pointers at 0x44B600; +4 status, 4 =
# playing; +0x10 length, +0x18 position, +0x30 loops left, 0 = for ever) is told instead that this pass is its last:
# it ends by itself, the game frees the voice and empties the suit's.
SOUND, VOICES, VOICE_N, SAMPLES = 0x82, 0x370738, 0x4F, 0x44B600
SND_PIECE = 0x29055D              # TN+ coop's sound piece there (a call): his shots already sound like a squadmate's
LASER_SOUNDS = {2046}             # the one weapon sound the player's path plays until stopped (weapon 4, table 0x39512A)
# With TN+ coop's sound piece his shots take the squadmates' path (0x29079C): their own variant of the sound (+13 for
# the player's side, the laser's 2059), played once, a shot dropped while the suit's voice still plays. The game's
# laser is a beam heard for as long as its player holds the fire (the player's path loops it, stopped when he lets
# go); a squadmate's came out in pieces, with gaps of 0.3 s, and rang on 1.3 s after he let go. The bridge holds that
# voice's driver sample going while he fires (put back to its start before its end, as a loop: the game drops his
# shots meanwhile) and ends it when he lets go, as before.
LASER_MATE_SOUNDS = {2059}
LOOP_MARGIN = 4096                # bytes before its end (0.18 s of the 22 kHz sample) at which it is put back to its start
# The game's sounds for the guest's window (coop_sound.gd): the game's voices (VOICES: 16 here, their number at
# 0x35982D) as it starts and ends them, seen each update. A voice: byte 0 the driver's sample (-1: free), +1 its kind
# (0 not placed; 1 at a place of the world, x y z 16.16 at +0x1A; 2 and 5 at a unit, its entity at +0x1A), +0x15 its
# volume now (0-127), +0x17 1 = played once (0: until stopped), +0x18 the sound (RESSOUND.RES). A sound the game
# plays as its player's (kind 0) is a shot of the suit whose voice it is (suit +0x82): placed at that suit for the
# guest. The game's sound volume: 0x35982F. A voice started again (the driver's sample back near its start, or
# another sound) is a new sound. 'SND' + master volume + count, then 'S' starts (voice, sound, kind, once, volume,
# entity, x, y, z) and 'E' ends (voice); sent when something happened, reliable online.
VOICE_MAX, SFX_VOLUME = 0x35982D, 0x35982F
STEP0 = 1941                                          # the player's footsteps: 1941 + 5 x ground + 0..3 (0x248EBC)
SPEECH0, SPEECH_END = 3050, 3050 + 275 * 18          # the squad's radio (SPEECH\RESBRKnn.RES, coop_sound.gd): heard by both
# A map marker for each player. The host's is the game's own nav marker. The guest's is Uplink's: his window asks for
# it ('W' + world x, y, floats; x = 0: none), the bridge keeps it (the game is not told: it has one marker only) and
# says it back to both windows: to his in the marks of his map (M_MATE), to the host's as 'GNAV' + x, y (floats; x = 0:
# none) + the number of maps on the host's game screen, then for each its rectangle (4 words), the world x, y of its
# corner and the world length of a column and of a row (4 floats): a cockpit panel showing the map (mode 9; its view:
# the pointer at +0x20 of the panel) or the full screen map (a panel in mode 8, the view at 0x38FB20); then where the
# game draws its own marker on that map (screen x, y, words; -1: none) and whether as one pixel (zoom levels 0 to 3)
# or as its small cross (0x277424): the host's window draws it again there in his co-op colour. 'GNAV' goes on as
# long as a guest plays (10 a second): it also tells the host's window that this is co-op.
PANELS, PANEL_N, PANEL_MODE, PANEL_VIEW, FULL_MAP, MAP_ROWS = 0x38FC00, 32, 0x12, 0x20, 0x38FB20, 0x35A544


_HOST = [0]                                           # the host's entity last read outside the guest's pass


def host_entity(g, pid_addr):
    """the host's entity (the game's player word, 0x441350). While TN+ coop's cave runs the player control pass for
    the guest's suit, that word holds the GUEST's entity (the cave swaps it in and back each game picture): a read
    falling in that pass took the guest's suit for the host's (his window hid the host's suit as its own body, keyed
    the host's sounds, map and walk on the wrong suit). Read again until the word is not the guest's; else the last
    good one"""
    v = 0
    for _ in range(8):
        r = g.read(pid_addr + 2, 2)
        v = r[0] | r[1] << 8
        on = g.read(G_ON, 4)
        if on[0] != 1 or v != (on[2] | on[3] << 8):
            if v != _HOST[0]:                          # (each change, with the guest's: never the same)
                builtins.print('coop: host entity %d (guest %d)' % (v, on[2] | on[3] << 8 if on[0] == 1 else 0), flush=True)
            _HOST[0] = v
            return v
    return _HOST[0] or v


_LOG = None


def print(*a, **k):                                   # coop messages: the console and live/logs/coop_host_<date>.log
    global _LOG
    builtins.print(*a, **k)
    try:
        if _LOG is None:
            d = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'logs')
            os.makedirs(d, exist_ok=True)
            _LOG = open(os.path.join(d, time.strftime('coop_host_%Y-%m-%d_%H-%M-%S.log')), 'a', encoding='utf-8')
        _LOG.write(time.strftime('[%H:%M:%S] ') + ' '.join(map(str, a)) + '\n'); _LOG.flush()
    except OSError:
        pass


class XState(ctypes.Structure):
    _fields_ = [('packet', ctypes.c_uint), ('buttons', ctypes.c_ushort), ('lt', ctypes.c_ubyte), ('rt', ctypes.c_ubyte),
                ('lx', ctypes.c_short), ('ly', ctypes.c_short), ('rx', ctypes.c_short), ('ry', ctypes.c_short)]


try:
    _xinput = ctypes.windll.xinput1_4
except OSError:
    _xinput = None


def pad():
    if not _xinput:
        return None
    s = XState()
    return s if _xinput.XInputGetState(0, ctypes.byref(s)) == 0 else None


def axis(v, dead=7849):
    if abs(v) < dead:
        return 0.0
    return max(-1.0, min(1.0, (v - math.copysign(dead, v)) / (32767 - dead)))


def launch(godot, vpath, mission):
    import subprocess
    return subprocess.Popen([godot, '--path', vpath, '--resolution', os.environ.get('TN_GUEST_RES', '1280x720')] +
                            (['--position', os.environ['TN_GUEST_POS']] if 'TN_GUEST_POS' in os.environ else []) +
                            ['--', '--live', '--live-port', str(LIVE_PORT), '--play', '--play-port', str(PLAY_PORT), '--coop-hud'] +
                            (['--coop-preview'] if os.environ.get('TN_COOP_PREVIEW') else []) +   # Steam name / avatar
                            (['--mission', mission] if mission else []))


class Guest:
    def __init__(self, g, master, pid_addr, nent, eye, sens_x, fov_now, sock, remote=False, view_hz=20.0, versus=False,
                 eye_fixed=False, oeil=None):
        # eye: the eye's height above the entity when the game's can't be read (eye_fixed, the bridge's --eye: always);
        # oeil: the address of the camera height the game adds (the bridge's OEIL)
        self.eye_fixed, self.oeil, self.eyes = eye_fixed, oeil, {}   # eyes: each suit's last good eye (from its entity)
        # versus (1v1, experimental): the guest drives a suit of the other side instead of a teammate, its AI off, and
        # fights the host (his shots come from the enemy side, so they hurt); his "squad" is the enemy suits
        self.versus = versus or bool(os.environ.get('TN_COOP_VERSUS'))
        self.remote, self.sent_t, self.view_hz = remote, 0.0, max(1.0, view_hz)
        self.smoke_t, self.smoke_on = 0.0, False
        self.weather_pk, self.weather_t = b'', 0.0
        self.relayed = {}                                     # online: per tag, the last packet relayed and when
        self.fx_pk, self.fx_sent, self.fx_t = b'', b'', 0.0
        self.beam_pk, self.beam_sent, self.part_pk, self.part_sent, self.part_t = None, None, None, None, 0.0
        self.joined = not remote                               # online: once his window speaks (coop_net.gd's 'R' / 'N')
        self.enc, self.resync_t = coop_view.Encoder() if remote else None, 0.0
        self.g, self.master, self.pid_addr, self.nent, self.eye, self.sens_x = g, master, pid_addr, nent, eye, sens_x
        self.fov_now, self.s = fov_now, sock
        self.fov_rest = None          # the game's field without the host's helmet zoom (the bridge's): the guest's view
        self.rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.rx.bind(('127.0.0.1', PLAY_PORT)); self.rx.setblocking(False)
        self.keys, self.gid, self.pitch, self.fire = set(), 0, 0.0, False
        self.gnav, self.gnav_t, self.gnav_told, self.gnav_mis = None, 0.0, False, None   # his map marker (world x, y)
        self.fired_t, self.laser_said = 0.0, None             # when he last held the fire (his laser's sound: laser_off)
        self.snd_piece = None                                  # (the TN+ build's sound piece: None not looked yet)
        self.looped = None                                     # (voice, driver sample) of his laser held looping (laser_off)
        self.voices, self.voices_t = {}, 0.0                   # the game's voices seen playing: slot -> (sound, kind, ent, sample pos)
        self.step_ground, self.step_speed = 4, 0.0
        self.steps_heard, self.step_due, self.step_n, self.step_at = 0, 0, 0, None   # (own_steps)
        self.ghd_max = 0                                       # the biggest 'GHD' sent (logged)
        self.private_said = set()                              # the host's own cockpit sounds seen (sounds: logged once)
        self.rpad, self.rpad_t = None, 0.0                    # online: the guest's gamepad (lx, ly, rx, ry, fire, jets)
        self.shift, self.pad_jump, self.jump_clock = False, False, None   # jump_clock: no jump before (game clock)
        self.held, self.steps, self.feet, self.pad_t = {}, 0, None, [0.0, 0.0]   # held move keys (code -> [pressed,
        # last repeat]), his footsteps, his feet's last states, his gamepad's A (pressed, last repeat)
        self.feet_c, self.walk, self.stance, self.at = 0, 0, None, None   # feet not drawn: when they last moved, the
        # walking time to the next footstep, the end of its stance (game clock), his last place and clock
        self.pending, self.clk, self.jet_n, self.jet_air = [0, 0, 0], None, None, None
        self.lock, self.lock_req, self.pad_lock, self.lock_step = 0, False, False, 0
        self.lock_seen = []
        self.shots, self.hits, self.retire = {}, [], []      # versus: the guest's projectiles (last spot), hits to send
        self.squad, self.state, self.down_t, self.hud_t, self.amax, self.next = [], OK, 0.0, 0.0, 1, False
        self.tag, self.name = NameTag(g), os.environ.get('TN_GUEST_NAME', 'Player 2')   # his name on the host's HUD
        self.face = None                                      # and his Steam avatar (21 x 27 RGB) as the portrait
        self.post_key, self.drop_t = None, 0.0                   # the bridge's key poster (DOSBox window)
        self.hud_src, self.tpl_t, self.taken_t = None, 0.0, 0.0   # the bridge's last game screen, for his cockpit
        # the Mission Outfitting lobby (his column, pilot, loadout)
        self.data_dir = coop_lobby.find_data(g)
        self.lobby, self.lobby_t, self.lobby_msgs = coop_lobby.Lobby(g, self.data_dir), 0.0, []
        self.frames = {}                                       # 3D window -> its cockpit frame (mask, pixels), the host whole
        self.tint_t, self.map_said = 0.0, False                 # his weapon box's colour tables: when last sent
        self.plant_top = {}                                    # suit record -> the most energy max seen (status_marks)
        self.comm, self.ind, self.ind_at = [], None, None      # his COMM rows' entities; the armour indicator's picture
        # (False: none) and where the host's game draws it (his window draws his own there)
        self.equip = GuestEquipment(self)                     # his drone and A.S.F. (guest_equipment.py, TN_COOP_EQUIP=1)
        self.aimer = GuestAim(self)                           # what his crosshair is on (coop_aim.py)
        # The host's suit in his window walks with the game's own walk ported to Uplink (suit_gait.gd, as every suit
        # the game does not pose), from its real motion. host_anim.py's learned cycle (TN_HOST_ANIM=1, the old way)
        # sent a pose every view: with no cycle learned yet (a new install) it was a standing pose for good, the
        # host's suit slid along unanimated in the guest's window
        self.anim = None
        if os.environ.get('TN_HOST_ANIM') == '1':
            try:
                from host_anim import HostAnim
                self.anim = HostAnim()
            except Exception:
                pass
        # TN+ Coop writes its code into the game at the main menu, a few seconds after the bridge starts: said when it
        # is seen (step), "NOT in place" only once the game has been up a while without it
        self.ready = g.read(CAVE, 4) != bytes(4)
        self.ready_t, self.ready_said = time.time(), self.ready
        print('coop :', 'code in place' if self.ready else 'waiting for the co-op code (TN+ Coop puts it in at the main menu)', flush=True)

    def host_id(self):
        return host_entity(self.g, self.pid_addr)

    def u16(self, a):
        return struct.unpack('<H', self.g.read(a, 2))[0]

    def i32(self, a):
        return struct.unpack('<i', self.g.read(a, 4))[0]

    def pilots(self):
        """entities with a pilot record (0x391e50, 4 x 0x32: the player and his squad): the player's side"""
        out = set()
        for a in range(0x391e50, 0x391f18, 0x32):
            r = self.g.read(a, 4)
            if r[0] | r[1]:
                out.add(struct.unpack_from('<H', r, 2)[0])
        return out

    def side(self, e):
        """the unit's side as the game keeps it: 1 the player's, 2 the enemy, 0 unknown (no AI record)"""
        a = self.g.read(self.master + 0x25 * e + 0x21, 1)[0]
        if a == 0 or a >= AI_MAX:
            return 0
        return self.g.read(AI_SIDE + (self.master - 0x3C3240) + AI_N * a, 1)[0]

    def dist(self, me, e):
        """2D distance between two entities"""
        mx, my = struct.unpack('<ii', self.g.read(self.master + 0x25 * me + 0x0F, 8))
        x, y = struct.unpack('<ii', self.g.read(self.master + 0x25 * e + 0x0F, 8))
        return math.hypot(x - mx, y - my) / 65536

    def suits(self, me):
        """living suits but the player's, nearest first: [(distance, entity)]"""
        mx, my = struct.unpack('<ii', self.g.read(self.master + 0x25 * me + 0x0F, 8))
        tab = self.g.read(self.master, 0x25 * self.nent)
        out = []
        for i in range(1, self.nent):
            b = tab[0x25 * i:0x25 * i + 0x17]
            if b[0] and b[1] == 1 and i != me:
                x, y = struct.unpack_from('<ii', b, 0x0F)
                out.append((math.hypot(x - mx, y - my) / 65536, i))
        return sorted(out)

    def squad_now(self, me):
        """the player's squad as the game keeps it: the living suits of the pilot records but the host's own, none of
        the enemy side (a stale record), in the records' order (the game's COMM panel; F8 goes round them in it: an
        order by distance changed as they walked, and F8 went back and forth between two); his own suit included"""
        out = []
        for k in range(4):
            r = self.g.read(PILOTS + PILOT_N * k, 8)
            e = struct.unpack_from('<H', r, 2)[0]
            if (r[0] | r[1]) and e and e != me and e not in out and self.side(e) != 2 and self.alive(e):
                out.append(e)
        return out

    def enemies_now(self, me):
        """versus: the living suits of the enemy side (no AI record: those without a pilot record), in the game's
        table order (a steady order for F8, as squad_now)"""
        friends = self.pilots()
        out = []
        for d, i in self.suits(me):
            sd = self.side(i)
            if (sd == 2 or (sd == 0 and i not in friends)) and self.alive(i):
                out.append(i)
        return sorted(out)

    def squad_info(self, me):
        """the guest's COMM panel: the host first, then his other living teammates: entity, armour %, pilot (name and
        portrait index in the game's tables, 255 = none)"""
        out = []
        for e in [me] + [i for i in self.squad if i != self.gid]:
            if not self.alive(e):
                continue
            full = self.armour_max(e)                          # current / max in its record (+0x15 / +0x17)
            pilot = 255
            for a in range(0x391e50, 0x391f18, 0x32):
                r = self.g.read(a, 8)
                if r[0] | r[1] and struct.unpack_from('<H', r, 2)[0] == e:
                    pilot = r[6]
            out.append(struct.pack('<HBB', e, max(0, min(100, self.armour(e) * 100 // full)), pilot))
        out = out[:3]
        self.comm = [struct.unpack_from('<H', r)[0] for r in out]
        # then his 4 weapon slots' types (the STATUS page) and whether a jump is allowed now (the game's gates)
        slots = bytes(self.g.read(self.suit(self.gid) + SLOTS + SLOT_N * k, 1)[0] for k in range(4)) if self.gid else bytes(4)
        en = 0
        if self.gid:                                           # then his energy, % of the suit's max (+0x8A), as the game's panel bar
            en = self.energy_pct(self.gid)
        return bytes([len(out)]) + b''.join(out) + slots + bytes([1 if self.jump_ok() else 0, en])

    def versus_hits(self, me):
        g, M = self.g, self.master
        if g.read(G_HIT, 1)[0] == 0:                         # the cave took the last hit: retire, send the next
            for i in self.retire:
                if g.read(M + 0x25 * i, 2) != b'':      # gone already
                    continue
                rec = struct.unpack('<h', g.read(M + 0x25 * i + 3, 2))[0]
                g.write(PROJ + PROJ_N * rec + 0x16, struct.pack('<i', -1))
            self.retire = []
            if self.hits:
                i = self.hits.pop(0)
                g.write(G_HIT + 2, struct.pack('<HHH', me, 0, i))
                g.write(G_HIT, b'\x01')
                self.retire.append(i)
                print('versus: hit on the host', flush=True)
        hx, hy, hz = (self.i32(M + me * 0x25 + o) / 65536 for o in (0x0F, 0x13, 0x17))
        tab = g.read(M, 0x25 * self.nent)
        seen = {}
        for i in range(1, self.nent):
            b = tab[0x25 * i:0x25 * i + 0x1B]
            if not (b[0] and b[1] == 5):
                continue
            rec = g.read(PROJ + PROJ_N * struct.unpack_from('<h', b, 3)[0], PROJ_N)
            if struct.unpack_from('<h', rec, 6)[0] != self.gid:
                continue
            p = tuple(v / 65536 for v in struct.unpack_from('<3i', b, 0x0F))
            last = self.shots.get(i)
            if last == 'done' or i in self.hits or i in self.retire:
                seen[i] = 'done'
                continue
            seen[i] = p
            if self.crosses(last or p, p, (hx, hy, hz)):
                self.hits.append(i)
                seen[i] = 'done'
            elif struct.unpack_from('<i', rec, 0x16)[0] == 0 and i not in self.retire:
                self.retire.append(i)                         # spent (hit the ground): free its slot
                seen[i] = 'done'
        self.shots = seen

    @staticmethod
    def crosses(a, b, host):
        """the shot's last step a -> b passes through the host's body (an upright cylinder)"""
        hx, hy, hz = host
        dx, dy = b[0] - a[0], b[1] - a[1]
        n = dx * dx + dy * dy
        t = 0.0 if n < 1e-9 else max(0.0, min(1.0, ((hx - a[0]) * dx + (hy - a[1]) * dy) / n))
        x, y, z = (u + (v - u) * t for u, v in zip(a, b))
        return math.hypot(x - hx, y - hy) < HIT_R and hz + HIT_Z[0] < z < hz + HIT_Z[1]

    def target_pos(self, e):
        """middle of a living unit (classes 1-3), or None"""
        b = self.g.read(self.master + 0x25 * e, 0x1B)
        if not b[0] or not 1 <= b[1] <= 3:
            return None
        x, y, z = (v / 65536 for v in struct.unpack_from('<3i', b, 0x0F))
        return (x, y, z + 0.35)

    @staticmethod
    def off_aim(eye, view, t):
        """(side, up / down) angles between the view and the direction to t"""
        d = [a - b for a, b in zip(t, eye)]
        side = abs((math.atan2(d[1], d[0]) - math.atan2(view[1], view[0]) + math.pi) % (2 * math.pi) - math.pi)
        up = abs(math.atan2(d[2], math.hypot(d[0], d[1])) - math.asin(max(-1.0, min(1.0, view[2]))))
        return side, up

    def lock_info(self):
        """the end of 'GHD' while he has a target, what the game writes beside its player's (0x26A7C8): 'LCK', the
        target's armour (% left, as its bar under the box; 100 for what has no armour record), 1 when it is beyond
        his weapon's range (the game's "Out of Range" instead of "LOCKED": its range, word +0x1E of the weapon's
        record 0x395100, against the distance), the distance in the game's metres (6 a unit)"""
        g, e = self.g, self.lock
        b = g.read(self.master + 0x25 * e, 0x1B)
        t = [v / 65536 for v in struct.unpack_from('<3i', b, 0x0F)]
        me = [v / 65536 for v in struct.unpack('<3i', g.read(self.master + 0x25 * self.gid + 0x0F, 12))]
        d = math.dist(t, me)
        arm = 100
        if b[1] == 1 and struct.unpack_from('<H', b, 3)[0] <= 200:
            arm = max(0, min(100, self.armour(e) * 100 // self.armour_max(e)))
        p = self.suit(self.gid)
        wt = g.read(p + SLOTS + SLOT_N * (g.read(p + SEL, 1)[0] & 3), 1)[0]
        far = 1 if d >= self.u16(W_RANGE + W_N * wt) else 0
        return b'LCK' + struct.pack('<BBH', arm, far, min(65535, int(d * 6)))

    def iff_colour(self, e, pilots, d):
        """the game's colour of a unit (0x2769E8) for his screen: his target green (0x84)"""
        if e == self.lock:
            return 0x84
        b = self.g.read(self.master + 0x25 * e + 1, 2)
        if b[0] == 1:
            if e in pilots:
                return self.g.read(SQUAD_COL + d + pilots[e], 1)[0]
            return 0x6E if b[1] == 0xD else 0x44
        if b[0] == 2:
            return 0x44 if b[1] > 3 else 0x22
        if b[0] == 3:
            if e == self.u16(OBJ_SPECIAL + d):
                return 0x4B
            return 0x63 if b[1] < 7 else 0x50 if b[1] == 7 else 0x6E
        return 0

    def iff_block(self):
        """the end of 'GHD': the units his window marks with the game's coloured brackets (see SQUAD_COL), entity
        (u16) and palette colour (u8) each, then 'IFF' and their count"""
        g, d = self.g, self.master - 0x3C3240
        out = {}
        all_c = g.read(IFF_ALL + d, 1)[0]
        pilots = {}
        for k in range(4):
            r = g.read(PILOTS + d + PILOT_N * k, 8)
            e = struct.unpack_from('<H', r, 2)[0]
            if (r[0] | r[1]) and e:
                pilots[e] = r[7]
        for e in pilots:
            if e != self.gid and 0 < e < self.nent and g.read(self.master + 0x25 * e + 1, 1)[0] == 1:
                out[e] = 0x36 if all_c else self.iff_colour(e, pilots, d)
        n, lst = struct.unpack('<2I', g.read(self.suit(self.gid) + CONTACTS + 8, 8))
        if 0x100000 < lst < 0x2000000 and 0 < n <= 300:
            c = g.read(lst, 6 * n)
            for k in range(n):
                e = struct.unpack_from('<H', c, 6 * k)[0]
                if not e:
                    break
                if e != self.gid and e not in out and 0 < e < self.nent and \
                        g.read(self.master + 0x25 * e + 1, 1)[0] in (1, 2, 3):
                    out[e] = 0x36 if all_c else self.iff_colour(e, pilots, d)
        recs = [(e, c) for e, c in out.items() if c][:IFF_MAX]
        return b''.join(struct.pack('<HB', e, c) for e, c in recs) + b'IFF' + bytes([len(recs)])

    def sensor(self):
        """his suit's sensor range (units), as the game keeps a lock (0x262B00)"""
        return self.i32(self.suit(self.gid) + SENSOR) / 65536 / 6

    def lockable(self, i, me):
        """a unit he may lock: not himself, not the host (co-op), not one of his squad, not a suit of his own side
        without a pilot record; and where the game has it (types 1-3)"""
        if not 0 < i < self.nent or i == self.gid or (i == me and not self.versus) or i in self.squad:
            return False
        if not self.versus and self.g.read(self.master + 0x25 * i + 1, 1)[0] == 1 and self.side(i) == 1:
            return False
        return self.target_pos(i) is not None

    def in_view(self, me, eye, view):
        """the units he could lock now (the game's list of those on its screen): [(distance, entity)], nearest first"""
        out = []
        for i in range(1, self.nent):
            if not self.lockable(i, me):
                continue
            t = self.target_pos(i)
            if math.dist(t[:2], eye[:2]) > LOCK_RANGE:
                continue
            side, up = self.off_aim(eye, view, t)
            if side < LOCK_PICK and up < LOCK_PICK_V:
                out.append((math.dist(t, eye), i))
        return sorted(out)

    def pick_target(self, me, eye, view, seen=()):
        """his right button, as the game's click on its 3D view picks its player's target (0x269F28): of the units it
        drew (its list 0x397CA0 of their boxes on the screen), those whose box grown by 20 pixels holds the click (here
        his crosshair), the one whose box's middle is nearest it. His window does that on what it draws and sends the
        units it found, nearest first (seen): the first he may lock. An older window sends none: the same rule here,
        each unit's box about PICK_SIZE units around its middle on his screen (the game's 3D window, 298 pixels for
        84.5 degrees across, rows half a pixel high); and none of those, the unit nearest his crosshair within
        PICK_NEAR. None at all: no target, and why"""
        for i in seen:
            if self.lockable(i, me):
                print('guest: lock', i, '(under his crosshair)', flush=True)
                return i
        best, pick, near, near_a, cands = None, 0, 0, None, 0
        f = PICK_HALF / math.tan(math.radians(84.5) / 2)       # (pixels a unit of tangent)
        for i in range(1, self.nent):
            if not self.lockable(i, me):
                continue
            t = self.target_pos(i)
            if math.dist(t[:2], eye[:2]) > LOCK_RANGE:
                continue
            side, up = self.off_aim(eye, view, t)
            if side > LOCK_PICK or up > LOCK_PICK_V:
                continue
            cands += 1
            a = math.hypot(side, up)
            if near_a is None or a < near_a:
                near, near_a = i, a
            d = max(0.5, math.dist(t, eye))
            sx, sy = f * math.tan(side), 2 * f * math.tan(up)  # (rows: two a pixel)
            r = f * PICK_SIZE / d
            if sx > r + PICK_GROW or sy > 2 * r + PICK_GROW:
                continue
            score = sx * sx + sy * sy
            if best is None or score < best:
                best, pick = score, i
        if not pick and near_a is not None and near_a <= PICK_NEAR:
            pick = near
        if pick:
            print('guest: lock', pick, flush=True)
        else:
            print('guest: lock nothing (%d lockable in his view%s; his window saw %s)' % (
                cands, ', nearest %.1f deg off' % math.degrees(near_a) if near_a is not None else '',
                list(seen) or 'none'), flush=True)
        return pick

    def clock(self):
        return struct.unpack('<I', self.g.read(CLOCK, 4))[0]

    def ground(self, x, y):
        """the terrain's height under x, y (units) as the game's 0x2949C4 takes it from its height map: on the plane
        of the cell's triangle he is over (cells are cut along one diagonal or the other, by turns); None when the
        map is not there"""
        base = struct.unpack('<I', self.g.read(HMAP, 4))[0]
        if not 0x100000 <= base < 0x2000000:
            return None
        ix, iy = min(HMAP_N - 2, max(0, int(x))), min(HMAP_N - 2, max(0, int(y)))
        fx, fy = min(1.0, max(0.0, x - ix)), min(1.0, max(0.0, y - iy))
        a, b = (self.g.read(base + 3 * (HMAP_N * j + ix), 6) for j in (iy, iy + 1))
        h = lambda r, o: (struct.unpack_from('<h', r, o + 1)[0] >> 4) / 24
        h00, h10, h01, h11 = h(a, 0), h(a, 3), h(b, 0), h(b, 3)
        if (ix + iy) & 1 == 0:                                 # cut from (0, 0) to (1, 1)
            if fx > fy:
                h01 = h00 + h11 - h10
            else:
                h10 = h00 + h11 - h01
        elif fx + fy >= 1.0:                                   # cut from (1, 0) to (0, 1), the far half
            h00 = h10 + h01 - h11
        return h00 + fx * (h10 - h00) + fy * (h01 - h00)

    def near_ground(self, e):
        """entity e within 0.25 of the terrain (the game's 0x28927C); True when the height map is not there"""
        x, y, z = (v / 65536 for v in struct.unpack('<3i', self.g.read(self.master + 0x25 * e + 0x0F, 12)))
        h = self.ground(x, y)
        return h is None or abs(z - h) <= AIR / 65536

    def ceiling(self):
        """his suit kept within 30 units of the ground, as the game keeps the player's (CEILING): higher, his body
        goes back to that height with no vertical speed. True when it was put back"""
        e = self.master + 0x25 * self.gid
        x, y, z = struct.unpack('<3i', self.g.read(e + 0x0F, 12))
        h = self.ground(x / 65536, y / 65536)
        if h is None or z <= int(h * 65536) + CEILING:
            return False
        slot = self.i32(BODY_SLOT + 4 * self.g.read(e + BODY, 1)[0])
        if not 0 <= slot < 0x60:
            return False
        a = BODY_STATE + BODY_N * slot + BODY_Z
        if abs(self.i32(a) - 6 * z) > 6 * 0x80000:             # not his body (the entity follows it at each step)
            return False
        self.g.write(a, struct.pack('<3i', 6 * (int(h * 65536) + CEILING), 0, 0))
        return True

    def grounded(self, e):
        """his suit stands on something: the game's contact bytes (0x27EDA0) say so, and he is near the ground"""
        r = self.g.read(self.suit(e), 0x398)
        return not any(r[o] in v for o, v in CONTACT) and self.near_ground(e)

    def jump_ok(self):
        """the game's Bound gates for his suit: on the ground (no foot swinging, within its 0.25 band: kicks
        pressed fast no longer carry him up), 250 game ms since the last one, 4 footsteps since, suit +0x3C8 low"""
        if not self.gid:
            return False
        s, c = self.suit(self.gid), self.clock()
        if self.jump_clock is not None and c < self.jump_clock - JUMP_WAIT:
            self.jump_clock = None                             # the clock went back: a new mission or a load
        if self.jump_clock is not None and not c > self.jump_clock:
            return False
        if self.stance is None:
            down = self.grounded(self.gid)
        else:                                                  # (feet not drawn: the stance after each footstep)
            down = c <= self.stance and self.near_ground(self.gid)
        return self.steps >= STEPS and down and self.i32(s + BOUND_GATE) < 0x30000

    def bound_tick(self):
        """each tick: his footsteps (a foot planted since the last tick, near the ground; none counted and the count
        back to 0 while the jets hold him up), then the repeats of his held move keys, each a Bound try with Shift"""
        r = self.g.read(self.suit(self.gid) + FEET[0], FEET[1] - FEET[0] + 1)
        feet, c = (r[0], r[-1]), self.clock()
        here = struct.unpack('<2i', self.g.read(self.master + 0x25 * self.gid + 0x0F, 8))
        if feet != self.feet or self.at is None or not 0 <= (c - self.feet_c) & 0xFFFFFFFF < 0x80000000:
            self.feet_c = c
        drawn = (c - self.feet_c) & 0xFFFFFFFF < STILL
        if self.jet_air is not None:
            self.steps, self.walk = 0, 0
        elif drawn:
            if self.feet is not None and self.near_ground(self.gid):
                self.steps += sum(1 for a, b in zip(self.feet, feet) if b == 2 and a != 2)
        elif self.at is not None:                              # his feet stand still: footsteps from his walking
            dt = (c - self.at[1]) & 0xFFFFFFFF
            if 0 < dt <= 100 and math.dist(here, self.at[0]) / 65536 > 0.3 * dt / 1000:
                self.walk += dt
                if self.walk >= STRIDE:
                    self.walk -= STRIDE
                    if self.near_ground(self.gid):
                        self.steps += 1
                        self.stance = c + STANCE
        self.stance = None if drawn else (self.stance or 0)
        if self.steps > self.steps_heard:                      # his own footsteps, for his window (own_steps)
            self.step_due += 1
        self.steps_heard = self.steps
        self.feet, self.at = feet, (here, c)
        now = time.time()
        for sc, t in self.held.items():
            if now - t[0] > REPEAT[0] and now - t[1] > REPEAT[1]:
                t[1] = now
                if self.shift:
                    self.jump(JUMP_DIR[sc])
        if self.pad_jump and self.rpad and now - self.pad_t[0] > REPEAT[0] and now - self.pad_t[1] > REPEAT[1]:
            self.pad_t[1] = now                                # (his gamepad's A held: the same)
            self.jump(self.pad_angle())

    def jump(self, angle):
        """the game's Bound toward the heading + angle: one kick of 120 flat, 80 up; it costs no energy"""
        if not self.jump_ok():
            return
        self.jump_clock = (self.clock() + JUMP_WAIT) & 0xFFFFFFFF
        self.steps = 0                                         # (the game: its legs leave the ground)
        h = self.u16(self.master + 0x25 * self.gid + 0x1B) / 65536 * 2 * math.pi + angle
        self.kick(int(math.cos(h) * JUMP_V[0] * 65536), int(math.sin(h) * JUMP_V[0] * 65536), JUMP_V[1] << 16)

    def kick(self, vx, vy, vz):
        """add a speed (16.16) to his body: through the mailbox once the cave has taken the last one, else added up
        and sent on a later tick (never written over)"""
        self.pending = [a + b for a, b in zip(self.pending, (vx, vy, vz))]
        self.flush()

    def flush(self):
        if any(self.pending) and self.g.read(G_JUMP, 1)[0] == 0:
            self.g.write(G_JV, struct.pack('<3i', *(max(-0x7FFFFFFF, min(0x7FFFFFFF, v)) for v in self.pending)))
            self.g.write(G_JUMP, b'\x01')
            self.pending = [0, 0, 0]

    def push(self, jets):
        """each tick: the game's ceiling, the jets while Space is held (counted in game updates: the clock moved),
        and what waits in the mailbox"""
        c = self.clock()
        dt = 0 if self.clk is None else (c - self.clk) & 0xFFFFFFFF
        if dt > 100:
            dt = 0 if dt > 0x7FFFFFFF else 100                  # the clock went back (no update), or a long hitch
        self.clk = c
        if self.gid:
            self.ceiling()
            if jets and self.i32(MISSION) != NO_JETS:
                self.jets(self.suit(self.gid), c, dt)
            else:
                self.jet_n = self.jet_air = None
        self.flush()

    def jets(self, s, c, dt):
        if self.jet_n is None:
            self.jet_n = 0                                     # pressed: this tick is the first update
        elif dt:
            self.jet_n += 1
        else:
            return                                             # no game update since the last tick
        if self.near_ground(self.gid):                         # within 0.25 of the ground: the kick, unpaid
            if self.jet_air is not None:
                self.jet_n = 0                                 # back from the air: the game kicks at once (0x288EF0)
            self.jet_air = None
            if self.jet_n % 2 == 0:
                self.kick(0, 0, JET_KICK << 16)
            return
        if self.jet_air is None:
            self.jet_air = c                                   # took off
        r = self.g.read(s + J_RATING, 6)
        fuel = struct.unpack_from('<H', r, J_FUEL - J_RATING)[0]
        if fuel == 0:
            return
        if (c - self.jet_air) & 0xFFFFFFFF > JET_FREE:
            cost = (dt << 32) // ((self.i32(ENERGY_F) + 0x20000) // 3)
            pool = self.i32(s + EN_CUR)
            if pool < cost:
                return                                         # too little energy: nothing this update
            burn = ((((struct.unpack_from('<H', r, 0)[0] // 15) << 9) * dt) >> 16) & 0xFF
            if self.i32(s + J_HALF) == 4:
                burn >>= 1
            if self.i32(MISSION) == NO_FUEL:
                burn = 0
            self.g.write(s + EN_CUR, struct.pack('<i', pool - cost))
            if burn:
                self.g.write(s + J_FUEL, struct.pack('<H', max(0, fuel - burn)))
        self.kick(0, 0, int(JET_ACC * dt / 1000 * 65536))

    def select_weapon(self, k):
        """weapon key k (slot 0-3) for his suit as the game does it for the player's (0x2760d1, 0x28ab1c): an odd
        slot gives the one before when byte +7 is 0 or that one holds a two-slot weapon; the same slot or an empty
        one: nothing; else the new slot's ready time goes up to now + the weapon's switch delay (never down), then
        the slot is selected (in that order: the cave may fire between the two writes). The game's sound and panel
        redraw are the host's cockpit: left out"""
        g, R = self.g, self.suit(self.gid)
        r = g.read(R, SEL + 1)
        typ = lambda j: r[SLOTS + SLOT_N * j]
        s = k
        if k & 1 and (r[SUIT_B7] == 0 or g.read(W_TWO + W_N * typ(k - 1), 1)[0]):
            s = k - 1
        t = typ(s)
        if s == r[SEL] or t == 0:
            return
        ready = (self.clock() + self.u16(W_DELAY + W_N * t)) & 0xFFFFFFFF
        a = R + SLOTS + SLOT_N * s + SLOT_READY
        if ready > struct.unpack('<I', g.read(a, 4))[0]:
            g.write(a, struct.pack('<I', ready))
        g.write(R + SEL, bytes([s]))

    def call_dropship(self):
        """the guest's "Call dropship": Enter in the host's game, as if the host pressed it; once in 5 s, said in the chat"""
        if not self.post_key or time.time() - self.drop_t < 5.0:
            return
        self.drop_t = time.time()
        self.post_key(DROPSHIP, True)
        self.post_key(DROPSHIP, False)
        self.lobby.say('guest', '* called the dropship *')
        print('guest: dropship called', flush=True)

    def suit(self, e):
        return PBA + PBA_N * self.u16(self.master + 0x25 * e + 3)

    def armour(self, e):
        """the suit's armour: its 4 parts' current values (hits take them down; a shot takes the energy, not this)"""
        r = self.g.read(self.suit(e), 0x30)
        return sum(max(0, struct.unpack_from('<h', r, c)[0]) for c, _ in PARTS)

    def armour_max(self, e):
        r = self.g.read(self.suit(e), 0x30)
        return max(1, sum(max(0, struct.unpack_from('<h', r, m)[0]) for _, m in PARTS))

    def health(self, e):
        """the pilot's health in suit e as the game's red bar reads it (0x2652a0): (current, max)"""
        s = self.suit(e)
        p = struct.unpack('<I', self.g.read(s + HEALTH_PTR, 4))[0]
        if 0x380000 <= p < 0x470000:
            mx, cur = struct.unpack('<HH', self.g.read(p + 1, 4))
        else:
            mx, cur = struct.unpack('<HH', self.g.read(s + HEALTH_MAX, 4))
        return (min(cur, mx), mx) if mx else (0, 0)

    def levels(self, e):
        """the armour indicator's five levels (0-6) for suit e, as the game works them out: front, left, right,
        back, pilot"""
        lvl = lambda cur, mx: 0 if mx <= 0 else max(0, min(6, (12 - (mx - max(0, min(cur, mx))) * 11 // mx) // 2))
        r = self.g.read(self.suit(e), 0x36)
        part = lambda k: struct.unpack_from('<hh', r, 0x15 + 7 * k)
        return bytes([lvl(*part(k)) for k in IND_PARTS] + [lvl(*reversed(struct.unpack_from('<HH', r, HEALTH_MAX)))])

    def hud_more(self):
        """the end of the 'GHD' packet: his pilot's health (current, max), his armour indicator's levels and where
        the game draws it (-1: not seen), then the pilot's health (%, 255: none) of each COMM row"""
        cur, mx = self.health(self.gid) if self.gid else (0, 0)
        lv = self.levels(self.gid) if self.gid else bytes(5)
        hp = []
        for e in self.comm[:3]:
            c, m = self.health(e)
            hp.append(c * 100 // m if m else 255)
        return struct.pack('<HH', cur, mx) + lv + struct.pack('<hh', *(self.ind_at or (-1, -1))) + bytes(hp + [255] * (3 - len(hp)))

    def weapon_state(self):
        """his selected weapon as the game's small box shows the player's (0x28f024): 0 it can fire, 1 destroyed, 2 no
        ammunition, 3 not enough energy for a shot (the box shows nothing of it), 5 not ready yet; and its ammunition, the
        number the box writes in its corner (0xFFFF: a weapon that counts none)"""
        p = self.suit(self.gid)
        slot = p + SLOTS + SLOT_N * (self.g.read(p + SEL, 1)[0] & 3)
        r = self.g.read(slot, SLOT_READY + 4)
        ammo = struct.unpack_from('<H', r, 4)[0] if self.u16(W_AMMO + W_N * r[0]) > 1 else 0xFFFF
        if struct.unpack_from('<h', r, 2)[0] <= 0:
            return 1, ammo
        if ammo == 0:
            return 2, ammo
        # 3: a weapon that counts no ammunition and needs more energy for a shot than the suit holds (word 0x395118 of
        # its type, 16.16 against the suit's +0x86: 0x28f05f); the panel writes "CHARGING", the box shows nothing
        if ammo == 0xFFFF and (self.u16(W_AMMO - 2 + W_N * r[0]) << 16) > self.i32(p + EN_CUR):
            return 3, ammo
        return (5 if self.clock() < struct.unpack_from('<I', r, SLOT_READY)[0] else 0), ammo

    def map_colour(self, e, b, pilots):
        """the colour of unit e's mark (0x2769e8; b: its entity record; pilots: the squad's colour numbers)"""
        if e == self.lock:
            return 0x84
        t, sub = b[1], b[2]
        if t == 1:
            if e in pilots:
                return self.g.read(SQUAD_COLOURS + pilots[e], 1)[0]
            return 0x6E if sub == 0x0D else 0x44
        if t == 2:
            return 0x22 if sub <= 3 else 0x44
        if t == 3:
            return 0x4B if e == self.u16(DRONE) else 0x63 if sub < 7 else 0x50 if sub == 7 else 0x6E
        if t == 4:
            return 0x44 if 0x45 <= sub <= 0x47 else 0x7B
        return 0x90

    def map_block(self, me):
        """the end of the 'GHD' packet: 'M', flags (bit 0: the two colour tables of the weapon box follow the
        header), his weapon's state and ammunition (a word), the number of marks; then each mark of his map in the game's drawing order:
        kind, colour (the game's palette), payload length, payload (world x, y in 1/64 units, words; a shape: its
        corners; a note: x, y, width, height and, for a text, its letters)"""
        g = self.g
        pt = lambda x, y: struct.pack('<2H', *(max(0, min(0xFFFF, v >> 10)) for v in (x, y)))
        marks = []
        a, n = struct.unpack('<I', g.read(NOTES, 4))[0], 0
        while a != NOTES_END and 0x300000 < a < 0x2000000 and n < 24:   # the mission's notes on the map
            r = g.read(a, 0x23 + 24)
            n += 1
            if r[0x0E] & 1 and r[0x0A] in (0, 2, 3):
                box = pt(*struct.unpack_from('<2i', r, 0x0F)) + pt(*struct.unpack_from('<2i', r, 0x17))
                kind = M_TEXT if r[0x0A] == 0 else M_RECT if r[0x0A] == 2 else M_ROUND
                body = box + (r[0x23:].split(b'\0')[0][:24] if kind == M_TEXT else b'')
                if r[0x0D] & NOTE_ZOOM:                        # (as an older window draws them: the panel's zoom 4)
                    marks.append((kind, r[0x0B], body))
                # every zoom's, for his window's map zoom (coop_hud.gd): the note's zoom bits, its kind, then as above
                marks.append((M_NOTEZ, r[0x0B], bytes([r[0x0D], kind]) + body))
            a = struct.unpack_from('<I', r, 0)[0]
        ents = g.read(self.master, 0x25 * 300)
        rec = lambda e: ents[0x25 * e:0x25 * e + 0x25]
        pilots = {}
        for k in range(4):
            r = g.read(PILOTS + PILOT_N * k, 8)
            if r[0] | r[1]:
                pilots[struct.unpack_from('<H', r, 2)[0]] = r[7]
        seen = set()
        for w in [self.gid] if self.versus else [me] + list(self.squad) + [self.u16(DRONE)]:   # what the squad sees
            b = rec(w) if 0 < w < 300 else b''
            if not b or not b[0] or b[1] not in CONTACTS_AT:
                continue
            base, size, at = CONTACTS_AT[b[1]]
            _, _, n, lst = struct.unpack('<4I', g.read(base + size * struct.unpack_from('<H', b, 3)[0] + at, 16))
            if not (0x300000 < lst < 0x2000000 and 0 < n <= 300):
                continue
            c = g.read(lst, 6 * n)
            for i in range(n):
                e = struct.unpack_from('<H', c, 6 * i)[0]
                if not e:
                    break
                if e < 300:
                    seen.add(e)
        if self.lock:
            seen.add(self.lock)
        for e in sorted(seen - {self.gid}) + [self.gid]:      # (himself last, as the game its player)
            b = rec(e)
            if not b[0]:
                continue
            x, y = struct.unpack_from('<2i', b, 0x0F)
            if b[1] == 4 and not (b[2] in (0x2E, 0x2F) or 0x45 <= b[2] <= 0x47):   # a building: its outline
                t = struct.unpack('<I', g.read(FOOTPRINTS + 16, 4))[0]
                if not 0x300000 < t < 0x2000000:
                    continue
                p = t + struct.unpack('<I', g.read(t + 4 * b[2] + 2, 4))[0]
                n = min(struct.unpack('<I', g.read(p, 4))[0] >> 16, 16)
                c = struct.unpack('<%di' % (2 * n), g.read(p + 4, 8 * n))
                h = struct.unpack_from('<H', b, 0x1B)[0] / 65536 * 2 * math.pi
                co, si = math.cos(h), math.sin(h)
                marks.append((M_SHAPE, 0x12, b''.join(pt(x + int(c[2 * i] * co - c[2 * i + 1] * si),
                                                          y + int(c[2 * i] * si + c[2 * i + 1] * co)) for i in range(n))))
            else:
                marks.append((M_SELF if e == self.gid else M_CROSS, self.map_colour(e, b, pilots), pt(x, y)))
        w = g.read(WAYPOINTS, 4 * 0x84)
        for k in range(40):                                   # the squad's waypoints (a place, or a unit to follow)
            r = w[0x84 * (k // 10) + 12 * (k % 10):][:12]
            if r[0] < 4:
                e = struct.unpack_from('<H', r, 1)[0]
                x, y = struct.unpack_from('<2i', rec(e), 0x0F) if 0 < e < 300 else struct.unpack_from('<2i', r, 3)
                marks.append((M_WAYPOINT, WAYPOINT_COLOURS[r[0]], pt(x, y)))
        nx, ny = struct.unpack('<2i', g.read(NAV, 8))
        if nx and ny:
            marks.append((M_NAV, 0x9C, pt(nx, ny)))
        if self.gnav:                                          # his own marker (an older window draws nothing of it)
            marks.append((M_MATE, 0, pt(*(int(v * 65536) for v in self.gnav))))
        try:                                                   # his STATUS pages and his squad's STAT (coop_panels.gd)
            marks += self.status_marks()
        except (OSError, struct.error, IndexError):
            pass
        marks = marks[:255]
        tables = b''
        if time.time() - self.tint_t > 5.0:                    # the weapon box's two colour tables, now and then
            self.tint_t = time.time()
            for a in (TINT_BAD, TINT_WAIT):
                p = struct.unpack('<I', g.read(a, 4))[0]
                tables += g.read(p, 256) if 0x300000 < p < 0x2000000 else bytes(range(256))
        state, ammo = self.weapon_state()
        return b'M' + struct.pack('<BBHB', 1 if tables else 0, state, ammo, len(marks)) + tables + \
            b''.join(bytes([k, c, len(d)]) + d for k, c, d in marks)

    def host_maps(self):
        """the maps on the host's game screen now: [(x0, y0, x1, y1, world x, y of the corner, world length of a
        column, of a row)]"""
        g = self.g
        modes = [g.read(PANELS + PANEL_N * k + PANEL_MODE, 1)[0] for k in range(3)]
        if 8 in modes:
            views = [self.i32(FULL_MAP)]
        else:
            views = [self.i32(PANELS + PANEL_N * k + PANEL_VIEW) for k in range(3) if modes[k] == 9]
        out = []
        for v in views:
            if not 0x300000 <= v < 0x500000:
                continue
            x, y, zoom, step, per, canvas = struct.unpack('<iiHiiI', g.read(v, 0x16))
            if not (0x300000 <= canvas < 0x500000 and step > 0):
                continue
            x0, y0, x1, y1 = struct.unpack('<4h', g.read(canvas - 0x22 + 8, 8))
            if 0 <= x0 < x1 <= 320 and 0 <= y0 < y1 <= 400:
                rows = g.read(MAP_ROWS, 1)[0] & 3
                nx, ny = struct.unpack('<2i', g.read(NAV, 8))
                at = (x0 + (((nx - x) * per) >> 32), y0 + ((((ny - y) << rows) * per) >> 32)) if nx and ny else (-1, -1)
                if not (x0 <= at[0] < x1 and y0 <= at[1] < y1):
                    at = (-1, -1)
                out.append(struct.pack('<4h4f2hB', x0, y0, x1, y1, x / 65536, y / 65536, step / 65536,
                                       step / 65536 / (1 << rows), at[0], at[1], 1 if zoom < 4 else 0))
        return out

    def host_marker(self, in_mission):
        """the guest's map marker and the game's maps for the host's window, 10 times a second while a guest plays
        (and once more after); his marker is gone with the mission"""
        mis = self.i32(MISSION) if in_mission else None
        if mis != self.gnav_mis:
            self.gnav, self.gnav_mis = None, mis
        on = in_mission and self.joined
        if time.time() - self.gnav_t < 0.1 or not (on or self.gnav_told):
            return
        self.gnav_t, self.gnav_told = time.time(), on
        try:
            maps = self.host_maps() if on else []
        except (OSError, struct.error):
            maps = []
        self.s.sendto(b'GNAV' + struct.pack('<2fB', *(self.gnav or (0.0, 0.0)), len(maps)) + b''.join(maps),
                      ('127.0.0.1', HOST_LIVE))

    def status_marks(self):
        """M_SYS: his suit's systems as the game's STATUS pages list them (each %: record [suit +0x9C], 5 bytes a
        system, max word at +1, current at +3, 100 when the max is 0: 0x27e01b; systems 1-7 sensors, targdisc,
        jumpjets, infrared, target, video, drone: 0x27df14, the infrared off at 4, the 360 view off at 6), its power
        plant (the energy's max now over the most seen for this suit) and its armour parts front, left, back, right
        (%); M_ROW: each COMM row's entity, energy % and its pilot's health % (the left MFD's STAT page)"""
        out = []
        if self.gid:
            s = self.suit(self.gid)
            p = struct.unpack('<I', self.g.read(s + HEALTH_PTR, 4))[0]
            sy = self.g.read(p, 40) if 0x380000 <= p < 0x470000 else bytes(40)
            # his suit is a squadmate's to the game, which counts systems 0-3 only for one (0x27df4e: the player's 0-7;
            # what its record holds after them read as damage in a live test, infrared 0 %, drone 7 %): the others
            # are given as whole
            n = 4
            pc = []
            for k in range(1, 8):
                mx, cur = struct.unpack_from('<HH', sy, 5 * k + 1) if k < n else (0, 0)
                pc.append(100 if mx == 0 else max(0, min(100, cur * 100 // mx)))
            emax = struct.unpack('<i', self.g.read(s + EN_MAX, 4))[0]
            top = self.plant_top.get(s, 0)
            if emax > top:
                self.plant_top[s] = top = emax
            pc.append(100 if top <= 0 else max(0, min(100, emax * 100 // top)))
            r = self.g.read(s, 0x30)
            for c, m in PARTS:
                cur, mx = struct.unpack_from('<h', r, c)[0], struct.unpack_from('<h', r, m)[0]
                pc.append(0 if mx <= 0 else max(0, min(100, cur * 100 // mx)))
            out.append((M_SYS, 0, bytes(pc)))
        for e in self.comm[:3]:
            c, m = self.health(e)
            act, tgt = self.activity(e)
            out.append((M_ROW, 0, struct.pack('<HBBBBHB', e, self.energy_pct(e), c * 100 // m if m else 255,
                                              self.specialty(e), act, tgt, self.label(tgt)) + self.row_look(e)))
        if self.gid:                                           # M_WPN: his weapon panel's percentage (0x272086: the
            p = self.suit(self.gid)                            # slot's health over the type's, word 0x39511C)
            slot = p + SLOTS + SLOT_N * (self.g.read(p + SEL, 1)[0] & 3)
            r = self.g.read(slot, 4)
            top = self.u16(W_HEALTH + W_N * r[0])
            out.append((M_WPN, 0, bytes([max(0, min(255, struct.unpack_from('<h', r, 2)[0] * 100 // top)) if top else 100])))
        return out

    def specialty(self, e):
        """the STAT page's first line (0x26ce09): RESGAME 366 string 104 + the pilot's specialty (pilot slot byte +6 =
        p; 0x20: none, 104; else byte 0x39034D + 0x1EE x byte (0x391F4D + p)); 0: not a pilot of the squad"""
        for a in range(PILOTS, PILOTS + 4 * PILOT_N, PILOT_N):
            r = self.g.read(a, 8)
            if (r[0] | r[1]) and struct.unpack_from('<H', r, 2)[0] == e:
                if r[6] == 0x20:
                    return 104
                return 104 + self.g.read(SPECIALTY + 0x1EE * self.g.read(PILOT_REC + r[6], 1)[0], 1)[0]
        return 0

    def row_look(self, e):
        """the rest of a COMM row as the game draws a squadmate's (0x26cd00): his name's colour (pilot record +0x31,
        the squad colour SQUAD_COL + byte +7), the record's state word +0 (1: in the squad, its specialty and bars;
        2: "EVAC MODE" in yellow; else "Dead Duck"; one byte, 255: more), then his 4 armour parts as the first of the
        row's two small bars counts them (0x27022c, suit +0x15 + 7k current, +0x17 max): 3 above 73 % of the max
        (green), 1 under 37 % and not 0 (red), 0 at 0 (0x25), else 2 (yellow); then his armour indicator's five levels
        (the STAT page's picture of his suit, 0x2635c8). No pilot record: colour 0x1D, state 1"""
        col, st = 0x1D, 1
        for a in range(PILOTS, PILOTS + 4 * PILOT_N, PILOT_N):
            r = self.g.read(a, PILOT_N)
            if (r[0] | r[1]) and struct.unpack_from('<H', r, 2)[0] == e:
                col, st = r[0x31], min(255, struct.unpack_from('<H', r, 0)[0])
                break
        cats = []
        rec = self.g.read(self.suit(e), 0x30)
        for c, m in PARTS:
            cur, mx = struct.unpack_from('<h', rec, c)[0], struct.unpack_from('<h', rec, m)[0]
            if cur > int(mx * 73 / 100):
                cats.append(3)
            elif cur < int(mx * 37 / 100) and cur > 0:
                cats.append(1)
            elif cur == 0:
                cats.append(0)
            else:
                cats.append(2)
        lv = bytearray(self.levels(e))                     # (the pilot's level from his health as the bars read it:
        c, m = self.health(e)                              # the host's suit has no squadmate's words at +0x32)
        lv[4] = 0 if m <= 0 else max(0, min(6, (12 - (m - max(0, min(c, m))) * 11 // m) // 2))
        return bytes([col, st] + cats) + bytes(lv)

    def activity(self, e):
        """what the squadmate is doing, as the game's STAT page writes it (0x270FB0): a RESGAME 367 string (0: none)
        and the unit it names. AI record a (entity +0x21): its group g (+6) and the group's record (0x380599 +
        0x170 g: the unit it follows at +0, its mode +0xAE, its order +0xB9); held, charge, repair: by the order
        unless the mode is 0, 2 or 4; else the AI state (+0x30): 0-1 holding position, 2 and 4 following its unit
        (none: moving), 8 and 0x10 attacking (its target, byte +0xCA), anything else planning. (Left out: the
        rewiring of a turret, and the direction the game writes after "Moving".)"""
        a = self.g.read(self.master + 0x25 * e + 0x21, 1)[0]
        if not 0 < a < AI_MAX:
            return 0, 0
        ai = self.g.read(AI_REC + (self.master - 0x3C3240) + AI_N * a, 0xCC)
        gr = self.g.read(GROUPS + 0x170 * ai[6], 0xC0)
        if gr[0xAE] not in (0, 2, 4):
            o = gr[0xB9]
            if o == 1:
                return 179, 0
            if o in (0x19, 0x42):
                return 176, 0
            if o == 0x34:
                return 177, 0
        st = ai[0x30]
        if st <= 1:
            return 179, 0
        if st in (2, 4):
            t = struct.unpack_from('<H', gr, 0)[0]
            return (166, t) if t else (168, 0)
        if st in (8, 0x10):
            return 167, ai[0xCA]
        return 178, 0

    def label(self, e):
        """a unit's name label (entity +0x24, 0x26a6d4: 1-0x1D RESGAME 375 string; else 0)"""
        if not 0 < e < 300:
            return 0
        b = self.g.read(self.master + 0x25 * e + 0x24, 1)[0]
        return b if b <= 0x1D else 0

    def energy_pct(self, e):
        """the energy as the game's panel bar shows it: the current over the suit's max now, both read live (power
        plant damage lowers the max, and he changes suits)"""
        cur, mx = struct.unpack('<ii', self.g.read(self.suit(e) + EN_CUR, 8))
        return 0 if mx <= 0 else max(0, min(100, cur * 100 // mx))

    def game_eye(self, e):
        """the eye of entity e's suit as the game computes its main view (0x27ec90), a world (x, y, z); a record being
        rewritten (out of the window) gives that suit's last good one"""
        b = self.g.read(self.master + 0x25 * e, 0x1B)
        p = [v / 65536 for v in struct.unpack_from('<3i', b, 0x0F)]
        if self.eye_fixed:
            return (p[0], p[1], p[2] + self.eye)
        rec = struct.unpack_from('<H', b, 3)[0]
        if rec <= 200:
            s = PBA + PBA_N * rec
            r = self.g.read(s + J8, 24)
            j8, j9 = struct.unpack_from('<3i', r, 0), struct.unpack_from('<3i', r, 12)
            k = EYE_K.get(struct.unpack('<I', self.g.read(s + SUIT_KIND, 4))[0], EYE_K_ELSE)
            off = [(a + (((a - c) * k) >> 16)) / 65536 - q for a, c, q in zip(j9, j8, p)]   # imul / shrd 16
            if 0.15 < off[2] < 1.2 and math.hypot(off[0], off[1]) < 0.2:
                self.eyes[e] = off
        off = self.eyes.get(e, (0.0, 0.0, self.eye))
        z = off[2] + (self.i32(self.oeil) / 65536 if self.oeil else 0.0)
        return (p[0] + off[0], p[1] + off[1], p[2] + z)

    def host_cam(self, me):
        """the host's main view as the game makes it (0x2695a0), when the bridge gave none: his eye, heading + head,
        head pitch + the ground's slope (unless the game leaves it out); pitch as the bridge sends it (+ = up)"""
        ex, ey, ez = self.game_eye(me)
        eh = ((self.u16(self.master + 0x25 * me + 0x1B) + self.u16(HEADYAW)) & 0xffff) / 65536 * 2 * math.pi
        t = struct.unpack('<h', self.g.read(HEADPITCH, 2))[0]
        if not self.g.read(SLOPE_OFF, 1)[0] & 2:
            t = ((t + struct.unpack('<h', self.g.read(SLOPE, 2))[0] + 0x8000) & 0xffff) - 0x8000
        return (ex, ey, ez, eh, -t / 65536 * 2 * math.pi)

    def alive(self, e):
        return e and self.g.read(self.master + 0x25 * e, 2) == b'\x01\x01' and self.armour(e) > 0

    def pick(self, me, after=0):
        """a living suit of the player's squad (the game's pilot records; versus: of the enemy side): the nearest, or
        the next one after `after` (F8); TN_GUEST_ID wins. The squad is read again each time (his COMM panel, the
        lock's exclusions)"""
        squad = self.enemies_now(me) if self.versus else self.squad_now(me)
        if squad != self.squad:
            print('guest: squad', squad, flush=True)
        self.squad = squad
        if os.environ.get('TN_GUEST_ID'):
            gid = int(os.environ['TN_GUEST_ID'])
            return gid if self.alive(gid) else 0
        if self.lobby.col and not after:                       # the column he took on the outfitting screen
            gid = struct.unpack('<H', self.g.read(coop_lobby.SQUAD + coop_lobby.SQUAD_N * self.lobby.col + 2, 2))[0]
            if gid and self.alive(gid):
                return gid
        live = self.squad                                      # (living, in a steady order)
        if not live:
            return 0
        if after in live:
            return live[(live.index(after) + 1) % len(live)]
        return min(live, key=lambda e: self.dist(me, e))       # a new suit: the one nearest the host

    def laser_off(self, e, firing=False):
        """the laser's sound of suit e (his, or the one he leaves) ended once he no longer fires: see SOUND"""
        if firing:
            self.fired_t = time.time()
        held = firing or time.time() - self.fired_t < 0.12
        if not e:
            return
        g = self.g
        if self.snd_piece is None:                             # a TN+ coop build that plays his shots as a squadmate's
            self.snd_piece = g.read(SND_PIECE, 1) == b'\xe8'  # (each once): his laser held looping (LASER_MATE_SOUNDS)
            print("coop : the guest's shots sound", "at his suit (TN+ coop sound piece)" if self.snd_piece else
                  "as the player's (older TN+ coop build: his laser is stopped by the bridge)", flush=True)
        if held and not self.snd_piece:
            return                                             # (the player's path loops it until stopped)
        v = self.i32(self.suit(e) + SOUND)
        if not 0 <= v < g.read(0x35982D, 1)[0]:
            self.looped = None
            return
        r = g.read(VOICES + VOICE_N * v, 0x1A)
        k = struct.unpack_from('<b', r, 0)[0]
        sound = struct.unpack_from('<H', r, 0x18)[0]
        if self.snd_piece:
            if k < 0 or sound not in LASER_MATE_SOUNDS:
                self.looped = None
                return
        elif k < 0 or r[0x17] != 0 or sound not in LASER_SOUNDS:
            return                                             # (no sample, or a sound played once: it ends by itself)
        p = self.i32(SAMPLES + 4 * k)
        if not 0x100000 <= p < 0x2000000:
            return
        status, length, pos, loops = (struct.unpack('<i', g.read(p + o, 4))[0] for o in (4, 0x10, 0x18, 0x30))
        if held:                                               # (TN+ coop sound piece) his laser goes on while he fires:
            if status == 4 and length > 4 * LOOP_MARGIN and pos > length - LOOP_MARGIN:   # back to its start before
                g.write(p + 0x18, struct.pack('<i', 0))        # its end (its loop count left alone: set to 0 on this
            self.looped = (v, k) if status == 4 else None      # sample it was cut at once, the laser was silent)
            return
        if self.snd_piece and self.looped != (v, k):
            return                                             # (a shot's sound of his own, not held: it ends by itself)
        self.looped = None
        said = (v, k, status, loops)
        if status == 4 and (loops == 0 or self.snd_piece):
            if loops == 0:
                g.write(p + 0x30, struct.pack('<i', 1))
            if 0 < pos < length - 2048:
                g.write(p + 0x18, struct.pack('<i', length - 1024))   # (and its end now: under a twentieth of a second)
            print('guest: laser sound stopped (voice %d, sample %d, entity %d)' % (v, k, e), flush=True)
        elif loops == 0 and said != self.laser_said:           # (once a case: a sound that would go on and is not stopped)
            print('guest: laser sound NOT stopped: voice %d, sample %d, status %d, loops %d' % said, flush=True)
        self.laser_said = said

    def sounds(self, me):
        """the game's sounds started and ended since the last update, for the guest's window (see VOICE_MAX)"""
        g = self.g
        if self.snd_piece and self.gid:
            self.laser_off(self.gid)                           # (his laser's voice set looping before it is told)
        n = min(g.read(VOICE_MAX, 1)[0], 32)
        t = g.read(VOICES, VOICE_N * n)
        owners = {}                                            # a suit's own sound (kind 0): whose
        for e in [me] + list(self.squad) + ([self.gid] if self.gid else []):
            if 0 < e < 300:
                owners.setdefault(self.i32(self.suit(e) + SOUND), e)
        out, now = [], {}
        for k in range(n):
            r = t[VOICE_N * k:VOICE_N * (k + 1)]
            drv = struct.unpack_from('<b', r, 0)[0]
            if drv < 0:
                continue
            sound, kind = struct.unpack_from('<H', r, 0x18)[0], struct.unpack_from('<I', r, 1)[0]
            ent, at = 0, (0.0, 0.0, 0.0)
            if kind in (2, 5):
                ent = struct.unpack_from('<H', r, 0x1A)[0]
                if 0 < ent < self.nent:                        # (and where it is: a shot or a blast is not among the
                    at = tuple(v / 65536 for v in struct.unpack('<3i', g.read(self.master + 0x25 * ent + 0x0F, 12)))   # guest's units)
            elif kind == 1:
                at = tuple(v / 65536 for v in struct.unpack_from('<3i', r, 0x1A))
            elif kind == 0:                                    # the game's player's own sounds: a suit's shot (its
                ent = owners.get(k, 0)                         # voice, +0x82), placed at that suit; the radio (speech)
                if not ent and STEP0 <= sound < STEP0 + 30:   # (the host's footstep: the ground's kind, own_steps)
                    self.step_ground = (sound - STEP0) // 5
                if not ent and not SPEECH0 <= sound < SPEECH_END and os.environ.get('TN_COOP_HOST_COCKPIT') != '1':
                    if sound not in self.private_said:         # for both; anything else is the host's cockpit (its
                        self.private_said.add(sound)           # servos, alarms, beeps, and what the cave's pass for
                        print("coop: sound %d is the host's own, not sent to the guest" % sound, flush=True)
                    continue                                   # the guest's suit plays as the player's): not his
            p = self.i32(SAMPLES + 4 * drv) if 0 <= drv < 16 else 0
            pos = self.i32(p + 0x18) if 0x100000 <= p < 0x2000000 else 0
            once = 0 if self.looped == (k, drv) else r[0x17]   # (his laser held looping: laser_off)
            now[k] = (sound, kind, ent, pos, once)
            was = self.voices.get(k)
            if was is None or was[:3] != (sound, kind, ent) or (once and pos + 4096 < was[3]):   # (a loop going round: the same)
                if was is not None:
                    out.append(b'E' + bytes([k]))
                out.append(b'S' + struct.pack('<BHBBBH3f', k, sound, kind & 0xFF, once, r[0x15], ent, *at))
            elif was[4] and not once:                          # (held looping since: his window loops it too, from
                out.append(b'S' + struct.pack('<BHBBBH3f', k, sound, kind & 0xFF, once, r[0x15], ent, *at))   # the start)
        for k in self.voices:
            if k not in now:
                out.append(b'E' + bytes([k]))
        out += self.own_steps(me)
        self.voices = now
        if time.time() - self.voices_t > 0.5:                 # twice a second, the voices playing: online the sounds
            self.voices_t = time.time()                        # go unreliable, an end lost is caught up this way
            out.append(b'A' + bytes([len(now)]) + b''.join(struct.pack('<BH', k, v[0]) for k, v in sorted(now.items())))
        if out:
            pk = b'SND' + bytes([g.read(SFX_VOLUME, 1)[0], min(len(out), 255)]) + b''.join(out[:255])
            self.s.sendto(pk, ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))

    def own_steps(self, me):
        """his own footsteps in his window. The game plays footsteps for its player only (0x27E5B8 -> 0x248EBC, the
        suit's entity tested against the player word): the host's, unplaced, never the guest's suit's. His window
        gets them as the game makes the player's: the sound 1941 + 5 x the ground's kind + one of 4 at random, its
        volume 16 x the speed (units a second) + 0..9, not placed. The ground's kind: the one of the host's last
        footstep (same map), else 4. On voices 16-19 (the game has 16): an older window ignores them"""
        here = self.target_pos(self.gid) if self.gid else None
        t = time.time()
        if here and self.step_at and 0.25 <= t - self.step_at[1] < 1.0:   # (his speed over a quarter second)
            self.step_speed = math.dist(here[:2], self.step_at[0][:2]) / (t - self.step_at[1])
        if not here or not self.step_at or t - self.step_at[1] >= 0.25:
            self.step_at = (here, t) if here else None
        speed = self.step_speed
        out = []
        while self.step_due > 0:
            self.step_due -= 1
            r = int.from_bytes(os.urandom(2), 'little')
            sound = STEP0 + 5 * self.step_ground + r % 4
            vol = max(1, min(127, int(16 * speed) + r // 4 % 10))
            out.append(b'S' + struct.pack('<BHBBBH3f', 16 + self.step_n % 4, sound, 0, 1, vol, 0, 0.0, 0.0, 0.0))
            self.step_n += 1
        return out

    def take(self, gid):
        g = self.g
        g.write(G_ON, b'\x00')
        if self.gid and self.gid != gid:
            try:
                self.fired_t = 0.0
                self.laser_off(self.gid)                       # (the suit he leaves: its sound would never be stopped)
            except (OSError, struct.error):
                pass
        self.gid = gid
        if gid:
            g.write(G_TIM, bytes(16)); g.write(G_CTRL, bytes(0x28)); g.write(G_ID, struct.pack('<H', gid))
            g.write(G_JUMP, b'\x00')                           # (a kick the last suit never took: not for this one)
            g.write(G_ON, b'\x01')
            self.amax, self.state, self.taken_t = self.armour_max(gid), OK, time.time()
            self.pending, self.jet_n, self.jet_air = [0, 0, 0], None, None
            self.steps, self.feet, self.stance, self.at, self.walk = 0, None, None, None, 0
            print('guest: entity %d' % gid, flush=True)
            self.tag.put(gid, self.name, self.face)
        else:
            self.tag.restore()

    def lobby_step(self, in_mission):
        """his requests, the redraw the outfitting screen waits for, and the lobby state for his window (twice a
        second in the menus, every 3 s in a mission: there it only tells his window to hide the lobby)"""
        for m in self.lobby_msgs:
            r = self.lobby.request(m, in_mission)
            if r:
                print('lobby:', r, flush=True)
                self.lobby_t = 0.0
        self.lobby_msgs = []
        self.lobby.guest_name = self.name
        self.lobby.tick(in_mission)
        if time.time() - self.lobby_t >= (3.0 if in_mission else 0.5):
            self.lobby_t = time.time()
            self.s.sendto(self.lobby.packet(in_mission), ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))

    def hud(self):
        if time.time() - self.hud_t < 0.1:
            return
        self.hud_t = time.time()
        a = self.armour(self.gid) if self.gid else 0
        sel, wtype = 0, 0
        if self.gid:
            p = self.suit(self.gid)
            sel = self.g.read(p + SEL, 1)[0] & 3
            wtype = self.g.read(p + SLOTS + SLOT_N * sel, 1)[0]
        head = self.u16(self.master + 0x25 * self.gid + 0x1B) if self.gid else 0
        # then: his lock (entity, middle; 0 = none), his suit's and the host's positions (the name markers)
        lt = self.target_pos(self.lock) if self.lock else None
        mine = self.target_pos(self.gid) if self.gid else None
        me = host_entity(self.g, self.pid_addr)
        host = tuple(self.i32(self.master + 0x25 * me + o) / 65536 for o in (0x0F, 0x13, 0x17))
        pk = b'GHD' + struct.pack('<BhhHBBH', self.state, max(0, a), self.amax, self.gid, sel, wtype, head) + \
            struct.pack('<H3f', self.lock if lt else 0, *(lt or (0, 0, 0))) + struct.pack('<3f', *(mine or (0, 0, 0))) + \
            struct.pack('<3f', *host) + self.squad_info(me) + struct.pack('<H', me) + self.hud_more()   # (me: the host's
        # entity, his name follows his drawn suit)
        mb = 0
        if self.gid and self.state == OK:
            try:
                n0 = len(pk)
                pk += self.map_block(me)                       # (an older guest window stops reading before it)
                mb = len(pk) - n0
            except (OSError, struct.error, IndexError) as ex:
                if not self.map_said:
                    self.map_said = True
                    print('guest: no map marks (%r)' % (ex,), flush=True)
            if self.lock:
                try:
                    pk += self.lock_info()
                except (OSError, struct.error):
                    pass
            try:
                pk += self.iff_block()                         # (at the very end: read from the end)
            except (OSError, struct.error, IndexError):
                pass
            if self.oeil:                                      # the height the game's target camera adds (0x275260)
                pk += struct.pack('<f', self.i32(self.oeil) / 65536 + 0.1875) + b'TCM'
        if len(pk) > self.ghd_max:                             # (online, over 1200 bytes it goes reliable: late)
            self.ghd_max = len(pk)
            print('coop: HUD packet %d bytes (map block %d)' % (len(pk), mb), flush=True)
        self.s.sendto(pk, ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))
        eq = self.equip.packet() if self.gid and self.state == OK else None
        if eq:                                                 # his drone and A.S.F. (guest_equipment.gd)
            self.s.sendto(eq, ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))
        # the cockpit: every 2 s for 20 s after a teammate is taken (his window may still be starting), then every 15 s
        if time.time() - self.tpl_t > (2.0 if time.time() - self.taken_t < 20.0 else 15.0):
            self.cockpit()

    def indicator(self):
        """the armour indicator's picture (palette indices, 42 x 21) from the game's files; None: not there"""
        if self.ind is None:
            self.ind = False
            try:
                import numpy as np, lgres
                f = lgres.frames(lgres.load(os.path.join(self.data_dir, 'RESHLMHI.RES'))[IND_RES][2])[0]
                w, h, row = struct.unpack_from('<HHH', f, 8)
                if f[4] == 2 and len(f) >= 0x1C + row * (h - 1) + w:
                    self.ind = np.frombuffer(f[0x1C:0x1C + row * h].ljust(row * h, b'\0'), np.uint8).reshape(h, row)[:, :w]
            except Exception:
                pass
        return None if self.ind is False else self.ind

    def regions(self):
        """the cockpit's COMM, map and WEAPON panels and its compass strip (x0, y0, x1, y1), as the game has them now;
        those it does not show: where the usual cockpit has them"""
        rs = []
        for k in range(8):
            p = struct.unpack('<I', self.g.read(REGIONS + 4 * k, 4))[0]
            if 0x380000 <= p < 0x3A0000:
                rs.append(struct.unpack('<4h', self.g.read(p + 8, 8)))
        low = sorted(r for r in rs if r[1] > 200 and 40 < r[2] - r[0] < 120)
        top = [r for r in rs if r[1] < 30 and r[2] - r[0] > 200]
        home = [(x, y, x + 1, y + 1) for x, y in REG_HOME]
        return (low if len(low) == 3 else home[:3]) + [top[0] if top else home[3]]


    def cockpit(self):
        src = self.hud_src() if self.hud_src else None
        if not src:
            return
        import numpy as np
        scr, alpha, (fx0, fy0, fw, fh), pal = src[:4]
        still = src[4] if len(src) > 4 else None
        if fw < 100 or fh < 100:                               # the game's map or a menu: not the cockpit
            return
        if fh > 300:                                           # the host's full view (G): his, not the guest's, whose
            return                                             # window makes its own (coop_views.gd)
        # ... nor while the game writes a line for the host at the bottom of his cockpit (what a button does: a box
        # drawn in its green, 161 pixels across): it stayed on the guest's cockpit until the next picture
        line = np.cumsum(scr[360:400] == 0x84, axis=1)
        if (line[:, 120:] - line[:, :-120]).max() >= 120:
            return
        self.tpl_t = time.time()
        scr, alpha = scr.copy(), alpha.copy()
        # the 3D window: only the cockpit's frame stays, pixel for pixel as on the host's screen (its rounded corners):
        # what is opaque there (and has not changed for a second, when the bridge knows) and joined to the window's
        # edge. The rest is the host's own, drawn in the 3D (crosshair, armour indicator, target box): left out
        win = alpha[fy0:fy0 + fh, fx0:fx0 + fw]
        opaque = still if still is not None and still.shape == win.shape else win == 255
        edge = np.zeros_like(opaque)
        edge[0], edge[-1], edge[:, 0], edge[:, -1] = opaque[0], opaque[-1], opaque[:, 0], opaque[:, -1]
        while True:
            g = edge.copy()
            g[1:] |= edge[:-1]; g[:-1] |= edge[1:]
            g[:, 1:] |= g[:, :-1].copy(); g[:, :-1] |= g[:, 1:].copy()
            g &= opaque
            if (g == edge).all():
                break
            edge = g
        # ... but not the cracks the game draws across the host's visor once he is hurt (they join the frame): the
        # frame as it was last seen while he was whole, when there is one
        pix = scr[fy0:fy0 + fh, fx0:fx0 + fw]
        me = host_entity(self.g, self.pid_addr)
        cur, mx = self.health(me)
        if cur >= mx and self.armour(me) >= self.armour_max(me):
            self.frames[(fx0, fy0, fw, fh)] = (edge.copy(), pix.copy())
        elif (fx0, fy0, fw, fh) in self.frames:
            edge, whole = self.frames[(fx0, fy0, fw, fh)]
            pix[edge] = whole[edge]
        win[:] = np.where(edge, 255, 0)
        # where the game draws the host's armour indicator: its dark outline, whole, in the window
        ind = self.indicator()
        if ind is not None and ind.shape[0] <= fh and ind.shape[1] <= fw:
            h, w = ind.shape
            dark = scr[fy0:fy0 + fh, fx0:fx0 + fw] == IND_EDGE
            ok = np.ones((fh - h + 1, fw - w + 1), bool)
            for y, x in zip(*np.nonzero(ind == IND_EDGE)):
                ok &= dark[y:y + fh - h + 1, x:x + fw - w + 1]
                if not ok.any():
                    break
            at = np.argwhere(ok)
            if len(at) == 1:
                self.ind_at = (fx0 + int(at[0][1]), fy0 + int(at[0][0]))
        reg = self.regions()
        moves = [(reg[k][0] - REG_HOME[k][0], reg[k][1] - REG_HOME[k][1]) for k in range(4)]
        for i, ((x0, y0, x1, y1), c, a) in enumerate(CLEAR):
            dx, dy = moves[i] if i < 4 else (0, 0)          # (CLEAR: COMM, WEAPON, map, compass, rear view)
            if i in (1, 2):
                dx, dy = moves[3 - i]
            x0, x1, y0, y1 = max(0, x0 + dx), min(320, x1 + dx), max(0, y0 + dy), min(400, y1 + dy)
            scr[y0:y1, x0:x1] = c
            alpha[y0:y1, x0:x1] = a
        scr[BAR_ROWS[0]:BAR_ROWS[1], BAR_LEDS] = 0
        pk = b'GCK' + struct.pack('<4h', fx0, fy0, fw, fh) + pal + zlib.compress(np.dstack([scr, alpha]).tobytes() +
                                                                       b'RGN' + b''.join(struct.pack('<2h', *r[:2]) for r in reg), 6)
        if len(pk) < 60000:
            self.s.sendto(pk, ('127.0.0.1', REMOTE_VIEW if self.remote else HUD_PORT))

    def step(self, body, joints, arts=(), cam=None, seen=None, alarm=0):
        # cam: the bridge's main view (x, y, z, heading, pitch): the spectator's; seen: the entity it is seen from (the
        # host, or his drone); alarm: the mission's alarm byte. The views end as the host's: the entity whose body the
        # view hides, then the alarm (the type-57 lamps)
        g, M = self.g, self.master
        host_state.tick(self)                                  # where the host's game is, for his window (host_state.py)
        coop_music.tick(self)                                  # the game's music, for his window (coop_music.py)
        if not self.ready:
            self.ready = g.read(CAVE, 4) != bytes(4)
            if self.ready:
                print('coop : code in place', flush=True)
            elif not self.ready_said and time.time() - self.ready_t > CAVE_WAIT:
                self.ready_said = True
                print('coop : NOT in place after %d s (start the game with TN+ Coop, English game)' % CAVE_WAIT, flush=True)
            if not self.ready:
                return
        me = host_entity(self.g, self.pid_addr)
        self.host_marker(g.read(M + me * 0x25, 2) == b'\x01\x01')
        if g.read(M + me * 0x25, 2) != b'\x01\x01':          # not in a mission
            if self.gid:
                self.take(0)
            self.squad, self.state = [], OK
            self.read_input(False)                             # no stale look / F8 at the next mission start
            self.lobby_step(False)
            return
        if not self.joined:                                    # online, nobody joined (or he left): the squad stays the
            if self.gid:                                       # game's (a teammate held for "Player 2" stood still)
                self.take(0)
                self.state = OK
            self.read_input(False)
            return
        if self.state == OK and not self.alive(self.gid):
            if self.gid:                                       # his suit is destroyed: a few seconds, then the next one
                self.take(0)
                self.state, self.down_t = DOWN, time.time()
                print('guest: suit destroyed', flush=True)
            else:
                self.take(self.pick(me))
                if not self.gid:                               # no teammate yet: the host's view, try again
                    self.state, self.down_t = SPECTATE, time.time() - 3.0
        if self.state != OK and time.time() - self.down_t > 3.0:
            gid = self.pick(me)
            if gid:
                self.take(gid)
            else:
                self.state = SPECTATE                          # no teammate left: the host's view
        if self.next and self.state == OK:
            self.next = False
            gid = self.pick(me, self.gid)
            if gid and gid != self.gid:
                self.take(gid)
        self.next = False
        self.hud()
        try:
            self.sounds(me)
        except (OSError, struct.error):
            pass
        self.tag.retry()
        self.lobby_step(True)
        if self.versus and self.state == OK:
            self.versus_hits(me)
        turn = self.read_input(self.state == OK)
        self.equip.tick(self.state == OK)
        if self.state != OK:                                   # the guest watches through the host's eyes
            self.send(struct.pack('<6f2i', *(cam or self.host_cam(me)), self.fov_now(), len(body), me) +
                      b''.join(body) + struct.pack('<i', len(joints)) + b''.join(joints) +
                      struct.pack('<i', len(arts)) + b''.join(arts) + struct.pack('<2i', seen or me, 1 if alarm else 0))
            return
        eg = M + self.gid * 0x25
        self.bound_tick()
        k = lambda sc: 1 if sc in self.keys else 0
        fwd, side, fire = k(0x11) - k(0x1F), k(0x20) - k(0x1E), self.fire
        p = None if self.remote else pad()        # online: the guest's own window only
        if p:                                                  # gamepad
            fwd = max(-1.0, min(1.0, fwd + axis(p.ly)))
            side = max(-1.0, min(1.0, side + axis(p.lx)))
            turn += axis(p.rx) * 600
            self.pitch = max(-0.9, min(0.9, self.pitch + axis(p.ry) * 0.03))
            fire = fire or p.rt > 64
        pad_jets = False
        if self.remote and self.rpad and time.time() - self.rpad_t < 0.3:   # online gamepad, same as the local one
            lx, ly, rx, ry, pf, pj = self.rpad
            fwd = max(-1.0, min(1.0, fwd + ly))
            side = max(-1.0, min(1.0, side + lx))
            turn += rx * 600
            self.pitch = max(-0.9, min(0.9, self.pitch + ry * 0.03))
            fire = fire or pf
            pad_jets = pj
        if turn:
            g.write(eg + 0x1B, struct.pack('<H', (self.u16(eg + 0x1B) + int(turn)) & 0xffff))
        c = bytearray(0x28)
        struct.pack_into('<ii', c, 0, int(fwd * 0x10000), int(side * 0x10000))
        g.write(G_CTRL, bytes(c))
        self.push(0x39 in self.keys or bool(p and p.lt > 64) or pad_jets)   # Space / left trigger
        gx, gy, gz = (self.i32(eg + o) / 65536 for o in (0x0F, 0x13, 0x17))
        gh = self.u16(eg + 0x1B) / 65536 * 2 * math.pi
        # aim: 30 units along the guest's view, or his locked target; held = a request every frame (the weapon's
        # reload sets the pace)
        eye = (gx, gy, self.game_eye(self.gid)[2])         # (the game's eye is up to 0.04 ahead: left out)
        view = (math.cos(gh) * math.cos(self.pitch), math.sin(gh) * math.cos(self.pitch), math.sin(self.pitch))
        if self.lock_req:
            # (the game's click, 0x269F28 -> 0x262D4C: the unit under it becomes the target, locked or not; nothing
            # under it: the target is dropped)
            self.lock_req = False
            was = self.lock
            self.lock = self.pick_target(me, eye, view, self.lock_seen)
            if was and not self.lock:
                print('guest: lock cleared (%d: nothing under his crosshair)' % was, flush=True)
            self.lock_seen = []
        if self.lock_step:                                     # the game's next / previous target keys (T, Y): the
            seen = [i for _, i in self.in_view(me, eye, view)]   # units in his view by distance, round from his target
            if seen:
                k = seen.index(self.lock) if self.lock in seen else (-1 if self.lock_step > 0 else 0)
                self.lock = seen[(k + self.lock_step) % len(seen)]
                print('guest: lock', self.lock, '(next)' if self.lock_step > 0 else '(previous)', flush=True)
            self.lock_step = 0
        aim = None
        if self.lock:
            t = self.target_pos(self.lock)
            if t is None:
                print('guest: lock lost (%d: gone)' % self.lock, flush=True)
                self.lock = 0                                  # (destroyed: the game's callback clears its target too)
            else:
                side, up = self.off_aim(eye, view, t)
                if side < LOCK_KEEP and up < LOCK_KEEP_V:
                    aim = t
                elif (side > LOCK_PICK or up > LOCK_PICK_V) and math.dist(t[:2], eye[:2]) > self.sensor():
                    print('guest: lock lost (%d: off his view, out of his sensor range)' % self.lock, flush=True)
                    self.lock = 0                              # (the game's rule: off its screen and out of range)
        if aim is None and fire and AIM_ON:                    # (coop_aim.py: what his crosshair is on, at any distance)
            s = self.suit(self.gid)
            wt = g.read(s + SLOTS + SLOT_N * (g.read(s + SEL, 1)[0] & 3), 1)[0]
            aim, what = self.aimer.point(eye, view, self.u16(W_RANGE + W_N * wt), (self.gid,), time.time())
        elif aim is not None:
            what = 'lock %d' % self.lock
        else:
            what = 'view 30'
        if aim is None:
            aim = tuple(e + v * 30 for e, v in zip(eye, view))
        if fire and AIM_LOG:
            print('aim: %.3f eye %.3f %.3f %.3f view %.4f %.4f %.4f aim %.3f %.3f %.3f -> %s at %.2f' % (
                time.time(), *eye, *view, *aim, what, math.dist(eye, aim)), flush=True)
        g.write(G_TGT, struct.pack('<3i', *(int(v * 65536) for v in aim)))
        if fire:
            g.write(G_FIRE, b'\x01')
        self.laser_off(self.gid, bool(fire))
        # the host's suit: the game never poses it in the cockpit view, its joints there are stale (they folded it
        # out of sight): left out; the learnt walk / rest pose instead, else the viewer's default pose
        joints = [j for j in joints if struct.unpack_from('<i', j)[0] != me]
        if self.anim:
            now = time.time()
            top = lambda j: max(struct.unpack_from('<48f', j, 8)[1::3])   # record: index, foot height, 48 floats
            hmax = max(map(top, joints)) if joints else 0
            up = {struct.unpack_from('<i', j)[0]: struct.unpack_from('<48f', j, 8) for j in joints if top(j) > 0.8 * hmax}
            where = lambda i: (self.i32(M + 0x25 * i + 0x0F) / 65536, self.i32(M + 0x25 * i + 0x13) / 65536,
                               self.u16(M + 0x25 * i + 0x1B) / 65536 * 2 * math.pi)
            self.anim.learn(up, where, now)
            pose = self.anim.host(*where(me), now)
            if pose:
                # after the index: the height of the feet in the world (the game's entity height minus its 0.12)
                joints = joints + [struct.pack('<if', me, self.i32(M + 0x25 * me + 0x17) / 65536 - 0.12) + pose]
        dv = self.equip.camera((*eye, gh, self.pitch))         # his view through his drone: from it, the drone hidden
        view = (struct.pack('<6f2i', *(dv[:5] if dv else (*eye, gh, self.pitch)), (self.fov_rest or self.fov_now)(), len(body), self.gid) +
                b''.join(body) + struct.pack('<i', len(joints)) + b''.join(joints) +
                struct.pack('<i', len(arts)) + b''.join(arts) + struct.pack('<2i', dv[5] if dv else self.gid, 1 if alarm else 0))
        self.send(view)

    def resync(self, pk):
        # 'R': the guest's decor table is not ours (it joined late), or it just connected (coop_net.gd)
        if pk[:1] == b'R' and self.enc and time.time() - self.resync_t > 0.5:
            self.resync_t = time.time()
            self.enc.resync()
            self.taken_t = time.time()                     # and his cockpit again

    def read_input(self, active):
        """the guest window: keys, mouse, buttons, online gamepad; returns the turn. Key and button releases count
        even while he has no suit (else a key let go while down stays held on the next teammate); look and F8 do not"""
        turn = 0
        for _ in range(512):
            try:
                pk, _ = self.rx.recvfrom(16384)
            except BlockingIOError:
                break
            except OSError:                                    # a datagram over 16 KB (WSAEMSGSIZE): dropped
                continue
            if pk == b'X':                                     # he left (coop_net.gd): his teammate back to the game
                if self.joined:
                    self.joined = False
                    print('guest: left', flush=True)
                self.gnav, self.fire = None, False             # (his map marker goes with him, and his fire)
                continue
            if not self.joined:
                self.joined = True
                print('guest: joined', flush=True)
            self.resync(pk)
            if pk[:1] == b'K' and len(pk) >= 4:
                sc, down = struct.unpack('<HB', pk[1:4])
                if sc == F8 and down and active:
                    self.next = True
                if sc in WEAPON_KEYS and down and active and self.gid:
                    self.select_weapon(WEAPON_KEYS[sc])
                if sc in TARGET_KEYS and down and active:
                    self.lock_step = TARGET_KEYS[sc]
                if sc == DROPSHIP and down and active:
                    self.call_dropship()
                self.equip.key(sc, down, active)               # 5 his A.S.F., Ctrl+Home his drone back
                if sc in SHIFT:
                    self.shift = bool(down)
                elif sc in JUMP_DIR and not down:
                    self.held.pop(sc, None)
                elif sc in JUMP_DIR and sc not in self.held:
                    self.held[sc] = [time.time()] * 2
                    if active and self.shift:
                        self.jump(JUMP_DIR[sc])
                if sc in KEYS:
                    (self.keys.add if down else self.keys.discard)(sc)
            elif pk[:1] == b'M' and len(pk) >= 5:
                if active:
                    dx, dy = (max(-200, min(200, v)) for v in struct.unpack('<hh', pk[1:5]))
                    turn += dx * self.sens_x
                    self.pitch = max(-0.9, min(0.9, self.pitch - dy * 0.003))
            elif pk[:1] == b'B' and len(pk) >= 3 and pk[1] == 2:
                if pk[2] and active:                           # (then the units his window drew under his crosshair)
                    self.lock_req = True
                    self.lock_seen = list(struct.unpack('<%dH' % ((len(pk) - 3) // 2), pk[3:3 + (len(pk) - 3) // 2 * 2]))
            elif pk[:1] == b'B' and len(pk) >= 3 and pk[1] == 1:
                self.fire = bool(pk[2])
            elif pk[:1] == b'C' and len(pk) >= 3 and pk[1] == 1 and not pk[2]:
                self.fire = False                              # (the left button let go with his mouse freed)
            elif pk[:1] == b'E' and len(pk) >= 2:                # his drone / A.S.F. (guest_equipment.py)
                self.equip.message(pk, active)
            elif pk[:1] == b'W' and len(pk) == 9:                # his map marker: put there, or (x = 0) taken away
                x, y = struct.unpack('<2f', pk[1:])
                self.gnav = (x, y) if active and 1.0 <= x <= 511.0 and 1.0 <= y <= 511.0 else None
            elif pk[:1] == b'N' and len(pk) > 1:                 # his Steam name (host coop_net.gd): on the host's HUD
                name = pk[1:33].decode('utf-8', 'ignore')
                if name != self.name:
                    self.name = name
                    if self.gid and self.state == OK:
                        self.tag.put(self.gid, name, self.face)
            elif pk[:1] == b'A' and len(pk) == 1 + 21 * 27 * 3 and pk[1:] != self.face:   # his avatar (coop_net.gd)
                self.face = pk[1:]
                if self.gid and self.state == OK:
                    self.tag.put(self.gid, self.name, self.face)
            elif pk[:1] == b'Q' and len(pk) == 1 + 64 * 64 * 3:     # his avatar, 64 x 64 (host coop_net.gd): the lobby
                self.lobby.guest_face = pk[1:]
            elif pk[:1] == b'L' and len(pk) > 1:                 # lobby request (his window's coop_hud.gd): JSON
                try:
                    self.lobby_msgs.append(json.loads(pk[1:].decode('utf-8')))
                except ValueError:
                    pass
            elif pk[:1] == b'P' and len(pk) >= 6 and self.remote:   # online gamepad (coop_net.gd)
                lx, ly, rx, ry, f = struct.unpack('<bbbbB', pk[1:6])
                self.rpad = tuple(max(-1.0, min(1.0, v / 127)) for v in (lx, ly, rx, ry)) + (bool(f & 1), bool(f & 8))
                if f & 2 and not self.pad_jump:                 # button A: jump where the left stick points
                    self.pad_t = [time.time()] * 2
                    if active:
                        self.jump(self.pad_angle())
                self.pad_jump = bool(f & 2)
                if f & 4 and not self.pad_lock and active:
                    self.lock_req = True
                self.pad_lock = bool(f & 4)
                self.rpad_t = time.time()
        return turn

    def pad_angle(self):
        return math.atan2(self.rpad[0], self.rpad[1]) if abs(self.rpad[0]) + abs(self.rpad[1]) > 0.3 else 0.0

    def smoke(self, clouds):
        """Smoke grenades' clouds (live_bridge.py fumees) for the guest's window: at most 40 particles a cloud. Local:
        'SMKC' as the bridge sends it, 20 a second. Online: 'SMK' + zlib, 5 a second (his viewer keeps the screen
        thick by itself between them); one empty message when they are over."""
        if not clouds and not self.smoke_on:
            return
        now = time.time()
        if self.remote and clouds and now - self.smoke_t < 0.2:
            return
        self.smoke_t, self.smoke_on = now, bool(clouds)
        out = []
        for c in clouds:
            n = struct.unpack_from('<H', c, 16)[0]
            keep = range(0, n, max(1, -(-n // 40)))
            out.append(c[:16] + struct.pack('<H', len(keep)) + b''.join(c[18 + 14 * k:32 + 14 * k] for k in keep))
        body = bytes([len(out)]) + b''.join(out)
        if self.remote:
            self.s.sendto(b'SMK' + zlib.compress(body, 6), ('127.0.0.1', REMOTE_VIEW))
        else:
            self.s.sendto(b'SMKC' + body, ('127.0.0.1', LIVE_PORT))

    def weather(self, pk):
        """The weather ('WTHR', live_bridge.py meteo) for the guest's window: local as it is; online 'WTH' when it
        changes, else every 2 s (a joining guest gets it)."""
        if not self.remote:
            self.s.sendto(pk, ('127.0.0.1', LIVE_PORT))
            return
        if pk != self.weather_pk or time.time() - self.weather_t > 2.0:
            self.weather_pk, self.weather_t = pk, time.time()
            self.s.sendto(b'WTH' + pk[4:], ('127.0.0.1', REMOTE_VIEW))

    def relay(self, pk, force=False):
        """What the bridge sends the host's window about his picture and the guest's needs as well: the sky's drift
        and sway (SKYO), the waypoint (WAYP), the haze (HAZE), the soldiers' bone lengths, arms and walks (SLEN, ARMS, GAIT), the
        ground tiles (TEXL, local only). Local: as it is. Online: 'LIV' + the packet (coop_net.gd hands the listed
        ones to his viewer), when it changes, at most RELAY_GAP a second, and every 2 s."""
        if not self.remote:
            self.s.sendto(pk, ('127.0.0.1', LIVE_PORT))
            return
        tag, now = pk[:4], time.time()
        gap = RELAY_GAP.get(tag)
        if gap is None:
            return
        last, t = self.relayed.get(tag, (b'', 0.0))
        if (pk != last and (now - t >= gap or force)) or now - t >= 2.0:
            self.relayed[tag] = (pk, now)
            self.s.sendto(b'LIV' + pk, ('127.0.0.1', REMOTE_VIEW))

    def fx29(self, pk=None):
        """What each 6/29 is when not a shot's dust ('FX29', live_bridge.py sortes_29: a jetpack's trail, a tree's
        smoke) for the guest's window: local as it is; online 'FXS', reliable, at most 20 a second (his views come at
        that rate), the last one once it is due. pk None: only what is due (called with each view)."""
        if pk is not None:
            self.fx_pk = pk
        if not self.remote:
            if pk is not None:
                self.s.sendto(pk, ('127.0.0.1', LIVE_PORT))
            return
        now = time.time()
        if self.fx_pk != self.fx_sent and now - self.fx_t >= 0.05:
            self.fx_sent, self.fx_t = self.fx_pk, now
            self.s.sendto(b'FXS' + self.fx_pk[4:], ('127.0.0.1', REMOTE_VIEW))

    def beams(self, pk):
        """The game's beams ('BEAM', live_bridge.py rayons: the two ends and the colour of each 6/28) for the guest's
        window: local as they are; online 'BMS' with his next view (extras): a beam lives one to three pictures of
        the game, he gets those of the moment his view is made."""
        if self.remote:
            self.beam_pk = pk
        else:
            self.s.sendto(pk, ('127.0.0.1', LIVE_PORT))

    def dust(self, pk):
        """The shots' dust ('PART', live_bridge.py poussieres: each particle's place and colour) for the guest's
        window: local as it is; online 'PTS' + zlib with his views (extras), at most 10 a second and 300 particles."""
        if self.remote:
            self.part_pk = pk
        else:
            self.s.sendto(pk, ('127.0.0.1', LIVE_PORT))

    def extras(self, now):
        """online, with each view: the beams and the dust of that moment (an empty one once they are over)"""
        pk = self.beam_pk
        if pk is not None and (len(pk) > 6 or pk != self.beam_sent):
            self.beam_sent = pk
            n = min(40, struct.unpack_from('<H', pk, 4)[0])                            # (40 beams fit an unreliable packet)
            self.s.sendto(b'BMS' + struct.pack('<H', n) + pk[6:6 + 29 * n], ('127.0.0.1', REMOTE_VIEW))
        pk = self.part_pk
        if pk is not None and (len(pk) > 6 or pk != self.part_sent) and now - self.part_t >= 0.1:
            self.part_sent, self.part_t = pk, now
            n = min(300, struct.unpack_from('<H', pk, 4)[0])
            self.s.sendto(b'PTS' + zlib.compress(struct.pack('<H', n) + pk[6:6 + 14 * n], 1), ('127.0.0.1', REMOTE_VIEW))

    def send(self, view):
        if not self.remote:
            self.s.sendto(view, ('127.0.0.1', LIVE_PORT))
            return
        now = time.time()
        if now - self.sent_t < 1 / self.view_hz:              # online: view_hz views a second (--view-hz)
            return
        self.sent_t = max(self.sent_t + 1 / self.view_hz, now - 1 / self.view_hz)   # on the beat, not the bridge's frames
        self.fx29()                                           # a 6/29 sort held back by the 20 a second
        self.extras(now)                                      # the beams and the dust of this moment
        for m in self.enc.encode(view, now):
            self.s.sendto(m, ('127.0.0.1', REMOTE_VIEW))
