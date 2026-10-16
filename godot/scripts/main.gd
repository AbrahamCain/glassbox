extends Node3D
## Game state and glue: scenes, selection, spells, predictions, XP, quests.
##
## Controls: W/S or Up/Down climb floors · left-click/drag select cells (Shift adds)
## A all image cells · T all text cells · X clear selection · Enter add to spell
## Tab activity/ripple view · I toggle picture · 1/2/3 tools · right-drag orbit · wheel zoom

const Backend := preload("res://scripts/backend.gd")
const Tower := preload("res://scripts/tower.gd")
const Hud := preload("res://scripts/hud.gd")
const OrbitCamera := preload("res://scripts/orbit_camera.gd")
const OUTCOMES := ["nothing", "nudge", "shove", "flip"]
var progress_path := "user://progress.json"

var backend: Node
var tower: Node3D
var hud: Control
var camera: Camera3D

var scenes: Array = []
var quests: Array = []
var scene: Dictionary = {}  # loaded slot A
var source_loaded := false
var spell: Array = []  # intervention specs
var quest: Dictionary = {}
var progress := {"xp": 0, "streak": 0, "done": {}, "best": {}}
var busy := false
var _painting := false


func _ready() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.02, 0.02, 0.04)
	add_child(env)

	camera = OrbitCamera.new()
	add_child(camera)
	tower = Tower.new()
	add_child(tower)
	backend = Backend.new()
	add_child(backend)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	layer.add_child(hud)

	backend.connected.connect(_on_connected)
	backend.disconnected.connect(func(): hud.status.text = "backend offline - run backend/run.ps1 (retrying)")
	hud.load_pressed.connect(_on_load_pressed)
	hud.add_pressed.connect(add_selection_to_spell)
	hud.clear_pressed.connect(_clear_spell)
	hud.cast_pressed.connect(cast)
	hud.quest_selected.connect(start_quest)
	hud.hint_pressed.connect(_on_hint)

	if "--autotest" in OS.get_cmdline_user_args():
		progress_path = "user://autotest_progress.json"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(progress_path))
	quests = JSON.parse_string(FileAccess.get_file_as_string("res://data/quests.json"))
	_load_progress()
	_refresh_quests()
	_update_info()


func _on_connected() -> void:
	var hello: Dictionary = await backend.call_op("hello")
	if hello.ok:
		hud.status.text = "%s  ·  %d layers" % [hello.data.model, int(hello.data.n_layers)]
	var r: Dictionary = await backend.call_op("list_scenes")
	if not r.ok:
		return
	scenes = r.data.scenes
	hud.scene_a.clear()
	hud.scene_b.clear()
	hud.scene_b.add_item("(none)")
	for s in scenes:
		hud.scene_a.add_item(s.name)
		hud.scene_b.add_item(s.name)
	if "--autotest" in OS.get_cmdline_user_args():
		_autotest()
	elif scene.is_empty():
		await load_scenes(scenes[0].name, "")


func _on_hint() -> void:
	if not quest.is_empty():
		hud.say(quest.get("hint", "No hint for this one."), Color(0.7, 0.9, 1), 9)


# ------------------------------------------------------------------ scenes

func _on_load_pressed() -> void:
	if hud.scene_a.item_count == 0:
		return
	var b: String = "" if hud.scene_b.selected <= 0 else hud.scene_b.get_item_text(hud.scene_b.selected)
	quest = {}
	_refresh_quests()
	await load_scenes(hud.scene_a.get_item_text(hud.scene_a.selected), b)


func load_scenes(a: String, b: String) -> bool:
	if busy:
		return false
	busy = true
	hud.say("loading %s..." % a, Color(0.8, 0.8, 0.8), 30)
	var r: Dictionary = await backend.call_op("load_scene", {"slot": "A", "scene": a})
	source_loaded = false
	if r.ok and b != "":
		var rb: Dictionary = await backend.call_op("load_scene", {"slot": "B", "scene": b})
		source_loaded = rb.ok
		if not rb.ok:
			r = rb
	busy = false
	if not r.ok:
		hud.say(r.error, Color(1, 0.4, 0.4), 8)
		return false
	scene = r.data
	_select_option(hud.scene_a, a)
	_select_option(hud.scene_b, b if b != "" else "(none)")
	spell.clear()
	tower.build(scene)
	_focus()
	_show_clean()
	_update_info()
	hud.say("")
	return true


func _select_option(ob: OptionButton, text: String) -> void:
	for i in ob.item_count:
		if ob.get_item_text(i) == text:
			ob.select(i)


# ------------------------------------------------------------------ input

func _unhandled_input(e: InputEvent) -> void:
	if scene.is_empty():
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_painting = e.pressed
		if e.pressed:
			if not e.shift_pressed:
				tower.selection.clear()
			_paint(e.position, not e.shift_pressed)
	elif e is InputEventMouseMotion and _painting:
		_paint(e.position, true)
	elif e is InputEventKey and e.pressed and not e.echo and not hud.any_text_focused():
		match e.keycode:
			KEY_W, KEY_UP, KEY_PAGEUP:
				_set_floor(tower.active + 1)
			KEY_S, KEY_DOWN, KEY_PAGEDOWN:
				_set_floor(tower.active - 1)
			KEY_A:
				_select_kind(["image"])
			KEY_T:
				_select_kind(["text", "special"])
			KEY_X:
				tower.selection.clear()
				tower.refresh()
			KEY_ENTER, KEY_KP_ENTER:
				add_selection_to_spell()
			KEY_TAB:
				tower.toggle_mode()
			KEY_I:
				tower.show_image = not tower.show_image
				tower.set_active(tower.active)
			KEY_1:
				hud.tool_buttons["ablate"].button_pressed = true
			KEY_2:
				hud.tool_buttons["patch"].button_pressed = true
			KEY_3:
				hud.tool_buttons["steer"].button_pressed = true
			_:
				return
		_update_info()
		get_viewport().set_input_as_handled()


func _paint(pos: Vector2, add: bool) -> void:
	var idx: int = tower.pick(camera.project_ray_origin(pos), camera.project_ray_normal(pos))
	if idx < 0:
		return
	if add:
		tower.selection[idx] = true
	elif tower.selection.has(idx):
		tower.selection.erase(idx)
	else:
		tower.selection[idx] = true
	tower.refresh()
	_update_info()


func _select_kind(kinds: Array) -> void:
	tower.selection.clear()
	for i in tower.tokens.size():
		if tower.tokens[i].kind in kinds:
			tower.selection[i] = true
	tower.refresh()


func _set_floor(layer: int) -> void:
	tower.selection.clear()
	tower.set_active(layer)
	_focus()


func _focus() -> void:
	camera.focus(tower.floor_center(tower.active))


# ------------------------------------------------------------------ spells

func add_selection_to_spell() -> bool:
	if tower.selection.is_empty():
		hud.say("Select some cells first (click, drag, or A for all image cells)", Color(1, 0.8, 0.4))
		return false
	var tool: String = hud.current_tool()
	var positions := []
	for i in tower.selection:
		positions.append(int(tower.tokens[i].index))
	positions.sort()
	var spec := {"type": tool, "layer": tower.active, "positions": positions}
	match tool:
		"ablate":
			spec.mode = hud.ablate_mode.get_item_text(hud.ablate_mode.selected)
		"patch":
			if not source_loaded:
				hud.say("Patching needs a patch-source scene (top bar) with the same prompt", Color(1, 0.5, 0.4), 6)
				return false
			spec.source = "B"
		"steer":
			spec.from_text = hud.steer_from.text
			spec.to_text = hud.steer_to.text
			spec.scale = hud.steer_scale.value
	var problem := _rule_problem(spec)
	if problem != "":
		hud.say("Quest rule: " + problem, Color(1, 0.5, 0.4), 6)
		return false
	spell.append(spec)
	if not tower.queued.has(tower.active):
		tower.queued[tower.active] = {}
	for i in tower.selection:
		tower.queued[tower.active][i] = true
	tower.selection.clear()
	tower.refresh()
	_update_info()
	return true


func _clear_spell() -> void:
	spell.clear()
	tower.queued.clear()
	tower.refresh()
	_update_info()


func _cells_in_spell(extra := {}) -> int:
	var n := 0
	for s in spell:
		n += s.positions.size()
	if not extra.is_empty():
		n += extra.positions.size()
	return n


func _rule_problem(spec: Dictionary) -> String:
	var rules: Dictionary = quest.get("rules", {})
	if rules.has("tools") and not spec.type in rules.tools:
		return "only %s allowed" % ", ".join(rules.tools)
	if rules.has("min_layer") and spec.layer < int(rules.min_layer):
		return "floors below %d are sealed" % int(rules.min_layer)
	if rules.has("max_layer") and spec.layer > int(rules.max_layer):
		return "floors above %d are sealed" % int(rules.max_layer)
	if rules.has("kinds"):
		for p in spec.positions:
			if not tower.tokens[p].kind in rules.kinds:
				return "you may only touch %s tokens" % " / ".join(rules.kinds)
	if rules.has("max_cells") and _cells_in_spell(spec) > int(rules.max_cells):
		return "at most %d cells in total" % int(rules.max_cells)
	return ""


func cast(prediction: String) -> void:
	if busy or scene.is_empty():
		return
	if spell.is_empty() and not tower.selection.is_empty():
		if not add_selection_to_spell():
			return
	if spell.is_empty():
		hud.say("The spell is empty: select cells, pick a tool, Add", Color(1, 0.8, 0.4))
		return
	busy = true
	var r: Dictionary = await backend.call_op("intervene", {"slot": "A", "interventions": spell})
	busy = false
	if not r.ok:
		hud.say(r.error, Color(1, 0.4, 0.4), 8)
		return
	var res: Dictionary = r.data
	tower.set_ripple(res)
	_show_result(res, prediction)

	var gained := 0
	var verdict := ""
	if prediction != "":
		var diff: int = absi(OUTCOMES.find(prediction) - OUTCOMES.find(res.outcome))
		if diff == 0:
			gained = 10 + 2 * int(progress.streak)
			progress.streak = int(progress.streak) + 1
			verdict = "Called it: %s  +%d XP" % [res.outcome.to_upper(), gained]
		elif diff == 1:
			gained = 3
			progress.streak = 0
			verdict = "Close: it was %s  +3 XP" % res.outcome.to_upper()
		else:
			progress.streak = 0
			verdict = "Wrong: it was %s" % res.outcome.to_upper()
	else:
		verdict = "Outcome: %s" % res.outcome.to_upper()

	var quest_msg := _check_quest(res)
	if quest_msg != "":
		gained += 50
		verdict += "\n" + quest_msg
	progress.xp = int(progress.xp) + gained
	_save_progress()
	_update_info()
	hud.say(verdict, Color(0.5, 1, 0.6) if gained > 0 else Color(1, 0.75, 0.5), 5)
	backend.call_op("log", {"record": {
		"scene": scene.image, "prompt": scene.prompt, "spell": spell, "prediction": prediction,
		"outcome": res.outcome, "p": res.p_clean_answer, "answer": res.answer,
		"generation": res.generation, "quest": quest.get("id", ""),
	}})


# ------------------------------------------------------------------ quests

func start_quest(index: int) -> void:
	if busy:
		return
	var q: Dictionary = quests[index]
	if not await load_scenes(q.scene, q.get("source", "")):
		return
	quest = q
	if q.has("tool"):
		hud.tool_buttons[q.tool].button_pressed = true
	var rules: Dictionary = q.get("rules", {})
	var lines := []
	if rules.has("tools"): lines.append("tools: " + ", ".join(rules.tools))
	if rules.has("kinds"): lines.append("touch only: " + ", ".join(rules.kinds))
	if rules.has("min_layer"): lines.append("floors >= %d" % int(rules.min_layer))
	if rules.has("max_layer"): lines.append("floors <= %d" % int(rules.max_layer))
	if rules.has("max_cells"): lines.append("at most %d cells" % int(rules.max_cells))
	var goal: Dictionary = q.goal
	var goal_text := "make the answer change" if goal.type == "flip" else "make it answer \"%s\"" % goal.target
	var text := "[b]%s[/b]\n\n%s\n\n[color=#ffd75e]Goal:[/color] %s\n[color=#9fd3ff]Rules:[/color] %s" % [
		q.title, q.brief, goal_text, "; ".join(lines) if lines else "none"]
	if progress.done.has(q.id):
		text += "\n\n[color=#7dff9a]Completed.[/color] %s" % q.get("lesson", "")
		if progress.best.has(q.id):
			text += "\nYour best: %d cells." % int(progress.best[q.id])
	hud.quest_text.text = text


func _check_quest(res: Dictionary) -> String:
	if quest.is_empty():
		return ""
	var goal: Dictionary = quest.goal
	var ok := false
	if goal.type == "flip":
		ok = res.outcome == "flip"
	elif goal.type == "make":
		ok = str(res.generation).strip_edges().to_lower().begins_with(str(goal.target).to_lower())
	if not ok:
		return ""
	var id: String = quest.id
	var first: bool = not progress.done.has(id)
	progress.done[id] = true
	var cells := _cells_in_spell()
	var best_msg := ""
	if not progress.best.has(id) or cells < int(progress.best[id]):
		progress.best[id] = cells
		best_msg = " (new best: %d cells)" % cells
	_refresh_quests()
	start_quest_text_refresh()
	if first:
		return "QUEST COMPLETE: %s  +50 XP%s" % [quest.title, best_msg]
	return "Quest solved again%s" % best_msg


func start_quest_text_refresh() -> void:
	hud.quest_text.text += "\n\n[color=#7dff9a]Solved![/color] %s" % quest.get("lesson", "")


func _refresh_quests() -> void:
	hud.quest_list.clear()
	for q in quests:
		var mark := "✓ " if progress.done.has(q.id) else "· "
		hud.quest_list.add_item(mark + q.title)
	if quest.is_empty():
		hud.quest_text.text = "[b]Glassbox[/b]\n\nPick a quest, or load any scene and experiment.\n\n" + \
			"Each floor of the tower is one transformer block. The 8x8 board is the picture as the " + \
			"model sees it (one cell = one image token); the strip in front is the text prompt.\n\n" + \
			"Before every cast, bet on what will happen. Your hit rate is the real score."


func _load_progress() -> void:
	if FileAccess.file_exists(progress_path):
		var p = JSON.parse_string(FileAccess.get_file_as_string(progress_path))
		if typeof(p) == TYPE_DICTIONARY:
			progress.merge(p, true)


func _save_progress() -> void:
	var f := FileAccess.open(progress_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(progress))


# ------------------------------------------------------------------ readouts

func _update_info() -> void:
	hud.xp_label.text = "XP %d   streak %d   quests %d/%d" % [
		int(progress.xp), int(progress.streak), progress.done.size(), quests.size()]
	if scene.is_empty():
		hud.info_label.text = "No scene loaded."
		return
	var mode_name: String = "ripple (change caused by spell)" if tower.mode == "ripple" else "activity (how much each block writes)"
	hud.info_label.text = "Floor %d/%d   ·   %d selected   ·   view: %s   ·   W/S floors, click/drag select, A image, T text, X clear, Tab view, I picture" % [
		tower.active, tower.n_layers - 1, tower.selection.size(), mode_name]
	if spell.is_empty():
		hud.queue_label.text = "spell: empty"
	else:
		var parts := []
		for s in spell:
			parts.append("%s L%d x%d" % [s.type, int(s.layer), s.positions.size()])
		hud.queue_label.text = "spell (%d cells): %s" % [_cells_in_spell(), ", ".join(parts)]


func _topk_text(topk: Array) -> String:
	var parts := []
	for t in topk.slice(0, 5):
		parts.append("%s [color=#8899aa]%.2f[/color]" % [_q(t.token), float(t.p)])
	return "  ".join(parts)


func _q(s) -> String:
	return "\"" + str(s).replace("[", "[lb]").replace("\n", "\\n") + "\""


func _show_clean() -> void:
	hud.answer_text.text = "[b]PROMPT[/b]\n%s\n\n[b]CLEAN ANSWER[/b]\n%s\n\n[color=#8899aa]next token:[/color]\n%s" % [
		scene.prompt.replace("[", "[lb]"), _q(scene.generation), _topk_text(scene.topk)]


func _show_result(res: Dictionary, prediction: String) -> void:
	var colors := {"nothing": "#8899aa", "nudge": "#9fd3ff", "shove": "#ffd75e", "flip": "#ff7a45"}
	var text := "[b]PROMPT[/b]\n%s\n\n[b]CLEAN[/b]  %s\n[b]AFTER SPELL[/b]  [color=#ffb070]%s[/color]\n\n" % [
		scene.prompt.replace("[", "[lb]"), _q(res.clean_generation), _q(res.generation)]
	text += "outcome: [color=%s][b]%s[/b][/color]" % [colors[res.outcome], res.outcome.to_upper()]
	if prediction != "":
		text += "   (you bet %s)" % prediction
	text += "\np(%s): %.2f -> %.2f\n\n[color=#8899aa]next token now:[/color]\n%s\n\n" % [
		_q(res.clean_answer), float(res.p_clean_answer.before), float(res.p_clean_answer.after), _topk_text(res.topk)]
	text += "[color=#8899aa]Tab toggles the ripple view: bright cells are where the spell changed the model's state.[/color]"
	hud.answer_text.text = text


# ------------------------------------------------------------------ autotest

func _autotest() -> void:
	## `godot --path godot -- --autotest`: play quest 1 end to end, screenshot, quit.
	start_quest(0)
	while scene.is_empty() or busy:
		await get_tree().process_frame
	_set_floor(10)
	_select_kind(["image"])
	add_selection_to_spell()
	await cast("flip")
	for i in 30:
		await get_tree().process_frame
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://autotest.png")
	print("AUTOTEST outcome=%s xp=%d done=%s png=%s" % [
		tower.mode, int(progress.xp), str(progress.done.keys()), ProjectSettings.globalize_path("user://autotest.png")])
	get_tree().quit()
