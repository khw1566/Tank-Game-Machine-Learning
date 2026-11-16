class_name TankDamageState
extends RefCounted
## 전차 1대(개체)의 피해 상태: 승무원, 모듈, 궤도, 화재/유폭/탈출 여부.
## 조작·전투 코드는 여기서 can_fire(), reload_time_s() 같은 "성능 배율"을 읽어 쓴다.
## to_dict() 는 로그용, observation() 은 ML 관측 벡터용.

const CREW_OK := "ok"
const CREW_WOUNDED := "wounded"
const CREW_KIA := "kia"
const MOD_OK := "ok"
const MOD_DAMAGED := "damaged"
const MOD_DESTROYED := "destroyed"

## 빈 자리를 채울 때의 우선순위(앞쪽이 중요)
const ROLE_PRIORITY := ["gunner", "driver", "loader", "commander", "radio"]

## 자기 자리가 아닌 역할을 맡았을 때 / 부상 상태일 때 작업시간 배율
const OFF_ROLE_FACTOR := 1.3
const WOUNDED_FACTOR := 1.5

var spec: TankSpec
## [{"id", "home_role", "status"}]
var crew: Array = []
## 모듈 id -> 상태. 외부 모듈: 궤도 "track_left"/"track_right", 포신 "gun_barrel".
var modules: Dictionary = {}
## 역할 -> 담당 승무원 id ("" = 공석)
var roles: Dictionary = {}

var on_fire := false
var ammo_detonated := false
var bailed_out := false
var ammo_remaining := 0
var hits_taken := 0
var penetrations_taken := 0
## 무력화 원인 (빈 문자열 = 아직 전투 가능)
var knockout_cause := ""


func _init(p_spec: TankSpec) -> void:
	spec = p_spec
	for c in spec.crew:
		crew.append({"id": c.id, "home_role": c.home_role, "status": CREW_OK})
	for m in spec.modules:
		modules[m.id] = MOD_OK
	modules["track_left"] = MOD_OK
	modules["track_right"] = MOD_OK
	modules["gun_barrel"] = MOD_OK
	ammo_remaining = spec.ammo_capacity
	reassign_roles()


func crew_member(id: String) -> Dictionary:
	for c in crew:
		if c.id == id:
			return c
	return {}


func alive_crew_count() -> int:
	var n := 0
	for c in crew:
		if c.status != CREW_KIA:
			n += 1
	return n


## 생존 승무원으로 역할을 다시 배정(포수 > 조종수 > 장전수 > 전차장 > 무전수).
func reassign_roles() -> void:
	var order: Array = ROLE_PRIORITY.duplicate()
	if spec.commander_is_gunner:
		order.erase("commander")
	roles.clear()
	for r in order:
		roles[r] = ""
	for c in crew:
		if c.status != CREW_KIA and roles.has(c.home_role) and roles[c.home_role] == "":
			roles[c.home_role] = c.id
	for i in order.size():
		var r: String = order[i]
		if roles[r] != "":
			continue
		for j in range(order.size() - 1, i, -1):
			var r2: String = order[j]
			if roles[r2] != "":
				roles[r] = roles[r2]
				roles[r2] = ""
				break


func has_role(role: String) -> bool:
	if role == "commander" and spec.commander_is_gunner:
		return has_role("gunner")
	return roles.get(role, "") != ""


## 해당 역할의 작업시간 배율(1 = 정상, 클수록 느림, INF = 수행 불가)
func role_factor(role: String) -> float:
	if role == "commander" and spec.commander_is_gunner:
		role = "gunner"
	var cid: String = roles.get(role, "")
	if cid == "":
		return INF
	var c := crew_member(cid)
	var f := 1.0
	if c.home_role != role:
		f *= OFF_ROLE_FACTOR
	if c.status == CREW_WOUNDED:
		f *= WOUNDED_FACTOR
	return f


func module_state_by_kind(kind: String) -> String:
	## 같은 종류 모듈 중 가장 나쁜 상태
	if kind == "barrel":
		return modules.get("gun_barrel", MOD_OK)
	var worst := MOD_OK
	for m in spec.modules:
		if m.kind == kind:
			var st: String = modules[m.id]
			if st == MOD_DESTROYED:
				return MOD_DESTROYED
			if st == MOD_DAMAGED:
				worst = MOD_DAMAGED
	return worst


func is_destroyed() -> bool:
	return ammo_detonated or on_fire


func is_knocked_out() -> bool:
	return knockout_cause != ""


## 전투 가능(조작·AI 가 행동할 수 있는 상태)
func is_combat_effective() -> bool:
	return not is_knocked_out()


func can_move() -> bool:
	if is_knocked_out() or not has_role("driver"):
		return false
	if module_state_by_kind("engine") == MOD_DESTROYED:
		return false
	if module_state_by_kind("transmission") == MOD_DESTROYED:
		return false
	return modules.track_left != MOD_DESTROYED and modules.track_right != MOD_DESTROYED


## 궤도 하나당 출력 배율(0~1). 궤도가 끊기면 그쪽은 0 → 실제로는 제자리 맴돌기만 가능.
func track_efficiency(side: String) -> float:
	if is_knocked_out() or not has_role("driver"):
		return 0.0
	var key := "track_left" if side == "left" else "track_right"
	if modules[key] == MOD_DESTROYED:
		return 0.0
	var f := 1.0
	match module_state_by_kind("engine"):
		MOD_DESTROYED:
			return 0.0
		MOD_DAMAGED:
			f *= 0.5
	match module_state_by_kind("transmission"):
		MOD_DESTROYED:
			return 0.0
		MOD_DAMAGED:
			f *= 0.7
	if modules[key] == MOD_DAMAGED:
		f *= 0.7
	return f / role_factor("driver")


## 주포 계통(포미·주퇴기·포신) 중 하나라도 파괴되면 사격 불가
func gun_system_ok() -> bool:
	for k in ["gun", "recoil", "barrel"]:
		if module_state_by_kind(k) == MOD_DESTROYED:
			return false
	return true


func can_fire() -> bool:
	if is_knocked_out() or ammo_remaining <= 0:
		return false
	if not gun_system_ok():
		return false
	return has_role("gunner")


func can_traverse() -> bool:
	return not is_knocked_out() and has_role("gunner") \
		and module_state_by_kind("turret_ring") != MOD_DESTROYED


func reload_time_s() -> float:
	if not can_fire():
		return INF
	var t := spec.gun.reload_s
	if has_role("loader"):
		t *= role_factor("loader")
	else:
		t *= 2.5 * role_factor("gunner") # 포수가 직접 장전
	if module_state_by_kind("gun") == MOD_DAMAGED:
		t *= 1.3
	if module_state_by_kind("recoil") == MOD_DAMAGED:
		t *= 1.5 # 복좌가 느려 다음 발 준비가 늦음
	return t


func traverse_rate_deg_s() -> float:
	if not can_traverse():
		return 0.0
	var r := spec.turret_traverse_deg_s / role_factor("gunner")
	if module_state_by_kind("turret_ring") == MOD_DAMAGED:
		r *= 0.4
	match module_state_by_kind("traverse_drive"):
		MOD_DAMAGED:
			r *= 0.5
		MOD_DESTROYED:
			r *= 0.15 # 수동 선회 핸들
	return r


func elevation_rate_deg_s() -> float:
	if not has_role("gunner") or is_knocked_out():
		return 0.0
	match module_state_by_kind("gun_mount"):
		MOD_DESTROYED:
			return 0.0 # 고저장치 고착
		MOD_DAMAGED:
			return spec.gun_elevation_rate_deg_s * 0.4 / role_factor("gunner")
	return spec.gun_elevation_rate_deg_s / role_factor("gunner")


## 안정장치가 동작하는가(있고, 고저장치가 멀쩡할 때)
func stabilizer_working() -> bool:
	return spec.stabilizer_vertical and module_state_by_kind("gun_mount") == MOD_OK and has_role("gunner")


## 정지 분산 배율: 포신·주퇴기·조준경 손상, 포수 대리/부상
func dispersion_factor() -> float:
	var f := 1.0
	if module_state_by_kind("barrel") == MOD_DAMAGED:
		f *= 2.0
	if module_state_by_kind("recoil") == MOD_DAMAGED:
		f *= 1.3
	match module_state_by_kind("sight"):
		MOD_DAMAGED:
			f *= 1.6
		MOD_DESTROYED:
			f *= 3.0 # 예비 조준기
	var g := role_factor("gunner")
	return f * (g if not is_inf(g) else 1.0)


## 조준 수렴 시간 배율
func aim_time_factor() -> float:
	var f := 1.0
	match module_state_by_kind("sight"):
		MOD_DAMAGED:
			f *= 1.5
		MOD_DESTROYED:
			f *= 2.5
	var g := role_factor("gunner")
	return f * (g if not is_inf(g) else 1.0)


## 탐지(상황인식) 배율: 전담 전차장 1.0, 포수 겸임 0.75, 없음 0.5
func spotting_multiplier() -> float:
	if is_knocked_out():
		return 0.0
	if spec.commander_is_gunner:
		return 0.75 if has_role("gunner") else 0.5
	if not has_role("commander"):
		return 0.5
	return 1.0 / role_factor("commander")


## 상태가 바뀐 뒤 호출: 무력화 여부와 원인을 갱신
func update_knockout() -> void:
	if knockout_cause != "":
		return
	if ammo_detonated:
		knockout_cause = "ammo_detonation"
	elif on_fire:
		knockout_cause = "fire"
	elif bailed_out:
		knockout_cause = "crew_bailed_out"
	elif alive_crew_count() < 2:
		knockout_cause = "crew_casualties"
	else:
		# 쏠 수도, 움직일 수도 없으면 전투불능
		var fire_ok := has_role("gunner") and gun_system_ok() and ammo_remaining > 0
		var move_ok := has_role("driver") and module_state_by_kind("engine") != MOD_DESTROYED \
			and module_state_by_kind("transmission") != MOD_DESTROYED
		if not fire_ok and not move_ok:
			knockout_cause = "firepower_and_mobility_lost"


func status_label() -> String:
	if is_destroyed():
		return "destroyed"
	if is_knocked_out():
		return "knocked_out"
	var tags := []
	if not can_move():
		tags.append("immobilized")
	if not can_fire():
		tags.append("firepower_kill")
	return "operational" if tags.is_empty() else "+".join(tags)


func to_dict() -> Dictionary:
	return {
		"tank": spec.id, "status": status_label(), "knockout_cause": knockout_cause,
		"crew": crew.duplicate(true), "roles": roles.duplicate(), "modules": modules.duplicate(),
		"on_fire": on_fire, "ammo_detonated": ammo_detonated, "bailed_out": bailed_out,
		"ammo_remaining": ammo_remaining, "hits_taken": hits_taken,
		"penetrations_taken": penetrations_taken,
		"can_move": can_move(), "can_fire": can_fire(),
		"reload_time_s": reload_time_s() if can_fire() else -1.0,
		"traverse_rate_deg_s": traverse_rate_deg_s(),
		"track_eff_left": track_efficiency("left"), "track_eff_right": track_efficiency("right"),
		"spotting_multiplier": spotting_multiplier(),
		"stabilizer_working": stabilizer_working(),
		"dispersion_factor": snappedf(dispersion_factor(), 0.01),
	}


## ML 관측용 고정 길이 벡터(0~1 정규화). 순서는 OBSERVATION_LABELS 참고.
const OBSERVATION_LABELS := [
	"combat_effective", "can_move", "can_fire", "alive_crew_frac", "reload_speed",
	"traverse_speed", "track_eff_left", "track_eff_right", "spotting", "ammo_frac",
	"elevation_ok", "stabilizer_working", "sight_quality",
]


func observation() -> PackedFloat32Array:
	var reload := reload_time_s()
	return PackedFloat32Array([
		1.0 if is_combat_effective() else 0.0,
		1.0 if can_move() else 0.0,
		1.0 if can_fire() else 0.0,
		float(alive_crew_count()) / maxf(spec.crew.size(), 1),
		0.0 if is_inf(reload) else clampf(spec.gun.reload_s / reload, 0.0, 1.0),
		traverse_rate_deg_s() / maxf(spec.turret_traverse_deg_s, 0.001),
		track_efficiency("left"), track_efficiency("right"),
		spotting_multiplier(),
		float(ammo_remaining) / maxf(spec.ammo_capacity, 1),
		1.0 if elevation_rate_deg_s() > 0.0 else 0.0,
		1.0 if stabilizer_working() else 0.0,
		clampf(1.0 / dispersion_factor(), 0.0, 1.0),
	])
