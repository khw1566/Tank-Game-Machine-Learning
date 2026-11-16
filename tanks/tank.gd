class_name Tank
extends CharacterBody3D
## 게임 속 전차 1대. 제원(TankSpec) + 피해상태(TankDamageState) + 공용 조작(TankControlInput).
##
## 매 물리 프레임 `control` 을 읽어 궤도 구동·포탑·포·발사를 처리한다.
## control 은 키보드(KeyboardController.read()) 또는 AI(TankControlInput.from_array()) 가 채운다.
## 외형은 상자/원통 프리미티브로 코드에서 생성(에셋 없음, 헤드리스에서도 동작).

signal shot_fired(shooter: Tank, result: Dictionary)
signal knocked_out(tank: Tank, cause: String)

const LAYER_GROUND := 1    # 지형·바위·나무줄기 (포탄 차단)
const LAYER_TANKS := 2
const LAYER_FOLIAGE := 4   # 나무 수관: 시야만 차단, 포탄은 통과
const MAX_SHOT_RANGE := 2500.0
const GRAVITY := 9.8
const SKID_STEER_EFFICIENCY := 0.35

## 헤드리스(학습)에서는 메시를 만들지 않는다: 더 빠르고, Godot 4.3 더미 렌더러 경고도 피함
static var visuals_enabled := DisplayServer.get_name() != "headless"

@export var tank_id := "sherman75"
@export var team := 0
@export var rng_seed := 0

var spec: TankSpec
var damage: TankDamageState
var control := TankControlInput.new()
## 포탑 회전(라디안, 차체 기준, + = 좌/반시계 — Godot 규약)
var turret_yaw := 0.0
## 포 고저각(라디안, + = 위)
var gun_pitch := 0.0
var reload_timer := 0.0
## 현재 장전 탄종(spec.ammo_types 인덱스)
var ammo_index := 0
var track_speed_left := 0.0
var track_speed_right := 0.0
var shots_fired := 0
var rng := RandomNumberGenerator.new()

var _turret_pivot: Node3D
var _gun_pivot: Node3D
var _turret_shape: CollisionShape3D
var _was_knocked_out := false
var _materials: Array = []


func _ready() -> void:
	if spec == null:
		setup(tank_id, team, rng_seed)


## 코드에서 생성할 때: Tank.new() → setup() → add_child()
func setup(p_tank_id: String, p_team: int, p_seed := 0) -> void:
	tank_id = p_tank_id
	team = p_team
	spec = TankDatabase.get_spec(tank_id)
	damage = TankDamageState.new(spec)
	rng.seed = p_seed if p_seed != 0 else hash(name) ^ Time.get_ticks_usec()
	collision_layer = LAYER_TANKS
	collision_mask = LAYER_GROUND | LAYER_TANKS
	floor_max_angle = deg_to_rad(35.0)
	_build_body()


func _build_body() -> void:
	var col := _nation_color()
	# 차체
	var hull_center := Vector3(0, spec.hull_bottom_y + spec.hull_size.y * 0.5, 0)
	var hull_shape := CollisionShape3D.new()
	var hb := BoxShape3D.new()
	hb.size = spec.hull_size
	hull_shape.shape = hb
	hull_shape.position = hull_center
	add_child(hull_shape)
	_add_box(self, spec.hull_size, hull_center, col)
	# 궤도(시각용)
	for sx in [-1.0, 1.0]:
		_add_box(self, Vector3(0.5, spec.hull_bottom_y + 0.6, spec.hull_size.z * 0.95),
			Vector3(sx * (spec.hull_size.x * 0.5 - 0.25), (spec.hull_bottom_y + 0.6) * 0.5, 0), col.darkened(0.6))
	# 포탑
	_turret_pivot = Node3D.new()
	_turret_pivot.name = "Turret"
	_turret_pivot.position = spec.turret_origin()
	add_child(_turret_pivot)
	var turret_center := Vector3(0, spec.turret_size.y * 0.5, 0)
	_add_box(_turret_pivot, spec.turret_size, turret_center, col.lightened(0.1))
	_turret_shape = CollisionShape3D.new()
	var tbox := BoxShape3D.new()
	tbox.size = spec.turret_size
	_turret_shape.shape = tbox
	add_child(_turret_shape)
	# 포(시각용)
	_gun_pivot = Node3D.new()
	_gun_pivot.name = "Gun"
	_gun_pivot.position = Vector3(0, spec.turret_size.y * 0.45, -spec.turret_size.z * 0.5)
	_turret_pivot.add_child(_gun_pivot)
	var barrel_len := spec.gun.caliber_mm * 0.001 * 50.0
	if visuals_enabled:
		_add_barrel(barrel_len, col)
	_sync_turret_shape()


func _add_barrel(barrel_len: float, col: Color) -> void:
	var barrel := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = spec.gun.caliber_mm * 0.001
	cm.bottom_radius = cm.top_radius * 1.3
	cm.height = barrel_len
	barrel.mesh = cm
	barrel.rotation.x = -PI * 0.5
	barrel.position = Vector3(0, 0, -barrel_len * 0.5)
	barrel.material_override = _mat(col.darkened(0.3))
	_gun_pivot.add_child(barrel)


func _add_box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> void:
	if not visuals_enabled:
		return
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = size
	mi.mesh = bm
	mi.position = pos
	mi.material_override = _mat(color)
	parent.add_child(mi)


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.set_meta("base", color)
	_materials.append(m)
	return m


func _nation_color() -> Color:
	match spec.nation:
		"Germany":
			return Color(0.45, 0.45, 0.42)
		"USA":
			return Color(0.33, 0.38, 0.2)
		"USSR":
			return Color(0.25, 0.35, 0.22)
	return Color.GRAY


func _sync_turret_shape() -> void:
	_turret_pivot.rotation.y = turret_yaw
	_gun_pivot.rotation.x = gun_pitch
	var b := HitGeometry.turret_basis(turret_yaw)
	_turret_shape.transform = Transform3D(b, spec.turret_origin() + b * Vector3(0, spec.turret_size.y * 0.5, 0))


func _physics_process(delta: float) -> void:
	step(delta)


## 한 물리 스텝. 학습 루프에서 직접 호출해도 된다.
func step(delta: float) -> void:
	var alive := damage.is_combat_effective()
	var c := control if alive else TankControlInput.new()
	if not alive:
		c.brake = 1.0
	_drive(c, delta)
	_aim(c, delta)
	reload_timer = maxf(reload_timer - delta, 0.0)
	if alive and c.fire and reload_timer <= 0.0 and damage.can_fire():
		fire()
	if not alive and not _was_knocked_out:
		_was_knocked_out = true
		_on_knocked_out()


func _drive(c: TankControlInput, delta: float) -> void:
	var max_v := spec.max_speed_offroad_kmh / 3.6
	var accel := 0.12 * spec.engine_hp / spec.mass_t      # m/s², 출력중량비에 비례
	var decel := 3.0 + 4.0 * c.brake                      # 엔진브레이크 + 브레이크
	var tl := c.left_track * max_v * damage.track_efficiency("left") * (1.0 - c.brake)
	var tr := c.right_track * max_v * damage.track_efficiency("right") * (1.0 - c.brake)
	track_speed_left = _approach(track_speed_left, tl, accel, decel, delta)
	track_speed_right = _approach(track_speed_right, tr, accel, decel, delta)
	var forward := (track_speed_left + track_speed_right) * 0.5
	# 궤도 미끄러짐(스키드 조향 손실)을 반영해 이론 선회율의 일부만 적용
	var yaw_rate := (track_speed_right - track_speed_left) / spec.track_width_m * SKID_STEER_EFFICIENCY
	rotate_y(yaw_rate * delta)
	var fwd := -global_transform.basis.z
	var vy := velocity.y - GRAVITY * delta
	if is_on_floor():
		vy = minf(vy, 0.0)
	velocity = fwd * forward + Vector3.UP * vy
	move_and_slide()


static func _approach(v: float, target: float, accel: float, decel: float, delta: float) -> float:
	# 같은 방향으로 더 빨라질 때만 가속, 그 외(감속·역방향)는 감속률
	var speeding_up := absf(target) > absf(v) and signf(target) == signf(v) or is_zero_approx(v)
	return move_toward(v, target, (accel if speeding_up else decel) * delta)


func _aim(c: TankControlInput, delta: float) -> void:
	turret_yaw = wrapf(turret_yaw - c.turret_traverse * deg_to_rad(damage.traverse_rate_deg_s()) * delta, -PI, PI)
	gun_pitch = clampf(gun_pitch + c.gun_elevation * deg_to_rad(damage.elevation_rate_deg_s()) * delta,
		deg_to_rad(spec.gun_depression_deg), deg_to_rad(spec.gun_elevation_max_deg))
	_sync_turret_shape()


## 현재 탄종
func current_shell() -> GunSpec:
	return spec.ammo_types[ammo_index] if ammo_index < spec.ammo_types.size() else spec.gun


## 탄종 변경. 장전된 탄을 바꾸므로 재장전 시간이 다시 걸린다.
func select_ammo(i: int) -> void:
	if i == ammo_index or i < 0 or i >= spec.ammo_types.size():
		return
	ammo_index = i
	if damage.can_fire():
		reload_timer = damage.reload_time_s()


## 포구 위치(월드)
func muzzle_position() -> Vector3:
	return _gun_pivot.global_position + gun_direction() * (spec.gun.caliber_mm * 0.001 * 50.0)


## 포가 향한 방향(월드, 정규화)
func gun_direction() -> Vector3:
	return (_gun_pivot.global_transform.basis * Vector3.FORWARD).normalized()


## 발사: 분산을 적용한 직사 광선. 지형/바위/나무줄기에 막히거나 전차에 명중.
func fire() -> Dictionary:
	reload_timer = damage.reload_time_s()
	damage.ammo_remaining -= 1
	shots_fired += 1
	var dir := gun_direction()
	var shell := current_shell()
	var spread := shell.dispersion_mrad * 0.001
	dir = dir.rotated(_gun_pivot.global_transform.basis.y, rng.randfn(0.0, spread))
	dir = dir.rotated(_gun_pivot.global_transform.basis.x, rng.randfn(0.0, spread)).normalized()
	var from := muzzle_position()
	var result := {"shooter": name, "shooter_tank": spec.id, "team": team, "shell": shell.shell_name,
		"from": TankSpec._v(from), "dir": TankSpec._v(dir), "hit": false, "target_name": ""}
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, from + dir * MAX_SHOT_RANGE, LAYER_GROUND | LAYER_TANKS, [get_rid()])
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		result["blocked_by"] = "none"
	elif hit.collider is Tank:
		var target: Tank = hit.collider
		var inv := target.global_transform.affine_inverse()
		var lo := inv * from
		var ld := (inv.basis * dir).normalized()
		var dist := from.distance_to(hit.position)
		var r := DamageModel.resolve_shot(target.damage, target.turret_yaw, lo, ld, dist, shell, rng)
		r.merge(result, false)
		r["target_name"] = target.name
		r["target_team"] = target.team
		r["hit_pos"] = TankSpec._v(hit.position)
		result = r
	else:
		result["blocked_by"] = (hit.collider as Node).name if hit.collider is Node else "?"
		result["hit_pos"] = TankSpec._v(hit.position)
	shot_fired.emit(self, result)
	return result


## 리플레이용: 물리 없이 기록된 자세를 그대로 적용(외형만 움직이는 꼭두각시)
func apply_replay_pose(xform: Transform3D, p_turret_yaw: float, p_gun_pitch: float, p_knocked_out: bool) -> void:
	set_physics_process(false)
	collision_layer = 0
	collision_mask = 0
	global_transform = xform
	turret_yaw = p_turret_yaw
	gun_pitch = p_gun_pitch
	_sync_turret_shape()
	if p_knocked_out != _was_knocked_out:
		_was_knocked_out = p_knocked_out
		for m in _materials:
			var sm := m as StandardMaterial3D
			var base: Color = sm.get_meta("base", sm.albedo_color)
			sm.albedo_color = base.darkened(0.6) if p_knocked_out else base


func _on_knocked_out() -> void:
	for m in _materials:
		(m as StandardMaterial3D).albedo_color = (m as StandardMaterial3D).albedo_color.darkened(0.6)
	knocked_out.emit(self, damage.knockout_cause)


## AI/로그용 자기 상태(월드 기준)
func state_dict() -> Dictionary:
	return {
		"name": name, "tank": spec.id, "team": team,
		"pos": TankSpec._v(global_position), "hull_yaw_deg": snappedf(rad_to_deg(rotation.y), 0.1),
		"turret_yaw_deg": snappedf(rad_to_deg(turret_yaw), 0.1),
		"gun_pitch_deg": snappedf(rad_to_deg(gun_pitch), 0.1),
		"track_speed": [snappedf(track_speed_left, 0.01), snappedf(track_speed_right, 0.01)],
		"reload_timer": snappedf(reload_timer, 0.01), "ammo": current_shell().shell_name,
		"control": control.to_dict(), "damage": damage.to_dict(),
	}
