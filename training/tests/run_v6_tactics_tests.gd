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

func _initialize() -> void:
	call_deferred("run")

func amount(items: Array, reason: String) -> float:
	var value := 0.0
	for item in items:
		if item.reason == reason:
			value += float(item.value)
	return value

func run() -> void:
	var env := Harness.new()
	root.add_child(env)
	env.reset_episode({"uid": "v6_tactics_tests", "seed": 97, "stage": "duel_scripted", "kind": "combat",
		"time_limit_s": 150, "record": false,
		"map": {"seed": 9, "size_m": 600, "cell_m": 4, "amplitude": 0, "features": false, "ridge_count": 0},
		"tanks": [{"type": "tiger1", "team": 0, "ctrl": "external"},
			{"type": "sherman75", "team": 1, "ctrl": "external"}]})
	for t in env.tanks:
		t.set_physics_process(false)
	var me: Tank = env.tanks[0]
	var enemy: Tank = env.tanks[1]
	me.position = Vector3(0, 0.5, 100)
	enemy.position = Vector3(0, 0.5, -100)
	await physics_frame
	await physics_frame
	var cfg := {"per_m": 0.4, "budget": 20.0, "open_bonus": 8.0, "stall_per_s": 0.1}
	var probe := FiringPositionProgress.new(env, cfg)
	check(probe.clear_fraction(me, enemy, me.global_position) > 0, "open flat ground has a firing opportunity")
	check(is_zero_approx(amount(probe.step(me, 0.5, 0.5), "fireline_open")), "initial visibility is not a relocation bonus")
	env.map.add_stone(Vector2(0, 0), Vector3(12, 20, 10))
	await physics_frame
	await physics_frame
	check(is_zero_approx(probe.clear_fraction(me, enemy, me.global_position)), "wall blocks firing opportunity despite high penetration")
	probe = FiringPositionProgress.new(env, cfg)
	probe.step(me, 0.5, 0.5)
	var s: Dictionary = probe.states[me.name]
	var start := me.position
	var goal: Vector3 = s.goal
	check(start.distance_to(goal) > 5 and probe._walkable(me, start, goal), "reward search finds a reachable reposition goal")
	me.position = start.lerp(goal, 0.1)
	var first := amount(probe.step(me, 1.0, 0.5), "fireline_progress")
	check(first > 0 and first <= 20, "moving toward an opening earns bounded immediate progress before LOS opens")
	me.position = start
	probe.step(me, 2.0, 0.5)
	me.position = start.lerp(goal, 0.1)
	check(is_zero_approx(amount(probe.step(me, 2.5, 0.5), "fireline_progress")), "repeating the same movement earns no progress")
	check(float(s.paid) <= 20, "episode progress stays within its budget")
	me.position = start
	var rw := {"battle_shaping": true, "time_per_s": 0, "combat": {"miss": 0}, "reposition": cfg,
		"position": {"version": 2, "attack": 20.0, "threat": 10.0}}
	env.rewarder = TrainingReward.new(env, rw)
	env.rewarder.start()
	env.rewarder._position_step(rw.position)
	check(is_zero_approx(env.rewarder._pos_phi[me.name]), "occluded penetration alone earns no position potential")
	me.position.x = 70
	await physics_frame
	env.rewarder._position_step(rw.position)
	var paid := env.rewarder.total(me.name)
	check(paid > 0, "opening a real firing line improves position potential")
	me.position = start
	await physics_frame
	env.rewarder._position_step(rw.position)
	me.position.x = 70
	await physics_frame
	env.rewarder._position_step(rw.position)
	check(is_equal_approx(env.rewarder.total(me.name), paid), "LOS position reward cannot be farmed by going back and forth")
	var before := env.rewarder.total(me.name)
	env.rewarder.on_shot(me, {"hit": false, "blocked_by": "Terrain"})
	check(is_equal_approx(env.rewarder.total(me.name) - before, -0.3), "actual terrain-blocked shot receives its extra cost")
	before = env.rewarder.total(me.name)
	env.rewarder.on_shot(me, {"hit": false, "blocked_by": "none"})
	check(is_equal_approx(env.rewarder.total(me.name), before), "unblocked miss does not receive blocked-shot cost")
	env.free()
	print("V6 tactics: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
