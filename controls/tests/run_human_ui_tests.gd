extends SceneTree

class Fixture extends "res://main.gd":
	func _ready() -> void:
		map = HillMap.new()
		map.size_m = 240
		map.cell_m = 4
		map.height_amplitude = 0
		map.features_enabled = false
		add_child(map)
		_spawn("tiger1", 0, Vector3.ZERO, 1)
		_spawn("sherman75", 1, Vector3(12, 0, -24), 2)
		fair_view = false
		for t in tanks:
			t.set_physics_process(false)
			t.step(0.0)
			agents.append(TankAgent.new(map, t, sounds, ScriptedAI.for_tank(t, 0, Vector3.ZERO)))
		recorder = MatchRecorder.new()
		recorder.write_files = false
		recorder.write_report = false
		recorder.auto_end = false
		add_child(recorder)
		recorder.start(map, tanks)
		recorder.set_physics_process(false)
		recorder.shot_recorded.connect(_on_shot_recorded)
		_setup_view()
		camera.capture_mouse = false
		set_physics_process(false)
		set_process(false)

var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, message: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func run() -> void:
	var game := Fixture.new()
	root.add_child(game)
	await physics_frame
	await process_frame
	var p: Tank = game.tanks[0]
	var target: Tank = game.tanks[1]
	var camera: TankViewCamera = game.camera
	var initial := camera.view_yaw()
	p.turret_yaw += .3
	p._sync_turret()
	camera.update_view(p, .1)
	check(absf(wrapf(camera.view_yaw() - initial, -PI, PI)) < .001, "cursor camera stays stable while turret turns")
	var aim := camera.aim_commands(p, 0.0, 0.0, 1.0 / 30)
	check(aim.x > 0 and absf(aim.x) <= 1, "mouse aiming uses correct direction and bounded controls")
	for i in 120:
		aim = camera.aim_commands(p, 0.0, 0.0, 1.0 / 30)
		p._aim(TankControlInput.from_array([0, 0, 1, aim.x, aim.y, 0]), 1.0 / 30)
	check(absf(p.turret_yaw) < .001, "turret converges at actual traverse rate without overshoot")
	camera.update_view(p, .1)
	var point := target.global_transform * Vector3(target.spec.hull_width * .5, .5, 0)
	var selected := camera.cursor_target(p, camera.unproject_position(point))
	check(selected.distance_to(point) < 4, "cursor picks low track geometry, including parts below movement collider")
	camera.toggle_gunner()
	camera.update_view(p, .1)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(30, -10)
	camera._unhandled_input(motion)
	check(camera._scope_target.x < p.turret_yaw and camera._scope_target.y > p.gun_pitch, "scoped mouse motion aims right and up")
	camera.toggle_commander()
	camera.update_view(p, .1)
	var locked := camera.human_control(p, .1)
	check(locked.turret_traverse == 0 and locked.gun_elevation == 0, "commander/free-look still locks gun input")
	camera.set_mode(TankView.THIRD)
	camera.update_view(p, .1)
	var tracks: TankTrackVisual = p.get_node("TrackDetail")
	var before: float = tracks.phases[0]
	p.track_speed_left = 2
	p.track_speed_right = 0
	tracks.update_belts(.25)
	check(not is_equal_approx(tracks.phases[0], before) and tracks.phases[1] == 0, "left/right treads animate independently")
	p.damage.modules.track_left = "damaged"
	before = tracks.phases[0]
	tracks.update_belts(.25)
	check(is_equal_approx(tracks.phases[0] - before, .5) and tracks.materials[0].albedo_color.r > tracks.materials[0].albedo_color.b, "damaged track remains at measured belt speed and turns amber")
	p.damage.modules.track_left = "destroyed"
	before = tracks.phases[0]
	tracks.update_belts(.25)
	check(is_equal_approx(tracks.phases[0], before) and tracks.materials[0].albedo_color.r > tracks.materials[0].albedo_color.g, "broken track stops and changes color")
	p.damage.modules.track_left = "ok"
	p.track_speed_left = 0
	check(tracks.sample_belt(0).is_equal_approx(tracks.sample_belt(tracks.perimeter())), "tread path closes at the loop seam")
	var count := get_nodes_in_group(Tank.GROUP).size()
	var track_point := target.global_transform * Vector3(target.spec.hull_width * .5 + .025, .45, 0)
	for i in 5:
		var solution := p.aim_solution(track_point)
		p.turret_yaw = solution.turret_yaw
		p.gun_pitch = solution.gun_pitch
		p._sync_turret()
	p.aim_error_mrad = .001
	var shot := p.fire()
	check(shot.get("hit", false), "fixture produces an actual tank hit")
	check(shot.has("track_hit"), "impact preview reports a real track hit")
	check(game.impact_view.active, "selected player's shot opens impact camera")
	check(get_nodes_in_group(Tank.GROUP).size() == count, "impact snapshot never becomes a gameplay or AI target")
	check(game.impact_view.camera.get_world_3d() != game.camera.get_world_3d(), "impact scene uses an isolated 3D world")
	var distance := game.impact_view.camera.position.distance_to(game.impact_view.focus)
	game.impact_view.age = 1
	game.impact_view._process(0)
	check(distance > game.impact_view.camera.position.distance_to(game.impact_view.focus), "shell viewpoint approaches and freezes near impact")
	check(game.impact_view.position.y >= game.minimap.position.y + game.minimap.size.y, "impact camera sits below minimap")
	var marker: Node3D = game.markers._hits_root.get_child(0)
	var old_position := marker.global_position
	target.position.x += 2
	game.markers._process(0)
	check(absf(marker.global_position.x - old_position.x - 2) < .001, "hit marker follows moving target armor")
	target.position.x -= 2
	game.markers._process(0)
	game._process(0)
	game.grid.mode = 0
	camera._third_yaw = .65
	camera.update_view(p, 0)
	# Freeze final close-up and leave enough render frames for the SubViewport.
	game.impact_view._render_frozen = false
	for i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var path := ProjectSettings.globalize_path("res://_sync/human_controls_preview.png")
	check(root.get_texture().get_image().save_png(path) == OK, "saved rendered HUD preview")
	print("Human UI tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
