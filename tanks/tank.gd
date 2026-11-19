class_name Tank
extends CharacterBody3D
## 게임 속 전차 1대. 제원(TankSpec) + 형상(TankShape) + 피해상태(TankDamageState) + 공용 조작(TankControlInput).
##
## 전차마다 다른 특성은 데이터로만 있지 않고 여기서 **물리·조작·사격에 강제**된다:
##   - 차체가 지형 굴곡·낮은 장애물(돌·통나무)을 따라 피치/롤로 기울고, 현가장치(스프링-감쇠)로 출렁인다.
##     가감속하면 앞뒤로, 선회하면 옆으로 쏠린다(전차마다 고유진동수·감쇠가 다름: T-34 크리스티는 오래 출렁임)
##     → 포 고저각·포탑 선회는 차체 기준이라, 차체가 기울면 같은 표적에도 포 각도를 다시 맞춰야 한다.
##       내림각(−5° / −8° / −10°)이 헐다운 가능 여부를 정하고, 기운 차체에서 포탑을 오르막 쪽으로 돌리면 느려진다
##   - 변속기: 실제 기어별 속도표 + 엔진 출력 → 견인력. 구름저항(접지압)·경사를 이겨야 다음 단으로 올라가고,
##     변속 중에는 동력이 끊기지만 엔진 회전은 유지한다. 전후진 전환은 멈춘 뒤 direction_change_s 가 걸린다
##   - 넘을 수 있는 수직 장애물 높이, 조향 효율, 제자리 선회 가능 여부
##   - 조준 오차(mrad)가 이동·선회·포탑 선회·차체 흔들림으로 커지고, 멈추면 aim_time_s 시상수로 줄어든다
##   - 수직 안정장치(셔먼): 차체가 출렁여도 포의 월드 고저각 유지 + 이동 흔들림 감소
##   - 포탄은 포구초속에 따른 포물선으로 날아간다(공기저항 무시) → 고속 88mm 는 원거리에서 유리
##
## 매 물리 프레임 `control` 을 읽는다. control 은 키보드(KeyboardController.read()) 또는 AI(TankControlInput.from_array()).

signal shot_fired(shooter: Tank, result: Dictionary)
signal shot_launched(shooter: Tank, result: Dictionary)
signal knocked_out(tank: Tank, cause: String)

const LAYER_GROUND := 1    # 지형·바위·나무줄기 (포탄 차단)
const LAYER_TANKS := 2
const LAYER_FOLIAGE := 4   # 나무 수관: 시야만 차단, 포탄은 통과
const MAX_SHOT_RANGE := 2500.0
const GRAVITY := 9.8
## 포탄 궤적 적분 간격(초). 0.1s ≈ 60~80m 구간마다 지형/전차 교차 검사
const SHELL_STEP_S := 0.1
## 엔진 브레이크(스로틀을 놓았을 때 감속, m/s²)
const COAST_DECEL := 1.0
## 궤도·보기륜 회전 관성까지 포함한 유효 질량 배율
const MASS_FACTOR := 1.2
## 현가 적분 최대 간격(초). 학습 루프가 큰 delta 로 호출해도 안정하게 나눠 적분
const SUSPENSION_SUBSTEP := 1.0 / 60.0
## 궤도 반쪽(앞/뒤)마다 지면을 재는 위치(궤도 끝 = 1.0). 0.7m 간격이라 통나무 하나도 놓치지 않는다
const SUPPORT_SAMPLES := [1.0, 0.75, 0.5, 0.25]
## 차체 기울기 한계(°): 이 이상은 전복 대신 잘라 둔다
const MAX_TILT_DEG := 40.0
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
## 진행 방향: 1 = 전진, -1 = 후진, 0 = 전후진 전환 중
var gear := 1
## 전후진 전환 / 변속 남은 시간(초)
var shift_timer := 0.0
var _pending_gear := 1
## 현재 단(1부터, 진행 방향의 기어표 기준)
var gear_index := 1
## 단 변경 중이면 목표 단(0 = 변속 안 함)
var _shift_to := 0
## 엔진 출력 준비 비율(0~1). 변속 중에도 유지하며 궤도로의 전달은 클러치가 차단한다.
var engine_output := 0.0
## 엔진 회전 비율(0~1, 현재 단 최고속도 대비 속도) — HUD·관측용
var engine_rpm_frac := 0.0
## 현가 상태: 차체 피치/롤(라디안, 피치 + = 앞이 들림, 롤 + = 오른쪽이 들림)과 각속도
var hull_pitch := 0.0
var hull_roll := 0.0
var _pitch_rate := 0.0
var _roll_rate := 0.0
## 지면이 요구하는 피치/롤(현가 목표, 관측용)
var ground_pitch := 0.0
var ground_roll := 0.0
## 길이방향 가속도(m/s², 저역통과)
var long_accel := 0.0
## 마지막 지면 표본: Vector2i(좌-1/우+1, 앞-1/뒤+1) → 지지 높이
var _support := {}
var _prev_forward := 0.0
## 현재 조준 오차(분산 1σ, mrad). 발사 시 이 값으로 탄이 흩어진다.
var aim_error_mrad := 1.0
## 지면 법선(부드럽게 따라감)
var ground_normal := Vector3.UP
## 차체 흔들림 중 포 방향 피치 변화율(°/s, 조준 오차 계산용)
var gun_axis_pitch_rate_dps := 0.0
var shots_fired := 0
var projectile_field: RefCounted = null
var rng := RandomNumberGenerator.new()

var _turret_pivot: Node3D
var _gun_pivot: Node3D
var _turret_shape: CollisionShape3D
var _was_knocked_out := false
var _materials: Array = []
var _initialized := false
var _muzzle_dist := 3.0
## 평탄 지형 맵(학습 환경이 넣어 줌). 있으면 주변에 장애물이 없을 때 지면 레이캐스트를 건너뛴다
var ground_map: HillMap = null
var _ground_clear := false


func _ready() -> void:
	if spec == null:
		setup(tank_id, team, rng_seed)


## 코드에서 생성할 때: Tank.new() → setup() → (position/rotation 지정) → add_child()
func setup(p_tank_id: String, p_team: int, p_seed := 0, p_pace := {}) -> void:
	tank_id = p_tank_id
	team = p_team
	spec = TankDatabase.get_spec(tank_id)
	if not p_pace.is_empty():
		spec.apply_pace(float(p_pace.get("mobility", 1.0)), float(p_pace.get("turret", 1.0)))
	shape = spec.shape()
	damage = TankDamageState.new(spec)
	rng.seed = p_seed if p_seed != 0 else hash(name) ^ Time.get_ticks_usec()
	collision_layer = LAYER_TANKS
	collision_mask = LAYER_GROUND | LAYER_TANKS
	motion_mode = CharacterBody3D.MOTION_MODE_FLOATING
	aim_error_mrad = spec.gun.dispersion_mrad
	gear_index = spec.start_gear
	add_to_group(GROUP)
	_build_body()


func _build_body() -> void:
	var col := _nation_color()
	# 충돌체: 차체 상자(지면에 닿지 않도록 0.6m 위부터) — 바위·나무·다른 전차와의 충돌용.
	# 높이는 지면 표본으로 직접 맞추므로 지형과는 충돌시키지 않는다.
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	# 충돌 상자 바닥 = 넘을 수 있는 장애물 높이: 이보다 낮은 돌·통나무는 상자에 걸리지 않고
	# 지면 표본(_follow_ground)에 잡혀 차체를 들어 올린다.
	var y0 := spec.obstacle_step_m + 0.1
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
		var tracks := TankTrackVisual.new()
		add_child(tracks)
		tracks.setup(self)
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


func hit_attachment(part_name: String) -> Node3D:
	var part := shape.get_part(part_name)
	match part.get("frame", "hull"):
		"gun": return _gun_pivot
		"turret": return _turret_pivot
	return self


## 학습 성능 계측(µs 누적, 모든 전차 합). training_env 가 에피소드마다 읽고 0 으로 돌린다
static var perf_step_us := 0
static var perf_ground_us := 0


func _physics_process(delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	step(delta)
	perf_step_us += Time.get_ticks_usec() - t0


## 한 물리 스텝. 학습 루프에서 직접 호출해도 된다.
func step(delta: float) -> void:
	_ground_clear = _check_ground_clear()
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
## 기동 한 스텝: 전후진 선택 → 자동 변속 → 견인력(엔진 출력 / 기어 최고속도) − 저항(구름·경사) → 궤도 속도.
## 궤도 명령은 "그 방향 최고속도 대비 목표 속도 비율"이다(키보드 1.0 = 낼 수 있는 만큼).
func _drive(c: TankControlInput, delta: float) -> void:
	var cmd := (c.left_track + c.right_track) * 0.5
	var want := gear if gear != 0 else _pending_gear
	if cmd > 0.05:
		want = 1
	elif cmd < -0.05:
		want = -1
	var reversing := false # 전후진 전환 중(동력 없음)
	if gear != 0 and want != gear:
		# 반대 방향으로 가려면 먼저 멈춰야 한다
		reversing = true
		if absf(track_speed_left) < 0.3 and absf(track_speed_right) < 0.3:
			gear = 0
			_pending_gear = want
			_shift_to = 0
			shift_timer = spec.direction_change_s
	elif gear == 0:
		reversing = true
		_pending_gear = want
		shift_timer -= delta
		if shift_timer <= 0.0:
			gear = _pending_gear
			gear_index = spec.start_gear if gear > 0 else 1
			shift_timer = 0.0

	var g := gear if gear != 0 else _pending_gear
	var rev := g < 0
	var table: Array = spec.reverse_gears_kmh if rev else spec.forward_gears_kmh
	gear_index = clampi(gear_index, 1, table.size())
	var dir_max := float(table[table.size() - 1]) / 3.6
	var fwd := -global_transform.basis.z
	var v := forward_speed()
	var va := absf(v)
	var sin_slope := fwd.y * float(g) # 진행 방향 오르막 sin
	var m_eff := spec.mass_t * 1000.0 * MASS_FACTOR
	var resist := spec.resistance_n(sin_slope)
	var brake := c.brake
	var want_speed := maxf(absf(c.left_track), absf(c.right_track)) * dir_max * (1.0 - brake)

	# 자동 변속(같은 방향 안에서 단 올리기/내리기). 변속 중에는 동력이 끊긴다.
	if not reversing:
		if _shift_to != 0:
			shift_timer -= delta
			if shift_timer <= 0.0:
				gear_index = _shift_to
				_shift_to = 0
				shift_timer = 0.0
		elif va < 0.3 and absf(track_speed_left - track_speed_right) < 0.3:
			# 정지 중에는 출발단으로(시간 없음). 오르막이라 출발단으로 못 움직이면 더 낮은 단에서 출발
			gear_index = spec.start_gear if not rev else 1
			while gear_index > 1 and spec.gear_force_n(gear_index, rev) < resist * 1.1:
				gear_index -= 1
		else:
			_auto_shift(table, rev, va, want_speed, resist, m_eff)
	var shifting := reversing or _shift_to != 0
	var v_top := spec.gear_top_mps(gear_index, rev)

	var tl := 0.0
	var tr := 0.0
	if not reversing:
		tl = _track_target(c.left_track, g, dir_max)
		tr = _track_target(c.right_track, g, dir_max)
		# 현재 단 최고속도를 넘지 않게 두 궤도를 같은 비율로 줄인다(조향 비율 유지)
		var peak := maxf(absf(tl), absf(tr))
		if peak > v_top:
			tl *= v_top / peak
			tr *= v_top / peak
		tl *= damage.track_efficiency("left") * (1.0 - brake)
		tr *= damage.track_efficiency("right") * (1.0 - brake)
	# 클러치가 끊겨도 가속 명령이 유지되면 엔진 회전은 떨어뜨리지 않는다.
	# 매 변속 뒤 처음부터 스로틀 응답을 반복하던 가속 공백을 없앤다.
	if not reversing and want_speed > 0.01:
		engine_output = move_toward(engine_output, 1.0, delta / maxf(spec.engine_response_s, 0.05))
	else:
		engine_output = move_toward(engine_output, 0.0, delta / (0.15 if shifting else 0.5))
	var force := 0.0 if shifting else engine_output * spec.gear_force_n(gear_index, rev)
	var a_drive := (force - resist) / m_eff                    # 동력이 걸린 궤도의 가속(음수면 못 버팀)
	if a_drive > 0.0:
		a_drive *= spec.acceleration_scale
	# 동력 없이 굴러갈 때 감속: 저항 + (클러치가 붙어 있으면) 엔진 브레이크
	var a_coast := maxf(resist, 0.0) / m_eff + (0.0 if shifting else COAST_DECEL)
	var a_brake := a_coast + spec.brake_mps2 * (1.0 if reversing else brake)
	track_speed_left = _track_step(track_speed_left, tl, a_drive, a_brake, delta)
	track_speed_right = _track_step(track_speed_right, tr, a_drive, a_brake, delta)
	engine_rpm_frac = clampf(absf(forward_speed()) / maxf(v_top, 0.1), 0.0, 1.0)
	var forward := forward_speed()
	yaw_rate = (track_speed_right - track_speed_left) / spec.track_gauge_m * spec.steer_efficiency
	heading = wrapf(heading + yaw_rate * delta, -PI, PI)
	long_accel = lerpf(long_accel, (forward - _prev_forward) / maxf(delta, 1e-4), clampf(delta * 10.0, 0.0, 1.0))
	_prev_forward = forward
	# 경사면을 따라 간 거리의 수평 성분만큼 이동(높이는 _follow_ground 가 지면에 맞춤)
	velocity = Vector3(-sin(heading), 0, -cos(heading)) * forward * sqrt(maxf(1.0 - fwd.y * fwd.y, 0.0))
	if _step_blocked(signf(forward), absf(forward) * delta):
		velocity = Vector3.ZERO
		track_speed_left = 0.0
		track_speed_right = 0.0
	_slide(velocity * delta, delta)
	_follow_ground(delta)


## 이번 스텝 동안 궤도·차체가 닿을 수 있는 범위(이동 여유 포함)에 지형 말고 지면 충돌체가 없는가
func _check_ground_clear() -> bool:
	if ground_map == null or not is_inside_tree():
		return false
	var lift := spec.obstacle_step_m + 0.8
	var half := Vector3(spec.hull_width * 0.5 + 0.6, (lift + 10.0) * 0.5 + 3.0, spec.track_length * 0.5 + 1.2)
	var c := Vector3(global_position.x, global_position.y + (lift - 10.0) * 0.5, global_position.z)
	return ground_map.ground_clear(Transform3D(Basis(Vector3.UP, heading), c), half, get_rid())


## 진행 방향 궤도 앞끝 바로 앞의 높이를 재서, 지금 궤도가 딛고 있는 높이보다 obstacle_step_m 이상 높으면 막힘.
## (돌·통나무·턱처럼 충돌 상자 아래로 들어오는 낮은 장애물에 대한 수직 장애물 한계)
func _step_blocked(dir: float, dist: float) -> bool:
	if dir == 0.0 or not is_inside_tree() or _support.is_empty():
		return false
	if _ground_clear:
		return false  # 평탄 지형 + 주변 장애물 없음: 앞의 지면은 지금 딛는 높이 이하
	var space := get_world_3d().direct_space_state
	var hx := spec.hull_width * 0.5 - spec.track_width * 0.5
	var half := -1 if dir > 0.0 else 1 # 앞(-Z) 또는 뒤
	var z := float(half) * (spec.track_length * 0.5 + 0.05 + dist)
	for side in [-1, 1]:
		var p: Vector3 = global_transform * Vector3(side * hx, 0.0, z)
		var base: float = _support[Vector2i(side, half)]
		var top := Vector3(p.x, base + spec.obstacle_step_m + 1.0, p.z)
		var q := PhysicsRayQueryParameters3D.create(top, Vector3(p.x, base - 3.0, p.z), LAYER_GROUND, [get_rid()])
		var hit := space.intersect_ray(q)
		if not hit.is_empty() and hit.position.y - base > spec.obstacle_step_m:
			var collider: Object = hit.collider
			var hill = collider.get_meta("hill_map") if collider and collider.has_meta("hill_map") else null
			if hill != null and hill.destruction.id_for(collider, int(hit.shape)) >= 0:
				continue  # Let actual contact apply crushing force instead of stopping before impact.
			return true
	return false


## 조종수의 자동 변속 판단.
##  올림: 현재 단 최고속도 근처 + 더 빨리 가고 싶음 + 다음 단 견인력이 저항을 이김
##        + 변속하는 동안(동력 단절) 속도를 너무 잃지 않음 → 그래서 T-34 는 오르막에서 2단에 머문다
##  내림: 현재 단으로 저항을 못 이기는데 속도가 아래 단 영역까지 떨어짐, 또는 속도가 아주 낮아짐
func _auto_shift(table: Array, rev: bool, va: float, want_speed: float, resist: float, m_eff: float) -> void:
	var n := table.size()
	var vt := spec.gear_top_mps(gear_index, rev)
	if gear_index < n and va >= 0.95 * vt and want_speed > vt * 1.02:
		var t_shift := spec.shift_time(gear_index, gear_index + 1)
		var v_after := va - maxf(resist, 0.0) / m_eff * t_shift # 클러치를 끊으면 저항만 감속
		if spec.gear_force_n(gear_index + 1, rev) > resist * 1.05 and v_after > 0.55 * vt:
			_begin_shift(gear_index + 1)
	elif gear_index > 1:
		var vp := spec.gear_top_mps(gear_index - 1, rev)
		var lugging := spec.gear_force_n(gear_index, rev) < resist and va < 0.95 * vp
		var low := gear_index > (1 if rev else spec.start_gear) and va < 0.45 * vp
		if lugging or low:
			_begin_shift(gear_index - 1)


func _begin_shift(to_gear: int) -> void:
	shift_timer = spec.shift_time(gear_index, to_gear)
	_shift_to = to_gear


## 궤도 속도 s 가 목표 t 쪽으로 더 빨라져야 하나(동력 필요)
static func _below(s: float, t: float) -> bool:
	return absf(t) > absf(s) + 1e-3 and (signf(t) == signf(s) or absf(s) < 1e-3)


## 궤도 하나의 속도 갱신: 목표보다 느리면 견인 가속(a_drive), 빠르거나 반대면 감속(a_brake)
static func _track_step(s: float, t: float, a_drive: float, a_brake: float, delta: float) -> float:
	if _below(s, t):
		if a_drive >= 0.0:
			return move_toward(s, t, a_drive * delta)
		return move_toward(s, 0.0, -a_drive * delta) # 견인력 부족: 속도가 떨어짐
	return move_toward(s, t, a_brake * delta)


## 수평 이동 + 장애물(바위·나무·전차)에 미끄러짐. step(delta) 의 delta 를 그대로 쓰므로
## 학습 루프에서 프레임과 무관하게 직접 호출해도 같은 결과가 나온다.
func _slide(motion: Vector3, delta := 1.0 / 30.0) -> void:
	if not is_inside_tree() or motion.length_squared() < 1e-10:
		return
	for i in 2:
		var col := move_and_collide(motion)
		if col == null:
			return
		var collider: Object = col.get_collider()
		var hill = collider.get_meta("hill_map") if collider and collider.has_meta("hill_map") else null
		if hill != null:
			var effort := maxf(absf(control.left_track), absf(control.right_track)) * (1.0 - control.brake)
			var energy := maxf(0.5 * spec.mass_t * forward_speed() * forward_speed(), spec.mass_t * effort * 2.0 * delta)
			var result: Dictionary = hill.destruction.damage(collider, col.get_collider_shape_index(), energy, "tank:" + str(name))
			if result.get("destroyed", false):
				motion = col.get_remainder()
				track_speed_left *= 0.7
				track_speed_right *= 0.7
				continue
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


## 궤도 아래 지면 표본 → 지면이 요구하는 피치/롤(ground_pitch/roll)과 높이.
## 궤도마다 앞/뒤 절반에서 각각 4점씩 재고 가장 높은 곳을 지지점으로 본다 → 한쪽 궤도로 돌·통나무를 타면 그쪽이 들림.
## 실제 차체 자세는 현가장치 스프링-감쇠 모델로 이 목표를 따라가고, 가감속·선회 관성으로 출렁인다.
func _follow_ground(delta: float, snap := false) -> void:
	var t0 := Time.get_ticks_usec()
	_follow_ground_impl(delta, snap)
	perf_ground_us += Time.get_ticks_usec() - t0


func _follow_ground_impl(delta: float, snap := false) -> void:
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var hx := spec.hull_width * 0.5 - spec.track_width * 0.5
	var hz := spec.track_length * 0.45
	var xf := global_transform
	var lift := spec.obstacle_step_m + 0.8
	var h := {}
	var ok := space != null
	if ok and _ground_clear:
		# 평탄 지형이고 궤도 주변에 장애물이 없다: 16개 레이가 모두 같은 높이를 돌려준다
		for side in [-1, 1]:
			for half in [-1, 1]:
				h[Vector2i(side, half)] = ground_map.flat_height
	elif ok:
		for side in [-1, 1]:
			for half in [-1, 1]: # -1 = 앞, +1 = 뒤
				var best := -INF
				for k in SUPPORT_SAMPLES:
					var lp := Vector3(side * hx, 0.0, half * hz * k)
					var p: Vector3 = xf * lp
					var q := PhysicsRayQueryParameters3D.create(p + Vector3.UP * lift, p + Vector3.DOWN * 10.0, LAYER_GROUND, [get_rid()])
					var hit := space.intersect_ray(q)
					if not hit.is_empty():
						best = maxf(best, hit.position.y)
				if best == -INF:
					ok = false
				h[Vector2i(side, half)] = best
	var span_z := hz * 1.25
	if ok:
		var front: float = (h[Vector2i(-1, -1)] + h[Vector2i(1, -1)]) * 0.5
		var rear: float = (h[Vector2i(-1, 1)] + h[Vector2i(1, 1)]) * 0.5
		var left: float = (h[Vector2i(-1, -1)] + h[Vector2i(-1, 1)]) * 0.5
		var right: float = (h[Vector2i(1, -1)] + h[Vector2i(1, 1)]) * 0.5
		_support = h
		ground_pitch = atan2(front - rear, span_z)
		ground_roll = atan2(right - left, 2.0 * hx)
		global_position.y = (front + rear) * 0.5
	elif is_inside_tree():
		global_position.y -= 5.0 * delta # 지면 밖: 천천히 낙하
	# 관성: 가속하면 앞이 들리고(제동 시 숙여짐), 선회하면 바깥쪽으로 기운다
	var a_lat := forward_speed() * yaw_rate # 좌측(+) 구심가속
	var tp := ground_pitch + deg_to_rad(spec.suspension_pitch_deg_per_mps2) * clampf(long_accel, -8.0, 8.0)
	var tr := ground_roll - deg_to_rad(spec.suspension_roll_deg_per_mps2) * clampf(a_lat, -6.0, 6.0)
	if snap:
		hull_pitch = tp
		hull_roll = tr
		_pitch_rate = 0.0
		_roll_rate = 0.0
	else:
		var w := TAU * spec.suspension_freq_hz
		var z := spec.suspension_damping
		var n := maxi(1, ceili(delta / SUSPENSION_SUBSTEP))
		var dt := delta / n
		for i in n:
			_pitch_rate += (w * w * (tp - hull_pitch) - 2.0 * z * w * _pitch_rate) * dt
			_roll_rate += (w * w * (tr - hull_roll) - 2.0 * z * w * _roll_rate) * dt
			hull_pitch += _pitch_rate * dt
			hull_roll += _roll_rate * dt
	var lim := deg_to_rad(MAX_TILT_DEG)
	hull_pitch = clampf(hull_pitch, -lim, lim)
	hull_roll = clampf(hull_roll, -lim, lim)
	global_transform.basis = Basis(Vector3.UP, heading) * Basis(Vector3.RIGHT, hull_pitch) * Basis(Vector3.BACK, hull_roll)
	ground_normal = global_transform.basis.y


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
	turret_yaw = wrapf(turret_yaw - c.turret_traverse * deg_to_rad(traverse_rate_deg_s(c.turret_traverse)) * delta, -PI, PI)
	gun_pitch = clampf(gun_pitch + c.gun_elevation * deg_to_rad(damage.elevation_rate_deg_s()) * delta,
		deg_to_rad(spec.gun_depression_deg), deg_to_rad(spec.gun_elevation_max_deg))
	_sync_turret()


## 지금 자세에서 포탑 선회속도(°/s). 차체가 기울면 포탑 무게 때문에 "오르막 쪽"으로 돌릴 때 느려지고
## 내리막 쪽은 빨라진다. direction: 조작 부호(+ = 우선회).
func traverse_rate_deg_s(direction: float) -> float:
	var base := damage.traverse_rate_deg_s()
	if absf(direction) < 1e-3:
		return base
	var up := global_transform.basis.y
	var tilt := sqrt(maxf(1.0 - up.y * up.y, 0.0)) # sin(차체 기울기)
	if tilt < 1e-3:
		return base
	# 포탑이 도는 방향으로 포 축이 얼마나 올라가나(+ = 오르막 쪽으로 돌림)
	var yaw_dir := -signf(direction)
	var a := global_transform.basis * (Basis(Vector3.UP, turret_yaw) * Vector3.FORWARD)
	var b := global_transform.basis * (Basis(Vector3.UP, turret_yaw + yaw_dir * 0.05) * Vector3.FORWARD)
	var climb := clampf((b.y - a.y) / (0.05 * tilt), -1.0, 1.0)
	return base * clampf(1.0 - spec.traverse_slope_penalty * tilt * climb, 0.25, 1.6)


## 지금 포탑 방향에서 포가 겨눌 수 있는 월드 고저각 범위(°). 차체가 앞으로 숙이면 둘 다 내려간다.
func gun_world_limits_deg() -> Vector2:
	var b := global_transform.basis * Basis(Vector3.UP, turret_yaw)
	var lo := b * (Basis(Vector3.RIGHT, deg_to_rad(spec.gun_depression_deg)) * Vector3.FORWARD)
	var hi := b * (Basis(Vector3.RIGHT, deg_to_rad(spec.gun_elevation_max_deg)) * Vector3.FORWARD)
	return Vector2(rad_to_deg(asin(clampf(lo.y, -1, 1))), rad_to_deg(asin(clampf(hi.y, -1, 1))))


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
	shot_launched.emit(self, result)
	if projectile_field != null:
		projectile_field.launch(self, from, dir, shell, result)
		aim_error_mrad = maxf(aim_error_mrad, shell.dispersion_mrad * damage.dispersion_factor() * 2.0)
		return result
	var hit := _trace_shell(from, dir * shell.muzzle_velocity_ms)
	if hit.is_empty():
		result["blocked_by"] = "none"
	elif hit.has("tank"):
		var target: Tank = hit.tank
		var target_was_alive := target.damage.is_combat_effective()
		var r := DamageModel.resolve_shot(target.damage, target.turret_yaw, hit.local_origin, hit.local_dir,
			hit.distance, shell, rng, target.gun_pitch)
		r.merge(result, false)
		r["target_name"] = target.name
		r["target_team"] = target.team
		r["target_was_combat_effective"] = target_was_alive
		r["flight_time_s"] = snappedf(hit.time, 0.01)
		r["hit_pos"] = TankSpec._v(hit.world_pos)
		result = r
	elif hit.has("blocked_by"):
		result["blocked_by"] = hit.blocked_by
		result["hit_pos"] = TankSpec._v(hit.position)
		var collider: Object = hit.get("collider")
		var hill = collider.get_meta("hill_map") if collider and collider.has_meta("hill_map") else null
		if hill != null:
			result["obstacle_damage"] = hill.destruction.damage(collider, int(hit.get("shape", -1)),
				0.5 * shell.shell_mass_kg * shell.muzzle_velocity_ms * shell.muzzle_velocity_ms / 1000.0 + shell.filler_g * 2.0,
				"shell:" + str(name))
	else:
		result["blocked_by"] = "none"
	if hit.has("near_miss"):
		result["near_miss"] = hit.near_miss
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
	var near := {}
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
			best = {"blocked_by": (col as Node).name if col is Node else "?", "position": gh.position,
				"collider": col, "shape": gh.shape}
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
		# Measure only the part of the actual ballistic segment before its first collision.
		var visible_end := p + d * best_t
		for t in tanks:
			var enemy := t as Tank
			if enemy == null or enemy == self or enemy.team == team or not enemy.damage.is_combat_effective():
				continue
			var center := enemy.global_position + Vector3.UP * (enemy.spec.hull_bottom_y + enemy.spec.hull_size.y * 0.5)
			var point := Geometry3D.get_closest_point_to_segment(center, p, visible_end)
			var miss := point.distance_to(center)
			if miss > 12.0 or miss >= float(near.get("miss_distance_m", INF)):
				continue
			# A shell stopping near the far side of a wall is not useful near-miss practice.
			var start := point + (point - center).normalized() * 0.02
			var visibility := PhysicsRayQueryParameters3D.create(start, center, 1 | 2, [get_rid(), enemy.get_rid()])
			visibility.hit_from_inside = true
			if not space.intersect_ray(visibility).is_empty():
				continue
			near = {"target_name": enemy.name, "target_team": enemy.team, "miss_distance_m": miss,
				"range_m": from.distance_to(center), "point": TankSpec._v(point),
				"local_point": TankSpec._v(enemy.global_transform.affine_inverse() * point)}
		if not best.is_empty():
			if best.has("tank"):
				best["distance"] = traveled + best_t
				best["time"] = time + SHELL_STEP_S * best_t / seg_len
			if not near.is_empty():
				best["near_miss"] = near
			return best
		traveled += seg_len
		time += SHELL_STEP_S
		p = p1
		v = v1
		if p.y < -200.0:
			break
	return {"near_miss": near} if not near.is_empty() else {}


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


## HUD·로그용 변속 상태: "전진 3단", "후진 1단", "변속 2→3", "전후진 전환"
func gear_label() -> String:
	if gear == 0:
		return "전후진 전환"
	var d := "전진" if gear > 0 else "후진"
	if _shift_to != 0:
		return "%s 변속 %d→%d" % [d, gear_index, _shift_to]
	return "%s %d단" % [d, gear_index]


## 차체 기준 진행 속도(m/s, + = 전진)
func forward_speed() -> float:
	return (track_speed_left + track_speed_right) * 0.5


## ML 관측용 자기 기동·사격 상태(고정 길이). 라벨: OBSERVATION_LABELS
const OBSERVATION_LABELS := [
	"speed_norm", "gear", "shifting", "yaw_rate_norm", "hull_pitch_norm", "hull_roll_norm",
	"turret_yaw_sin", "turret_yaw_cos", "gun_pitch_norm", "depression_margin_norm",
	"aim_error_norm", "reload_frac",
	"gear_index_norm", "engine_rpm_frac", "ground_pitch_norm", "ground_roll_norm",
	"gun_world_min_norm", "gun_world_max_norm",
]


func observation() -> PackedFloat32Array:
	var dep := deg_to_rad(spec.gun_depression_deg)
	var ele := deg_to_rad(spec.gun_elevation_max_deg)
	var reload_total := damage.reload_time_s()
	var lim := gun_world_limits_deg()
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
		float(gear_index) / float((spec.forward_gears_kmh if gear >= 0 else spec.reverse_gears_kmh).size()),
		engine_rpm_frac,
		clampf(rad_to_deg(ground_pitch) / 30.0, -1.0, 1.0),
		clampf(rad_to_deg(ground_roll) / 30.0, -1.0, 1.0),
		clampf(lim.x / 30.0, -1.0, 1.0),
		clampf(lim.y / 30.0, -1.0, 1.0),
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
		"gear": gear, "gear_index": gear_index, "gear_label": gear_label(),
		"shift_timer": snappedf(shift_timer, 0.01), "engine_output": snappedf(engine_output, 0.01),
		"ground_pitch_deg": snappedf(rad_to_deg(ground_pitch), 0.1), "ground_roll_deg": snappedf(rad_to_deg(ground_roll), 0.1),
		"gun_world_limits_deg": [snappedf(gun_world_limits_deg().x, 0.1), snappedf(gun_world_limits_deg().y, 0.1)],
		"aim_error_mrad": snappedf(aim_error_mrad, 0.01),
		"reload_timer": snappedf(reload_timer, 0.01), "ammo": current_shell().shell_name,
		"control": control.to_dict(), "damage": damage.to_dict(),
	}
