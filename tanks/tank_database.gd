class_name TankDatabase
extends RefCounted
## 실전 자료를 단순화한 3종 전차 제원.
## 수치는 널리 인용되는 공개 자료의 대표값이며, 생산 시기·개체별 차이는 무시했다.
## 근사치(≈)로 표시한 값은 문헌마다 차이가 커서 대표값을 고른 것이다.
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
	g.dispersion_mrad = 0.35
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
	s.engine_hp = 650.0 # Maybach HL 230 P45 (최대 700hp, 실사용 회전수 기준)
	s.max_speed_road_kmh = 38.0
	s.max_speed_offroad_kmh = 20.0
	s.track_width_m = 2.82
	s.hull_size = Vector3(3.56, 1.48, 6.32)
	s.hull_bottom_y = 0.47
	s.turret_size = Vector3(2.25, 0.95, 2.35)
	s.turret_offset_z = -0.15
	s.front_lower_split_y = 1.15
	s.side_lower_split_y = 1.30 # 측면 상부(펜더 위 상부구조) 80mm / 하부 60mm
	s.armor = {
		"hull_front_upper": {"t": 100.0, "slope": 9.0},   # 조종수 전면판
		"hull_front_lower": {"t": 100.0, "slope": 25.0},  # 하부 전면(노즈)판
		"hull_side_upper": {"t": 80.0, "slope": 0.0},
		"hull_side_lower": {"t": 60.0, "slope": 0.0},     # 보기륜 뒤
		"hull_rear": {"t": 80.0, "slope": 9.0},
		"hull_top": {"t": 25.0, "slope": 0.0},
		"hull_bottom": {"t": 25.0, "slope": 0.0},
		"turret_front": {"t": 120.0, "slope": 0.0},       # 100mm 전면 + 방순 겹침을 120mm로 단순화(≈)
		"turret_side": {"t": 80.0, "slope": 0.0},
		"turret_rear": {"t": 80.0, "slope": 0.0},
		"turret_top": {"t": 25.0, "slope": 0.0},
	}
	s.gun = g
	s.ammo_types = [g, g40, ghe]
	s.turret_traverse_deg_s = 6.0 # 유압 선회, 360°에 약 60초(엔진 회전수 의존)
	s.gun_elevation_rate_deg_s = 4.0
	s.gun_depression_deg = -8.0
	s.gun_elevation_max_deg = 15.0
	s.ammo_capacity = 92
	s.crew = [
		_crew("driver", "driver", Vector3(-0.65, 1.15, -2.35), 0.35, false),
		_crew("radio", "radio", Vector3(0.65, 1.15, -2.35), 0.35, false),
		_crew("gunner", "gunner", Vector3(-0.45, -0.15, -0.35), 0.33, true),
		_crew("commander", "commander", Vector3(-0.50, 0.15, 0.55), 0.33, true),
		_crew("loader", "loader", Vector3(0.55, -0.20, 0.10), 0.35, true),
	]
	s.modules = [
		_mod("engine", "engine", Vector3(0.0, 1.10, 2.25), 0.60),
		_mod("fuel", "fuel", Vector3(0.0, 0.85, 1.55), 0.50),       # 엔진실 양측 연료탱크를 하나로
		_mod("transmission", "transmission", Vector3(0.0, 0.90, -2.70), 0.45),
		_mod("ammo_l", "ammo", Vector3(-1.30, 1.40, -0.20), 0.45),   # 측면 스폰슨 탄약고
		_mod("ammo_r", "ammo", Vector3(1.30, 1.40, -0.20), 0.45),
		_mod("ammo_floor", "ammo", Vector3(0.0, 0.70, -0.60), 0.40),
		_mod("gun_breech", "gun", Vector3(0.0, 0.35, -0.40), 0.35, true),
		_mod("turret_ring", "turret_ring", Vector3(0.0, 0.0, 0.0), 0.55, true),
	]
	s.ammo_detonation_chance = 0.40
	s.fuel_fire_chance = 0.30 # 가솔린
	s.engine_fire_chance = 0.12
	s.notes = "전면은 거의 수직이지만 두꺼움. 30~45° 비스듬히 대면(티타임/정오 자세) 하면 전면·측면 유효장갑이 모두 크게 늘어난다."
	s.sources = ["Jentz & Doyle, Germany's Tiger Tanks", "Tank Museum Bovington Tiger 131 data", "Wikipedia: Tiger I"]
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
	s.engine_hp = 400.0 # Continental R975
	s.max_speed_road_kmh = 39.0
	s.max_speed_offroad_kmh = 24.0
	s.track_width_m = 2.11
	s.hull_size = Vector3(2.62, 1.47, 5.84)
	s.hull_bottom_y = 0.43
	s.turret_size = Vector3(1.80, 0.84, 1.85)
	s.turret_offset_z = -0.40
	s.front_lower_split_y = 1.05
	s.side_lower_split_y = 1.10
	s.armor = {
		"hull_front_upper": {"t": 51.0, "slope": 56.0},   # 용접 상부 전면판
		"hull_front_lower": {"t": 51.0, "slope": 30.0},   # 주조 변속기 덮개(곡면 0~56°)를 평균 30°로
		"hull_side_upper": {"t": 38.0, "slope": 0.0},
		"hull_side_lower": {"t": 38.0, "slope": 0.0},
		"hull_rear": {"t": 38.0, "slope": 10.0},
		"hull_top": {"t": 19.0, "slope": 0.0},
		"hull_bottom": {"t": 13.0, "slope": 0.0},
		"turret_front": {"t": 76.0, "slope": 30.0},       # 주조 포탑 전면(방순 89mm 일부 겹침 무시)
		"turret_side": {"t": 51.0, "slope": 5.0},
		"turret_rear": {"t": 51.0, "slope": 0.0},
		"turret_top": {"t": 25.0, "slope": 0.0},
	}
	s.gun = g
	s.ammo_types = [g, g72, ghe]
	s.turret_traverse_deg_s = 24.0 # 유압 동력선회, 360°에 약 15초
	s.gun_elevation_rate_deg_s = 4.0
	s.gun_depression_deg = -10.0
	s.gun_elevation_max_deg = 25.0
	s.ammo_capacity = 90
	s.crew = [
		_crew("driver", "driver", Vector3(-0.50, 1.10, -2.10), 0.33, false),
		_crew("radio", "radio", Vector3(0.50, 1.10, -2.10), 0.33, false),  # 차체 기관총수
		_crew("gunner", "gunner", Vector3(0.40, -0.15, -0.25), 0.32, true),
		_crew("commander", "commander", Vector3(0.40, 0.15, 0.45), 0.32, true),
		_crew("loader", "loader", Vector3(-0.45, -0.20, 0.05), 0.33, true),
	]
	s.modules = [
		_mod("engine", "engine", Vector3(0.0, 1.15, 2.10), 0.55),
		_mod("fuel_l", "fuel", Vector3(-0.95, 1.30, 1.35), 0.35),
		_mod("fuel_r", "fuel", Vector3(0.95, 1.30, 1.35), 0.35),
		_mod("transmission", "transmission", Vector3(0.0, 0.80, -2.50), 0.45),
		_mod("ammo_l", "ammo", Vector3(-1.00, 1.50, -0.30), 0.40),   # 스폰슨 탄약고(건식)
		_mod("ammo_r", "ammo", Vector3(1.00, 1.50, -0.30), 0.40),
		_mod("gun_breech", "gun", Vector3(0.0, 0.30, -0.35), 0.32, true),
		_mod("turret_ring", "turret_ring", Vector3(0.0, 0.0, 0.0), 0.50, true),
	]
	s.ammo_detonation_chance = 0.55 # 초기형 건식 탄약고: 화재율이 높았음
	s.fuel_fire_chance = 0.30 # 가솔린
	s.engine_fire_chance = 0.12
	s.notes = "경사 상부 전면판(51mm@56°)은 75mm급에는 유효하나 88mm에는 장거리에서도 관통됨. 기동성·선회속도·재장전이 강점."
	s.sources = ["Hunnicutt, Sherman", "Wikipedia: M4 Sherman"]
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
	s.engine_hp = 500.0 # V-2-34 디젤
	s.max_speed_road_kmh = 53.0
	s.max_speed_offroad_kmh = 30.0
	s.track_width_m = 2.45
	s.hull_size = Vector3(3.00, 1.30, 5.92)
	s.hull_bottom_y = 0.40
	s.turret_size = Vector3(1.90, 0.75, 1.90)
	s.turret_offset_z = -1.00
	s.front_lower_split_y = 0.95
	s.side_lower_split_y = 1.05
	s.armor = {
		"hull_front_upper": {"t": 45.0, "slope": 60.0},
		"hull_front_lower": {"t": 45.0, "slope": -53.0},  # 아래로 기울어진 하부 전면판
		"hull_side_upper": {"t": 40.0, "slope": 40.0},
		"hull_side_lower": {"t": 45.0, "slope": 0.0},
		"hull_rear": {"t": 40.0, "slope": 47.0},
		"hull_top": {"t": 20.0, "slope": 0.0},
		"hull_bottom": {"t": 16.0, "slope": 0.0},
		"turret_front": {"t": 52.0, "slope": 30.0},       # 육각 포탑(≈), 방순 단순화
		"turret_side": {"t": 52.0, "slope": 20.0},
		"turret_rear": {"t": 52.0, "slope": 15.0},
		"turret_top": {"t": 20.0, "slope": 0.0},
	}
	s.gun = g
	s.ammo_types = [g, gp, ghe]
	s.turret_traverse_deg_s = 25.0 # 전기 선회 ≈
	s.gun_elevation_rate_deg_s = 4.0
	s.gun_depression_deg = -5.0
	s.gun_elevation_max_deg = 26.0
	s.ammo_capacity = 100
	s.commander_is_gunner = true
	s.crew = [
		_crew("driver", "driver", Vector3(-0.45, 0.95, -2.20), 0.33, false),
		_crew("radio", "radio", Vector3(0.45, 0.95, -2.20), 0.33, false),
		_crew("commander", "gunner", Vector3(-0.38, -0.15, 0.05), 0.32, true), # 전차장 겸 포수
		_crew("loader", "loader", Vector3(0.38, -0.20, 0.05), 0.33, true),
	]
	s.modules = [
		_mod("engine", "engine", Vector3(0.0, 1.05, 1.90), 0.55),
		_mod("transmission", "transmission", Vector3(0.0, 0.90, 2.60), 0.40), # 후방 변속기
		_mod("fuel_l", "fuel", Vector3(-1.15, 1.10, -0.60), 0.35),  # 전투실 측면 내부 연료탱크
		_mod("fuel_r", "fuel", Vector3(1.15, 1.10, -0.60), 0.35),
		_mod("ammo_floor", "ammo", Vector3(0.0, 0.65, -0.70), 0.55), # 바닥 탄약함
		_mod("gun_breech", "gun", Vector3(0.0, 0.30, -0.30), 0.32, true),
		_mod("turret_ring", "turret_ring", Vector3(0.0, 0.0, 0.0), 0.50, true),
	]
	s.ammo_detonation_chance = 0.45
	s.fuel_fire_chance = 0.12 # 디젤: 잘 붙지 않음
	s.engine_fire_chance = 0.05
	s.notes = "전면 경사장갑(45mm@60°)과 빠른 속도가 강점. 전차장이 포수를 겸해 상황인식(탐지)이 떨어짐."
	s.sources = ["Zaloga, T-34/76 Medium Tank", "Wikipedia: T-34"]
	return s
