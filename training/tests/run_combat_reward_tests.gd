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

func fixture() -> Harness:
	var env := Harness.new()
	root.add_child(env)
	env.reset_episode({"seed": 101, "stage": "final_battle", "kind": "combat", "time_limit_s": 180,
		"save_episode": false, "map": {"features": false, "amplitude": 0, "size_m": 360, "ridge_count": 0},
		"spawn": {"distance": [200, 200], "center_jitter": 0, "yaw_jitter_deg": 0},
		"tanks": [{"type": "tiger1", "team": 0, "ctrl": "external"},
			{"type": "tiger1", "team": 0, "ctrl": "external"}, {"type": "sherman75", "team": 1, "ctrl": "external"}],
		"reward": {"battle_shaping": true, "time_per_s": 0, "spot": 0,
			"combat": {"hit": 5, "penetration": 3, "knockout": 12, "miss": -0.05, "live_target_only": true}}})
	for t in env.tanks:
		t.set_physics_process(false)
	env.tanks[0].position = Vector3(0, .5, 100)
	env.tanks[1].position = Vector3(120, .5, 100)
	env.tanks[2].position = Vector3(0, .5, -100)
	for t in env.tanks:
		t.rotation = Vector3.ZERO
		t.turret_yaw = 0
		t.gun_pitch = 0
		t._sync_turret()
	env.rewarder = TrainingReward.new(env, env.config.reward)
	env.rewarder.start()
	return env

func near_result(target: String, miss: float, team := 1, distance := 100) -> Dictionary:
	return {"hit": false, "near_miss": {"target_name": target, "target_team": team,
		"miss_distance_m": miss, "range_m": distance}}

func run() -> void:
	var env := fixture()
	var t: Tank = env.tanks[0]
	var enemy: Tank = env.tanks[2]
	var shot := {"hit": true, "target_name": enemy.name, "target_team": 1, "target_was_combat_effective": true}
	env.rewarder.on_shot(t, shot)
	check(is_equal_approx(env.rewarder.total(t.name), 5), "non-penetrating live hit earns five points")
	shot.penetrated = true
	env.rewarder.on_shot(t, shot)
	check(is_equal_approx(env.rewarder.total(t.name), 13), "penetration adds three to the five point hit")
	shot.events = ["knocked_out:crew"]
	env.rewarder.on_shot(t, shot)
	check(is_equal_approx(env.rewarder.total(t.name), 33), "knockout adds twelve to hit and penetration")
	shot.target_was_combat_effective = false
	env.rewarder.on_shot(t, shot)
	check(is_equal_approx(env.rewarder.total(t.name), 32.95), "wreck hits cost ammunition and give no damage bonus")
	shot = {"hit": true, "target_name": env.tanks[1].name, "target_team": 0}
	env.rewarder.on_shot(t, shot)
	check(is_equal_approx(env.rewarder.total(t.name), 27.95), "friendly hits lose five points")
	env.free()
	env = fixture()
	t = env.tanks[0]
	enemy = env.tanks[2]
	env.rewarder.on_shot(t, near_result(enemy.name, 3))
	check(is_equal_approx(env.rewarder.total(t.name), .7), "three metre miss earns 0.75 minus shot cost")
	env.rewarder.on_shot(t, near_result(enemy.name, 3))
	check(is_equal_approx(env.rewarder.total(t.name), .65), "identical near misses cannot farm reward")
	env.rewarder.on_shot(t, near_result(enemy.name, 1.5))
	check(is_equal_approx(env.rewarder.total(t.name), .725), "only improved miss distance earns an extra bonus")
	var before: float = env.rewarder.total(t.name)
	env.rewarder.on_shot(t, near_result(env.tanks[1].name, 0, 0))
	env.rewarder.on_shot(t, near_result(enemy.name, 0, 1, 10))
	check(is_equal_approx(env.rewarder.total(t.name), before - .1), "friendly and point-blank misses receive no bonus")
	for i in 10:
		env.rewarder.on_shot(t, near_result("enemy%d" % i, 0))
	check(is_equal_approx(env.rewarder._near_paid[t.name], 3), "all near-miss rewards are capped at three per battle")
	check(env.rewarder.hits.get(t.name, 0) == 0, "near misses do not inflate hit statistics")
	env.free()
	env = fixture()
	t = env.tanks[0]
	enemy = env.tanks[2]
	t.position.z = 90
	env.rewarder.decision()
	check(is_equal_approx(env.rewarder._closing_paid[t.name], .3), "own ten metre advance earns 0.3")
	check(is_equal_approx(env.rewarder._closing_paid[enemy.name], 0), "enemy movement alone cannot reward a stationary tank")
	for z in [100, 90, 100, 90]:
		t.position.z = z
		env.rewarder.decision()
	check(is_equal_approx(env.rewarder._closing_paid[t.name], .3), "reversing and reapproaching cannot repeat progress")
	t.position.z = 40
	env.rewarder.decision()
	check(is_equal_approx(env.rewarder.battle_summary()[t.name].close_150m, .5), "first 150m crossing receives a milestone")
	t.position.z = -80
	env.rewarder.decision()
	check(is_equal_approx(env.rewarder._closing_paid[t.name], 4), "closing progress is capped at four")
	var parts: Dictionary = env.rewarder.battle_summary()[t.name]
	check(parts.close_100m == .75 and parts.close_60m == 1.0 and parts.close_30m == 1.5, "closer milestones are paid once")
	var total := env.rewarder.total(t.name)
	var sum_parts := 0.0
	for value in parts.values():
		sum_parts += float(value)
	check(is_equal_approx(total, sum_parts), "reported components sum to the actual PPO reward")
	env.free()
	# Verify actual ballistic geometry rather than an infinite aim ray.
	env = fixture()
	t = env.tanks[0]
	enemy = env.tanks[2]
	enemy.position = Vector3(0, .5, 0)
	var aim := t.aim_solution(enemy.position + Vector3.UP * (enemy.spec.hull_bottom_y + enemy.spec.hull_size.y * .5))
	t.turret_yaw = aim.turret_yaw
	t.gun_pitch = aim.gun_pitch
	t.aim_error_mrad = 0
	t._sync_turret()
	await physics_frame
	await physics_frame
	var actual_hit := t.fire()
	check(actual_hit.hit and actual_hit.get("target_was_combat_effective", false), "physical tank hit carries the live-target flag")
	check(env.rewarder.total(t.name) >= 5 and env.rewarder.hits.get(t.name, 0) == 1, "physical tank hit earns the large real training bonus")
	env.free()
	env = fixture()
	t = env.tanks[0]
	enemy = env.tanks[2]
	enemy.position = Vector3(8, .5, 0)
	t.aim_error_mrad = 0
	await physics_frame
	await physics_frame
	var result := t.fire()
	check(not result.hit and result.get("near_miss", {}).get("target_name", "") == enemy.name, "actual passing shell records a near miss")
	check(float(env.rewarder._near_paid[t.name]) > 0, "physical near miss reaches the training reward")
	env.map.add_stone(Vector2(0, 5), Vector3(30, 6, 2))
	await physics_frame
	await physics_frame
	result = t.fire()
	check(not result.hit and result.get("near_miss", {}).is_empty(), "shell blocked by nearby wall cannot earn through-wall near-miss reward")
	env.free()
	env = fixture()
	t = env.tanks[0]
	var rec := MatchRecorder.new()
	rec.external_rewards = true
	rec.write_files = false
	rec.write_report = false
	rec.auto_end = false
	env.add_child(rec)
	rec.start(env.map, env.tanks)
	rec.set_physics_process(false)
	env.recorder = rec
	shot = {"hit": true, "target_name": env.tanks[2].name, "target_team": 1}
	env.rewarder.on_shot(t, shot)
	rec._on_shot(t, shot)
	check(is_equal_approx(rec.tank_scores[t.name], 5), "replay score receives the training hit exactly once")
	t.position.z = 80
	env.rewarder.decision()
	check(is_equal_approx(rec.tank_scores[t.name], env.rewarder.total(t.name)), "replay score also includes approach shaping")
	env.tick = env.time_limit_ticks
	env.rewarder.decision()
	check(is_equal_approx(env.rewarder.battle_summary()[t.name].timeout, -4), "timeout discourages collecting approach rewards and waiting")
	check(is_equal_approx(rec.tank_scores[t.name], env.rewarder.total(t.name)), "timeout score matches the training return")
	rec.end_episode("test", 0)
	check(is_equal_approx(rec.tank_scores[t.name], env.rewarder.total(t.name)), "replay end does not add a second victory bonus")
	env.free()
	print("Combat rewards: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
