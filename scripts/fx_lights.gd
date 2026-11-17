# Light from the shots (an extra on top of the game's look: off unless TN_FX_LIGHTS=1; the game's shots light
# nothing). A short flash in the weapon's colour where a shot leaves its gun, a light that flies with the energy
# bolts and the missiles, a flash where one of the game's blasts goes off. The ground takes them as real lights
# (terrain.gdshader light(): the two strongest flashes also cast the shadows of what stands around them); the suits,
# the models and the plants, which the game's shading draws unlit, take the four strongest through the shaders'
# globals (tn_haze.gdshaderinc tn_shot_light). Sizes in the game's units: a suit is 0.4 tall.
extends Node3D

# weapon (class 5 type) -> [colour, the gun's flash (0: none), the light flying with the shot (0: none)]
const WEAPON := {
	2: [Color(1.0, 0.85, 0.6), 0.5, 0.0], 3: [Color(1.0, 0.85, 0.6), 0.5, 0.0],          # grenades
	4: [Color(1.0, 0.16, 0.1), 1.0, 0.8], 5: [Color(1.0, 0.3, 0.28), 1.0, 0.8],          # laser, multipulsar
	6: [Color(1.0, 0.25, 0.15), 1.0, 0.8], 7: [Color(0.8, 0.86, 1.0), 1.0, 0.0],         # particle beam, railgun
	9: [Color(1.0, 0.5, 0.2), 1.0, 0.7], 10: [Color(1.0, 0.65, 0.3), 1.2, 1.0],          # thermal disruptor, missile
	11: [Color(0.35, 0.5, 1.0), 1.0, 0.8], 13: [Color(1.0, 0.9, 0.6), 1.3, 0.0],         # ion rifle, MB cannon
	14: [Color(1.0, 0.9, 0.6), 1.0, 0.0], 22: [Color(0.3, 1.0, 0.35), 1.0, 0.8],         # MB accelerator, plasma
	25: [Color(0.3, 1.0, 0.35), 0.8, 0.6], 23: [Color(1.0, 0.9, 0.6), 0.7, 0.0]}         # plasma spray, machine gun
const OTHER := [Color(1.0, 0.88, 0.65), 0.6, 0.0]   # the weapons not listed: a plain gun flash
const NONE := [8, 12]                                # EM emitter, SIR: no shot to see
const FLASH_S := 0.07           # the gun's flash lasts this long
const FLASH_RANGE := 2.2
const FLASH_ENERGY := 4.0
const FLY_RANGE := 1.5
const FLY_ENERGY := 1.3
const BLAST_S := 0.4            # a blast's flash: fading over this long
const BLAST_COLOUR := Color(1.0, 0.7, 0.35)
const BLAST_ENERGY := 6.0
const DAY := 0.15               # in full daylight the lights count this much (a flash hardly shows on sunlit ground:
                                # at full strength it washed the desert white): from the map's own light (its
                                # diffuse + ambient: 0.26 on the night maps, 1 by day)
const POOL := 8                 # real lights at once (the ground's); the first SHADOWS of them may cast shadows
const SHADOWS := 2
const UNLIT := 4                # lights the unlit shaders take

var v: Node                     # the viewer
var shots: Node                 # fx_shots.gd
var lights: Array[OmniLight3D] = []
var flashes := []               # [position, range, colour, energy, start (s), length (s)]
var on := false


func _ready() -> void:
	for k in POOL:
		var l := OmniLight3D.new()
		l.visible = false
		l.light_specular = 0.0
		l.omni_attenuation = 1.6
		l.shadow_enabled = k < SHADOWS
		l.omni_shadow_mode = OmniLight3D.SHADOW_CUBE
		l.shadow_bias = 0.02
		l.shadow_normal_bias = 0.5
		l.shadow_opacity = 0.8
		add_child(l)
		lights.append(l)
	shots.fired.connect(_on_fired)
	shots.blast.connect(_on_blast)


func _exit_tree() -> void:
	_globals([])


func _on_fired(_idx: int, typ: int, pos: Vector3) -> void:
	if NONE.has(typ):
		return
	var w: Array = WEAPON.get(typ, OTHER)
	if float(w[1]) <= 0.0:
		return
	var cam: Transform3D = v.camera.global_transform
	if pos.distance_to(cam.origin) < 2.5:              # the player's own gun: beside the view, a little ahead
		var rel := cam.affine_inverse() * pos
		pos = cam * Vector3(0.3 * (-1.0 if rel.x < 0.0 else 1.0), -0.08, -0.45)
	flashes.append([pos, FLASH_RANGE, w[0], FLASH_ENERGY * float(w[1]), v._ticks() / 1000.0, FLASH_S])


func _on_blast(_typ: int, pos: Vector3, width: float) -> void:
	width *= 0.5                                    # (the effect's radius: its sprite is twice its type's radius wide)
	if width < 0.45:
		return                                          # (sparks and small impacts: none)
	flashes.append([pos + Vector3(0.0, 0.3, 0.0), 2.5 + 4.5 * width, BLAST_COLOUR, BLAST_ENERGY * clampf(width, 0.5, 1.5),
			v._ticks() / 1000.0, BLAST_S])


func _process(_dt: float) -> void:
	var now: float = v._ticks() / 1000.0
	var cam: Vector3 = v.camera.global_position
	var want := []                                     # [score, position, range, colour, energy, casts shadows]
	for k in range(flashes.size() - 1, -1, -1):
		var f: Array = flashes[k]
		var t := (now - float(f[4])) / float(f[5])
		if t >= 1.0 or v.current.is_empty():
			flashes.remove_at(k)
			continue
		var e := float(f[3]) * (1.0 - t) * (1.0 - t) if float(f[5]) > 0.2 else float(f[3])
		want.append([e * float(f[1]) / (1.0 + (f[0] as Vector3).distance_to(cam)), f[0], f[1], f[2], e, true])
	if v.live and not v.current.is_empty():
		for idx in shots.shots:
			var s: Array = shots.shots[idx]
			var w: Array = WEAPON.get(s[0], OTHER)
			if float(w[2]) <= 0.0 or NONE.has(s[0]):
				continue
			var p: Vector3 = s[1]
			if p.distance_to(cam) < 0.4:
				continue                                # (still in the gun: its flash)
			var e := FLY_ENERGY * float(w[2])
			want.append([e * FLY_RANGE / (1.0 + p.distance_to(cam)), p, FLY_RANGE, w[0], e, false])
	if want.is_empty():
		if on:
			on = false
			for l in lights:
				l.visible = false
			_globals([])
		return
	on = true
	want.sort_custom(func(a, b): return a[0] > b[0])
	var dim := lerpf(1.0, DAY, smoothstep(0.35, 0.95, float(v.map_dif) + float(v.map_amb)))
	for w in want:
		w[4] = float(w[4]) * dim
	# the real lights: the shadow casters to the strongest flashes, the others to what is left
	var casters := range(SHADOWS)
	var plain := range(SHADOWS, POOL)
	for w in want:
		var slot := -1
		if bool(w[5]) and not casters.is_empty():
			slot = casters.pop_front()
		elif not plain.is_empty():
			slot = plain.pop_front()                    # (no caster left: lit without shadows; never a caster on a bolt)
		else:
			continue
		var l := lights[slot]
		l.global_position = w[1]
		l.omni_range = w[2]
		l.light_color = w[3]
		l.light_energy = w[4]
		l.visible = true
	for k in casters + plain:
		lights[k].visible = false
	_globals(want.slice(0, UNLIT))


# The same lights to the shaders that draw unlit (suits, models, plants): tn_shot_p0..3 (place, range), tn_shot_c0..3
# (colour x strength; c0's alpha: how many are on)
func _globals(want: Array) -> void:
	for k in UNLIT:
		var p := Vector4.ZERO
		var c := Vector4.ZERO
		if k < want.size():
			var w: Array = want[k]
			var col: Color = w[3]
			var e := float(w[4]) * 0.35
			p = Vector4(w[1].x, w[1].y, w[1].z, w[2])
			c = Vector4(col.r * e, col.g * e, col.b * e, 0.0)
		if k == 0:
			c.w = float(want.size())
		RenderingServer.global_shader_parameter_set("tn_shot_p%d" % k, p)
		RenderingServer.global_shader_parameter_set("tn_shot_c%d" % k, c)
