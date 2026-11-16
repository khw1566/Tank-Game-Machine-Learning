class_name Tank
extends CharacterBody3D
## 게임 속 전차 1대. 제원(TankSpec) + 형상(TankShape) + 피해상태(TankDamageState) + 공용 조작(TankControlInput).
##
## 전차마다 다른 특성은 데이터로만 있지 않고 여기서 **물리·조작·사격에 강제**된다:
##   - 차체가 지형 경사를 따라 기운다 → 포 고저각은 차체 기준이라, 내림각(−5° / −8° / −10°)이 헐다운 가능 여부를 정한다
##   - 전진/후진 최고속도가 다르고, 전후진 전환은 멈춘 뒤 기어 변경 시간(direction_change_s)이 걸린다
##   - 오르막 속도 손실(출력중량비), 조향 효율, 제자리 선회 가능 여부
##   - 조준 오차(mrad)가 이동·선회·포탑 선회·차체 흔들림으로 커지고, 멈추면 aim_time_s 시상수로 줄어든다
##   - 수직 안정장치(셔먼): 차체가 출렁여도 포의 월드 고저각 유지 + 이동 흔들림 감소
##   - 포탄은 포구초속에 따른 포물선으로 날아간다(공기저항 무시) → 고속 88mm 는 원거리에서 유리
##
## 매 물리 프레임 `control` 을 읽는다. control 은 키보드(KeyboardController.read()) 또는 AI(TankControlInput.from_array()).

signal shot_fired(shooter: Tank, result: Dictionary)
signal knocked_out(tank: Tank, cause: String)

const LAYER_GROUND := 1    # 지형·바위·나무줄기 (포탄 차단)
const LAYER_TANKS := 2
const LAYER_FOLIAGE := 4   # 나무 수관: 시야만 차단, 포탄은 통과
const MAX_SHOT_RANGE := 2500.0
const GRAVITY := 9.8
## 포탄 궤적 적분 간격(초). 0.1s ≈ 60~80m 구간마다 지형/전차 교차 검사
const SHELL_STEP_S := 0.1
## 엔진 브레이크(스로틀을 놓았을 때 감속, m/s²)
const COAST_DECEL := 2.0
## 차체가 지형 경사를 따라가는 속도(1/s). 클수록 즉시 따라감
const SUSPENSION_RATE := 8.0
## 그룹 이름: 포탄이 맞을 수 있는 전차 목록
const GROUP := "tanks"

## 헤드리스(학습)에서는 메시를 만들지 않는다: 더 빠르고, Godot 4.3 더미 렌더러 경고도 피함
static var visuals_enabled := DisplayServer.get_name() != "headless"

@export var tank_id := "sherman75"
@export var team := 0
@export var rng_seed := 0

var spec: TankSpec
var shape: TankShape
var damage: TankDamageState
var control := TankControlInput.new()
## 포탑 회전(라디안, 차체 기준, + = 좌/반시계 — Godot 규약)
var turret_yaw := 0.0
## 포 고저각(라디안, 차체 기준, + = 위)
var gun_pitch := 0.0
var reload_timer := 0.0
## 현재 장전 탄종(spec.ammo_types 인덱스)
var ammo_index := 0
var track_speed_left := 0.0
var track_speed_right := 0.0
## 차체 방위(라디안). 지형 기울기와 별개로 관리한다.
var heading := 0.0
## 차체 선회율(라디안/초, + = 좌)
var yaw_rate := 0.0
## 변속 상태: 1 = 전진, -1 = 후진, 0 = 기어 변경 중
var gear := 1
var shift_timer := 0.0
var _pending_gear := 1
## 현재 조준 오차(분산 1σ, mrad). 발사 시 이 값으로 탄이 흩어진다.
var aim_error_mrad := 1.0
## 지면 법선(부드럽게 따라감)
var ground_normal := Vector3.UP
## 차체 흔들림 중 포 방향 피치 변화율(°/s, 조준 오차 계산용)
var gun_axis_pitch_rate_dps := 0.0
var shots_fired := 0
var rng := RandomNumberGenerator.new()

var _turret_pivot: Node3D
var _gun_pivot: Node3D
var _turret_shape: CollisionShape3D
var _was_knocked_out := false
var _materials: Array = []
var _initialized := false
var _muzzle_dist := 3.0


func _ready() -> void:
	if spec == null:
		setup(tank_id, team, rng_seed)


## 코드에서 생성할 때: Tank.new() → setup() → (position/rotation 지정) → add_child()
func setup(p_tank_id: String, p_team: int, p_seed := 0) -> void:
	tank_id = p_tank_id
	team = p_team
	spec = TankDatabase.get_spec(tank_id)
	shape = spec.shape()
	damage = TankDamageState.new(spec)
	rng.seed = p_seed if p_seed != 0 else hash(name) ^ Time.get_ticks_usec()
	collision_layer = LAYER_TANKS
	collision_mask = LAYER_GROUND | LAYER_TANKS
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	aim_error_mrad = spec.gun.dispersion_mrad
	add_to_group(GROUP)
	_build_body()


func _build_body() -> void:
	var col := _nation_color()
	# 충돌체: 차체 상자(지면에 닿지 않도록 0.6m 위부터) — 바위·나무·다른 전차와의 충돌용.
	# 높이는 지면 표본으로 직접 맞추므로 지형과는 충돌시키지 않는다.
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	var y0 := 0.6
	bs.size = Vector3(spec.hull_width, spec.hull_roof_y - y0, spec.hull_length * 0.95)
	cs.shape = bs
	cs.position = Vector3(0, (spec.hull_roof_y + y0) * 0.5, 0)
	add_child(cs)
	# 포탑 충돌체(시야 판정 등 물리 레이용). 포탄 명중은 TankShape 로 해석적으로 계산한다.
	_turret_shape = CollisionShape3D.new()
	var tcs := ConvexPolygonShape3D.new()
	tcs.points = shape.get_part("turret").verts
	_turret_shape.shape = tcs
	add_child(_turret_shape)

	_turret_pivot = Node3D.new()
	_turret_pivot.name = "Turret"
	_turret_pivot.position = spec.turret_origin()
	add_child(_turret_pivot)
	_gun_pivot = Node3D.new()
	_gun_pivot.name = "Gun"
	_gun_pivot.position = shape.trunnion
	_turret_pivot.add_child(_gun_pivot)
	var barrel: Dictionary = shape.get_part("gun_barrel")
	var zmin := 0.0
	for v in barrel.verts:
		zmin = minf(zmin, (v as Vector3).z)
	_muzzle_dist = -zmin

	if visuals_enabled:
		for part in shape.parts:
			var parent: Node3D = self
			var c := col
			match part.frame:
				"turret":
					parent = _turret_pivot
					c = col.lightened(0.08)
				"gun":
					parent = _gun_pivot
					c = col.darkened(0.3)
			if part.name.begins_with("track"):
				c = col.darkened(0.6)
			elif part.name == "mantlet":
				c = col.darkened(0.15)
			parent.add_child(_mesh_from_faces(part.faces, c))
	_sync_turret()


func _mesh_from_faces(faces: Array, color: Color) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for f in faces:
		var pts: PackedVector3Array = f.points
		var n: Vector3 = f.normal
		for i in range(1, pts.size() - 1):
			for p in [pts[0], pts[i + 1], pts[i]]:
				st.set_normal(n)
				st.add_vertex(p)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _mat(color)
	return mi


func _mat(color: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.set_meta("base", color)
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
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


func _sync_turret() -> void:
	_turret_pivot.rotation = Vector3(0, turret_yaw, 0)
	# 포 좌표계(포신)는 포이 기준 X 회전. 포방패는 포탑에 고정.
	_gun_pivot.rotation = Vector3(gun_pitch, 0, 0)
	_turret_shape.transform = Transform3D(Basis(Vector3.UP, turret_yaw), spec.turret_origin())


func _physics_process(delta: float) -> void:
	step(delta)


## 한 물리 스텝. 학습 루프에서 직접 호출해도 된다.
func step(delta: float) -> void:
	if not _initialized:
		_initialized = true
		heading = rotation.y
		_follow_ground(1.0, true)
	var alive := damage.is_combat_effective()
	var c := control if alive else TankControlInput.new()
	if not alive:
		c.brake = 1.0
	var pitch_before := _gun_axis_world_pitch()
	_drive(c, delta)
	_stabilize(pitch_before, delta)
	_aim(c, delta)
	_update_aim_error(c, delta)
	reload_timer = maxf(reload_timer - delta, 0.0)
	if alive and c.fire and reload_timer <= 0.0 and damage.can_fire():
		fire()
	if not alive and not _was_knocked_out:
		_was_knocked_out = true
		_on_knocked_out()


# ------------------------------------------------------------------ 기동
func _drive(c: TankControlInput, delta: float) -> void:
	var cmd := (c.left_track + c.right_track) * 0.5
	var want := gear if gear != 0 else _pending_gear
	if cmd > 0.05:
		want = 1
	elif cmd < -0.05:
		want = -1
	var shifting := false
	if gear != 0 and want != gear:
		# 반대 방향으로 가려면 먼저 멈춰야 한다
		shifting = true
		if absf(track_speed_left) < 0.3 and absf(track_speed_right) < 0.3:
			gear = 0
			_pending_gear = want
			shift_timer = spec.direction_change_s
	elif gear == 0:
		shifting = true
		_pending_gear = want
		shift_timer -= delta
		if shift_timer <= 0.0:
			gear = _pending_gear
			shift_timer = 0.0

	var fwd := -global_transform.basis.z
	var g := gear if gear != 0 else _pending_gear
	var vmax := spec.max_forward_mps() if g > 0 else spec.max_reverse_mps()
	var climb := maxf(fwd.y * float(g), 0.0) # 진행 방향 오르막 sin
	var slope_f := clampf(1.0 - spec.climb_penalty * climb, 0.15, 1.0)
	var brake := c.brake
	var tl := 0.0
	var tr := 0.0
	if not shifting:
		tl = _track_target(c.left_track, g, vmax * slope_f) * damage.track_efficiency("left") * (1.0 - brake)
		tr = _track_target(c.right_track, g, vmax * slope_f) * damage.track_efficiency("right") * (1.0 - brake)
	var accel := spec.accel_mps2 * slope_f
	var decel := COAST_DECEL + spec.brake_mps2 * (1.0 if shifting else brake)
	track_speed_left = _approach(track_speed_left, tl, accel, decel, delta)
	track_speed_right = _approach(track_speed_right, tr, accel, decel, delta)
	var forward := (track_speed_left + track_speed_right) * 0.5
	yaw_rate = (track_speed_right - track_speed_left) / spec.track_gauge_m * spec.steer_efficiency
	heading = wrapf(heading + yaw_rate * delta, -PI, PI)
	# 경사면을 따라 간 거리의 수평 성분만큼 이동(높이는 _follow_ground 가 지면에 맞춤)
	velocity = Vector3(-sin(heading), 0, -cos(heading)) * forward * sqrt(maxf(1.0 - fwd.y * fwd.y, 0.0))
	_slide(velocity * delta)
	_follow_ground(delta)


## 수평 이동 + 장애물(바위·나무·전차)에 미끄러짐. step(delta) 의 delta 를 그대로 쓰므로
## 학습 루프에서 프레임과 무관하게 직접 호출해도 같은 결과가 나온다.
func _slide(motion: Vector3) -> void:
	if not is_inside_tree() or motion.length_squared() < 1e-10:
		return
	for i in 2:
		var col := move_and_collide(motion)
		if col == null:
			return
		var n := col.get_normal()
		n.y = 0.0
		if n.length_squared() < 1e-6:
			return
		motion = col.get_remainder().slide(n.normalized())
		# 부딪힌 쪽 궤도 속도도 줄어든다
		var keep := clampf(motion.length() / maxf(col.get_remainder().length(), 1e-6), 0.0, 1.0)
		track_speed_left *= keep
		track_speed_right *= keep


## 궤도 하나의 목표 속도. 현재 기어와 반대 방향 명령은 제자리 선회 가능 전차만 (후진속도로) 허용.
func _track_target(cmd: float, g: int, vmax: float) -> float:
	if absf(cmd) < 1e-3:
		return 0.0
	if signf(cmd) == float(g):
		return cmd * vmax
	if spec.neutral_steer:
		return cmd * minf(spec.max_reverse_mps(), vmax)
	return 0.0 # 반대 궤도는 브레이크만 걸림(그쪽을 축으로 선회)


static func _approach(v: float, target: float, accel: float, decel: float, delta: float) -> float:
	# 같은 방향으로 더 빨라질 때만 가속, 그 외(감속·역방향)는 감속률
	var speeding_up := absf(target) > absf(v) and signf(target) == signf(v) or is_zero_approx(v)
	return move_toward(v, target, (accel if speeding_up else decel) * delta)


## 궤도 네 모서리 아래 지면을 표본 → 높이와 기울기(차체가 경사를 따라감)
func _follow_ground(delta: float, snap := false) -> void:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var yaw_b := Basis(Vector3.UP, heading)
	var hx := spec.hull_width * 0.5 - spec.track_width * 0.5
	var hz := spec.track_length * 0.45
	var pts := []
	var ok := space != null
	if ok:
		for off in [Vector3(-hx, 0, -hz), Vector3(hx, 0, -hz), Vector3(-hx, 0, hz), Vector3(hx, 0, hz)]:
			var p: Vector3 = global_position + yaw_b * off
			var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * 6.0, p + Vector3.DOWN * 12.0, LAYER_GROUND, [get_rid()])
			var hit := space.intersect_ray(q)
			if hit.is_empty():
				ok = false
				break
			pts.append(hit.position)
	var n := Vector3.UP
	if ok:
		var front: Vector3 = (pts[0] + pts[1]) * 0.5
		var rear: Vector3 = (pts[2] + pts[3]) * 0.5
		var left: Vector3 = (pts[0] + pts[2]) * 0.5
		var right: Vector3 = (pts[1] + pts[3]) * 0.5
		n = (right - left).cross(front - rear).normalized()
		if n.y < 0.0:
			n = -n
		var h: float = (pts[0].y + pts[1].y + pts[2].y + pts[3].y) * 0.25
		global_position.y = h
	elif is_inside_tree():
		global_position.y -= 5.0 * delta # 지면 밖: 천천히 낙하
	ground_normal = n if snap else ground_normal.slerp(n, clampf(delta * SUSPENSION_RATE, 0.0, 1.0)).normalized()
	var flat_fwd := yaw_b * Vector3.FORWARD
	var up := ground_normal
	var f := (flat_fwd - up * flat_fwd.dot(up)).normalized()
	var r := f.cross(up).normalized()
	global_transform.basis = Basis(r, up, -f)


# ------------------------------------------------------------------ 포탑·포
## 포 축(포탑 정면 방향)의 월드 피치. 차체 흔들림 측정용(포 고저와 무관).
func _gun_axis_world_pitch() -> float:
	var d := global_transform.basis * (Basis(Vector3.UP, turret_yaw) * Vector3.FORWARD)
	return asin(clampf(d.y, -1.0, 1.0))


## 차체 피치 변화가 포 방향을 흔든 양을 측정하고, 안정장치가 있으면 그만큼 포를 반대로 보정.
func _stabilize(pitch_before: float, delta: float) -> void:
	var dp := _gun_axis_world_pitch() - pitch_before
	gun_axis_pitch_rate_dps = absf(rad_to_deg(dp)) / maxf(delta, 1e-4)
	if damage.stabilizer_working():
		gun_pitch -= dp * spec.stabilizer_efficiency
		gun_pitch = clampf(gun_pitch, deg_to_rad(spec.gun_depression_deg), deg_to_rad(spec.gun_elevation_max_deg))


func _aim(c: TankControlInput, delta: float) -> void:
	turret_yaw = wrapf(turret_yaw - c.turret_traverse * deg_to_rad(damage.traverse_rate_deg_s()) * delta, -PI, PI)
	gun_pitch = clampf(gun_pitch + c.gun_elevation * deg_to_rad(damage.elevation_rate_deg_s()) * delta,
		deg_to_rad(spec.gun_depression_deg), deg_to_rad(spec.gun_elevation_max_deg))
	_sync_turret()


## 조준 오차 갱신: 움직이면 즉시 커지고, 멈추면 정지 분산까지 지수적으로 줄어든다.
func _update_aim_error(c: TankControlInput, delta: float) -> void:
	var base := current_shell().dispersion_mrad * damage.dispersion_factor()
	var sf := spec.stabilizer_bloom_factor if damage.stabilizer_working() else 1.0
	var speed := absf(track_speed_left + track_speed_right) * 0.5
	var trav := absf(c.turret_traverse) * damage.traverse_rate_deg_s()
	var target := base \
		+ sf * (spec.bloom_move_mrad_per_mps * speed + spec.bloom_pitch_mrad_per_dps * gun_axis_pitch_rate_dps) \
		+ spec.bloom_hull_turn_mrad_per_dps * absf(rad_to_deg(yaw_rate)) \
		+ spec.bloom_traverse_mrad_per_dps * trav
	if target >= aim_error_mrad:
		aim_error_mrad = target
	else:
		var tau := spec.aim_time_s * damage.aim_time_factor()
		aim_error_mrad = target + (aim_error_mrad - target) * exp(-delta / maxf(tau, 0.05))


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
	return _gun_pivot.global_position + gun_direction() * _muzzle_dist


## 포가 향한 방향(월드, 정규화)
func gun_direction() -> Vector3:
	return (_gun_pivot.global_transform.basis * Vector3.FORWARD).normalized()


## 월드 지점을 맞히려면 필요한 (turret_yaw, gun_pitch) — 차체 기준, 탄도 낙차 보정 포함.
## 스크립트 AI·테스트용. reachable = 포 고저 한계 안에서 겨눌 수 있는가(헐다운·내림각 판정).
func aim_solution(target_world: Vector3) -> Dictionary:
	var shell := current_shell()
	var from := _gun_pivot.global_position
	var to_t := target_world - from
	var rng_m := Vector2(to_t.x, to_t.z).length()
	var world_dir := (to_t.normalized())
	# 낙차 보정: 월드 기준으로 위로 superelevation 만큼 올림
	var se := Ballistics.superelevation_rad(shell, rng_m)
	var horiz := Vector3(world_dir.x, 0, world_dir.z).normalized()
	var los_pitch := asin(clampf(world_dir.y, -1.0, 1.0))
	var p := los_pitch + se
	var aim_dir := horiz * cos(p) + Vector3.UP * sin(p)
	var ld := global_transform.basis.inverse() * aim_dir
	var want_yaw := atan2(-ld.x, -ld.z)
	var want_pitch := atan2(ld.y, Vector2(ld.x, ld.z).length())
	return {"turret_yaw": want_yaw, "gun_pitch": want_pitch, "range_m": rng_m,
		"superelevation_deg": rad_to_deg(se),
		"reachable": want_pitch >= deg_to_rad(spec.gun_depression_deg) - 1e-4 \
			and want_pitch <= deg_to_rad(spec.gun_elevation_max_deg) + 1e-4}


## 발사: 조준 오차만큼 흩어진 방향으로 포물선 탄도를 따라가며 지형/바위/전차와 교차 검사.
func fire() -> Dictionary:
	reload_timer = damage.reload_time_s()
	damage.ammo_remaining -= 1
	shots_fired += 1
	var shell := current_shell()
	var dir := gun_direction()
	var spread := aim_error_mrad * 0.001
	var gb := _gun_pivot.global_transform.basis
	dir = dir.rotated(gb.y.normalized(), rng.randfn(0.0, spread))
	dir = dir.rotated(gb.x.normalized(), rng.randfn(0.0, spread)).normalized()
	var from := muzzle_position()
	var result := {"shooter": name, "shooter_tank": spec.id, "team": team, "shell": shell.shell_name,
		"from": TankSpec._v(from), "dir": TankSpec._v(dir), "hit": false, "target_name": "",
		"aim_error_mrad": snappedf(aim_error_mrad, 0.01),
		"shooter_speed_mps": snappedf((track_speed_left + track_speed_right) * 0.5, 0.01)}
	var hit := _trace_shell(from, dir * shell.muzzle_velocity_ms)
	if hit.is_empty():
		result["blocked_by"] = "none"
	elif hit.has("tank"):
		var target: Tank = hit.tank
		var r := DamageModel.resolve_shot(target.damage, target.turret_yaw, hit.local_origin, hit.local_dir,
			hit.distance, shell, rng, target.gun_pitch)
		r.merge(result, false)
		r["target_name"] = target.name
		r["target_team"] = target.team
		r["flight_time_s"] = snappedf(hit.time, 0.01)
		r["hit_pos"] = TankSpec._v(hit.world_pos)
		result = r
	else:
		result["blocked_by"] = hit.blocked_by
		result["hit_pos"] = TankSpec._v(hit.position)
	# 조준 오차는 발사 반동으로 다시 커진다(연속 사격 시 재조준 필요)
	aim_error_mrad = maxf(aim_error_mrad, shell.dispersion_mrad * damage.dispersion_factor() * 2.0)
	shot_fired.emit(self, result)
	return result


## 포물선 탄도 적분. 반환: {} (최대 사거리까지 아무것도 안 맞음),
## {"blocked_by", "position"} (지형/장애물), {"tank", "local_origin", "local_dir", "distance", "time"} (전차)
func _trace_shell(from: Vector3, vel: Vector3) -> Dictionary:
	var space := get_world_3d().direct_space_state
	var tanks := get_tree().get_nodes_in_group(GROUP) if is_inside_tree() else []
	var p := from
	var v := vel
	var traveled := 0.0
	var time := 0.0
	while traveled < MAX_SHOT_RANGE:
		var p1 := p + v * SHELL_STEP_S + Vector3.DOWN * (0.5 * GRAVITY * SHELL_STEP_S * SHELL_STEP_S)
		var v1 := v + Vector3.DOWN * GRAVITY * SHELL_STEP_S
		var seg := p1 - p
		var seg_len := seg.length()
		var d := seg / seg_len
		var best_t := seg_len
		var best := {}
		var q := PhysicsRayQueryParameters3D.create(p, p1, LAYER_GROUND, [get_rid()])
		var gh := space.intersect_ray(q)
		if not gh.is_empty():
			best_t = p.distance_to(gh.position)
			var col = gh.collider
			best = {"blocked_by": (col as Node).name if col is Node else "?", "position": gh.position}
		for t in tanks:
			var tk := t as Tank
			if tk == null or tk == self:
				continue
			var c := tk.global_position + Vector3.UP * 1.2
			var closest := Geometry3D.get_closest_point_to_segment(c, p, p1)
			if closest.distance_to(c) > 8.0:
				continue
			var inv := tk.global_transform.affine_inverse()
			var lo := inv * p
			var ld := (inv.basis * d).normalized()
			var tr := HitGeometry.trace(tk.spec, tk.turret_yaw, lo, ld, tk.gun_pitch)
			if tr.hit and float(tr.t) <= best_t:
				best_t = tr.t
				best = {"tank": tk, "local_origin": lo, "local_dir": ld, "world_pos": p + d * float(tr.t)}
		if not best.is_empty():
			if best.has("tank"):
				best["distance"] = traveled + best_t
				best["time"] = time + SHELL_STEP_S * best_t / seg_len
			return best
		traveled += seg_len
		time += SHELL_STEP_S
		p = p1
		v = v1
		if p.y < -200.0:
			break
	return {}


## 리플레이용: 물리 없이 기록된 자세를 그대로 적용(외형만 움직이는 꼭두각시)
func apply_replay_pose(xform: Transform3D, p_turret_yaw: float, p_gun_pitch: float, p_knocked_out: bool) -> void:
	set_physics_process(false)
	_initialized = true
	collision_layer = 0
	collision_mask = 0
	global_transform = xform
	turret_yaw = p_turret_yaw
	gun_pitch = p_gun_pitch
	_sync_turret()
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


## 차체 피치(°, + = 앞이 들림) / 롤(°, + = 오른쪽이 들림)
func hull_pitch_deg() -> float:
	return rad_to_deg(asin(clampf((-global_transform.basis.z).y, -1.0, 1.0)))


func hull_roll_deg() -> float:
	return rad_to_deg(asin(clampf(global_transform.basis.x.y, -1.0, 1.0)))


## 차체 기준 진행 속도(m/s, + = 전진)
func forward_speed() -> float:
	return (track_speed_left + track_speed_right) * 0.5


## ML 관측용 자기 기동·사격 상태(고정 길이). 라벨: OBSERVATION_LABELS
const OBSERVATION_LABELS := [
	"speed_norm", "gear", "shifting", "yaw_rate_norm", "hull_pitch_norm", "hull_roll_norm",
	"turret_yaw_sin", "turret_yaw_cos", "gun_pitch_norm", "depression_margin_norm",
	"aim_error_norm", "reload_frac",
]


func observation() -> PackedFloat32Array:
	var dep := deg_to_rad(spec.gun_depression_deg)
	var ele := deg_to_rad(spec.gun_elevation_max_deg)
	var reload_total := damage.reload_time_s()
	return PackedFloat32Array([
		forward_speed() / spec.max_forward_mps(),
		float(gear),
		1.0 if gear == 0 or shift_timer > 0.0 else 0.0,
		clampf(yaw_rate / 1.0, -1.0, 1.0),
		clampf(hull_pitch_deg() / 30.0, -1.0, 1.0),
		clampf(hull_roll_deg() / 30.0, -1.0, 1.0),
		sin(turret_yaw), cos(turret_yaw),
		(gun_pitch - dep) / maxf(ele - dep, 1e-3) * 2.0 - 1.0,
		clampf((gun_pitch - dep) / deg_to_rad(10.0), 0.0, 1.0),
		clampf(aim_error_mrad / 10.0, 0.0, 1.0),
		0.0 if is_inf(reload_total) else clampf(reload_timer / reload_total, 0.0, 1.0),
	])


## AI/로그용 자기 상태(월드 기준)
func state_dict() -> Dictionary:
	return {
		"name": name, "tank": spec.id, "team": team,
		"pos": TankSpec._v(global_position), "hull_yaw_deg": snappedf(rad_to_deg(heading), 0.1),
		"hull_pitch_deg": snappedf(hull_pitch_deg(), 0.1), "hull_roll_deg": snappedf(hull_roll_deg(), 0.1),
		"turret_yaw_deg": snappedf(rad_to_deg(turret_yaw), 0.1),
		"gun_pitch_deg": snappedf(rad_to_deg(gun_pitch), 0.1),
		"track_speed": [snappedf(track_speed_left, 0.01), snappedf(track_speed_right, 0.01)],
		"gear": gear, "shift_timer": snappedf(shift_timer, 0.01),
		"aim_error_mrad": snappedf(aim_error_mrad, 0.01),
		"reload_timer": snappedf(reload_timer, 0.01), "ammo": current_shell().shell_name,
		"control": control.to_dict(), "damage": damage.to_dict(),
	}
