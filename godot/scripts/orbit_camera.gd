extends Camera3D
## Right-drag to orbit, wheel to zoom, middle-drag to pan. Glides to whatever it is told to focus on.

var yaw := 0.5
var pitch := -0.55
var dist := 20.0
var _target := Vector3.ZERO
var _goal := Vector3.ZERO
var _pan := Vector3.ZERO


func focus(point: Vector3) -> void:
	_goal = point


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion:
		if e.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			yaw -= e.relative.x * 0.005
			pitch = clampf(pitch - e.relative.y * 0.005, -1.5, 0.4)
		elif e.button_mask & MOUSE_BUTTON_MASK_MIDDLE:
			var right := global_transform.basis.x
			var fwd := Vector3(sin(yaw), 0, cos(yaw))
			_pan += (-right * e.relative.x + fwd * -e.relative.y) * dist * 0.0015
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = maxf(3.0, dist * 0.9)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = minf(90.0, dist * 1.1)


func _process(delta: float) -> void:
	_target = _target.lerp(_goal + _pan, 1.0 - exp(-delta * 8.0))
	var offset := Vector3(cos(pitch) * sin(yaw), -sin(pitch), cos(pitch) * cos(yaw)) * dist
	global_position = _target + offset
	look_at(_target, Vector3.UP)
