extends SceneTree

class Harness extends "res://training/training_env.gd":
	func _ready() -> void:
		set_physics_process(false)

var failures := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	if not ok:
		failures += 1
		push_error(message)


func shoot_past(env: Harness, shooter: Tank) -> Dictionary:
	env.projectiles = TrainingProjectileField.new(env)
	env.projectiles.launch(shooter, Vector3(5, 2, 90), Vector3.FORWARD, shooter.current_shell(), {"hit": false})
	for i in 100:
		env.projectiles.step(1.0 / 30.0)
		if env.projectiles.active.is_empty():
			return env._shots.back()
	return {}


func _run() -> void:
	var env := Harness.new()
	root.add_child(env)
	var cfg := {"battle_shaping": true, "progressive_combat_v2": true, "near_miss_visible_pass_only": true,
		"attack_shaping_version": 1, "near_miss_bonus": 0.15, "near_miss_budget": 3.0}
	env.reset_episode({"uid": "v6_occlusion_tests", "seed": 7, "kind": "combat", "record": false,
		"map": {"seed": 9, "size_m": 600, "cell_m": 4, "amplitude": 0, "features": false, "ridge_count": 0},
		"tanks": [{"type": "tiger1", "team": 0, "ctrl": "external"},
			{"type": "sherman75", "team": 1, "ctrl": "external"}], "reward": cfg})
	for t in env.tanks:
		t.set_physics_process(false)
	var me: Tank = env.tanks[0]
	var enemy: Tank = env.tanks[1]
	me.position = Vector3(0, 0, 100)
	enemy.position = Vector3(0, 0, -100)
	me.rotation.y = 0.0
	var observer: TankAgent = env.agents[0]
	observer.view.set_mode(TankView.COMMANDER, me)
	await physics_frame
	await physics_frame
	observer.perception.observe(env.tanks, 0.1)
	check(observer.perception.contacts[enemy.name].visible_now, "open target is currently visible")
	var cover := TargetOcclusionObs.compute(env.map, me, observer.perception, env.tanks)
	check(cover.size() == 12 and cover[0] == 0 and cover[1] == 0, "open tank has zero cover for both parts")
	var hit := shoot_past(env, me)
	check(hit.get("near_miss", {}).get("visible_pass", false), "valid visible near pass is eligible")
	check(hit.get("reward_events", []).any(func(e): return e.reason == "near_miss" and e.value > 0), "visible near pass pays a reward")
	observer.view.cmd_yaw = PI
	observer.perception.observe(env.tanks, 0.1)
	check(not observer.perception.contacts[enemy.name].visible_now, "remembered target is outside the field of view")
	check(not shoot_past(env, me).has("near_miss"), "remembered or unseen target cannot pay a near-miss reward")
	observer.view.cmd_yaw = 0.0
	env.map.add_stone(Vector2(5, -94), Vector3(2, 4, 2))
	await physics_frame
	await physics_frame
	observer.perception.observe(env.tanks, 0.1)
	var short := shoot_past(env, me)
	check(short.get("blocked_by", "none") != "none" and not short.has("near_miss"), "a near impact that stops short of the target is not a pass")

	env.map.add_stone(Vector2(0, -84), Vector3(8, 2, 2))
	await physics_frame
	await physics_frame
	observer.perception.observe(env.tanks, 0.1)
	cover = TargetOcclusionObs.compute(env.map, me, observer.perception, env.tanks)
	check(observer.perception.contacts[enemy.name].visible_now and cover[0] > cover[1] + 0.3 and cover[1] < 0.5,
		"low cover hides hull more than turret: %.2f vs %.2f" % [cover[0], cover[1]])
	env.map.add_stone(Vector2(0, -78), Vector3(8, 8, 2))
	await physics_frame
	await physics_frame
	observer.perception.observe(env.tanks, 0.1)
	cover = TargetOcclusionObs.compute(env.map, me, observer.perception, env.tanks)
	check(not observer.perception.contacts[enemy.name].visible_now and cover[0] == 0 and cover[1] == 0,
		"fully hidden remembered contact receives no live occlusion inputs")
	env.free()
	print("V6 occlusion checks: %d failures" % failures)
	quit(1 if failures else 0)
