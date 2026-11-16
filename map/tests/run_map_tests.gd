extends SceneTree
## 맵·시야 검증(헤드리스).
## 실행: godot --headless --path . -s res://map/tests/run_map_tests.gd
## 1) 시드 재현성, 스폰 지역 비움, 요소 개수
## 2) 차단물별 시야 판정: 개활지 / 건물 / 숲 / 생울타리 / 돌담 뒤(hull-down) / 다른 전차
## 3) 맵 전체 통계: 임의 두 지점(200~900m) 사이 시선이 트인 비율 — 평지 vs 지형만 vs 전체
## 4) 속도: 맵 생성 시간, 시선 1회 비용

var failures := 0
var frame := 0
var phase := 0
var map: HillMap
var observer: Tank
var cases := [] # [{"name", "target": Tank, "expect": Callable}]
var stats := {}


func check(cond: bool, msg: String) -> void:
	print("  ", "PASS  " if cond else "FAIL  ", msg)
	if not cond:
		failures += 1


func _initialize() -> void:
	print("== 1) 생성·재현성 ==")
	var t0 := Time.get_ticks_usec()
	var a := _new_map(7, true)
	var gen_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var b := _new_map(7, true)
	var c := _new_map(8, true)
	check(_signature(a) == _signature(b), "같은 시드(7) → 같은 맵 (%d개 장애물, 시야 볼륨 %d개)" % [a.obstacles.size(), a.vision_volumes.size()])
	check(_signature(a) != _signature(c), "다른 시드(8) → 다른 맵")
	var counts := {}
	for o in a.obstacles:
		counts[o.type] = counts.get(o.type, 0) + 1
	print("  구성: ", counts, "  능선 %d개" % a.ridges.size())
	for k in ["woods", "hedge", "building", "rock", "tree", "wall"]:
		check(counts.get(k, 0) > 0, "%s 있음 (%d)" % [k, counts.get(k, 0)])
	var bad := 0
	for o in a.obstacles:
		if o.type in ["rock", "tree", "building"] and a._in_spawn_zone(Vector2(o.pos.x, o.pos.z)):
			bad += 1
	check(bad == 0, "스폰 지역에 단단한 장애물 없음")
	var shapes := 0
	for ch in a.get_children():
		shapes += ch.get_child_count()
	print("  헤드리스 생성 %.0f ms, 노드 %d개, 충돌 형상 약 %d개" % [gen_ms, a.get_child_count(), shapes])
	check(gen_ms < 3000.0, "생성 3초 이내")
	for m in [a, b, c]:
		m.free()

	# 시나리오 맵: 평지, 장애물 없음. 관측자(티거)는 원점, 표적 셔먼은 400m 거리 방위별로 하나씩
	map = HillMap.new()
	map.height_amplitude = 0.0
	map.features_enabled = false
	map.generate()
	root.add_child(map)
	observer = _tank("tiger1", 0, Vector2(0, 0), 0.0)
	var lane := func(deg: float, dist: float) -> Vector2:
		return Vector2(sin(deg_to_rad(deg)), -cos(deg_to_rad(deg))) * dist
	_case("개활지", lane.call(-75.0, 400.0), func(r): return r.detected and r.visible_fraction > 0.95)
	map.add_building(lane.call(-45.0, 200.0), Vector3(12, 7, 10), deg_to_rad(-45.0))
	_case("건물 뒤", lane.call(-45.0, 400.0), func(r): return not r.detected and r.visible_fraction == 0.0 and r.blocked_by.has("building"))
	map.add_woods(lane.call(-15.0, 200.0), 30.0, 3)
	_case("숲 너머", lane.call(-15.0, 400.0), func(r): return not r.detected and r.visible_fraction < 0.12)
	var hc: Vector2 = lane.call(15.0, 200.0)
	var hd := Vector2(cos(deg_to_rad(15.0)), sin(deg_to_rad(15.0)))
	map.add_hedge(hc - hd * 30.0, hc + hd * 30.0)
	_case("생울타리 너머", lane.call(15.0, 400.0), func(r): return not r.detected and r.visible_fraction < 0.15)
	# 돌담(1.4m) 바로 뒤: 차체는 가리고 포탑만 보임 → 부분 가시
	var wc: Vector2 = lane.call(45.0, 397.0)
	var wd := Vector2(cos(deg_to_rad(45.0)), sin(deg_to_rad(45.0)))
	map.add_wall(wc - wd * 10.0, wc + wd * 10.0)
	_case("돌담 뒤(hull-down)", lane.call(45.0, 400.0), func(r): return r.visible_fraction > 0.1 and r.visible_fraction < 0.6)
	# 다른 전차가 가로막음
	_tank("t34_76", 1, lane.call(75.0, 388.0), 0.5 * PI)
	_case("다른 전차 뒤", lane.call(75.0, 400.0), func(r): return r.blocked_by.has("tank"))
	# 숲 속 표적: 관측자에서 보면 숲 가장자리 10m 안쪽
	map.add_woods(lane.call(120.0, 420.0), 30.0, 5)
	_case("숲 가장자리 안쪽", lane.call(120.0, 400.0), func(r): return r.visible_fraction < 0.6)


func _case(name: String, at: Vector2, expect: Callable) -> void:
	cases.append({"name": name, "target": _tank("sherman75", 1, at, 0.0), "expect": expect})


func _tank(id: String, team: int, at: Vector2, yaw: float) -> Tank:
	var t := Tank.new()
	t.name = "%s_%d" % [id, root.get_child_count()]
	t.setup(id, team, 1)
	t.position = Vector3(at.x, map.height_at(at.x, at.y) + 0.05, at.y)
	t.rotation.y = yaw
	root.add_child(t)
	return t


func _new_map(seed_v: int, features: bool, amp := 15.0) -> HillMap:
	var m := HillMap.new()
	m.map_seed = seed_v
	m.features_enabled = features
	m.height_amplitude = amp
	m.generate()
	return m


func _signature(m: HillMap) -> String:
	var parts := []
	for o in m.obstacles:
		parts.append("%s:%.2f,%.2f,%.2f" % [o.type, o.pos.x, o.pos.y, o.pos.z])
	parts.append("h%.3f" % m.height_at(123.0, -77.0))
	return ",".join(parts).md5_text()


func _physics_process(_delta: float) -> bool:
	frame += 1
	if frame < 3:
		return false
	match phase:
		0:
			print("\n== 2) 차단물별 시야 판정 (관측: 티거, 표적: 셔먼 400m) ==")
			for cs in cases:
				var r := LineOfSight.spot(map, observer, cs.target)
				check(cs.expect.call(r), "%s: 보임 %d%%, 탐지=%s, 보이는 점 %d/6, 가림 %s" % [cs.name,
					int(r.visible_fraction * 100), r.detected, r.points_visible, r.blocked_by])
			for ch in root.get_children():
				ch.free()
			phase = 1
			frame = 0
			print("\n== 3) 맵 전체 시선 통계 (시드 1, 임의 지점 쌍 600개, 200~900m, 눈높이 2.7m → 표적 1.5m) ==")
			map = _start_stats_map(1, false, 0.0)
		1:
			stats["평지·장애물 없음"] = _los_stats()
			map.free()
			map = _start_stats_map(1, false, 15.0)
			phase = 2
			frame = 0
		2:
			stats["지형(능선)만"] = _los_stats()
			map.free()
			map = _start_stats_map(1, true, 15.0)
			phase = 3
			frame = 0
		3:
			stats["전체(능선+숲+생울타리+건물…)"] = _los_stats()
			for k in stats:
				print("  %-28s 시선 트임 %5.1f%%   부분 가림 %5.1f%%" % [k, stats[k].open * 100.0, stats[k].partial * 100.0])
			check(stats["전체(능선+숲+생울타리+건물…)"].open < 0.6, "전체 맵에서 시선이 트인 쌍이 60% 미만")
			check(stats["전체(능선+숲+생울타리+건물…)"].open < stats["지형(능선)만"].open, "장애물이 시선을 추가로 가림")
			print("\n== 4) 속도 ==")
			var t0 := Time.get_ticks_usec()
			var rng := RandomNumberGenerator.new()
			rng.seed = 99
			for i in 1000:
				var a := _rand_point(rng, 2.7)
				var b := _rand_point(rng, 1.5)
				LineOfSight.ray(map, a, b)
			var us := (Time.get_ticks_usec() - t0) / 1000.0
			print("  시선 1회 %.1f µs (전차 6대 × 상대 5대 × 표본점 6 = 180회 → %.1f ms)" % [us, us * 180.0 / 1000.0])
			check(us < 300.0, "시선 1회 0.3ms 이내")
			map.free()
			print("\n== map tests: %d failures ==" % failures)
			quit(1 if failures > 0 else 0)
			return true
	return false


func _start_stats_map(seed_v: int, features: bool, amp: float) -> HillMap:
	var m := HillMap.new()
	m.map_seed = seed_v
	m.features_enabled = features
	m.height_amplitude = amp
	root.add_child(m)
	map = m
	return m


func _rand_point(rng: RandomNumberGenerator, eye: float) -> Vector3:
	var x := rng.randf_range(-550.0, 550.0)
	var z := rng.randf_range(-550.0, 550.0)
	return Vector3(x, map.height_at(x, z) + eye, z)


func _los_stats() -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var open := 0
	var partial := 0
	var n := 0
	while n < 600:
		var a := _rand_point(rng, 2.7)
		var b := _rand_point(rng, 1.5)
		var d := Vector2(a.x - b.x, a.z - b.z).length()
		if d < 200.0 or d > 900.0:
			continue
		n += 1
		var r := LineOfSight.ray(map, a, b)
		if r.transmittance >= 0.9:
			open += 1
		elif r.transmittance > 0.0:
			partial += 1
	return {"open": float(open) / n, "partial": float(partial) / n}
