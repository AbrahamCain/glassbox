extends Node
## WebSocket link to the Python backend. Reconnects on its own; `call_op` is awaitable.

signal connected
signal disconnected

const TIMEOUT_MS := 120000

var url := "ws://127.0.0.1:8765/ws"
var _ws := WebSocketPeer.new()
var _state := WebSocketPeer.STATE_CLOSED
var _next_id := 1
var _pending := {}  # id -> {"done": bool, "msg": Dictionary}
var _retry := 0.0


func _ready() -> void:
	_open()


func _open() -> void:
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 24  # scene replies carry a PNG and activation grids
	_ws.outbound_buffer_size = 1 << 20
	_ws.connect_to_url(url)


func is_open() -> bool:
	return _state == WebSocketPeer.STATE_OPEN


func _process(delta: float) -> void:
	_ws.poll()
	var s := _ws.get_ready_state()
	if s != _state:
		_state = s
		if s == WebSocketPeer.STATE_OPEN:
			connected.emit()
		elif s == WebSocketPeer.STATE_CLOSED:
			for id in _pending:
				_pending[id].msg = {"ok": false, "error": "backend disconnected"}
				_pending[id].done = true
			_pending.clear()
			disconnected.emit()
	if s == WebSocketPeer.STATE_OPEN:
		while _ws.get_available_packet_count() > 0:
			var msg = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
			if typeof(msg) != TYPE_DICTIONARY:
				continue
			var id := int(msg.get("id", 0))
			if _pending.has(id):
				_pending[id].msg = msg
				_pending[id].done = true
				_pending.erase(id)
	elif s == WebSocketPeer.STATE_CLOSED:
		_retry -= delta
		if _retry <= 0.0:
			_retry = 2.0
			_open()


## Send an op and wait for the reply: {"ok": bool, "data": {...}} or {"ok": false, "error": "..."}.
func call_op(op: String, payload := {}) -> Dictionary:
	if not is_open():
		return {"ok": false, "error": "backend not connected (run backend/run.ps1)"}
	var msg := payload.duplicate()
	msg["op"] = op
	msg["id"] = _next_id
	var box := {"done": false, "msg": {}}
	_pending[_next_id] = box
	_next_id += 1
	_ws.send_text(JSON.stringify(msg))
	var start := Time.get_ticks_msec()
	while not box.done:
		if Time.get_ticks_msec() - start > TIMEOUT_MS:
			return {"ok": false, "error": "timed out waiting for backend"}
		await get_tree().process_frame
	return box.msg
