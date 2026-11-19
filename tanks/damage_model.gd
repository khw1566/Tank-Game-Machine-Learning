class_name DamageModel
extends RefCounted
## 사격 1발의 결과를 판정하는 진입점.
##
## 사용법:
##   var result := DamageModel.resolve_shot(target_state, turret_yaw, local_origin, local_dir,
##                                          distance_m, shooter_gun, rng, gun_pitch)
##   - local_origin/local_dir: 표적 전차 로컬 좌표의 탄 궤적(Transform3D.affine_inverse() 로 변환)
##   - rng: RandomNumberGenerator (시드 고정 시 완전 재현 가능)
## 반환값은 JSON 으로 직렬화 가능한 Dictionary(보고서/로그용). target_state 는 그 자리에서 갱신된다.

## 관통 1회당 기본 탈출 확률 + 이번 탄으로 사상자 1명당 추가 확률
const BAIL_BASE := 0.05
const BAIL_PER_CASUALTY := 0.15
## 기동불능 상태에서 관통당하면 추가 탈출 확률
const BAIL_IMMOBILE := 0.15
## 비관통 하부측면/하부전면 명중 시 궤도 손상 확률
const TRACK_HIT_CHANCE := 0.35
## 궤도(외부 모듈)에 직접 맞았을 때 궤도 손상 확률(철갑 / 고폭)
const TRACK_DIRECT_CHANCE := 0.75
const TRACK_DIRECT_CHANCE_HE := 0.9
## 포신 명중 시 바로 파괴(사격 불가)될 확률. 아니면 손상(분산 2배).
const BARREL_DESTROY_CHANCE := 0.4
## 포방패 비관통 시 고저장치(gun_mount) / 주퇴기 손상 확률
const MANTLET_MOUNT_CHANCE := 0.12
const MANTLET_RECOIL_CHANCE := 0.05
## 파편(스폴) 원뿔 반경(m) = 기본 + 진행거리 × 원뿔계수 + 잔여관통 mm × 계수
## 파편은 신관 폭발과 무관하게 반대편 벽까지 날아간다.
const SPALL_BASE_R := 0.25
const SPALL_CONE := 0.25
const SPALL_PER_MM := 0.006
## 작약 폭발 반경(m) = 계수 × (작약 g / 60)^(1/3). 밀폐된 전투실이라 크게 잡음.
const BLAST_R_COEF := 1.1


static func resolve_shot(state: TankDamageState, turret_yaw: float, local_origin: Vector3,
		local_dir: Vector3, distance_m: float, gun: GunSpec, rng: RandomNumberGenerator,
		gun_pitch := 0.0) -> Dictionary:
	var spec := state.spec
	var result := {
		"ray_origin_local": TankSpec._v(local_origin), "ray_dir_local": TankSpec._v(local_dir.normalized()),
		"target_turret_yaw": turret_yaw, "target_gun_pitch": gun_pitch,
		"target": spec.id, "gun": gun.id, "shell": gun.shell_name, "shell_type": gun.shell_type, "distance_m": snappedf(distance_m, 0.1),
		"hit": false, "part": "", "zone": "", "plate_mm": 0.0, "slope_deg": 0.0,
		"impact_angle_deg": 0.0, "effective_mm": 0.0, "pen_mean_mm": 0.0,
		"pen_roll_mm": 0.0, "pen_probability": 0.0, "ricochet": false,
		"penetrated": false, "entry_local": [], "damage": [], "events": [],
		"status_before": state.status_label(), "status_after": "",
	}
	var dir := local_dir.normalized()
	var tr := HitGeometry.trace(spec, turret_yaw, local_origin, dir, gun_pitch)
	if not tr.hit:
		result.status_after = state.status_label()
		return result
	var pen_mean := gun.penetration_mm(distance_m)
	state.hits_taken += 1
	result.hit = true

	if state.is_destroyed():
		_fill_hit(result, spec, tr, gun, pen_mean, distance_m)
		result.events.append("hit_wreck")
		result.status_after = state.status_label()
		return result

	# 0-a) 궤도(외부 모듈): 궤도 손상 후 관통력이 깎인 채 차체로 계속 진행
	if tr.zone == "track":
		var side := "track_left" if tr.part == "track_left" else "track_right"
		result["track_hit"] = side
		result.events.append("track_hit")
		if rng.randf() < (TRACK_DIRECT_CHANCE_HE if gun.is_he() else TRACK_DIRECT_CHANCE):
			_damage_module(state, side, 0.5 if gun.is_he() else 0.35, rng, result, "track_hit")
		if gun.is_he():
			_fill_hit(result, spec, tr, gun, pen_mean, distance_m)
			_finish(state, result)
			return result
		pen_mean = maxf(pen_mean - spec.track_armor_mm, 0.0)
		result["track_absorbed_mm"] = spec.track_armor_mm
		# 차체 측면판은 궤도 바로 안쪽(같은 폭)에 있으므로 궤도 진입점 바로 앞에서 궤도를 빼고 다시 추적
		var o2: Vector3 = tr.entry - dir * 0.02
		var tr2 := HitGeometry.trace(spec, turret_yaw, o2, dir, gun_pitch, ["track_left", "track_right"])
		if not tr2.hit:
			_fill_hit(result, spec, tr, gun, pen_mean, distance_m)
			_finish(state, result)
			return result
		tr = tr2

	# 0-b) 포신: 장갑 판정 없이 포신 손상/파괴
	if tr.zone == "gun_barrel":
		_fill_hit(result, spec, tr, gun, pen_mean, distance_m)
		result.events.append("barrel_hit")
		_damage_module(state, "gun_barrel", BARREL_DESTROY_CHANCE, rng, result, "barrel_hit")
		_finish(state, result)
		return result

	_fill_hit(result, spec, tr, gun, pen_mean, distance_m)
	var zone: String = tr.zone
	var t: float = spec.plate(zone).t
	var angle: float = tr.impact_angle_deg
	var eff := Ballistics.effective_thickness_mm(gun, t, angle)
	var entry: Vector3 = tr.entry

	# 1) 도탄
	if rng.randf() < Ballistics.ricochet_chance(gun, t, angle):
		result.ricochet = true
		result.events.append("ricochet")
		_non_pen_effects(state, zone, entry, gun, t, rng, result)
		_finish(state, result)
		return result

	# 2) 관통력 판정(탄마다 편차)
	var pen_roll := pen_mean * (1.0 + rng.randfn(0.0, gun.penetration_sigma))
	result.pen_roll_mm = snappedf(pen_roll, 0.1)
	if pen_roll <= eff:
		result.events.append("non_penetration")
		_non_pen_effects(state, zone, entry, gun, t, rng, result)
		_finish(state, result)
		return result

	# 3) 관통: 내부 피해
	result.penetrated = true
	state.penetrations_taken += 1
	result.events.append("penetration")
	var residual := pen_roll - eff
	var casualties := _internal_damage(state, turret_yaw, entry, dir, residual, gun, rng, result)

	# 4) 승무원 탈출(사기) 판정
	if not state.is_destroyed():
		var p_bail := BAIL_BASE + BAIL_PER_CASUALTY * casualties
		if not state.can_move():
			p_bail += BAIL_IMMOBILE
		if rng.randf() < p_bail:
			state.bailed_out = true
			result.events.append("crew_bailed_out")
	_finish(state, result)
	return result


## 명중 부위 정보를 결과에 채움
static func _fill_hit(result: Dictionary, spec: TankSpec, tr: Dictionary, gun: GunSpec, pen_mean: float, distance_m: float) -> void:
	var t: float = spec.plate(tr.zone).t
	var angle: float = tr.impact_angle_deg
	result.part = tr.part
	result.zone = tr.zone
	result.plate_mm = t
	result.slope_deg = snappedf(tr.slope_deg, 0.1)
	result.impact_angle_deg = snappedf(angle, 0.1)
	result.effective_mm = snappedf(Ballistics.effective_thickness_mm(gun, t, angle), 0.1) if t > 0.0 else 0.0
	result.pen_mean_mm = snappedf(pen_mean, 0.1)
	if t > 0.0:
		var pen := Ballistics.penetration_probability(gun, distance_m, t, angle)
		if pen_mean < gun.penetration_mm(distance_m):
			# 궤도로 관통력이 깎였으면 그만큼 반영
			var eff := Ballistics.effective_thickness_mm(gun, t, angle)
			var sigma := maxf(pen_mean * gun.penetration_sigma, 0.001)
			pen = Ballistics.normal_cdf((pen_mean - eff) / sigma) * (1.0 - Ballistics.ricochet_chance(gun, t, angle))
		result.pen_probability = snappedf(pen, 0.001)
	result.entry_local = TankSpec._v(tr.entry)


static func _finish(state: TankDamageState, result: Dictionary) -> void:
	state.reassign_roles()
	state.update_knockout()
	result.status_after = state.status_label()
	if state.knockout_cause != "" and result.status_before != "destroyed" and result.status_before != "knocked_out":
		result.events.append("knocked_out:" + state.knockout_cause)


## 비관통 명중의 부가 효과: 궤도 손상, 포탑 정면 명중 시 포/선회링 충격.
## 고폭탄은 외부 폭발로 궤도·포·선회링 손상 확률이 높고, 얇은 장갑이면 내부 박리(스폴)로 승무원 부상 가능.
static func _non_pen_effects(state: TankDamageState, zone: String, entry: Vector3, gun: GunSpec,
		plate_mm: float, rng: RandomNumberGenerator, result: Dictionary) -> void:
	var he := gun.is_he()
	if zone == "hull_side_lower" or zone == "hull_front_lower":
		if rng.randf() < (0.6 if he else TRACK_HIT_CHANCE):
			var key := "track_left" if entry.x < 0.0 else "track_right"
			_damage_module(state, key, 0.6, rng, result, "track_hit")
	elif zone == "mantlet":
		# 포방패 충격: 고저장치 고착, 주퇴기 손상
		if rng.randf() < (MANTLET_MOUNT_CHANCE * 1.5 if he else MANTLET_MOUNT_CHANCE):
			_damage_module(state, "gun_mount", 0.0, rng, result, "mantlet_shock")
		elif rng.randf() < MANTLET_RECOIL_CHANCE:
			_damage_module(state, "recoil", 0.0, rng, result, "mantlet_shock")
	elif zone.begins_with("turret"):
		if rng.randf() < (0.10 if he else 0.05):
			_damage_module(state, "turret_ring", 0.0, rng, result, "turret_ring_jam")
		elif rng.randf() < (0.08 if he else 0.04):
			_damage_module(state, "traverse_drive", 0.0, rng, result, "traverse_shock")
		elif zone == "turret_front" and rng.randf() < (0.10 if he else 0.03):
			_damage_module(state, "sight", 0.0, rng, result, "sight_shock")
	if he:
		var p_spall := clampf(gun.filler_g / (maxf(plate_mm, 1.0) * 60.0), 0.0, 0.3)
		if rng.randf() < p_spall:
			var alive := state.crew.filter(func(c): return c.status != TankDamageState.CREW_KIA)
			if not alive.is_empty():
				var c: Dictionary = alive[rng.randi() % alive.size()]
				var before: String = c.status
				c.status = TankDamageState.CREW_KIA if before == TankDamageState.CREW_WOUNDED else TankDamageState.CREW_WOUNDED
				result.damage.append({"kind": "crew", "id": c.id, "before": before, "after": c.status,
					"cause": "he_spall", "chance": snappedf(p_spall, 0.01)})
				result.events.append("he_spall")


## 관통 후 내부 피해. 반환: 이번 탄으로 생긴 사상자 수.
static func _internal_damage(state: TankDamageState, turret_yaw: float, entry: Vector3, dir: Vector3,
		residual: float, gun: GunSpec, rng: RandomNumberGenerator, result: Dictionary) -> int:
	var spec := state.spec
	# 포탑·포방패 관통이면 포탑 바닥 아래(차체)까지 이어지는 경로를 허용
	var max_len := maxf(spec.shape().interior_length(turret_yaw, entry, dir), 0.3)
	var has_filler := gun.filler_g > 0.0
	var wall := entry + dir * max_len
	var burst := entry + dir * minf(gun.fuse_delay_m, max_len * 0.95)
	var spall := {"a": entry, "b": wall, "r0": SPALL_BASE_R + residual * SPALL_PER_MM}
	var blast_r := BLAST_R_COEF * pow(gun.filler_g / 60.0, 1.0 / 3.0) if has_filler else 0.0
	if has_filler:
		result.events.append("filler_detonation")

	var casualties := 0
	# 승무원
	for i in spec.crew.size():
		var cdef: Dictionary = spec.crew[i]
		var pos: Vector3 = cdef.pos
		if cdef.in_turret:
			pos = HitGeometry.turret_to_hull(spec, turret_yaw, pos)
		var p := _hit_chance(pos, cdef.radius, spall, burst, blast_r)
		if p > 0.0 and rng.randf() < p:
			var c: Dictionary = state.crew[i]
			var before: String = c.status
			if before == TankDamageState.CREW_KIA:
				continue
			if before == TankDamageState.CREW_WOUNDED or rng.randf() < 0.55:
				c.status = TankDamageState.CREW_KIA
			else:
				c.status = TankDamageState.CREW_WOUNDED
			casualties += 1
			result.damage.append({"kind": "crew", "id": c.id, "before": before, "after": c.status,
				"chance": snappedf(p, 0.01)})
	# 모듈
	for mdef in spec.modules:
		var pos: Vector3 = mdef.pos
		if mdef.in_turret:
			pos = HitGeometry.turret_to_hull(spec, turret_yaw, pos)
		var p := _hit_chance(pos, mdef.radius, spall, burst, blast_r)
		if p > 0.0 and rng.randf() < p:
			_damage_module(state, mdef.id, 0.5, rng, result, "internal", p)
			if state.ammo_detonated:
				break
	if state.ammo_detonated:
		for c in state.crew:
			c.status = TankDamageState.CREW_KIA
	return casualties


## 구(중심 pos, 반경 r)가 파편 원뿔(spall: a→b, 시작반경 r0, 진행할수록 넓어짐)
## 또는 작약 폭발(중심 burst, 반경 blast_r)에 맞을 확률
static func _hit_chance(pos: Vector3, r: float, spall: Dictionary, burst: Vector3, blast_r: float) -> float:
	var p := 0.0
	var a: Vector3 = spall.a
	var b: Vector3 = spall.b
	var closest := Geometry3D.get_closest_point_to_segment(pos, a, b)
	var d := pos.distance_to(closest)
	var reach: float = r + float(spall.r0) + SPALL_CONE * a.distance_to(closest)
	if d < reach:
		p = 0.20 + 0.75 * (1.0 - d / reach)
	if blast_r > 0.0:
		var db := pos.distance_to(burst)
		var reach_b := r + blast_r
		if db < reach_b:
			p = 1.0 - (1.0 - p) * (1.0 - 0.85 * (1.0 - db / reach_b))
	return clampf(p, 0.0, 0.98)


## 모듈 손상. destroy_chance: 바로 파괴될 확률(이미 손상이면 파괴).
static func _damage_module(state: TankDamageState, id: String, destroy_chance: float,
		rng: RandomNumberGenerator, result: Dictionary, cause: String, chance := 1.0) -> void:
	if not state.modules.has(id):
		return
	var before: String = state.modules[id]
	if before == TankDamageState.MOD_DESTROYED:
		return
	var after := TankDamageState.MOD_DAMAGED
	if before == TankDamageState.MOD_DAMAGED or rng.randf() < destroy_chance:
		after = TankDamageState.MOD_DESTROYED
	state.modules[id] = after
	result.damage.append({"kind": "module", "id": id, "before": before, "after": after,
		"cause": cause, "chance": snappedf(chance, 0.01)})
	# 2차 효과
	var kind := _module_kind(state.spec, id)
	if kind == "ammo" and rng.randf() < state.spec.ammo_detonation_chance:
		state.ammo_detonated = true
		result.events.append("ammo_detonation")
	elif kind == "fuel" and rng.randf() < state.spec.fuel_fire_chance:
		state.on_fire = true
		result.events.append("fuel_fire")
	elif kind == "engine" and rng.randf() < state.spec.engine_fire_chance:
		state.on_fire = true
		result.events.append("engine_fire")


static func _module_kind(spec: TankSpec, id: String) -> String:
	for m in spec.modules:
		if m.id == id:
			return m.kind
	return "track" if id.begins_with("track") else ""
