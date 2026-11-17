extends SceneTree

class Harness extends "res://training/training_env.gd":
	func _ready() -> void:
		set_physics_process(false)

var checks := 0
var failures := 0


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func fixture(extra_obstacles: Array = [], low := false) -> Harness:
	var env := Harness.new()
	root.add_child(env)
	env.situation = true
	env.threat_inputs = true
	var sc := {"id": "under_fire_test", "variant": "screened", "goal": "take_cover",
		"observation_version": 3, "projectile_version": 1,
		"learner": {"p": [0, 0], "yaw": 0}, "enemies": [{"p": [0, -600], "yaw": PI}],
		"obstacles": [{"type": "stone", "p": [60, -45], "size": [30, 0.7 if low else 4.5, 6], "yaw": 0}] + extra_obstacles,
		"cover_regions": [{"p": [60, -33], "radius": 5}], "max_hits": 4,
		"evade": {"version": 1, "hold_s": 4, "min_displacement_m": 35, "require_fire_cue": true}}
	env.reset_episode({"seed": 42, "uid": "under_fire_test", "save_episode": false,
		"stage": "m3_under_fire", "kind": "combat", "time_limit_s": 100,
		"map": {"seed": 42, "features": false, "amplitude": 0, "profile": "flat", "size_m": 1600, "cell_m": 16, "ridge_count": 0},
		"tanks": [{"type": "tiger1", "team": 0, "ctrl": "external"}, {"type": "sherman75", "team": 1, "ctrl": "static"}],
		"scenario": sc, "reward": {"objective": 8, "progress": 0.03, "shaping_scale": 1, "time_per_s": -0.01}})
	for t in env.tanks:
		t.set_physics_process(false)
	return env


func shoot(env: Harness) -> void:
	var enemy: Tank = env.tanks[1]
	var me: Tank = env.tanks[0]
	var solution := enemy.aim_solution(me.global_position + Vector3.UP * me.spec.hull_top_y() * 0.6)
	enemy.turret_yaw = solution.turret_yaw
	enemy.gun_pitch = solution.gun_pitch
	enemy.aim_error_mrad = 0
	enemy._sync_turret()
	enemy.fire()


func advance(env: Harness, frames: int) -> void:
	for i in frames:
		env.projectiles.step(1.0 / 30.0)
		env.sounds.advance(1.0 / 30.0)


func hold(env: Harness, decisions := 45) -> Dictionary:
	var result := {"done": false}
	for i in decisions:
		env.tick += 3
		env.decisions += 1
		result = env.rewarder.decision()
		if result.done:
			break
	return result


func drive_to_cover(env: Harness) -> Dictionary:
	for tank in env.tanks:
		tank.set_physics_process(true)
	var me: Tank = env.tanks[0]
	var route: ScenarioRoute = env.rewarder._sc_cover_routes[0]
	var result := {"done": false}
	for frame in 3003:
		if frame % 3 == 0:
			if frame > 0:
				result = env.rewarder.decision()
				if result.done:
					break
			var pos := Vector2(me.global_position.x, me.global_position.z)
			var target := route.nodes[0]
			var best := INF
			for i in route.nodes.size():
				var remaining := pos.distance_to(route.nodes[i]) + route.distances[i]
				if remaining < best and route.clear(pos, route.nodes[i]):
					best = remaining
					target = route.nodes[i]
			var delta := target - pos
			var bearing := wrapf(atan2(-delta.x, -delta.y) - me.global_rotation.y, -PI, PI)
			var turn := clampf(bearing * 1.8, -0.8, 0.8)
			var throttle := 0.65 if delta.length() > 14 else 0.22
			if absf(bearing) > 0.6:
				throttle = 0
			var brake := 0.0
			if pos.distance_to(route.nodes[0]) < 3.5:
				throttle = 0
				turn = 0
				brake = 1
			elif delta.length() < 10 and me.forward_speed() > 2:
				brake = 0.7
			env._last_actions[0] = [clampf(throttle - turn, -1, 1), clampf(throttle + turn, -1, 1), brake, 0, 0, 0, 0, 0, 0, 0, 0]
			env.decisions += 1
		env._advance(1.0 / 30.0)
		await physics_frame
	return result


func validate_layouts(path: String) -> void:
	var fixtures: Array = JSON.parse_string(FileAccess.get_file_as_string(path))
	var rows := []
	for configuration in fixtures:
		var env := Harness.new()
		root.add_child(env)
		configuration["save_episode"] = false
		env.reset_episode(configuration)
		for tank in env.tanks:
			tank.set_physics_process(false)
		await physics_frame
		await physics_frame
		var me: Tank = env.tanks[0]
		var origin := me.global_position
		var initially_exposed := false
		for enemy in env.tanks:
			if enemy.team == me.team:
				continue
			var exposure := SituationObs.exposure_from(env.map, LineOfSight.eye_position(enemy), me, [me.get_rid(), enemy.get_rid()])
			initially_exposed = initially_exposed or exposure.hull or exposure.turret
		check(initially_exposed, configuration.uid + ": starts exposed to enemy fire")
		var safe: Array = configuration.scenario.cover_regions[0].p
		me.position = Vector3(safe[0], env.map.height_at(safe[0], safe[1]) + .5, safe[1])
		await physics_frame
		await physics_frame
		var blocked_all := true
		for enemy in env.tanks:
			if enemy.team == me.team:
				continue
			var exposure := SituationObs.exposure_from(env.map, LineOfSight.eye_position(enemy), me, [me.get_rid(), enemy.get_rid()])
			blocked_all = blocked_all and not exposure.hull and not exposure.turret
		check(blocked_all and env.rewarder._sc_near_cover(me), configuration.uid + ": far cover blocks every enemy and the turret")
		me.position = origin
		await physics_frame
		var row := {"uid": configuration.uid, "initially_exposed": initially_exposed, "safe_cover": blocked_all}
		if int(configuration.seed) == 42:
			var result := await drive_to_cover(env)
			row["physical_success"] = result.get("success", false)
			row["reason"] = result.get("reason", "not_terminated")
			row["summary"] = env.rewarder.scenario_summary()
			check(row.physical_success, configuration.uid + ": physical evade-to-cover controller: " + JSON.stringify(row))
			print("Physical cover: " + JSON.stringify(row))
		rows.append(row)
		env.free()
	var file := FileAccess.open(path.get_base_dir().path_join("layout_validation.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(rows, "  "))
	file.close()


func run() -> void:
	var env := fixture()
	await physics_frame
	await physics_frame
	check(env._observation(0).size() == 437, "18 appended fire cues; old 419-column prefix retained")
	check(env.waypoint == Vector3.INF, "the policy is not told the safe cover location")
	check(env._task_waypoint(env.tanks[0]) == Vector3.INF, "no hidden target or enemy-base waypoint bypasses threat recognition")
	shoot(env)
	check(env.rewarder._sc_taken.hits == 0 and env.projectiles.active.size() == 1, "launch cannot deal instant damage")
	var cues := ThreatObs.compute(env.agents[0].perception, env.projectiles)
	check(cues[0] > 0.9, "gunfire audible at launch")
	check(cues[3] > 0.9, "visible enemy muzzle flash has an explicit input")
	advance(env, 6)
	check(env.rewarder._sc_taken.hits == 0, "a 600m shot has nonzero flight time")
	cues = ThreatObs.compute(env.agents[0].perception, env.projectiles)
	check(cues[12] == 1 and cues[16] < -0.9, "visible tracer and its incoming direction are reported")
	env.tanks[0].position.x = 5
	advance(env, 60)
	check(env.rewarder._sc_taken.hits == 0, "moving after launch avoids the original aim point")
	check(env.projectiles.near_passes.has(str(env.tanks[0].name)), "a passing shell produces a near-pass cue")
	cues = ThreatObs.compute(env.agents[0].perception, env.projectiles)
	check(cues[9] > 0, "near-pass input reaches the policy")
	for i in 8:
		env.sounds.add(SoundField.IMPACT, env.tanks[0].global_position + Vector3.RIGHT * i, "other")
	env.agents[0].perception.observe(env.tanks, 0.1)
	check(ThreatObs.compute(env.agents[0].perception, env.projectiles)[0] > 0,
		"many impacts cannot evict the dedicated shot cue")
	env.free()
	env = fixture()
	await physics_frame
	await physics_frame
	shoot(env)
	advance(env, 70)
	check(env.rewarder._sc_taken.hits == 1, "the same shot hits a stationary target after flight")
	check(env.projectiles.resolved == 1, "a projectile resolves once")
	env.free()
	env = fixture()
	env.config.scenario["practice_rounds"] = true
	await physics_frame
	await physics_frame
	var before: PackedFloat32Array = env.tanks[0].damage.observation()
	shoot(env)
	advance(env, 70)
	check(env.rewarder._sc_taken.hits == 1 and env.tanks[0].damage.observation() == before,
		"practice rounds count physical hits without random internal destruction")
	for i in 4:
		env.rewarder.on_shot(env.tanks[1], {"hit": true, "target_name": str(env.tanks[0].name), "target_team": 0})
	check(hold(env, 1).get("reason", "") == "evade_too_many_hits", "five hits fail the practice lesson")
	env.free()
	env = fixture([{"type": "stone", "p": [0, -300], "size": [50, 10, 6], "yaw": 0}])
	await physics_frame
	await physics_frame
	shoot(env)
	cues = ThreatObs.compute(env.agents[0].perception, env.projectiles)
	check(cues[0] > 0 and cues[3] == 0 and cues[12] == 0, "hidden gunfire is heard without revealing a hidden flash or tracer")
	advance(env, 70)
	check(env.rewarder._sc_taken.hits == 0 and env.projectiles.resolved == 1, "the screen physically stops the shell")
	check(not env.projectiles.near_passes.has(str(env.tanks[0].name)), "shells stopped behind a wall do not fake a near pass")
	env.free()
	env = fixture()
	await physics_frame
	await physics_frame
	env.rewarder._sc_enemy_seen = true
	shoot(env)
	check(not hold(env).done, "standing exposed after noticing fire never succeeds")
	env.tanks[0].position = Vector3(60, 0.5, -33)
	await physics_frame
	await physics_frame
	var result := hold(env)
	check(result.get("success", false) and result.reason == "covered_after_fire", "distant full cover held for four seconds succeeds")
	check(env.rewarder.scenario_summary().longest_cover_s >= 4, "cover duration is recorded")
	env.free()
	env = fixture()
	await physics_frame
	await physics_frame
	env.rewarder._sc_enemy_seen = true
	env.tanks[0].position = Vector3(60, .5, -33)
	await physics_frame
	check(not hold(env).done, "reaching cover without ever noticing a shot does not pass")
	env.free()
	env = fixture([], true)
	await physics_frame
	await physics_frame
	env.rewarder._sc_enemy_seen = true
	env.rewarder._sc_fire_cue = true
	env.tanks[0].position = Vector3(60, .5, -33)
	await physics_frame
	check(not hold(env).done and env.rewarder._sc_cover_hold == 0, "a low decoy rock does not count as full cover")
	env.free()
	var replay := ReplayData.new()
	replay.frames = [{"t": 0.0, "projectiles": [{"id": 0, "from": [0, 1, 0], "to": [0, 1, 10]}]},
		{"t": 0.1, "projectiles": [{"id": 0, "from": [0, 1, 70], "to": [0, 1, 80]}]}]
	var middle := replay.projectile_tracers(0.05)
	check(middle.size() == 1 and is_equal_approx(middle[0].to.z, 45), "replay interpolates moving projectiles")
	replay.frames = [{"t": 0.0}, {"t": 0.1}]
	check(replay.projectile_tracers(0.05).is_empty(), "legacy replays need no flight frames")
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixtures="):
			await validate_layouts(argument.get_slice("=", 1))
	print("Under-fire tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
