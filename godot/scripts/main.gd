extends Node3D
## Game state and glue: scenes, selection, spells, bets, XP, quests, tutorial.
## Keys and terms are listed in hud.gd (HELP_TEXT), shown in-game with H.

const Backend := preload("res://scripts/backend.gd")
const Tower := preload("res://scripts/tower.gd")
const Hud := preload("res://scripts/hud.gd")
const OrbitCamera := preload("res://scripts/orbit_camera.gd")
const Audio := preload("res://scripts/audio.gd")
const OUTCOMES := ["nothing", "nudge", "shove", "flip"]
const ALL_TOOLS := ["ablate", "patch", "steer"]
const OUTCOME_SENTENCE := {
	"nothing": "Your spell barely mattered: the model didn't need those cells (on that floor) for this answer.",
	"nudge": "Your spell shook the model's confidence a little, but it kept its answer.",
	"shove": "Your spell shook the model's confidence a lot, but it still gave the same answer.",
	"flip": "Your spell changed the model's answer.",
}

## The guided tutorial. `wait` is what moves it on: "next" (button), or something the player does.
const TUTORIAL := [
	{"wait": "next", "target": "", "text": "Welcome! This tower [b]is[/b] a vision-language model (SmolVLM). Each [b]floor[/b] is one of its layers, and its thinking flows upward, floor by floor. The picture on the ground is what it's looking at, cut into 64 cells. We asked it [i]\"What color is the shape?\"[/i] It answers [b]\"Red.\"[/b]"},
	{"wait": "next", "target": "meter", "text": "This [b]meter[/b] shows how sure each floor is that the answer is \"Red\". The low floors haven't worked it out yet; only the floors near the top are sure. Hover over a row for details."},
	{"wait": "floor10", "target": "meter", "text": "Go to [b]floor 10[/b]: click its row in the meter, or press [b]W[/b] to climb one floor at a time. Each floor plays a note: the surer it is, the higher the note."},
	{"wait": "selected", "target": "", "text": "On each floor, cells glow where that layer is doing a lot of work. Press [b]A[/b] to select every picture cell (or click and drag over them). Hover a cell to see what it is."},
	{"wait": "spell", "target": "add", "text": "Your tool is [b]Transplant[/b]: it copies these cells' state from a second run where the model looked at a [b]blue[/b] circle. Click [b]Add to spell[/b] (or press Enter)."},
	{"wait": "cast", "target": "bets", "text": "Now [b]bet[/b]: what will happen to the answer \"Red\"? Hover over each button for its exact meaning. Clicking a bet casts the spell."},
	{"wait": "tab", "target": "meter", "text": "The [color=#ff8a3d]orange bars[/color] show how sure each floor is of the model's [i]new[/i] answer after your spell. The tower now shows the [b]ripple[/b]: bright cells are where your change spread. Press [b]Tab[/b] to switch between ripple and normal colours."},
	{"wait": "next", "target": "help", "text": "That's the whole loop: [b]select → add → bet → cast[/b]. Press [b]H[/b] any time for keys and terms, and [b]B[/b] for a top-down view of the floor. Quest 1 is unlocked. Good luck!"},
]

var progress_path := "user://progress.json"

var backend: Node
var tower: Node3D
var hud: Control
var camera: Camera3D
var audio: Node

var scenes: Array = []
var quests: Array = []
var scene: Dictionary = {}  # loaded slot A
var source_name := ""  # loaded slot B, "" if none
var spell: Array = []  # intervention specs
var quest: Dictionary = {}
var progress := {"xp": 0, "streak": 0, "done": {}, "best": {}, "volume": 0.8, "music": true,
	"muted": false, "unlock_all": false}
var busy := false
var tut_step := -1
var _tut := {}  # player actions seen during the tutorial
var _painting := false
var _last_new_answer := ""


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
	audio = Audio.new()
	add_child(audio)
	backend = Backend.new()
	add_child(backend)
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Hud.new()
	layer.add_child(hud)

	backend.connected.connect(_on_connected)
	backend.disconnected.connect(func(): hud.status.text = "backend offline: run backend/run.ps1 (retrying)")
	hud.load_pressed.connect(_on_load_pressed)
	hud.add_pressed.connect(add_selection_to_spell)
	hud.clear_pressed.connect(_clear_spell)
	hud.cast_pressed.connect(cast)
	hud.quest_selected.connect(start_quest)
	hud.hint_pressed.connect(_on_hint)
	hud.volume_changed.connect(_on_volume)
	hud.music_toggled.connect(_on_music)
	hud.floor_clicked.connect(_set_floor)
	hud.coach_next.connect(_coach_next)
	hud.coach_skip.connect(func(): _tutorial_end(true))
	hud.unlock_all_toggled.connect(_on_unlock_all)
	hud.replay_tutorial.connect(func(): start_quest(_quest_index("tutorial")))
	for p in hud.get_children():
		if p is PanelContainer:
			p.mouse_entered.connect(_clear_hover)

	var args := OS.get_cmdline_user_args()
	if "--autotest" in args or "--demo" in args:
		progress_path = "user://autotest_progress.json"
		DirAccess.remove_absolute(ProjectSettings.globalize_path(progress_path))
	quests = JSON.parse_string(FileAccess.get_file_as_string("res://data/quests.json"))
	_load_progress()
	if "--demo" in args:
		progress.unlock_all = true
		progress.done["tutorial"] = true
	hud.volume.set_value_no_signal(float(progress.volume))
	hud.music.set_pressed_no_signal(bool(progress.music))
	hud.unlock_all.set_pressed_no_signal(bool(progress.unlock_all))
	_apply_audio()
	_refresh_quests()
	_apply_tools()
	_update_info()


func _on_connected() -> void:
	var hello: Dictionary = await backend.call_op("hello")
	if hello.ok:
		var model: String = hello.data.model
		hud.status.text = "%s  ·  %d floors" % [model.get_slice("/", model.get_slice_count("/") - 1), int(hello.data.n_layers)]
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
	var args := OS.get_cmdline_user_args()
	if "--autotest" in args:
		_autotest()
	elif "--demo" in args:
		_demo()
	elif not progress.done.has("tutorial"):
		start_quest(_quest_index("tutorial"))
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
	if tut_step >= 0:
		_tutorial_end(true)
	quest = {}
	_refresh_quests()
	await load_scenes(hud.scene_a.get_item_text(hud.scene_a.selected), b)
	_apply_tools()


func load_scenes(a: String, b: String) -> bool:
	if busy:
		return false
	busy = true
	hud.say("loading %s..." % a, Color(0.8, 0.8, 0.8), 30)
	var r: Dictionary = await backend.call_op("load_scene", {"slot": "A", "scene": a})
	source_name = ""
	if r.ok and b != "":
		var rb: Dictionary = await backend.call_op("load_scene", {"slot": "B", "scene": b})
		if rb.ok:
			source_name = b
		else:
			r = rb
	busy = false
	if not r.ok:
		audio.play("error")
		hud.say(r.error, Color(1, 0.4, 0.4), 8)
		return false
	scene = r.data
	_select_option(hud.scene_a, a)
	_select_option(hud.scene_b, b if b != "" else "(none)")
	hud.transplant_from.text = "copying from: %s" % source_name if source_name != "" \
		else "copying from: nothing (choose 'Transplant from' above, then Load)"
	spell.clear()
	tower.build(scene)
	_focus()
	_floor_sound()
	_show_clean()
	_update_meter()
	_update_info()
	hud.say("")
	return true


func _select_option(ob: OptionButton, text: String) -> void:
	for i in ob.item_count:
		if ob.get_item_text(i) == text:
			ob.select(i)


# ------------------------------------------------------------------ input

func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and not hud.any_text_focused():
		if e.keycode == KEY_H or (e.keycode == KEY_ESCAPE and hud.help.visible):
			hud.toggle_help()
			get_viewport().set_input_as_handled()
			return
	if scene.is_empty():
		return
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_painting = e.pressed
		if e.pressed:
			if not e.shift_pressed:
				tower.selection.clear()
			_paint(e.position, not e.shift_pressed)
	elif e is InputEventMouseMotion:
		if _painting:
			_paint(e.position, true)
		_hover(e.position)
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
				_tut["tab"] = true
				audio.play("toggle")
			KEY_B:
				camera.toggle_board_view()
				tower.board_view = camera.board_view
				tower.refresh()
				audio.play("toggle")
			KEY_I:
				tower.show_image = not tower.show_image
				tower.set_active(tower.active)
			KEY_1:
				hud.select_tool("ablate")
			KEY_2:
				hud.select_tool("patch")
			KEY_3:
				hud.select_tool("steer")
			KEY_M:
				progress.muted = not progress.muted
				_apply_audio()
				_save_progress()
				hud.say("sound off" if progress.muted else "sound on", Color(0.8, 0.8, 0.8), 1.5)
			_:
				return
		_update_info()
		get_viewport().set_input_as_handled()


func _pick(pos: Vector2) -> int:
	return tower.pick(camera.project_ray_origin(pos), camera.project_ray_normal(pos))


func _paint(pos: Vector2, add: bool) -> void:
	var idx := _pick(pos)
	if idx < 0:
		return
	if add:
		if tower.selection.has(idx):
			return
		tower.selection[idx] = true
	elif tower.selection.has(idx):
		tower.selection.erase(idx)
	else:
		tower.selection[idx] = true
	audio.play("select", -2.0, 1.0 + 0.15 * (tower.selection.size() % 5))
	tower.refresh()
	_update_info()


func _hover(pos: Vector2) -> void:
	var idx := _pick(pos)
	if idx != tower.hover:
		tower.hover = idx
		tower.refresh()
	if idx < 0:
		hud.show_hover("", pos)
		return
	var t: Dictionary = tower.tokens[idx]
	var what: String
	if t.kind == "image":
		what = "picture cell, row %d, column %d" % [int(t.grid[0]) + 1, int(t.grid[1]) + 1]
	elif t.kind == "special":
		what = "formatting token %s" % _q(t.text)
	else:
		what = "text cell %s" % _q(t.text)
	var v: float = tower.value_at(tower.active, idx)
	var view := "changed by your spell" if tower.mode == "ripple" else "activity"
	hud.show_hover("Floor %d  ·  %s\n%s: %d%%%s" % [
		tower.active, what, view, roundi(v * 100), "   (selected)" if tower.selection.has(idx) else ""], pos)


func _clear_hover() -> void:
	hud.show_hover("", Vector2.ZERO)
	if tower.hover != -1:
		tower.hover = -1
		tower.refresh()


func _select_kind(kinds: Array) -> void:
	tower.selection.clear()
	for i in tower.tokens.size():
		if tower.tokens[i].kind in kinds:
			tower.selection[i] = true
	audio.play("select")
	tower.refresh()
	_update_info()


func _set_floor(layer: int) -> void:
	if scene.is_empty():
		return
	tower.selection.clear()
	tower.hover = -1
	tower.set_active(layer)
	_focus()
	_floor_sound()
	_update_meter()
	_update_info()


func _focus() -> void:
	camera.focus(tower.floor_center(tower.active))


# ------------------------------------------------------------------ unlocking

func _quest_index(id: String) -> int:
	for i in quests.size():
		if quests[i].id == id:
			return i
	return -1


func _quest_unlocked(i: int) -> bool:
	return bool(progress.unlock_all) or i == 0 or progress.done.has(quests[i - 1].id)


## Tools appear as you reach the quests that teach them.
func _unlocked_tools() -> Array:
	if progress.unlock_all:
		return ALL_TOOLS.duplicate()
	var out := []
	for i in quests.size():
		if _quest_unlocked(i):
			for t in quests[i].get("rules", {}).get("tools", []):
				if not t in out:
					out.append(t)
	return out


func _apply_tools() -> void:
	var avail := _unlocked_tools()
	var rules: Dictionary = quest.get("rules", {})
	if rules.has("tools"):
		avail = ALL_TOOLS.filter(func(t): return t in rules.tools)
	hud.set_tools(avail)


func _on_unlock_all(on: bool) -> void:
	progress.unlock_all = on
	_save_progress()
	_refresh_quests()
	_apply_tools()


# ------------------------------------------------------------------ spells

func add_selection_to_spell() -> bool:
	if tower.selection.is_empty():
		audio.play("error")
		hud.say("Select some cells first (click, drag, or A for all picture cells)", Color(1, 0.8, 0.4))
		return false
	var tool: String = hud.current_tool()
	var positions := []
	for i in tower.selection:
		positions.append(int(tower.tokens[i].index))
	positions.sort()
	var spec := {"type": tool, "layer": tower.active, "positions": positions}
	match tool:
		"ablate":
			spec.mode = "mean" if hud.ablate_mode.selected == 0 else "zero"
		"patch":
			if source_name == "":
				audio.play("error")
				hud.say("Transplant needs a 'Transplant from' scene (top bar) that asks the same question", Color(1, 0.5, 0.4), 6)
				return false
			spec.source = "B"
		"steer":
			spec.from_text = hud.steer_from.text
			spec.to_text = hud.steer_to.text
			spec.scale = hud.steer_scale.value
	var problem := _rule_problem(spec)
	if problem != "":
		audio.play("error")
		hud.say("Quest rule: " + problem, Color(1, 0.5, 0.4), 6)
		return false
	spell.append(spec)
	if not tower.queued.has(tower.active):
		tower.queued[tower.active] = {}
	for i in tower.selection:
		tower.queued[tower.active][i] = true
	tower.selection.clear()
	audio.play("add")
	tower.refresh()
	_update_info()
	return true


func _clear_spell() -> void:
	if not spell.is_empty():
		audio.play("toggle", 0.0, 0.7)
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


func _kind_names(kinds: Array) -> String:
	var names := []
	for k in kinds:
		var n: String = "picture" if k == "image" else "text"
		if not n in names:
			names.append(n)
	return " or ".join(names) + " cells"


func _tool_names(tools: Array) -> String:
	var names := []
	for t in tools:
		names.append(Hud.TOOL_NAMES[t])
	return ", ".join(names)


func _rule_problem(spec: Dictionary) -> String:
	var rules: Dictionary = quest.get("rules", {})
	if rules.has("tools") and not spec.type in rules.tools:
		return "only %s allowed" % _tool_names(rules.tools)
	if rules.has("min_layer") and spec.layer < int(rules.min_layer):
		return "floors below %d are sealed" % int(rules.min_layer)
	if rules.has("max_layer") and spec.layer > int(rules.max_layer):
		return "floors above %d are sealed" % int(rules.max_layer)
	if rules.has("kinds"):
		for p in spec.positions:
			if not tower.tokens[p].kind in rules.kinds:
				return "you may only touch %s" % _kind_names(rules.kinds)
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
		audio.play("error")
		hud.say("The spell is empty: select cells, pick a tool, Add to spell", Color(1, 0.8, 0.4))
		return
	busy = true
	audio.play("cast")
	var r: Dictionary = await backend.call_op("intervene", {"slot": "A", "interventions": spell})
	busy = false
	if not r.ok:
		audio.play("error")
		hud.say(r.error, Color(1, 0.4, 0.4), 8)
		return
	var res: Dictionary = r.data
	tower.set_ripple(res)
	_last_new_answer = str(res.new_answer).strip_edges()
	_tut["cast"] = true
	_show_result(res, prediction)
	_update_meter()

	var gained := 0
	var verdict := ""
	var bet := ""
	if prediction != "":
		var diff: int = absi(OUTCOMES.find(prediction) - OUTCOMES.find(res.outcome))
		if diff == 0:
			gained = 10 + 2 * int(progress.streak)
			progress.streak = int(progress.streak) + 1
			bet = "right"
			verdict = "Called it: %s  +%d XP" % [res.outcome.to_upper(), gained]
		elif diff == 1:
			gained = 3
			progress.streak = 0
			bet = "close"
			verdict = "Close: it was %s  +3 XP" % res.outcome.to_upper()
		else:
			progress.streak = 0
			bet = "wrong"
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
	audio.cast_result(res.outcome, bet, quest_msg.begins_with("QUEST COMPLETE"), res.ripple)
	backend.call_op("log", {"record": {
		"scene": scene.image, "prompt": scene.prompt, "spell": spell, "prediction": prediction,
		"outcome": res.outcome, "p": res.p_clean_answer, "answer": res.answer,
		"generation": res.generation, "quest": quest.get("id", ""),
	}})


# ------------------------------------------------------------------ sound

func _floor_sound() -> void:
	if scene.is_empty():
		return
	var lens: Array = tower.spell_lens if tower.mode == "ripple" and not tower.spell_lens.is_empty() else tower.clean_lens
	audio.floor_tone(float(lens[tower.active].p_answer))
	audio.set_floor(tower.active / float(maxi(tower.n_layers - 1, 1)))


func _on_volume(v: float) -> void:
	progress.volume = v
	_apply_audio()
	_save_progress()


func _on_music(on: bool) -> void:
	progress.music = on
	_apply_audio()
	_save_progress()


func _apply_audio() -> void:
	audio.volume = float(progress.volume)
	audio.music = bool(progress.music)
	audio.muted = bool(progress.muted)
	audio.apply_settings()


# ------------------------------------------------------------------ quests

func start_quest(index: int) -> void:
	if busy or index < 0:
		return
	if not _quest_unlocked(index):
		audio.play("error")
		hud.say("Locked: finish the previous quest first (or unlock everything in Help)", Color(1, 0.8, 0.4))
		return
	var q: Dictionary = quests[index]
	if tut_step >= 0 and not q.get("tutorial", false):
		_tutorial_end(true)
	if not await load_scenes(q.scene, q.get("source", "")):
		return
	quest = q
	_apply_tools()
	if q.has("tool"):
		hud.select_tool(q.tool)
	if q.get("tutorial", false):
		_set_floor(0)
		_tutorial_begin()
		hud.quest_text.text = "[b]%s[/b]\n\n%s" % [q.title, q.brief]
		return
	var rules: Dictionary = q.get("rules", {})
	var lines := []
	if rules.has("tools"): lines.append("tools: " + _tool_names(rules.tools))
	if rules.has("kinds"): lines.append("touch only " + _kind_names(rules.kinds))
	if rules.has("min_layer"): lines.append("floors %d and up" % int(rules.min_layer))
	if rules.has("max_layer"): lines.append("floors %d and below" % int(rules.max_layer))
	if rules.has("max_cells"): lines.append("at most %d cells" % int(rules.max_cells))
	var goal: Dictionary = q.goal
	var goal_text := "make the model change its answer" if goal.type == "flip" else "make it answer \"%s\"" % goal.target
	var text := "[b]%s[/b]\n\n%s\n\n[color=#ffd75e]Goal:[/color] %s\n[color=#9fd3ff]Rules:[/color] %s" % [
		q.title, q.brief, goal_text, "; ".join(lines) if lines else "none"]
	if progress.done.has(q.id):
		text += "\n\n[color=#7dff9a]Completed.[/color] %s" % q.get("lesson", "")
		if progress.best.has(q.id):
			text += "\nYour best: %d cells." % int(progress.best[q.id])
	hud.quest_text.text = text


func _check_quest(res: Dictionary) -> String:
	if quest.is_empty() or quest.get("tutorial", false):
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
	_apply_tools()
	hud.quest_text.text += "\n\n[color=#7dff9a]Solved![/color] %s" % quest.get("lesson", "")
	var nxt := _quest_index(id) + 1
	if first and nxt < quests.size():
		hud.quest_text.text += "\n\n[color=#ffd75e]Unlocked: %s[/color]" % quests[nxt].title
	if first:
		return "QUEST COMPLETE: %s  +50 XP%s" % [quest.title, best_msg]
	return "Quest solved again%s" % best_msg


func _refresh_quests() -> void:
	hud.quest_list.clear()
	for i in quests.size():
		var q: Dictionary = quests[i]
		var unlocked := _quest_unlocked(i)
		var mark := "✓ " if progress.done.has(q.id) else ("· " if unlocked else "   ")
		var idx: int = hud.quest_list.add_item(mark + q.title + ("" if unlocked else "   (locked)"))
		hud.quest_list.set_item_disabled(idx, not unlocked)
		if not unlocked:
			hud.quest_list.set_item_tooltip(idx, "Finish the previous quest to unlock")
	if quest.is_empty():
		hud.quest_text.text = "[b]Free play[/b]\n\nPick a quest, or choose scenes in the top bar and press Load to experiment.\n\n" + \
			"Before every cast, bet on what will happen: your hit rate is the real score.\n\nPress [b]H[/b] for keys and terms."


func _load_progress() -> void:
	if FileAccess.file_exists(progress_path):
		var p = JSON.parse_string(FileAccess.get_file_as_string(progress_path))
		if typeof(p) == TYPE_DICTIONARY:
			progress.merge(p, true)


func _save_progress() -> void:
	var f := FileAccess.open(progress_path, FileAccess.WRITE)
	f.store_string(JSON.stringify(progress))


# ------------------------------------------------------------------ tutorial

func _tutorial_begin() -> void:
	tut_step = 0
	_tut = {}
	_coach_show()


func _coach_show() -> void:
	var st: Dictionary = TUTORIAL[tut_step]
	var target: Control = null
	match st.target:
		"meter": target = hud.meter_panel
		"add": target = hud.add_button
		"bets": target = hud.bets_row
		"help": target = hud.help_button
	hud.show_coach("[color=#ffd75e]Step %d of %d[/color]   %s" % [tut_step + 1, TUTORIAL.size(), st.text],
		st.wait == "next", target)


func _process(_delta: float) -> void:
	if tut_step >= 0 and _tutorial_condition(TUTORIAL[tut_step].wait):
		_coach_advance()


func _tutorial_condition(wait: String) -> bool:
	match wait:
		"floor10":
			return tower.active == 10
		"selected":
			return not tower.selection.is_empty()
		"spell":
			return not spell.is_empty()
		"cast":
			return _tut.get("cast", false)
		"tab":
			return _tut.get("tab", false)
	return false


func _coach_next() -> void:
	if tut_step >= 0 and TUTORIAL[tut_step].wait == "next":
		_coach_advance()


func _coach_advance() -> void:
	tut_step += 1
	if tut_step >= TUTORIAL.size():
		_tutorial_end(false)
		return
	audio.play("toggle", -4.0, 1.5)
	_coach_show()


func _tutorial_end(skipped: bool) -> void:
	if tut_step < 0 and skipped:
		return
	tut_step = -1
	hud.hide_coach()
	var first: bool = not progress.done.has("tutorial")
	progress.done["tutorial"] = true
	quest = {}
	_save_progress()
	_refresh_quests()
	_apply_tools()
	_update_info()
	if skipped:
		hud.say("Tutorial skipped. Press H for help any time.", Color(0.8, 0.8, 0.8), 4)
	else:
		hud.say("Tutorial complete! Quest 1 is unlocked.", Color(0.5, 1, 0.6), 5)
		if first:
			audio.play("quest")


# ------------------------------------------------------------------ readouts

func _update_meter() -> void:
	if scene.is_empty():
		return
	var answer := str(scene.answer).strip_edges()
	var after: bool = not tower.spell_lens.is_empty()
	var new_answer: String = _last_new_answer if after else answer
	hud.meter_subtitle.text = "of its answer, \"%s\"" % answer
	hud.legend_before.text = "\"%s\" normally" % answer
	hud.legend_after.text = "\"%s\" after spell" % new_answer
	hud.legend_after.get_parent().visible = after
	hud.meter.set_data(tower.clean_lens, tower.spell_lens, tower.active, answer, new_answer)


func _update_info() -> void:
	hud.xp_label.text = "XP %d   streak %d   quests %d/%d" % [
		int(progress.xp), int(progress.streak), progress.done.size(), quests.size()]
	if scene.is_empty():
		hud.info_label.text = "No scene loaded."
		return
	var colours: String = "ripple (what your spell changed)" if tower.mode == "ripple" else "activity (how hard each floor works)"
	hud.info_label.text = "Floor %d of %d   ·   %d cells selected   ·   tower colours: %s, Tab switches   ·   B board view   ·   H help" % [
		tower.active, tower.n_layers - 1, tower.selection.size(), colours]
	if spell.is_empty():
		hud.queue_label.text = "spell: empty"
	else:
		var parts := []
		for s in spell:
			parts.append("%s %d cells on floor %d" % [Hud.TOOL_NAMES[s.type], s.positions.size(), int(s.layer)])
		hud.queue_label.text = "spell: " + ", ".join(parts)


func _topk_text(topk: Array) -> String:
	var parts := []
	for t in topk.slice(0, 5):
		parts.append("%s [color=#8899aa]%d%%[/color]" % [_q(str(t.token).strip_edges()), roundi(100 * float(t.p))])
	return "   ".join(parts)


func _q(s) -> String:
	return "\"" + str(s).replace("[", "[lb]").replace("\n", "\\n") + "\""


func _show_clean() -> void:
	hud.answer_text.text = "[b]THE QUESTION[/b]\n%s\n\n[b]ITS ANSWER[/b]\n[font_size=22]%s[/font_size]\n\n[color=#8899aa]its top guesses for the first word:[/color]\n%s" % [
		scene.prompt.replace("[", "[lb]"), _q(scene.generation), _topk_text(scene.topk)]


func _show_result(res: Dictionary, prediction: String) -> void:
	var colors := {"nothing": "#8899aa", "nudge": "#9fd3ff", "shove": "#ffd75e", "flip": "#ff7a45"}
	var answer := str(res.clean_answer).strip_edges()
	var text := "[b]THE QUESTION[/b]\n%s\n\n[b]ITS ANSWER NOW[/b]\n[font_size=22][color=#ffb070]%s[/color][/font_size]\n(normally %s)\n\n" % [
		scene.prompt.replace("[", "[lb]"), _q(res.generation), _q(res.clean_generation)]
	text += "[color=%s][b]%s[/b][/color]" % [colors[res.outcome], res.outcome.to_upper()]
	if prediction != "":
		text += "   (you bet %s)" % prediction.to_upper()
	text += "\n%s\n\nConfidence in \"%s\": %d%% → %d%%\n\n[color=#8899aa]its top guesses now:[/color]\n%s\n\n" % [
		OUTCOME_SENTENCE[res.outcome], answer, roundi(100 * float(res.p_clean_answer.before)),
		roundi(100 * float(res.p_clean_answer.after)), _topk_text(res.topk)]
	text += "[color=#8899aa]The tower now shows the ripple: bright cells are where your spell spread. The meter's orange bars show how sure each floor is of the new answer.[/color]"
	hud.answer_text.text = text


# ------------------------------------------------------------------ autotest

func _autotest() -> void:
	## `godot --path godot -- --autotest`: play the tutorial, then quest 1, screenshot, quit.
	backend.blocking = true
	await start_quest(_quest_index("tutorial"))
	var locked_before: bool = not _quest_unlocked(_quest_index("soul-swap"))
	_coach_next()
	await _frames(10)
	_shot("user://autotest_tutorial.png")
	_coach_next()
	_set_floor(10)
	await _frames(2)
	_select_kind(["image"])
	await _frames(2)
	add_selection_to_spell()
	await _frames(2)
	await cast("flip")
	await _frames(2)
	tower.toggle_mode()
	_tut["tab"] = true
	await _frames(2)
	_coach_next()
	var tutorial_done: bool = progress.done.has("tutorial") and tut_step == -1

	await start_quest(_quest_index("soul-swap"))
	_set_floor(10)
	_select_kind(["image"])
	add_selection_to_spell()
	await cast("flip")
	hud.toggle_help()
	await _frames(5)
	_shot("user://autotest_help.png")
	hud.toggle_help()
	var probe := 20  # a picture cell: hover readout + highlight in the screenshot
	var at: Vector2 = camera.unproject_position(tower.cell_world(tower.cell_pos[probe], tower.active))
	_hover(at)
	await _frames(30)
	_shot("user://autotest.png")
	var pick_ok: bool = tower.hover == probe
	camera.toggle_board_view()
	tower.board_view = true
	tower.refresh()
	await _frames(40)
	var at2: Vector2 = camera.unproject_position(tower.cell_world(tower.cell_pos[probe], tower.active))
	_hover(at2)
	pick_ok = pick_ok and tower.hover == probe
	await _frames(2)
	_shot("user://autotest_board.png")
	camera.toggle_board_view()
	tower.board_view = false
	tower.refresh()
	print("AUTOTEST locked_before=%s tutorial_done=%s quests=%s tools=%s xp=%d pick_ok=%s hover=%s" % [
		locked_before, tutorial_done, str(progress.done.keys()), str(_unlocked_tools()), int(progress.xp),
		pick_ok, hud.hover_label.text.replace("\n", " | ")])
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _shot(path: String) -> void:
	get_viewport().get_texture().get_image().save_png(path)


# ------------------------------------------------------------------ recorded demo

## Scripted tour for recording a video:
##   godot --path godot --write-movie demo.avi --fixed-fps 30 -- --demo
func _demo() -> void:
	backend.blocking = true
	_caption("")
	await _wait(0.3)
	await start_quest(_quest_index("soul-swap"))
	camera.dist = 27.0
	camera.pitch = -0.32
	camera.yaw = 1.1
	_set_floor(0)
	_caption("Glassbox: inside SmolVLM-256M, a small vision-language model")
	await _turn(0.35, 4.5)
	_caption("Each floor of the tower is one of its 30 layers. The board is the picture as the model sees it.")
	await _wait(4.5)
	_caption("Asked \"What color is the shape?\" it answers \"Red.\"   Now climb, listening:")
	await _wait(3.5)
	_caption("Each note's pitch = how sure that floor already is of \"Red\" (the meter on the left)")
	for L in tower.n_layers:
		_set_floor(L)
		await _wait(0.24)
	await _wait(1.2)

	_set_floor(10)
	camera.dist = 20.0
	_caption("Quest 1: on floor 10, select every picture cell...")
	await _wait(2.5)
	_select_kind(["image"])
	await _wait(1.0)
	_caption("...and transplant in the state from a run on a BLUE circle")
	add_selection_to_spell()
	await _wait(2.0)
	_caption("Bet before casting. I predict FLIP: the answer will change.")
	await _wait(2.5)
	_caption("")
	await cast("flip")
	await _wait(1.5)
	_caption("\"Blue.\" Listen to the sweep: louder pings = floors the spell changed more (orange)")
	await _turn(1.6, 5.5)

	await start_quest(_quest_index("too-late"))
	_caption("Quest 3: transplant the picture higher up the tower. Floor 22 first...")
	_set_floor(22)
	await _wait(2.5)
	_select_kind(["image"])
	add_selection_to_spell()
	await _wait(1.0)
	await cast("flip")
	await _wait(3.5)
	_clear_spell()
	_caption("...now floor 23, one layer higher. I bet NOTHING happens.")
	_set_floor(23)
	await _wait(2.5)
	_select_kind(["image"])
	add_selection_to_spell()
	await _wait(1.0)
	await cast("nothing")
	await _wait(3.0)
	_caption("Still \"Red\". By floor 23 the colour has already left the picture cells.")
	await _wait(4.0)

	await start_quest(_quest_index("handoff"))
	_caption("Quest 4: so where did it go? Transplant only the LAST text cell, on floor 23")
	_set_floor(23)
	camera.yaw = 0.4
	await _wait(3.0)
	tower.selection = {tower.tokens.size() - 1: true}
	tower.refresh()
	_update_info()
	await _wait(1.0)
	add_selection_to_spell()
	await cast("flip")
	await _wait(3.5)
	_caption("One cell flips it. Floors 22 -> 23 are a handoff: picture cells -> answer position.")
	await _turn(-0.4, 5.0)
	_caption("Glassbox: bet, cast, listen, and build an intuition for what's inside.")
	await _wait(4.0)
	get_tree().quit()


func _caption(text: String) -> void:
	hud.caption.text = text
	hud.caption.visible = text != ""


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _turn(to_yaw: float, seconds: float) -> void:
	var tw := create_tween()
	tw.tween_property(camera, "yaw", to_yaw, seconds).set_trans(Tween.TRANS_SINE)
	await tw.finished
