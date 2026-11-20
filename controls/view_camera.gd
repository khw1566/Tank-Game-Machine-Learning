class_name TankViewCamera
extends Camera3D
## 사람이 조종하는 전차의 시점 카메라(게임 화면 전용, 헤드리스·학습에는 쓰지 않음).
##
##   (기본)  3인칭: 포탑 뒤에서 포 방향을 본다
##   Shift : 포수 조준경 시점 켜기/끄기. 포구 위치에서 포 방향 그대로 본다.
##           가운데 십자 = 포 축, 아래 눈금 = 거리별 조준점(현재 탄종 탄도), 원 = 현재 조준 오차.
##           휠 / + - : 저배율·고배율
##   C(누르는 동안) : 3인칭 자유 시선. 포탑·포는 그대로 두고 카메라만 마우스/방향키로 돌린다.
##           떼면 포 방향으로 되돌아온다.
##   B     : 전차장 시점 켜기/끄기. 전차장 해치 높이에서 마우스/방향키로 둘러본다.
##           포는 움직이지 않는다. 휠 / + - 로 확대(쌍안경, 최대 약 8배).
##
## 시선이 포와 분리되는 동안(C, B) 방향키는 카메라를 돌리고, 조종 입력의 포탑·포 값은 0 이 된다
## (apply_locks). 따라서 기록되는 액션도 "포를 움직이지 않음"으로 남는다.

const THIRD := TankView.THIRD
const GUNNER := TankView.GUNNER
const COMMANDER := TankView.COMMANDER
const MODE_LABELS := TankView.MODE_LABELS

const THIRD_FOV := TankView.THIRD_FOV
const GUNNER_FOVS := TankView.GUNNER_FOVS
const COMMANDER_FOV_MAX := TankView.COMMANDER_FOV_MAX
const COMMANDER_FOV_MIN := TankView.COMMANDER_FOV_MIN
const MOUSE_SENS := 0.0035   # rad/px (시야각 70° 기준, 확대하면 그만큼 느려짐)
const KEY_LOOK_RATE := TankView.KEY_LOOK_RATE
## WorldMarkers.attach_label 의 기본 pixel_size
const TAG_PIXEL_SIZE := 0.0012
const RANGE_MARKS := [200, 400, 600, 800, 1000, 1200, 1600, 2000]

## 시점 상태. 메인이 조종 전차의 TankView 를 꽂아 준다(AI 관측·기록과 같은 객체).
var view := TankView.new()
var mode: int:
	get: return view.mode
	set(v): view.mode = v
var free_look: bool:
	get: return view.free_look
	set(v): view.free_look = v
var orbit_yaw: float:
	get: return view.orbit_yaw
	set(v): view.orbit_yaw = v
var orbit_pitch: float:
	get: return view.orbit_pitch
	set(v): view.orbit_pitch = v
var cmd_yaw: float:
	get: return view.cmd_yaw
	set(v): view.cmd_yaw = v
var cmd_pitch: float:
	get: return view.cmd_pitch
	set(v): view.cmd_pitch = v
var cmd_fov: float:
	get: return view.cmd_fov
	set(v): view.cmd_fov = v
var gunner_zoom: int:
	get: return view.gunner_zoom
	set(v): view.gunner_zoom = v
## 지면 아래로 카메라가 들어가지 않게 높이 조회용(없어도 됨)
var map: HillMap
## 화면 표시(조준경 눈금, 방위 표시). 메인이 CanvasLayer 에 붙인다.
var reticle: TankViewReticle
## 마우스 캡처 여부를 바꾸는지(테스트·헤드리스에서는 false)
var capture_mouse := true
## true 면 입력을 받지 않고 view 를 그대로 보여준다(AI 가 조종하는 전차를 관전할 때 = AI 가 보는 화면)
var follow_only := false

var tank: Tank
var _mouse_delta := Vector2.ZERO
var mouse_aim_enabled := true
var aim_point := Vector3.INF
var _third_yaw := 0.0
var _third_pitch := 0.0
var _scope_target := Vector2.ZERO
var _scope_valid := false
## The Godot practice scene uses a centered terrain pointer for its ring controls.
var centered_pointer := false
## 중앙 조준점 광선 길이(m). V7 링 연습 = 180, 실제 전투 시범 = 2500
var pointer_range := 180.0
var pointer_active := false
var _pointer_motion := Vector2.ZERO
var _pointer_angles := Vector2.ZERO
var _pointer_input_pending := false
var _pointer_initialized := false


func reset_pointer() -> void:
	aim_point = Vector3.INF
	tank = null
	_pointer_motion = Vector2.ZERO
	_pointer_angles = Vector2.ZERO
	_pointer_input_pending = false
	_pointer_initialized = false
	_mouse_delta = Vector2.ZERO
	view = TankView.new()


func is_free_look_pressed() -> bool:
	return mode == THIRD and (Input.is_physical_key_pressed(KEY_C)
		or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT))


func take_pointer_input() -> bool:
	var pending := _pointer_input_pending
	_pointer_input_pending = false
	return pending


func _update_pointer_angles(p: Tank) -> void:
	if not _pointer_initialized:
		_pointer_angles = Vector2(p.heading + p.turret_yaw, -0.28)
		_pointer_initialized = true
	var sensitivity := MOUSE_SENS * view.fov() / THIRD_FOV
	_pointer_angles.x = wrapf(_pointer_angles.x - _pointer_motion.x * sensitivity, -PI, PI)
	_pointer_angles.y = clampf(_pointer_angles.y - _pointer_motion.y * sensitivity,
		deg_to_rad(-74.0), deg_to_rad(46.0))
	_pointer_motion = Vector2.ZERO


func _pointer_transform(p: Tank) -> Transform3D:
	var direction := TankView.dir(_pointer_angles.x, _pointer_angles.y)
	var origin: Vector3
	if mode == GUNNER:
		origin = view.eye_transform(p, map).origin
	else:
		var back := TankView.dir(_pointer_angles.x, 0.0)
		origin = p.global_position - back * 14.0 + Vector3.UP * 7.0
		if map:
			origin.y = maxf(origin.y, map.height_at(origin.x, origin.z) + 1.0)
	return Transform3D(Basis.looking_at(direction, Vector3.UP), origin)


func update_pointer(p: Tank, practice_marker := Vector3.INF) -> void:
	if not pointer_active or is_free_look_pressed() or mode == COMMANDER:
		_pointer_motion = Vector2.ZERO
		return
	_update_pointer_angles(p)
	var pose := _pointer_transform(p)
	var origin := pose.origin
	var direction := -pose.basis.z
	var end := origin + direction * pointer_range
	var query := PhysicsRayQueryParameters3D.create(origin, end, Tank.LAYER_GROUND, [p.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	aim_point = hit.position if not hit.is_empty() else end
	if practice_marker != Vector3.INF:
		var distance := (practice_marker - origin).dot(direction)
		var on_ray := origin + direction * distance
		if distance > 0.0 and distance <= origin.distance_to(aim_point) and on_ray.distance_to(practice_marker) < 1.1:
			aim_point = on_ray


func pointer_commands(p: Tank, delta: float) -> Vector2:
	if not pointer_active or is_free_look_pressed() or mode == COMMANDER or aim_point == Vector3.INF:
		return Vector2.ZERO
	var offset := p.to_local(aim_point) - p.spec.turret_origin()
	if offset.length_squared() < 0.001:
		return Vector2.ZERO
	return aim_commands(p, atan2(-offset.x, -offset.z), atan2(offset.y, Vector2(offset.x, offset.z).length()), delta)


## Human input only. The normal rate limits, damage and elevation limits still apply.
func human_control(p: Tank, delta: float) -> TankControlInput:
	if p != tank:
		update_view(p, 0.0)
	var c := KeyboardController.read()
	c.fire = c.fire or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	if follow_only or not mouse_aim_enabled or locks_gun():
		return apply_locks(c)
	if mode == THIRD:
		aim_point = cursor_target(p, get_viewport().get_mouse_position())
		var solution := p.aim_solution(aim_point)
		var commands := aim_commands(p, float(solution.turret_yaw), float(solution.gun_pitch), delta)
		if c.turret_traverse == 0.0:
			c.turret_traverse = commands.x
		if c.gun_elevation == 0.0:
			c.gun_elevation = commands.y
	elif mode == GUNNER:
		if c.turret_traverse != 0.0 or c.gun_elevation != 0.0:
			_scope_valid = false
			return c
		if not _scope_valid:
			_scope_target = Vector2(p.turret_yaw, p.gun_pitch)
			_scope_valid = true
		var commands := aim_commands(p, _scope_target.x, _scope_target.y, delta)
		c.turret_traverse = commands.x
		c.gun_elevation = commands.y
	return apply_locks(c)


static func aim_commands(p: Tank, yaw: float, pitch: float, delta: float) -> Vector2:
	var error := wrapf(yaw - p.turret_yaw, -PI, PI)
	var direction := -signf(error)
	var yaw_step := maxf(deg_to_rad(p.traverse_rate_deg_s(direction)) * delta, 0.00001)
	var pitch_step := maxf(deg_to_rad(p.damage.elevation_rate_deg_s()) * delta, 0.00001)
	return Vector2(clampf(-error / yaw_step, -1, 1), clampf((pitch - p.gun_pitch) / pitch_step, -1, 1))


func cursor_target(p: Tank, pixel: Vector2) -> Vector3:
	var origin := project_ray_origin(pixel)
	var direction := project_ray_normal(pixel)
	var distance := 2500.0
	var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * distance, Tank.LAYER_GROUND, [p.get_rid()])
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		distance = origin.distance_to(hit.position)
	# Exact armor geometry also exposes the low tracks, which have no tank movement collider.
	for other in get_tree().get_nodes_in_group(Tank.GROUP):
		if other == p or not other.is_visible_in_tree():
			continue
		var inv: Transform3D = other.global_transform.affine_inverse()
		var result: Dictionary = HitGeometry.trace(other.spec, other.turret_yaw, inv * origin,
			(inv.basis * direction).normalized(), other.gun_pitch)
		if result.hit and float(result.t) < distance:
			distance = float(result.t)
	return origin + direction * distance


func _init() -> void:
	far = 3000.0
	fov = THIRD_FOV
	reticle = TankViewReticle.new()
	reticle.rig = self


func locks_gun() -> bool:
	return view.locks_gun()


## 시선이 포와 분리된 동안 포탑 선회·포 고저 입력을 막는다.
func apply_locks(c: TankControlInput) -> TankControlInput:
	return view.apply_locks(c)


func toggle_gunner() -> void:
	set_mode(THIRD if mode == GUNNER else GUNNER)


func toggle_commander() -> void:
	set_mode(THIRD if mode == COMMANDER else COMMANDER)


func set_mode(m: int) -> void:
	if tank and m == THIRD:
		_third_yaw = tank.global_rotation.y + tank.turret_yaw
		_third_pitch = 0.0
	view.set_mode(m, tank)
	_mouse_delta = Vector2.ZERO
	_scope_valid = false


## 휠·+/- : 포수 조준경 배율 단계 / 전차장 쌍안경 확대
func zoom(step: int) -> void:
	view.zoom(step)


## 3인칭 대비 배율
func magnification() -> float:
	return view.magnification()


func status_text() -> String:
	match mode:
		GUNNER:
			return "시점: 포수 조준경 x%.1f (마우스 조준, 좌클릭 발사, Shift 해제, 휠 배율)" % magnification()
		COMMANDER:
			return "시점: 전차장 x%.1f  시선 %+.0f° (포 고정, B 해제, 휠 확대)" % [magnification(), rad_to_deg(wrapf(cmd_yaw - tank.turret_yaw, -PI, PI)) if tank else 0.0]
	if free_look:
		return "시점: 3인칭 자유 시선 (포 고정, C 떼면 복귀)"
	return "시점: 3인칭 (커서 조준 %s · R 전환 · 우클릭/C 둘러보기 · Shift 포수 · B 전차장)" % ("켬" if mouse_aim_enabled else "끔")


func _unhandled_input(event: InputEvent) -> void:
	handle_view_input(event)


func handle_view_input(event: InputEvent) -> void:
	if follow_only:
		return
	if event is InputEventMouseMotion:
		if centered_pointer:
			if not pointer_active:
				return
			if is_free_look_pressed() or mode == COMMANDER:
				_mouse_delta += event.relative
			else:
				_pointer_motion += event.relative
				if event.relative != Vector2.ZERO:
					_pointer_input_pending = true
			return
		_mouse_delta += event.relative
		if mode == GUNNER and mouse_aim_enabled and tank:
			if not _scope_valid:
				_scope_target = Vector2(tank.turret_yaw, tank.gun_pitch)
				_scope_valid = true
			_scope_target += Vector2(-event.relative.x, -event.relative.y) * MOUSE_SENS * fov / THIRD_FOV
			_scope_target.y = clampf(_scope_target.y, deg_to_rad(tank.spec.gun_depression_deg), deg_to_rad(tank.spec.gun_elevation_max_deg))
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			zoom(1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			zoom(-1)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_SHIFT:
				toggle_gunner()
			KEY_B:
				toggle_commander()
			KEY_R:
				if centered_pointer:
					return
				mouse_aim_enabled = not mouse_aim_enabled
				aim_point = Vector3.INF
				_scope_valid = false
				_mouse_delta = Vector2.ZERO
				if tank:
					_third_yaw = tank.global_rotation.y + tank.turret_yaw + view.orbit_yaw
			KEY_EQUAL, KEY_KP_ADD:
				zoom(1)
			KEY_MINUS, KEY_KP_SUBTRACT:
				zoom(-1)


## 매 프레임 메인이 호출. p = 지금 조종하는 전차
func update_view(p: Tank, delta: float) -> void:
	if p != tank:
		if is_instance_valid(tank):
			_set_tag_visible(tank, true)
		tank = p
		_third_yaw = p.global_rotation.y + p.turret_yaw
		_third_pitch = 0.0
		_scope_valid = false
	if centered_pointer:
		_update_pointer_view(p, delta)
		return
	if follow_only:
		_mouse_delta = Vector2.ZERO
		release_mouse()
		_set_tag_visible(p, mode == THIRD)
		fov = view.fov()
		global_transform = view.eye_transform(p, map)
		_scale_tags()
		if reticle:
			reticle.queue_redraw()
		return
	free_look = mode == THIRD and (Input.is_physical_key_pressed(KEY_C) or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT))
	var looking := free_look or mode == COMMANDER
	if capture_mouse:
		var want := Input.MOUSE_MODE_CAPTURED if looking or (mode == GUNNER and mouse_aim_enabled) else Input.MOUSE_MODE_VISIBLE
		if Input.mouse_mode != want:
			Input.mouse_mode = want
	# 시선 입력: 마우스 + 방향키, 확대할수록 느리게
	var look := Vector2.ZERO
	if looking:
		var scale := fov / THIRD_FOV
		look = -_mouse_delta * MOUSE_SENS * scale
		look.x += (_key(KEY_LEFT) - _key(KEY_RIGHT)) * KEY_LOOK_RATE * scale * delta
		look.y += (_key(KEY_UP) - _key(KEY_DOWN)) * KEY_LOOK_RATE * scale * delta
	_mouse_delta = Vector2.ZERO
	_set_tag_visible(p, mode == THIRD)
	if looking:
		view.look(look.x, look.y)
	if mode == THIRD and looking:
		_third_yaw = p.global_rotation.y + p.turret_yaw + view.orbit_yaw
		_third_pitch = view.orbit_pitch
	view.relax(delta)
	if mode == THIRD and mouse_aim_enabled and not looking:
		view.orbit_yaw = wrapf(_third_yaw - p.global_rotation.y - p.turret_yaw, -PI, PI)
		view.orbit_pitch = _third_pitch
	fov = view.fov()
	global_transform = view.eye_transform(p, map)
	_scale_tags()
	if reticle:
		reticle.queue_redraw()


func _update_pointer_view(p: Tank, delta: float) -> void:
	var was_free := free_look
	free_look = pointer_active and is_free_look_pressed()
	var looking := free_look or mode == COMMANDER
	var want := Input.MOUSE_MODE_CAPTURED if pointer_active else Input.MOUSE_MODE_VISIBLE
	if capture_mouse and Input.mouse_mode != want:
		Input.mouse_mode = want
	if free_look and not was_free and _pointer_initialized:
		view.orbit_yaw = wrapf(_pointer_angles.x - p.global_rotation.y - p.turret_yaw, -PI, PI)
		view.orbit_pitch = _pointer_angles.y
	if looking and pointer_active:
		var look := -_mouse_delta * MOUSE_SENS * view.fov() / THIRD_FOV
		look.x += (_key(KEY_LEFT) - _key(KEY_RIGHT)) * KEY_LOOK_RATE * delta
		look.y += (_key(KEY_UP) - _key(KEY_DOWN)) * KEY_LOOK_RATE * delta
		view.look(look.x, look.y)
	_mouse_delta = Vector2.ZERO
	view.relax(delta)
	fov = view.fov()
	_set_tag_visible(p, mode == THIRD)
	if looking:
		global_transform = view.eye_transform(p, map)
		return
	_update_pointer_angles(p)
	global_transform = _pointer_transform(p)


## 이름표(Label3D fixed_size)는 확대하면 같이 커지므로 시야각에 맞춰 줄여 화면 크기를 유지
var _tag_fov := THIRD_FOV
func _scale_tags() -> void:
	if is_equal_approx(fov, _tag_fov) or not is_inside_tree():
		return
	_tag_fov = fov
	for t in get_tree().get_nodes_in_group(Tank.GROUP):
		var tag := (t as Node).get_node_or_null("NameTag") as Label3D
		if tag:
			tag.pixel_size = TAG_PIXEL_SIZE * fov / THIRD_FOV


## 방위 yaw(+ = 좌, 0 = -Z), 앙각 pitch 의 단위 벡터
static func _dir(yaw: float, pitch: float) -> Vector3:
	return TankView.dir(yaw, pitch)


## 지금 화면이 바라보는 월드 방위(rad)
func view_yaw() -> float:
	var f := -global_basis.z
	return atan2(-f.x, -f.z)


static func _key(k: Key) -> float:
	return 1.0 if Input.is_physical_key_pressed(k) else 0.0


static func _set_tag_visible(t: Tank, v: bool) -> void:
	if t and is_instance_valid(t):
		var tag := t.get_node_or_null("NameTag")
		if tag:
			tag.visible = v


func release_mouse() -> void:
	if capture_mouse and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func _exit_tree() -> void:
	release_mouse()
