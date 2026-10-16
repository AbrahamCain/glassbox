extends Node
## All sound is synthesised at startup: no audio files. Effects play through a small
## voice pool on the SFX bus (light reverb); an ambient drone loops on the Music bus.
##
## Sounds that carry information:
##   floor tone   pitch = p(clean answer) at the active floor, read by the logit lens
##   ripple sweep after a cast, one ping per floor rising up the tower, louder where
##                the spell changed more

const RATE := 44100
const DRONE_RATE := 22050
const DRONE_SECONDS := 8.0  # every drone frequency completes whole cycles in this time
const VOICES := 14
# A minor pentatonic over two octaves from A3: p(answer) 0..1 maps onto it.
const SCALE := [220.0, 261.63, 293.66, 329.63, 392.0, 440.0, 523.25, 587.33, 659.25, 783.99, 880.0]
const PING_HZ := 440.0  # "ping" and "glass" are pitched by pitch_scale from this base

var volume := 0.8
var muted := false
var music := true

var _sfx := {}
var _voices: Array[AudioStreamPlayer] = []
var _next := 0
var _drone: AudioStreamPlayer
var _drone_tween: Tween
var _rng := RandomNumberGenerator.new()
var _sweep_id := 0


func _ready() -> void:
	_rng.seed = 7
	_make_bus("Music", -14.0, false)
	_make_bus("SFX", -3.0, true)
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_voices.append(p)
	_build_sfx()
	_drone = AudioStreamPlayer.new()
	_drone.bus = "Music"
	_drone.stream = _build_drone()
	add_child(_drone)
	apply_settings()


# ------------------------------------------------------------------ public

func apply_settings() -> void:
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.001)))
	AudioServer.set_bus_mute(0, muted)
	if music and not _drone.playing:
		_drone.play()
	elif not music and _drone.playing:
		_drone.stop()


func play(name: String, db := 0.0, pitch := 1.0) -> void:
	if not _sfx.has(name):
		return
	var p := _voices[_next]
	_next = (_next + 1) % VOICES
	p.stream = _sfx[name]
	p.volume_db = db
	p.pitch_scale = pitch
	p.play()


## The note for the floor you're standing on: higher = the model is surer of the clean answer.
func floor_tone(p_answer: float) -> void:
	var idx := clampi(roundi(p_answer * (SCALE.size() - 1)), 0, SCALE.size() - 1)
	play("glass", -4.0, SCALE[idx] / PING_HZ)


## Drone rises slightly as you climb (frac 0 = ground floor, 1 = top).
func set_floor(frac: float) -> void:
	if _drone_tween:
		_drone_tween.kill()
	_drone_tween = create_tween()
	_drone_tween.tween_property(_drone, "pitch_scale", 1.0 + 0.26 * clampf(frac, 0, 1), 0.6)


## Outcome sting, then the verdict on your bet, then the ripple sweep, then any quest fanfare.
func cast_result(outcome: String, bet: String, quest_done: bool, ripple: Array) -> void:
	play("outcome_" + outcome)
	await get_tree().create_timer(0.45).timeout
	if bet != "":
		play("bet_" + bet)
		await get_tree().create_timer(0.35).timeout
	await ripple_sweep(ripple)
	if quest_done:
		play("quest")


func ripple_sweep(ripple: Array) -> void:
	_sweep_id += 1
	var me := _sweep_id
	var n := ripple.size()
	for L in n:
		if me != _sweep_id:
			return  # a newer cast started its own sweep
		var row: Array = ripple[L]
		var total := 0.0
		for v in row:
			total += float(v)
		var strength := clampf(sqrt(total / maxf(row.size(), 1)) * 1.6, 0.0, 1.0)
		if strength > 0.04:
			var pitch := pow(2.0, 2.0 * L / maxf(n - 1, 1)) * 0.5  # two octaves bottom to top
			play("ping", linear_to_db(0.15 + 0.85 * strength) - 6.0, pitch)
		await get_tree().create_timer(0.045).timeout


# ------------------------------------------------------------------ buses

func _make_bus(bus_name: String, db: float, reverb: bool) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	AudioServer.add_bus()
	var i := AudioServer.bus_count - 1
	AudioServer.set_bus_name(i, bus_name)
	AudioServer.set_bus_send(i, "Master")
	AudioServer.set_bus_volume_db(i, db)
	if reverb:
		var r := AudioEffectReverb.new()
		r.room_size = 0.55
		r.damping = 0.4
		r.wet = 0.18
		r.dry = 1.0
		AudioServer.add_bus_effect(i, r)


# ------------------------------------------------------------------ synthesis

func _build_sfx() -> void:
	var b: PackedFloat32Array

	b = _buf(0.05)
	_note(b, 0.0, 1760.0, 0.035, 0.16, "sine")
	_sfx.select = _wav(b)

	b = _buf(0.22)
	_note(b, 0.0, 523.25, 0.09, 0.2, "tri")
	_note(b, 0.06, 783.99, 0.15, 0.2, "tri")
	_sfx.add = _wav(b)

	b = _buf(0.07)
	_note(b, 0.0, 880.0, 0.06, 0.13, "tri", -0.5)
	_sfx.toggle = _wav(b)

	b = _buf(0.22)
	_note(b, 0.0, 110.0, 0.2, 0.16, "square")
	_note(b, 0.0, 116.5, 0.2, 0.13, "square")
	_sfx.error = _wav(b)

	b = _buf(0.5)
	_whoosh(b, 0.0, 0.45, 0.35, 300.0, 4500.0)
	_note(b, 0.05, 220.0, 0.4, 0.12, "sine", 1.0)
	_sfx.cast = _wav(b)

	# outcome stings: what the spell did
	b = _buf(0.4)
	_note(b, 0.0, 196.0, 0.35, 0.28, "sine", -0.3)
	_sfx.outcome_nothing = _wav(b)

	b = _buf(0.4)
	_note(b, 0.0, 392.0, 0.18, 0.2, "tri")
	_note(b, 0.11, 440.0, 0.26, 0.2, "tri")
	_sfx.outcome_nudge = _wav(b)

	b = _buf(0.7)
	for f in [220.0, 261.63, 329.63]:
		_note(b, 0.0, f, 0.65, 0.13, "tri")
	_whoosh(b, 0.0, 0.4, 0.15, 150.0, 900.0)
	_sfx.outcome_shove = _wav(b)

	b = _buf(1.0)
	var arp := [440.0, 554.37, 659.25, 880.0]
	for i in arp.size():
		_note(b, i * 0.07, arp[i], 0.5, 0.16, "bell")
	_note(b, 0.28, 1760.0, 0.7, 0.07, "bell")
	_sfx.outcome_flip = _wav(b)

	# verdict on your bet
	b = _buf(0.75)
	_note(b, 0.0, 1046.5, 0.6, 0.18, "bell")
	_note(b, 0.09, 1318.5, 0.65, 0.18, "bell")
	_sfx.bet_right = _wav(b)

	b = _buf(0.6)
	_note(b, 0.0, 880.0, 0.45, 0.12, "bell")
	_note(b, 0.1, 987.77, 0.45, 0.12, "bell")
	_sfx.bet_close = _wav(b)

	b = _buf(0.5)
	_note(b, 0.0, 329.63, 0.2, 0.16, "tri")
	_note(b, 0.16, 311.13, 0.32, 0.16, "tri", -0.1)
	_sfx.bet_wrong = _wav(b)

	b = _buf(1.8)
	var fan := [523.25, 659.25, 783.99]
	for i in fan.size():
		_note(b, i * 0.12, fan[i], 0.25, 0.16, "tri")
	for f in [523.25, 659.25, 783.99, 1046.5]:
		_note(b, 0.4, f, 1.3, 0.1, "bell")
	_sfx.quest = _wav(b)

	b = _buf(0.6)
	_note(b, 0.0, PING_HZ, 0.55, 0.22, "bell")
	_sfx.glass = _wav(b)

	b = _buf(0.2)
	_note(b, 0.0, PING_HZ, 0.18, 0.2, "bell")
	_sfx.ping = _wav(b)


func _build_drone() -> AudioStreamWAV:
	# Frequencies x 8 s are all whole numbers, so the loop point is seamless.
	var partials := [[55.0, 0.30, 0.125], [55.125, 0.22, 0.25], [82.5, 0.16, 0.375],
		[110.0, 0.12, 0.125], [165.0, 0.06, 0.25], [220.0, 0.03, 0.5]]
	var n := int(DRONE_SECONDS * DRONE_RATE)
	var buf := PackedFloat32Array()
	buf.resize(n)
	for k in n:
		var t := k / float(DRONE_RATE)
		var s := 0.0
		for p in partials:
			var lfo := 0.65 + 0.35 * sin(TAU * p[2] * t)  # slow swell, whole cycles per loop
			s += p[1] * lfo * sin(TAU * p[0] * t)
		buf[k] = s * 0.8
	var w := _wav(buf, DRONE_RATE)
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = n
	return w


func _buf(seconds: float) -> PackedFloat32Array:
	var b := PackedFloat32Array()
	b.resize(int(seconds * RATE) + 1)
	b.fill(0.0)
	return b


func _env(t: float, dur: float, attack: float) -> float:
	if t < attack:
		return t / attack
	var x := 1.0 - (t - attack) / maxf(dur - attack, 1e-4)
	return x * x


## Add a note to `b`. wave: sine | tri | square | bell. sweep = octaves of glide over the note.
func _note(b: PackedFloat32Array, start: float, freq: float, dur: float, vol: float, wave: String, sweep := 0.0) -> void:
	var i0 := int(start * RATE)
	var n := mini(int(dur * RATE), b.size() - i0)
	var phase := 0.0
	for k in n:
		var t := k / float(RATE)
		phase += TAU * freq * pow(2.0, sweep * t / dur) / RATE
		var s: float
		match wave:
			"tri":
				s = 2.0 / PI * asin(sin(phase))
			"square":
				s = 0.6 * signf(sin(phase))
			"bell":  # inharmonic partials that die away fast: a glassy strike
				s = sin(phase) + 0.4 * sin(phase * 2.76) * exp(-t * 7.0) + 0.2 * sin(phase * 5.4) * exp(-t * 14.0)
			_:
				s = sin(phase)
		b[i0 + k] += s * vol * _env(t, dur, 0.004)


## Low-passed noise whose cutoff sweeps f0 -> f1.
func _whoosh(b: PackedFloat32Array, start: float, dur: float, vol: float, f0: float, f1: float) -> void:
	var i0 := int(start * RATE)
	var n := mini(int(dur * RATE), b.size() - i0)
	var lp := 0.0
	for k in n:
		var t := k / float(RATE)
		var a := 1.0 - exp(-TAU * lerpf(f0, f1, t / dur) / RATE)
		lp += a * (_rng.randf() * 2.0 - 1.0 - lp)
		b[i0 + k] += lp * vol * _env(t, dur, dur * 0.4)


func _wav(b: PackedFloat32Array, rate := RATE) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(b.size() * 2)
	for i in b.size():
		data.encode_s16(i * 2, int(clampf(b[i], -1.0, 1.0) * 32767.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = rate
	w.stereo = false
	w.data = data
	return w
