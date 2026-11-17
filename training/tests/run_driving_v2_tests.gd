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


func fixture(tank_id := "tiger1", driving := true, obstacles: Array = []) -> Harness:
	var env := Harness.new()
	root.add_child(env)
	var sc := {"id": "drive_v2_test", "variant": "wall", "goal": "reach", "obstacles": obstacles,
		"learner_type": tank_id, "learner": {"p": [0, 0], "yaw": 0}, "enemies": [],
		"objective": {"p": [0, -100], "radius": 6, "hold_s": 0.6}, "observation_version": 2}
	if driving:
		sc.driving = {"version": 2, "route_progress": true, "min_forward_fraction": 0.85,
			"reverse_allowance_m": 2, "reverse_per_m": -0.08}
	env.reset_episode({"seed": 123, "uid": "drive_v2_test", "kind": "drive", "stage": "m2_route",
		"time_limit_s": 90, "save_episode": false, "scenario": sc,
		"map": {"seed": 123, "features": false, "amplitude": 0, "profile": "flat", "size_m": 600, "cell_m": 8, "ridge_count": 0},
		"tanks": [{"type": tank_id, "team": 0, "ctrl": "external"}],
		"reward": {"progress": 0.03, "objective": 8, "shaping_scale": 1, "timeout_penalty": -3}})
	for t in env.tanks:
		t.set_physics_process(false)
	return env


func decide(env: Harness) -> Dictionary:
	env.tick += 3
	env.decisions += 1
	return env.rewarder.decision()


func arrive(env: Harness, backwards: bool) -> Dictionary:
	var t: Tank = env.tanks[0]
	t.rotation.y = PI if backwards else 0.0
	for z in range(1, 101):
		t.position.z = -float(z)
		decide(env)
	var result := {"done": false}
	for i in 7:
		result = decide(env)
		if result.done:
			break
	return result


func drive_course(tank_id: String, obstacles: Array, initial_yaw: float) -> void:
	var env := fixture(tank_id, true, obstacles)
	var t: Tank = env.tanks[0]
	t.rotation.y = initial_yaw
	t.set_physics_process(true)
	var route: ScenarioRoute = env.rewarder._sc_route
	var result := {"done": false}
	for tick in 2703:
		if tick % 3 == 0:
			if tick > 0:
				result = env.rewarder.decision()
				if result.done:
					break
			var pos := Vector2(t.global_position.x, t.global_position.z)
			var target := route.nodes[0]
			var best := INF
			for i in route.nodes.size():
				var distance := pos.distance_to(route.nodes[i]) + route.distances[i]
				if distance < best and route.clear(pos, route.nodes[i]):
					best = distance
					target = route.nodes[i]
			var delta := target - pos
			var bearing := wrapf(atan2(-delta.x, -delta.y) - t.global_rotation.y, -PI, PI)
			var turn := clampf(bearing * 1.8, -0.8, 0.8)
			var throttle := 0.65 if delta.length() > 14 else 0.22
			if absf(bearing) > 0.6:
				throttle = 0.0
			var brake := 0.0
			if pos.distance_to(route.nodes[0]) < 4:
				throttle = 0.0
				turn = 0.0
				brake = 1.0
			elif delta.length() < 10 and t.forward_speed() > 2:
				brake = 0.7
			env._last_actions[0] = [clampf(throttle - turn, -1, 1), clampf(throttle + turn, -1, 1), brake, 0, 0, 0, 0, 0, 0, 0, 0]
			env.decisions += 1
		env._advance(1.0 / 30.0)
		await physics_frame
	check(result.done and result.get("success", false), "%s physical obstacle course, yaw %.2f: %s" % [tank_id, initial_yaw, result])
	print("Physical course: %s yaw=%.2f success=%s time=%.1f reverse=%.2f" % [tank_id, initial_yaw,
		result.get("success", false), float(env.tick) / 30, env.rewarder.scenario_summary().reverse_m])
	env.free()


func run() -> void:
	for tank_id in ["tiger1", "sherman75", "t34_76"]:
		for backwards in [false, true]:
			var env := fixture(tank_id)
			var result := arrive(env, backwards)
			check(result.done and bool(result.success) == not backwards, tank_id + ": forward success / reverse failure")
			var summary: Dictionary = env.rewarder.scenario_summary()
			check(summary.reverse_m > 99 if backwards else summary.forward_m > 99, tank_id + ": measured driving direction")
			if backwards:
				check(result.reason == "arrival_requires_forward_drive", "explicit reverse arrival reason")
				check(summary.reward_components.get("shaping_progress", 0) == 0, "reverse never receives approach reward")
				check(summary.reward_components.get("reverse", 0) < -7, "reverse has a distance cost")
			env.free()
	# Legacy/tactical reach tasks still allow reversing, preserving old episode reward semantics.
	var legacy := fixture("tiger1", false)
	check(arrive(legacy, true).success, "tactical / legacy reverse arrival remains valid")
	legacy.free()
	var wall := [{"type": "stone", "p": [0, -50], "size": [60, 3.5, 3], "yaw": 0}]
	var env := fixture("tiger1", true, wall)
	var route: ScenarioRoute = env.rewarder._sc_route
	check(not route.clear(Vector2.ZERO, Vector2(0, -100)), "direct path is blocked by wall")
	check(route.remaining(Vector3.ZERO) > 110, "route includes a tank-sized detour")
	var initial := route.remaining(Vector3.ZERO)
	check(route.remaining(Vector3(10, 0, 0)) < initial, "sideways detour earns progress although Euclidean distance grows")
	env.tanks[0].rotation.y = -PI / 2
	env.tanks[0].position.x = 10
	decide(env)
	var paid: float = env.rewarder.scenario_summary().reward_components.get("shaping_progress", 0)
	check(paid > 0, "detour progress is actually paid")
	env.tanks[0].position.x = 0
	decide(env)
	env.tanks[0].position.x = 10
	decide(env)
	check(is_equal_approx(paid, env.rewarder.scenario_summary().reward_components.get("shaping_progress", 0)), "oscillating cannot farm route progress")
	env.free()
	# A narrow obstacle halfway between the old 45-degree rays was invisible to cover sensing.
	var angle := PI / 8
	var p := Vector2(-sin(angle), -cos(angle)) * 40
	env = fixture("tiger1", true, [{"type": "stone", "p": [p.x, p.y], "size": [3, 3.5, 3], "yaw": 0}])
	await physics_frame
	await physics_frame
	var t: Tank = env.tanks[0]
	var perception: TankPerception = env.agents[0].perception
	var old := SituationObs.compute(env.map, t, perception, env.waypoint, 6, 1)
	var improved := SituationObs.compute(env.map, t, perception, env.waypoint, 6, 2)
	check(old[14] == 0 and old[15] == 0, "fixture reproduces the original blind spot")
	check(improved[14] > 0.5 and improved[15] > 0.5, "fan rays detect obstacles between old rays")
	check(old.size() == improved.size() and improved.size() == 30, "existing model input width retained")
	check(env._observation(0).size() == 389, "base observation width unchanged")
	env.free()
	# A wall beyond the old 60m range must be visible early enough to plan a detour.
	env = fixture("tiger1", true, [{"type": "stone", "p": [0, -68], "size": [60, 3.5, 3], "yaw": 0}])
	await physics_frame
	await physics_frame
	t = env.tanks[0]
	perception = env.agents[0].perception
	old = SituationObs.compute(env.map, t, perception, env.waypoint, 6, 1)
	improved = SituationObs.compute(env.map, t, perception, env.waypoint, 6, 2)
	check(old[14] == 0 and improved[14] > 0.4, "long range wall detection")
	env.free()
	for tank_id in ["tiger1", "sherman75", "t34_76"]:
		await drive_course(tank_id, wall, PI)
		await drive_course(tank_id, [
			{"type": "stone", "p": [-22, -35], "size": [36, 3.5, 3], "yaw": 0},
			{"type": "stone", "p": [38, -35], "size": [20, 3.5, 3], "yaw": 0},
			{"type": "stone", "p": [22, -70], "size": [36, 3.5, 3], "yaw": 0},
			{"type": "stone", "p": [-38, -70], "size": [20, 3.5, 3], "yaw": 0}], 0.0)
	print("Driving v2: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
