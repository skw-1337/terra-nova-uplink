# The mission editor's spawn menu (held key, as in Garry's Mod): the unit types as pictures, by kind, with a
# search field; the tools; the group new units go to; the mission file (save, revert) and the way out of the
# build mode. The editor (mission_editor.gd) fills it and listens to its signals.
extends PanelContainer

signal spawn(index: int)
signal tool_picked(id: int)
signal group_picked(id: int)
signal save_pressed
signal revert_pressed
signal leave_pressed
signal export_file_pressed
signal copy_code_pressed
signal import_file_pressed
signal paste_code_pressed

const KIND_TABS := [[-1, "All"], [1, "Soldiers"], [2, "Vehicles"], [3, "Probes & craft"], [4, "Buildings"], [0, "Decor"]]
const KIND_COL := {1: Color(0.95, 0.45, 0.25), 2: Color(0.95, 0.75, 0.25), 3: Color(0.45, 0.75, 0.95),
	4: Color(0.65, 0.65, 0.75), 0: Color(0.45, 0.8, 0.4)}
const CELL := Vector2(150, 172)
const FOLD := {"à": "a", "â": "a", "ä": "a", "é": "e", "è": "e", "ê": "e", "ë": "e", "î": "i", "ï": "i", "ô": "o",
	"ö": "o", "ù": "u", "û": "u", "ü": "u", "ç": "c"}
const ACCENT := Color(0.3, 0.62, 0.95)
const BG := Color(0.085, 0.095, 0.115, 0.97)
const CARD := Color(0.14, 0.155, 0.18)

var catalog := []
var buttons := []                # catalog index -> its Button
var kind := -1
var search: LineEdit
var grid: GridContainer
var scroll: ScrollContainer
var count_label: Label
var tool_buttons := []
var group_opt: OptionButton
var file_label: Label
var help: Label
var placeholders := {}           # class -> Texture2D
var busy := false
var flash_t := 0                 # the last spawn's line in the top bar, until then
var flashed := -1


func _ready() -> void:
	anchor_left = 0.05
	anchor_right = 0.95
	anchor_top = 0.07
	anchor_bottom = 0.93
	add_theme_stylebox_override("panel", _box(BG, ACCENT, 2, 12, 10))
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	add_child(h)
	# kinds, on the left
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(170, 0)
	left.add_theme_constant_override("separation", 4)
	h.add_child(left)
	left.add_child(_title("SPAWN"))
	var bg := ButtonGroup.new()
	for k in KIND_TABS:
		var b := _flat(str(k[1]), 15)
		b.toggle_mode = true
		b.button_group = bg
		b.button_pressed = k[0] == -1
		b.pressed.connect(_on_kind.bind(int(k[0])))
		left.add_child(b)
	var gap := Control.new()
	gap.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(gap)
	help = Label.new()
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	help.add_theme_font_size_override("font_size", 14)
	help.add_theme_color_override("font_color", Color(0.65, 0.7, 0.75))
	left.add_child(help)
	# the pictures, in the middle
	var mid := VBoxContainer.new()
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(mid)
	var top := HBoxContainer.new()
	mid.add_child(top)
	search = LineEdit.new()
	search.placeholder_text = "Search units, vehicles, buildings..."
	search.clear_button_enabled = true
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.text_changed.connect(func(_t): _filter())
	search.text_submitted.connect(func(_t): search.release_focus())
	search.editing_toggled.connect(func(on): if not on: search.release_focus())   # (Esc: the keys are the editor's again)
	top.add_child(search)
	count_label = Label.new()
	count_label.add_theme_color_override("font_color", Color(0.65, 0.7, 0.75))
	top.add_child(count_label)
	scroll = ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.resized.connect(_columns)
	mid.add_child(scroll)
	grid = GridContainer.new()
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	scroll.add_child(grid)
	# tools, groups and the file, on the right
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(280, 0)
	right.add_theme_constant_override("separation", 6)
	h.add_child(right)
	right.add_child(_title("TOOLS"))
	var tools := VBoxContainer.new()
	tools.name = "Tools"
	right.add_child(tools)
	right.add_child(HSeparator.new())
	right.add_child(_title("NEW UNITS GO TO"))
	group_opt = OptionButton.new()
	group_opt.focus_mode = Control.FOCUS_NONE
	group_opt.fit_to_longest_item = false
	group_opt.clip_text = true
	group_opt.item_selected.connect(func(i): if not busy: group_picked.emit(int(group_opt.get_item_metadata(i))))
	right.add_child(group_opt)
	right.add_child(HSeparator.new())
	right.add_child(_title("MISSION"))
	file_label = Label.new()
	file_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	right.add_child(file_label)
	var fr := HBoxContainer.new()
	right.add_child(fr)
	var save := _flat("Save", 15)
	save.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	save.pressed.connect(func(): save_pressed.emit())
	fr.add_child(save)
	var revert := _flat("Revert", 15)
	revert.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	revert.pressed.connect(func(): revert_pressed.emit())
	fr.add_child(revert)
	right.add_child(HSeparator.new())
	right.add_child(_title("SHARE  (only your changes)"))
	var sh := GridContainer.new()
	sh.columns = 2
	right.add_child(sh)
	for it in [["Export to a file...", export_file_pressed, "Your changes to this mission as a small .tnmod file"],
			["Copy as a code", copy_code_pressed, "The same as a text code, copied: paste it in a chat or a forum"],
			["Import a file...", import_file_pressed, "Put a .tnmod creation on this mission (nothing is written until you save)"],
			["Paste a code", paste_code_pressed, "Put the creation whose code you copied on this mission (nothing is written until you save)"]]:
		var b := _flat(str(it[0]), 14)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = str(it[2])
		var sig: Signal = it[1]
		b.pressed.connect(func(): sig.emit())
		sh.add_child(b)
	var gap2 := Control.new()
	gap2.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_child(gap2)
	var leave := _flat("Leave build mode", 15)
	leave.pressed.connect(func(): leave_pressed.emit())
	right.add_child(leave)


# ---- filling
# [[name, what it does, key]]
func set_tools(list: Array, current: int) -> void:
	var box: VBoxContainer = find_child("Tools", true, false)
	for c in box.get_children():
		c.queue_free()
	tool_buttons.clear()
	var tg := ButtonGroup.new()
	for i in list.size():
		var b := _flat("%s   %s\n%s" % [list[i][2], list[i][0], list[i][1]], 14)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		b.custom_minimum_size = Vector2(270, 50)
		b.toggle_mode = true
		b.button_group = tg
		b.button_pressed = i == current
		b.pressed.connect(func(): tool_picked.emit(i))
		box.add_child(b)
		tool_buttons.append(b)


func set_tool(current: int) -> void:
	for i in tool_buttons.size():
		tool_buttons[i].set_pressed_no_signal(i == current)


# [[group, text]] (group -1: automatic), the first one selected unless `current` is one of them. The group is the
# item's metadata: an item id of -1 would be taken as "use the index", the same as group 0's
func set_groups(items: Array, current: int) -> void:
	busy = true
	group_opt.clear()
	var k := 0
	for it in items:
		group_opt.add_item(str(it[1]))
		group_opt.set_item_metadata(group_opt.item_count - 1, int(it[0]))
		if int(it[0]) == current:
			k = group_opt.item_count - 1
	group_opt.select(k)
	busy = false


func set_file(file_name: String, dirty: bool) -> void:
	file_label.text = file_name +("\n● unsaved changes" if dirty else "\nsaved")
	file_label.add_theme_color_override("font_color", Color(1.0, 0.75, 0.3) if dirty else Color(0.6, 0.85, 0.6))


func set_help(t: String) -> void:
	help.text = t


# [{cls, sub, name, kind}]
func set_catalog(c: Array) -> void:
	catalog = c
	for b in buttons:
		b.queue_free()
	buttons.clear()
	var names := {}                                  # a name two types share: the kind, then the type number, added
	var named := {}
	for it in catalog:
		names[it["name"]] = names.get(it["name"], 0) + 1
		var nk: String = "%s|%s" % [it["name"], it["kind"]]
		named[nk] = named.get(nk, 0) + 1
	for i in catalog.size():
		var it: Dictionary = catalog[i]
		var b := Button.new()
		b.custom_minimum_size = CELL
		b.focus_mode = Control.FOCUS_NONE
		b.text = str(it["name"])
		if named["%s|%s" % [it["name"], it["kind"]]] > 1:
			b.text = "%s (%s %d)" % [it["name"], str(it["kind"]).to_lower(), it["sub"]]
		elif names[it["name"]] > 1:
			b.text = "%s (%s)" % [it["name"], str(it["kind"]).to_lower()]
		b.tooltip_text = "%s  ·  %s   (%d/%d)\nClick: spawn it where you aim" % [it["kind"], it["name"], it["cls"], it["sub"]]
		b.icon = _placeholder(int(it["cls"]))
		b.expand_icon = true
		b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		b.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		b.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART   # (the whole name, on two lines: "Station de détection Hégémonie")
		b.clip_text = false
		b.add_theme_font_size_override("font_size", 14)
		b.add_theme_stylebox_override("normal", _box(CARD, CARD.lightened(0.15), 1, 6, 6))
		b.add_theme_stylebox_override("hover", _box(CARD.lightened(0.08), ACCENT, 2, 6, 6))
		b.add_theme_stylebox_override("pressed", _box(ACCENT.darkened(0.5), ACCENT, 2, 6, 6))
		b.pressed.connect(_on_item.bind(i))
		grid.add_child(b)
		buttons.append(b)
	_filter()


func set_thumb(key: int, tex: Texture2D) -> void:
	for i in catalog.size():
		if int(catalog[i]["cls"]) * 256 + int(catalog[i]["sub"]) == key:
			buttons[i].icon = tex


# typing in the search field: its letters are not the editor's keys
func search_focused() -> bool:
	return search.is_editing()


func popup_open() -> bool:
	return group_opt.get_popup().visible


# what a click on a picture did, in the top bar (green: spawned, red: not), the card lit for a moment
func flash(i: int, t: String, col: Color) -> void:
	count_label.text = "  " + t
	count_label.add_theme_color_override("font_color", col)
	flash_t = Time.get_ticks_msec() + 2500
	if flashed >= 0 and flashed < buttons.size():
		buttons[flashed].add_theme_stylebox_override("normal", _box(CARD, CARD.lightened(0.15), 1, 6, 6))
	flashed = i
	if i >= 0 and i < buttons.size():
		buttons[i].add_theme_stylebox_override("normal", _box(CARD.lightened(0.05), col, 2, 6, 6))


func _process(_dt: float) -> void:
	if flash_t != 0 and Time.get_ticks_msec() > flash_t:
		flash_t = 0
		if flashed >= 0 and flashed < buttons.size():
			buttons[flashed].add_theme_stylebox_override("normal", _box(CARD, CARD.lightened(0.15), 1, 6, 6))
		flashed = -1
		_filter()


# ---- the parts
func _on_kind(k: int) -> void:
	kind = k
	_filter()


func _on_item(i: int) -> void:
	search.release_focus()
	spawn.emit(i)


func _filter() -> void:
	var want := _fold(search.text.strip_edges())
	var n := 0
	for i in buttons.size():
		var it: Dictionary = catalog[i]
		var ok: bool = (kind == -1 or int(it["cls"]) == kind) and \
			(want == "" or _fold(str(it["name"])).contains(want) or _fold(str(it["kind"])).contains(want))
		buttons[i].visible = ok
		if ok:
			n += 1
	if flash_t == 0:
		count_label.text = "  %d" % n
		count_label.add_theme_color_override("font_color", Color(0.65, 0.7, 0.75))
	_columns()


# lower case, no accents: "hegemonie" finds "Hégémonie"
static func _fold(t: String) -> String:
	var s := t.to_lower()
	for a in FOLD:
		s = s.replace(a, FOLD[a])
	return s


func _columns() -> void:
	if grid:
		grid.columns = maxi(1, int((scroll.size.x - 14.0) / (CELL.x + 6.0)))


func _placeholder(cls: int) -> Texture2D:
	if not placeholders.has(cls):
		var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
		var c: Color = KIND_COL.get(cls, Color(0.6, 0.6, 0.6))
		img.fill(Color(c, 0.0))
		for y in range(18, 46):
			for x in range(18, 46):
				if Vector2(x - 31.5, y - 31.5).length() < 13.0:
					img.set_pixel(x, y, Color(c, 0.35))
		placeholders[cls] = ImageTexture.create_from_image(img)
	return placeholders[cls]


func _title(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", ACCENT.lightened(0.2))
	return l


func _flat(t: String, size: int) -> Button:
	var b := Button.new()
	b.text = t
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_stylebox_override("normal", _box(CARD, CARD, 0, 6, 8))
	b.add_theme_stylebox_override("hover", _box(CARD.lightened(0.08), ACCENT, 1, 6, 8))
	b.add_theme_stylebox_override("pressed", _box(ACCENT.darkened(0.35), ACCENT, 1, 6, 8))
	b.add_theme_stylebox_override("hover_pressed", _box(ACCENT.darkened(0.25), ACCENT, 1, 6, 8))
	return b


static func _box(bg: Color, border: Color, width: int, radius: int, pad: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(width)
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(pad)
	return sb
