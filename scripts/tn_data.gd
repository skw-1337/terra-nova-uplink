# Terra Nova game data: install detection, mission list, maps, planet colors.
# Everything is read straight from the player's own install (nothing is copied).
extends RefCounted

const LGRes = preload("res://scripts/lgres.gd")

const CANDIDATES := [
	"C:/Program Files (x86)/GOG Galaxy/Games/Terra Nova Strike Force Centauri",
	"C:/Program Files (x86)/Steam/steamapps/common/Terra Nova Strike Force Centauri",
	"C:/Program Files/Steam/steamapps/common/Terra Nova Strike Force Centauri",
	"C:/GOG Games/Terra Nova Strike Force Centauri",
	"D:/SteamLibrary/steamapps/common/Terra Nova Strike Force Centauri",
]
# campaign order (mission 1..37) -> MISSx.RES number
const CAMPAIGN := [37, 38, 1, 2, 3, 4, 5, 6, 7, 8, 9, 32, 33, 10, 11, 12, 13, 34, 29, 15, 17, 16, 36,
		14, 20, 39, 21, 35, 22, 23, 19, 24, 27, 25, 26, 30, 31]
const FRIENDLY := ["SFC", "Nikola", "Strike Force", "Centauri"]
const DETAIL_N := 513        # detailed grid: 513 x 513, 1 unit apart, covers 0..512
const COARSE_N := 257        # outer grid: 257 x 257, 4 units apart, covers -256..768
const HEIGHT_SCALE := 1.0 / 384.0   # measured on the running game: units stand 0.12 above it on every map
const BASE_PALETTE := [0, 0, 0, 156, 189, 189, 135, 163, 163, 103, 135, 131, 87, 119, 115, 72, 104, 96,
		63, 95, 83, 51, 83, 67, 43, 75, 59, 39, 67, 47, 31, 59, 39, 29, 55, 37, 28, 50, 35, 26, 46, 33,
		24, 41, 30, 23, 37, 28, 7, 28, 16]

var root := ""               # game folder (contains TNOVA)
var type_names := {}         # class -> PackedStringArray
var mission_names := PackedStringArray()
var planet_cache := {}


static func find_root(extra: String) -> String:
	var tries := [extra] + CANDIDATES
	for t in tries:
		if t != "" and FileAccess.file_exists(t.path_join("TNOVA/DATA/RESMISS.RES")):
			return t
	return ""


func setup(game_root: String) -> bool:
	root = game_root
	clean_tilemap_cache()
	var g = LGRes.open(data_dir().path_join("RESGAME.RES"))
	var m = LGRes.open(data_dir().path_join("RESMISS.RES"))
	if g == null or m == null:
		return false
	for c in 5:
		type_names[c] = g.strings(381 + c)
	mission_names = m.strings(1706)
	return true


func data_dir() -> String:
	return root.path_join("TNOVA/DATA")


func maps_dir() -> String:
	return root.path_join("TNOVA/MAPS")


func type_name(cls: int, sub: int) -> String:
	var names: PackedStringArray = type_names.get(cls, PackedStringArray())
	if sub < names.size() and names[sub] != "":
		return names[sub]
	return "?%d/%d" % [cls, sub]


func is_friendly(name: String) -> bool:
	for f in FRIENDLY:
		if name.contains(f):
			return true
	return false


# [{label, file, dirs}] in a sensible order: campaign, training, cut, generator, demos.
func mission_list() -> Array:
	var out := []
	var d := data_dir()
	for i in CAMPAIGN.size():
		var n: int = CAMPAIGN[i]
		out.append({"label": "%02d  %s" % [i + 1, _mname(n)], "file": d.path_join("MISS%d.RES" % n)})
	for n in [46, 47]:
		out.append({"label": "Training  %s" % _mname(n), "file": d.path_join("MISS%d.RES" % n)})
	out.append({"label": "Cut  MISS40 - %s" % _mname(40), "file": d.path_join("MISS40.RES")})
	out.append({"label": "Cut  MISS41 (prototype)", "file": d.path_join("MISS41.RES")})
	for f in DirAccess.get_files_at(d):
		var u := f.to_upper()
		if u.begins_with("MISS") and u.ends_with(".RES") and not u.substr(4, u.length() - 8).is_valid_int():
			out.append({"label": "Generator  %s" % u.substr(4, u.length() - 8), "file": d.path_join(f)})
	for demo in [["TNDEMO1/DATA/MISS1D.RES", "Demo 1  exclusive mission"],
			["TNDEMO2/MAPS/MISS2D.RES", "CD demo  mission 1"],
			["TNDEMO2/MAPS/MISS3D.RES", "CD demo  mission 2"],
			["TNDEMO2/MAPS/MISS4D.RES", "CD demo  mission 3"]]:
		var p := root.path_join(demo[0])
		if FileAccess.file_exists(p):
			out.append({"label": demo[1], "file": p})
	var kept := []
	for e in out:
		if FileAccess.file_exists(e["file"]):
			kept.append(e)
	return kept


func _mname(n: int) -> String:
	if n - 1 < mission_names.size() and mission_names[n - 1].strip_edges() != "":
		return mission_names[n - 1].strip_edges()
	return "MISS%d" % n


# Looks for a data file next to the mission, in the demo folders, then in the main game.
func resolve(mission_file: String, name: String) -> String:
	var here := mission_file.get_base_dir()
	for dir in [here, here.get_base_dir().path_join("DATA"), here.get_base_dir().path_join("MAPS"),
			maps_dir(), data_dir()]:
		var p: String = dir.path_join(name.to_upper())
		if FileAccess.file_exists(p):
			return p
	return ""


# Mission file -> {map, groups, zones, entities}
func load_mission(path: String) -> Dictionary:
	var r = LGRes.open(path)
	if r == null:
		return {}
	var groups: PackedStringArray = LGRes.names16(r.data(172))
	var zone_names: PackedStringArray = LGRes.names16(r.data(177))
	var zc: PackedByteArray = r.data(176)
	var zones := []
	for i in zone_names.size():
		if 8 * i + 8 > zc.size():
			break
		var x := zc.decode_s32(8 * i) / 65536.0
		var y := zc.decode_s32(8 * i + 4) / 65536.0
		var nm := zone_names[i]
		var label := nm.substr(nm.find(": ") + 2) if nm.contains(": ") else nm
		if label.strip_edges() != "" or x != 0.0 or y != 0.0:
			zones.append({"name": label, "x": x, "y": y})
	var ents := []
	for t in LGRes.frames(r.data(173)):
		var f: PackedByteArray = t
		if f.size() < 24:
			continue
		var g := f[7]
		ents.append({"cls": f[0], "sub": f[1], "group": groups[g] if g < groups.size() else "",
				"x": f.decode_s32(8) / 65536.0, "y": f.decode_s32(12) / 65536.0,
				"z": f.decode_s32(16) / 65536.0,     # height above the ground (only the Nid d'aigle bridge)
				"heading": f.decode_u16(20) / 65536.0 * TAU})
	var sky := LGRes.text(r.data(178).slice(0, 16)) if r.has(178) else ""
	return {"map": LGRes.text(r.data(170)), "groups": groups, "zones": zones, "entities": ents,
			"sky": sky}


# Map file -> heights, ground tiles (detail + outer grid), planet textures.
func load_map(path: String, mission_file: String) -> Dictionary:
	var r = LGRes.open(path)
	if r == null or not r.has(86):
		return {}
	var planet := "RESPLNT0.RES"
	var info: String = r.data(80).get_string_from_ascii()
	var raw80: PackedByteArray = r.data(80)
	for i in raw80.size() - 12:
		if raw80.slice(i, i + 7).get_string_from_ascii().to_lower() == "resplnt":
			planet = raw80.slice(i, i + 12).get_string_from_ascii()
			break
	var pl := load_planet(resolve(mission_file, planet))
	var detail := _grid(r.data(86), DETAIL_N, pl, path + "#86")
	var outer := _grid(r.data(85), COARSE_N, pl, path + "#85") if r.has(85) else {}
	# Vegetation, as the engine lays it out: resource 83 = 128 x 128 map (stored column by column)
	# of 4 x 4 unit cells; value v > 0 puts vegetation list v (resource 119 + v) in the cell,
	# each list item at an offset inside the cell (16.16 fixed point, 0..4).
	var veg_sets := []
	for rid in range(120, 150):
		var items := []
		for t in LGRes.frames(r.data(rid)):
			var f: PackedByteArray = t
			if f.size() >= 24:
				items.append({"cls": f[0], "sub": f[1], "ox": f.decode_s32(8) / 65536.0, "oy": f.decode_s32(12) / 65536.0})
		veg_sets.append(items)
	var veg_map: PackedByteArray = r.data(83)
	# resource 82: direction of the light (u16 azimuth, u16 elevation, 1/65536 turn), where the
	# engine also draws the sky's moon
	var light := Vector2(0.0, TAU / 8.0)
	var r82: PackedByteArray = r.data(82)
	if r82.size() >= 4:
		light = Vector2(r82.decode_u16(0) / 65536.0 * TAU, r82.decode_s16(2) / 65536.0 * TAU)
	return {"planet": planet, "planet_data": pl, "detail": detail, "outer": outer,
			"veg_map": veg_map, "veg_sets": veg_sets, "info": info, "light": light}


# Grid: heights, tile index per vertex (byte & 0x3F), fallback vertex colors, and the tile map
# (R = tile, G = quarter turns) used by the terrain shader.
func _grid(d: PackedByteArray, n: int, pl: Dictionary, key: String = "") -> Dictionary:
	var h := PackedFloat32Array()
	h.resize(n * n)
	var col := PackedColorArray()
	col.resize(n * n)
	var tiles := PackedByteArray()
	tiles.resize(n * n)
	var tile_color: PackedColorArray = pl["tile_color"]
	var count: int = pl["count"]
	for i in n * n:
		var t := d[3 * i] & 0x3F
		if t >= count:
			t = 0
		h[i] = d.decode_s16(3 * i + 1) * HEIGHT_SCALE
		tiles[i] = t
		col[i] = tile_color[t]
	var grid := {"n": n, "h": h, "col": col, "tile": tiles}
	if pl["ok"]:
		grid["tilemap"] = _tilemap(tiles, n, pl, key)
	return grid


# Transition tiles (sand/water edge, road diagonal...) and one-sided tiles of a single material
# (road edge triangle, hazard-striped pad border) are stored without orientation: like the engine,
# turn each one so that its sides match the materials of the 8 neighbouring cells.
#  1. first guess from the neighbours' materials (neighbouring transition tiles: unknown);
#  2. again with the neighbours' chosen orientations, until nothing changes (a diagonal road made
#     of transition tiles only is settled step by step from its ends);
#  3. polish the transition tiles (not the one-sided ones, whose stripes would drift inwards):
#     keep the turn whose edges best continue the neighbours' edge colors.
# The result is cached per map file in user://tilemaps.
const TILEMAP_VERSION := 5
const NB8 := [Vector2i(0, -1), Vector2i(1, -1), Vector2i(1, 0), Vector2i(1, 1), Vector2i(0, 1),
		Vector2i(-1, 1), Vector2i(-1, 0), Vector2i(-1, -1)]   # N NE E SE S SW W NW
const SIDE_DX := [0, 1, 0, -1]                                  # N E S W
const SIDE_DY := [-1, 0, 1, 0]


func _tilemap(tiles: PackedByteArray, n: int, pl: Dictionary, key: String) -> Image:
	var cache_path := ""
	if key != "":
		var src := key.get_slice("#", 0)
		var sig := "%s|%d|%d|%d" % [key, FileAccess.get_modified_time(src), TILEMAP_VERSION, n]
		cache_path = "%s/%08x.bin" % [_tilemap_dir(), sig.hash() & 0xFFFFFFFF]
		if FileAccess.file_exists(cache_path):
			var cached := FileAccess.get_file_as_bytes(cache_path)
			if cached.size() == n * n * 2:
				return Image.create_from_data(n, n, false, Image.FORMAT_RG8, cached)
	var mat: PackedByteArray = pl["mat"]
	var pair: Dictionary = pl["pair"]
	var prof: Dictionary = pl["prof"]
	var own: Dictionary = pl["own"]
	var edge: PackedFloat32Array = pl["edge"]
	var rot := PackedByteArray()
	rot.resize(n * n)
	var cells := PackedInt32Array()
	var directional := PackedByteArray()
	directional.resize(n * n)
	for i in n * n:
		if pair.has(tiles[i]) or own.has(tiles[i]):
			cells.append(i)
			directional[i] = 1
	# 1. first guess
	var first := PackedByteArray()
	first.resize(n * n)
	for i in cells:
		first[i] = _best_turn(tiles, rot, directional, n, i, mat, pair, prof, own, true)
	rot = first
	# 2. neighbours' orientations: work list of the cells whose neighbourhood changed
	var queued := PackedByteArray()
	queued.resize(n * n)
	var queue := cells.duplicate()
	for i in cells:
		queued[i] = 1
	var budget := cells.size() * 8
	var head := 0
	while head < queue.size() and budget > 0:
		var i := queue[head]
		head += 1
		budget -= 1
		queued[i] = 0
		var r := _best_turn(tiles, rot, directional, n, i, mat, pair, prof, own, false)
		if r != rot[i]:
			rot[i] = r
			var x := i % n
			var y := i / n
			for k in 8:
				var xx: int = x + NB8[k].x
				var yy: int = y + NB8[k].y
				if xx >= 0 and yy >= 0 and xx < n and yy < n:
					var j := yy * n + xx
					if directional[j] == 1 and queued[j] == 0:
						queued[j] = 1
						queue.append(j)
	# 3. edge colors
	for polish in 3:
		var changed := false
		for i in cells:
			var t := tiles[i]
			if not pair.has(t):
				continue
			var x := i % n
			var y := i / n
			var best := int(rot[i])
			var best_cost := INF
			for r in 4:
				var cost := 0.0
				for side in 4:
					var nx: int = x + SIDE_DX[side]
					var ny: int = y + SIDE_DY[side]
					if nx < 0 or ny < 0 or nx >= n or ny >= n:
						continue
					var j := ny * n + nx
					var ea := ((t * 4 + r) * 4 + side) * 24
					var eb := ((tiles[j] * 4 + rot[j]) * 4 + (side + 2) % 4) * 24
					for q in 24:
						cost += absf(edge[ea + q] - edge[eb + q])
				if cost < best_cost - 0.001:
					best_cost = cost
					best = r
			if best != rot[i]:
				rot[i] = best
				changed = true
		if not changed:
			break
	var out := PackedByteArray()
	out.resize(n * n * 2)
	for i in n * n:
		out[2 * i] = tiles[i]
		out[2 * i + 1] = rot[i]
	if cache_path != "":
		DirAccess.make_dir_recursive_absolute(_tilemap_dir())
		var fa := FileAccess.open(cache_path, FileAccess.WRITE)
		if fa != null:
			fa.store_buffer(out)
	return Image.create_from_data(n, n, false, Image.FORMAT_RG8, out)


static func _tilemap_dir() -> String:
	return "user://tilemaps/v%d" % TILEMAP_VERSION


# Removes the tile maps cached by other versions of the orientation code.
static func clean_tilemap_cache() -> void:
	var d := DirAccess.open("user://tilemaps")
	if d == null:
		return
	for f in d.get_files():
		d.remove(f)
	for sub in d.get_directories():
		if "user://tilemaps/" + sub != _tilemap_dir():
			var ds := DirAccess.open("user://tilemaps/" + sub)
			if ds != null:
				for f in ds.get_files():
					ds.remove(f)
			d.remove(sub)


# Best quarter turn of directional cell i. first: neighbouring directional tiles count as unknown;
# otherwise their chosen turn tells which material touches us.
func _best_turn(tiles: PackedByteArray, rot: PackedByteArray, directional: PackedByteArray, n: int,
		i: int, mat: PackedByteArray, pair: Dictionary, prof: Dictionary, own: Dictionary, first: bool) -> int:
	var t := tiles[i]
	var x := i % n
	var y := i / n
	var obs := PackedFloat32Array()
	obs.resize(8)
	var is_pair := pair.has(t)
	var ab: Vector2i = pair[t] if is_pair else Vector2i(own[t], -1)
	var lowest := 1.0
	for k in 8:
		var xx := clampi(x + NB8[k].x, 0, n - 1)
		var yy := clampi(y + NB8[k].y, 0, n - 1)
		var j := yy * n + xx
		var tt := tiles[j]
		if directional[j] == 1 and first:
			obs[k] = 0.5 if is_pair else (0.75 if mat[tt] == ab.x else 0.0)
		elif is_pair:
			var sa := _share(tt, rot[j], k, ab.x, mat, pair, prof, own)
			var sb := _share(tt, rot[j], k, ab.y, mat, pair, prof, own)
			obs[k] = 0.5 if sa + sb < 0.000001 else sa / (sa + sb)
		else:
			obs[k] = _share(tt, rot[j], k, ab.x, mat, pair, prof, own)
		lowest = minf(lowest, obs[k])
	if not is_pair and lowest > 0.5:
		return 0                              # inside its own material: nothing to line up with
	var best := 0
	var best_err := INF
	var rots: Array = prof[t]
	for r in 4:
		var p: PackedFloat32Array = rots[r]
		var err := 0.0
		for k in 8:
			err += absf(p[k] - obs[k])
		if err < best_err:
			best_err = err
			best = r
	return best


# Share of material m on the side of neighbour tile tt (turned r) that faces direction k from us.
static func _share(tt: int, r: int, k: int, m: int, mat: PackedByteArray, pair: Dictionary,
		prof: Dictionary, own: Dictionary) -> float:
	if pair.has(tt):
		var p: float = prof[tt][r][(k + 4) % 8]
		var ab: Vector2i = pair[tt]
		return p * float(ab.x == m) + (1.0 - p) * float(ab.y == m)
	if own.has(tt):
		var q: float = prof[tt][r][(k + 4) % 8]
		return q if own[tt] == m else 0.5 * (1.0 - q)
	return 1.0 if mat[tt] == m else 0.0


# Planet file: 64x64 ground tiles stored one after the other (resource 48; some planets have
# fewer than 64), palette (resource 50 = RGB colors from palette index 17), tile -> material
# (resource 43), material -> first tile (47), transition table (46: index = a*50 + b*5 + k).
func load_planet(path: String) -> Dictionary:
	if planet_cache.has(path):
		return planet_cache[path]
	var res := _read_planet(path)
	planet_cache[path] = res
	return res


# The 256-color game palette: colors 0-16 are fixed (the same in every palette of RESGAME and the
# helmet files), the planet supplies 17-255 (object textures use 1-145, the ground 146-247).
func full_palette(planet_pal: PackedByteArray) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(256)
	for i in 17:
		out[i] = Color8(BASE_PALETTE[3 * i], BASE_PALETTE[3 * i + 1], BASE_PALETTE[3 * i + 2])
	for i in range(17, 256):
		var k := 3 * (i - 17)
		out[i] = Color8(planet_pal[k], planet_pal[k + 1], planet_pal[k + 2]) if k + 2 < planet_pal.size() else Color.MAGENTA
	return out


func _read_planet(path: String) -> Dictionary:
	var out := {"ok": false, "count": 64, "tile_color": PackedColorArray(), "textures": null}
	var fallback := PackedColorArray()
	fallback.resize(64)
	fallback.fill(Color(0.45, 0.5, 0.35))
	out["tile_color"] = fallback
	var r = LGRes.open(path)
	if r == null or not r.has(48) or not r.has(50) or not r.has(43):
		return out
	var pal: PackedByteArray = r.data(50)
	var raw: PackedByteArray = r.data(48)
	var count := mini(64, raw.size() / 4096)
	var images: Array[Image] = []
	var tile_color := PackedColorArray()
	tile_color.resize(64)
	tile_color.fill(Color(0.45, 0.5, 0.35))
	var rgb_tiles := []
	var tile_spread := PackedFloat32Array()     # color spread of each tile (low = plain texture)
	var fp := full_palette(pal)                 # tiles also use colors 1-16 (planet 3: a lot)
	for t in count:
		var rgb := PackedByteArray()
		rgb.resize(64 * 64 * 3)
		var acc := Vector3.ZERO
		var acc2 := Vector3.ZERO
		for p in 4096:
			var fc: Color = fp[raw[t * 4096 + p]]
			var c := Vector3(fc.r8, fc.g8, fc.b8)
			rgb[3 * p] = int(c.x)
			rgb[3 * p + 1] = int(c.y)
			rgb[3 * p + 2] = int(c.z)
			acc += c
			acc2 += c * c
		acc /= 4096.0
		acc2 /= 4096.0
		var sd := acc2 - acc * acc
		tile_spread.append(sqrt(maxf(sd.x, 0.0)) + sqrt(maxf(sd.y, 0.0)) + sqrt(maxf(sd.z, 0.0)))
		acc /= 255.0
		tile_color[t] = Color(acc.x, acc.y, acc.z)
		rgb_tiles.append(rgb)
		var img := Image.create_from_data(64, 64, false, Image.FORMAT_RGB8, rgb)
		img.generate_mipmaps()
		images.append(img)
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	var mat: PackedByteArray = r.data(43)
	var first: PackedByteArray = r.data(47)
	var t46: PackedByteArray = r.data(46)
	var pair := {}
	for i in t46.size():
		if t46[i] != 255 and t46[i] < count:
			pair[t46[i]] = Vector2i(i / 50, (i / 5) % 10)
	# mean color of each material (its first tile), to tell A from B inside transition tiles
	var mat_color := {}
	for m in first.size() / 2:
		var ft := first[2 * m]
		if first[2 * m + 1] > 0 and ft < count:
			mat_color[m] = tile_color[ft]
	var prof := {}
	for t in pair.keys():                # copy of the keys: entries are erased below
		var ab: Vector2i = pair[t]
		if not mat_color.has(ab.x) or not mat_color.has(ab.y):
			pair.erase(t)
			continue
		prof[t] = _profiles(rgb_tiles[t], mat_color[ab.x], mat_color[ab.y])
	# one-sided tiles: their four border bands clearly differ. Their own-material part is told
	# apart from the rest with the plainest tile of that material (the first tile can be striped).
	var own := {}
	var plain := {}                          # material -> [spread, color]
	var one_sided := {}
	for t in count:
		if not pair.has(t) and _one_sided(rgb_tiles[t]):
			one_sided[t] = true
	for t in count:
		if pair.has(t) or one_sided.has(t):
			continue
		var m := mat[t]
		if not plain.has(m) or tile_spread[t] < plain[m][0]:
			plain[m] = [tile_spread[t], tile_color[t]]
	for t in one_sided:
		var m := mat[t]
		if plain.has(m):
			var c_own: Color = plain[m][1]
			prof[t] = _profiles(rgb_tiles[t], c_own, _far_color(rgb_tiles[t], c_own))
			own[t] = m
	out["ok"] = true
	out["palette"] = full_palette(pal)
	out["count"] = count
	out["tile_color"] = tile_color
	out["textures"] = arr
	out["mat"] = mat
	out["pair"] = pair
	out["prof"] = prof
	out["own"] = own
	out["edge"] = _edges(rgb_tiles)
	return out


# Border colors of every tile for each quarter turn: sides N, E, S, W (N / S read left to right,
# E / W top to bottom), 8 samples of 8 pixels, RGB 0-1. Index ((tile * 4 + turn) * 4 + side) * 24.
static func _edges(rgb_tiles: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(64 * 4 * 4 * 24)
	for t in rgb_tiles.size():
		var rgb: PackedByteArray = rgb_tiles[t]
		for r in 4:
			for side in 4:
				for q in 8:
					var acc := Vector3.ZERO
					for u in 8:
						var along := q * 8 + u
						var i := along if side == 1 or side == 3 else (0 if side == 0 else 63)
						var j := along if side == 0 or side == 2 else (63 if side == 1 else 0)
						var si := i                  # source pixel of the turned tile (as the shader)
						var sj := j
						if r == 1:
							si = 63 - j
							sj = i
						elif r == 2:
							si = 63 - i
							sj = 63 - j
						elif r == 3:
							si = j
							sj = 63 - i
						var p := (si * 64 + sj) * 3
						acc += Vector3(rgb[p], rgb[p + 1], rgb[p + 2])
					acc /= 8.0 * 255.0
					var o := ((t * 4 + r) * 4 + side) * 24 + q * 3
					out[o] = acc.x
					out[o + 1] = acc.y
					out[o + 2] = acc.z
	return out


# True when the mean colors of the tile's four 4-pixel border bands are far apart.
static func _one_sided(rgb: PackedByteArray) -> bool:
	var bands: Array[Vector3] = [Vector3.ZERO, Vector3.ZERO, Vector3.ZERO, Vector3.ZERO]
	for a in 64:
		for b in 4:
			var pn := (b * 64 + a) * 3                # top
			var pe := (a * 64 + 63 - b) * 3           # right
			var ps := ((63 - b) * 64 + a) * 3         # bottom
			var pw := (a * 64 + b) * 3                # left
			bands[0] += Vector3(rgb[pn], rgb[pn + 1], rgb[pn + 2])
			bands[1] += Vector3(rgb[pe], rgb[pe + 1], rgb[pe + 2])
			bands[2] += Vector3(rgb[ps], rgb[ps + 1], rgb[ps + 2])
			bands[3] += Vector3(rgb[pw], rgb[pw + 1], rgb[pw + 2])
	for i in 4:
		for j in range(i + 1, 4):
			if (bands[i] - bands[j]).length() / 256.0 > 30.0:
				return true
	return false


# Mean color of the 30 % of pixels (16x16 subsample) least like the given color.
static func _far_color(rgb: PackedByteArray, c_own: Color) -> Color:
	var o := Vector3(c_own.r, c_own.g, c_own.b)
	var d := []
	for y in 16:
		for x in 16:
			var p := (y * 4 * 64 + x * 4) * 3
			var c := Vector3(rgb[p], rgb[p + 1], rgb[p + 2]) / 255.0
			d.append([c.distance_squared_to(o), c])
	d.sort_custom(func(a, b): return a[0] > b[0])
	var acc := Vector3.ZERO
	var k := int(256 * 0.3)
	for i in k:
		acc += d[i][1]
	acc /= k
	return Color(acc.x, acc.y, acc.z)


# For a transition tile: share of material A on its 8 border regions (N NE E SE S SW W NW),
# for each of the 4 clockwise quarter turns. Works on a 16x16 subsample.
func _profiles(rgb: PackedByteArray, ca: Color, cb: Color) -> Array:
	var m := PackedFloat32Array()
	m.resize(256)
	for y in 16:
		for x in 16:
			var p := (y * 4 * 64 + x * 4) * 3
			var c := Vector3(rgb[p], rgb[p + 1], rgb[p + 2]) / 255.0
			var da := c.distance_squared_to(Vector3(ca.r, ca.g, ca.b))
			var db := c.distance_squared_to(Vector3(cb.r, cb.g, cb.b))
			m[y * 16 + x] = 1.0 if da < db else 0.0
	var out := []
	var cur := m
	for r in 4:
		out.append(_regions(cur))
		var nxt := PackedFloat32Array()
		nxt.resize(256)
		for i in 16:                     # clockwise quarter turn: new[i][j] = old[15 - j][i]
			for j in 16:
				nxt[i * 16 + j] = cur[(15 - j) * 16 + i]
		cur = nxt
	return out


static func _regions(m: PackedFloat32Array) -> PackedFloat32Array:
	# row / column ranges of the 8 regions on a 16x16 mask (3-pixel borders)
	var rr := [[0, 3, 3, 13], [0, 3, 13, 16], [3, 13, 13, 16], [13, 16, 13, 16],
			[13, 16, 3, 13], [13, 16, 0, 3], [3, 13, 0, 3], [0, 3, 0, 3]]
	var out := PackedFloat32Array()
	for q in rr:
		var s := 0.0
		var c := 0
		for y in range(q[0], q[1]):
			for x in range(q[2], q[3]):
				s += m[y * 16 + x]
				c += 1
		out.append(s / c)
	return out


# Terrain height at game coordinates (x, y), bilinear, detail grid first then outer grid.
static func height_at(m: Dictionary, x: float, y: float) -> float:
	if x >= 0 and y >= 0 and x < 512 and y < 512:
		return _bilinear(m["detail"], x, y)
	if not m["outer"].is_empty():
		return _bilinear(m["outer"], (x + 256.0) / 4.0, (y + 256.0) / 4.0)
	return 0.0


static func _bilinear(g: Dictionary, gx: float, gy: float) -> float:
	var n: int = g["n"]
	var h: PackedFloat32Array = g["h"]
	gx = clampf(gx, 0, n - 1.001)
	gy = clampf(gy, 0, n - 1.001)
	var x0 := int(gx)
	var y0 := int(gy)
	var fx := gx - x0
	var fy := gy - y0
	var a := lerpf(h[y0 * n + x0], h[y0 * n + x0 + 1], fx)
	var b := lerpf(h[(y0 + 1) * n + x0], h[(y0 + 1) * n + x0 + 1], fx)
	return lerpf(a, b, fy)
