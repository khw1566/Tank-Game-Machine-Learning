class_name TankSpec
extends RefCounted
## 전차 한 종류의 정적 제원. "현실 수치 재현"보다 **전차마다 다른 전술을 낳는 특성**을 담는 것이 목적이다.
##
## 좌표계(전차 로컬, Godot 규약): -Z = 차체 정면, +X = 우측, +Y = 위. 원점은 차체 바닥 중앙의 지면.
##
## 모든 전차는 같은 모듈 구조를 가진다(TankShape 가 이 제원으로 형상을 만든다):
##   1. 무한궤도   track_left / track_right   — 차체 옆 하부를 덮는 상자. 맞으면 궤도 손상, 탄은 관통력이 깎인 채 차체로 진행
##   2. 포탑       turret_front/side/rear/top 장갑면 + 내부 모듈 turret_ring(선회링), traverse_drive(선회장치), sight(조준경)
##   3. 포방패     mantlet                    — 포탑 정면 앞에 붙은 별도 장갑. 뒤에 gun_mount(고저장치)
##   4. 주퇴기·주포 recoil(주퇴복좌기), gun_breech(포미), gun_barrel(포신: 밖으로 나온 얇은 상자)
##   5. 차체 장갑  hull_front_upper/lower, hull_side_upper/lower, hull_rear, hull_top, hull_bottom
##
## 경사장갑은 "법선만 기울인 상자"가 아니라 **실제로 기울어진 면**이다(볼록 다면체).
## 그래서 낮고 경사진 T-34 는 피탄 면적이 실제로 작고, 입사각·도탄이 형상에서 바로 나온다.

## 장갑 구역 이름(관측·로그에 그대로 쓰임).
const ZONES := [
	"hull_front_upper", "hull_front_lower", "hull_side_upper", "hull_side_lower",
	"hull_rear", "hull_top", "hull_bottom",
	"turret_front", "turret_side", "turret_rear", "turret_top",
	"mantlet", "gun_barrel", "track",
]

var id: String = ""
var display_name: String = ""
var nation: String = ""
var mass_t: float = 0.0
var engine_hp: float = 0.0

# ---------------------------------------------------------------- 형상(차체)
var hull_length: float = 6.0
## 궤도 포함 전체 폭
var hull_width: float = 3.0
## 지상고(차체 바닥 높이)
var hull_bottom_y: float = 0.45
## 차체 지붕 높이(지면 기준)
var hull_roof_y: float = 1.9
## 호환용(시야·지도 코드에서 쓰는 이전 이름): 차체 외곽 상자 폭·높이·길이, 포탑 상자
var hull_size: Vector3:
	get:
		return Vector3(hull_width, hull_roof_y - hull_bottom_y, hull_length)
var turret_size: Vector3:
	get:
		return Vector3(turret_width, turret_height, turret_length)
## 상·하부 전면판이 만나는 코(nose) 높이
var nose_y: float = 1.0
## 전면판 경사(수직 기준 °). 상부는 위가 뒤로, 하부는 아래가 뒤로 기운다.
var front_upper_slope_deg: float = 0.0
var front_lower_slope_deg: float = 0.0
var rear_y: float = 1.0
var rear_upper_slope_deg: float = 0.0
var rear_lower_slope_deg: float = 0.0
## 이 높이 위의 측면 = hull_side_upper. side_upper_slope_deg > 0 이면 그 위 측면이 안쪽으로 기운다(T-34 경사 측면).
var side_split_y: float = 1.2
var side_upper_slope_deg: float = 0.0

# ---------------------------------------------------------------- 형상(궤도)
## 궤도 하나의 폭(차체 바깥쪽에서 안쪽으로), 높이(보기륜 포함), 길이
var track_width: float = 0.5
var track_height: float = 1.0
var track_length: float = 5.8
## 궤도·보기륜이 흡수하는 관통력(mm). 궤도 너머 차체 하부측면을 쏘면 이만큼 깎인다.
var track_armor_mm: float = 20.0
## 궤도 중심 간 거리(m). 피벗 선회 계산용.
var track_gauge_m: float = 2.5

# ---------------------------------------------------------------- 형상(포탑·포)
var turret_width: float = 2.0
var turret_length: float = 2.0
var turret_height: float = 0.9
## 포탑 회전축의 차체 길이방향 위치(음수 = 앞쪽)
var turret_offset_z: float = 0.0
var turret_front_slope_deg: float = 0.0
var turret_side_slope_deg: float = 0.0
var turret_rear_slope_deg: float = 0.0
## 포방패 상자 크기(폭, 높이, 두께 방향 깊이)
var mantlet_size: Vector3 = Vector3(1.2, 0.6, 0.25)
## 포이(trunnion) 높이(포탑 바닥 기준)
var gun_height: float = 0.45
var barrel_length: float = 3.5

## 구역 -> {"t": 두께 mm}. 경사는 형상에서 나온다.
var armor: Dictionary = {}

# ---------------------------------------------------------------- 기동
## 최고속도: 전진 / 후진 (km/h). 변속기 최고단 속도(기어표에서 계산, 호환용 필드).
## 야지에서 실제로 낼 수 있는 속도는 출력·구름저항·경사로 정해진다(Tank._drive).
var max_forward_kmh: float = 25.0
var max_reverse_kmh: float = 8.0
## 브레이크 감속(m/s²)
var brake_mps2: float = 6.0
## 전진 ↔ 후진 전환 시 완전히 멈춘 뒤 기어를 바꾸는 데 걸리는 시간(초)
var direction_change_s: float = 1.0
## 조향 효율(궤도 속도차 대비 실제 선회율, 0~1). 클러치-브레이크 조향은 낮다.
var steer_efficiency: float = 0.35
## 제자리 선회(양쪽 궤도 역회전) 가능 여부. 불가면 반대 궤도는 멈추기만 한다.
var neutral_steer: bool = false

# ---------------------------------------------------------------- 변속기·엔진
## 기어별 최고속도(km/h, 엔진 정격 회전수 기준). 실제 변속기 기어비에서 계산한 값.
var forward_gears_kmh: Array = [5.0, 10.0, 25.0]
var reverse_gears_kmh: Array = [5.0]
## 출발 기어(전진). 실제 조종수가 보통 쓰던 출발단.
var start_gear: int = 1
## 기어 하나 바꾸는 데 걸리는 시간(초). 이동 중 이 시간 동안 동력이 끊긴다.
var shift_time_s: float = 1.0
## 특정 변속만 다른 시간: {"2>3": 3.0} (위로/아래로 각각)
var shift_time_overrides: Dictionary = {}
## 엔진 반응 시간(초): 스로틀을 열고 나서 최대 견인력까지
var engine_response_s: float = 1.0
## 게임용 가속 배율. 양의 순가속에만 적용하므로 기어 최고속도·등판 가능 기어는 그대로다.
var acceleration_scale: float = 4.0
## 접지압(kg/cm²). 클수록 야지 구름저항이 커진다(넓은 궤도 = 유리).
var ground_pressure_kgcm2: float = 0.9
## 넘을 수 있는 수직 장애물 높이(m). 이보다 낮은 돌·통나무는 타고 넘으며 차체가 기운다.
var obstacle_step_m: float = 0.6

# ---------------------------------------------------------------- 현가장치(차체 출렁임)
## 피치/롤 고유진동수(Hz)와 감쇠비(0~1). 낮은 감쇠 = 오래 출렁임.
var suspension_freq_hz: float = 1.0
var suspension_damping: float = 0.3
## 가감속 1 m/s² 당 차체 피치(°, 가속 시 앞이 들림·제동 시 앞이 숙여짐) / 선회 원심가속 1 m/s² 당 롤(°)
var suspension_pitch_deg_per_mps2: float = 0.5
var suspension_roll_deg_per_mps2: float = 0.4

# ---------------------------------------------------------------- 포·사격
## 기본 탄(ammo_types[0])
var gun: GunSpec
## 이 전차가 쓸 수 있는 탄종 목록(포 공통값은 같고 탄만 다름)
var ammo_types: Array = []
var turret_traverse_deg_s: float = 15.0
## 차체가 기울었을 때 포탑을 "오르막 쪽"으로 돌리면 느려지고 내리막 쪽은 빨라지는 정도.
## 선회속도 × (1 − 계수 × sin(기울기) × 방향). 포탑이 무겁고 선회장치가 약할수록 크다.
var traverse_slope_penalty: float = 2.0
var gun_elevation_rate_deg_s: float = 4.0
## 포 내림 한계(음수) / 올림 한계 (차체 기준 °). 헐다운 가능 여부를 정한다.
var gun_depression_deg: float = -8.0
var gun_elevation_max_deg: float = 15.0
var ammo_capacity: int = 80
## 수직(고저) 1축 안정장치. 차체가 출렁여도 포의 월드 고저각을 유지하고, 기동 중 조준 흔들림을 줄인다.
var stabilizer_vertical: bool = false
## 안정장치 효율(0~1): 차체 피치 변화 중 이 비율만큼 보정
var stabilizer_efficiency: float = 0.0
## 조준 오차(분산 1σ, mrad) 모델. 정지 시 포 분산(gun.dispersion_mrad)까지 aim_time_s 시상수로 수렴.
## 이동 속도(m/s)·차체 선회(°/s)·포탑 선회(°/s)·차체 흔들림(°/s) 이 오차를 키운다.
var aim_time_s: float = 2.5
var bloom_move_mrad_per_mps: float = 1.2
var bloom_hull_turn_mrad_per_dps: float = 0.12
var bloom_traverse_mrad_per_dps: float = 0.05
var bloom_pitch_mrad_per_dps: float = 0.6
## 안정장치가 이동·흔들림 오차에 곱하는 배율(작을수록 기동간 사격이 좋다)
var stabilizer_bloom_factor: float = 1.0

# ---------------------------------------------------------------- 승무원·모듈
## 승무원: [{"id", "home_role", "pos": Vector3, "radius", "in_turret": bool}]
## in_turret 이면 pos 는 포탑 좌표계(포탑 링 중심 기준)이다.
var crew: Array = []
## T-34/76 처럼 전차장이 포수를 겸하는가(상황인식 저하 반영)
var commander_is_gunner: bool = false
## 내부 모듈: [{"id", "kind", "pos", "radius", "in_turret"}]
## kind: engine, transmission, fuel, ammo, gun(포미), recoil, gun_mount, turret_ring, traverse_drive, sight
## 포신(gun_barrel)과 궤도(track_left/right)는 외부 모듈로 TankDamageState 가 자동 추가한다.
var modules: Array = []

var ammo_detonation_chance: float = 0.4
var fuel_fire_chance: float = 0.3
var engine_fire_chance: float = 0.1

## 이 전차가 학습에서 보여 줘야 할 특성(보고서용 요약)
var traits: Array = []
var notes: String = ""

var _shape: TankShape


## 형상(볼록 다면체 부품들). 처음 부를 때 한 번 만든다.
func shape() -> TankShape:
	if _shape == null:
		_shape = TankShape.new(self)
	return _shape


## 차체 지붕 높이(호환용 함수)
func hull_top_y() -> float:
	return hull_roof_y


## 포탑 좌표계 원점(포탑 링 중심, 차체 지붕 높이)
func turret_origin() -> Vector3:
	return Vector3(0.0, hull_roof_y, turret_offset_z)


## 전체 높이(실루엣)
func total_height() -> float:
	return hull_roof_y + turret_height


## 차체 지붕 위로 드러나는 높이(헐다운 시 노출되는 포탑 높이)
func turret_exposed_height() -> float:
	return turret_height


func plate(zone: String) -> Dictionary:
	return armor.get(zone, {"t": 10.0})


func max_forward_mps() -> float:
	return max_forward_kmh / 3.6


func max_reverse_mps() -> float:
	return max_reverse_kmh / 3.6


func power_to_weight() -> float:
	return engine_hp / maxf(mass_t, 0.001)


## 동력 전달 효율(엔진 → 궤도). 변속기·조향장치·궤도 손실 포함.
const DRIVE_EFFICIENCY := 0.6
## 접지 마찰 한계(견인력 상한 = μ × 중량)
const TRACTION_MU := 0.6
const G := 9.8


## 야지 구름저항 계수: 단단한 땅 0.045 + 접지압에 비례하는 침하 손실
func rolling_resistance() -> float:
	return 0.045 + 0.025 * ground_pressure_kgcm2


## 궤도에 전달되는 엔진 출력(W)
func drive_power_w() -> float:
	return engine_hp * 745.7 * DRIVE_EFFICIENCY


## 기어 i(1부터)의 견인력(N). 엔진 토크가 대략 일정하다고 보고 정격출력 / 그 기어 최고속도.
func gear_force_n(gear_index: int, reverse := false) -> float:
	var table := reverse_gears_kmh if reverse else forward_gears_kmh
	var v := float(table[clampi(gear_index, 1, table.size()) - 1]) / 3.6
	return minf(drive_power_w() / maxf(v, 0.1), TRACTION_MU * mass_t * 1000.0 * G)


## 기어 i 최고속도(m/s)
func gear_top_mps(gear_index: int, reverse := false) -> float:
	var table := reverse_gears_kmh if reverse else forward_gears_kmh
	return float(table[clampi(gear_index, 1, table.size()) - 1]) / 3.6


## 변속 시간(초): from → to
func shift_time(from_gear: int, to_gear: int) -> float:
	return float(shift_time_overrides.get("%d>%d" % [from_gear, to_gear], shift_time_s))


## 주행 저항(N): 구름저항 + 경사(sin_slope > 0 = 오르막)
func resistance_n(sin_slope: float) -> float:
	return mass_t * 1000.0 * G * (rolling_resistance() + sin_slope)


## 일정한 경사(°)에서 계속 낼 수 있는 최고속도(km/h): 저항을 이기는 가장 높은 기어의 최고속도
func sustained_speed_kmh(slope_deg: float) -> float:
	var r := resistance_n(sin(deg_to_rad(slope_deg)))
	var best := 0.0
	for i in forward_gears_kmh.size():
		if gear_force_n(i + 1) > r:
			best = float(forward_gears_kmh[i])
	return best


func to_dict() -> Dictionary:
	var crew_out := []
	for c in crew:
		crew_out.append({"id": c.id, "home_role": c.home_role, "pos": _v(c.pos),
			"radius": c.radius, "in_turret": c.in_turret})
	var mod_out := []
	for m in modules:
		mod_out.append({"id": m.id, "kind": m.kind, "pos": _v(m.pos),
			"radius": m.radius, "in_turret": m.in_turret})
	return {
		"id": id, "display_name": display_name, "nation": nation,
		"mass_t": mass_t, "engine_hp": engine_hp, "power_to_weight": snappedf(power_to_weight(), 0.1),
		"shape": {
			"hull_length": hull_length, "hull_width": hull_width, "hull_bottom_y": hull_bottom_y,
			"hull_top_y": hull_roof_y, "nose_y": nose_y,
			"front_upper_slope_deg": front_upper_slope_deg, "front_lower_slope_deg": front_lower_slope_deg,
			"rear_y": rear_y, "rear_upper_slope_deg": rear_upper_slope_deg, "rear_lower_slope_deg": rear_lower_slope_deg,
			"side_split_y": side_split_y, "side_upper_slope_deg": side_upper_slope_deg,
			"track_width": track_width, "track_height": track_height, "track_length": track_length,
			"track_armor_mm": track_armor_mm, "track_gauge_m": track_gauge_m,
			"turret_width": turret_width, "turret_length": turret_length, "turret_height": turret_height,
			"turret_offset_z": turret_offset_z, "turret_front_slope_deg": turret_front_slope_deg,
			"turret_side_slope_deg": turret_side_slope_deg, "turret_rear_slope_deg": turret_rear_slope_deg,
			"mantlet_size": _v(mantlet_size), "gun_height": gun_height, "barrel_length": barrel_length,
			"total_height": total_height(),
			"frontal_area_m2": snappedf(shape().projected_area(Vector3.BACK), 0.01),
			"side_area_m2": snappedf(shape().projected_area(Vector3.RIGHT), 0.01),
		},
		"armor": armor,
		"mobility": {
			"max_forward_kmh": max_forward_kmh, "max_reverse_kmh": max_reverse_kmh,
			"brake_mps2": brake_mps2,
			"direction_change_s": direction_change_s, "steer_efficiency": steer_efficiency,
			"neutral_steer": neutral_steer,
			"forward_gears_kmh": forward_gears_kmh, "reverse_gears_kmh": reverse_gears_kmh,
			"start_gear": start_gear, "shift_time_s": shift_time_s, "shift_time_overrides": shift_time_overrides,
			"engine_response_s": engine_response_s, "ground_pressure_kgcm2": ground_pressure_kgcm2,
			"acceleration_scale": acceleration_scale,
			"rolling_resistance": snappedf(rolling_resistance(), 0.0001),
			"obstacle_step_m": obstacle_step_m,
			"offroad_top_kmh": snappedf(sustained_speed_kmh(0.0), 0.1),
			"top_kmh_on_5deg": snappedf(sustained_speed_kmh(5.0), 0.1),
			"top_kmh_on_10deg": snappedf(sustained_speed_kmh(10.0), 0.1),
		},
		"suspension": {
			"freq_hz": suspension_freq_hz, "damping": suspension_damping,
			"pitch_deg_per_mps2": suspension_pitch_deg_per_mps2, "roll_deg_per_mps2": suspension_roll_deg_per_mps2,
		},
		"gunnery": {
			"turret_traverse_deg_s": turret_traverse_deg_s, "traverse_slope_penalty": traverse_slope_penalty,
			"gun_elevation_rate_deg_s": gun_elevation_rate_deg_s,
			"gun_depression_deg": gun_depression_deg, "gun_elevation_max_deg": gun_elevation_max_deg,
			"stabilizer_vertical": stabilizer_vertical, "stabilizer_efficiency": stabilizer_efficiency,
			"aim_time_s": aim_time_s, "bloom_move_mrad_per_mps": bloom_move_mrad_per_mps,
			"bloom_hull_turn_mrad_per_dps": bloom_hull_turn_mrad_per_dps,
			"bloom_traverse_mrad_per_dps": bloom_traverse_mrad_per_dps,
			"bloom_pitch_mrad_per_dps": bloom_pitch_mrad_per_dps,
			"stabilizer_bloom_factor": stabilizer_bloom_factor,
		},
		"gun": gun.to_dict() if gun else {},
		"ammo_types": ammo_types.map(func(a): return a.to_dict()),
		"ammo_capacity": ammo_capacity, "crew": crew_out,
		"commander_is_gunner": commander_is_gunner, "modules": mod_out,
		"ammo_detonation_chance": ammo_detonation_chance,
		"fuel_fire_chance": fuel_fire_chance,
		"engine_fire_chance": engine_fire_chance,
		"traits": traits, "notes": notes,
	}


static func _v(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
