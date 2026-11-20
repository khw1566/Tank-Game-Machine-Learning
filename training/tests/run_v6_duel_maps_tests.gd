extends SceneTree

class Harness extends "res://training/training_env.gd":
	func _ready() -> void:
		set_physics_process(false)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OS.get_cmdline_user_args()[0]))
	var env := Harness.new()
	root.add_child(env)
	var counts := {}
	var failures := 0
	for cfg in fixture.cases:
		env.reset_episode(cfg)
		for tank in env.tanks:
			tank.set_physics_process(false)
		await physics_frame
		await physics_frame
		var a: Tank = env.tanks[0]
		var b: Tank = env.tanks[1]
		var probe := FiringPositionProgress.new(env, {})
		var sight_a := LineOfSight.target_visibility(env.map, a, b)
		var sight_b := LineOfSight.target_visibility(env.map, b, a)
		var open := float(sight_a.visible_fraction) > 0.01 or float(sight_b.visible_fraction) > 0.01 \
			or probe.clear_fraction(a, b, a.global_position) > 0 or probe.clear_fraction(b, a, b.global_position) > 0
		var concealed := bool(cfg.scenario.v6.get("concealed_start", false))
		var label: String = cfg.scenario.variant + ("/new" if concealed else "/legacy")
		if not counts.has(label):
			counts[label] = {"total": 0, "open": 0, "relocated": 0, "start_exits": 0, "fireline_goals": 0}
		var stat: Dictionary = counts[label]
		stat.total += 1
		stat.open += int(open)
		stat.relocated += int(not env.config.scenario_relocated.is_empty())
		if not concealed:
			continue
		var positions := [[a, b], [b, a]]
		var exits := 0
		for pair in positions:
			var actor: Tank = pair[0]
			var opponent: Tank = pair[1]
			var start := actor.global_position
			start.y = env.map.height_at(start.x, start.z)
			stat.fireline_goals += int(probe.clear_fraction(actor, opponent, probe._goal(actor, opponent)) > 0)
			for flank in [-1.0, 1.0]:
				var exit := Vector3(float(flank) * float(fixture.flank_x), 0.0, signf(start.z) * float(fixture.flank_z))
				exit.y = env.map.height_at(exit.x, exit.z)
				var walkable := probe._walkable(actor, start, exit)
				var clear := probe.clear_fraction(actor, opponent, exit)
				if walkable and clear > 0:
					exits += 1
				elif failures < 4:
					print("%s %s to %s: walkable=%s clear=%s" % [cfg.uid, start, exit, walkable, clear])
		stat.start_exits += exits
		if open or not env.config.scenario_relocated.is_empty() or exits != 4:
			failures += 1
			if failures <= 12:
				push_error("%s: spawn open=%s, moved=%s, working flanks=%s/4" % [cfg.uid, open, env.config.scenario_relocated, exits])
	env.free()
	print(JSON.stringify(counts))
	print("V6 duel openings: %d failed generated starts" % failures)
	quit(1 if failures else 0)
