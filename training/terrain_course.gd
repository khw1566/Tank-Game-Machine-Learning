class_name TerrainCourse
extends RefCounted
## Seeded, small driving lessons. Obstacles change at reset and stay fixed during a trial.

const VERSION := 3
const IDS := ["approach", "turn_gentle", "turn_wide", "parking", "slope", "low_step", "one_tree", "detour", "gate_wide", "gates", "grove", "rough", "mixed"]


static func plan(config: Dictionary) -> Dictionary:
	var course: Dictionary = config.terrain_course
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.seed)
	var length := rng.randf_range(float(course.distance[0]), float(course.distance[1]))
	var angle := rng.randf_range(-PI, PI)
	var center := Vector2(rng.randf_range(-18, 18), rng.randf_range(-18, 18))
	var side := Vector2(cos(angle), sin(angle))
	var forward := Vector2(-sin(angle), cos(angle))
	var points: Array = []
	var boxes: Array = []
	var tree_points: Array = []
	var id := str(course.id)
	if id == "one_tree":
		tree_points.append(Vector2.ZERO)
		var flank := 9.0 * (-1.0 if rng.randf() < 0.5 else 1.0)
		points.append(Vector2(flank, -10))
		points.append(Vector2(flank, 10))
	if id == "grove":
		for y in [-length * 0.22, 0.0, length * 0.22]:
			var x := rng.randf_range(-3, 3)
			points.append(Vector2(x, y))
			for sign_value in [-1, 1]:
				tree_points.append(Vector2(x + float(sign_value) * rng.randf_range(10, 14), y))
	if id == "detour" or id == "mixed":
		var widths: Array = course.get("rock_width", [10, 16])
		var depths: Array = course.get("rock_depth", [8, 12])
		var width := rng.randf_range(widths[0], widths[1])
		var depth := rng.randf_range(depths[0], depths[1])
		var y := -length * 0.18 if id == "mixed" else 0.0
		var flank := (width * 0.5 + 8.0) * (-1.0 if rng.randf() < 0.5 else 1.0)
		boxes.append({"p": Vector2(0, y), "size": Vector3(width, 2.5, depth)})
		points.append(Vector2(flank, y - depth * 0.5 - 9.0))
		points.append(Vector2(flank, y + depth * 0.5 + 9.0))
	if id == "gates" or id == "gate_wide" or id == "mixed":
		var positions := [-length / 6.0, length / 6.0] if id == "gates" else [length * 0.22]
		if id == "gate_wide":
			positions = [0.0]
		for y in positions:
			var gaps: Array = course.get("gap", [14, 20])
			var gap := rng.randf_range(gaps[0], gaps[1])
			var x := rng.randf_range(-10, 10)
			var left := x - gap * 0.5
			var right := x + gap * 0.5
			boxes.append({"p": Vector2((-42.0 + left) * 0.5, y), "size": Vector3(left + 42.0, 2.5, 2.0), "kind": "wall"})
			boxes.append({"p": Vector2((42.0 + right) * 0.5, y), "size": Vector3(42.0 - right, 2.5, 2.0), "kind": "wall"})
			points.append(Vector2(x, y))
	if id == "rough" or id == "mixed" or id == "low_step":
		var positions := [-length * 0.2, 0.0, length * 0.2] if id == "rough" else [length * 0.37]
		if id == "low_step":
			positions = [0.0]
		for y in positions:
			boxes.append({"p": Vector2(rng.randf_range(-2, 2), y),
				"size": Vector3(rng.randf_range(6, 9), rng.randf_range(0.15, 0.25) if id == "low_step" else rng.randf_range(0.2, 0.4), 1.2)})
	points.append(Vector2(0, length * 0.5))
	var route := []
	for p in points:
		var q: Vector2 = center + side * p.x + forward * p.y
		route.append([q.x, q.y])
	var obstacles := []
	for box in boxes:
		var q: Vector2 = center + side * box.p.x + forward * box.p.y
		obstacles.append({"position": [q.x, q.y], "size": [box.size.x, box.size.y, box.size.z], "yaw": -angle, "kind": box.get("kind", "stone")})
	var spawn := center - forward * length * 0.5
	var trees := []
	for p in tree_points:
		var q: Vector2 = center + side * p.x + forward * p.y
		trees.append({"position": [q.x, q.y], "seed": rng.randi()})
	var jitter := float(course.get("yaw_jitter", 40.0))
	return {"version": VERSION, "id": id, "seed": int(config.seed), "length_m": length,
		"center": [center.x, center.y], "angle": angle, "half_width": 42.0, "half_length": length * 0.5 + 18.0,
		"spawn": [spawn.x, spawn.y], "yaw": atan2(-forward.x, -forward.y) + deg_to_rad(rng.randf_range(-jitter, jitter)),
		"route": route, "obstacles": obstacles, "trees": trees}


static func populate(map: HillMap, layout: Dictionary) -> void:
	for tree in layout.get("trees", []):
		map.add_practice_tree(Vector2(tree.position[0], tree.position[1]), int(tree.seed))
	for box in layout.obstacles:
		var position := Vector2(box.position[0], box.position[1])
		var size := Vector3(box.size[0], box.size[1], box.size[2])
		if box.get("kind", "stone") == "wall":
			map.add_training_barrier(position, size, float(box.yaw))
		else:
			map.add_stone(position, size, float(box.yaw))
	map.finish_layout()


static func outside(layout: Dictionary, position: Vector3) -> bool:
	var delta := Vector2(position.x - float(layout.center[0]), position.z - float(layout.center[1]))
	var angle := float(layout.angle)
	return absf(delta.dot(Vector2(cos(angle), sin(angle)))) > float(layout.half_width) \
		or absf(delta.dot(Vector2(-sin(angle), cos(angle)))) > float(layout.half_length)
