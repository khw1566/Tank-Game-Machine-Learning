class_name CompactBattle
extends RefCounted
## Small battle arena. A central firing lane and both deployment zones stay clear.
static func populate(map: HillMap) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = map.map_seed
	for sign_x in [-1, 1]:
		for sign_z in [-1, 1]:
			var p := Vector2(sign_x * rng.randf_range(50, 70), sign_z * rng.randf_range(20, 40))
			map.add_stone(p, Vector3(9, 2.5, 7), rng.randf_range(-0.3, 0.3))
			map.add_practice_tree(Vector2(sign_x * rng.randf_range(110, 135), sign_z * 45), rng.randi())
	var half := map.size_m * 0.5 - 3
	for sign_value in [-1, 1]:
		map.add_stone(Vector2(sign_value * half, 0), Vector3(4, 4, map.size_m), 0)
		map.add_stone(Vector2(0, sign_value * half), Vector3(map.size_m, 4, 4), 0)
	map.finish_layout()
