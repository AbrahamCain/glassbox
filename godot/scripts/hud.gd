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

const OUTCOME_HELP := {
	"nothing": "p(clean answer) moves by less than 5 points",
	"nudge": "moves 5-30 points, answer unchanged",
	"shove": "moves more than 30 points, answer unchanged",
	"flip": "the top answer changes",
}

var status: Label
var xp_label: Label
var scene_a: OptionButton
var scene_b: OptionButton
var quest_list: ItemList
var quest_text: RichTextLabel
var answer_text: RichTextLabel
var tool_buttons := {}
var ablate_mode: OptionButton
var steer_from: LineEdit
var steer_to: LineEdit
var steer_scale: HSlider
var queue_label: Label
var info_label: Label
var toast: Label
var caption: Label
var volume: HSlider
var music: CheckBox
var _toast_left := 0.0


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# --- top bar
	var top := _panel(Control.PRESET_TOP_WIDE)
	top.offset_bottom = 44
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	top.add_child(bar)
	status = Label.new()
	status.text = "connecting..."
	status.custom_minimum_size.x = 340
	bar.add_child(status)
	bar.add_child(_label("Scene"))
	scene_a = OptionButton.new()
	scene_a.custom_minimum_size.x = 180
	bar.add_child(scene_a)
	bar.add_child(_label("Patch source"))
	scene_b = OptionButton.new()
	scene_b.custom_minimum_size.x = 180
	bar.add_child(scene_b)
	bar.add_child(_button("Load", func(): load_pressed.emit()))
	bar.add_child(VSeparator.new())
	bar.add_child(_label("Sound"))
	volume = HSlider.new()
	volume.min_value = 0.0
	volume.max_value = 1.0
	volume.step = 0.05
	volume.custom_minimum_size = Vector2(90, 0)
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
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(spacer)
	xp_label = _label("XP 0")
	xp_label.add_theme_font_size_override("font_size", 20)
	bar.add_child(xp_label)

	# --- left: quests
	var left := _panel(Control.PRESET_LEFT_WIDE)
	left.offset_top = 52
	left.offset_right = 320
	left.offset_bottom = -178
	var lv := VBoxContainer.new()
	left.add_child(lv)
	lv.add_child(_label("QUESTS"))
	quest_list = ItemList.new()
	quest_list.custom_minimum_size.y = 210
	quest_list.item_selected.connect(func(i): quest_selected.emit(i))
	lv.add_child(quest_list)
	quest_text = _rich()
	quest_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	lv.add_child(quest_text)
	lv.add_child(_button("Hint", func(): hint_pressed.emit()))

	# --- right: answers
	var right := _panel(Control.PRESET_RIGHT_WIDE)
	right.offset_top = 52
	right.offset_left = -360
	right.offset_bottom = -178
	answer_text = _rich()
	right.add_child(answer_text)

	# --- bottom: tools, spell, bets
	var bottom := _panel(Control.PRESET_BOTTOM_WIDE)
	bottom.offset_top = -170
	var bv := VBoxContainer.new()
	bottom.add_child(bv)
	info_label = _label("")
	bv.add_child(info_label)

	var tools := HBoxContainer.new()
	tools.add_theme_constant_override("separation", 8)
	bv.add_child(tools)
	var group := ButtonGroup.new()
	for t in ["ablate", "patch", "steer"]:
		var b := Button.new()
		b.text = "%s [%d]" % [t.capitalize(), ["ablate", "patch", "steer"].find(t) + 1]
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size.x = 100
		tools.add_child(b)
		tool_buttons[t] = b
	tool_buttons["patch"].button_pressed = true
	tools.add_child(VSeparator.new())
	tools.add_child(_label("ablate with"))
	ablate_mode = OptionButton.new()
	ablate_mode.add_item("mean")
	ablate_mode.add_item("zero")
	tools.add_child(ablate_mode)
	tools.add_child(VSeparator.new())
	tools.add_child(_label("steer"))
	steer_from = _line(" red")
	tools.add_child(steer_from)
	tools.add_child(_label("->"))
	steer_to = _line(" blue")
	tools.add_child(steer_to)
	tools.add_child(_label("strength"))
	steer_scale = HSlider.new()
	steer_scale.min_value = 0.5
	steer_scale.max_value = 12
	steer_scale.step = 0.5
	steer_scale.value = 4
	steer_scale.custom_minimum_size.x = 140
	tools.add_child(steer_scale)
	var scale_label := _label("4.0")
	steer_scale.value_changed.connect(func(v): scale_label.text = "%.1f" % v)
	tools.add_child(scale_label)

	var spell := HBoxContainer.new()
	spell.add_theme_constant_override("separation", 8)
	bv.add_child(spell)
	spell.add_child(_button("Add to spell [Enter]", func(): add_pressed.emit()))
	spell.add_child(_button("Clear spell", func(): clear_pressed.emit()))
	queue_label = _label("spell: empty")
	queue_label.custom_minimum_size.x = 420
	queue_label.clip_text = true
	spell.add_child(queue_label)

	var bets := HBoxContainer.new()
	bets.add_theme_constant_override("separation", 8)
	bv.add_child(bets)
	bets.add_child(_label("Predict, then cast:"))
	for o in ["nothing", "nudge", "shove", "flip"]:
		var b := _button(o.to_upper(), func(): cast_pressed.emit(o))
		b.tooltip_text = OUTCOME_HELP[o]
		b.custom_minimum_size.x = 100
		bets.add_child(b)
	bets.add_child(_button("cast without betting", func(): cast_pressed.emit("")))

	# --- caption (used by the recorded demo)
	caption = Label.new()
	caption.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	caption.offset_bottom = -186
	caption.offset_top = -236
	caption.grow_horizontal = Control.GROW_DIRECTION_BOTH
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.add_theme_font_size_override("font_size", 24)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0, 0, 0, 0.72)
	csb.set_corner_radius_all(6)
	csb.set_content_margin_all(10)
	caption.add_theme_stylebox_override("normal", csb)
	caption.visible = false
	add_child(caption)

	# --- toast
	toast = Label.new()
	toast.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	toast.offset_top = 70
	toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	toast.add_theme_font_size_override("font_size", 26)
	toast.add_theme_color_override("font_outline_color", Color.BLACK)
	toast.add_theme_constant_override("outline_size", 8)
	toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	add_child(toast)


func _process(delta: float) -> void:
	if _toast_left > 0:
		_toast_left -= delta
		toast.modulate.a = clampf(_toast_left, 0, 1)


func say(text: String, color := Color.WHITE, seconds := 3.5) -> void:
	toast.text = text
	toast.add_theme_color_override("font_color", color)
	_toast_left = seconds


func current_tool() -> String:
	for t in tool_buttons:
		if tool_buttons[t].button_pressed:
			return t
	return "patch"


func any_text_focused() -> bool:
	var f := get_viewport().gui_get_focus_owner()
	return f is LineEdit


func _panel(preset: int) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.04, 0.05, 0.09, 0.86)
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override("panel", sb)
	add_child(p)
	p.set_anchors_and_offsets_preset(preset)
	return p


func _label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	return l


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	b.focus_mode = Control.FOCUS_NONE
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
