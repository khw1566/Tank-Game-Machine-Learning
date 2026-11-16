class_name TankDatabase
extends RefCounted
## 3종 전차 제원. 포·장갑 두께는 공개 자료 대표값에서 출발했지만,
## 형상·기동·사격 수치는 **각 전차의 고유 특성(→ 고유 전술)이 분명히 드러나도록** 게임용으로 조정했다.
##
##   Tiger I  : 두꺼운 장갑, 원거리에서 강한 88mm(평탄한 탄도·작은 분산·좋은 조준경), 느린 포탑·느린 기동
##   Sherman  : 높은 차체 + 좋은 포 내림각(−10°) → 헐다운 유리, 수직 1축 안정장치 → 기동간 사격 우수, 빠른 포탑
##   T-34/76  : 낮은 차체 + 경사장갑 → 피탄면적 작고 도탄 잘 남, 빠른 전진·가속, 나쁜 후진·기어 전환,
##              포 내림각 −5° → 헐다운 불리, 전차장 겸 포수 → 조준 느림
## 자세한 근거와 가정은 tanks/README.md 참고.

const IDS := ["tiger1", "sherman75", "t34_76"]


static func get_spec(id: String) -> TankSpec:
	match id:
		"tiger1":
			return tiger1()
		"sherman75":
			return sherman75()
		"t34_76":
			return t34_76()
	push_error("Unknown tank id: %s" % id)
	return null


static func all_specs() -> Array:
	return [tiger1(), sherman75(), t34_76()]


## 모든 전차의 모든 탄종 [GunSpec, ...] (시험장 탄종 선택용)
static func all_ammo() -> Array:
	var out := []
	for s in all_specs():
		out.append_array(s.ammo_types)
	return out


static func _crew(id: String, role: String, pos: Vector3, radius: float, in_turret: bool) -> Dictionary:
	return {"id": id, "home_role": role, "pos": pos, "radius": radius, "in_turret": in_turret}


static func _mod(id: String, kind: String, pos: Vector3, radius: float, in_turret := false) -> Dictionary:
	return {"id": id, "kind": kind, "pos": pos, "radius": radius, "in_turret": in_turret}


# --------------------------------------------------------------------------
# 독일: Panzerkampfwagen VI Tiger Ausf. E (중기~후기형 기준)
# --------------------------------------------------------------------------
static func tiger1() -> TankSpec:
	var g := GunSpec.new()
	g.id = "kwk36_88"
	g.display_name = "8.8 cm KwK 36 L/56"
	g.caliber_mm = 88.0
	g.muzzle_velocity_ms = 773.0
	g.shell_name = "PzGr.39 (APCBC-HE)"
	g.shell_type = "APCBC"
	g.shell_mass_kg = 10.2
	g.filler_g = 59.0 # ≈ 작약 59 g
	g.fuse_delay_m = 1.2
	g.penetration_table_30deg = [[100, 120], [500, 110], [1000, 100], [1500, 91], [2000, 84]]
	g.normalization_deg = 4.0
	g.ricochet_angle_deg = 70.0
	g.reload_s = 7.0 # 실용 발사속도 분당 약 6~8발
	g.dispersion_mrad = 0.30
	g.sources = ["Jentz & Doyle, Germany's Tiger Tanks: D.W. to Tiger I", "Wikipedia: 8.8 cm KwK 36 (penetration table, 30°)"]

	var g40 := g.variant("kwk36_88_pzgr40", "PzGr.40 (APCR)", "APCR")
	g40.muzzle_velocity_ms = 930.0
	g40.shell_mass_kg = 7.3
	g40.penetration_table_30deg = [[100, 171], [500, 156], [1000, 138], [1500, 122], [2000, 106]] # ≈ 2000m 외삽
	g40.normalization_deg = 0.0
	g40.ricochet_angle_deg = 65.0
	g40.sources = g.sources
	var ghe := g.variant("kwk36_88_he", "Sprgr. L/4.5 (HE)", "HE")
	ghe.muzzle_velocity_ms = 820.0
	ghe.shell_mass_kg = 9.0
	ghe.filler_g = 900.0
	ghe.fuse_delay_m = 0.05
	ghe.penetration_table_30deg = [[100, 15], [2000, 15]] # ≈ 고폭탄 직접 관통은 미미
	ghe.normalization_deg = 0.0
	ghe.ricochet_angle_deg = 89.0
	ghe.penetration_sigma = 0.1


	var s := TankSpec.new()
	s.id = "tiger1"
	s.display_name = "Tiger I Ausf. E"
	s.nation = "Germany"
	s.mass_t = 57.0
	s.engine_hp = 650.0
	# 형상: 크고 각진 상자형. 전면은 거의 수직이지만 두껍다.
	s.hull_length = 6.32
	s.hull_width = 3.56
	s.hull_bottom_y = 0.47
	s.hull_roof_y = 1.87
	s.nose_y = 1.15
	s.front_upper_slope_deg = 9.0
	s.front_lower_slope_deg = 25.0
	s.rear_y = 1.05
	s.rear_upper_slope_deg = 9.0
	s.rear_lower_slope_deg = 20.0
	s.side_split_y = 1.30          # 펜더 위 상부구조 80mm / 아래 60mm
	s.side_upper_slope_deg = 0.0
	s.track_width = 0.72
	s.track_height = 1.15          # 겹친 대형 보기륜이 하부측면을 많이 가림
	s.track_length = 6.0
	s.track_armor_mm = 15.0
	s.track_gauge_m = 2.82
	s.turret_width = 2.30
	s.turret_length = 2.50
	s.turret_height = 0.95
	s.turret_offset_z = -0.15
	s.mantlet_size = Vector3(1.90, 0.75, 0.25)
	s.gun_height = 0.45
	s.barrel_length = 4.9
	s.armor = {
		"hull_front_upper": {"t": 100.0}, "hull_front_lower": {"t": 100.0},
		"hull_side_upper": {"t": 80.0}, "hull_side_lower": {"t": 60.0},
		"hull_rear": {"t": 80.0}, "hull_top": {"t": 25.0}, "hull_bottom": {"t": 25.0},
		"turret_front": {"t": 100.0}, "turret_side": {"t": 80.0}, "turret_rear": {"t": 80.0}, "turret_top": {"t": 25.0},
		"mantlet": {"t": 120.0}, "gun_barrel": {"t": 0.0}, "track": {"t": 0.0},
	}
	# 기동: 느리고 무겁다. 대신 반자동 프리셀렉터 변속기 → 전후진 전환이 빠르고 후진도 쓸 만함, 제자리 선회 가능.
	s.max_forward_kmh = 20.0
	s.max_reverse_kmh = 9.0
	s.accel_mps2 = 0.9
	s.brake_mps2 = 5.0
	s.direction_change_s = 0.8
	s.steer_efficiency = 0.22
	s.neutral_steer = true
	s.climb_penalty = 1.7          # 출력중량비 11.4 hp/t → 오르막에서 크게 느려짐
	# 포·사격: 정지 사격은 최고(작은 분산·좋은 조준경), 포탑은 매우 느림, 안정장치 없음.
	s.gun = g
	s.ammo_types = [g, g40, ghe]
	s.turret_traverse_deg_s = 6.0
	s.gun_elevation_rate_deg_s = 4.0
	s.gun_depression_deg = -8.0
	s.gun_elevation_max_deg = 15.0
	s.ammo_capacity = 92
	s.aim_time_s = 1.8
	s.bloom_move_mrad_per_mps = 1.4
	s.bloom_hull_turn_mrad_per_dps = 0.12
	s.bloom_traverse_mrad_per_dps = 0.05
	s.bloom_pitch_mrad_per_dps = 0.6
	s.stabilizer_vertical = false
	s.stabilizer_bloom_factor = 1.0
	var zf := -s.turret_length * 0.5   # 포탑 정면이 수직이라 포이 = 정면판 위치
	s.crew = [
		_crew("driver", "driver", Vector3(-0.65, 1.15, -2.35), 0.35, false),
		_crew("radio", "radio", Vector3(0.65, 1.15, -2.35), 0.35, false),
		_crew("gunner", "gunner", Vector3(-0.45, -0.15, -0.35), 0.33, true),
		_crew("commander", "commander", Vector3(-0.50, 0.15, 0.55), 0.33, true),
		_crew("loader", "loader", Vector3(0.55, -0.20, 0.10), 0.35, true),
	]
	s.modules = [
		_mod("engine", "engine", Vector3(0.0, 1.10, 2.25), 0.60),
		_mod("fuel", "fuel", Vector3(0.0, 0.85, 1.55), 0.50),
		_mod("transmission", "transmission", Vector3(0.0, 0.90, -2.70), 0.45),
		_mod("ammo_l", "ammo", Vector3(-1.30, 1.40, -0.20), 0.45),
		_mod("ammo_r", "ammo", Vector3(1.30, 1.40, -0.20), 0.45),
		_mod("ammo_floor", "ammo", Vector3(0.0, 0.70, -0.60), 0.40),
	] + _turret_modules(zf, s.gun_height, -0.45)
	s.ammo_detonation_chance = 0.40
	s.fuel_fire_chance = 0.30
	s.engine_fire_chance = 0.12
	s.traits = [
		"정면 장갑 100~120mm: 연합군 75/76mm 는 정면을 어떤 거리에서도 못 뚫음 → 정면을 적에게 두고 30~45° 비스듬히",
		"88mm: 포구초속 773m/s(평탄한 탄도), 분산 0.30mrad, 조준 1.8s → 1000m 이상 원거리 정지 사격이 강점",
		"포탑 선회 6°/s(360°에 60초): 측면으로 돌아오는 적에 대응이 늦음 → 차체를 돌려 대응해야 함",
		"최고 20km/h, 가속 0.9m/s², 오르막에서 크게 느려짐. 대신 제자리 선회 가능, 전후진 전환 0.8s",
	]
	s.notes = "넓고 각진 상자형 실루엣(피탄면적 큼). 측면 하부 60mm 가 약점이지만 대형 보기륜·궤도가 15mm 만큼 막아 준다."
	return s


# --------------------------------------------------------------------------
# 미국: M4 Sherman (75mm, 용접차체·건식 탄약고 초기형 기준)
# --------------------------------------------------------------------------
static func sherman75() -> TankSpec:
	var g := GunSpec.new()
	g.id = "m3_75"
	g.display_name = "75 mm Gun M3 L/40"
	g.caliber_mm = 75.0
	g.muzzle_velocity_ms = 619.0
	g.shell_name = "M61 (APCBC-HE)"
	g.shell_type = "APCBC"
	g.shell_mass_kg = 6.79
	g.filler_g = 67.0 # Explosive D ≈ 67 g
	g.fuse_delay_m = 1.0
	# 원자료는 야드 단위(500/1000/1500/2000yd: 66/60/55/50mm). 미터로 근사 정리.
	g.penetration_table_30deg = [[100, 72], [500, 66], [1000, 60], [1500, 55], [2000, 50]]
	g.normalization_deg = 4.0
	g.ricochet_angle_deg = 70.0
	g.reload_s = 5.0 # 넓은 포탑, 분당 10발 이상 가능
	g.dispersion_mrad = 0.45
	g.sources = ["Hunnicutt, Sherman: A History of the American Medium Tank", "Wikipedia: 75 mm gun M2/M3/M6 (penetration table, 30°)"]

	var g72 := g.variant("m3_75_m72", "M72 (AP, 고체탄)", "AP")
	g72.shell_mass_kg = 6.3
	g72.filler_g = 0.0
	g72.penetration_table_30deg = [[100, 82], [500, 74], [1000, 62], [1500, 51], [2000, 43]] # ≈ 야드 표를 미터로 근사
	g72.normalization_deg = 0.0
	g72.ricochet_angle_deg = 65.0
	g72.sources = g.sources
	var ghe := g.variant("m3_75_he", "M48 (HE)", "HE")
	ghe.muzzle_velocity_ms = 463.0
	ghe.shell_mass_kg = 6.3
	ghe.filler_g = 670.0
	ghe.fuse_delay_m = 0.05
	ghe.penetration_table_30deg = [[100, 12], [2000, 12]]
	ghe.normalization_deg = 0.0
	ghe.ricochet_angle_deg = 89.0
	ghe.penetration_sigma = 0.1


	var s := TankSpec.new()
	s.id = "sherman75"
	s.display_name = "M4 Sherman (75mm)"
	s.nation = "USA"
	s.mass_t = 30.3
	s.engine_hp = 400.0
	# 형상: 높은 차체(지붕 1.95m), 경사 상부전면 56°. 실루엣은 크지만 언덕 뒤에 차체를 숨기기 좋다.
	s.hull_length = 5.84
	s.hull_width = 2.62
	s.hull_bottom_y = 0.43
	s.hull_roof_y = 1.95
	s.nose_y = 0.95
	s.front_upper_slope_deg = 56.0
	s.front_lower_slope_deg = 45.0   # 둥근 주조 변속기 덮개를 평균 45° 로
	s.rear_y = 1.0
	s.rear_upper_slope_deg = 10.0
	s.rear_lower_slope_deg = 20.0
	s.side_split_y = 1.25
	s.side_upper_slope_deg = 0.0
	s.track_width = 0.42
	s.track_height = 1.0
	s.track_length = 5.5
	s.track_armor_mm = 10.0
	s.track_gauge_m = 2.11
	s.turret_width = 1.80
	s.turret_length = 1.90
	s.turret_height = 0.80
	s.turret_offset_z = -0.40
	s.turret_front_slope_deg = 30.0
	s.turret_side_slope_deg = 10.0
	s.mantlet_size = Vector3(1.20, 0.55, 0.22)
	s.gun_height = 0.40
	s.barrel_length = 3.0
	s.armor = {
		"hull_front_upper": {"t": 51.0}, "hull_front_lower": {"t": 51.0},
		"hull_side_upper": {"t": 38.0}, "hull_side_lower": {"t": 38.0},
		"hull_rear": {"t": 38.0}, "hull_top": {"t": 19.0}, "hull_bottom": {"t": 13.0},
		"turret_front": {"t": 76.0}, "turret_side": {"t": 51.0}, "turret_rear": {"t": 51.0}, "turret_top": {"t": 25.0},
		"mantlet": {"t": 89.0}, "gun_barrel": {"t": 0.0}, "track": {"t": 0.0},
	}
	# 기동: 중간. 후진도 무난(12km/h), 제어차동식 조향(제자리 선회 불가).
	s.max_forward_kmh = 26.0
	s.max_reverse_kmh = 12.0
	s.accel_mps2 = 1.4
	s.brake_mps2 = 6.0
	s.direction_change_s = 1.2
	s.steer_efficiency = 0.18
	s.neutral_steer = false
	s.climb_penalty = 1.45
	# 포·사격: 포 내림 −10°(헐다운 핵심), 빠른 동력 선회, 수직 1축 안정장치 → 기동간 사격.
	s.gun = g
	s.ammo_types = [g, g72, ghe]
	s.turret_traverse_deg_s = 24.0
	s.gun_elevation_rate_deg_s = 5.0
	s.gun_depression_deg = -10.0
	s.gun_elevation_max_deg = 25.0
	s.ammo_capacity = 90
	s.aim_time_s = 2.2
	s.bloom_move_mrad_per_mps = 1.2
	s.bloom_hull_turn_mrad_per_dps = 0.12
	s.bloom_traverse_mrad_per_dps = 0.05
	s.bloom_pitch_mrad_per_dps = 0.6
	s.stabilizer_vertical = true
	s.stabilizer_efficiency = 0.85
	s.stabilizer_bloom_factor = 0.35
	var zf := s.gun_height * tan(deg_to_rad(s.turret_front_slope_deg)) - s.turret_length * 0.5
	s.crew = [
		_crew("driver", "driver", Vector3(-0.50, 1.10, -2.10), 0.33, false),
		_crew("radio", "radio", Vector3(0.50, 1.10, -2.10), 0.33, false),
		_crew("gunner", "gunner", Vector3(0.40, -0.15, -0.25), 0.32, true),
		_crew("commander", "commander", Vector3(0.40, 0.15, 0.45), 0.32, true),
		_crew("loader", "loader", Vector3(-0.45, -0.20, 0.05), 0.33, true),
	]
	s.modules = [
		_mod("engine", "engine", Vector3(0.0, 1.15, 2.10), 0.55),
		_mod("fuel_l", "fuel", Vector3(-0.95, 1.30, 1.35), 0.35),
		_mod("fuel_r", "fuel", Vector3(0.95, 1.30, 1.35), 0.35),
		_mod("transmission", "transmission", Vector3(0.0, 0.80, -2.40), 0.45),
		_mod("ammo_l", "ammo", Vector3(-1.00, 1.50, -0.30), 0.40),
		_mod("ammo_r", "ammo", Vector3(1.00, 1.50, -0.30), 0.40),
	] + _turret_modules(zf, s.gun_height, 0.40)
	s.ammo_detonation_chance = 0.55
	s.fuel_fire_chance = 0.30
	s.engine_fire_chance = 0.12
	s.traits = [
		"높은 차체(지붕 1.95m) + 포 내림 −10° → 능선 뒤에 차체를 숨기고 포탑만 내미는 헐다운이 가장 쉬움",
		"수직 1축 안정장치: 차체가 출렁여도 포 고저각 유지, 기동 중 조준 흔들림 35% 로 감소 → 기동간 사격",
		"포탑 선회 24°/s: 측면으로 빠르게 돌며 쏘는 기동전에 유리",
		"75mm 는 티거 정면 불가 → 헐다운으로 버티며 다른 전차가 측면을 잡게 하거나 근접 측면 공격",
	]
	s.notes = "피탄면적은 셋 중 가장 크고(특히 높이) 장갑은 얇다. 대신 헐다운하면 포탑(76mm@30°)+포방패만 노출된다."
	return s


# --------------------------------------------------------------------------
# 소련: T-34 Model 1942/43 (76.2mm F-34, 육각 포탑)
# --------------------------------------------------------------------------
static func t34_76() -> TankSpec:
	var g := GunSpec.new()
	g.id = "f34_76"
	g.display_name = "76.2 mm F-34 L/41.5"
	g.caliber_mm = 76.2
	g.muzzle_velocity_ms = 662.0
	g.shell_name = "BR-350A (APHE)"
	g.shell_type = "APHE"
	g.shell_mass_kg = 6.3
	g.filler_g = 150.0 # ≈ 문헌별 차이 큼
	g.fuse_delay_m = 1.0
	g.penetration_table_30deg = [[100, 67], [500, 61], [1000, 55], [1500, 50], [2000, 45]] # ≈
	g.normalization_deg = 3.0
	g.ricochet_angle_deg = 68.0
	g.reload_s = 6.5 # 좁은 2인 포탑, 전차장이 포수 겸임
	g.dispersion_mrad = 0.55
	g.sources = ["Zaloga, T-34/76 Medium Tank 1941-45", "Wikipedia: 76 mm tank gun M1940 F-34"]

	var gp := g.variant("f34_76_br350p", "BR-350P (APCR, 1943~)", "APCR")
	gp.muzzle_velocity_ms = 965.0
	gp.shell_mass_kg = 3.02
	gp.penetration_table_30deg = [[100, 92], [500, 80], [1000, 60], [1500, 45], [2000, 35]] # ≈
	gp.normalization_deg = 0.0
	gp.ricochet_angle_deg = 65.0
	gp.sources = g.sources
	var ghe := g.variant("f34_76_he", "OF-350 (HE)", "HE")
	ghe.muzzle_velocity_ms = 680.0
	ghe.shell_mass_kg = 6.2
	ghe.filler_g = 710.0
	ghe.fuse_delay_m = 0.05
	ghe.penetration_table_30deg = [[100, 12], [2000, 12]]
	ghe.normalization_deg = 0.0
	ghe.ricochet_angle_deg = 89.0
	ghe.penetration_sigma = 0.1


	var s := TankSpec.new()
	s.id = "t34_76"
	s.display_name = "T-34/76 (1942)"
	s.nation = "USSR"
	s.mass_t = 28.5
	s.engine_hp = 500.0
	# 형상: 낮은 차체(지붕 1.65m) + 사방 경사장갑(전면 60°, 측면 상부 40°, 후면 47°) → 작은 피탄면적, 도탄 잘 남
	s.hull_length = 5.92
	s.hull_width = 3.00
	s.hull_bottom_y = 0.40
	s.hull_roof_y = 1.65
	s.nose_y = 0.85
	s.front_upper_slope_deg = 60.0
	s.front_lower_slope_deg = 53.0
	s.rear_y = 0.95
	s.rear_upper_slope_deg = 47.0
	s.rear_lower_slope_deg = 45.0
	s.side_split_y = 1.05
	s.side_upper_slope_deg = 40.0
	s.track_width = 0.55
	s.track_height = 1.05
	s.track_length = 5.9
	s.track_armor_mm = 12.0
	s.track_gauge_m = 2.45
	s.turret_width = 1.90
	s.turret_length = 2.00
	s.turret_height = 0.72
	s.turret_offset_z = -0.60
	s.turret_front_slope_deg = 30.0
	s.turret_side_slope_deg = 20.0
	s.turret_rear_slope_deg = 15.0
	s.mantlet_size = Vector3(1.10, 0.50, 0.20)
	s.gun_height = 0.36
	s.barrel_length = 3.2
	s.armor = {
		"hull_front_upper": {"t": 45.0}, "hull_front_lower": {"t": 45.0},
		"hull_side_upper": {"t": 40.0}, "hull_side_lower": {"t": 45.0},
		"hull_rear": {"t": 40.0}, "hull_top": {"t": 20.0}, "hull_bottom": {"t": 16.0},
		"turret_front": {"t": 52.0}, "turret_side": {"t": 52.0}, "turret_rear": {"t": 52.0}, "turret_top": {"t": 20.0},
		"mantlet": {"t": 60.0}, "gun_barrel": {"t": 0.0}, "track": {"t": 0.0},
	}
	# 기동: 전진 최고속도·가속 최고. 후진은 5km/h, 4단 변속기라 전후진 전환에 2.5s,
	# 클러치-브레이크 조향이라 선회 효율이 낮다.
	s.max_forward_kmh = 34.0
	s.max_reverse_kmh = 5.0
	s.accel_mps2 = 1.9
	s.brake_mps2 = 6.0
	s.direction_change_s = 2.5
	s.steer_efficiency = 0.12
	s.neutral_steer = false
	s.climb_penalty = 1.1          # 출력중량비 17.5 hp/t
	# 포·사격: 포 내림 −5° 뿐(헐다운하면 앞쪽 아래 적을 못 겨눔). 전차장 겸 포수 → 조준이 느리고 분산 큼.
	s.gun = g
	s.ammo_types = [g, gp, ghe]
	s.turret_traverse_deg_s = 20.0
	s.gun_elevation_rate_deg_s = 4.0
	s.gun_depression_deg = -5.0
	s.gun_elevation_max_deg = 26.0
	s.ammo_capacity = 100
	s.aim_time_s = 3.0
	s.bloom_move_mrad_per_mps = 1.5
	s.bloom_hull_turn_mrad_per_dps = 0.14
	s.bloom_traverse_mrad_per_dps = 0.06
	s.bloom_pitch_mrad_per_dps = 0.9  # 크리스티 현가장치: 차체가 많이 출렁임
	s.stabilizer_vertical = false
	s.stabilizer_bloom_factor = 1.0
	s.commander_is_gunner = true
	var zf := s.gun_height * tan(deg_to_rad(s.turret_front_slope_deg)) - s.turret_length * 0.5
	s.crew = [
		_crew("driver", "driver", Vector3(-0.45, 0.95, -2.20), 0.33, false),
		_crew("radio", "radio", Vector3(0.45, 0.95, -2.20), 0.33, false),
		_crew("commander", "gunner", Vector3(-0.38, -0.15, 0.05), 0.32, true), # 전차장 겸 포수
		_crew("loader", "loader", Vector3(0.38, -0.20, 0.05), 0.33, true),
	]
	s.modules = [
		_mod("engine", "engine", Vector3(0.0, 1.05, 1.90), 0.55),
		_mod("transmission", "transmission", Vector3(0.0, 0.90, 2.55), 0.40),
		_mod("fuel_l", "fuel", Vector3(-1.10, 1.10, -0.60), 0.33),
		_mod("fuel_r", "fuel", Vector3(1.10, 1.10, -0.60), 0.33),
		_mod("ammo_floor", "ammo", Vector3(0.0, 0.65, -0.70), 0.55),
	] + _turret_modules(zf, s.gun_height, -0.38)
	s.ammo_detonation_chance = 0.45
	s.fuel_fire_chance = 0.12
	s.engine_fire_chance = 0.05
	s.traits = [
		"낮은 차체(지붕 1.65m, 전고 2.37m) + 경사장갑 → 피탄면적 최소, 비스듬히 맞으면 도탄 가능성 큼",
		"전진 34km/h·가속 1.9m/s² → 빠르게 우회해 티거 측면으로 파고드는 기동",
		"후진 5km/h, 전후진 전환 2.5s → 한 번 들어가면 빠지기 어려움(후퇴는 차체를 돌려서)",
		"포 내림 −5° → 능선 위 헐다운에서 아래쪽 적을 못 겨눔. 정지 사격도 조준이 느림(3.0s)",
	]
	s.notes = "피탄면적은 작지만 88mm 에는 어디든 관통된다. 장점은 '덜 맞고, 튕기고, 빨리 다가가는 것'."
	return s


## 모든 전차 공통 포탑 내부 모듈(포탑 좌표계).
## zf: 포이(포탑 정면판) z, gy: 포이 높이, gunner_x: 포수 쪽 x
static func _turret_modules(zf: float, gy: float, gunner_x: float) -> Array:
	return [
		_mod("gun_mount", "gun_mount", Vector3(0.0, gy, zf + 0.18), 0.22, true),     # 포방패 뒤 고저장치·포이
		_mod("recoil", "recoil", Vector3(0.0, gy + 0.05, zf + 0.55), 0.24, true),    # 주퇴복좌기
		_mod("gun_breech", "gun", Vector3(0.0, gy - 0.05, zf + 0.95), 0.30, true),   # 포미
		_mod("sight", "sight", Vector3(gunner_x, gy + 0.05, zf + 0.30), 0.15, true), # 포수 조준경
		_mod("traverse_drive", "traverse_drive", Vector3(gunner_x, 0.05, zf + 0.75), 0.20, true),
		_mod("turret_ring", "turret_ring", Vector3(0.0, 0.0, 0.0), 0.50, true),
	]
