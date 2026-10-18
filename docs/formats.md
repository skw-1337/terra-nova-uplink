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
| MAPx.RES 86 | 513 × 513 × 3 bytes: ground type, s16 height (÷ 384 in game units) |
| MAPx.RES 85 | 257 × 257 × 3 bytes, same format, step 4, offset 256 |
| MAPx.RES 80 | planet file name (`resplntN.res`) |
| MAPx.RES 82 | light: u16 azimuth, s16 elevation (1/65536 turn) — the engine also draws the sky's moon there; then 2 words not decoded |
| MAPx.RES 83 | vegetation map, 128 × 128 bytes stored column by column (index = x × 128 + y), 4 × 4-unit cells; value v > 0 → list 119 + v |
| MAPx.RES 84 | 30 ground type names (16 bytes) |
| MAPx.RES 120-149 | 30 vegetation lists (50-byte entries: class, type, X/Y offsets in 16.16, 0 to 4 inside the cell) |
| RESPLNTn 48 | 64 × 64 ground tiles one after the other (4096 bytes each; 64 tiles, 53 and 59 on planets 2 and 3) |
| RESPLNTn 43 | tile → material (64 entries) |
| RESPLNTn 47 | material → first tile, number of variants |
| RESPLNTn 46 | transition table: index = materialA × 50 + materialB × 5 + shape → tile |
| RESPLNTn 49 | the 64 tiles at 16 × 16 (low resolution) |
| RESPLNTn 50 | palette: 239 RGB colors from index 17 |
| RESPLNTn 51 | material names (water, sand, grass, rock, snow, grass2, road, concrete, cliff, rock2) |
| RESPLNTn 53-57 | shading tables (16 / 8 / 16 / 8 / 5 levels × 256 colors) |
| RESTNOBJ 1343-1362 | 3D models, several per resource (see below) |
| RESTNOBJ 1160-1163 | tree, bush and rock sprites (LG bitmaps: type 2 raw, type 4 RSD run-length) |
| RESTNOBJ 1164-1193 | effect animations (explosions, fire, smoke; type 5 = translucent: 248 / 249 = light / dense smoke through the translucency tables) |
| RESTNOBJ 1196-1342 | model textures |
| RESTNOBJ 1371 / 1372 / 1373 / 1374 | object type → model or sprite for classes 0 (props), 2 (vehicles), 3 (aircraft), 4 (buildings): ref = u16 frame, u16 resource; props and buildings have 2 refs per type (intact, destroyed) |
| RESTNOBJ 1364 + class | per-type properties: collision shape (u16 kind, u16 index of the radius / height entry, 8-byte entries) |
| RESMAP.RES 1440 | global texture number → ref (resource, frame) |
| RESGAME / helmet files | palette colors 0-16 (fixed; a blue-grey ramp also used by planet 3's ground); the planet supplies 17-255 |
| MISSx.RES 170 / 172 / 173 / 176 / 177 | map / groups / entities (50 bytes: class, type, … x, y, z in 16.16 at 8 / 12 / 16, u16 heading at 20; z = height above the ground, 0 everywhere except the *Eagle's Nest* bridge) / zone positions / zone names |
| MISSx.RES 178 | sky file name (16 bytes), then mission parameters (copied to 0x4424D4: +0x13 view distance, +0x15 gravity 16.16 — 0.6 on the moon —, +0x1D / +0x1F cloud wind direction and speed) |
| SKYn.RES 152 | pictures: 0 = 256 × 256 cloud texture (absent on SKY3 / SKY4), then clouds, sun, moons, planets |
| SKYn.RES 153 | layout: u16 count, u8 base color; 0x04 cloud texture ref, 0x0C u16 star field resource, 0x14 moon ref; from 0x20 12-byte items: u16 azimuth, u16 elevation (1/65536 turn), ref (frame, 152), 4 bytes |
| SKYn.RES 150 / 151 | haze tables (16 × 256 / 8 × 256 colors); level 15 of 150 = fully hazed color |
| SKYn.RES 154 (SKY3 / SKY4) | wrapping 512 × 320 star field: 32 × 40 cells of 16 × 16 px (the last 20 rows repeat the first 20), u16 offset per cell (0 = empty), then per cell a list of small bitmaps ended by 0xFF: position (y << 4 \| x), size (w << 4 \| h), record length, w × h colors |

## Ground tile orientation

Tile of a map point: `byte & 0x3F`. Bit 7 (~57 % of points) is not an orientation and bit 6 is never set: the orientation is not stored, it follows from the materials of the 8 neighbouring cells. This holds for the transition tiles of table 46, and also for the "one-sided" tiles of a single material (road edge triangles, striped pad borders, corners): their own-material part (told apart with the plainest tile of that material) faces the cells of the same material.
The viewer makes a first guess from the neighbours' materials, repeats it using the neighbours' chosen orientation until nothing changes (a diagonal road made only of transition tiles settles step by step from its ends), then polishes the transition tiles by edge color continuity.

## 3D models

A model is a program for the Looking Glass 3D interpreter (the same family as System Shock's); the opcode sizes were read from the game's interpreter (jump table at 0x36069C). Header: name (8 bytes), bounding box and radius in 16.16, number of polygons (0x40), points (0x42), parameters (0x44), hot points (0x47, 16 bytes each from 0x5E), textures (0x49, 10 bytes each after them: byte 1 = local number, u16 at 2 = global number), size (0x4A), code start (0x4E).
Model axes: y down (objects stand on y = 0 and rise into negative y), z forward.
Useful opcodes: 03 / 15 / 16 / 21 define points, 0A-0F relative points (offset on 1 or 2 axes), 06 = BSP node (two sub-programs), 10-12 = articulated part (turret, gun), 28 / 29 = part with its own matrix, 14 = subroutine, 33 = polygon with its normal (sub-opcode 0 flat, 1 wireframe, 2 textured with u, v in 16.16), 04 = flat polygon, 26 = textured polygon, 24 / 25 / 1D = texture coordinates, 05 = color. Flat polygon color: bit 0x8000 = palette index, otherwise a color given at run time (alarm light). The stored normal, not the vertex order, decides which side is visible: mirrored parts can be wound backwards.
Sprites: the engine makes them 2 × the type's collision radius wide; the height follows the picture's proportions.

## Power suits

Soldier type → suit number: byte at 0x395CA5 + 70 × type (SFC light / standard / heavy 0-2, Hog 3, Hog scout 4, Hog heavy 5, clones 6-8, pirate 9, captain 10, biped mech 11).
Suit s → RESTNOBJ 800 + 7 s + part (0 foot, 1 shin, 2 thigh, 3 upper arm, 4 forearm, 5 torso, 6 other forearm). A part: u8 number of views (16 all around, 9 from back to front for the torso), u16 length in pixels between its two joints at 9 (byte 12 is a flag), view offsets (u32 from 13); each view is an LG bitmap whose bytes 16-19 give the position of the two joints in the picture.
Skeletons: 884 (most suits), 885 (clones, pirates: 7th part), 886 (biped mech, whose parts are the 3D models 877-883); byte 1 = number of segments, 16-byte segments from 0x14: joint a, joint b, chain, flags, u16 part. 16 joints: 0/1 toes, 2/3 ankles, 4/5 knees, 6/7 hips, 8 pelvis, 9 neck, 10/11 shoulders, 12/13 elbows, 14/15 hands.
In game, bone length = pixels / 256 × the soldier's own size (random, about ±12 %). No pose is stored: the game computes the walk when drawing (0x280934) and keeps the 16 joints (x, y, z in 16.16, z up) at +0x1AF of the soldier record (0x3A56B8 + 0x582 × n, n = word at +3 of the master table entry; suit number at +0xDE). `data/soldier_poses.json` holds poses read there (joints as right, up, forward, ground at 0); the viewer uses the Hog scout's standing pose for the other suits, with their own bone lengths.
