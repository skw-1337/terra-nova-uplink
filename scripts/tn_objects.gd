# Terra Nova 3D objects (RESTNOBJ.RES): polygon models, their textures and the sprites used for
# trees, bushes and rocks.
#
# A model is a program for the Looking Glass 3D interpreter (the same family as System Shock's):
# header (name, bounding box, counts, texture list), then bytecode that defines points, relative
# points, BSP nodes, articulated sub-objects and polygons (flat, textured or wireframe).
# Opcode sizes were read from the game's own interpreter (jump table at 0x36069c in __FF.EXE).
extends RefCounted

const LGRes = preload("res://scripts/lgres.gd")

# object class -> [RESTNOBJ table, refs per type]; each ref = u16 frame, u16 resource.
# Decor and buildings have two refs per type: intact, destroyed.
const TABLES := {0: [1371, 2], 2: [1372, 1], 3: [1373, 1], 4: [1374, 2]}
const MODELS := Vector2i(1343, 1362)       # compound resources holding the models
const SPRITES := Vector2i(1160, 1195)      # sprite / animation bitmaps
const PROPS := 1364                        # + class: footprint and size of each object type
# lamp polygons take their color from the object at run time (blinking alarm light)
const RUNTIME_COLOR := Color(0.95, 0.25, 0.15)

var res                 # RESTNOBJ.RES
var tex_ref := {}       # global texture index -> Vector2i(resource, frame), from RESMAP.RES 1440
var refs := {}          # class -> Array of Vector2i(resource, frame) (intact version)
var props := {}         # class -> Array of property frames (one per type)
var model_cache := {}
var tex_cache := {}


func setup(data_dir: String) -> bool:
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
		var stride: int = TABLES[c][1]
		for f in LGRes.frames(res.data(TABLES[c][0])):
			var b: PackedByteArray = f
			for i in range(0, b.size() / 4, stride):
				arr.append(Vector2i(b.decode_u16(4 * i + 2), b.decode_u16(4 * i)))
		refs[c] = arr
	for c in 7:
		props[c] = LGRes.frames(res.data(PROPS + c))
	return true


# World width of a type's sprite. The engine scales every sprite to twice the collision radius of
# its type (property frame: u16 shape kind, u16 index of the radius / height entry, then 8-byte
# entries) and derives the height from the bitmap's proportions. Default 1/6 (probes).
func sprite_width(cls: int, sub: int) -> float:
	var arr: Array = props.get(cls, [])
	if sub < arr.size():
		var f: PackedByteArray = arr[sub]
		if f.size() >= 4:
			var kind := f.decode_u16(0)
			var e := 4 + 8 * f.decode_u16(2)
			if (kind == 2 or kind == 3) and e + 4 <= f.size():
				return f.decode_s32(e) / 65536.0         # measured against the game: its sprite is as wide as this radius
	return 1.0 / 12.0


# ------------------------------------------------------------------ soldiers
# Power suits (class 1) are skeletons whose segments are drawn as limb sprites stretched between
# two joints. Suit s uses RESTNOBJ 800 + 7 s + part (0 foot, 1 shin, 2 thigh, 3 upper arm,
# 4 forearm, 5 torso, 6 other forearm); a part holds 16 views of the limb seen from all around
# (torso: 9, back to front) and every view marks where the two joints are. Skeletons: 884 (most
# suits), 885 (clones, pirates), 886 (biped mech, whose parts are 3D models).
# Soldier type -> suit: table at 0x395CA5 in __FF.EXE (one byte every 70).
const SUIT_OF_TYPE := [0, 1, 2, 4, 3, 5, 6, 7, 8, 11, 9, 10, 5, 1, 0, 1, 2, 9]
const MECH_SUIT := 11
const MECH_PARTS := Vector2i(877, 883)     # its legs and body: 3D models


static func suit_of(sub: int) -> int:
	return SUIT_OF_TYPE[sub % SUIT_OF_TYPE.size()]


# Segments of a suit's skeleton: [joint a, joint b, part]; the part's first view marker is joint a.
func skeleton(suit: int) -> Array:
	var rid := 886 if suit == MECH_SUIT else (885 if suit in [6, 7, 9] else 884)
	var d: PackedByteArray = res.data(rid)
	var out := []
	if d.size() < 4:
		return out
	for k in d[1]:
		var o := 0x14 + 16 * k
		if o + 6 <= d.size():
			out.append([d[o], d[o + 1], d.decode_u16(o + 4)])
	return out


# One limb: its views in a texture array, every view placed so that joint a sits at the same
# spot (x centered, y = "a1"), plus the pixel length between the two joints. {} for 3D parts.
func limb(suit: int, part: int, pal: PackedColorArray, pal_key: String) -> Dictionary:
	var key := "l%d/%d/%s" % [suit, part, pal_key]
	if tex_cache.has(key):
		return tex_cache[key]
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
	tex_cache[key] = out
	return out


# ------------------------------------------------------------------ effects
# Translucent animations (bitmap type 5): 248 = thin smoke, 249 = dense smoke, both drawn by the
# game through its translucency tables. 1186 = rising smoke column (13 frames), used for the
# "Fumee" objects (buildings type 61, whose model entry is only an editor placeholder).
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
	for fr in LGRes.frames(res.data(rid)):
		var f: PackedByteArray = fr
		var img := _bitmap(f, pal)
		if img == null:
			continue
		if size == Vector2i.ZERO:
			size = img.get_size()
			anchor = Vector2(f.decode_u16(16), f.decode_u16(18))
		if img.get_size() != size:
			continue
		img.generate_mipmaps()
		images.append(img)
	if not images.is_empty():
		var arr := Texture2DArray.new()
		arr.create_from_images(images)
		out = {"tex": arr, "frames": images.size(), "size": Vector2(size), "anchor": anchor}
	tex_cache[key] = out
	return out


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


func ref_for(cls: int, sub: int) -> Vector2i:
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
# Mesh axes: the model's forward axis is +X (heading 0 = east), up is +Y; turn the node by
# rotation.y = -heading.
func model(ref: Vector2i, pal: PackedColorArray, pal_key: String, params := PackedByteArray()) -> Dictionary:
	var key := "%d/%d/%s/%s" % [ref.x, ref.y, pal_key, params.hex_encode()]
	if model_cache.has(key):
		return model_cache[key]
	var out := {}
	if is_model(ref) or (ref.x >= MECH_PARTS.x and ref.x <= MECH_PARTS.y):
		var fr := LGRes.frames(res.data(ref.x))
		if ref.y < fr.size():
			out = _build(fr[ref.y], pal, pal_key, params)
	model_cache[key] = out
	return out


# Sprite as a texture + height / width ratio, or {}.
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
			out = {"texture": ImageTexture.create_from_image(img), "aspect": aspect}
	tex_cache[key] = out
	return out


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


# LG bitmap (28-byte frame header, then pixels): type 2 = raw 8-bit, type 4 = run-length (RSD).
# Color 0 is transparent (sprites; a model's texture is made opaque, _texture).
static func _bitmap(f: PackedByteArray, pal: PackedColorArray, data_at: int = 0x1c) -> Image:
	if f.size() < data_at:
		return null
	var typ := f[4]
	var w := f.decode_u16(8)
	var h := f.decode_u16(10)
	var row := f.decode_u16(12)
	if w == 0 or h == 0:
		return null
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
	var rgba := PackedByteArray()
	rgba.resize(w * h * 4)
	for p in w * h:
		var c: Color = pal[idx[p]]
		rgba[4 * p] = int(c.r8)
		rgba[4 * p + 1] = int(c.g8)
		rgba[4 * p + 2] = int(c.b8)
		rgba[4 * p + 3] = 0 if idx[p] == 0 else 255
	return Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, rgba)


func _build(f: PackedByteArray, pal: PackedColorArray, pal_key: String, params := PackedByteArray()) -> Dictionary:
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
	var mesh := ArrayMesh.new()
	var groups := {}                             # slot (or -1 for flat colors) -> [poly]
	for p in d.polys:
		var s: int = p[2]
		if not groups.has(s):
			groups[s] = []
		groups[s].append(p)
	var top := 0.0
	for s in groups:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for p in groups[s]:
			var v: PackedVector3Array = p[0]
			var uv: PackedVector2Array = p[1]
			var col := Color.WHITE
			if s < 0:
				var ci: int = p[3]
				col = pal[ci & 0xFF] if ci >= 0 else RUNTIME_COLOR
			for k in range(1, v.size() - 1):
				for j in [0, k, k + 1]:
					if s >= 0:
						st.set_uv(uv[j])
					else:
						st.set_color(col)
					var q: Vector3 = v[j]
					top = maxf(top, -q.y)
					st.add_vertex(Vector3(q.z, -q.y, q.x))
		st.generate_normals()
		var mat := StandardMaterial3D.new()
		mat.roughness = 1.0
		mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
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
	return {"mesh": mesh, "name": LGRes.text(f.slice(0, 8)), "height": top, "params": f.decode_u16(0x44)}


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
	var polys := []         # [PackedVector3Array, PackedVector2Array, texture slot or -1, color]
	var lines := []         # [a, b, color]
	var color := 0

	func v3(o: int) -> Vector3:
		return Vector3(f.decode_s32(o), f.decode_s32(o + 4), f.decode_s32(o + 8)) / 65536.0

	func fx(o: int) -> float:
		return f.decode_s32(o) / 65536.0

	func pt(i: int) -> Vector3:
		return pts.get(i, Vector3.ZERO)

	# nrm: the polygon's stored normal, when it has one. The game decides visibility with it, not
	# with the vertex order, so mirrored parts (the mech's left foot) can be wound backwards: put
	# them back in the order the rest of the data uses (clockwise seen from outside).
	func add_poly(idx: Array, uvs: PackedVector2Array, slot: int, col: int, nrm := Vector3.ZERO) -> void:
		var v := PackedVector3Array()
		for i in idx:
			v.append(pt(i))
		if v.size() < 3:
			return
		if nrm != Vector3.ZERO:
			var nw := Vector3.ZERO                 # Newell normal of the vertex order
			for k in v.size():
				var a := v[k]
				var b := v[(k + 1) % v.size()]
				nw += Vector3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
			if nw.dot(nrm) > 0.0:
				v.reverse()
				uvs.reverse()
		polys.append([v, uvs, slot, col])

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
					run(pc + a, xf, depth + 1)
					run(pc + b, xf, depth + 1)
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
					pc += 0xa
				0x0d, 0x0e, 0x0f:                  # ... offset on two axes (xy, xz, yz)
					var ax: Array = [[0, 1], [0, 2], [1, 2]][op - 0x0d]
					var d2 := Vector3.ZERO
					d2[ax[0]] = fx(pc + 6)
					d2[ax[1]] = fx(pc + 10)
					pts[f.decode_u16(pc + 2)] = pt(f.decode_u16(pc + 4)) + xf.basis * d2
					pc += 0xe
				0x10, 0x11, 0x12:                  # articulated part (pitch / bank / heading)
					var target := f.decode_u32(pc + 2)
					var po := f.decode_u16(pc + 0x12)
					var ang := 0.0
					if po + 2 <= params.size():
						ang = params.decode_u16(po) / 65536.0 * TAU
					var axis: Vector3 = [Vector3.RIGHT, Vector3.BACK, Vector3.UP][op - 0x10]   # model x, z, y (y down)
					var t2 := Transform3D(xf.basis * Basis(axis, ang * ART_SIGN), xf * v3(pc + 6))
					run(target, t2, depth + 1)
					pc += 0x14
				0x14:                              # subroutine
					run(pc + f.decode_s16(pc + 2), xf, depth + 1)
					pc += 4
				0x15:
					pts[f.decode_u16(pc + 2)] = xf * v3(pc + 4)
					pc += 0x10
				0x16:
					pts[f.decode_u16(pc + 2)] = xf * v3(pc + 4)
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
					if pn + 4 <= params.size():
						if op == 0x28:
							bs = bs * Basis(Vector3.RIGHT, params.decode_u16(pn) / 65536.0 * TAU * ART_SIGN)
						else:
							at -= (xf.basis * bs).x * (params.decode_s32(pn) / 65536.0)
					run(pc + 0x34, Transform3D(xf.basis * bs, at), depth + 1)
					return
				0x2a, 0x2c:
					pc += 0x10
				0x2b:
					pc += 4 + 2 * f.decode_u16(pc + 2)
				0x30, 0x31:
					pc += 3
				0x33:                              # polygon with its normal: flat / wire / textured
					var skip := f.decode_s16(pc + 2)
					var sub := f.decode_u16(pc + 0x1c)
					var n33 := f.decode_u16(pc + 0x1e)
					var idx33 := []
					for i in n33:
						idx33.append(f.decode_u16(pc + 0x20 + 2 * i))
					var last := f.decode_u16(pc + 0x20 + 2 * n33)
					var col := (last & 0xFFF) if last & 0x8000 else -1
					var nrm := xf.basis * v3(pc + 4)
					if sub == 2:
						var uv33 := PackedVector2Array()
						for k in n33:
							var e3 := pc + 0x22 + 2 * n33 + 8 * k
							uv33.append(Vector2(fx(e3), fx(e3 + 4)))
						add_poly(idx33, uv33, last, 0, nrm)
					elif sub == 1:
						for k in n33:
							lines.append([pt(idx33[k]), pt(idx33[(k + 1) % n33]), maxi(col, 0)])
					else:
						add_poly(idx33, PackedVector2Array(), -1, col, nrm)
					if skip <= 0:
						return
					pc += skip
				0x34:                              # vertex normals for shading, 0xFFFF-terminated
					pc += 2
					while pc + 2 <= f.size() and f.decode_u16(pc) != 0xFFFF:
						pc += 0x1a
					pc += 0x1a
				_:
					push_warning("TN model: unknown opcode %x at %x" % [op, pc])
					return
