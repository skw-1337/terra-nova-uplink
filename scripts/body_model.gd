extends RefCounted
# The player's own suit as a solid model, for his eyes when he looks down past the game's limit (look_down.gd): its
# legs, feet and lower torso. The game's suits are flat pictures, sixteen around each limb and none from above: seen
# from the eye they fall apart. Each limb here is a solid built from its own pictures: at every row of the limb, its
# width as the front picture has it and its depth as the side picture has it (a rounded box section), and dressed in
# those pictures, each face in the picture taken from its side (front, back, right, left), in the game's palette.
# Built in the limb's picture space, as the viewer's limbs are posed (x its front, y along the bone from joint a in
# picture rows, z its right side, a picture pixel each): a child of the limb, it takes every pose of the game's
# skeleton with it.

const SHADER := preload("res://body.gdshader")
const RINGS := 14                    # sections along the limb
const SIDES := 20                    # points around a section
const ROUND := 3.2                   # the section's shape: 2 an ellipse, higher a box with rounded corners

static var meshes := {}              # (limb dictionary's id, mirrored) -> mesh
static var mats := {}                # limb dictionary's id -> material


# a picture row's opaque span, [first, last] column, or [] when it has none
static func _span(img: Image, row: int) -> Array:
	if img == null or row < 0 or row >= img.get_height():
		return []
	var lo := -1
	var hi := -1
	for x in img.get_width():
		if img.get_pixel(x, row).a > 0.5:
			if lo < 0:
				lo = x
			hi = x
	return [] if lo < 0 else [lo, hi]


static func front_layer(ld: Dictionary) -> int:
	return mini(8, int(ld["views"]) - 1)


# The limb's solid (mirrored: a left limb, drawn from the right one's pictures, its outer side the other way)
# from: where the solid begins, a share of the bone from joint a (the torso: its belly only, under the eye)
# max_w: a half width (pixels) it is held to (the torso: its picture holds the arms too; 0: none)
# top: the share of the limb's rows from its top end whose section is held to the limb's own middle size (a thigh:
# its hip pad, right under the eye, looked like a rump; 0: none)
# slim: the section's width and depth scaled by it (the thighs: their pictures' width read as padded shorts from above)
# dome: > 0 the top end rounded back over that many rows (instead of a flat end)
static func mesh(ld: Dictionary, mirror: bool, from := 0.0, max_w := 0.0, top := 0.0, slim := 1.0, dome := 0.0, taper := 0.9) -> ArrayMesh:
	var key := "%d/%s/%.2f/%.1f/%.2f/%.2f/%.1f/%.2f" % [(ld["tex"] as Object).get_instance_id(), mirror, from, max_w, top, slim, dome, taper]
	if meshes.has(key):
		return meshes[key]
	var tex: Texture2DArray = ld["tex"]
	var w := int(ld["size"].x)
	var h := int(ld["size"].y)
	var a1: float = ld["a1"]
	var img_f: Image = tex.get_layer_data(front_layer(ld))
	var img_s: Image = tex.get_layer_data(4) if int(ld["views"]) > 4 else img_f
	# the rows where the limb is (either picture opaque)
	var first := h
	var last := -1
	for r in h:
		if not _span(img_f, r).is_empty() or not _span(img_s, r).is_empty():
			first = mini(first, r)
			last = maxi(last, r)
	first = maxi(first, int(a1 + from * float(ld["len"])))
	if last < first:
		return null
	var sections := []                                   # [y, centre x, half depth, centre z, half width]
	for k in RINGS:
		var row := int(round(lerpf(first + 0.5, last - 0.5, float(k) / (RINGS - 1))))
		var f := _span(img_f, row)
		var s := _span(img_s, row)
		if f.is_empty() and s.is_empty():
			continue
		# front picture: its columns run to the limb's left (z = w / 2 - column); side picture: to its front
		var hw: float = (f[1] - f[0] + 1) * 0.5 if not f.is_empty() else (s[1] - s[0] + 1) * 0.5
		var cz: float = w * 0.5 - (f[0] + f[1] + 1) * 0.5 if not f.is_empty() else 0.0
		var hd: float = (s[1] - s[0] + 1) * 0.5 if not s.is_empty() else hw
		var cx: float = (s[0] + s[1] + 1) * 0.5 - w * 0.5 if not s.is_empty() else 0.0
		if max_w > 0.0:
			hw = minf(hw, max_w)
			hd = minf(hd, max_w * 0.8)
			cx = clampf(cx, -max_w * 0.3, max_w * 0.3)
			cz = clampf(cz, -max_w * 0.2, max_w * 0.2)
		sections.append([row - a1, cx * slim, maxf(hd * lerpf(1.0, slim, 0.6), 1.0), cz * slim, maxf(hw * slim, 1.0)])
	if sections.size() < 2:
		return null
	if top > 0.0:
		var mid: Array = sections[sections.size() / 2]
		var n_top := int(round(top * sections.size()))
		for i in n_top:
			var sc: Array = sections[i]
			var k := float(i) / maxf(n_top, 1.0)          # (from the top end down: eased back to the picture's own)
			sc[2] = lerpf(minf(sc[2], mid[2] * taper), sc[2], k * k)
			sc[4] = lerpf(minf(sc[4], mid[4] * taper), sc[4], k * k)
			sc[1] = lerpf(mid[1], sc[1], k * k)
			sc[3] = lerpf(mid[3], sc[3], k * k)
	var mz := -1.0 if mirror else 1.0
	# a domed top (the belly: its upper end curves back, away from the eye, instead of a flat lid)
	if dome > 0.0:
		var s0: Array = sections[0]
		for i in range(1, 4):
			var k := float(i) / 4.0
			sections.push_front([s0[0] - dome * k * 6.0, s0[1] - s0[2] * k * 0.6, s0[2] * sqrt(1.0 - k * k * 0.85),
					s0[3], s0[4] * sqrt(1.0 - k * k * 0.6)])
	var pts := []                                        # rings of points, and their normals (outwards)
	var nrm := []
	for sc in sections:
		var ring := []
		var rn := []
		for i in SIDES:
			var t := TAU * float(i) / SIDES
			var c := cos(t)
			var s := sin(t)
			var ex := signf(c) * pow(absf(c), 2.0 / ROUND)
			var ez := signf(s) * pow(absf(s), 2.0 / ROUND)
			ring.append(Vector3(sc[1] + sc[2] * ex, sc[0], (sc[3] + sc[4] * ez) * mz))
			rn.append(Vector3(ex / maxf(sc[2], 0.5), 0.0, ez / maxf(sc[4], 0.5) * mz).normalized())
		pts.append(ring)
		nrm.append(rn)
	# every face both ways (the material draws both sides): a closed shell, its normals set outwards here, so that no
	# winding can show the inside of a piece
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for r in pts.size() - 1:
		for i in SIDES:
			var j := (i + 1) % SIDES
			for v in [[r, i], [r, j], [r + 1, j], [r, i], [r + 1, j], [r + 1, i]]:
				st.set_normal(nrm[v[0]][v[1]])
				st.add_vertex(pts[v[0]][v[1]])
	# the ends closed, a little domed
	for e in [0, pts.size() - 1]:
		var ring: Array = pts[e]
		var mid := Vector3.ZERO
		for p in ring:
			mid += p
		mid /= ring.size()
		var other: Vector3 = Vector3.ZERO
		for p in pts[1 if e == 0 else e - 1]:
			other += p
		other /= ring.size()
		var out := (mid - other).normalized()
		var tip := mid + out * 1.5
		for i in SIDES:
			var j := (i + 1) % SIDES
			for q in [tip, ring[i], ring[j]]:
				st.set_normal(((q - mid) * 0.15 + out).normalized() if q != tip else out)
				st.add_vertex(q)
	var m := st.commit()
	meshes[key] = m
	return m


static func material(ld: Dictionary) -> ShaderMaterial:
	var key := (ld["tex"] as Object).get_instance_id()
	if mats.has(key):
		return mats[key]
	var sm := ShaderMaterial.new()
	sm.shader = SHADER
	sm.set_shader_parameter("views", ld["tex"])
	sm.set_shader_parameter("view_count", float(ld["views"]))
	sm.set_shader_parameter("size", ld["size"])
	sm.set_shader_parameter("a1", float(ld["a1"]))
	mats[key] = sm
	return sm
