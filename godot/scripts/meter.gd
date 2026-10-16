extends Control
## Confidence meter: one row per floor (top floor at the top). The blue bar is how sure that
## floor already is of the model's normal answer (logit lens). After a spell, an orange bar
## shows how sure the floor is of the answer the model gives *after* the spell (the same
## answer if it didn't flip). Click a row to go to that floor.

signal floor_clicked(layer: int)

const BEFORE := Color(0.3, 0.65, 1.0)
const AFTER := Color(1.0, 0.5, 0.15)
const LABEL_W := 30.0
const GUESS_W := 64.0

var clean: Array = []
var spell: Array = []
var active := 0
var answer := ""
var new_answer := ""
var _hover := -1


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	tooltip_text = " "  # non-empty so _get_tooltip is used


func set_data(clean_lens: Array, spell_lens: Array, active_floor: int, answer_text: String, new_text := "") -> void:
	new_answer = new_text if new_text != "" else answer_text
	clean = clean_lens
	spell = spell_lens
	active = active_floor
	answer = answer_text
	queue_redraw()


func _row_h() -> float:
	return size.y / maxf(clean.size(), 1)


func _row_at(y: float) -> int:
	if clean.is_empty():
		return -1
	var L := clean.size() - 1 - floori(y / _row_h())
	return L if L >= 0 and L < clean.size() else -1


func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		var L := _row_at(e.position.y)
		if L != _hover:
			_hover = L
			queue_redraw()
	elif e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		var L := _row_at(e.position.y)
		if L >= 0:
			floor_clicked.emit(L)
			accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT and _hover != -1:
		_hover = -1
		queue_redraw()


func _get_tooltip(at: Vector2) -> String:
	var L := _row_at(at.y)
	if L < 0:
		return ""
	var t := "Floor %d\nIf the model had to answer here, its top guess would be %s.\nConfidence in %s: %d%%" % [
		L, _quoted(clean[L].top[0].token), _quoted(answer), roundi(100 * float(clean[L].p_answer))]
	if not spell.is_empty():
		t += "\nAfter your spell: guess %s, confidence in %s: %d%%" % [
			_quoted(spell[L].top[0].token), _quoted(new_answer), roundi(100 * float(spell[L].p_new))]
	return t + "\n(click to go to this floor)"


func _draw() -> void:
	if clean.is_empty():
		return
	var font := get_theme_default_font()
	var fs := clampi(int(_row_h() * 0.62), 9, 14)
	var h := _row_h()
	var bar_x := LABEL_W
	var bar_w := maxf(size.x - LABEL_W - GUESS_W - 6, 10)
	var n := clean.size()
	for L in n:
		var y := (n - 1 - L) * h
		if L == active:
			draw_rect(Rect2(0, y, size.x, h), Color(1, 0.85, 0.3, 0.2))
		elif L == _hover:
			draw_rect(Rect2(0, y, size.x, h), Color(1, 1, 1, 0.08))
		var text_y := y + h * 0.5 + fs * 0.36
		var num_col := Color(1, 0.88, 0.4) if L == active else Color(0.6, 0.66, 0.75)
		draw_string(font, Vector2(2, text_y), str(L), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, num_col)
		draw_rect(Rect2(bar_x, y + 1, bar_w, h - 2), Color(1, 1, 1, 0.05))
		var pc := float(clean[L].p_answer)
		if spell.is_empty():
			draw_rect(Rect2(bar_x, y + 2, bar_w * pc, h - 4), BEFORE)
		else:
			var half := (h - 4) / 2.0
			draw_rect(Rect2(bar_x, y + 2, bar_w * pc, half), BEFORE)
			draw_rect(Rect2(bar_x, y + 2 + half, bar_w * float(spell[L].p_new), half), AFTER)
		var lens: Array = spell if not spell.is_empty() else clean
		var guess := str(lens[L].top[0].token).strip_edges()
		var target := new_answer if not spell.is_empty() else answer
		var match_answer := guess.to_lower() == target.strip_edges().to_lower()
		var guess_col := Color(0.55, 1, 0.65) if match_answer else Color(0.7, 0.72, 0.8, 0.8)
		if guess.length() > 7:
			guess = guess.substr(0, 6) + "…"
		draw_string(font, Vector2(bar_x + bar_w + 6, text_y), guess, HORIZONTAL_ALIGNMENT_LEFT, GUESS_W, fs, guess_col)


func _quoted(s) -> String:
	return "\"" + str(s).strip_edges() + "\""
