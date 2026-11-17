# Technical notes

For modders and the curious: how Terra Nova Uplink reads the game files.

## Command line options (for screenshots and tests)

`godot --path . -- [options]`

| Option | Meaning |
|---|---|
| `--mission "05 "` | open the entry whose label contains this text (or a file name, e.g. `MISS17.RES`) |
| `--cam x,y,height,yaw,pitch` | camera position (map units, height above the ground) and angles in degrees |
| `--clean` | no labels, zones, panel or help line |
| `--shot file.png` | save a screenshot and quit |
| `--all` | load every entry once and quit (test) |

## File formats

Everything below was worked out for Uplink from the game files and from the game's own code (`__FF.EXE`). Memory addresses refer to the running game (GOG version, as loaded by DOSBox).

| File / resource | Contents |
|---|---|
| LG Res v2 | 128-byte header, directory offset at 0x7C; entries: u16 id, 24-bit size + flags, 24-bit compressed size + type |
| MAPx.RES 86 | 513 × 513 × 3 bytes a point: byte 0 = tile (bits 5:0), burned (bit 6: set on 240 points of 13 maps), light level bit 0 (bit 7); byte 1 = light level bits 2:1 (bits 1:0; level 0 brightest .. 7), quarter turns (bits 3:2; the plain tiles turned again at load from resource 81's seed), height bits 3:0 (bits 7:4); byte 2 = height bits 11:4. Height = (s16 at +1 & ~0xF) ÷ 384 game units (12 bits ÷ 24) |
| MAPx.RES 85 | 257 × 257 × 3 bytes, same format, step 4, offset 256 |
| MAPx.RES 80 | planet file name (`resplntN.res`) |
| MAPx.RES 82 | light: u16 azimuth, u16 elevation (1/65536 turn) — the engine also draws the sky's moon there; s32 16.16 diffuse, s32 16.16 ambient (lowered to 1 − diffuse when they add up to more than 1; the stored light levels are baked with them, the models are lit with them); a last u16 with no reader |
| MAPx.RES 83 | vegetation map, 128 × 128 bytes stored column by column (index = x × 128 + y), 4 × 4-unit cells; value v > 0 → list 119 + v |
| MAPx.RES 81 | u16 seed of the quarter turns the loader draws for the plain tiles (0x29431C) |
| MAPx.RES 84 | names of the 30 vegetation lists 120-149 (16 bytes each) |
| MAPx.RES 120-149 | 30 vegetation lists (50-byte entries: class, type, X/Y offsets in 16.16, 0 to 4 inside the cell) |
| RESPLNTn 48 | 64 × 64 ground tiles one after the other (4096 bytes each; 64 tiles, 53 and 59 on planets 2 and 3) |
| RESPLNTn 43 | tile → material (64 entries) |
| RESPLNTn 47 | material → first tile, number of variants |
| RESPLNTn 46 | transition table: index = materialA × 5n + materialB × 5 + shape → tile, n = RESPLNTn 42 byte 0 (10 / 9 / 7 / 8 / 10 materials); the game itself never reads it |
| RESPLNTn 49 | the 64 tiles at 16 × 16 (low resolution) |
| RESPLNTn 50 | palette: 239 RGB colors from index 17 |
| RESPLNTn 51 | material names (water, sand, grass, rock, snow, grass2, road, concrete, cliff, rock2) |
| RESPLNTn 53-57 | shading tables (16 / 8 / 16 / 8 / 5 levels × 256 colors) |
| RESTNOBJ 1343-1362 | 3D models, several per resource (see below) |
| RESTNOBJ 1160-1163 | tree, bush and rock sprites (LG bitmaps: type 2 raw, type 4 RSD run-length) |
| RESTNOBJ 1164-1193 | effect animations (explosions, fire, smoke; type 5 = translucent: 248 / 249 = light / dense smoke through the translucency tables) |
| RESTNOBJ 1196-1342 | model textures |
| RESTNOBJ 1371 / 1372 / 1373 / 1374 | object type → model or sprite for classes 0 (props), 2 (vehicles), 3 (aircraft), 4 (buildings): ref = u16 frame, u16 resource; props and buildings have 2 refs per type (props: intact, hit once — a burnt stump, picked by the state byte +6 of the decor record 0x3BA080 + 9n, a second hit removes the prop; buildings: intact, destroyed) |
| RESTNOBJ 1364 + class | per-type properties: collision shape (u16 kind, u16 index of the radius / height entry, 8-byte entries) |
| RESMAP.RES 1440 | global texture number → ref (resource, frame) |
| RESGAME / helmet files | palette colors 0-16 (fixed; a blue-grey ramp also used by planet 3's ground); the planet supplies 17-255 |
| MISSx.RES 170 / 172 / 173 / 176 / 177 | map / groups / entities (50 bytes: class, type, … x, y, z in 16.16 at 8 / 12 / 16, u16 heading at 20, s16 pitch at 22 (1/65536 turn: only MISS16 #20 and the CD demo's MISS3D #18; +24 is a third angle the game never draws); byte 0x1B = a decor object's initial state (1: hit once, its second picture; MISS13's burnt grove); z = height above the ground, 0 everywhere except the *Eagle's Nest* bridge) / zone positions / zone names |
| MISSx.RES 178 | sky file name (16 bytes), then mission parameters (copied to 0x442424 EN / 0x4424D4 FR, 0x3B bytes zeroed first: the 27-byte ones read 0 from +0x1B): +0x0E haze radius 16.16 (its s16 at +0x10 × 25558 >> 16 = the haze table's k: 99; MISS2 37, MISS7 96), +0x13 u16 temperature in kelvin (default 293, at least 174; suit and weapon heat), +0x15 gravity 16.16 (0.6 on the moon), +0x1B u16 desert flag (rippling, swaying clouds: MISS25, 26, 35, 36, DVAL, SAND), +0x1D u16 wind angle (1/65536 turn), +0x1F u32 wind speed (16.16 texels a tick), +0x23 s16 cloud ceiling height (768-1280; 0: 1024), +0x27 u8 weather (1 snow, 2 rain), +0x28 u32 its amount; +0x11, +0x12, +0x19, +0x25 have no reader |
| MISSx.RES 174 / 175 / 180 / 181 / 182 | side of each of the 32 groups (1 the player's, 2 enemy) / map annotations / version (u16 = 4, the game refuses another) / reinforcements (u32 mask, then 32 unit records: slot n appears at zone n when a script arms it) / zone shapes (128 x 10 bytes: u16 0 circle or 1 rectangle, width, height 16.16; a circle's radius is width / 2, and the game's missions leave most zones at 0.5: points to go to. A group is "in" a zone only inside its shape, 0x2C9D50). Zone 0 is where the squad is dropped, zone 31 the pickup point. The game's loader (0x2C9898) never asks for 171, 172 or 177 (the names): a mission without them loads and plays. The player's squad takes the first group number the mission leaves free. A unit record's byte +26 is its label, +7 its group (1-31): scripts name units by label, group and zone index only. Missions 18 and 28 have scripts, names and objective lines but no file: `scripts/mission_new.gd` writes one (played in game: briefing, drop, objectives, the script's end, debriefing; the player is dropped alone). Their text briefing is RESPTERM.RES 0x5AF string mission, the outfitting screen's note string mission + 48 |
| RESBABL2.RES | the missions' scripts: bytecode of a stack machine, one module per compound resource of type 12 (item 0 = name, items 1.. = functions), its debriefing texts in the string table at the next id. Module `do3d` (1005) switches on the mission number (dword 0x359708) to each mission's objectives function (its function 3), debriefing (7) and director (8). Branch targets are u16 offsets from the start of item 0; a script call is (resource id << 16) or function index; 0x7F nn nn is a source line (skipped). Objectives: three per mission, the game's functions 83 ObjInit(on1, on2, on3), 84 ObjNeedKill(label, pct1, pct2, pct3), 85 ObjNeedAlive (judged only once the mission is over), 105 ObjComplete(k), 138 ObjSetState(k, time, state: 1 done, 4 failed), 141 ObjState(k); their lines are RESGAME.RES 0x175 (string mission x 3 + k - 1), the mission names RESMISS.RES 0x6AA. The director gets events: 97 a group exists at the start (one per group), 96 a group finished its move, 99 a group spotted an enemy, 108 a labelled unit died, 109 a group was wiped out, 110 a group entered or left a zone 0-31. Orders: 113 go to zone, 120 patrol three zones, 118 / 119 attack group / label, 122 follow label, 124 hold zone (group record 0x3804F0 + g x 0x170: +0x120 = 1, +0x121 = zone, taken only when the group stands inside the zone's shape; its moves then stay in the zone), 132 link with a group (the two join one ring, +0x165 / +0x166), 134 reinforcement timer (slot, seconds). `scripts/babl.gd` reads and builds the code, `scripts/mission_script.gd` says what a mission's script does, `scripts/mission_build.gd` rebuilds one from blocks |
| SKYn.RES 152 | pictures: 0 = 256 × 256 cloud texture (absent on SKY3 / SKY4), then clouds, sun, moons, planets |
| SKYn.RES 153 | layout: u16 count, u8 base color; 0x04 cloud texture ref, 0x0C u16 star field resource, 0x14 moon ref; from 0x20 12-byte items: u16 azimuth, u16 elevation (1/65536 turn), ref (frame, 152), 4 bytes |
| SKYn.RES 150 / 151 | haze tables (16 × 256 / 8 × 256 colors); level 15 of 150 = fully hazed color |
| SKYn.RES 154 (SKY3 / SKY4) | wrapping 512 × 320 star field: 32 × 40 cells of 16 × 16 px (the last 20 rows repeat the first 20), u16 offset per cell (0 = empty), then per cell a list of small bitmaps ended by 0xFF: position (y << 4 \| x), size (w << 4 \| h), record length, w × h colors |

## Ground tile orientation

Quarter turns are stored in byte 1 bits 3:2 of each point (the game reads them at 0x2AE6AC). At load the game turns its plain tiles again (one material on all four corners, in the planet's mask: RESPLNT 52 and 72) with a generator seeded from resource 81: maps that store 0 there (DVAL, ICE, IMBR, KEEP, SAND, VALE, WILD) get their turns from it. Bit 7 of byte 0 is a light level bit (39.9 % of points), bit 6 the burned flag.

## 3D models

A model is a program for the Looking Glass 3D interpreter (the same family as System Shock's); the opcode sizes were read from the game's interpreter (jump table at 0x3605F4 in the English exe, 0x36069C in the French one). Header: name (8 bytes), bounding box and radius in 16.16, number of polygons (0x40), points (0x42), parameters (0x44), hot points (0x47, 16 bytes each from 0x5E), textures (0x49, 10 bytes each after them: byte 1 = local number, u16 at 2 = global number), size (0x4A), code start (0x4E).
Model axes: y down (objects stand on y = 0 and rise into negative y), z forward.
Useful opcodes: 03 / 15 / 16 / 21 define points, 0A-0F relative points (offset on 1 or 2 axes), 06 = BSP node (two sub-programs), 10-12 = articulated part (turret, gun), 28 / 29 = part with its own matrix, 14 = subroutine, 33 = polygon with its normal (sub-opcode 0 flat, 1 wireframe, 2 textured with u, v in 16.16), 04 = flat polygon, 26 = textured polygon, 24 / 25 / 1D = texture coordinates, 05 = color. Flat polygon color: bit 0x8000 = palette index, otherwise a color given at run time (alarm light). The stored normal, not the vertex order, decides which side is visible: mirrored parts can be wound backwards.
Sprites: the engine makes them 2 × the type's collision radius wide; the height follows the picture's proportions.

## Power suits

Soldier type → suit number: byte at 0x395BF5 (English exe) / 0x395CA5 (French) + 70 × type (SFC light / standard / heavy 0-2, Hog 3, Hog scout 4, Hog heavy 5, clones 6-8, pirate 9, captain 10, biped mech 11).
Suit s → RESTNOBJ 800 + 7 s + part (0 foot, 1 shin, 2 thigh, 3 upper arm, 4 forearm, 5 torso, 6 other forearm). Part 6 exists only for suits 6-10 (2-byte stubs for 0-5). A part: u8 number of views (16 all around; 9, back to front, for the torsos of suits 0, 2, 4, 5, 6, 7, 8), u32 at 4 = 256, u32 at 8 = length in pixels between its two joints << 8 (so u16 at 9 = the pixels), byte 12 = 1 on 9-view parts (a view v > 8 is drawn as view 16 - v flipped horizontally), view offsets (u32 from 13); each view is an LG bitmap whose bytes 16-19 give the position of the two joints in the picture.
Skeletons: 884 (most suits), 885 (suits 6, 7, 9: 7th part; the clone heavy 8 uses 884), 886 (biped mech, whose parts are the 3D models 877-883); chosen at 0x27F19A (both exes). Header: byte 0 = draw kind (2 sprite limbs, 3 3D parts), byte 1 = number of segments, byte 2 = joints (16), byte 3 = 5 (presumably the chains); bytes 4-0x13 are 0 in the file, pointers filled at run time (+8 segments, +0xC joints, +0x10 chain vectors, 12 bytes each). Each soldier record keeps its own copy at +0xEB. 16-byte segments from 0x14: joint a, joint b, chain, flags, u16 part. Chain = which reference vector picks the view, at [skeleton + 0x10] + 12 × chain (a pointer; the vectors are copied each draw from the soldier record, +0x26F + 12 × chain): 884 / 885 0 torso, 1 and 3 legs, 2 and 4 arms; 886 0 body, 1 and 3 thighs / shins, 2 and 4 feet. Flags: 0x01 = left side (view (16 - v) & 15, mirrored), 0x10 = segment hidden (set at run time only); 0x02 and 0x04 occur, meaning unknown. 16 joints: 0/1 toes, 2/3 ankles, 4/5 knees, 6/7 hips, 8 pelvis, 9 neck, 10/11 shoulders, 12/13 elbows, 14/15 hands.
In game, bone length = pixels / 256 × the soldier's own size (0x27F00C, 0x2817B0): v = 6 + (r1 + r2 + r3) / 4 with r uniform 0-15 (mean 11.25), 11 for the clones (suits 6-8), 8 for the mech; the player's squad takes v from a table by character (byte table 0x35B680, at mission start). d = v + the suit's offset - 8 (scout 4: +10, 2 and 5: +5, 3: +2, 1: -2, others 0); thigh and shin × (1 + d / 64), upper arm, forearm and torso × (1 + d / 128), feet unscaled. Stored in the record (16.16): torso +0x2AB, upper arm +0x2BB, forearm +0x2BF, thigh +0x2C3, shin +0x2C7, legs' reach +0x2ED = 0.9 × (thigh + shin). The viewer draws each suit at its mean size, legs at 0.9 (as they stand); live, the bridge sends each soldier's own lengths. The exe sets per-suit gait constants when it loads a soldier (0x2817B0, jump table 0x281780 by suit, both exes) into suit base (+0xDE) + 0x1D1 to + 0x21D. No pose is stored: the game computes the walk when drawing (0x280934, the same in both exes; the other code addresses here are the English exe's unless said: the French code moves, e.g. the limb drawer 0x2F6C50 → 0x2F6E40) and keeps the 16 joints (x, y, z in 16.16, z up) at +0x1AF of the soldier record (0x3A5608 English exe / 0x3A56B8 French + 0x582 × n, n = word at +3 of the master table entry; suit number at +0xDE). `data/soldier_poses.json` holds poses read there (joints as right, up, forward, ground at 0); the viewer uses the Hog scout's standing pose for the other suits, with their own bone lengths.
