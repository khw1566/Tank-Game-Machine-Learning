extends SceneTree
## 장갑·피해 모델 헤드리스 검증 + 보고서용 표 출력.
## 실행: godot --headless --path . -s res://tanks/tests/run_tank_tests.gd
## 옵션: -- --export   (tanks/data/*.json 으로 제원·관통확률표 저장)

var failures := 0
var checks := 0


func _init() -> void:
	var export := "--export" in OS.get_cmdline_user_args()
	_print_specs()
	_print_penetration_tables()
	var matrix := _print_angle_matrix()
	_unit_tests()
	_monte_carlo()
	if export:
		_export(matrix)
	print("\n== %d checks, %d failures ==" % [checks, failures])
	quit(1 if failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	checks += 1
	if cond:
		print("  PASS  ", msg)
	else:
		failures += 1
		print("  FAIL  ", msg)


## 표적 로컬 좌표에서, 표적 정면 기준 방위 bearing_deg(+ = 우측) 에서 날아오는 수평 광선.
func ray_from_bearing(bearing_deg: float, aim: Vector3) -> Array:
	var b := deg_to_rad(bearing_deg)
	var origin := aim + Vector3(sin(b), 0.0, -cos(b)) * 60.0
	return [origin, (aim - origin).normalized()]


func aim_point(spec: TankSpec, where: String) -> Vector3:
	var hh := spec.hull_roof_y - spec.hull_bottom_y
	match where:
		"turret":
			# 포방패 위쪽 포탑면(포방패를 피해 포탑 장갑 자체를 겨냥)
			return spec.turret_origin() + Vector3(0, spec.turret_height * 0.93, 0)
		"mantlet":
			return spec.turret_origin() + Vector3(spec.mantlet_size.x * 0.3, spec.gun_height, 0) # 포신을 피해 옆으로
		"hull_low":
			return Vector3(0, spec.hull_bottom_y + hh * 0.2, 0)
	return Vector3(0, spec.hull_bottom_y + hh * 0.75, 0) # hull_high


## 관통확률(궤도를 지나면 궤도가 막는 만큼 관통력 감소 반영). DamageModel 과 같은 규칙.
func pen_prob(target: TankSpec, gun: GunSpec, dist: float, bearing: float, where: String) -> Dictionary:
	var r := ray_from_bearing(bearing, aim_point(target, where))
	var rng := RandomNumberGenerator.new()
	var res := DamageModel.resolve_shot(TankDamageState.new(target), 0.0, r[0], r[1], dist, gun, rng)
	if not res.hit:
		return {"zone": "-", "angle": 0.0, "eff": 0.0, "p": 0.0, "ricochet": 0.0, "track": false}
	return {"zone": res.zone, "angle": res.impact_angle_deg, "eff": res.effective_mm, "p": res.pen_probability,
		"ricochet": Ballistics.ricochet_chance(gun, res.plate_mm, res.impact_angle_deg) if res.plate_mm > 0 else 0.0,
		"track": res.has("track_hit")}


func _print_specs() -> void:
	print("\n# 전차 제원 요약")
	for s in TankDatabase.all_specs():
		var sh: TankShape = s.shape()
		print("- %s: %.1ft %dhp(%.1fhp/t) | 전진 %d / 후진 %d km/h, 전후진 전환 %.1fs | 포 %s 재장전 %.1fs | 포탑 %.0f°/s | 포 %+.0f°~%+.0f° | 안정장치 %s | 전고 %.2fm, 정면 %.1fm², 측면 %.1fm²" % [
			s.display_name, s.mass_t, s.engine_hp, s.power_to_weight(), s.max_forward_kmh, s.max_reverse_kmh,
			s.direction_change_s, s.gun.display_name, s.gun.reload_s, s.turret_traverse_deg_s,
			s.gun_depression_deg, s.gun_elevation_max_deg, "있음" if s.stabilizer_vertical else "없음",
			s.total_height(), sh.projected_area(Vector3.FORWARD), sh.projected_area(Vector3.RIGHT)])
		var parts := []
		for z in TankSpec.ZONES:
			parts.append("%s %d" % [z, s.plate(z).t])
		print("    ", ", ".join(parts))
		for t in s.traits:
			print("    * ", t)


func _print_penetration_tables() -> void:
	print("\n# 거리별 평균 관통력 (수직 0° 환산, mm)")
	var dists := [100, 250, 500, 750, 1000, 1500, 2000]
	print("포·탄 | ", " | ".join(dists.map(func(d): return "%dm" % d)))
	for g in TankDatabase.all_ammo():
		var row := []
		for d in dists:
			row.append("%.0f" % g.penetration_mm(d))
		print("%s | %s" % [g.label(), " | ".join(row)])


## 티거를 여러 각도로 세웠을 때 연합군 포의 관통확률(차체 상단 조준).
func _print_angle_matrix() -> Dictionary:
	var tiger := TankDatabase.tiger1()
	var out := {}
	var bearings := [0, 15, 30, 35, 45, 60, 75, 90, 135, 180]
	for shooter_id in ["sherman75", "t34_76"]:
		var gun := TankDatabase.get_spec(shooter_id).gun
		for where in ["hull_high", "hull_low", "turret"]:
			print("\n# %s → Tiger I 관통확률 (%s 조준, 방위 = 티거 정면 기준 사수 각도)" % [gun.display_name, where])
			print("거리 | ", " | ".join(bearings.map(func(b): return "%d°" % b)))
			var table := {}
			for dist in [100, 300, 500, 1000]:
				var row := []
				var vals := []
				for b in bearings:
					var r := pen_prob(tiger, gun, dist, b, where)
					row.append("%3.0f%%" % (r.p * 100.0))
					vals.append(snappedf(r.p, 0.001))
				table[str(dist)] = vals
				print("%dm | %s" % [dist, " | ".join(row)])
			out["%s_vs_tiger1_%s" % [shooter_id, where]] = {"bearings": bearings, "by_distance": table}
	var tgun := tiger.gun
	for target_id in ["sherman75", "t34_76"]:
		var target := TankDatabase.get_spec(target_id)
		print("\n# 8.8cm KwK 36 → %s 관통확률 (차체 상단 조준)" % target.display_name)
		print("거리 | ", " | ".join(bearings.map(func(b): return "%d°" % b)))
		var table := {}
		for dist in [500, 1000, 1500, 2000]:
			var row := []
			var vals := []
			for b in bearings:
				var r := pen_prob(target, tgun, dist, b, "hull_high")
				row.append("%3.0f%%" % (r.p * 100.0))
				vals.append(snappedf(r.p, 0.001))
			table[str(dist)] = vals
			print("%dm | %s" % [dist, " | ".join(row)])
		out["tiger1_vs_%s_hull_high" % target_id] = {"bearings": bearings, "by_distance": table}
	return out


func _unit_tests() -> void:
	print("\n# 단위 검증")
	var tiger := TankDatabase.tiger1()
	var sherman := TankDatabase.sherman75()
	var t34 := TankDatabase.t34_76()

	# 구역 판정
	check(pen_prob(tiger, sherman.gun, 500, 0, "hull_high").zone == "hull_front_upper", "정면 상단 조준 → hull_front_upper")
	var side_low := pen_prob(tiger, sherman.gun, 500, 90, "hull_low")
	check(side_low.zone == "hull_side_lower" and side_low.track, "측면 하단 조준 → 궤도를 지나 hull_side_lower")
	check(pen_prob(tiger, sherman.gun, 500, 0, "mantlet").zone == "mantlet", "포 높이 정면 → 포방패")
	check(pen_prob(tiger, sherman.gun, 500, 180, "hull_high").zone == "hull_rear", "후방 → hull_rear")
	check(pen_prob(tiger, sherman.gun, 500, 0, "turret").zone == "turret_front", "포탑 정면")
	var r_turret := ray_from_bearing(0, aim_point(tiger, "turret"))
	var tr_rot := HitGeometry.trace(tiger, PI * 0.5, r_turret[0], r_turret[1])
	check(tr_rot.zone == "turret_side", "포탑을 90° 돌리면 정면 사격이 포탑 측면에 맞음")
	# 포신: 포 앞에서 포신 축을 따라 약간 비켜 오는 사격
	var bz: Vector3 = tiger.turret_origin() + tiger.shape().trunnion + Vector3(0, 0, -2.5)
	var tr_b := HitGeometry.trace(tiger, 0.0, bz + Vector3(5, 0, 0), Vector3.LEFT)
	check(tr_b.zone == "gun_barrel", "포신 옆구리 사격 → gun_barrel (%s)" % tr_b.get("zone", "-"))
	var st_b := TankDamageState.new(tiger)
	var rb := RandomNumberGenerator.new()
	rb.seed = 7
	DamageModel.resolve_shot(st_b, 0.0, bz + Vector3(5, 0, 0), Vector3.LEFT, 500, sherman.gun, rb)
	check(st_b.modules.gun_barrel != TankDamageState.MOD_OK, "포신 명중 → 포신 손상/파괴 (%s)" % st_b.modules.gun_barrel)

	# 형상 특성: 낮고 경사진 T-34 가 피탄면적 최소, 셔먼 차체가 가장 높음
	var fa := {}
	for sp in [tiger, sherman, t34]:
		fa[sp.id] = sp.shape().projected_area(Vector3.FORWARD)
	check(fa.t34_76 < fa.sherman75 and fa.sherman75 < fa.tiger1, "정면 피탄면적 T-34 %.1f < 셔먼 %.1f < 티거 %.1f m²" % [fa.t34_76, fa.sherman75, fa.tiger1])
	check(t34.total_height() < sherman.total_height() and sherman.hull_roof_y > t34.hull_roof_y + 0.25, "셔먼 차체 지붕 %.2fm > T-34 %.2fm" % [sherman.hull_roof_y, t34.hull_roof_y])
	# 도탄: 같은 88mm 로 30° 비스듬히 쏘면 T-34 전면이 셔먼 전면보다 도탄 가능성이 큼
	var ric_t34 := pen_prob(t34, tiger.gun, 1000, 30, "hull_high")
	var ric_sh := pen_prob(sherman, tiger.gun, 1000, 30, "hull_high")
	check(ric_t34.ricochet > ric_sh.ricochet, "88mm 30° 사격 도탄확률: T-34 %.0f%% > 셔먼 %.0f%%" % [ric_t34.ricochet * 100, ric_sh.ricochet * 100])
	var ric_t34_75 := pen_prob(t34, sherman.gun, 500, 30, "hull_high")
	check(ric_t34_75.ricochet > 0.2, "75mm 로 T-34 전면을 30° 에서 쏘면 도탄 20%% 이상 (%.0f%%)" % [ric_t34_75.ricochet * 100])
	check(pen_prob(tiger, sherman.gun, 500, 0, "hull_high").ricochet == 0.0, "티거 수직 전면판은 정면에서 도탄 없음(두께로 막음)")

	# 학습용 balance v3: 연합군 포는 티거 정면을 근거리에서만, 측면은 교전 거리에서 관통.
	check(pen_prob(tiger, sherman.gun, 500, 0, "hull_high").p < 0.05, "셔먼 76mm: 500m 티거 정면은 거의 못 뚫음")
	check(pen_prob(tiger, t34.gun, 100, 0, "hull_high").p > 0.8, "T-34-85: 100m 티거 정면 관통")
	check(pen_prob(tiger, sherman.gun, 400, 90, "hull_high").p > 0.95, "셔먼 76mm: 400m 티거 측면 관통")
	var p_sh: float = pen_prob(sherman, tiger.gun, 2000, 0, "hull_high").p
	var p_t34: float = pen_prob(t34, tiger.gun, 2000, 0, "hull_high").p
	check(p_sh > 0.9, "88mm는 2000m에서 셔먼 정면 관통 (%.0f%%, 나머지는 도탄)" % [p_sh * 100])
	check(p_t34 > 0.75 and p_t34 < p_sh, "88mm는 2000m에서 T-34 정면도 대부분 관통하지만 경사 때문에 셔먼보다 도탄이 잦음 (%.0f%%)" % [p_t34 * 100])
	check(pen_prob(tiger, sherman.gun, 300, 90, "hull_low").p > 0.7, "셔먼은 300m에서 궤도 너머 티거 하부측면(60mm) 관통 (%.0f%%)" % [pen_prob(tiger, sherman.gun, 300, 90, "hull_low").p * 100])
	check(t34.gun.penetration_mm(100) > t34.gun.penetration_mm(500), "T-34-85는 가까울수록 평균 관통력 증가")
	check(tiger.plate("hull_side_lower").t + tiger.track_armor_mm < tiger.plate("hull_side_upper").t, "티거 하부측면은 궤도를 포함해도 상부측면보다 얇음")
	check(pen_prob(tiger, sherman.gun, 100, 180, "hull_high").p > 0.1, "셔먼은 100m에서 티거 후면(80mm) 관통 가능 (%.0f%%)" % [pen_prob(tiger, sherman.gun, 100, 180, "hull_high").p * 100])
	# 지정한 최적 자세는 35°다. 45°에서는 측면 장갑의 입사각이 작아져 다시 취약해진다.
	var side_at_35 := pen_prob(tiger, sherman.gun, 300, 35, "hull_high")
	check(side_at_35.p < 0.01, "티거 35°: 300m 셔먼탄을 차체에서 방어 (%s, %.0f%%)" % [side_at_35.zone, side_at_35.p * 100])

	# 탄종
	var pzgr40: GunSpec = tiger.ammo_types[1]
	var he88: GunSpec = tiger.ammo_types[2]
	check(tiger.ammo_types.size() == 3 and pzgr40.shell_type == "APCR" and he88.is_he(), "티거 탄종 3종(APCBC/APCR/HE)")
	check(pzgr40.penetration_mm(100) > tiger.gun.penetration_mm(100), "PzGr.40은 근거리 관통력이 PzGr.39보다 높음")
	check(pen_prob(sherman, he88, 500, 0, "hull_high").p < 0.01, "88mm 고폭탄은 셔먼 정면 장갑 관통 불가")
	check(pen_prob(tiger, he88, 500, 0, "turret").p < 0.01, "고폭탄은 티거 포탑도 관통 불가")
	var gp: GunSpec = t34.ammo_types[1]
	check(gp.penetration_mm(100) > t34.gun.penetration_mm(100), "T-34-85 APCR은 주력탄보다 평균 관통력이 높음")

	# 승무원 역할 재배정
	var st := TankDamageState.new(sherman)
	var base_reload := st.reload_time_s()
	st.crew_member("gunner").status = TankDamageState.CREW_KIA
	st.reassign_roles()
	check(st.roles.gunner == "radio" and st.roles.radio == "", "포수 전사 → 우선순위 낮은 무전수가 포수 자리로")
	check(st.can_fire() and absf(st.reload_time_s() - base_reload) < 0.01, "장전수는 그대로라 재장전 시간 유지")
	st.crew_member("loader").status = TankDamageState.CREW_KIA
	st.reassign_roles()
	check(st.roles.loader == "commander" and absf(st.reload_time_s() - base_reload * 1.3) < 0.01, "장전수 전사 → 전차장이 장전(자기 자리 아님 1.3배)")
	st.crew_member("commander").status = TankDamageState.CREW_KIA
	st.reassign_roles()
	check(st.roles.loader == "" and st.reload_time_s() >= base_reload * 2.5, "전차장까지 전사 → 포수가 직접 장전, 재장전 2.5배 이상 (%.1fs → %.1fs)" % [base_reload, st.reload_time_s()])
	var st2 := TankDamageState.new(sherman)
	st2.crew_member("driver").status = TankDamageState.CREW_KIA
	st2.reassign_roles()
	check(st2.roles.driver != "" and st2.can_move(), "조종수 전사 → 다른 승무원이 운전")
	for c in st.crew:
		c.status = TankDamageState.CREW_KIA
	st.crew[0].status = TankDamageState.CREW_OK
	st.reassign_roles()
	st.update_knockout()
	check(st.is_knocked_out() and st.knockout_cause == "crew_casualties", "생존 1명 → 전투불능")

	var tst := TankDamageState.new(t34)
	check(absf(tst.spotting_multiplier() - 1.0) < 0.001, "T-34-85 전차장과 포수 분리 → 탐지 배율 1.0")

	var mst := TankDamageState.new(tiger)
	mst.modules.track_left = TankDamageState.MOD_DESTROYED
	check(not mst.can_move() and mst.track_efficiency("left") == 0.0 and mst.can_fire(), "궤도 절단 → 기동불능, 사격 가능")
	mst.update_knockout()
	check(not mst.is_knocked_out(), "궤도 절단만으로는 전투불능 아님")

	# 공통 모듈 효과
	var gm := TankDamageState.new(sherman)
	check(gm.stabilizer_working(), "셔먼 안정장치 정상 동작")
	gm.modules.gun_mount = TankDamageState.MOD_DESTROYED
	check(gm.elevation_rate_deg_s() == 0.0 and not gm.stabilizer_working(), "고저장치(gun_mount) 파괴 → 포 고저 고착 + 안정장치 정지")
	var rc := TankDamageState.new(t34)
	var r0 := rc.reload_time_s()
	rc.modules.recoil = TankDamageState.MOD_DAMAGED
	check(rc.reload_time_s() > r0 * 1.4, "주퇴기 손상 → 재장전 1.5배")
	rc.modules.recoil = TankDamageState.MOD_DESTROYED
	check(not rc.can_fire(), "주퇴기 파괴 → 사격 불가")
	var sg := TankDamageState.new(tiger)
	sg.modules.sight = TankDamageState.MOD_DAMAGED
	check(sg.dispersion_factor() > 1.5 and sg.aim_time_factor() > 1.4, "조준경 손상 → 분산·조준시간 증가")
	var tdv := TankDamageState.new(sherman)
	var trav0 := tdv.traverse_rate_deg_s()
	tdv.modules.traverse_drive = TankDamageState.MOD_DESTROYED
	check(absf(tdv.traverse_rate_deg_s() - trav0 * 0.15) < 0.01 and tdv.can_traverse(), "선회장치 파괴 → 수동 선회(15%)")
	for sp in [tiger, sherman, t34]:
		var ids := TankDamageState.new(sp).modules.keys()
		var ok := true
		for need in ["track_left", "track_right", "gun_barrel", "gun_mount", "recoil", "gun_breech", "sight", "traverse_drive", "turret_ring"]:
			ok = ok and need in ids
		check(ok, "%s: 공통 모듈(궤도·포신·고저장치·주퇴기·포미·조준경·선회장치·선회링) 모두 있음" % sp.id)

	# 재현성
	var a := _shoot_once(tiger, sherman.gun, 300, 90, 12345)
	var b := _shoot_once(tiger, sherman.gun, 300, 90, 12345)
	check(JSON.stringify(a) == JSON.stringify(b), "같은 시드 → 같은 결과(재현 가능)")
	check(JSON.stringify(a).length() > 0 and a.has("damage"), "결과는 JSON 직렬화 가능")
	print("  예시 결과: ", JSON.stringify(a))


func _shoot_once(target: TankSpec, gun: GunSpec, dist: float, bearing: float, seed_v: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var st := TankDamageState.new(target)
	var r := ray_from_bearing(bearing, aim_point(target, "hull_low"))
	return DamageModel.resolve_shot(st, 0.0, r[0], r[1], dist, gun, rng)


## 무작위 명중점으로 여러 발을 쏴서 "몇 발 만에 전투불능"인지 통계.
func _monte_carlo() -> void:
	print("\n# 몬테카를로: 표적 중심 ±(폭/2, 높이/2) 무작위 명중, 전투불능까지 필요한 명중 수 (최대 10발, 400회)")
	var cases := [
		["tiger1", "sherman75", 300, 0], ["tiger1", "sherman75", 300, 35], ["tiger1", "sherman75", 300, 90],
		["tiger1", "sherman75", 300, 180], ["tiger1", "t34_76", 300, 90],
		["sherman75", "tiger1", 1000, 0], ["t34_76", "tiger1", 1000, 0], ["sherman75", "tiger1", 1000, 45],
	]
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	for cs in cases:
		var target := TankDatabase.get_spec(cs[0])
		var gun := TankDatabase.get_spec(cs[1]).gun
		var dist: float = cs[2]
		var bearing: float = cs[3]
		var trials := 400
		var kills := 0
		var total_hits := 0
		var causes := {}
		for i in trials:
			var st := TankDamageState.new(target)
			for shot in 10:
				var aim := Vector3(rng.randf_range(-1.2, 1.2), rng.randf_range(0.2, target.total_height()), 0)
				var r := ray_from_bearing(bearing, aim)
				var res := DamageModel.resolve_shot(st, 0.0, r[0], r[1], dist, gun, rng)
				if not res.hit:
					continue
				if st.is_knocked_out():
					kills += 1
					total_hits += shot + 1
					causes[st.knockout_cause] = causes.get(st.knockout_cause, 0) + 1
					break
		var avg := float(total_hits) / maxf(kills, 1)
		print("- %s → %s %dm 방위 %d°: 10발 내 전투불능 %.0f%%, 평균 %.1f발, 원인 %s" % [
			gun.display_name, target.display_name, dist, bearing, 100.0 * kills / trials, avg, JSON.stringify(causes)])


func _export(matrix: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://tanks/data"))
	var specs := {}
	for s in TankDatabase.all_specs():
		specs[s.id] = s.to_dict()
	_write_json("res://tanks/data/tank_specs.json", specs)
	_write_json("res://tanks/data/penetration_matrix.json", matrix)
	print("\n내보냄: res://tanks/data/tank_specs.json, penetration_matrix.json")


func _write_json(path: String, data) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "  "))
	f.close()
