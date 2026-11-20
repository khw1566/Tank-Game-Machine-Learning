extends SceneTree

class Harness extends "res://training/training_env.gd":
	func _ready() -> void:
		set_physics_process(false)

var failures := 0
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func config() -> Dictionary:
	return {"battle_shaping": true, "progressive_combat_v2": true, "attack_shaping_version": 1,
		"time_per_s": 0, "spot": 0, "near_miss_radius_m": 4.0, "near_miss_radius_ratio": 0.03,
		"near_miss_max_radius_m": 12.0, "near_miss_bonus": 0.15, "near_miss_budget": 3.0,
		"aim_alignment_bonus": 2.0, "aim_alignment_budget": 6.0,
		"aim_overlap_per_s": 0.3, "aim_overlap_budget": 8.0, "aimed_fire_bonus": 2.0, "aimed_fire_budget": 8.0,
		"friendly_aim_fire_penalty": 4.0,
		"combat": {"hit": 0.2, "penetration": 8.0, "knockout": 25.0,
			"friendly_fire": -3.0, "friendly_knockout": -60.0, "live_target_only": true}}

func _initialize() -> void:
	call_deferred("run")

func aim_at(t: Tank, target: Tank) -> void:
	var point := target.global_transform * Vector3(0, target.spec.hull_bottom_y + target.spec.hull_size.y * 0.55, 0)
	var aim := t.aim_solution(point)
	t.turret_yaw = aim.turret_yaw
	t.gun_pitch = aim.gun_pitch
	t._sync_turret()

func run() -> void:
	var cfg := config()
	var values := []
	for miss in [0.0, 3.0, 6.0, 9.0]:
		var progress := CombatProgress.new(cfg)
		values.append(progress.near_miss("a", {"target_name": "b", "range_m": 300, "miss_distance_m": miss, "penetration_ratio": 1.0}))
	check(is_equal_approx(values[0], 0.15) and is_equal_approx(values[1], 0.1) and is_equal_approx(values[2], 0.05) and values[3] == 0, "near-miss reward is linear in miss / range-scaled radius")
	var progress := CombatProgress.new(cfg)
	check(progress.near_miss("a", {"target_name": "b", "range_m": 10, "miss_distance_m": 0}) == 0, "no point-blank near-miss farming")
	for i in 100:
		progress.near_miss("a", {"target_name": "b", "range_m": 300, "miss_distance_m": 0, "penetration_ratio": 1.0})
	check(is_equal_approx(progress.miss_paid.a, 3.0), "repeated near misses obey episode budget")
	var straight := progress.aim_quality(Vector3.FORWARD, Vector3(0, 0, -100), 2)
	var off := progress.aim_quality(Vector3.FORWARD, Vector3(1, 0, -100), 2)
	var behind := progress.aim_quality(Vector3.FORWARD, Vector3(0, 0, 100), 2)
	check(straight.alignment > off.alignment and straight.overlap > off.overlap and behind.alignment == 0, "aim quality improves with alignment and overlap; rejects targets behind gun")
	for i in 1000:
		progress.aim("a", str(i), 1.0, 1.0, 0.5)
		progress.aimed_fire("a", 1.0)
	check(is_equal_approx(progress.attack_paid["a:aim_alignment"], 6.0) and is_equal_approx(progress.attack_paid["a:aim_overlap"], 8.0) and is_equal_approx(progress.attack_paid["a:aimed_fire"], 8.0), "switching targets and repeated firing cannot exceed shared budgets")
	var old := RewardModel.new({"hit": 0.2, "penetration": 8.0, "knockout": 25.0})
	var new := RewardModel.new(cfg.combat)
	var shot := {"hit": true, "penetrated": true, "events": ["knocked_out:crew"], "target_was_combat_effective": true}
	var baseline: Array = old.shot_rewards("a", 1, "b", 1, shot)
	var severe: Array = new.shot_rewards("a", 1, "b", 1, shot)
	check(is_equal_approx(severe[0].value, baseline[0].value * 3) and severe[1].reason == "friendly_knockout" and severe[1].value == -60, "friendly damage costs triple plus sixty for teamkill")
	var env := Harness.new()
	root.add_child(env)
	env.reset_episode({"seed": 101, "stage": "final_1v6", "kind": "combat", "save_episode": false,
		"map": {"features": false, "profile": "flat", "amplitude": 0, "size_m": 360, "ridge_count": 0},
		"tanks": [{"type": "sherman75", "team": 1, "ctrl": "external"},
			{"type": "sherman75", "team": 1, "ctrl": "external"}, {"type": "tiger1", "team": 0, "ctrl": "external"}], "reward": cfg})
	for tank in env.tanks:
		tank.set_physics_process(false)
	# Legacy fixtures are grouped by team during spawn (Germany first).
	var t: Tank = env.tanks[1]
	var ally: Tank = env.tanks[2]
	var enemy: Tank = env.tanks[0]
	t.position = Vector3(0, .5, 100)
	ally.position = Vector3(70, .5, 0)
	enemy.position = Vector3(0, .5, -100)
	aim_at(t, enemy)
	await physics_frame
	await physics_frame
	var clear := FireLineObs.compute(t, env.agents[1].perception, env.tanks)
	check(clear[0] == 0.0 and clear[5] == 0.0, "fire line: ally off to the side is not in the line of fire")
	env.rewarder = TrainingReward.new(env, cfg)
	env.rewarder.start()
	env.rewarder._attack_aim(t, 0.5)
	var parts: Dictionary = env.rewarder.battle_summary()[t.name]
	check(float(parts.get("aim_alignment", 0)) > 0 and float(parts.get("aim_overlap", 0)) > 0, "real ballistic aim at a visible enemy earns proportional reward")
	var before_launch := env.rewarder.total(t.name)
	var launch := {"from": TankSpec._v(t.muzzle_position()), "dir": TankSpec._v(t.gun_direction())}
	env.rewarder.on_launch(t, launch)
	check(float(env.rewarder.battle_summary()[t.name].get("aimed_fire", 0)) > 0, "aligned enemy firing earns bounded aggression bonus")
	var actual_hit := launch.merged({"hit": true, "penetrated": true, "target_name": str(enemy.name), "target_team": enemy.team})
	env.rewarder.on_shot(t, actual_hit)
	var captured := 0.0
	for reward in actual_hit.reward_events:
		check(reward.has("before") and reward.has("after") and is_equal_approx(float(reward.after) - float(reward.before), float(reward.value)), "recorded shot reward balances before, delta and after")
		if str(reward.tank) == str(t.name): captured += float(reward.value)
	check(is_equal_approx(captured, env.rewarder.total(t.name) - before_launch), "shot record captures launch and impact reward exactly without continuous aim")
	ally.position = Vector3(0, .5, 0)
	aim_at(t, ally)
	await physics_frame
	await physics_frame
	var blocked := FireLineObs.compute(t, env.agents[1].perception, env.tanks)
	check(blocked[0] == 1.0 and blocked[5] == 1.0 and blocked[1] > 0.15 and blocked[1] < 0.25, "fire line: ally between shooter and enemy is flagged (%s)" % [blocked])
	env.rewarder = TrainingReward.new(env, cfg)
	env.rewarder.start()
	env.rewarder.on_launch(t, {"from": TankSpec._v(t.muzzle_position()), "dir": TankSpec._v(t.gun_direction())})
	parts = env.rewarder.battle_summary()[t.name]
	check(float(parts.get("friendly_aim_fire", 0)) < 0 and float(parts.get("aimed_fire", 0)) == 0, "firing at an ally costs points before impact and never earns enemy firing bonus")
	ally.position.x = 70
	aim_at(t, enemy)
	env.map.add_stone(Vector2(0, 0), Vector3(30, 20, 8))
	await physics_frame
	await physics_frame
	env.rewarder = TrainingReward.new(env, cfg)
	env.rewarder.start()
	env.rewarder._attack_aim(t, 0.5)
	env.rewarder.on_launch(t, {"from": TankSpec._v(t.muzzle_position()), "dir": TankSpec._v(t.gun_direction())})
	check(is_zero_approx(env.rewarder.total(t.name)), "occluded enemies give no aim or firing rewards")
	# V6 비례 보상(전력 교환): 2대 팀(연합군) vs 1대(티거)
	var ex_cfg := cfg.duplicate(true)
	ex_cfg["exchange"] = {"version": 1, "enemy": 200.0, "own": 120.0, "win": 100.0, "loss": -60.0, "contrib": 0.0}
	env.rewarder = TrainingReward.new(env, ex_cfg)
	env.rewarder.start()
	ally.damage.knockout_cause = "test"          # 연합군 1대 격파 → 연합군 전력 1/2 손실
	env.rewarder._exchange_settle()
	check(is_equal_approx(env.rewarder.total(enemy.name), 100.0), "exchange: Tiger gains 200 x 1/2 for one of two enemies (%s)" % env.rewarder.total(enemy.name))
	check(is_equal_approx(env.rewarder.total(t.name), -60.0), "exchange: allied teammate loses 120 x 1/2 (%s)" % env.rewarder.total(t.name))
	env.rewarder._exchange_settle()
	check(is_equal_approx(env.rewarder.total(enemy.name), 100.0), "exchange: the same loss is paid only once")
	env.rewarder._exchange_outcome(-1)
	check(is_equal_approx(env.rewarder.total(enemy.name), 40.0) and is_equal_approx(env.rewarder.total(t.name), -120.0), "exchange: timeout counts as a loss for both teams")
	ally.damage.knockout_cause = ""
	# V6 맹목 사격 비용: 보이는 적을 겨눈 발사만 면제
	var fd_cfg := cfg.duplicate(true)
	fd_cfg["fire_discipline"] = {"version": 1, "blind": 0.3, "cone_deg": 3.0}
	env.rewarder = TrainingReward.new(env, fd_cfg)
	env.rewarder.start()
	var me_idx: int = env.tanks.find(t)
	env.agents[me_idx].perception.contacts[enemy.name] = {"visible_now": true, "enemy": true, "t": 0.0}
	ally.position = Vector3(70, .5, 0)
	aim_at(t, enemy)
	await physics_frame
	await physics_frame
	check(env.rewarder.aimed_at_visible_enemy(t, 3.0), "fire discipline: aiming at a visible enemy is aimed fire")
	var before_fd := env.rewarder.total(t.name)
	env.rewarder.on_launch(t, {"from": TankSpec._v(t.muzzle_position()), "dir": TankSpec._v(t.gun_direction())})
	check(not is_equal_approx(env.rewarder.total(t.name) - before_fd, -0.3), "fire discipline: aimed fire is not charged as blind")
	aim_at(t, ally)
	await physics_frame
	await physics_frame
	check(not env.rewarder.aimed_at_visible_enemy(t, 3.0), "fire discipline: aiming away from the enemy is blind fire")
	var launch_blind := {"from": TankSpec._v(t.muzzle_position()), "dir": TankSpec._v(t.gun_direction())}
	var before_blind := env.rewarder.total(t.name)
	env.rewarder.on_launch(t, launch_blind)
	check(bool(launch_blind.get("blind_fire", false)) and env.rewarder.total(t.name) - before_blind <= -0.3 + 0.0001, "fire discipline: blind fire costs 0.3 (%s)" % (env.rewarder.total(t.name) - before_blind))
	env.agents[me_idx].perception.contacts[enemy.name]["visible_now"] = false
	aim_at(t, enemy)
	await physics_frame
	await physics_frame
	check(not env.rewarder.aimed_at_visible_enemy(t, 3.0), "fire discipline: firing at an unseen enemy behind cover is blind")
	env.free()
	print("Attack rewards: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
