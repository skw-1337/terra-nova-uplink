# Builds terrain meshes from a height grid, in 64-cell chunks (frustum culling).
extends RefCounted

const CHUNK := 64


# grid: {"n", "h", "col"}; step: spacing in game units; origin: world position of vertex (0, 0);
# skip: cells (in grid coordinates) to leave out (the outer grid under the detailed map); only: when given, the cells
# to build (1 at the cell's first point, y * n + x: the water drawn over the ground), without shadows.
static func build(parent: Node3D, grid: Dictionary, step: float, origin: Vector2, skip: Rect2i,
		mat: Material, only: PackedByteArray = PackedByteArray()) -> void:
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
