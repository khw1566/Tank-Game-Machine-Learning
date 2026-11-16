extends SceneTree
## 시점 기반 관측(TankView + TankPerception + SoundField + TankAgent) 검증(헤드리스).
## 실행: godot --headless --path . -s res://controls/tests/run_perception_tests.gd
##  1) 시점 행동: 모드 전환·포 잠금·시선 회전·확대
##  2) 보이는 것만: 화면 안 + 탐지된 전차만, 화면 밖은 기억(MEMORY_S 후 잊음), 벽 뒤는 안 보임
##  3) 거리 대신 화면 크기: 확대하면 식별·거리 어림이 정확해짐, 관측 라벨에 거리 없음
##  4) 포수 조준경: 십자선 오차(mrad) 부호·크기
##  5) 소리: 뒤에서 난 포성 방향, 엔진 소리 방위, 피탄
##  6) 규칙 AI: 관측만으로 찾아서 쏜다 / 벽 뒤 적은 못 찾는다

var failures := 0
var map: HillMap


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	map = HillMap.new()
	map.features_enabled = false
	map.height_amplitude = 0.0
	root.add_child(map)
	await physics_frame

	print("== 1) 시점 행동")
	var me := _tank("tiger1", 0, Vector3(0, 0, 300), 0.0)
	var v := TankView.new()
	v.apply_action([2, 0, 0, 0, 0], me, 1.0 / 30.0)
	_check(v.mode == TankView.COMMANDER and v.locks_gun(), "view_mode=2 → 전차장, 포 잠금")
	var c := v.apply_locks(TankControlInput.from_array([0.5, 0.5, 0, 1, 1, 0]))
	_check(c.turret_traverse == 0.0 and c.gun_elevation == 0.0 and c.left_track == 0.5, "전차장 시점에서는 포탑·포 입력 0, 주행은 그대로")
	for i in 30:
		v.apply_action([2, 0, 1, 0, 0], me, 1.0 / 30.0)
	_check(absf(v.cmd_yaw - TankView.KEY_LOOK_RATE) < 0.02, "look_yaw=+1 1초 → 시선 %.2f rad 좌회전" % v.cmd_yaw)
	for i in 120:
		v.apply_action([2, 0, 0, 0, 1], me, 1.0 / 30.0)
	_check(is_equal_approx(v.fov(), TankView.COMMANDER_FOV_MIN), "zoom=+1 → 최대 확대 x%.1f" % v.magnification())
	v.apply_action([1, 0, 0, 0, 1], me, 1.0 / 30.0)
	_check(v.mode == TankView.GUNNER and not v.locks_gun() and v.gunner_zoom == 1, "view_mode=1 → 포수 조준경 고배율, 포 조작 가능")
	v.apply_action([0, 1, 0, 0, 0], me, 1.0 / 30.0)
	_check(v.mode == TankView.THIRD and v.free_look and v.locks_gun(), "view_mode=0 + free_look → 3인칭 자유 시선(포 잠금)")
	var st := v.state_array(me)
	var v2 := TankView.new()
	v.apply_action([2, 0, 0.5, 0.3, 0.4], me, 0.5)
	st = v.state_array(me)
	v2.apply_state(st, me)
	_check(v2.eye_transform(me).origin.distance_to(v.eye_transform(me).origin) < 1e-3 \
		and v2.eye_transform(me).basis.z.dot(v.eye_transform(me).basis.z) > 0.9999 and is_equal_approx(v2.fov(), v.fov()),
		"기록한 시점 상태로 같은 화면 재구성")

	print("== 2) 보이는 것만")
	var foe := _tank("sherman75", 1, Vector3(0, 0, -300), PI)
	await physics_frame
	await physics_frame
	var tanks := [me, foe]
	var sounds := SoundField.new()
	var ag := TankAgent.new(map, me, sounds)
	ag.view.set_mode(TankView.COMMANDER, me)
	var pc := ag.perception
	pc.observe(tanks, 0.1)
	var ct: Dictionary = pc.contacts.get(foe.name, {})
	_check(not ct.is_empty() and ct.visible_now, "정면 600m 셔먼: 전차장 시점에서 보임")
	_check(not ct.is_empty() and absf(ct.screen.x) < 0.02, "화면 가운데 (x=%.3f)" % (ct.screen.x if not ct.is_empty() else 9.0))
	_check(not ct.is_empty() and ct.get("type", "") == "", "맨눈(x1)에서는 %dpx 라 종류 식별 불가" % int(ct.get("size_px", 0)))
	var r1 := TankPerception.estimate_range(ct)
	var px1 := int(ct.get("size_px", 1))
	ag.view.cmd_fov = TankView.COMMANDER_FOV_MIN
	pc.observe(tanks, 0.1)
	ct = pc.contacts.get(foe.name, {})
	var r2 := TankPerception.estimate_range(ct)
	_check(ct.get("type", "") == "sherman75", "쌍안경 x8.9 → %dpx, 셔먼으로 식별" % int(ct.get("size_px", 0)))
	# 픽셀은 정수로 반올림되므로 ±0.5px 만큼 거리 불확실성이 생긴다: 확대할수록 작다
	var unc1 := 0.5 / float(px1)
	var unc2 := 0.5 / float(ct.size_px)
	var true_r := LineOfSight.eye_position(me).distance_to(foe.global_position)
	_check(unc2 < unc1 * 0.3 and absf(r2 - true_r) / true_r < 0.05,
		"크기로 어림한 거리: 맨눈 %.0fm(±%.0f%%) → 확대 %.0fm(±%.0f%%), 실제 %.0fm" % [r1, unc1 * 100, r2, unc2 * 100, true_r])
	ag.view.cmd_yaw = PI
	pc.observe(tanks, 1.0)
	ct = pc.contacts.get(foe.name, {})
	_check(not ct.is_empty() and not ct.visible_now, "뒤를 보면 화면 밖: 지금은 안 보이고 기억만")
	var vec := pc.vector
	var labels := TankPerception.labels()
	var e0 := labels.find("enemy0.present")
	_check(vec[e0] == 1.0 and vec[e0 + 1] == 0.0 and vec[e0 + 4] > 0.99, "기억 슬롯: 정면 방위(cos %.2f), visible_now=0" % vec[e0 + 4])
	pc.observe(tanks, TankPerception.MEMORY_S + 0.5)
	_check(not pc.contacts.has(foe.name), "MEMORY_S 지나면 잊음")
	_check(vec.size() == labels.size() and labels.size() == TankPerception.size(), "관측 길이 %d = 라벨 수" % labels.size())
	var bad := labels.filter(func(l): return "range" in l or "dist" in l)
	_check(bad.is_empty(), "관측 라벨에 거리 항목 없음")
	var nan := false
	for x in vec:
		nan = nan or is_nan(x) or is_inf(x)
	_check(not nan, "NaN/Inf 없음")
	# 3인칭 시점이라도 탐지는 큐폴라에서: 벽 뒤
	var wall_foe := _tank("t34_76", 1, Vector3(200, 0, 0), PI)
	map.add_building(Vector2(200, 30), Vector3(120, 8, 3))
	await physics_frame
	await physics_frame
	ag.view.set_mode(TankView.COMMANDER, me)
	ag.view.cmd_yaw = atan2(-200.0, 300.0)
	ag.view.cmd_fov = 30.0
	pc.observe([me, wall_foe], 0.1)
	_check(not pc.contacts.has(wall_foe.name), "건물 뒤 T-34 는 쌍안경으로도 안 보임")
	wall_foe.free()
	await physics_frame

	print("== 4) 포수 조준경")
	ag.view.set_mode(TankView.GUNNER, me)
	me.turret_yaw = deg_to_rad(1.0)
	me._sync_turret()
	pc.observe(tanks, 0.1)
	ct = pc.contacts.get(foe.name, {})
	var ge = ct.get("gun_err")
	_check(ge != null and ge.x > 0.0 and absf(ge.x * 1000.0 - 17.45) < 1.5, "포탑을 1° 왼쪽으로 → 표적이 십자선 오른쪽 %.1f mrad" % (ge.x * 1000.0 if ge != null else 0.0))
	me.turret_yaw = 0.0
	me._sync_turret()

	print("== 5) 소리")
	ag.view.set_mode(TankView.COMMANDER, me)
	ag.view.cmd_yaw = 0.0
	sounds.add(SoundField.GUNFIRE, Vector3(0, 2, 1200), "someone")
	pc.observe(tanks, 0.1)
	var heard: Array = pc.last_sounds
	_check(heard.size() == 1 and heard[0].kind == SoundField.GUNFIRE and absf(absf(heard[0].bearing) - PI) < 0.05,
		"뒤 900m 포성: 보이지 않아도 들림, 방향 뒤 (%.0f°)" % (rad_to_deg(heard[0].bearing) if not heard.is_empty() else 0.0))
	var sh := sounds.events.size()
	sounds.add(SoundField.IMPACT, me.global_position + Vector3(2, 1, 0), "x", me.name)
	pc.observe(tanks, 0.1)
	_check(pc.last_sounds[0].kind == SoundField.HIT_ME and pc.last_sounds[0].bearing < -1.0, "피탄: 오른쪽을 맞음 (%.0f°)" % rad_to_deg(pc.last_sounds[0].bearing))
	sounds.advance(SoundField.KEEP_S + 0.1)
	foe.velocity = Vector3(6, 0, 0)
	foe.global_position = Vector3(-150, foe.global_position.y, 300)
	pc.observe(tanks, 0.1)
	var sec := int((PI * 0.5 + PI) / TAU * TankPerception.ENGINE_SECTORS)
	_check(pc.last_sounds.is_empty() and pc.last_engine[sec] > 0.2, "왼쪽 150m 달리는 전차의 엔진 소리 = 왼쪽 방위 %.2f" % pc.last_engine[sec])
	foe.free()
	me.free()
	await physics_frame

	print("== 6) 규칙 AI: 관측만으로 교전")
	var res := await _duel(false)
	_check(res.shots > 0, "정면 700m 셔먼을 찾아 사격 %d발 (첫 발 %.1f초, 그때까지 포수 시점 %s)" % [res.shots, res.first_shot, res.gunner])
	_check(res.detect_before_fire, "탐지하기 전에는 쏘지 않음")
	res = await _duel(true)
	_check(res.shots == 0 and res.contacts == 0, "건물 뒤 셔먼은 못 찾고 쏘지도 않음")

	print("\nPERCEPTION TESTS: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures else 0)


## 티거(규칙 AI) vs 정지한 셔먼. hidden = 사이에 건물
func _duel(hidden: bool) -> Dictionary:
	var me := _tank("tiger1", 0, Vector3(0, 0, 350), 0.0)
	var foe := _tank("sherman75", 1, Vector3(60, 0, -350), PI)
	var wall: Node = null
	if hidden:
		map.add_building(Vector2(60, -300), Vector3(120, 9, 3))
	await physics_frame
	await physics_frame
	var sounds := SoundField.new()
	var ai := ScriptedAI.for_tank(me, 0, Vector3(0, 0, -450))
	var ag := TankAgent.new(map, me, sounds, ai)
	var shots := [0]
	var first := [-1.0]
	var detected_at := [-1.0]
	var gunner := [false]
	var t := [0.0]
	me.shot_fired.connect(func(_s, _r):
		shots[0] += 1
		if first[0] < 0.0:
			first[0] = t[0])
	var max_contacts := 0
	for i in 30 * 40:
		ag.step_ai([me, foe], 1.0 / 30.0)
		foe.control = TankControlInput.new()
		await physics_frame
		t[0] += 1.0 / 30.0
		max_contacts = maxi(max_contacts, ag.perception.contacts.size())
		if detected_at[0] < 0.0 and not ag.perception.contacts.is_empty():
			detected_at[0] = t[0]
		gunner[0] = gunner[0] or ag.view.mode == TankView.GUNNER
		if shots[0] >= 2:
			break
	var out := {"shots": shots[0], "first_shot": first[0], "gunner": gunner[0], "contacts": max_contacts,
		"detect_before_fire": shots[0] == 0 or (detected_at[0] >= 0.0 and detected_at[0] <= first[0])}
	me.free()
	foe.free()
	await physics_frame
	return out


func _tank(id: String, team: int, at: Vector3, yaw: float) -> Tank:
	var t := Tank.new()
	t.name = "%s_%d" % [id, randi() % 100000]
	t.setup(id, team, 1)
	t.position = Vector3(at.x, map.height_at(at.x, at.z) + 0.5, at.z)
	t.rotation.y = yaw
	root.add_child(t)
	return t


func _check(ok: bool, what: String) -> void:
	print(("  ok  " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
