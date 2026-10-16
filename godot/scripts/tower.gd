extends Node3D
## The layer tower. Floor L shows the residual stream right after block L: image tokens
## form the patch board (row-major, same orientation as the picture on the ground), text
## and special tokens form a strip in front of it.
##
## Views: "activity" = how much each block writes into each token (clean run, normalised
## per floor). "ripple" = how far the last spell pushed each token away from the clean run.

const PITCH := 1.0
const FLOOR_H := 1.0
const CELL := 0.86
const GROUND_Y := -1.5

const SELECT_COLOR := Color(1.0, 0.25, 0.9)
const QUEUED_COLOR := Color(0.25, 1.0, 0.45)

var n_layers := 0
var grid := 0
var width := 8
var tokens: Array = []
var token_at := {}  # Vector2i -> token index
var cell_pos := {}  # token index -> Vector2i
var active := 0
var mode := "activity"
var activity: Array = []
var ripple: Array = []
var clean_lens: Array = []
var spell_lens: Array = []
var selection := {}  # token index -> true, on the active floor
var queued := {}  # layer -> {token index: true}
var show_image := true

var _floors: Array[MultiMeshInstance3D] = []
var _floor_labels: Array[Label3D] = []
var _token_labels: Array[Label3D] = []
var _ghost: MeshInstance3D
var _mat: StandardMaterial3D


func _ready() -> void:
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA


func build(scene: Dictionary) -> void:
	for c in get_children():
		c.queue_free()
	_floors.clear()
	_floor_labels.clear()
	_token_labels.clear()
	_ghost = null
	n_layers = int(scene.n_layers)
	grid = int(scene.grid_size)
	width = maxi(grid, 8)
	tokens = scene.tokens
	activity = scene.activity
	clean_lens = scene.lens
	spell_lens = []
	ripple = []
	selection.clear()
	queued.clear()
	mode = "activity"
	active = clampi(active, 0, n_layers - 1)
	_layout()

	var box := BoxMesh.new()
	box.size = Vector3(CELL, 0.1, CELL)
	box.material = _mat
	for L in n_layers:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = box
		mm.instance_count = tokens.size()
		for i in tokens.size():
			mm.set_instance_transform(i, Transform3D(Basis(), cell_world(cell_pos[i], L)))
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		add_child(mmi)
		_floors.append(mmi)

		var lab := Label3D.new()
		lab.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		lab.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		lab.position = Vector3(-(width / 2.0 + 0.7) * PITCH, L * FLOOR_H, 0)
		lab.font_size = 40
		lab.pixel_size = 0.008
		lab.outline_size = 10
		add_child(lab)
		_floor_labels.append(lab)

	for i in tokens.size():
		if tokens[i].kind == "image":
			continue
		var t := Label3D.new()
		t.text = _short(str(tokens[i].text))
		t.font_size = 26
		t.pixel_size = 0.0055
		t.outline_size = 8
		t.rotation_degrees = Vector3(-90, 0, 0)
		t.set_meta("token", i)
		add_child(t)
		_token_labels.append(t)

	_build_image(scene)
	set_active(active)


func _layout() -> void:
	token_at.clear()
	cell_pos.clear()
	var k := 0
	for i in tokens.size():
		var t: Dictionary = tokens[i]
		var c: Vector2i
		if t.kind == "image" and t.grid != null:
			c = Vector2i(int(t.grid[1]), int(t.grid[0]))
		else:
			c = Vector2i(k % width, grid + 1 + floori(k / float(width)))
			k += 1
		cell_pos[i] = c
		token_at[c] = i


func cell_world(c: Vector2i, layer: int) -> Vector3:
	return Vector3((c.x - width / 2.0 + 0.5) * PITCH, layer * FLOOR_H, (c.y - grid / 2.0 + 0.5) * PITCH)


func floor_center(layer: int) -> Vector3:
	return Vector3(0, layer * FLOOR_H, 1.0)


func _build_image(scene: Dictionary) -> void:
	if grid == 0 or scene.get("image_png") == null:
		return
	var img := Image.new()
	if img.load_png_from_buffer(Marshalls.base64_to_raw(scene.image_png)) != OK:
		return
	var tex := ImageTexture.create_from_image(img)
	var center := (cell_world(Vector2i(0, 0), 0) + cell_world(Vector2i(grid - 1, grid - 1), 0)) / 2.0
	for ghost in [false, true]:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_texture = tex
		if ghost:  # a faint copy of the picture under the active floor
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color = Color(1, 1, 1, 0.45)
		var plane := PlaneMesh.new()
		plane.size = Vector2(grid * PITCH, grid * PITCH)
		plane.material = mat
		var mi := MeshInstance3D.new()
		mi.mesh = plane
		mi.position = center + Vector3(0, GROUND_Y, 0)
		add_child(mi)
		if ghost:
			_ghost = mi


func set_active(layer: int) -> void:
	active = clampi(layer, 0, maxi(n_layers - 1, 0))
	for t in _token_labels:
		t.position = cell_world(cell_pos[t.get_meta("token")], active) + Vector3(0, 0.07, 0)
	if _ghost:
		_ghost.position.y = active * FLOOR_H - 0.08
		_ghost.visible = show_image
	refresh()


func set_ripple(result: Dictionary) -> void:
	ripple = result.ripple
	spell_lens = result.lens
	mode = "ripple"
	refresh()


func toggle_mode() -> void:
	mode = "activity" if mode == "ripple" or ripple.is_empty() else "ripple"
	refresh()


func pick(origin: Vector3, dir: Vector3) -> int:
	if n_layers == 0 or absf(dir.y) < 1e-5:
		return -1
	var t := (active * FLOOR_H - origin.y) / dir.y
	if t < 0:
		return -1
	var p := origin + dir * t
	var c := Vector2i(floori(p.x / PITCH + width / 2.0), floori(p.z / PITCH + grid / 2.0))
	return token_at.get(c, -1)


func _values(layer: int) -> Array:
	var out := []
	if mode == "ripple" and not ripple.is_empty():
		for v in ripple[layer]:
			out.append(clampf(sqrt(float(v)), 0.0, 1.0))
		return out
	var row: Array = activity[layer]
	var peak := 1e-6
	for i in row.size():
		if tokens[i].kind != "special":
			peak = maxf(peak, float(row[i]))
	for v in row:
		out.append(clampf(float(v) / peak, 0.0, 1.0))
	return out


func _ramp(v: float) -> Color:
	if mode == "ripple":
		var c := Color(0.1, 0.06, 0.06).lerp(Color(1.0, 0.4, 0.08), clampf(v * 1.6, 0, 1))
		return c.lerp(Color(1.0, 0.95, 0.4), clampf(v * 2.0 - 1.0, 0, 1))
	var a := Color(0.05, 0.08, 0.22).lerp(Color(0.1, 0.6, 1.0), clampf(v * 1.4, 0, 1))
	return a.lerp(Color(0.9, 0.97, 1.0), clampf(v * 2.5 - 1.5, 0, 1))


func refresh() -> void:
	var lens: Array = spell_lens if mode == "ripple" and not spell_lens.is_empty() else clean_lens
	for L in n_layers:
		var mm := _floors[L].multimesh
		var vals := _values(L)
		var q: Dictionary = queued.get(L, {})
		for i in tokens.size():
			var col: Color
			if L == active and selection.has(i):
				col = SELECT_COLOR
			elif q.has(i):
				col = QUEUED_COLOR
				col.a = 0.95
			else:
				col = _ramp(vals[i])
				if L == active:
					col.a = 0.8 if show_image else 1.0
				elif mode == "ripple":
					col.a = 0.03 + 0.85 * vals[i]
				else:
					col.a = 0.05
			mm.set_instance_color(i, col)

		var lab := _floor_labels[L]
		var top: Dictionary = lens[L].top[0]
		lab.text = "L%d  %s  p(ans)=%.2f" % [L, _short(str(top.token), 10), float(lens[L].p_answer)]
		if L == active:
			lab.modulate = Color(1, 0.9, 0.3)
			lab.font_size = 72
		else:
			lab.modulate = Color(0.75, 0.8, 0.9, 0.55)
			lab.font_size = 44


func _short(s: String, n := 6) -> String:
	s = s.replace("\n", "\\n")
	return s if s.length() <= n else s.substr(0, n - 1) + "…"
