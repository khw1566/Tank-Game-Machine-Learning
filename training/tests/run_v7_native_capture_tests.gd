extends SceneTree
## Rendered integration test, run with --fixed-fps 30 and --demos-dir=<temporary QA folder>.

var failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func _key(code: Key, down: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.keycode = code
	event.pressed = down
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _run() -> void:
	var dest := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--demos-dir="):
			dest = arg.trim_prefix("--demos-dir=")
	if DisplayServer.get_name() == "headless" or not dest.get_file().begins_with("v7-godot-qa-capture-") or not FileAccess.file_exists(dest.path_join("fixture.only")):
		push_error("Requires graphical Godot and an explicit fresh temporary fixture.only directory")
		quit(2)
		return
	var scene = load("res://training/v7_native.tscn").instantiate()
	root.add_child(scene)
	await process_frame
	_check(scene.hud != null and not scene.active and scene.world.player is Tank, "Native 3D lobby preview")
	scene.hud.tank_select.select(0)
	scene.hud.stage_select.select(0)
	scene.hud.play.pressed.emit()
	for i in 4:
		await physics_frame
	_check(scene.active and scene.waiting_for_input and scene.actions.is_empty(), "Before first human input")
	_check(scene.world.player.tank_id == "sherman75" and scene.world.round_status().allies == 1, "Native 1 vs 2 roster")
	var before: Array = Array(scene.world.observation())
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(dest.path_join("game.png"))
	# Native OS events and all 30 Hz physics frames still run; only rendering of the remaining frames is unnecessary.
	RenderingServer.render_loop_enabled = false
	_key(KEY_W, true)
	for i in 6:
		await physics_frame
	_check(scene.actions.size() >= 1 and scene.observations[0] == before, "Store observation before keyboard action")
	_check(scene.actions.size() >= 1 and scene.actions[0][0] == 1.0 and scene.actions[0][1] == 1.0, "Real KeyboardController tracks")
	_key(KEY_W, false)
	_key(KEY_SPACE, true)
	for i in 8:
		await physics_frame
	_key(KEY_SPACE, false)
	_check(scene.actions.size() > 1 and scene.actions.back()[2] == 1.0, "Space applied to native brake")
	var angle: float = scene.world.player.turret_yaw
	var mouse := InputEventMouseMotion.new()
	mouse.relative = Vector2(18, -10)
	scene._input(mouse)
	for i in 6:
		await physics_frame
	_check(scene.actions.any(func(row): return absf(row[7]) > 0.0 and absf(row[8]) > 0.0)
		and not is_equal_approx(angle, scene.world.player.turret_yaw), "Mouse commands move turret and enter captured actions")
	var selected: Vector3 = scene.camera.aim_point
	await process_frame
	var projected: Vector2 = scene.camera.unproject_position(selected)
	_check(projected.distance_to(root.get_visible_rect().get_center()) < 1.0, "Camera-ray destination projects at screen center")
	var heading: Vector3 = -scene.camera.global_basis.z
	_key(KEY_W, true)
	for i in 42:
		await physics_frame
	_key(KEY_W, false)
	_check(scene.camera.aim_point.distance_to(selected) > 0.25
		and heading.dot(-scene.camera.global_basis.z) > 0.999, "Driving changes the point under a stationary view")
	var wide := InputEventMouseMotion.new()
	wide.relative = Vector2(590, 0)
	var start_yaw: float = scene.world.player.turret_yaw
	var old_heading: Vector3 = -scene.camera.global_basis.z
	scene._input(wide)
	scene._process(0.0)
	_check(old_heading.dot(-scene.camera.global_basis.z) < 0.5
		and is_equal_approx(start_yaw, scene.world.player.turret_yaw), "Camera turns immediately while the turret is still slewing")
	var turned: Vector3 = -scene.camera.global_basis.z
	var correction := InputEventMouseMotion.new()
	correction.relative = Vector2(100, 0)
	scene._input(correction)
	scene._process(0.0)
	_check(turned.dot(-scene.camera.global_basis.z) < 0.98, "Further mouse input changes the view during traverse")
	for i in 270:
		await physics_frame
	_check(absf(angle_difference(start_yaw, scene.world.player.turret_yaw)) > deg_to_rad(100),
		"Turret continues following the view past 100 degrees after the mouse stops")
	_key(KEY_SHIFT, true)
	_key(KEY_SHIFT, false)
	await process_frame
	_check(scene.camera.mode == TankView.GUNNER, "Shift enables gunner")
	_key(KEY_B, true)
	_key(KEY_B, false)
	await process_frame
	_check(scene.camera.mode == TankView.COMMANDER, "B enables commander")
	scene._input(mouse)
	_check(scene._human_action()[7] == 0.0, "Commander movement never turns turret")
	_key(KEY_B, true)
	_key(KEY_B, false)
	_key(KEY_C, true)
	scene._input(mouse)
	await process_frame
	_check(scene.camera.is_free_look_pressed() and scene._human_action()[7] == 0.0
		and not is_zero_approx(scene.camera.view.orbit_yaw), "C rotates view with locked turret")
	_key(KEY_C, false)
	var button := InputEventMouseButton.new()
	button.button_index = MOUSE_BUTTON_RIGHT
	button.pressed = true
	Input.parse_input_event(button)
	Input.flush_buffered_events()
	scene._input(mouse)
	await process_frame
	_check(scene.camera.is_free_look_pressed() and scene._human_action()[7] == 0.0, "Right button activates free look")
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_RIGHT
	Input.parse_input_event(release)
	Input.flush_buffered_events()
	var lines: ImmediateMesh = scene.world._observation_lines.mesh
	var observed: bool = scene.world.round_status().visible_rivals > 0
	_check(lines.get_surface_count() == (1 if observed else 0), "Red rays share the learning observation")
	scene.hud.pause_button.pressed.emit()
	for i in 4:
		await physics_frame
	var paused_count: int = scene.actions.size()
	for i in 12:
		await physics_frame
	_check(scene.actions.size() == paused_count, "Paused frames produce no extra records")
	scene.hud.pause_button.pressed.emit()
	var max_frames: int = (scene.world.limit_steps + 2) * scene.REPEAT
	for i in max_frames:
		if not scene.active:
			break
		await physics_frame
	_check(not scene.active and FileAccess.file_exists(scene.saved_path), "Completed human-mode capture")
	if FileAccess.file_exists(scene.saved_path):
		var demo: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(scene.saved_path))
		_check(demo.actions.size() == demo.obs.size() and demo.actions.size() == scene.world.turn, "One pair per physical decision")
		_check(demo.source == "godot-human" and demo.completed and demo.repeat == 3, "Capture source and completion")
		_check(PackedFloat32Array(demo.obs[0]) == PackedFloat32Array(before) and demo.actions[0][0] == 1.0,
			"Serialized first float32 observation/action")
		print("QA_NATIVE_DEMO=", scene.saved_path)
	# Exercise the ordinary control and projectile path with one player in an isolated empty lane.
	scene.world.reset_round("sherman75", "v7_target", 41)
	var manual := TankViewCamera.new()
	scene.add_child(manual)
	manual.mouse_aim_enabled = false
	manual.capture_mouse = false
	var original: Tank = scene.world.player
	var ammo: int = original.damage.ammo_remaining
	_key(KEY_F, true)
	original.control = manual.human_control(original, 1.0 / 30.0)
	original.step(1.0 / 30.0)
	_key(KEY_F, false)
	_check(original.shots_fired == 1 and original.damage.ammo_remaining == ammo - 1, "Base game controls fire a shell")
	manual.reticle.free()
	manual.reticle = null
	print("V7 graphical capture failures: ", failures)
	quit(1 if failures > 0 else 0)
