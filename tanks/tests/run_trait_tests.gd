extends SceneTree
## 전차별 고유 특성이 실제 조작·물리·사격에서 강제되는지 검증(헤드리스).
## 실행: godot --headless --path . -s res://tanks/tests/run_trait_tests.gd
##
##  A. 전진/후진 속도, 전후진 전환 시간       (T-34: 전진 최고, 후진·전환 최악)
##  B. 경사면 헐다운: 포 내림각으로 겨눌 수 있나 (셔먼 −10° 가능, T-34 −5° 불가)
##  C. 기동 중 조준 오차와 정지 후 수렴         (셔먼 안정장치: 기동간 오차 최소 / 티거: 정지 후 가장 정확)
##  D. 요철 주행 중 포 고저 유지               (셔먼 안정장치)
##  E. 포탑 90° 선회 시간                     (티거 가장 느림)
##  F. 오르막 속도 손실                       (티거 가장 큼)
##  G. 원거리 탄도                            (88mm 낙차 최소)
##
## 결과 표는 보고서에 그대로 옮길 수 있게 출력한다.

const DT := 1.0 / 30.0
const IDS := ["tiger1", "sherman75", "t34_76"]

var failures := 0
var checks := 0
var _ran := false


func check(cond: bool, msg: String) -> void:
	checks += 1
	print("  ", "PASS  " if cond else "FAIL  ", msg)
	if not cond:
		failures += 1


func _initialize() -> void:
	# 평지(위면 y = 0)
	_ground(Vector3(0, -0.5, 0), Vector3(6000, 1, 6000), 0.0)
	# 헐다운 시험용 경사면(앞이 들리는 방향): x = 3000 + i*100, 7° / 9°
	for i in 2:
		_ground(Vector3(3000 + i * 100, 0, 0), Vector3(40, 1, 60), [7.0, 9.0][i])
	# 오르막 시험용 긴 경사면 12°
	_ground(Vector3(4000, 0, -150), Vector3(40, 1, 400), 12.0)
	# 요철 길(0.35m 턱이 7m 간격)
	for k in 60:
		_ground(Vector3(-2000, 0.0, -10.0 - k * 7.0), Vector3(30, 0.7, 1.2), 0.0)


func _ground(center: Vector3, size: Vector3, tilt_deg: float) -> void:
	var b := StaticBody3D.new()
	b.collision_layer = Tank.LAYER_GROUND
	b.collision_mask = 0
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	b.add_child(cs)
	b.position = center
	b.rotation.x = deg_to_rad(tilt_deg) # + = -Z 쪽(전차 정면)이 높아짐
	root.add_child(b)


func _make(id: String, pos: Vector3, yaw := 0.0) -> Tank:
	var t := Tank.new()
	t.name = "%s_%d" % [id, root.get_child_count()]
	t.setup(id, 0, 777)
	t.position = pos
	t.rotation.y = yaw
	root.add_child(t)
	return t


func _run(t: Tank, action: Array, seconds: float) -> void:
	t.control = TankControlInput.from_array(action)
	for i in int(seconds / DT):
		t.step(DT)


func _physics_process(_delta: float) -> bool:
	if _ran:
		return true
	_ran = true
	_test_drive()
	_test_hull_down()
	_test_aim_error()
	_test_stabilizer()
	_test_traverse()
	_test_climb()
	_test_ballistics()
	print("\n== trait tests: %d checks, %d failures ==" % [checks, failures])
	for c in root.get_children():
		c.free()
	quit(1 if failures > 0 else 0)
	return true


# ------------------------------------------------------------------ A
func _test_drive() -> void:
	print("\n# A. 전진/후진 (평지, 전진 10초 → 후진 명령)")
	print("전차 | 전진 최고 m/s | 후진 시작까지 s | 후진 최고 m/s")
	var r := {}
	for i in IDS.size():
		var t := _make(IDS[i], Vector3(i * 60.0, 0, 0))
		_run(t, [1, 1, 0, 0, 0, 0], 10.0)
		var vf := t.forward_speed()
		t.control = TankControlInput.from_array([-1, -1, 0, 0, 0, 0])
		var ts := 0.0
		while t.forward_speed() > -0.5 and ts < 15.0:
			t.step(DT)
			ts += DT
		_run(t, [-1, -1, 0, 0, 0, 0], 10.0)
		var vr := -t.forward_speed()
		r[IDS[i]] = {"vf": vf, "ts": ts, "vr": vr}
		print("%s | %.1f | %.1f | %.1f" % [IDS[i], vf, ts, vr])
	check(r.t34_76.vf > r.sherman75.vf and r.sherman75.vf > r.tiger1.vf, "전진 최고속도 T-34 > 셔먼 > 티거")
	check(r.t34_76.vr < r.tiger1.vr and r.t34_76.vr < r.sherman75.vr, "후진 최고속도는 T-34 가 가장 느림 (%.1f m/s)" % r.t34_76.vr)
	check(r.t34_76.ts > r.sherman75.ts and r.t34_76.ts > r.tiger1.ts, "전진→후진 전환은 T-34 가 가장 오래 걸림 (%.1fs)" % r.t34_76.ts)


# ------------------------------------------------------------------ B
func _test_hull_down() -> void:
	print("\n# B. 경사면(앞이 들림)에서 같은 높이의 500m 앞 적을 겨눌 수 있나 (= 능선 뒤 헐다운 가능 여부)")
	print("경사 | 전차 | 차체 피치 | 필요한 포 각(차체 기준) | 포 내림 한계 | 가능")
	var ok := {}
	for i in 2:
		var slope: float = [7.0, 9.0][i]
		for j in IDS.size():
			var t := _make(IDS[j], Vector3(3000 + i * 100 + (j - 1) * 10.0, 5.0, 0))
			_run(t, [0, 0, 1, 0, 0, 0], 1.0)
			var gun_pos := t.muzzle_position()
			var target := gun_pos + Vector3(0, 0, -500)
			var sol := t.aim_solution(target)
			ok["%d_%s" % [slope, IDS[j]]] = sol.reachable
			print("%d° | %s | %.1f° | %.1f° | %.0f° | %s" % [slope, IDS[j], t.hull_pitch_deg(), rad_to_deg(sol.gun_pitch),
				t.spec.gun_depression_deg, "가능" if sol.reachable else "불가"])
			if i == 0 and j == 0:
				check(absf(t.hull_pitch_deg() - slope) < 1.0, "차체가 지형 경사를 따라 기욺 (%.1f°)" % t.hull_pitch_deg())
			t.free()
	check(ok["7_sherman75"] and not ok["7_t34_76"], "7° 경사: 셔먼 가능, T-34(−5°) 불가")
	check(ok["7_tiger1"], "7° 경사: 티거(−8°) 가능")
	check(ok["9_sherman75"] and not ok["9_tiger1"] and not ok["9_t34_76"], "9° 경사: 셔먼(−10°)만 가능")


# ------------------------------------------------------------------ C
func _test_aim_error() -> void:
	print("\n# C. 조준 오차(분산 1σ, mrad): 전진 최고속도 주행 중 → 정지 후 수렴")
	print("전차 | 정지 분산 | 주행 중 | 정지 1초 후 | 정지 3초 후 | 1.5×정지분산까지 s | 1000m 주행 중 1σ 탄착 반경")
	var r := {}
	for i in IDS.size():
		var t := _make(IDS[i], Vector3(500 + i * 60.0, 0, 0))
		_run(t, [1, 1, 0, 0, 0, 0], 8.0)
		var moving := t.aim_error_mrad
		_run(t, [0, 0, 1, 0, 0, 0], 1.0)
		var after1 := t.aim_error_mrad
		_run(t, [0, 0, 1, 0, 0, 0], 2.0)
		var after3 := t.aim_error_mrad
		var base := t.current_shell().dispersion_mrad
		var tt := 3.0
		while t.aim_error_mrad > base * 1.5 and tt < 30.0:
			t.step(DT)
			tt += DT
		r[IDS[i]] = {"moving": moving, "after3": after3, "settle": tt, "base": base}
		print("%s | %.2f | %.2f | %.2f | %.2f | %.1f | %.1fm" % [IDS[i], base, moving, after1, after3, tt, moving])
	check(r.sherman75.moving < r.tiger1.moving * 0.6 and r.sherman75.moving < r.t34_76.moving * 0.6,
		"셔먼(안정장치)은 기동 중 조준 오차가 다른 전차의 60%% 미만 (%.1f vs 티거 %.1f, T-34 %.1f)" % [r.sherman75.moving, r.tiger1.moving, r.t34_76.moving])
	check(r.tiger1.base < r.sherman75.base and r.tiger1.base < r.t34_76.base, "정지 분산은 티거 88mm 가 가장 작음")
	check(r.t34_76.settle > r.tiger1.settle and r.t34_76.settle > r.sherman75.settle, "T-34(전차장 겸 포수)는 정지 후 조준 수렴이 가장 느림 (%.1fs)" % r.t34_76.settle)


# ------------------------------------------------------------------ D
func _test_stabilizer() -> void:
	print("\n# D. 요철 길 주행 중 포의 월드 고저각 흔들림(표준편차, °) — 고저 입력 없음")
	var r := {}
	for i in IDS.size():
		var t := _make(IDS[i], Vector3(-2000 + (i - 1) * 9.0, 0, 0))
		t.control = TankControlInput.from_array([0.6, 0.6, 0, 0, 0, 0])
		var samples := []
		for k in int(14.0 / DT):
			t.step(DT)
			if k > 30:
				samples.append(rad_to_deg(asin(clampf(t.gun_direction().y, -1, 1))))
		var mean := 0.0
		for s in samples:
			mean += s
		mean /= samples.size()
		var v := 0.0
		for s in samples:
			v += (s - mean) * (s - mean)
		var sd := sqrt(v / samples.size())
		r[IDS[i]] = sd
		print("%s | 포 고저 흔들림 %.2f° | 안정장치 %s" % [IDS[i], sd, "있음" if t.spec.stabilizer_vertical else "없음"])
	check(r.sherman75 < r.tiger1 * 0.5 and r.sherman75 < r.t34_76 * 0.5, "셔먼 안정장치: 요철 주행 중 포 고저 흔들림이 절반 이하")


# ------------------------------------------------------------------ E
func _test_traverse() -> void:
	print("\n# E. 포탑 90° 선회 시간")
	var r := {}
	for i in IDS.size():
		var t := _make(IDS[i], Vector3(800 + i * 60.0, 0, 0))
		t.control = TankControlInput.from_array([0, 0, 1, -1, 0, 0])
		var tt := 0.0
		while t.turret_yaw < PI * 0.5 and tt < 60.0:
			t.step(DT)
			tt += DT
		r[IDS[i]] = tt
		print("%s | %.1fs" % [IDS[i], tt])
	check(r.tiger1 > 3.0 * r.sherman75, "티거 포탑 선회는 셔먼보다 3배 이상 느림 (%.1fs vs %.1fs)" % [r.tiger1, r.sherman75])


# ------------------------------------------------------------------ F
func _test_climb() -> void:
	print("\n# F. 12° 오르막 최고속도 / 평지 최고속도")
	var r := {}
	for i in IDS.size():
		var t := _make(IDS[i], Vector3(4000 + (i - 1) * 10.0, 5.0, 30.0))
		_run(t, [1, 1, 0, 0, 0, 0], 12.0)
		var ratio := t.forward_speed() / t.spec.max_forward_mps()
		r[IDS[i]] = ratio
		print("%s | 차체 피치 %.1f° | %.1f m/s (평지의 %.0f%%)" % [IDS[i], t.hull_pitch_deg(), t.forward_speed(), ratio * 100])
	check(r.tiger1 < r.sherman75 and r.sherman75 < r.t34_76, "오르막 속도 유지율 T-34 > 셔먼 > 티거 (출력중량비)")


# ------------------------------------------------------------------ G
func _test_ballistics() -> void:
	print("\n# G. 탄도(공기저항 무시): 1200m 표적, 거리를 10% 잘못 쟀을 때 탄착 높이 오차")
	var r := {}
	for id in IDS:
		var g := TankDatabase.get_spec(id).gun
		var err := Ballistics.drop_at_m(g, 1320.0) - Ballistics.drop_at_m(g, 1200.0)
		r[id] = err
		print("%s | 포구초속 %d m/s | 1200m 낙차 %.1fm | 거리 10%% 오차 시 %.2fm 빗나감 | 필요 앙각 %.2f°" % [id, g.muzzle_velocity_ms,
			Ballistics.drop_at_m(g, 1200.0), err, rad_to_deg(Ballistics.superelevation_rad(g, 1200.0))])
	check(r.tiger1 < r.sherman75 and r.tiger1 < r.t34_76, "88mm 는 거리 오차에 가장 덜 민감(평탄한 탄도)")
