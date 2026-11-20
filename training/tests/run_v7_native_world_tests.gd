extends SceneTree

const World := preload("res://training/v7_native_world.gd")
class TrainingReference extends "res://training/training_env.gd":
	func _ready() -> void:
		pass
var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("run")


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(message)


func run() -> void:
	var w := World.new()
	root.add_child(w)
	var reference := TrainingReference.new()
	root.add_child(reference)
	var catalog := World.catalog()
	for native_stage in ["v7_1v1", "v7_1v2", "v7_1v3", "v7_1v6"]:
		for map_index in catalog.map_ids.size():
			var seed_value: int = 10 + int(map_index)
			var row: Dictionary = catalog.layouts[native_stage.replace("v7_", "v6_")].sherman75[seed_value]
			var geometry: Dictionary = catalog.maps[row.map_key]
			w.reset_round("sherman75", native_stage, seed_value)
			var poses: Array = row.tanks
			reference.config = {"seed": int(row.source_seed), "scenario": {"learner": poses[0],
				"enemies": poses.slice(1), "obstacles": geometry.obstacles, "learner_type": "sherman75"}}
			reference._clear_tanks()
			reference._ensure_map(geometry.map)
			var rng := RandomNumberGenerator.new()
			rng.seed = int(row.source_seed)
			reference._spawn_scenario(poses, rng)
			var tanks := [w.player]
			for actor in w._actors:
				tanks.append(actor.tank)
			check(tanks.size() == reference.tanks.size() and w.layout_info.layout_id == row.layout_id, "Original lineup identity")
			for i in reference.tanks.size():
				var a: Tank = tanks[i]
				var b: Tank = reference.tanks[i]
				check(a.position.is_equal_approx(b.position) and a.rotation.is_equal_approx(b.rotation)
					and a.tank_id == b.tank_id and a.team == b.team, "Original terrain elevation and spawn transform")
			check(w.map.obstacles.size() == reference.map.obstacles.size()
				and w.map.vision_volumes == reference.map.vision_volumes
				and is_equal_approx(w.map.height_at(45, 32), reference.map.height_at(45, 32)), "Original map and obstacle volumes")
	reference.free()
	for tank in ["sherman75", "t34_76", "tiger1"]:
		w.reset_round(tank, "v7_1v6", 112)
		var s := w.round_status()
		check(w.player is Tank and w.map is HillMap and w._actors.size() == 6, "Native vehicle lineup")
		check(s.allies == (0 if tank == "tiger1" else 5), "Allied roster")
		check(s.rivals == (6 if tank == "tiger1" else 1), "Opposition roster")
		check(w.observation().size() == 78 and w.schema.action_labels.size() == 9, "Schema")
		check(w.limit_steps == 4800, "1v6 maneuver time")
		for actor in w._actors:
			if not actor.ally:
				actor.points = w.goal + 1
		w.turn = 3839
		check(w.round_status().rival_score < w.goal, "Opponent cannot end early")
		w.turn = 3840
		check(w.round_status().rival_score == w.goal, "Opponent can finish after protected time")
		for actor in w._actors:
			check(actor.tank is Tank and not actor.tank.is_physics_processing(), "Explicit native physics")
	w.reset_round("sherman75", "v7_target", 41)
	var first := w.observation()
	w.reset_round("sherman75", "v7_target", 41)
	check(first == w.observation(), "Seeded reset")
	await physics_frame
	var target_result := {}
	for i in 120:
		var offset := w._local(w.ring_position) - w._cursor
		var action := PackedFloat32Array([0, 0, 1, offset.x / w.CURSOR_RATE, offset.y / w.CURSOR_RATE, 1, 0, 0, 0])
		var applied := w.apply_action(action)
		check(absf(applied[3]) <= 1 and absf(applied[4]) <= 1, "Stored action is applied action")
		for tick in 3:
			w.physics_tick(1.0 / 30)
		target_result = w.advance_decision()
		if w.finished:
			break
	check(target_result.info.get("is_success", false) and target_result.info.score == 3, "Native ring lesson completes")
	w.reset_round("t34_76", "v7_1v2", 23)
	await physics_frame
	var start := w.player.position
	var npc: Tank = w._actors[0].tank
	# Isolate the arcade badge rule from actual starting separation.
	npc.position = w._to_world(Vector2(0, 12)) + Vector3.UP * 0.5
	w._actors[0].anchor = w._flat(npc.position)
	var npc_start := npc.position
	var side_paid := 0.0
	for i in 35:
		var action := PackedFloat32Array([0, 0, 1, 0, 0, 0, 0, 0, 0])
		w.apply_action(action)
		for tick in 3:
			w.physics_tick(1.0 / 30)
		var result := w.advance_decision()
		side_paid += float(result.info.reward_components.side_seen)
	check(side_paid == 0.5 and w.round_status().side_seen_count == 1, "Stationary side badge credited once")
	check(w.round_status().score == 0 and w.round_status().side_checkpoints == 0, "Sight credit without tag or gate")
	for i in 45:
		w.apply_action(PackedFloat32Array([1, 1, 0, 0, 0, 0, 0, 0, 0]))
		for tick in 3:
			w.physics_tick(1.0 / 30)
		w.advance_decision()
	check(w.player.position.distance_to(start) > 4.0 and npc.position.distance_to(npc_start) > 4.0, "Player and opponents physically drive")
	check(w.player.shots_fired == 0 and npc.shots_fired == 0, "Arcade tag uses its own scoring")
	var turret_before := w.player.turret_yaw
	w.apply_action(PackedFloat32Array([0, 0, 1, 0, 0, 0, 0, 0.5, 0.25]))
	for tick in 3:
		w.physics_tick(1.0 / 30)
	check(not is_equal_approx(w.player.turret_yaw, turret_before) and w.observation().size() == 78,
		"Turret control is applied by shared physics and observed")
	for stage in ["v7_1v2", "v7_1v3", "v7_1v6"]:
		w.reset_round("sherman75", stage, 31)
		await physics_frame
		var outcome := {}
		while not w.finished:
			var a := PackedFloat32Array([0, 0, 1, 0, 0, 1, 0, 0, 0])
			if not w.gate_open:
				var g := w._local(w.gate_position)
				var steer := clampf(atan2(g.x, g.y) * 1.7, -1, 1)
				var drive := 0.7 * (1.0 - 0.65 * absf(steer))
				a[0] = drive + steer
				a[1] = drive - steer
				a[2] = 0.0
			else:
				var delta := w._local(w.ring_position) - w._cursor
				a[3] = delta.x / w.CURSOR_RATE
				a[4] = delta.y / w.CURSOR_RATE
			w.apply_action(a)
			for tick in 3:
				w.physics_tick(1.0 / 30)
			outcome = w.advance_decision()
		check(outcome.info.is_success, "Allied course completable %s at %d/%d rings (%s)" % [
			stage, w.score, w.goal, outcome.info.reason])
	w.free()
	print("V7 native world: %d checks; %d failures" % [checks, failures])
	quit(1 if failures else 0)
