# Builds terrain meshes from a height grid, in 64-cell chunks (frustum culling).
extends RefCounted

const CHUNK := 64


# grid: {"n", "h", "col"}; step: spacing in game units; origin: world position of vertex (0, 0);
# skip: cells (in grid coordinates) to leave out (the outer grid under the detailed map); only: when given, the cells
# to build (1 at the cell's first point, y * n + x: the water drawn over the ground), without shadows. skirt: a wall
# that deep hangs under the grid's outer edges (the detailed map: where it meets the coarse grid around it, every 4 of
# its points on one edge of the coarse one, the coarse edge's straight line between them left gaps a pixel wide that
# showed the sky through the ground, at the map's borders)
static func build(parent: Node3D, grid: Dictionary, step: float, origin: Vector2, skip: Rect2i,
		mat: Material, only: PackedByteArray = PackedByteArray(), skirt := 0.0) -> void:
	var n: int = grid["n"]
	var h: PackedFloat32Array = grid["h"]
	var cols: PackedColorArray = grid["col"]
	var lv: PackedByteArray = grid.get("level", PackedByteArray())
	var cy := 0
	while cy < n - 1:
		var cx := 0
		while cx < n - 1:
			var w := mini(CHUNK, n - 1 - cx)
			var hh := mini(CHUNK, n - 1 - cy)
			var idx := PackedInt32Array()
			for y in hh:
				for x in w:
					if skip.has_point(Vector2i(cx + x, cy + y)):
						continue
					if not only.is_empty() and only[(cy + y) * n + cx + x] == 0:
						continue
					var a := y * (w + 1) + x
					var c := a + w + 1
					# clockwise seen from above (Godot's front faces). The game splits its cells in a checkerboard
					# (height 0x2949C4, drawing 0x2B1814): (X + Y) even along (X, Y)-(X+1, Y+1), odd along the other
					if ((cx + x + cy + y) & 1) == 0:
						idx.append(a); idx.append(a + 1); idx.append(c + 1)
						idx.append(a); idx.append(c + 1); idx.append(c)
					else:
						idx.append(a); idx.append(a + 1); idx.append(c)
						idx.append(a + 1); idx.append(c + 1); idx.append(c)
			if idx.size() > 0:
				var count := (w + 1) * (hh + 1)
				var verts := PackedVector3Array()
				verts.resize(count)
				var norms := PackedVector3Array()
				norms.resize(count)
				var colors := PackedColorArray()
				colors.resize(count)
				var light := PackedVector2Array()        # UV2.x: the game's vertex light 15.5 - 2 level (0x2AE6AC)
				light.resize(count)
				var k := 0
				for y in range(cy, cy + hh + 1):
					for x in range(cx, cx + w + 1):
						var i := y * n + x
						var hl := h[i - 1] if x > 0 else h[i]
						var hr := h[i + 1] if x < n - 1 else h[i]
						var hu := h[i - n] if y > 0 else h[i]
						var hd := h[i + n] if y < n - 1 else h[i]
						verts[k] = Vector3(origin.x + x * step, h[i], origin.y + y * step)
						norms[k] = Vector3((hl - hr) / (2.0 * step), 1.0, (hu - hd) / (2.0 * step)).normalized()
						colors[k] = cols[i]
						light[k] = Vector2(15.5 - 2.0 * lv[i] if lv.size() == n * n else 15.5, 0.0)
						k += 1
				if skirt > 0.0:
					var edges := []                                # [vertex indices along an outer edge]
					if cx == 0:
						edges.append(range(hh + 1).map(func(yy): return yy * (w + 1)))
					if cx + w == n - 1:
						edges.append(range(hh + 1).map(func(yy): return yy * (w + 1) + w))
					if cy == 0:
						edges.append(range(w + 1))
					if cy + hh == n - 1:
						edges.append(range(w + 1).map(func(xx): return hh * (w + 1) + xx))
					for e in edges:
						var base: int = verts.size()
						for vi in e:
							verts.append(verts[vi] - Vector3(0.0, skirt, 0.0))
							norms.append(norms[vi])
							colors.append(colors[vi])
							light.append(light[vi])
						for j in e.size() - 1:
							var a0: int = e[j]
							var a1: int = e[j + 1]
							var b0: int = base + j
							var b1: int = base + j + 1
							for q in [a0, a1, b1, a0, b1, b0, a0, b1, a1, a0, b0, b1]:   # (both ways: seen from either side)
								idx.append(q)
				var arr := []
				arr.resize(Mesh.ARRAY_MAX)
				arr[Mesh.ARRAY_VERTEX] = verts
				arr[Mesh.ARRAY_NORMAL] = norms
				arr[Mesh.ARRAY_COLOR] = colors
				arr[Mesh.ARRAY_TEX_UV2] = light
				arr[Mesh.ARRAY_INDEX] = idx
				var mesh := ArrayMesh.new()
				mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
				var mi := MeshInstance3D.new()
				mi.mesh = mesh
				mi.material_override = mat
				if not only.is_empty():
					mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				parent.add_child(mi)
			cx += CHUNK
		cy += CHUNK
