extends SceneTree
var checks := 0
var failures := 0


func _initialize() -> void:
	call_deferred("run")


func check(ok: bool, message: String) -> void:
	checks += 1
	print("PASS " if ok else "FAIL ", message)
	if not ok:
		failures += 1


func new_map(visuals := false) -> HillMap:
	var map := HillMap.new()
	map.size_m = 240
	map.cell_m = 4
	map.height_amplitude = 0
	map.features_enabled = false
	map.visuals_enabled = visuals
	root.add_child(map)
	return map


func shape_index(shape: CollisionShape3D) -> int:
	var body: CollisionObject3D = shape.get_parent()
	for owner in body.get_shape_owners():
		if body.shape_owner_get_owner(owner) == shape:
			return body.shape_owner_get_shape_index(owner, 0)
	return -1


func run() -> void:
	for seed_v in range(1, 6):
		var map := new_map()
		map.add_woods(Vector2.ZERO, 22, seed_v)
		check(not map.is_spawn_safe(Vector2.ZERO), "forest spawn rejected before physics sync, seed %d" % seed_v)
		var rng := RandomNumberGenerator.new()
		rng.seed = seed_v
		var spot := map.find_safe_spawn(Vector2.ZERO, rng)
		check(spot != Vector2.INF and map.is_spawn_safe(spot), "relocated to clear pad with exit, seed %d" % seed_v)
		var other := map.find_safe_spawn(spot, rng, [spot])
		check(other != Vector2.INF and other.distance_to(spot) >= 12, "spawn separation, seed %d" % seed_v)
		for id in map.destruction.items:
			var item: Dictionary = map.destruction.items[id]
			if item.kind != "tree":
				continue
			var pos: Vector3 = item.shape.position
			var a := Vector3(pos.x - 2, 2, pos.z)
			var b := Vector3(pos.x + 2, 2, pos.z)
			var opaque: float = LineOfSight.foliage(map, a, b).transmittance
			map.destruction.damage(item.shape.get_parent(), shape_index(item.shape), 100, "test")
			check(opaque < .99 and float(LineOfSight.foliage(map, a, b).transmittance) > .99, "fallen forest tree opens a local sight corridor, seed %d" % seed_v)
			break
		map.free()
	var enclosed := new_map()
	enclosed.add_training_barrier(Vector2(0, -10), Vector3(24, 3, 2))
	enclosed.add_training_barrier(Vector2(0, 10), Vector3(24, 3, 2))
	enclosed.add_training_barrier(Vector2(-10, 0), Vector3(2, 3, 24))
	enclosed.add_training_barrier(Vector2(10, 0), Vector3(2, 3, 24))
	check(enclosed.is_clear(Vector2.ZERO, 5) and not enclosed.is_spawn_safe(Vector2.ZERO), "empty pad surrounded by walls rejected")
	enclosed.add_building(Vector2.ZERO, Vector3(500, 20, 500))
	check(enclosed.find_safe_spawn(Vector2.ZERO, RandomNumberGenerator.new()) == Vector2.INF, "no unsafe fallback when whole map blocked")
	enclosed.free()
	var map := new_map(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	map._ensure_foliage_area()
	map._add_lone_tree(Vector2(0, -12), rng)
	map.add_wall(Vector2(-8, -24), Vector2(8, -24))
	map.add_hedge(Vector2(-8, -35), Vector2(8, -35))
	map.add_building(Vector2(30, -15), Vector3(8, 8, 8))
	map.finish_layout()
	var tree_id := -1
	for id in map.destruction.items:
		if map.destruction.items[id].kind == "tree":
			tree_id = id
	var tree: Dictionary = map.destruction.items[tree_id]
	var foliage: Dictionary = tree.foliage[0][0]
	var height := (float(foliage.y0) + float(foliage.y1)) * 0.5
	var before: float = LineOfSight.foliage(map, Vector3(-3, height, -12), Vector3(3, height, -12)).transmittance
	var tank := Tank.new()
	tank.setup("tiger1", 0, 44)
	tank.position = Vector3(0, .5, 0)
	root.add_child(tank)
	tank.set_physics_process(false)
	var rec := MatchRecorder.new()
	rec.auto_end = false
	rec.write_report = false
	rec.log_root = "user://spawn_destruction_tests"
	root.add_child(rec)
	rec.start(map, [tank])
	rec.set_physics_process(false)
	await physics_frame
	await physics_frame
	var shot := tank.fire()
	check(shot.get("obstacle_damage", {}).get("destroyed", false), "real shell destroys tree trunk")
	check(tree.shape.disabled, "destroyed trunk collision disabled")
	var after: float = LineOfSight.foliage(map, Vector3(-3, height, -12), Vector3(3, height, -12)).transmittance
	check(before < .8 and after > .99, "fallen crown no longer blocks sight")
	var visual_id: int = tree.visuals[0]
	var ref: Array = map._visual_refs[visual_id]
	check(map._mm[ref[0]][ref[1]].basis.get_scale().length() < .001, "tree visual transforms removed")
	if DisplayServer.get_name() != "headless":
		check(map._mm_nodes[ref[0]].multimesh.get_instance_transform(ref[1]).basis.get_scale().length() < .001, "GPU tree instances removed")
	rec.tick = 3
	rec._write_frame()
	map.destruction.set_destroyed([])
	check(not tree.shape.disabled and map.foliage_clearings.is_empty(), "replay rewind restores tree collision and foliage")
	check(map._mm[ref[0]][ref[1]].basis.get_scale().length() > .1, "replay rewind restores visuals")
	if DisplayServer.get_name() != "headless":
		check(map._mm_nodes[ref[0]].multimesh.get_instance_transform(ref[1]).basis.get_scale().length() > .1, "GPU tree instances restored")
	tank.control = TankControlInput.from_array([1, 1, 0, 0, 0, 0])
	for tick in 600:
		tank.step(1.0 / 30.0)
		await physics_frame
		if tank.position.z < -44:
			break
	check(tank.position.z < -44, "tank physically pushes through tree, stone wall and hedge")
	var kinds := {}
	for id in map.destruction.destroyed_ids():
		kinds[map.destruction.items[id].kind] = true
	check(kinds.has("tree") and kinds.has("wall") and kinds.has("hedge"), "all three material types crushed")
	rec.tick += 600
	rec._write_frame()
	rec.end_episode("test", -1)
	var data := ReplayData.load_file(rec.events_path)
	check(not data.obstacle_events.is_empty() and not data.frames[-1].get("destroyed", []).is_empty(), "destruction events and frame state recorded")
	var replay := new_map(true)
	replay.load_record(data.header.map)
	replay.destruction.set_destroyed(data.frames[-1].destroyed)
	check(replay.destruction.destroyed_ids() == map.destruction.destroyed_ids(), "recorded map reconstructs same destroyed IDs")
	replay.destruction.set_destroyed(data.frames[0].get("destroyed", []))
	check(replay.destruction.destroyed_ids().is_empty(), "recorded map supports backward seeking")
	replay.free()
	map.destruction.reset()
	check(map.destruction.destroyed_ids().is_empty() and not tree.shape.disabled, "episode reset restores all obstacles")
	for id in map.destruction.items:
		var item: Dictionary = map.destruction.items[id]
		if item.kind == "wall":
			map.destruction.damage(item.shape.get_parent(), shape_index(item.shape), 20, "test")
			check(float(item.hp) < 100, "partial wall damage tracked")
			map.destruction.reset()
			check(float(item.hp) == 100, "episode reset restores partially damaged wall")
			break
	check(map.destruction.id_for(map._bodies.building, 0) == -1, "buildings remain solid")
	map.free()
	tank.free()
	rec.free()
	print("Spawn/destruction tests: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
