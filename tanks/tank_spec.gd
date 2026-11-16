class_name TankSpec
extends RefCounted
## 전차 한 종류의 정적 제원(실제 자료를 단순화).
##
## 좌표계(전차 로컬, Godot 규약): -Z = 차체 정면, +X = 우측, +Y = 위.
## 원점은 차체 바닥 중앙의 지면 위치.
##
## 형상은 "차체 상자 + 포탑 상자" 두 개로 단순화한다. 장갑판의 실제 경사는
## 상자 면의 법선을 slope 만큼 위로 기울여 입사각 계산에만 반영한다.

## 장갑 구역 이름(관측·로그에 그대로 쓰임).
const ZONES := [
	"hull_front_upper", "hull_front_lower", "hull_side_upper", "hull_side_lower",
	"hull_rear", "hull_top", "hull_bottom",
	"turret_front", "turret_side", "turret_rear", "turret_top",
]

var id: String = ""
var display_name: String = ""
var nation: String = ""
var mass_t: float = 0.0
var engine_hp: float = 0.0
var max_speed_road_kmh: float = 0.0
var max_speed_offroad_kmh: float = 0.0
## 궤도 중심 간 거리(m). 피벗 선회 계산용.
var track_width_m: float = 2.5

## 차체 상자: x = 폭, y = 높이, z = 길이 (m)
var hull_size: Vector3 = Vector3.ONE
## 지상고: 차체 상자 바닥의 높이(m)
var hull_bottom_y: float = 0.45
## 포탑 상자: x = 폭, y = 높이, z = 길이 (m)
var turret_size: Vector3 = Vector3.ONE
## 포탑 회전축의 차체 길이방향 위치(음수 = 앞쪽)
var turret_offset_z: float = 0.0
## 정면에서 이 높이 아래 명중 = 하부 전면판
var front_lower_split_y: float = 1.0
## 측면에서 이 높이 아래 명중 = 하부 측면(궤도·보기륜 뒤)
var side_lower_split_y: float = 1.0

## 구역 -> {"t": 두께 mm, "slope": 수직으로부터 경사각 °(음수 = 아래로 기울어짐)}
var armor: Dictionary = {}

## 기본 탄(ammo_types[0])
var gun: GunSpec
## 이 전차가 쓸 수 있는 탄종 목록(포 공통값은 같고 탄만 다름)
var ammo_types: Array = []
var turret_traverse_deg_s: float = 15.0
var gun_elevation_rate_deg_s: float = 4.0
var gun_depression_deg: float = -8.0
var gun_elevation_max_deg: float = 15.0
var ammo_capacity: int = 80

## 승무원: [{"id", "home_role", "pos": Vector3, "radius", "in_turret": bool}]
## in_turret 이면 pos 는 포탑 좌표계(포탑 링 중심 기준)이다.
var crew: Array = []
## T-34/76 처럼 전차장이 포수를 겸하는가(상황인식 저하 반영)
var commander_is_gunner: bool = false
## 모듈: [{"id", "kind", "pos", "radius", "in_turret"}]
## kind: engine, transmission, fuel, ammo, gun, turret_ring
var modules: Array = []

## 탄약고 피격 시 유폭 확률, 연료탱크 피격 시 화재 확률, 엔진 피격 시 화재 확률
var ammo_detonation_chance: float = 0.4
var fuel_fire_chance: float = 0.3
var engine_fire_chance: float = 0.1

var notes: String = ""
var sources: Array = []


func hull_min() -> Vector3:
	return Vector3(-hull_size.x * 0.5, hull_bottom_y, -hull_size.z * 0.5)


func hull_max() -> Vector3:
	return Vector3(hull_size.x * 0.5, hull_bottom_y + hull_size.y, hull_size.z * 0.5)


func hull_top_y() -> float:
	return hull_bottom_y + hull_size.y


## 포탑 좌표계 원점(포탑 링 중심, 차체 상판 높이)
func turret_origin() -> Vector3:
	return Vector3(0.0, hull_top_y(), turret_offset_z)


func turret_min() -> Vector3:
	return Vector3(-turret_size.x * 0.5, 0.0, -turret_size.z * 0.5)


func turret_max() -> Vector3:
	return Vector3(turret_size.x * 0.5, turret_size.y, turret_size.z * 0.5)


## 전체 높이(실루엣). 은폐/피탐 계산에 쓸 수 있음.
func total_height() -> float:
	return hull_top_y() + turret_size.y


func plate(zone: String) -> Dictionary:
	return armor.get(zone, {"t": 10.0, "slope": 0.0})


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
		"mass_t": mass_t, "engine_hp": engine_hp,
		"max_speed_road_kmh": max_speed_road_kmh,
		"max_speed_offroad_kmh": max_speed_offroad_kmh,
		"track_width_m": track_width_m,
		"hull_size": _v(hull_size), "hull_bottom_y": hull_bottom_y,
		"turret_size": _v(turret_size), "turret_offset_z": turret_offset_z,
		"front_lower_split_y": front_lower_split_y,
		"side_lower_split_y": side_lower_split_y,
		"armor": armor, "gun": gun.to_dict() if gun else {},
		"ammo_types": ammo_types.map(func(a): return a.to_dict()),
		"turret_traverse_deg_s": turret_traverse_deg_s,
		"gun_elevation_rate_deg_s": gun_elevation_rate_deg_s,
		"gun_depression_deg": gun_depression_deg,
		"gun_elevation_max_deg": gun_elevation_max_deg,
		"ammo_capacity": ammo_capacity, "crew": crew_out,
		"commander_is_gunner": commander_is_gunner, "modules": mod_out,
		"ammo_detonation_chance": ammo_detonation_chance,
		"fuel_fire_chance": fuel_fire_chance,
		"engine_fire_chance": engine_fire_chance,
		"notes": notes, "sources": sources,
	}


static func _v(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
