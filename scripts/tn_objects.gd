# Terra Nova 3D objects (RESTNOBJ.RES): polygon models, their textures and the sprites used for
# trees, bushes and rocks.
#
# A model is a program for the Looking Glass 3D interpreter (the same family as System Shock's):
# header (name, bounding box, counts, texture list), then bytecode that defines points, relative
# points, BSP nodes, articulated sub-objects and polygons (flat, textured or wireframe).
# Opcode sizes were read from the game's own interpreter (jump table at 0x3605F4 in the English exe, 0x36069C French).
extends RefCounted

const LGRes = preload("res://scripts/lgres.gd")

# object class -> [RESTNOBJ table, refs per type]; each ref = u16 frame, u16 resource.
# Decor and buildings have two refs per type: decor (plants) intact, then hit once (a burnt stump, the picture its
# decor record's state byte picks: 0x29ad0a; a second hit removes it), buildings intact, destroyed.
const TABLES := {0: [1371, 2], 2: [1372, 1], 3: [1373, 1], 4: [1374, 2]}
const MODELS := Vector2i(1343, 1362)       # compound resources holding the models
const SPRITES := Vector2i(1160, 1195)      # sprite / animation bitmaps
const PROPS := 1364                        # + class: footprint and size of each object type
# Lamps: the lamp model's 7 polygons take their colour at run time (slot 2 of the byte table 0x3617F8): the game's
# routine 0x29B4D0 writes 0x4B there for an object of type 56, and for type 57 once the alarm is on (0 before: black).
# Such an object is then drawn full-bright (ambient 1, no diffuse: its palette colours as they are, shade row 16),
# whatever its class (also the research buildings 4/56 and 4/57). Nothing blinks.
const LAMP_TYPES := [56, 57]
const LAMP_COLOR := 0x4B
enum {LAMP_NONE = -1, LAMP_OFF = 0, LAMP_ON = 1}

var res                 # RESTNOBJ.RES
var tex_ref := {}       # global texture index -> Vector2i(resource, frame), from RESMAP.RES 1440
var refs := {}          # class -> Array of Vector2i(resource, frame) (intact version)
var refs2 := {}         # class -> Array of the second refs (classes 0 and 4; (0, 0): none)
var props := {}         # class -> Array of property frames (one per type)
var model_cache := {}
# live: the models shaded as the game does (model.gdshader): {"shade_idx": RESPLNT 53 as a 256 x 16 R8 texture,
# "pal_tex": the palette, 256 x 1} of the current planet ({}: Godot's own lighting, the map viewer)
var game_shade := {}
const MODEL_SHADER := preload("res://model.gdshader")
var tex_cache := {}
# How far below its entity the game draws a unit's model (0x2d45cc of the English exe, added to z by 0x29b3ac when
# the unit has a physics body): a s32 of its class's RESSIM.RES table divided by 6 (16.16). Classes 1-3 only.
const SIM_TABLES := {1: [919, 0x22], 2: [920, 0x12], 3: [921, 0x13]}
var draw_off := {}      # class -> Array of offsets (units), one per type


func setup(data_dir: String) -> bool:
	_load_draw_offsets(data_dir)
	res = LGRes.open(data_dir.path_join("RESTNOBJ.RES"))
	var m = LGRes.open(data_dir.path_join("RESMAP.RES"))
	if res == null or m == null or not m.has(1440):
		return false
	var fr := LGRes.frames(m.data(1440))
	var t: PackedByteArray = fr[0] if fr.size() > 0 else m.data(1440)
	for k in range(0, t.size() - 7, 8):
		var v := t.decode_u32(k + 4)
		tex_ref[t.decode_u32(k)] = Vector2i(v >> 16, v & 0xFFFF)
	for c in TABLES:
		var arr := []
		var arr2 := []
		var stride: int = TABLES[c][1]
		for f in LGRes.frames(res.data(TABLES[c][0])):
			var b: PackedByteArray = f
			for i in range(0, b.size() / 4, stride):
				arr.append(Vector2i(b.decode_u16(4 * i + 2), b.decode_u16(4 * i)))
				if stride == 2:
					arr2.append(Vector2i(b.decode_u16(4 * i + 6), b.decode_u16(4 * i + 4)) if 4 * i + 8 <= b.size() else Vector2i.ZERO)
		refs[c] = arr
		refs2[c] = arr2
	for c in 7:
		props[c] = LGRes.frames(res.data(PROPS + c))
	return true


func _load_draw_offsets(data_dir: String) -> void:
	draw_off = {}
	var sim = LGRes.open(data_dir.path_join("RESSIM.RES"))
	for c in SIM_TABLES:
		var arr := []
		if sim != null and sim.has(SIM_TABLES[c][0]):
			for f in LGRes.frames(sim.data(SIM_TABLES[c][0])):
				var b: PackedByteArray = f
				var at: int = SIM_TABLES[c][1]
				arr.append(float(int(b.decode_s32(at) / 6)) / 65536.0 if b.size() >= at + 4 else 0.0)
		if arr.is_empty():                              # (no file: its values)
			var n: int = {1: 18, 2: 12, 3: 17}[c]
			for t in n:
				if c == 3:
					arr.append(0.116653 if t <= 6 else 0.5 if t == 7 else 0.666656 if t <= 14 else 0.145828)
				else:
					arr.append(0.299988 if c == 1 and t == 9 else 0.145828)
		draw_off[c] = arr


# The game's draw offset of a class / type: its model's origin is drawn this far below its entity's z (0 for other
# classes, and beyond the table).
func draw_offset(cls: int, sub: int) -> float:
	var arr: Array = draw_off.get(cls, [])
	return float(arr[sub]) if sub >= 0 and sub < arr.size() else 0.0


# World width of a type's sprite (0x29AF44): twice the collision radius of its type (property frame: u16 shape kind
# 2 or 3, u16 index of the radius / height entry, then 8-byte entries); the height follows from the bitmap's
# proportions. Class 5 (shots, 0x29AE52): a fixed 1/12, already the whole width; any other shape: 1/12 too (the game
# would draw it 0 wide and log "wrong shape image"). The game then draws it with its plain focal, the world with 1.1 x
# that: see viewer.gd SPRITE_SCALE.
func sprite_width(cls: int, sub: int) -> float:
	if cls == 5:
		return 1.0 / 12.0
	var arr: Array = props.get(cls, [])
	if sub < arr.size():
		var f: PackedByteArray = arr[sub]
		if f.size() >= 4:
			var kind := f.decode_u16(0)
			var e := 4 + 8 * f.decode_u16(2)
			if (kind == 2 or kind == 3) and e + 4 <= f.size():
				return 2.0 * f.decode_s32(e) / 65536.0
	return 1.0 / 12.0


# ------------------------------------------------------------------ soldiers
# Power suits (class 1) are skeletons whose segments are drawn as limb sprites stretched between
# two joints. Suit s uses RESTNOBJ 800 + 7 s + part (0 foot, 1 shin, 2 thigh, 3 upper arm,
# 4 forearm, 5 torso, 6 other forearm); a part holds 16 views of the limb seen from all around
# (torso: 9, back to front) and every view marks where the two joints are. Skeletons: 884 (most
# suits), 885 (clones, pirates), 886 (biped mech, whose parts are 3D models).
# Soldier type -> suit: table at 0x395BF5 English exe / 0x395CA5 French (one byte every 70).
const SUIT_OF_TYPE := [0, 1, 2, 4, 3, 5, 6, 7, 8, 11, 9, 10, 5, 1, 0, 1, 2, 9]
const MECH_SUIT := 11
const MECH_PARTS := Vector2i(877, 883)     # its legs and body: 3D models


static func suit_of(sub: int) -> int:
	return SUIT_OF_TYPE[sub % SUIT_OF_TYPE.size()]


# Segments of a suit's skeleton: [joint a, joint b, part, flags]; the part's first view marker is joint a.
# Flags bit 0: the game draws the part mirrored, its view taken from the other side (the left limbs share the right
# ones' sprites; drawer 0x2F6C50). Bit 0x10: not drawn (never set in the data).
func skeleton(suit: int) -> Array:
	var rid := 886 if suit == MECH_SUIT else (885 if suit in [6, 7, 9] else 884)
	var d: PackedByteArray = res.data(rid)
	var out := []
	if d.size() < 4:
		return out
	for k in d[1]:
		var o := 0x14 + 16 * k
		if o + 6 <= d.size():
			out.append([d[o], d[o + 1], d.decode_u16(o + 4), d[o + 3], d[o + 2]])   # joint a, b, part, flags, chain
	return out


# A mech part's height in its model header (16.16, max y - min y; frame 0 of RESTNOBJ 877 + part), -1 if missing:
# the game sizes the mech's skeleton from them (0x281918).
func mech_yext(part: int) -> int:
	var fr := LGRes.frames(res.data(MECH_PARTS.x + part))
	if fr.is_empty() or (fr[0] as PackedByteArray).size() < 0x20:
		return -1
	var f: PackedByteArray = fr[0]
	return f.decode_s32(0x0C) - f.decode_s32(0x18)


# One limb: its views in a texture array, every view placed so that joint a sits at the same
# spot (x centered, y = "a1"), plus the pixel length between the two joints. {} for 3D parts.
func limb(suit: int, part: int, pal: PackedColorArray, pal_key: String) -> Dictionary:
	var key := "l%d/%d/%s" % [suit, part, pal_key]
	if tex_cache.has(key):
		return tex_cache[key]
	var out := _limb_views(suit, part, pal)
	tex_cache[key] = out
	return out


# The same views through one of the planet's IR remap tables (256 colours: TNData.ir_palettes; the suits: table 62,
# soldier draw 0x29C96E), laid out as limb()'s, or null.
func limb_ir(suit: int, part: int, pal_key: String, table: int, cols: PackedColorArray) -> Texture2DArray:
	var key := "li%d/%d/%s/%d" % [suit, part, pal_key, table]
	if tex_cache.has(key):
		return tex_cache[key]
	var tex: Texture2DArray = null
	if cols.size() == 256:
		tex = _limb_views(suit, part, cols).get("tex")
	tex_cache[key] = tex
	return tex


func _limb_views(suit: int, part: int, pal: PackedColorArray) -> Dictionary:
	var out := {}
	var fr := LGRes.frames(res.data(800 + 7 * suit + part))
	if not fr.is_empty() and fr[0].size() > 13:
		var f: PackedByteArray = fr[0]
		var n := f[0]
		var views := []
		var half_w := 0
		var top := 0
		var bottom := 0
		for v in n:
			var o := f.decode_u32(13 + 4 * v)
			if o + 0x1c > f.size() or not (f[o + 4] == 2 or f[o + 4] == 4):
				views.clear()
				break
			var img := _bitmap(f.slice(o), pal, 0x20)     # a limb view's pixels start 4 bytes past the usual header
			if img == null:
				views.clear()
				break
			var ax := f[o + 16]
			var ay := f[o + 17]
			views.append([img, ax, ay])
			half_w = maxi(half_w, maxi(ax, img.get_width() - ax))
			top = maxi(top, ay)
			bottom = maxi(bottom, img.get_height() - ay)
		if not views.is_empty():
			var w := 2 * half_w + 2
			var h := top + bottom
			var images: Array[Image] = []
			for vw in views:
				var src: Image = vw[0]
				var canvas := Image.create(w, h, false, Image.FORMAT_RGBA8)
				canvas.blit_rect(src, Rect2i(Vector2i.ZERO, src.get_size()), Vector2i(w / 2 - vw[1], top - vw[2]))
				canvas.generate_mipmaps()
				images.append(canvas)
			var arr := Texture2DArray.new()
			arr.create_from_images(images)
			out = {"tex": arr, "views": n, "size": Vector2(w, h), "a1": float(top), "len": float(f.decode_u16(9))}
	return out


# How often each palette index shows on the suits' limb sprites (all suits, parts and views; colour 0 left out):
# the weights of the shade rows' colour gains (viewer.gd _limb_light).
var limb_hist_cache := PackedFloat32Array()


func limb_histogram() -> PackedFloat32Array:
	if not limb_hist_cache.is_empty():
		return limb_hist_cache
	var hist := PackedFloat32Array()
	hist.resize(256)
	var suits := {}
	for su in SUIT_OF_TYPE:
		if su != MECH_SUIT:
			suits[su] = true
	for suit in suits:
		for part in 7:
			if not res.has(800 + 7 * suit + part):
				continue
			var fr := LGRes.frames(res.data(800 + 7 * suit + part))
			if fr.is_empty() or fr[0].size() <= 13:
				continue
			var f: PackedByteArray = fr[0]
			for v in f[0]:
				var o := f.decode_u32(13 + 4 * v)
				if o + 0x1c > f.size() or not (f[o + 4] == 2 or f[o + 4] == 4):
					break
				for c in _bitmap_idx(f.slice(o), 0x20):
					hist[c] += 1.0
	hist[0] = 0.0
	limb_hist_cache = hist
	return hist


# ------------------------------------------------------------------ effects
# Translucent animations (bitmap type 5): 248 = dense, bright veil, 249 = thinner, darker one, both drawn by the
# game through its translucency tables (BITMAP_VEILS). 1186 = rising smoke column (13 frames), effect 15 (played
# once). The "Fumee" objects (buildings type 61, whose model entry is only an editor placeholder) are not drawn: the
# game removes them right after loading them (0x2C9B20 -> 0x2894A0), after one short puff (viewer.gd FUMEE_COLUMN).
const SMOKE_ANIM := 1186
const SMOKE_TYPE := 61


# An effect animation (explosions, fire: RESTNOBJ 1162-1193), all its frames in a texture array; its frames share
# one size and one anchor (header +16 / +18: the point standing on the effect's position, near the bottom).
func anim(rid: int, pal: PackedColorArray, pal_key: String) -> Dictionary:
	var key := "a%d/%s" % [rid, pal_key]
	if tex_cache.has(key):
		return tex_cache[key]
	var out := {}
	var images: Array[Image] = []
	var size := Vector2i.ZERO
	var anchor := Vector2.ZERO
	var soft := false
	for fr in LGRes.frames(res.data(rid)):
		var f: PackedByteArray = fr
		var see_through := f.size() > 5 and f[4] == 5      # (a translucent one: smoke, the white flash)
		var img := _soft_bitmap(f, pal) if see_through else _bitmap(f, pal)
		if img == null:
			continue
		if size == Vector2i.ZERO:
			size = img.get_size()
			anchor = Vector2(f.decode_u16(16), f.decode_u16(18))
		if img.get_size() != size:
			continue
		soft = soft or see_through
		img.generate_mipmaps()
		images.append(img)
	if not images.is_empty():
		var arr := Texture2DArray.new()
		arr.create_from_images(images)
		out = {"tex": arr, "frames": images.size(), "size": Vector2(size), "anchor": anchor, "soft": soft}
	tex_cache[key] = out
	return out


# A translucent bitmap (type 5, not compressed): its pixels 248 and 249 are not colours but the game's two bitmap
# veils (tables at [0x360478] + 4 c, built at 0x261933 by 0x2F1C64): 248 = 120 + 0.469 x what is behind (colour 240 at
# opacity 1/2), 249 = 56 + 0.656 x behind (colour 224 at 1/4); as a grey laid at an opacity. Any other pixel is drawn
# as its palette colour, opaque and unlit (span routine 0x3328C2).
const BITMAP_VEILS := {248: Color(0.886, 0.886, 0.886, 0.531), 249: Color(0.639, 0.639, 0.639, 0.344)}
static func _soft_bitmap(f: PackedByteArray, pal: PackedColorArray) -> Image:
	if f.size() < 0x1c:
		return null
	var w := f.decode_u16(8)
	var h := f.decode_u16(10)
	var row := f.decode_u16(12)
	if w == 0 or h == 0 or f.size() < 0x1c + row * h:
		return null
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var v := f[0x1c + y * row + x]
			if BITMAP_VEILS.has(v):
				img.set_pixel(x, y, BITMAP_VEILS[v])
			elif v != 0:
				var c: Color = pal[v]
				img.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))
	return img


# The game's own table of effects (class 6: impacts, sparks, blasts, flames). RESTNOBJ 1195 holds one ref per type
# (0: none, the type is drawn another way: beams 28, particles 29, debris 32 / 33) into the definitions of 1194,
# 21 bytes each: +0 / +2 the bitmap's size, +4 the animation's resource (1165 to 1193), +16 its last frame, +17 a
# frame's time in milliseconds, +20 1 = played once, 2 = looping (flames). The game draws the animation as wide as
# its type's sprite (sprite_width: its collision record), whatever the bitmap's size, anchored on the entity.
const FX_TYPES := 1195
const FX_DEFS := 1194
var fx_defs := {}       # class 6 type -> {res, frames, ms, loop, width}


func fx_def(typ: int) -> Dictionary:
	if fx_defs.is_empty():
		fx_defs[-1] = {}                                    # (read once, even when the files hold none)
		var types: Array = LGRes.frames(res.data(FX_TYPES)) if res.has(FX_TYPES) else []
		var defs: Array = LGRes.frames(res.data(FX_DEFS)) if res.has(FX_DEFS) else []
		for t in types.size():
			var r: PackedByteArray = types[t]
			if r.size() < 4 or r.decode_u16(2) != FX_DEFS or r.decode_u16(0) >= defs.size():
				continue
			var d: PackedByteArray = defs[r.decode_u16(0)]
			if d.size() < 21 or not res.has(d.decode_u16(4)):
				continue
			fx_defs[t] = {"res": d.decode_u16(4), "frames": d[16] + 1, "ms": maxi(1, d[17]), "loop": d[20] == 2,
					"width": sprite_width(6, t)}
	return fx_defs.get(typ, {})


# 1186 as the texture of Uplink's own smoke puffs (viewer.gd _spawn_puff: trails, burning trees, grenades), in its
# own colours (tuned with the puffs' tint): not the game's drawing of 1186 (anim, BITMAP_VEILS).
func smoke_anim(pal: PackedColorArray, pal_key: String) -> Dictionary:
	var key := "smoke/%s" % pal_key
	if tex_cache.has(key):
		return tex_cache[key]
	var out := {}
	var images: Array[Image] = []
	var size := Vector2i.ZERO
	for fr in LGRes.frames(res.data(SMOKE_ANIM)):
		var f: PackedByteArray = fr
		if f.size() < 0x1c:
			continue
		var w := f.decode_u16(8)
		var h := f.decode_u16(10)
		var row := f.decode_u16(12)
		if size == Vector2i.ZERO:
			size = Vector2i(w, h)
		if Vector2i(w, h) != size or f.size() < 0x1c + row * h:
			continue
		var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
		for y in h:
			for x in w:
				var v := f[0x1c + y * row + x]
				if v == 248:
					img.set_pixel(x, y, Color(0.62, 0.62, 0.6, 0.4))
				elif v == 249:
					img.set_pixel(x, y, Color(0.42, 0.42, 0.4, 0.6))
				elif v != 0:
					var c: Color = pal[v]
					img.set_pixel(x, y, Color(c.r, c.g, c.b, 0.6))
		img.generate_mipmaps()
		images.append(img)
	if not images.is_empty():
		var arr := Texture2DArray.new()
		arr.create_from_images(images)
		out = {"tex": arr, "frames": images.size(), "aspect": float(size.y) / size.x}
	tex_cache[key] = out
	return out


# ------------------------------------------------------------------ skies
# SKYn.RES (named by resource 178 of the mission): 152 = images (frame 0: 256 x 256 cloud texture,
# absent on airless worlds; then clouds, sun, moons, planets), 153 = layout (u16 item count,
# u8 base color; 0x04 = cloud texture ref, 0x0C = u16 star field resource, 0x14 = moon ref;
# from 0x20 items of 12 bytes: u16 azimuth, u16 elevation (1/65536 turn), ref (frame, 152),
# 4 bytes), 150 = haze tables (16 levels x 256 colors, level 15 = fully hazed).
func load_sky(path: String, pal: PackedColorArray) -> Dictionary:
	var r = LGRes.open(path)
	if r == null or not r.has(152) or not r.has(153):
		return {}
	var f152 := LGRes.frames(r.data(152))
	var out := {"clouds": null, "items": [], "haze": Color(0.7, 0.76, 0.84), "base": Color.BLACK}
	if f152.size() > 0 and f152[0].size() > 0x1c and f152[0].decode_u16(8) == 256 and f152[0].decode_u16(10) == 256:
		var img := _bitmap(f152[0], pal)
		img.convert(Image.FORMAT_RGB8)
		var lightest := Color.BLACK                  # the horizon's colour: the clouds lighten into it
		for y in range(0, 256, 4):
			for x in range(0, 256, 4):
				var c := img.get_pixel(x, y)
				if c.get_luminance() > lightest.get_luminance():
					lightest = c
		out["light"] = lightest
		img.generate_mipmaps()
		out["clouds"] = ImageTexture.create_from_image(img)
		# the game's cloud ceiling (0x2A7222 - 0x2A7622) hazes its rows by their distance from overhead: plain up to
		# 192 texels, then the rows of resource 151 (cloud haze, 8 x 256 palette indices) 1 to 7, as layers 0-7 here
		var idx := _bitmap_idx(f152[0])
		var t151: PackedByteArray = r.data(151) if r.has(151) else PackedByteArray()
		var layers: Array[Image] = [img]
		for k in range(1, 8):
			var rgb := PackedByteArray()
			rgb.resize(256 * 256 * 3)
			for p in 256 * 256:
				var c: Color = pal[t151[k * 256 + idx[p]] if t151.size() >= 2048 else idx[p]]
				rgb[3 * p] = c.r8
				rgb[3 * p + 1] = c.g8
				rgb[3 * p + 2] = c.b8
			var li := Image.create_from_data(256, 256, false, Image.FORMAT_RGB8, rgb)
			li.generate_mipmaps()
			layers.append(li)
		var arr := Texture2DArray.new()
		arr.create_from_images(layers)
		out["cloud_levels"] = arr
		out["cloud_idx"] = idx                    # (live, infrared: the same through the planet's IR table 60)
		out["cloud_haze"] = t151
		# ... and beyond 1024 texels draws plain colours: palette 0xA2 + 3, + 2, + 1, then 0xA2 under its last rows
		# (raining: 0x20 for 0xA2, 0x2A7085)
		out["band"] = [pal[0xA5], pal[0xA4], pal[0xA3], pal[0xA2]]
		out["band_rain"] = [pal[0x23], pal[0x22], pal[0x21], pal[0x20]]
	var lay: PackedByteArray = LGRes.frames(r.data(153))[0]
	out["base"] = pal[lay[2]]
	# moon: ref at 0x14 (frame, 152); the engine draws it in the map's light direction
	out["moon"] = null
	if lay.decode_u16(0x16) == 152 and lay.decode_u16(0x14) < f152.size():
		var mimg := _bitmap(f152[lay.decode_u16(0x14)], pal)
		if mimg != null:
			var msize := Vector2(mimg.get_width(), mimg.get_height())
			mimg.generate_mipmaps()
			out["moon"] = {"tex": ImageTexture.create_from_image(mimg), "size": msize}
	var star_res := lay.decode_u16(0x0c)          # star field resource (airless skies)
	out["stars"] = _star_map(r.data(star_res), pal) if star_res != 0 and r.has(star_res) else null
	var t150: PackedByteArray = r.data(150)
	if t150.size() >= 4096:
		var acc := Vector3.ZERO
		for i in range(146, 248):                  # colors of the ground, fully hazed
			var c: Color = pal[t150[15 * 256 + i]]
			acc += Vector3(c.r, c.g, c.b)
		acc /= 102.0
		out["haze"] = Color(acc.x, acc.y, acc.z)
		out["haze_rows"] = t150.slice(0, 4096)      # (live, old school: the ground hazed through them, as the game)
	var textures := {}
	for k in range(0x20, lay.size() - 7, 12):
		if lay.decode_u16(k + 6) != 152:
			continue
		var fr := lay.decode_u16(k + 4)
		if fr >= f152.size():
			continue
		if not textures.has(fr):
			var img2 := _bitmap(f152[fr], pal)
			if img2 == null:
				continue
			var lum := 0.0
			var cnt := 0
			for y in img2.get_height():
				for x in img2.get_width():
					var c2 := img2.get_pixel(x, y)
					if c2.a > 0.5:
						lum += c2.get_luminance()
						cnt += 1
			img2.generate_mipmaps()
			textures[fr] = {"tex": ImageTexture.create_from_image(img2),
					"size": Vector2(img2.get_width(), img2.get_height()),
					"bright": lum / maxi(cnt, 1)}
		var it := {"frame": fr, "az": lay.decode_u16(k) / 65536.0 * TAU,
				"el": lay.decode_u16(k + 2) / 65536.0 * TAU}
		it.merge(textures[fr])
		out["items"].append(it)
	return out


# Star field (SKY3 / SKY4 resource 154): 32 x 40 cells of 16 x 16 pixels; u16 offset per cell
# (0 = empty), each cell a list of small bitmaps ended by 0xFF: position (y << 4 | x in the cell),
# size (w << 4 | h), record length, then w x h palette indices. The lower 20 rows repeat the upper
# ones (wrap-around), so the image kept is the 512 x 320 upper half: 360 degrees of azimuth.
static func _star_map(d: PackedByteArray, pal: PackedColorArray) -> ImageTexture:
	if d.size() < 2560:
		return null
	var img := Image.create(512, 320, false, Image.FORMAT_RGBA8)
	for c in 640:
		var off := d.decode_u16(2 * c)
		if off == 0:
			continue
		var cx := (c % 32) * 16
		var cy := (c / 32) * 16
		var p := off
		while p + 2 < d.size() and d[p] != 0xFF:
			var pos := d[p]
			var w := d[p + 1] >> 4
			var h := d[p + 1] & 15
			var ln := d[p + 2]
			if ln < 3 or w == 0:
				break
			for k in mini(ln - 3, w * h):
				var v := d[p + 3 + k]
				var x := cx + (pos & 15) + k % w
				var y := cy + (pos >> 4) + k / w
				if v != 0 and x < 512 and y < 320:
					var col: Color = pal[v]
					img.set_pixel(x, y, Color(col.r, col.g, col.b, 1.0))
			p += ln
	return ImageTexture.create_from_image(img)


# state: a decor object's (class 0) picture slot, 1 = hit once: its second ref (ZERO: the game draws nothing).
func ref_for(cls: int, sub: int, state := 0) -> Vector2i:
	if state != 0 and cls == 0:
		var arr2: Array = refs2.get(cls, [])
		return arr2[sub] if sub < arr2.size() else Vector2i.ZERO
	var arr: Array = refs.get(cls, [])
	return arr[sub] if sub < arr.size() else Vector2i.ZERO


static func is_model(ref: Vector2i) -> bool:
	return ref.x >= MODELS.x and ref.x <= MODELS.y


static func is_sprite(ref: Vector2i) -> bool:
	return ref.x >= SPRITES.x and ref.x <= SPRITES.y


# Every distinct model (copies stored twice are listed once).
func all_models() -> Array:
	var out := []
	var seen := {}
	for rid in range(MODELS.x, MODELS.y + 1):
		var fr := LGRes.frames(res.data(rid))
		for i in fr.size():
			var b: PackedByteArray = fr[i]
			var h := hash(b)
			if b.size() < 0x5e or seen.has(h):
				continue
			seen[h] = true
			out.append(Vector2i(rid, i))
	return out


func model_name(ref: Vector2i) -> String:
	var fr := LGRes.frames(res.data(ref.x))
	return LGRes.text(fr[ref.y].slice(0, 8)) if ref.y < fr.size() else ""


# {"mesh": ArrayMesh, "name": String, "height": float}, or {} when the ref is not a model.
# A model with articulated parts, built at rest (no params): "joints" (joint_bones) and its mesh carries each vertex's
# part as its bone, so a skeleton turns the parts without a new mesh (viewer.gd _live_arts).
# Mesh axes: the model's forward axis is +X (heading 0 = east), up is +Y; turn the node by
# rotation.y = -heading.
# lamp: LAMP_NONE (not a lamp object: run-time colours lit as the lamp's), LAMP_OFF (type 57 before the alarm) or
# LAMP_ON (full-bright, run-time colours = palette 0x4B), see lamp_state.
func model(ref: Vector2i, pal: PackedColorArray, pal_key: String, params := PackedByteArray(), lamp := LAMP_NONE) -> Dictionary:
	var key := "%d/%d/%s/%s/%d/%s" % [ref.x, ref.y, pal_key, params.hex_encode(), lamp, "g" if not game_shade.is_empty() else ""]
	if model_cache.has(key):
		return model_cache[key]
	var out := {}
	if is_model(ref) or (ref.x >= MECH_PARTS.x and ref.x <= MECH_PARTS.y):
		var fr := LGRes.frames(res.data(ref.x))
		if ref.y < fr.size():
			out = _build(fr[ref.y], pal, pal_key, params, lamp)
	model_cache[key] = out
	return out


# The lamp state of a model object (any class but the soldiers): type 56 always on, type 57 on once the alarm is.
static func lamp_state(cls: int, sub: int, alarm: bool) -> int:
	if cls == 1 or not sub in LAMP_TYPES:
		return LAMP_NONE
	return LAMP_ON if sub == 56 or alarm else LAMP_OFF


# Sprite as a texture + height / width ratio, or {}. Also its anchor (frame +16 / +18, signed: the pixel the game puts
# on the object's point, 0 / 0 = bottom middle) and its size in pixels.
func sprite(ref: Vector2i, pal: PackedColorArray, pal_key: String) -> Dictionary:
	var key := "s%d/%d/%s" % [ref.x, ref.y, pal_key]
	if tex_cache.has(key):
		return tex_cache[key]
	var out := {}
	var fr := LGRes.frames(res.data(ref.x))
	if is_sprite(ref) and ref.y < fr.size():
		var img := _bitmap(fr[ref.y], pal)
		if img != null:
			var aspect := float(img.get_height()) / img.get_width()
			img.generate_mipmaps()
			var f: PackedByteArray = fr[ref.y]
			out = {"texture": ImageTexture.create_from_image(img), "aspect": aspect,
					"anchor": Vector2(f.decode_s16(16), f.decode_s16(18)), "px": Vector2(img.get_width(), img.get_height())}
	tex_cache[key] = out
	return out


# A sprite's palette indices (R8, 0 = transparent), or null: the ground's burn pictures (viewer.gd _burn_pictures).
func sprite_idx(ref: Vector2i) -> Image:
	var fr := LGRes.frames(res.data(ref.x))
	if not is_sprite(ref) or ref.y >= fr.size():
		return null
	var f: PackedByteArray = fr[ref.y]
	var idx := _bitmap_idx(f)
	var w := f.decode_u16(8)
	var h := f.decode_u16(10)
	if idx.size() < w * h or w == 0 or h == 0:
		return null
	return Image.create_from_data(w, h, false, Image.FORMAT_R8, idx.slice(0, w * h))


# A sprite through each of the planet's 16 shade rows (TNData.shade_luts): layer k = file row k, as the game lights a
# plant by swapping each texel's palette index through the row at its foot. null: not a sprite.
func sprite_rows(ref: Vector2i, pal_key: String, luts: Array) -> Texture2DArray:
	var key := "sr%d/%d/%s" % [ref.x, ref.y, pal_key]
	if tex_cache.has(key):
		return tex_cache[key]
	var arr: Texture2DArray = null
	var fr := LGRes.frames(res.data(ref.x))
	if is_sprite(ref) and ref.y < fr.size() and luts.size() == 16:
		var f: PackedByteArray = fr[ref.y]
		var idx := _bitmap_idx(f)
		if not idx.is_empty():
			var w := f.decode_u16(8)
			var h := f.decode_u16(10)
			var imgs: Array[Image] = []
			for k in 16:
				var lut: PackedByteArray = luts[k]
				var rgba := PackedByteArray()
				rgba.resize(w * h * 4)
				for p in w * h:
					var c := 3 * idx[p]
					rgba[4 * p] = lut[c]
					rgba[4 * p + 1] = lut[c + 1]
					rgba[4 * p + 2] = lut[c + 2]
					rgba[4 * p + 3] = 0 if idx[p] == 0 else 255
				var img := Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba)
				img.generate_mipmaps()
				imgs.append(img)
			arr = Texture2DArray.new()
			arr.create_from_images(imgs)
	tex_cache[key] = arr
	return arr


func _texture(global_index: int, pal: PackedColorArray, pal_key: String) -> Texture2D:
	var key := "t%d/%s" % [global_index, pal_key]
	if tex_cache.has(key):
		return tex_cache[key]
	var tex: Texture2D = null
	var r: Vector2i = tex_ref.get(global_index, Vector2i.ZERO)
	if r.x != 0:
		var fr := LGRes.frames(res.data(r.x))
		if r.y < fr.size():
			var img := _bitmap(fr[r.y], pal)
			if img != null:
				# color 0 opaque, as the game draws it on its models (a tower's dark door showed the ground behind
				# it); only sprites see through it
				img.convert(Image.FORMAT_RGB8)
				img.generate_mipmaps()
				tex = ImageTexture.create_from_image(img)
	tex_cache[key] = tex
	return tex


# A sprite through one of the IR remap tables (256 colours: TNData.ir_palettes), or null.
func sprite_ir(ref: Vector2i, pal_key: String, table: int, cols: PackedColorArray) -> Texture2D:
	var key := "si%d/%d/%s/%d" % [ref.x, ref.y, pal_key, table]
	if tex_cache.has(key):
		return tex_cache[key]
	var tex: Texture2D = null
	var fr := LGRes.frames(res.data(ref.x))
	if is_sprite(ref) and ref.y < fr.size() and cols.size() == 256:
		var img := _bitmap(fr[ref.y], cols)
		if img != null:
			img.generate_mipmaps()
			tex = ImageTexture.create_from_image(img)
	tex_cache[key] = tex
	return tex


# A model texture's palette indices as an R8 texture (model.gdshader), or null.
func _texture_idx(global_index: int) -> Texture2D:
	var key := "i%d" % global_index
	if tex_cache.has(key):
		return tex_cache[key]
	var tex: Texture2D = null
	var r: Vector2i = tex_ref.get(global_index, Vector2i.ZERO)
	if r.x != 0:
		var fr := LGRes.frames(res.data(r.x))
		if r.y < fr.size():
			var f: PackedByteArray = fr[r.y]
			var idx := _bitmap_idx(f)
			if not idx.is_empty():
				tex = ImageTexture.create_from_image(Image.create_from_data(f.decode_u16(8), f.decode_u16(10), false,
						Image.FORMAT_R8, idx))
	tex_cache[key] = tex
	return tex


# LG bitmap (28-byte frame header, then pixels): type 2 = raw 8-bit, type 4 = run-length (RSD).
# Color 0 is transparent (sprites; a model's texture is made opaque, _texture).
static func _bitmap(f: PackedByteArray, pal: PackedColorArray, data_at: int = 0x1c) -> Image:
	var idx := _bitmap_idx(f, data_at)
	if idx.is_empty():
		return null
	var w := f.decode_u16(8)
	var h := f.decode_u16(10)
	var rgba := PackedByteArray()
	rgba.resize(w * h * 4)
	for p in w * h:
		var c: Color = pal[idx[p]]
		rgba[4 * p] = int(c.r8)
		rgba[4 * p + 1] = int(c.g8)
		rgba[4 * p + 2] = int(c.b8)
		rgba[4 * p + 3] = 0 if idx[p] == 0 else 255
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba)


# The bitmap's palette indices, w * h (empty: not a bitmap).
static func _bitmap_idx(f: PackedByteArray, data_at: int = 0x1c) -> PackedByteArray:
	if f.size() < data_at:
		return PackedByteArray()
	var typ := f[4]
	var w := f.decode_u16(8)
	var h := f.decode_u16(10)
	var row := f.decode_u16(12)
	if w == 0 or h == 0:
		return PackedByteArray()
	var idx := PackedByteArray()
	idx.resize(w * h)
	if typ == 2:
		for y in h:
			for x in w:
				var p := data_at + y * row + x
				idx[y * w + x] = f[p] if p < f.size() else 0
	else:
		var i := data_at
		var o := 0
		var n := w * h
		while o < n and i < f.size():
			var c := f[i]
			i += 1
			if c == 0:                          # short run
				var cnt := f[i]
				var v := f[i + 1]
				i += 2
				for k in cnt:
					if o + k < n:
						idx[o + k] = v
				o += cnt
			elif c < 0x80:                      # short literal
				for k in c:
					if o + k < n:
						idx[o + k] = f[i + k]
				i += c
				o += c
			elif c > 0x80:                      # short skip (transparent)
				o += c & 0x7F
			else:
				var wv := f.decode_u16(i)
				i += 2
				if wv == 0:
					break
				if wv & 0x8000 == 0:
					o += wv
				elif wv & 0x4000 == 0:
					var cnt2 := wv & 0x3FFF
					for k in cnt2:
						if o + k < n:
							idx[o + k] = f[i + k]
					i += cnt2
					o += cnt2
				else:
					var cnt3 := wv & 0x3FFF
					var v3 := f[i]
					i += 1
					for k in cnt3:
						if o + k < n:
							idx[o + k] = v3
					o += cnt3
	return idx


func _build(f: PackedByteArray, pal: PackedColorArray, pal_key: String, params := PackedByteArray(), lamp := LAMP_NONE) -> Dictionary:
	if f.size() < 0x5e:
		return {}
	var d := Decoder.new()
	d.f = f
	d.params = params
	var nvhots := f[0x47]
	var ntex := f[0x49]
	var code := f.decode_u32(0x4e)
	var slots := {}                              # texture slot used by polygons -> global index
	var o := 0x5e + 16 * nvhots
	for i in ntex:
		slots[f[o + 1]] = f.decode_u16(o + 2)
		o += 10
	d.run(code, Transform3D.IDENTITY, 0)
	if d.polys.is_empty():
		return {}
	d.separate()
	# parts that are rigid pieces (every model of the game's files): one bone each
	var joints := []
	if params.is_empty() and d.parts > 0 and not d.loose:
		joints = Decoder.joints_rest(d.joints)
	var bone_w := PackedFloat32Array([1.0, 0.0, 0.0, 0.0])
	var mesh := ArrayMesh.new()
	var groups := {}                             # slot (or -1 for flat colors) -> [poly]
	for p in d.polys:
		var s: int = p[2]
		if not groups.has(s):
			groups[s] = []
		groups[s].append(p)
	var top := 0.0
	# the game's shading (live), not on the lamps (full-bright or off: their own colours)
	var gs := not game_shade.is_empty() and lamp == LAMP_NONE
	for s in groups:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for p in groups[s]:
			var v: PackedVector3Array = p[0]
			var uv: PackedVector2Array = p[1]
			var ns: PackedVector3Array = p[4]
			var col := Color.WHITE
			if s < 0:
				var ci: int = p[3]
				col = pal[ci & 0xFF] if ci >= 0 else (Color.BLACK if lamp == LAMP_OFF else pal[LAMP_COLOR])
				if gs:                                   # (model.gdshader: the palette index)
					col = Color((ci & 0xFF) / 255.0, 0.0, 0.0) if ci >= 0 else Color(0.0, 0.0, 0.0)
			for k in range(1, v.size() - 1):
				for j in [0, k, k + 1]:
					if s >= 0:
						st.set_uv(uv[j])
					else:
						st.set_color(col)
					var n: Vector3 = ns[j]
					st.set_normal(Vector3(n.z, -n.y, n.x))   # the game's normals: flat faces, not averaged
					if not joints.is_empty():
						st.set_bones(PackedInt32Array([p[7], 0, 0, 0]))
						st.set_weights(bone_w)
					var q: Vector3 = v[j]
					top = maxf(top, -q.y)
					st.add_vertex(Vector3(q.z, -q.y, q.x))
		if gs:
			var sm := ShaderMaterial.new()
			sm.shader = MODEL_SHADER
			sm.set_shader_parameter("shade_idx", game_shade["shade_idx"])
			sm.set_shader_parameter("pal_tex", game_shade["pal_tex"])
			if game_shade.get("ir_lut") != null:
				sm.set_shader_parameter("ir_lut", game_shade["ir_lut"])
				sm.set_shader_parameter("has_ir", true)
			var it: Texture2D = _texture_idx(slots.get(s, 0)) if s >= 0 else null
			sm.set_shader_parameter("textured", it != null)
			if it != null:
				sm.set_shader_parameter("idx_tex", it)
			st.set_material(sm)
			st.commit(mesh)
			continue
		var mat := StandardMaterial3D.new()
		mat.roughness = 1.0
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		if lamp == LAMP_ON:                          # full-bright: its colours as they are, on every face
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
		if s < 0:
			mat.vertex_color_use_as_albedo = true
			mat.vertex_color_is_srgb = true
		else:
			var tex := _texture(slots.get(s, 0), pal, pal_key)
			if tex != null:
				mat.albedo_texture = tex
			else:
				mat.albedo_color = Color(0.6, 0.6, 0.6)
		st.set_material(mat)
		st.commit(mesh)
	if not d.lines.is_empty():                   # wireframe polygons (lattice towers)
		var sl := SurfaceTool.new()
		sl.begin(Mesh.PRIMITIVE_LINES)
		for seg in d.lines:
			var a: Vector3 = seg[0]
			var b: Vector3 = seg[1]
			if not joints.is_empty():
				sl.set_bones(PackedInt32Array([seg[3], 0, 0, 0]))
				sl.set_weights(bone_w)
			sl.set_color(pal[int(seg[2]) & 0xFF])
			sl.add_vertex(Vector3(a.z, -a.y, a.x))
			sl.set_color(pal[int(seg[2]) & 0xFF])
			sl.add_vertex(Vector3(b.z, -b.y, b.x))
		var lm := StandardMaterial3D.new()
		lm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		lm.vertex_color_use_as_albedo = true
		lm.vertex_color_is_srgb = true
		sl.set_material(lm)
		sl.commit(mesh)
	# half its length (header z extent, +0x10 max / +0x1C min): the game tilts a vehicle by the ground this far ahead
	# of and behind its origin (0x29dd64)
	var half_len := float((f.decode_s32(0x10) - f.decode_s32(0x1c)) / 2) / 65536.0
	return {"mesh": mesh, "name": LGRes.text(f.slice(0, 8)), "height": top, "params": f.decode_u16(0x44),
			"half_len": half_len, "joints": joints}


# Walks the bytecode like the game's interpreter, but draws every polygon (no back-face jumps).
# Articulated parts (turrets, gun barrels, the dropship's door) turn by the object's parameters, as
# the game copies them to its table (0x361AA8 in the English exe) before drawing: a part's angle is
# the word at its byte offset there (empty: their rest angle).
class Decoder:
	var f: PackedByteArray
	var params := PackedByteArray()
	const ART_SIGN := 1.0   # the way a part turns for a growing angle (checked on the dropship's door)
	var pts := {}           # point index -> position (model space, y down)
	var uv := {}            # point index -> Vector2
	var polys := []         # [PackedVector3Array, PackedVector2Array, texture slot or -1, color, normals, mode]
	var lines := []         # [a, b, color]
	var color := 0
	var mode := 0           # shading mode (op 0x31): 1 = one shade per polygon from its stored normal, 2 = per point
	var part := 0           # the rigid part being walked (a new one under each 0x10-0x12 / 0x28 / 0x29)
	var parts := 0
	var path := []          # the BSP nodes (op 6) above: [pc, 0 / 1 for its first / second branch]
	var vn := {}            # point index -> normal given by op 0x34 (smooth shading, mode 2)
	var joints := []        # part k's joint at k - 1: [parent part, op, its parameter's byte offset, pivot, basis] (joint_local)
	var pt_part := {}       # point index -> the part it was set under (-1: built on another part's point)
	var vn_part := {}
	var loose := false      # a polygon over points of another part than its own: the parts are not rigid pieces

	# A part in its parent's frame for the object's parameters, as run() places it (ops 0x10-0x12, 0x28, 0x29).
	static func joint_local(j: Array, pr: PackedByteArray) -> Transform3D:
		var op: int = j[1]
		var po: int = j[2]
		if op <= 0x12:
			var ang := 0.0
			if po + 2 <= pr.size():
				ang = pr.decode_u16(po) / 65536.0 * TAU
			var axis: Vector3 = [Vector3.RIGHT, Vector3.BACK, Vector3.UP][op - 0x10]
			return Transform3D(Basis(axis, ang * ART_SIGN), j[3])
		var bs: Basis = j[4]
		var at: Vector3 = j[3]
		if po + 4 <= pr.size():
			if op == 0x28:
				bs = bs * Basis(Vector3.RIGHT, pr.decode_u16(po) / 65536.0 * TAU * ART_SIGN)
			else:
				at -= bs.x * (pr.decode_s32(po) / 65536.0)
		return Transform3D(bs, at)

	# The joints with each part's place at rest, inverted (joint_bones): only when every joint is a rigid move.
	static func joints_rest(js: Array) -> Array:
		var out := []
		var rest := [Transform3D.IDENTITY]
		for j in js:
			var b: Basis = j[4]
			if not b.is_equal_approx(b.orthonormalized()) or b.determinant() < 0.0:
				return []
			var r: Transform3D = rest[j[0]] * joint_local(j, PackedByteArray())
			rest.append(r)
			out.append(j + [r.affine_inverse()])
		return out

	# For a model built at rest: each part's move (mesh axes) to the pose of the parameters; [0] is the body's (none).
	static func joint_bones(js: Array, pr: PackedByteArray) -> Array:
		var at := [Transform3D.IDENTITY]
		var out := [Transform3D.IDENTITY]
		var m := Transform3D(Basis(Vector3(0, 0, 1), Vector3(0, -1, 0), Vector3(1, 0, 0)), Vector3.ZERO)   # (its own inverse)
		for j in js:
			var t: Transform3D = at[j[0]] * joint_local(j, pr)
			at.append(t)
			out.append(m * (t * (j[5] as Transform3D)) * m)
		return out

	func v3(o: int) -> Vector3:
		return Vector3(f.decode_s32(o), f.decode_s32(o + 4), f.decode_s32(o + 8)) / 65536.0

	func fx(o: int) -> float:
		return f.decode_s32(o) / 65536.0

	func pt(i: int) -> Vector3:
		return pts.get(i, Vector3.ZERO)

	# nrm: the polygon's stored normal, when it has one. The game decides visibility with it, not
	# with the vertex order, so mirrored parts (the mech's left foot) can be wound backwards: put
	# them back in the order the rest of the data uses (clockwise seen from outside).
	# Normals as the game shades: mode 1, the stored normal for the whole polygon (one shade per face, op 0x33 at
	# 0x2F52E8); mode 2, each point's own from op 0x34. No stored normal (ops 0x04 / 0x26, unused by the models):
	# the face's own.
	func add_poly(idx: Array, uvs: PackedVector2Array, slot: int, col: int, nrm := Vector3.ZERO) -> void:
		var v := PackedVector3Array()
		for i in idx:
			v.append(pt(i))
			if pt_part.get(i, part) != part or (mode == 2 and vn_part.get(i, part) != part):
				loose = true
		if v.size() < 3:
			return
		var nw := Vector3.ZERO                     # Newell normal of the vertex order
		for k in v.size():
			var a := v[k]
			var b := v[(k + 1) % v.size()]
			nw += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
		var rev := nrm != Vector3.ZERO and nw.dot(nrm) > 0.0
		if rev:
			v.reverse()
			uvs.reverse()
		var face := nrm.normalized() if nrm != Vector3.ZERO else (-nw).normalized()
		if face == Vector3.ZERO:
			face = Vector3.UP
		var ns := PackedVector3Array()
		for i in idx:
			ns.append(vn[i] if mode == 2 and vn.has(i) else face)
		if rev:
			ns.reverse()
		polys.append([v, uvs, slot, col, ns, mode, polys.size(), part, path])

	# The game paints a model's polygons in its program's order, no depth (op 0x33 draws at once, 0x2F52E8): a decal
	# drawn after the plate under it wins, even in its plane. Here a depth buffer decides: two polygons of the same
	# part in (nearly) the same plane and overlapping fought (a stone head's face: exactly coplanar; the harvester's
	# plates, 0.0007 apart, from afar). The game's winner is pushed out along its normal to MIN_SEP in front: the later
	# one, or under a BSP node that orders them by the view, the one in front (as the game shows it from most views).
	const MIN_SEP := 0.005
	const MAX_SHIFT := 0.01
	const NEAR_PLANE := 0.003
	const MIN_OVERLAP := 0.05

	var sep_pairs := []     # [winner, loser] found by separate()
	var sep_nrm := []

	func separate(verify := false) -> Dictionary:
		if verify:                                       # (tests: the pairs found, after the shifts)
			var least := INF
			for pr in sep_pairs:
				least = minf(least, _sep(pr[0], pr[1], sep_nrm))
			return {"pairs": sep_pairs.size(), "worst": least}
		var n := polys.size()
		var nrm := []
		for p in polys:
			var v: PackedVector3Array = p[0]
			var nw := Vector3.ZERO
			for k in v.size():
				var a := v[k]
				var b := v[(k + 1) % v.size()]
				nw += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
			nrm.append((-nw).normalized())
		var pairs := []                                  # [winner, loser]
		for i in n:
			var ni: Vector3 = nrm[i]
			if ni == Vector3.ZERO:
				continue
			for j in range(i + 1, n):
				var nj: Vector3 = nrm[j]
				if polys[i][7] != polys[j][7] or ni.dot(nj) <= 0.999:
					continue
				if not _near_plane(polys[j][0], polys[i][0][0], ni) or not _near_plane(polys[i][0], polys[j][0][0], nj):
					continue
				var ov := _overlap(polys[i][0], polys[j][0], ni)
				if ov < MIN_OVERLAP:
					continue
				var w := j                                 # drawn later
				if _split(polys[i][8], polys[j][8]):        # their order follows the view: the one in front
					w = i if _mean(polys[i][0], ni) > _mean(polys[j][0], ni) else j
				pairs.append([w, i + j - w])
		pairs.sort_custom(func(a, b): return polys[a[0]][6] < polys[b[0]][6])
		sep_pairs = pairs
		sep_nrm = nrm
		var moved := {}                                  # polygon -> its total shift
		for pass_n in 4:                                 # (a chain: a winner pushed past the one above it, again)
			var changed := false
			for pr in pairs:
				var s := _sep(pr[0], pr[1], nrm)
				if s >= MIN_SEP - 1e-6:
					continue
				var shift := minf(MIN_SEP - s, MAX_SHIFT - moved.get(pr[0], 0.0))
				if shift <= 0.0:
					continue
				var v: PackedVector3Array = polys[pr[0]][0]
				for k in v.size():
					v[k] += nrm[pr[0]] * shift
				polys[pr[0]][0] = v
				moved[pr[0]] = moved.get(pr[0], 0.0) + shift
				changed = true
			if not changed:
				break
		var max_shift := 0.0
		for k in moved:
			max_shift = maxf(max_shift, moved[k])
		return {"pairs": pairs.size(), "moved": moved.size(), "max_shift": max_shift}

	static func _near_plane(v: PackedVector3Array, at: Vector3, n: Vector3) -> bool:
		for q in v:
			if absf(n.dot(q - at)) > NEAR_PLANE:
				return false
		return true

	static func _mean(v: PackedVector3Array, n: Vector3) -> float:
		var s := 0.0
		for q in v:
			s += n.dot(q)
		return s / v.size()

	# two BSP paths that part at a node (one under each branch)
	static func _split(a: Array, b: Array) -> bool:
		for x in a:
			for y in b:
				if x[0] == y[0] and x[1] != y[1]:
					return true
		return false

	# how far the winner's plane stands in front of the loser's, the least over both polygons' points
	func _sep(w: int, l: int, nrm: Array) -> float:
		var nw: Vector3 = nrm[w]
		var nl: Vector3 = nrm[l]
		var vw: PackedVector3Array = polys[w][0]
		var vl: PackedVector3Array = polys[l][0]
		var s := INF
		for q in vw:
			s = minf(s, nl.dot(q - vl[0]))
		for q in vl:
			s = minf(s, nw.dot(vw[0] - q))
		return s

	# share of the smaller polygon covered by the other, both seen along n (convex clipping)
	static func _overlap(a: PackedVector3Array, b: PackedVector3Array, n: Vector3) -> float:
		var ax := 0 if absf(n.x) >= absf(n.y) and absf(n.x) >= absf(n.z) else (1 if absf(n.y) >= absf(n.z) else 2)
		var pa := _flat(a, ax)
		var pb := _flat(b, ax)
		var area_a := absf(_area(pa))
		var area_b := absf(_area(pb))
		if area_a < 1e-10 or area_b < 1e-10:
			return 0.0
		var clip := _clip(pa, pb)
		return absf(_area(clip)) / minf(area_a, area_b)

	static func _flat(v: PackedVector3Array, drop: int) -> PackedVector2Array:
		var out := PackedVector2Array()
		for q in v:
			out.append(Vector2(q.y, q.z) if drop == 0 else (Vector2(q.x, q.z) if drop == 1 else Vector2(q.x, q.y)))
		if _area(out) < 0.0:
			out.reverse()
		return out

	static func _area(p: PackedVector2Array) -> float:
		var s := 0.0
		for k in p.size():
			s += p[k].cross(p[(k + 1) % p.size()])
		return s * 0.5

	# subject clipped by a convex counter-clockwise polygon (Sutherland-Hodgman)
	static func _clip(subject: PackedVector2Array, by: PackedVector2Array) -> PackedVector2Array:
		var out := subject
		for k in by.size():
			if out.is_empty():
				break
			var e0 := by[k]
			var e1 := by[(k + 1) % by.size()]
			var inp := out
			out = PackedVector2Array()
			for m in inp.size():
				var c := inp[m]
				var p := inp[(m + inp.size() - 1) % inp.size()]
				var c_in := (e1 - e0).cross(c - e0) >= 0.0
				var p_in := (e1 - e0).cross(p - e0) >= 0.0
				if c_in:
					if not p_in:
						out.append(_cut(p, c, e0, e1))
					out.append(c)
				elif p_in:
					out.append(_cut(p, c, e0, e1))
		return out

	static func _cut(p: Vector2, c: Vector2, e0: Vector2, e1: Vector2) -> Vector2:
		var d := c - p
		var e := e1 - e0
		var den := d.cross(e)
		if absf(den) < 1e-12:
			return c
		return p + d * ((e0 - p).cross(e) / den)

	func run(pc: int, xf: Transform3D, depth: int) -> void:
		if depth > 24:
			return
		var steps := 0
		while pc >= 0 and pc + 2 <= f.size() and steps < 200000:
			steps += 1
			var op := f.decode_u16(pc)
			match op:
				0x00:
					return
				0x01, 0x32, 0x2d:                  # normal tests / lighting: fall through
					pc += 0x1c
				0x02:
					pc += 6
				0x03:                              # n points from index start
					var n := f.decode_u16(pc + 2)
					var start := f.decode_u16(pc + 4)
					for i in n:
						pts[start + i] = xf * v3(pc + 6 + 12 * i)
						pt_part[start + i] = part
					pc += 6 + 12 * n
				0x04:                              # flat polygon, current color
					var n4 := f.decode_u16(pc + 2)
					var idx4 := []
					for i in n4:
						idx4.append(f.decode_u16(pc + 4 + 2 * i))
					add_poly(idx4, PackedVector2Array(), -1, color)
					pc += 4 + 2 * n4
				0x05:
					color = f.decode_u16(pc + 2)
					pc += 4
				0x06:                              # BSP node: both sides, then continue
					var a := f.decode_s32(pc + 0x1a)
					var b := f.decode_s32(pc + 0x1e)
					var above := path
					path = above + [[pc, 0]]
					run(pc + a, xf, depth + 1)
					path = above + [[pc, 1]]
					run(pc + b, xf, depth + 1)
					path = above
					pc += 0x22
				0x07, 0x2e, 0x2f:
					pc += 2
				0x08:
					pc += 4 + 4 * f.decode_u16(pc + 2)
				0x09, 0x19, 0x1a, 0x1e:
					pc += 4
				0x1b, 0x1f:
					color = -1
					pc += 4
				0x1c, 0x20:
					color = -1
					pc += 6
				0x0a, 0x0b, 0x0c:                  # point = other point + offset on one axis
					var d := Vector3.ZERO
					d[op - 0x0a] = fx(pc + 6)
					pts[f.decode_u16(pc + 2)] = pt(f.decode_u16(pc + 4)) + xf.basis * d
					pt_part[f.decode_u16(pc + 2)] = part if pt_part.get(f.decode_u16(pc + 4), part) == part else -1
					pc += 0xa
				0x0d, 0x0e, 0x0f:                  # ... offset on two axes (xy, xz, yz)
					var ax: Array = [[0, 1], [0, 2], [1, 2]][op - 0x0d]
					var d2 := Vector3.ZERO
					d2[ax[0]] = fx(pc + 6)
					d2[ax[1]] = fx(pc + 10)
					pts[f.decode_u16(pc + 2)] = pt(f.decode_u16(pc + 4)) + xf.basis * d2
					pt_part[f.decode_u16(pc + 2)] = part if pt_part.get(f.decode_u16(pc + 4), part) == part else -1
					pc += 0xe
				0x10, 0x11, 0x12:                  # articulated part (pitch / bank / heading)
					var target := f.decode_u32(pc + 2)
					var po := f.decode_u16(pc + 0x12)
					var ang := 0.0
					if po + 2 <= params.size():
						ang = params.decode_u16(po) / 65536.0 * TAU
					var axis: Vector3 = [Vector3.RIGHT, Vector3.BACK, Vector3.UP][op - 0x10]   # model x, z, y (y down)
					var t2 := Transform3D(xf.basis * Basis(axis, ang * ART_SIGN), xf * v3(pc + 6))
					var was := part
					parts += 1
					part = parts
					joints.append([was, op, po, v3(pc + 6), Basis.IDENTITY])
					run(target, t2, depth + 1)
					part = was
					pc += 0x14
				0x14:                              # subroutine
					run(pc + f.decode_s16(pc + 2), xf, depth + 1)
					pc += 4
				0x15:
					pts[f.decode_u16(pc + 2)] = xf * v3(pc + 4)
					pt_part[f.decode_u16(pc + 2)] = part
					pc += 0x10
				0x16:
					pts[f.decode_u16(pc + 2)] = xf * v3(pc + 4)
					pt_part[f.decode_u16(pc + 2)] = part
					pc += 0x12
				0x1d:                              # per-point texture coordinates, 8.8
					var n1d := f.decode_u16(pc + 2)
					for i in n1d:
						var e := pc + 4 + 10 * i
						uv[f.decode_u16(e)] = Vector2(f.decode_u16(e + 2), f.decode_u16(e + 4)) / 256.0
					pc += 4 + 10 * n1d
				0x21:                              # scaled points (scale = run-time parameter)
					var n21 := f.decode_u16(pc + 2)
					var s21 := f.decode_u16(pc + 6)
					for i in n21:
						pts[s21 + i] = xf * v3(pc + 8 + 12 * i)
						pt_part[s21 + i] = part
					pc += 8 + 12 * n21
				0x22, 0x23:
					pc += 6
				0x24:
					uv[f.decode_u16(pc + 2)] = Vector2(fx(pc + 4), fx(pc + 8))
					pc += 0xc
				0x25:
					var n25 := f.decode_u16(pc + 2)
					for i in n25:
						var e2 := pc + 4 + 10 * i
						uv[f.decode_u16(e2)] = Vector2(fx(e2 + 2), fx(e2 + 6))
					pc += 4 + 10 * n25
				0x26:                              # textured polygon, coordinates set before
					var slot := f.decode_u16(pc + 2)
					var n26 := f.decode_u16(pc + 4)
					var idx26 := []
					var uv26 := PackedVector2Array()
					for i in n26:
						var pn := f.decode_u16(pc + 6 + 2 * i)
						idx26.append(pn)
						uv26.append(uv.get(pn, Vector2.ZERO))
					add_poly(idx26, uv26, slot, 0)
					pc += 6 + 2 * n26
				0x27:
					pc += 8
				0x28, 0x29:                        # part with its own matrix: rest of the program
					var bs := Basis(Vector3(fx(pc + 0x10), fx(pc + 0x1c), fx(pc + 0x28)),
							Vector3(fx(pc + 0x14), fx(pc + 0x20), fx(pc + 0x2c)),
							Vector3(fx(pc + 0x18), fx(pc + 0x24), fx(pc + 0x30)))
					if bs.determinant() == 0.0:
						bs = Basis.IDENTITY
					# then turned about its x by parameter n (u16 at +2: the dword n of the table; the dropship's
					# door and ramp), or for 0x29 slid along its x by it (16.16)
					var pn := 4 * f.decode_u16(pc + 2)
					var at := xf * v3(pc + 4)
					var bs0 := bs
					if pn + 4 <= params.size():
						if op == 0x28:
							bs = bs * Basis(Vector3.RIGHT, params.decode_u16(pn) / 65536.0 * TAU * ART_SIGN)
						else:
							at -= (xf.basis * bs).x * (params.decode_s32(pn) / 65536.0)
					var was2 := part
					parts += 1
					part = parts
					joints.append([was2, op, pn, v3(pc + 4), bs0])
					run(pc + 0x34, Transform3D(xf.basis * bs, at), depth + 1)
					part = was2
					return
				0x2a, 0x2c:
					pc += 0x10
				0x2b:
					pc += 4 + 2 * f.decode_u16(pc + 2)
				0x30, 0x31:                        # shading mode, global: kept into the sub-parts (0x2F58AA)
					mode = f[pc + 2]
					pc += 3
				0x33:                              # polygon with its normal: flat / wire / textured
					var skip := f.decode_s16(pc + 2)
					var sub := f.decode_u16(pc + 0x1c)
					var n33 := f.decode_u16(pc + 0x1e)
					var idx33 := []
					for i in n33:
						idx33.append(f.decode_u16(pc + 0x20 + 2 * i))
					var last := f.decode_u16(pc + 0x20 + 2 * n33)
					var col := (last & 0xFFF) if last & 0x8000 else -1 - (last & 0xFF)   # < 0: run-time colour slot
					var nrm := xf.basis * v3(pc + 4)
					if sub == 2:
						var uv33 := PackedVector2Array()
						for k in n33:
							var e3 := pc + 0x22 + 2 * n33 + 8 * k
							uv33.append(Vector2(fx(e3), fx(e3 + 4)))
						add_poly(idx33, uv33, last, 0, nrm)
					elif sub == 1:
						for k in n33:
							lines.append([pt(idx33[k]), pt(idx33[(k + 1) % n33]), maxi(col, 0), part])
							if pt_part.get(idx33[k], part) != part:
								loose = true
					else:
						add_poly(idx33, PackedVector2Array(), -1, col, nrm)
					if skip <= 0:
						return
					pc += skip
				0x34:                              # vertex normals for shading, 0xFFFF-terminated
					pc += 2
					while pc + 2 <= f.size() and f.decode_u16(pc) != 0xFFFF:
						if pc + 0xE <= f.size():
							vn[f.decode_u16(pc)] = (xf.basis * v3(pc + 2)).normalized()
							vn_part[f.decode_u16(pc)] = part
						pc += 0x1a
					pc += 0x1a
				_:
					push_warning("TN model: unknown opcode %x at %x" % [op, pc])
					return
