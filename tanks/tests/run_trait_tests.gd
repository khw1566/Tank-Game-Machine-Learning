extends SceneTree
## 전차별 고유 특성이 실제 조작·물리·사격에서 강제되는지 검증(헤드리스).
## 실행: godot --headless --path . -s res://tanks/tests/run_trait_tests.gd
##
##  A. 전진/후진 속도(실제 기어표), 전후진 전환 (T-34: 야지 전진 최고, 전환 최악)
##  B. 경사면 헐다운: 포 내림각으로 겨눌 수 있나 (셔먼 −10° 가능, T-34 −5° 불가)
##  C. 기동 중 조준 오차와 정지 후 수렴         (셔먼 안정장치: 기동간 오차 최소 / 티거: 정지 후 가장 정확)
##  D. 요철 주행 중 포 고저 유지               (셔먼 안정장치 켬/끔 비교)
##  E. 포탑 90° 선회 시간                     (티거 가장 느림)
##  F. 오르막 속도                           (T-34 출력중량비 최고)
##  G. 원거리 탄도                            (88mm 낙차 최소)
##  H. 변속기: 빠른 가속·단수, 변속 중 동력 단절  (T-34 2→3단 0.55s, 4단은 야지에서 못 씀)
##  I. 낮은 장애물 넘기 → 차체 피치/롤          (0.7m 돌: 티거·T-34 넘음, 셔먼 막힘)
##  J. 기운 차체에서 포 조준                    (포 각도 재조정 필요, 오르막 쪽 포탑 선회 느림)
##  K. 현가: 급정거 시 차체 숙임·출렁임         (T-34 크리스티 가장 오래 출렁임)
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
	# 장애물 시험: x = 2500 + j*40 에 높이 0.7m 돌(폭 4m, 길이 1.5m)을 정면 20m 앞에
	for j in 3:
		_ground(Vector3(2500 + j * 40, 0.2, -20.0), Vector3(4.0, 1.0, 1.5), 0.0)
	# 통나무(0.5m)를 왼쪽 궤도만 밟도록: x = 2700 + j*40, 차체 왼쪽(−X) 1.2m 지점
	for j in 3:
		_ground(Vector3(2700 + j * 40 - 1.4, 0.0, -20.0), Vector3(1.2, 1.0, 0.6), 0.0)
	# 옆으로 기운 경사(롤 10°): x = 6000 근처, Z 축 회전
	var side := StaticBody3D.new()
	side.collision_layer = Tank.LAYER_GROUND
	var scs := CollisionShape3D.new()
	var sbs := BoxShape3D.new()
	sbs.size = Vector3(200, 1, 200)
	scs.shape = sbs
	side.add_child(scs)
	side.position = Vector3(6000, 0, 0)
	side.rotation.z = deg_to_rad(10.0)
	root.add_child(side)


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
	_test_gearbox()
	_test_obstacles()
	_test_tilted_aim()
	_test_suspension()
	print("\n== trait tests: %d checks, %d failures ==" % [checks, failures])
	for c in root.get_children():
		c.free()
	quit(1 if failures > 0 else 0)
	return true


# ------------------------------------------------------------------ A
func _test_drive() -> void:
	print("\n# A. 전진/후진 (평지 야지, 전진 40초 → 후진 명령)")
	print("전차 | 야지 전진 최고 km/h (단) | 기어표 최고 | 후진 시작까지 s | 후진 최고 km/h | 기어표 후진 | 후진 10m 이탈까지 s")
	var r := {}
	for i in IDS.size():
		var t := _make(IDS[i], Vector3(i * 60.0, 0, 0))
		_run(t, [1, 1, 0, 0, 0, 0], 40.0)
		var vf := t.forward_speed()
		var gl := t.gear_label()
		var z0 := t.global_position.z
		t.control = TankControlInput.from_array([-1, -1, 0, 0, 0, 0])
		var ts := 0.0
		while t.forward_speed() > -0.5 and ts < 15.0:
			t.step(DT)
			ts += DT
		var tb := ts
		var zmin := t.global_position.z
		while tb < 40.0:
			t.step(DT)
			tb += DT
			zmin = minf(zmin, t.global_position.z)
			if t.global_position.z > zmin + 10.0:
				break
		_run(t, [-1, -1, 0, 0, 0, 0], 8.0)
		var vr := -t.forward_speed()
		r[IDS[i]] = {"vf": vf, "ts": ts, "vr": vr, "tb": tb}
		print("%s | %.1f (%s) | %.1f | %.1f | %.1f | %.1f | %.1f" % [IDS[i], vf * 3.6, gl, t.spec.max_forward_kmh, ts, vr * 3.6,
			t.spec.max_reverse_kmh, tb])
		check(absf(vf * 3.6 - t.spec.sustained_speed_kmh(0.0)) < 0.6, "%s 야지 최고속도 = 저항을 이기는 최고단 속도 (%.1f km/h)" % [IDS[i], vf * 3.6])
		check(absf(vr * 3.6 - t.spec.max_reverse_kmh) < 0.3, "%s 후진 최고속도 = 기어표 (%.1f km/h)" % [IDS[i], vr * 3.6])
	check(r.t34_76.vf > r.sherman75.vf and r.sherman75.vf > r.tiger1.vf, "야지 전진 최고속도 T-34 > 셔먼 > 티거")
	check(r.t34_76.ts > r.sherman75.ts and r.t34_76.ts > r.tiger1.ts, "전진→후진 전환은 T-34 가 가장 오래 걸림 (%.1fs)" % r.t34_76.ts)
	check(r.tiger1.vr > r.sherman75.vr and r.tiger1.vr > r.t34_76.vr, "후진은 티거(4단 9.2km/h)가 가장 빠름")


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
	var runs := ["sherman75", "sherman_off", "t34_76"]
	for i in runs.size():
		var t := _make("sherman75" if runs[i] == "sherman_off" else runs[i], Vector3(-2000 + (i - 1) * 9.0, 0, 0))
		if runs[i] == "sherman_off":
			t.spec.stabilizer_efficiency = 0.0
			t.spec.stabilizer_vertical = false
		t.control = TankControlInput.from_array([0.3, 0.3, 0, 0, 0, 0])
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
		r[runs[i]] = sd
		print("%s | %.1f km/h | 포 고저 흔들림 %.2f° | 안정장치 %s" % [runs[i], t.forward_speed() * 3.6, sd,
			"있음" if t.spec.stabilizer_efficiency > 0.0 else "없음"])
	check(r.sherman75 < r.sherman_off * 0.5, "셔먼 안정장치: 같은 전차·같은 길에서 포 고저 흔들림이 절반 이하 (%.2f° vs 끔 %.2f°)" % [r.sherman75, r.sherman_off])


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
	print("\n# F. 12° 오르막 30초 주행")
	var r := {}
	for i in IDS.size():
		var t := _make(IDS[i], Vector3(4000 + (i - 1) * 10.0, 5.0, 30.0))
		_run(t, [1, 1, 0, 0, 0, 0], 30.0)
		r[IDS[i]] = t.forward_speed()
		print("%s | 차체 피치 %.1f° | %.1f km/h (%s) | 이론 %.1f km/h | 출력중량비 %.1f hp/t" % [IDS[i], t.hull_pitch_deg(),
			t.forward_speed() * 3.6, t.gear_label(), t.spec.sustained_speed_kmh(12.0), t.spec.power_to_weight()])
	check(r.t34_76 > r.tiger1 and r.t34_76 > r.sherman75, "12° 오르막 속도는 T-34(출력중량비 17.5) 가 가장 빠름")


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


# ------------------------------------------------------------------ H
func _test_gearbox() -> void:
	print("\n# H. 변속기: 평지 전속 출발 → 매초 속도·단")
	var r := {}
	for i in IDS.size():
		var t := _make(IDS[i], Vector3(1200 + i * 60.0, 0, 0))
		t.control = TankControlInput.from_array([1, 1, 0, 0, 0, 0])
		var line := ""
		var t10 := -1.0
		var max_gear := 0
		var shift_drop := 0.0 # 변속 중 최대 속도 손실(km/h)
		var v_at_shift := -1.0
		for k in int(40.0 / DT):
			t.step(DT)
			var v := t.forward_speed() * 3.6
			if t10 < 0.0 and v >= 10.0:
				t10 = (k + 1) * DT
			max_gear = maxi(max_gear, t.gear_index)
			if t.gear_label().contains("변속"):
				if v_at_shift < 0.0:
					v_at_shift = v
				shift_drop = maxf(shift_drop, v_at_shift - v)
			else:
				v_at_shift = -1.0
			if (k + 1) % int(4.0 / DT) == 0:
				line += "%ds %.0f(%s)  " % [int((k + 1) * DT), v, t.gear_label().replace("전진 ", "")]
		r[IDS[i]] = {"t10": t10, "max_gear": max_gear, "drop": shift_drop}
		print("%s | 0→10km/h %.1fs | 최대 변속손실 %.1f km/h | %s" % [IDS[i], t10, shift_drop, line])
	check(r.t34_76.t10 < r.sherman75.t10 and r.t34_76.t10 < r.tiger1.t10, "0→10km/h 는 T-34 가 가장 빠름 (%.1fs)" % r.t34_76.t10)
	for id in IDS:
		check(r[id].t10 >= 0.5 and r[id].t10 <= 2.5, "%s: 출발 가속은 빠르지만 순간 가속은 아님 (0→10km/h %.1fs)" % [id, r[id].t10])
	check(r.t34_76.max_gear == 3, "T-34 는 야지 평지에서 4단(도로용)으로 올리지 않음")
	check(r.t34_76.drop > r.sherman75.drop and r.t34_76.drop > r.tiger1.drop, "T-34 변속 중 속도 손실이 가장 큼 (%.1f km/h, 2→3단 0.55s)" % r.t34_76.drop)
	print("이론 지속속도(km/h): 경사 0° / 5° / 10°")
	var s5 := {}
	for id in IDS:
		var sp := TankDatabase.get_spec(id)
		s5[id] = sp.sustained_speed_kmh(5.0)
		print("%s | %.1f / %.1f / %.1f | 구름저항 %.3f (접지압 %.2f kg/cm²)" % [id, sp.sustained_speed_kmh(0.0), s5[id],
			sp.sustained_speed_kmh(10.0), sp.rolling_resistance(), sp.ground_pressure_kgcm2])
	check(s5.t34_76 > s5.tiger1 and s5.t34_76 > s5.sherman75, "5° 오르막 지속속도 T-34 최고")


# ------------------------------------------------------------------ I
func _test_obstacles() -> void:
	print("\n# I. 0.7m 돌로 직진 / 0.5m 통나무를 왼쪽 궤도로만 밟기")
	var r := {}
	for j in IDS.size():
		var t := _make(IDS[j], Vector3(2500 + j * 40, 0, 0))
		var max_pitch := 0.0
		t.control = TankControlInput.from_array([0.4, 0.4, 0, 0, 0, 0])
		for k in int(25.0 / DT):
			t.step(DT)
			max_pitch = maxf(max_pitch, absf(t.hull_pitch_deg()))
		var passed := t.global_position.z < -26.0
		r[IDS[j]] = passed
		print("%s | 넘는 한계 %.2fm | 돌 0.7m %s | 최대 피치 %.1f° | z=%.1f" % [IDS[j], t.spec.obstacle_step_m,
			"넘음" if passed else "막힘", max_pitch, t.global_position.z])
		if passed:
			check(max_pitch > 3.0, "%s: 돌을 넘으며 차체가 앞뒤로 기욺 (%.1f°)" % [IDS[j], max_pitch])
		t.free()
	check(r.tiger1 and r.t34_76 and not r.sherman75, "0.7m 돌: 티거(0.79)·T-34(0.73) 넘음, 셔먼(0.61) 막힘")
	for j in IDS.size():
		var t := _make(IDS[j], Vector3(2700 + j * 40, 0, 0))
		var max_roll := 0.0
		t.control = TankControlInput.from_array([0.4, 0.4, 0, 0, 0, 0])
		for k in int(20.0 / DT):
			t.step(DT)
			max_roll = maxf(max_roll, absf(t.hull_roll_deg()))
		print("%s | 통나무를 한쪽 궤도로 넘을 때 최대 롤 %.1f°" % [IDS[j], max_roll])
		check(max_roll > 2.5, "%s: 한쪽 궤도로 장애물을 밟으면 차체가 옆으로 기욺 (%.1f°)" % [IDS[j], max_roll])
		t.free()


# ------------------------------------------------------------------ J
func _test_tilted_aim() -> void:
	print("\n# J. 옆으로 10° 기운 경사에서 정면 500m 표적 조준")
	print("전차 | 롤 | 좌45° 표적: 포탑/포(차체 기준) | 우45° 표적: 포탑/포 | 정면 포 월드 고저 한계 | 포탑 좌 90° / 우 90°")
	for j in IDS.size():
		var t := _make(IDS[j], Vector3(6000 + (j - 1) * 15.0, 3.0, 0))
		_run(t, [0, 0, 1, 0, 0, 0], 2.0)
		# 정면에서 좌우 45° 방향 500m 표적: 평지라면 포 각도는 둘 다 같다
		var mp := t.muzzle_position()
		var sol := t.aim_solution(mp + Vector3(-354, 0, -354))
		var sol_r := t.aim_solution(mp + Vector3(354, 0, -354))
		var lim := t.gun_world_limits_deg()
		# 포탑을 양쪽으로 90° 돌리는 시간
		var times := []
		for d in [-1.0, 1.0]:
			t.turret_yaw = 0.0
			var tt := 0.0
			t.control = TankControlInput.from_array([0, 0, 1, d, 0, 0])
			while absf(t.turret_yaw) < PI * 0.5 and tt < 60.0:
				t.step(DT)
				tt += DT
			times.append(tt)
		var roll := t.hull_roll_deg()
		print("%s | %.1f° | %.1f° / %+.2f° | %.1f° / %+.2f° | %+.1f°~%+.1f° | 좌 %.1fs / 우 %.1fs" % [IDS[j], roll,
			rad_to_deg(sol.turret_yaw), rad_to_deg(sol.gun_pitch), rad_to_deg(sol_r.turret_yaw), rad_to_deg(sol_r.gun_pitch),
			lim.x, lim.y, times[0], times[1]])
		check(absf(roll) > 8.0, "%s: 옆 경사에서 차체 롤 (%.1f°)" % [IDS[j], roll])
		check(absf(rad_to_deg(sol.gun_pitch - sol_r.gun_pitch)) > 8.0,
			"%s: 같은 높이 표적인데 좌/우에 따라 포 고저각이 크게 달라짐 → 포 각도 재조정 필요 (%.1f°)" % [IDS[j], rad_to_deg(sol.gun_pitch - sol_r.gun_pitch)])
		# 오른쪽(+X)이 들린 경사(롤 +): 포탑을 왼쪽(반시계)으로 돌리면 포가 내려가고 오른쪽은 올라간다
		var slow: float = maxf(times[0], times[1])
		var fast: float = minf(times[0], times[1])
		check(slow > fast * 1.2, "%s: 기운 차체에서 포탑을 오르막 쪽으로 돌리면 느림 (%.1fs vs %.1fs)" % [IDS[j], slow, fast])
		t.free()


# ------------------------------------------------------------------ K
func _test_suspension() -> void:
	print("\n# K. 15km/h 주행 중 급정거: 차체 숙임과 출렁임")
	var r := {}
	for j in IDS.size():
		var t := _make(IDS[j], Vector3(2000 + j * 60.0, 0, 0))
		_run(t, [0.29, 0.29, 0, 0, 0, 0], 25.0)
		var v0 := t.forward_speed() * 3.6
		var min_p := 0.0
		var settle := 0.0
		t.control = TankControlInput.from_array([0, 0, 1, 0, 0, 0])
		for k in int(10.0 / DT):
			t.step(DT)
			min_p = minf(min_p, t.hull_pitch_deg())
			if absf(t.hull_pitch_deg()) > 0.3:
				settle = (k + 1) * DT
		r[IDS[j]] = {"dive": -min_p, "settle": settle}
		print("%s | 정지 전 %.1f km/h | 최대 숙임 %.1f° | ±0.3° 안으로 가라앉기까지 %.1fs | %.1f Hz, 감쇠 %.2f" % [IDS[j], v0, -min_p,
			settle, t.spec.suspension_freq_hz, t.spec.suspension_damping])
		check(-min_p > 1.0, "%s: 급정거 시 앞이 숙여짐 (%.1f°)" % [IDS[j], -min_p])
	check(r.t34_76.settle > r.tiger1.settle and r.t34_76.settle > r.sherman75.settle, "T-34 크리스티 현가가 가장 오래 출렁임 (%.1fs)" % r.t34_76.settle)
