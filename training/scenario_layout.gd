class_name ScenarioLayout
extends RefCounted
## 커리큘럼 v4 전투 상황 배치. Python(tankrl/scenarios.py)이 시드로 만든 배치를 config.scenario 로 넘기고
## 여기서는 그대로 놓기만 한다(배치가 설정 파일에 남으므로 재현·보고서에서 같은 지형을 다시 만든다).
##
## config.scenario:
##   version, id, variant, goal("reach"|"survive"|"destroy"|"zone"), survive_s, zone_s
##   obstacles: [{type: "stone", p:[x,z], size:[w,h,d], yaw}
##               {type: "berm",  p, w, d, yaw, hull_frac}   높이 = 학습 전차 차체 지붕 × hull_frac (헐다운 둔덕)
##               {type: "tree",  p, seed} | {type: "woods", p, r, seed}
##               {type: "house", p, size, yaw}  (돌 상자, 집 색)
##               {type: "hedge"|"wall", p:[x,z] = 시작, b:[x,z] = 끝}]   (최종 1대6 맵, FINAL_BATTLE_VERSION 1)
##   learner: {p, yaw}, enemies: [{p, yaw, ai:{...ScriptedAI 매개변수}}]   (config.tanks 순서: 학습 전차, 적들)
##   objective: {p, radius, hold_s}   (선택)

const VERSION := 1


static func build_map(parent: Node, mc: Dictionary, config: Dictionary) -> HillMap:
	var terrain: HillMap
	if mc.has("profile"):
		var practice := PracticeMap.new()
		practice.profile = str(mc.profile)
		var layout: Dictionary = config.get("terrain_layout", {})
		practice.course_angle = float(layout.get("angle", 0))
		var center: Array = layout.get("center", [0, 0])
		practice.course_center = Vector2(center[0], center[1])
		terrain = practice
	else:
		terrain = HillMap.new()
	terrain.map_seed = int(mc.get("seed", 1))
	terrain.features_enabled = bool(mc.get("features", false))
	terrain.height_amplitude = float(mc.get("amplitude", 15.0))
	terrain.size_m = float(mc.get("size_m", 1200.0))
	terrain.cell_m = float(mc.get("cell_m", 5.0))
	terrain.ridge_count = int(mc.get("ridge_count", 3))
	terrain.noise_frequency = float(mc.get("noise_frequency", 0.0025))
	terrain.custom_ridges = mc.get("custom_ridges", [])
	terrain.mounds = mc.get("mounds", [])
	parent.add_child(terrain)
	if mc.get("profile", "") == "battle_compact":
		CompactBattle.populate(terrain)
	if config.has("terrain_layout"):
		TerrainCourse.populate(terrain, config.terrain_layout)
	if config.has("scenario"):
		populate(terrain, config.scenario)
	return terrain


static func resolve_spawn(terrain: HillMap, p: Vector2, rng: RandomNumberGenerator, reserved: Array) -> Vector2:
	return p if terrain.is_spawn_safe(p, 4.0, 6.0) else terrain.find_safe_spawn(p, rng, reserved)


static func berm_height(sc: Dictionary, o: Dictionary) -> float:
	var spec := TankDatabase.get_spec(str(sc.get("learner_type", "tiger1")))
	var roof := spec.hull_top_y() if spec else 1.9
	return roof * float(o.get("hull_frac", 0.95))


static func populate(map: HillMap, sc: Dictionary) -> void:
	for o in sc.get("obstacles", []):
		var p := Vector2(float(o.p[0]), float(o.p[1]))
		match str(o.get("type", "stone")):
			"stone":
				var s: Array = o.get("size", [6, 3, 6])
				map.add_stone(p, Vector3(s[0], s[1], s[2]), float(o.get("yaw", 0.0)))
			"berm":
				map.add_stone(p, Vector3(float(o.get("w", 10.0)), berm_height(sc, o), float(o.get("d", 3.0))),
					float(o.get("yaw", 0.0)), Color(0.45, 0.4, 0.3))
			"tree":
				map.add_practice_tree(p, int(o.get("seed", 1)))
			"woods":
				map.add_woods(p, float(o.get("r", 25.0)), int(o.get("seed", 1)))
			"house":
				var hs: Array = o.get("size", [10, 6, 12])
				map.add_stone(p, Vector3(hs[0], hs[1], hs[2]), float(o.get("yaw", 0.0)), Color(0.62, 0.55, 0.45))
			"hedge", "wall":
				var b: Array = o.get("b", [p.x + 20.0, p.y])
				var q := Vector2(float(b[0]), float(b[1]))
				if str(o.type) == "hedge":
					map.add_hedge(p, q)
				else:
					map.add_wall(p, q)
	map.finish_layout()


static func objective_point(map: HillMap, sc: Dictionary) -> Vector3:
	if not sc.has("objective"):
		return Vector3.INF
	var p: Array = sc.objective.p
	return Vector3(p[0], map.height_at(p[0], p[1]), p[1])
