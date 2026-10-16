extends SceneTree
## Render every synthesised sound to WAV so you can audition or tweak them outside the game:
##   godot --headless --path godot -s res://tools/export_sounds.gd
## Files go to <user data>/sounds/.

const Audio := preload("res://scripts/audio.gd")


func _initialize() -> void:
	var t := Time.get_ticks_msec()
	var a: Node = Audio.new()
	root.add_child(a)
	while a._drone == null:  # _ready (which synthesises everything) runs once the tree is live
		await process_frame
	var built := Time.get_ticks_msec() - t
	var dir := ProjectSettings.globalize_path("user://sounds")
	DirAccess.make_dir_recursive_absolute(dir)
	for name in a._sfx:
		a._sfx[name].save_to_wav("%s/%s.wav" % [dir, name])
	a._drone.stream.save_to_wav(dir + "/drone.wav")
	print("SOUNDS synth_ms=%d count=%d dir=%s" % [built, a._sfx.size() + 1, dir])
	quit()
