extends SceneTree

class Harness extends "res://training/training_env.gd":
	func _ready() -> void:
		set_physics_process(false)

var failures := 0
var checks := 0


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)


func fixture(id := "approach", seed_v := 123) -> Harness:
	var env := Harness.new()
	root.add_child(env)
	env.reset_episode({"seed": seed_v, "uid": "terrain_test", "kind": "drive", "stage": "drive_terrain",
		"time_limit_s": 110, "save_episode": false,
		"map": {"seed": seed_v, "features": false, "amplitude": 0, "profile": "slope" if id == "slope" else ("rough" if id == "rough" else "flat"), "size_m": 240, "cell_m": 4, "ridge_count": 0},
		"tanks": [{"type": "tiger1", "team": 0, "ctrl": "external"}],
		"terrain_course": {"id": id, "version": 3, "distance": [60, 85], "goal_radius": 5,
			"checkpoint_radius": 5, "stop_speed": 1, "hold_s": 0.6, "no_progress_s": 20},
		"reward": {"progress": 4, "checkpoint": 1, "arrive": 8, "failure": -2, "time_per_s": -0.02}})
	for t in env.tanks:
		t.set_physics_process(false)
	return env


func decide(env: Harness) -> Dictionary:
	env.tick += 3
	return env.rewarder.decision()


func hold(env: Harness) -> Dictionary:
	var result := {"done": false}
	for i in 8:
		result = decide(env)
		if result.done:
			break
	return result


func run() -> void:
	for id in TerrainCourse.IDS:
		var env := fixture(id)
		var layout: Dictionary = env.config.terrain_layout
		check(JSON.stringify(layout) == JSON.stringify(TerrainCourse.plan(env.config)), id + ": same seed is reproducible")
		var changed: Dictionary = env.config.duplicate(true)
		changed.seed = 456
		check(JSON.stringify(layout) != JSON.stringify(TerrainCourse.plan(changed)), id + ": episode seed changes layout")
		check(not TerrainCourse.outside(layout, env.tanks[0].global_position), id + ": valid spawn")
		check(env.map.is_spawn_safe(Vector2(layout.spawn[0], layout.spawn[1])), id + ": clear spawn and exit")
		if id == "slope" or id == "rough":
			check(absf(env.map.height_at(layout.spawn[0], layout.spawn[1]) - env.map.height_at(layout.route[-1][0], layout.route[-1][1])) > 0.01, id + ": practice terrain is not flat")
		check(env._observation(0).size() == 444, id + ": observation width (V6: 389 + 46 + 9)")
		# A tank-sized centre path must exist between all task waypoints.
		var from := Vector2(layout.spawn[0], layout.spawn[1])
		for point in layout.route:
			var to := Vector2(point[0], point[1])
			for k in 101:
				var p := from.lerp(to, k / 100.0)
				for tree in layout.get("trees", []):
					check(p.distance_to(Vector2(tree.position[0], tree.position[1])) > 5.0, id + ": clear path through trees")
				for box in layout.obstacles:
					if float(box.size[1]) <= 0.8:
						continue
					var delta := (p - Vector2(box.position[0], box.position[1])).rotated(float(box.yaw))
					check(absf(delta.x) >= float(box.size[0]) * 0.5 + 3.0 or absf(delta.y) >= float(box.size[2]) * 0.5 + 3.0,
						id + ": feasible centre path through obstacles")
			from = to
		# Visiting every target at speed cannot count as success.
		var t: Tank = env.tanks[0]
		t.global_position = env.waypoint
		t.track_speed_left = 5.0
		t.track_speed_right = 5.0
		check(not hold(env).done, id + ": driving through target is not arrival")
		t.track_speed_left = 0.0
		t.track_speed_right = 0.0
		var result := {"done": false}
		for point in env.course_route:
			t.global_position = point
			result = hold(env)
		check(result.get("success", false), id + ": stopping at ordered targets succeeds")
		var summary: Dictionary = env.rewarder.course_summary()
		check(summary.checkpoints == env.course_route.size() - 1, id + ": each checkpoint counted once")
		check(float(summary.reward_components.progress) <= 4.00001, id + ": progress reward bounded by 4")
		env.free()
	var env := fixture()
	var t: Tank = env.tanks[0]
	var initial := t.global_position
	var toward: Vector3 = (env.waypoint - initial).normalized() * 10.0
	t.global_position = initial + toward
	decide(env)
	var first: float = env.rewarder.course_summary().reward_components.progress
	for i in 10:
		t.global_position = initial
		decide(env)
		t.global_position = initial + toward
		decide(env)
	check(is_equal_approx(first, float(env.rewarder.course_summary().reward_components.progress)), "oscillation cannot farm progress")
	var ended := {"done": false}
	for i in 210:
		ended = decide(env)
		if ended.done:
			break
	check(ended.get("reason", "") == "no_progress", "stationary policy ends after 20 seconds without progress")
	env.free()
	env = fixture()
	env.tanks[0].global_position = Vector3(1000, 0, 1000)
	check(decide(env).get("reason", "") == "out_of_bounds", "leaving the trial area fails explicitly")
	env.free()
	print("Terrain tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
