extends SceneTree
## 조작·물리·사격 통합 스모크 테스트(헤드리스).
## 실행: godot --headless --path . -s res://controls/tests/run_sim_smoke.gd
## 1) 양쪽 궤도 전진 → 앞으로 이동  2) 왼쪽 궤도만 → 우선회  3) 티거가 액션 벡터로 조준·사격 → 피해 판정

var map: HillMap
var tiger: Tank
var sherman: Tank
var frame := 0
var phase := "drive"
var start_pos: Vector3
var start_yaw := 0.0
var failures := 0
var hits := 0
var shots := 0


func _initialize() -> void:
	map = HillMap.new()
	map.height_amplitude = 0.0 # 평지: 사격 검증을 단순하게
	map.features_enabled = false
	map.forest_patches = 0
	map.lone_trees = 0
	map.rock_count = 0
	root.add_child(map)
	tiger = _make("tiger1", 0, Vector3(0, 0.0, 0), 0.0)
	sherman = _make("sherman75", 1, Vector3(40, 0.0, -400), PI)
	tiger.shot_fired.connect(_on_shot)


func _make(id: String, team: int, pos: Vector3, yaw: float) -> Tank:
	var t := Tank.new()
	t.name = id
	t.setup(id, team, 42 + team)
	t.position = pos
	t.rotation.y = yaw
	root.add_child(t)
	return t


func check(cond: bool, msg: String) -> void:
	print("  ", "PASS  " if cond else "FAIL  ", msg)
	if not cond:
		failures += 1


func _physics_process(_delta: float) -> bool:
	frame += 1
	match phase:
		"drive":
			if frame == 15:
				start_pos = sherman.global_position
			if frame >= 15:
				sherman.control = TankControlInput.from_array([1, 1, 0, 0, 0, 0])
			if frame == 15 + 150:
				var moved := sherman.global_position - start_pos
				check(moved.z > 15.0 and absf(moved.x) < 1.0, "양쪽 궤도 전진 5초 → +Z로 %.1fm 이동 (속도 %.1f m/s)" % [moved.z, sherman.track_speed_left])
				start_yaw = sherman.rotation.y
				phase = "turn"
				frame = 0
		"turn":
			sherman.control = TankControlInput.from_array([1, 0, 0, 0, 0, 0])
			if frame == 60:
				var dyaw := wrapf(sherman.rotation.y - start_yaw, -PI, PI)
				check(dyaw < -0.1, "왼쪽 궤도만 전진 → 시계방향(우)선회 %.0f°" % rad_to_deg(dyaw))
				sherman.control = TankControlInput.from_array([0, 0, 1, 0, 0, 0])
				phase = "shoot"
				frame = 0
		"shoot":
			sherman.control = TankControlInput.from_array([0, 0, 1, 0, 0, 0])
			tiger.control = TankControlInput.from_array(_aim_action(tiger, sherman))
			if not sherman.damage.is_combat_effective() or frame > 30 * 90:
				check(shots > 0, "티거 발사 %d발" % shots)
				check(hits > 0, "명중 %d발 (거리 약 %.0fm)" % [hits, tiger.global_position.distance_to(sherman.global_position)])
				check(not sherman.damage.is_combat_effective(), "셔먼 전투불능: %s" % sherman.damage.knockout_cause)
				print("  셔먼 최종 상태: ", JSON.stringify(sherman.damage.to_dict()))
				print("\n== smoke test: %d failures ==" % failures)
				for c in root.get_children():
					c.free()
				return true
	return false


## 간단한 비례 조준기(스크립트 AI 기준선). Tank.aim_solution() 이 탄도 낙차까지 보정한 목표 각을 준다.
## 조준 오차(aim_error_mrad)가 충분히 줄어든 뒤에만 쏜다. 반환: 액션 벡터
static func _aim_action(me: Tank, target: Tank) -> Array:
	var aim := target.global_position + target.global_transform.basis.y * (target.spec.hull_bottom_y + (target.spec.hull_roof_y - target.spec.hull_bottom_y) * 0.6)
	var sol := me.aim_solution(aim)
	var e_yaw := wrapf(float(sol.turret_yaw) - me.turret_yaw, -PI, PI)
	var e_pitch := float(sol.gun_pitch) - me.gun_pitch
	var trav := clampf(-e_yaw * 20.0, -1.0, 1.0)
	var elev := clampf(e_pitch * 40.0, -1.0, 1.0)
	var on_target := absf(e_yaw) < 0.002 and absf(e_pitch) < 0.002 and me.aim_error_mrad < me.current_shell().dispersion_mrad * 1.5
	return [0, 0, 1, trav, elev, 1.0 if on_target else 0.0]


func _on_shot(_shooter: Tank, r: Dictionary) -> void:
	shots += 1
	if r.get("hit", false):
		hits += 1
	print("  shot %d: hit=%s zone=%s pen=%s events=%s" % [shots, r.get("hit"), r.get("zone", ""), r.get("penetrated", false), r.get("events", [])])
