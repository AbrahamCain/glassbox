extends Control
## Widgets only. main.gd owns the game state and wires these up.

signal load_pressed
signal add_pressed
signal clear_pressed
signal cast_pressed(prediction: String)
signal quest_selected(index: int)
signal hint_pressed
signal volume_changed(value: float)
signal music_toggled(on: bool)
signal floor_clicked(layer: int)
signal tool_changed(tool: String)
signal coach_next
signal coach_skip
signal unlock_all_toggled(on: bool)
signal replay_tutorial

const Meter := preload("res://scripts/meter.gd")

## Internal tool ids (what the backend calls them) -> what the player sees.
const TOOL_NAMES := {"ablate": "Erase", "patch": "Transplant", "steer": "Push"}
const TOOL_HELP := {
	"ablate": "ERASE: wipe the selected cells' state on this floor, replacing it with an average cell (or zeros).\nShows what the model loses without them.",
	"patch": "TRANSPLANT: copy the selected cells' state on this floor from a second run (the 'Transplant from' scene).\nIf the answer follows, those cells were carrying the information.",
	"steer": "PUSH: add a direction to the cells' state, the difference between how the model represents two words.\nStrength scales how hard you push.",
}
const OUTCOME_HELP := {
	"nothing": "NOTHING: confidence in the original answer moves by less than 5 points",
	"nudge": "NUDGE: it moves 5-30 points, but the answer stays the same",
	"shove": "SHOVE: it moves more than 30 points, but the answer stays the same",
	"flip": "FLIP: the model gives a different answer",
}
const HELP_TEXT := """[b]How to play[/b]
1. Climb to a floor  2. select cells  3. pick a tool and [i]Add to spell[/i]  4. bet on what will happen, which casts it.
Correct bets earn XP and streaks: your hit rate is how good your intuition is getting.

[b]Keys[/b]
[color=#ffd75e]W / S[/color] or arrows: climb up / down   ·   click a floor in the meter to jump there
[color=#ffd75e]Click / drag[/color]: select cells (Shift adds)   ·   [color=#ffd75e]A[/color] all picture cells   ·   [color=#ffd75e]T[/color] all text cells   ·   [color=#ffd75e]X[/color] clear selection
[color=#ffd75e]1 / 2 / 3[/color]: Erase / Transplant / Push   ·   [color=#ffd75e]Enter[/color]: add selection to spell
[color=#ffd75e]Tab[/color]: tower colours: activity / ripple   ·   [color=#ffd75e]B[/color]: board view (top-down)   ·   [color=#ffd75e]I[/color]: picture on/off
[color=#ffd75e]Right-drag[/color] orbit   ·   [color=#ffd75e]wheel[/color] zoom   ·   [color=#ffd75e]middle-drag[/color] pan   ·   [color=#ffd75e]M[/color] mute   ·   [color=#ffd75e]H[/color] this help

[b]Terms[/b]
[color=#9fd3ff]Floor[/color]: one layer of the model. Information flows upward; the answer is read off the top floor.
[color=#9fd3ff]Cell[/color]: one token. The 8x8 board is the picture cut into 64 cells; the strip in front is the text question.
[color=#9fd3ff]Cell state[/color]: the list of numbers the model holds for that cell on that floor (the 'residual stream').
[color=#9fd3ff]Activity colours[/color]: bright = this floor changed that cell's state a lot.
[color=#9fd3ff]Ripple colours[/color] (after a spell): bright = your spell changed that cell's state a lot, compared with normal.
[color=#9fd3ff]Meter[/color]: for each floor, how sure the model would be of its answer if it stopped there (a 'logit lens').
[color=#9fd3ff]Spell[/color]: the changes you've queued. One cast applies them all.
[color=#9fd3ff]Bets[/color]: NOTHING (<5 points of confidence), NUDGE (5-30), SHOVE (>30, same answer), FLIP (answer changes)."""

var status: Label
var xp_label: Label
var scene_a: OptionButton
var scene_b: OptionButton
var quest_list: ItemList
var quest_text: RichTextLabel
var answer_text: RichTextLabel
var meter: Control
var meter_panel: PanelContainer
var meter_subtitle: Label
var legend_before: Label
var legend_after: Label
var legend_after_swatch: ColorRect
var tools_row: HBoxContainer
var tool_buttons := {}
var tool_options := {}  # tool -> HBoxContainer of its settings
var ablate_mode: OptionButton
var transplant_from: Label
var steer_from: LineEdit
var steer_to: LineEdit
var steer_scale: HSlider
var add_button: Button
var bets_row: HBoxContainer
var help_button: Button
var queue_label: Label
var info_label: Label
var toast: Label
var caption: Label
var volume: HSlider
var music: CheckBox
var hover_label: Label
var coach: PanelContainer
var coach_text: RichTextLabel
var coach_next_button: Button
var help: PanelContainer
var unlock_all: CheckBox
var _highlight: Panel
var _highlight_target: Control
var _toast_left := 0.0
var _t := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_top()
	_build_left()
	_build_meter()
	_build_right()
	_build_bottom()
	_build_overlays()


# ------------------------------------------------------------------ layout

func _build_top() -> void:
	var top := _panel(Control.PRESET_TOP_WIDE)
	top.offset_bottom = 44
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	top.add_child(bar)
	status = Label.new()
	status.text = "connecting..."
	status.custom_minimum_size.x = 250
	bar.add_child(status)
	bar.add_child(_label("Scene"))
	scene_a = OptionButton.new()
	scene_a.custom_minimum_size.x = 170
	scene_a.tooltip_text = "The picture and question the model is working on"
	bar.add_child(scene_a)
	bar.add_child(_label("Transplant from"))
	scene_b = OptionButton.new()
	scene_b.custom_minimum_size.x = 170
	scene_b.tooltip_text = "A second run the Transplant tool copies cell states from.\nIt must ask the same question."
	bar.add_child(scene_b)
	bar.add_child(_button("Load", func(): load_pressed.emit(), "Load these scenes for free play (leaves the current quest)"))
	bar.add_child(VSeparator.new())
	bar.add_child(_label("Sound"))
	volume = HSlider.new()
	volume.min_value = 0.0
	volume.max_value = 1.0
	volume.step = 0.05
	volume.custom_minimum_size = Vector2(80, 0)
	volume.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	volume.focus_mode = Control.FOCUS_NONE
	volume.tooltip_text = "Volume (M mutes)"
	volume.value_changed.connect(func(v): volume_changed.emit(v))
	bar.add_child(volume)
	music = CheckBox.new()
	music.text = "Music"
	music.focus_mode = Control.FOCUS_NONE
	music.toggled.connect(func(on): music_toggled.emit(on))
	bar.add_child(music)
	help_button = _button("? Help  [H]", func(): toggle_help(), "Keys, terms and how to play")
	bar.add_child(help_button)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	xp_label = _label("XP 0")
	xp_label.add_theme_font_size_override("font_size", 18)
	bar.add_child(xp_label)


func _build_left() -> void:
	var left := _panel(Control.PRESET_LEFT_WIDE)
	left.offset_top = 52
	left.offset_right = 320
	left.offset_bottom = -178
	var lv := VBoxContainer.new()
	left.add_child(lv)
	lv.add_child(_label("QUESTS"))
	quest_list = ItemList.new()
	quest_list.custom_minimum_size.y = 230
	quest_list.item_selected.connect(func(i): quest_selected.emit(i))
	lv.add_child(quest_list)
	quest_text = _rich()
	quest_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lv.add_child(quest_text)
	lv.add_child(_button("Hint", func(): hint_pressed.emit()))


func _build_meter() -> void:
	meter_panel = _panel(Control.PRESET_LEFT_WIDE)
	meter_panel.offset_left = 328
	meter_panel.offset_right = 548
	meter_panel.offset_top = 52
	meter_panel.offset_bottom = -178
	var v := VBoxContainer.new()
	meter_panel.add_child(v)
	var title := _label("How sure is each floor?")
	title.add_theme_font_size_override("font_size", 15)
	v.add_child(title)
	meter_subtitle = _label("")
	meter_subtitle.add_theme_color_override("font_color", Color(0.7, 0.75, 0.85))
	meter_subtitle.add_theme_font_size_override("font_size", 13)
	v.add_child(meter_subtitle)
	var l1 := HBoxContainer.new()
	l1.add_theme_constant_override("separation", 6)
	l1.add_child(_swatch(Meter.BEFORE))
	legend_before = _small("normal")
	legend_before.clip_text = true
	legend_before.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l1.add_child(legend_before)
	v.add_child(l1)
	var l2 := HBoxContainer.new()
	l2.add_theme_constant_override("separation", 6)
	legend_after_swatch = _swatch(Meter.AFTER)
	l2.add_child(legend_after_swatch)
	legend_after = _small("after spell")
	legend_after.clip_text = true
	legend_after.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l2.add_child(legend_after)
	v.add_child(l2)
	meter = Meter.new()
	meter.size_flags_vertical = Control.SIZE_EXPAND_FILL
	meter.floor_clicked.connect(func(L): floor_clicked.emit(L))
	v.add_child(meter)
	var foot := _small("top floor ↑   ·   click a row to go there")
	foot.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
	v.add_child(foot)


func _build_right() -> void:
	var right := _panel(Control.PRESET_RIGHT_WIDE)
	right.offset_top = 52
	right.offset_left = -360
	right.offset_bottom = -178
	answer_text = _rich()
	right.add_child(answer_text)


func _build_bottom() -> void:
	var bottom := _panel(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -170
	var bv := VBoxContainer.new()
	bottom.add_child(bv)
	info_label = _label("")
	bv.add_child(info_label)

	tools_row = HBoxContainer.new()
	tools_row.add_theme_constant_override("separation", 8)
	bv.add_child(tools_row)
	tools_row.add_child(_label("Tool:"))
	var group := ButtonGroup.new()
	var keys := {"ablate": 1, "patch": 2, "steer": 3}
	for t in ["ablate", "patch", "steer"]:
		var b := Button.new()
		b.text = "%s [%d]" % [TOOL_NAMES[t], keys[t]]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.custom_minimum_size.x = 120
		b.tooltip_text = TOOL_HELP[t]
		b.toggled.connect(func(on): _tool_toggled(on, t))
		tools_row.add_child(b)
		tool_buttons[t] = b
	tools_row.add_child(VSeparator.new())

	var erase := HBoxContainer.new()
	erase.add_child(_label("replace with"))
	ablate_mode = OptionButton.new()
	ablate_mode.add_item("an average cell")
	ablate_mode.add_item("zeros")
	ablate_mode.focus_mode = Control.FOCUS_NONE
	ablate_mode.tooltip_text = "Average: the mean state of cells of the same kind in this scene.\nZeros: blank them entirely (harsher, can confuse the model)."
	erase.add_child(ablate_mode)
	tools_row.add_child(erase)
	tool_options["ablate"] = erase

	var transplant := HBoxContainer.new()
	transplant_from = _label("copying from: (nothing loaded)")
	transplant.add_child(transplant_from)
	tools_row.add_child(transplant)
	tool_options["patch"] = transplant

	var push := HBoxContainer.new()
	push.add_theme_constant_override("separation", 6)
	push.add_child(_label("from word"))
	steer_from = _line(" red")
	steer_from.tooltip_text = "Leading spaces matter: \" red\" is the word as it appears mid-sentence."
	push.add_child(steer_from)
	push.add_child(_label("towards"))
	steer_to = _line(" blue")
	steer_to.tooltip_text = steer_from.tooltip_text
	push.add_child(steer_to)
	push.add_child(_label("strength"))
	steer_scale = HSlider.new()
	steer_scale.min_value = 0.5
	steer_scale.max_value = 12
	steer_scale.step = 0.5
	steer_scale.value = 4
	steer_scale.focus_mode = Control.FOCUS_NONE
	steer_scale.custom_minimum_size.x = 140
	steer_scale.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	push.add_child(steer_scale)
	var scale_label := _label("4.0")
	steer_scale.value_changed.connect(func(v): scale_label.text = "%.1f" % v)
	push.add_child(scale_label)
	tools_row.add_child(push)
	tool_options["steer"] = push

	var spell := HBoxContainer.new()
	spell.add_theme_constant_override("separation", 8)
	bv.add_child(spell)
	add_button = _button("Add to spell  [Enter]", func(): add_pressed.emit(),
		"Queue the selected cells with the current tool on this floor.\nYou can add from several floors and tools before casting.")
	spell.add_child(add_button)
	spell.add_child(_button("Clear spell", func(): clear_pressed.emit()))
	queue_label = _label("spell: empty")
	queue_label.custom_minimum_size.x = 520
	queue_label.clip_text = true
	spell.add_child(queue_label)

	bets_row = HBoxContainer.new()
	bets_row.add_theme_constant_override("separation", 8)
	bv.add_child(bets_row)
	bets_row.add_child(_label("Bet on what happens to the answer, then cast:"))
	for o in ["nothing", "nudge", "shove", "flip"]:
		var b := _button(o.to_upper(), func(): cast_pressed.emit(o), OUTCOME_HELP[o])
		b.custom_minimum_size.x = 100
		bets_row.add_child(b)
	bets_row.add_child(_button("cast without betting", func(): cast_pressed.emit(""), "Cast for no XP"))
	_on_tool_toggled("patch")


func _build_overlays() -> void:
	# demo captions
	caption = Label.new()
	caption.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	caption.offset_bottom = -186
	caption.offset_top = -236
	caption.grow_horizontal = Control.GROW_DIRECTION_BOTH
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 24)
	caption.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0.72)))
	caption.visible = false
	add_child(caption)

	# tutorial coach
	coach = PanelContainer.new()
	var csb := _box(Color(0.08, 0.07, 0.03, 0.95))
	csb.border_color = Color(1, 0.85, 0.3)
	csb.set_border_width_all(2)
	coach.add_theme_stylebox_override("panel", csb)
	add_child(coach)
	coach.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	coach.offset_left = 566  # in the open space over the tower, clear of the meter and side panels
	coach.offset_right = 1226
	coach.offset_bottom = -186
	coach.offset_top = -330
	coach.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var cv := VBoxContainer.new()
	coach.add_child(cv)
	coach_text = RichTextLabel.new()
	coach_text.bbcode_enabled = true
	coach_text.fit_content = true
	coach_text.custom_minimum_size = Vector2(636, 0)
	coach_text.add_theme_font_size_override("normal_font_size", 17)
	coach_text.add_theme_font_size_override("bold_font_size", 17)
	cv.add_child(coach_text)
	var cb := HBoxContainer.new()
	cb.alignment = BoxContainer.ALIGNMENT_END
	cb.add_child(_button("Skip tutorial", func(): coach_skip.emit()))
	coach_next_button = _button("Next  →", func(): coach_next.emit())
	cb.add_child(coach_next_button)
	cv.add_child(cb)
	coach.visible = false

	_highlight = Panel.new()
	var hsb := StyleBoxFlat.new()
	hsb.draw_center = false
	hsb.border_color = Color(1, 0.85, 0.3)
	hsb.set_border_width_all(3)
	hsb.set_corner_radius_all(6)
	_highlight.add_theme_stylebox_override("panel", hsb)
	_highlight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_highlight.visible = false
	add_child(_highlight)

	# help sheet
	help = PanelContainer.new()
	help.add_theme_stylebox_override("panel", _box(Color(0.03, 0.04, 0.08, 0.97)))
	add_child(help)
	help.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	help.offset_left = -470
	help.offset_right = 470
	help.offset_top = -330
	help.offset_bottom = 330
	var hv := VBoxContainer.new()
	help.add_child(hv)
	var ht := _rich()
	ht.text = HELP_TEXT
	hv.add_child(ht)
	var hb := HBoxContainer.new()
	unlock_all = CheckBox.new()
	unlock_all.text = "Unlock all quests and tools (skip the progression)"
	unlock_all.focus_mode = Control.FOCUS_NONE
	unlock_all.toggled.connect(func(on): unlock_all_toggled.emit(on))
	hb.add_child(unlock_all)
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hb.add_child(sp)
	hb.add_child(_button("Replay tutorial", _on_replay))
	hb.add_child(_button("Close  [H]", func(): help.visible = false))
	hv.add_child(hb)
	help.visible = false

	# cell readout under the mouse
	hover_label = Label.new()
	hover_label.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0.8)))
	hover_label.add_theme_font_size_override("font_size", 14)
	hover_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hover_label.visible = false
	add_child(hover_label)

	toast = Label.new()
	toast.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	toast.offset_left = 566  # centred over the tower, between the meter and the answer panel
	toast.offset_right = 1226
	toast.offset_top = 62
	toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.add_theme_font_size_override("font_size", 24)
	toast.add_theme_color_override("font_outline_color", Color.BLACK)
	toast.add_theme_constant_override("outline_size", 8)
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(toast)


# ------------------------------------------------------------------ behaviour

func _process(delta: float) -> void:
	_t += delta
	if _toast_left > 0:
		_toast_left -= delta
		toast.modulate.a = clampf(_toast_left, 0, 1)
	if _highlight_target and is_instance_valid(_highlight_target) and _highlight_target.is_visible_in_tree():
		var r := _highlight_target.get_global_rect().grow(5)
		_highlight.position = r.position
		_highlight.size = r.size
		_highlight.visible = true
		_highlight.modulate.a = 0.55 + 0.45 * sin(_t * 5.0)
	else:
		_highlight.visible = false


func say(text: String, color := Color.WHITE, seconds := 3.5) -> void:
	toast.text = text
	toast.add_theme_color_override("font_color", color)
	_toast_left = seconds


func show_coach(text: String, show_next: bool, target: Control) -> void:
	coach_text.text = text
	coach_next_button.visible = show_next
	coach.visible = true
	_highlight_target = target


func hide_coach() -> void:
	coach.visible = false
	_highlight_target = null


func _on_replay() -> void:
	help.visible = false
	replay_tutorial.emit()


func toggle_help() -> void:
	help.visible = not help.visible
	if help.visible:
		_toast_left = 0.0
		toast.modulate.a = 0.0


func show_hover(text: String, at: Vector2) -> void:
	hover_label.text = text
	hover_label.position = at + Vector2(18, 18)
	hover_label.visible = text != ""


func current_tool() -> String:
	for t in tool_buttons:
		if tool_buttons[t].button_pressed:
			return t
	return "patch"


func select_tool(t: String) -> void:
	if tool_buttons.has(t) and tool_buttons[t].visible:
		tool_buttons[t].button_pressed = true


## Show only these tools; if the current one is hidden, switch to the first that isn't.
func set_tools(available: Array) -> void:
	for t in tool_buttons:
		tool_buttons[t].visible = t in available
	if not current_tool() in available and not available.is_empty():
		tool_buttons[available[0]].button_pressed = true
	_on_tool_toggled(current_tool())


func _tool_toggled(on: bool, t: String) -> void:
	if on:
		_on_tool_toggled(t)


func _on_tool_toggled(t: String) -> void:
	for k in tool_options:
		tool_options[k].visible = k == t
	tool_changed.emit(t)


func any_text_focused() -> bool:
	return get_viewport().gui_get_focus_owner() is LineEdit


# ------------------------------------------------------------------ widget helpers

func _box(color: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(10)
	return sb


func _panel(preset: int) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := _box(Color(0.04, 0.05, 0.09, 0.86))
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", sb)
	add_child(p)
	p.set_anchors_and_offsets_preset(preset)
	return p


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _small(text: String) -> Label:
	var l := _label(text)
	l.add_theme_font_size_override("font_size", 12)
	return l


func _swatch(c: Color) -> ColorRect:
	var r := ColorRect.new()
	r.color = c
	r.custom_minimum_size = Vector2(12, 12)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r


func _button(text: String, cb: Callable, tip := "") -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = tip
	return b


func _line(text: String) -> LineEdit:
	var e := LineEdit.new()
	e.text = text
	e.custom_minimum_size.x = 90
	return e


func _rich() -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.scroll_active = true
	r.size_flags_vertical = Control.SIZE_EXPAND_FILL
	r.custom_minimum_size = Vector2(0, 120)
	return r
