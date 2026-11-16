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

const THIRD := 0
const GUNNER := 1
const COMMANDER := 2
const MODE_LABELS := ["3인칭", "포수 조준경", "전차장"]

const THIRD_FOV := 70.0
## 포수 조준경 배율 단계(수직 시야각°). 약 3배 / 6배
const GUNNER_FOVS := [24.0, 12.0]
const COMMANDER_FOV_MAX := 70.0
const COMMANDER_FOV_MIN := 9.0
const ZOOM_STEP := 1.25
const MOUSE_SENS := 0.0035   # rad/px (시야각 70° 기준, 확대하면 그만큼 느려짐)
const KEY_LOOK_RATE := 1.4   # rad/s (방향키)
## WorldMarkers.attach_label 의 기본 pixel_size
const TAG_PIXEL_SIZE := 0.0012
const RANGE_MARKS := [200, 400, 600, 800, 1000, 1200, 1600, 2000]

var mode := THIRD
## C 를 누르고 있는 동안(3인칭에서만)
var free_look := false
## 3인칭 자유 시선: 포탑 방향 기준 오프셋(rad, + = 좌)
var orbit_yaw := 0.0
var orbit_pitch := 0.0
## 전차장 시선: 차체 기준 방위(rad, + = 좌), 수평 기준 앙각
var cmd_yaw := 0.0
var cmd_pitch := 0.0
var cmd_fov := COMMANDER_FOV_MAX
var gunner_zoom := 0
## 지면 아래로 카메라가 들어가지 않게 높이 조회용(없어도 됨)
var map: HillMap
## 화면 표시(조준경 눈금, 방위 표시). 메인이 CanvasLayer 에 붙인다.
var reticle: TankViewReticle
## 마우스 캡처 여부를 바꾸는지(테스트·헤드리스에서는 false)
var capture_mouse := true

var tank: Tank
var _mouse_delta := Vector2.ZERO


func _init() -> void:
	far = 3000.0
	fov = THIRD_FOV
	reticle = TankViewReticle.new()
	reticle.rig = self


func locks_gun() -> bool:
	return free_look or mode == COMMANDER


## 시선이 포와 분리된 동안 포탑 선회·포 고저 입력을 막는다.
func apply_locks(c: TankControlInput) -> TankControlInput:
	if locks_gun():
		c.turret_traverse = 0.0
		c.gun_elevation = 0.0
	return c


func toggle_gunner() -> void:
	set_mode(THIRD if mode == GUNNER else GUNNER)


func toggle_commander() -> void:
	set_mode(THIRD if mode == COMMANDER else COMMANDER)


func set_mode(m: int) -> void:
	if m == COMMANDER and mode != COMMANDER and tank:
		# 처음에는 포가 향한 쪽을 본다
		cmd_yaw = tank.turret_yaw
		cmd_pitch = 0.0
	mode = m
	orbit_yaw = 0.0
	orbit_pitch = 0.0
	_mouse_delta = Vector2.ZERO


## 휠·+/- : 포수 조준경 배율 단계 / 전차장 쌍안경 확대
func zoom(step: int) -> void:
	if mode == GUNNER:
		gunner_zoom = clampi(gunner_zoom + step, 0, GUNNER_FOVS.size() - 1)
	elif mode == COMMANDER:
		cmd_fov = clampf(cmd_fov / pow(ZOOM_STEP, step), COMMANDER_FOV_MIN, COMMANDER_FOV_MAX)


## 3인칭 대비 배율
func magnification() -> float:
	return tan(deg_to_rad(THIRD_FOV) * 0.5) / tan(deg_to_rad(fov) * 0.5)


func status_text() -> String:
	match mode:
		GUNNER:
			return "시점: 포수 조준경 x%.1f (Shift 해제, 휠 배율)" % magnification()
		COMMANDER:
			return "시점: 전차장 x%.1f  시선 %+.0f° (포 고정, B 해제, 휠 확대)" % [magnification(), rad_to_deg(wrapf(cmd_yaw - tank.turret_yaw, -PI, PI)) if tank else 0.0]
	if free_look:
		return "시점: 3인칭 자유 시선 (포 고정, C 떼면 복귀)"
	return "시점: 3인칭 (Shift 포수, C 자유 시선, B 전차장)"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_delta += event.relative
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
			KEY_EQUAL, KEY_KP_ADD:
				zoom(1)
			KEY_MINUS, KEY_KP_SUBTRACT:
				zoom(-1)


## 매 프레임 메인이 호출. p = 지금 조종하는 전차
func update_view(p: Tank, delta: float) -> void:
	if p != tank:
		_set_tag_visible(tank, true)
		tank = p
		if mode == COMMANDER:
			cmd_yaw = p.turret_yaw
			cmd_pitch = 0.0
	free_look = mode == THIRD and Input.is_physical_key_pressed(KEY_C)
	var looking := free_look or mode == COMMANDER
	if capture_mouse:
		var want := Input.MOUSE_MODE_CAPTURED if looking else Input.MOUSE_MODE_VISIBLE
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
	match mode:
		GUNNER:
			_place_gunner(p)
		COMMANDER:
			cmd_yaw = wrapf(cmd_yaw + look.x, -PI, PI)
			cmd_pitch = clampf(cmd_pitch + look.y, deg_to_rad(-25.0), deg_to_rad(30.0))
			_place_commander(p)
		_:
			if free_look:
				orbit_yaw = wrapf(orbit_yaw + look.x, -PI, PI)
				orbit_pitch = clampf(orbit_pitch + look.y, deg_to_rad(-25.0), deg_to_rad(35.0))
			else:
				# 떼면 부드럽게 포 뒤로 복귀
				var k := 1.0 - exp(-delta * 8.0)
				orbit_yaw = lerpf(orbit_yaw, 0.0, k)
				orbit_pitch = lerpf(orbit_pitch, 0.0, k)
			_place_third(p)
	_scale_tags()
	if reticle:
		reticle.queue_redraw()


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


func _place_third(p: Tank) -> void:
	fov = THIRD_FOV
	var yaw := p.global_rotation.y + p.turret_yaw + orbit_yaw
	var fwd := _dir(yaw, orbit_pitch)
	var target := p.global_position + Vector3.UP * 3.0
	var pos := target - fwd * 14.0 + Vector3.UP * 4.0
	if map:
		pos.y = maxf(pos.y, map.height_at(pos.x, pos.z) + 1.0)
	global_position = pos
	look_at(target + fwd * 30.0, Vector3.UP)


func _place_gunner(p: Tank) -> void:
	fov = GUNNER_FOVS[gunner_zoom]
	var d := p.gun_direction()
	global_position = p.muzzle_position() + d * 0.3
	look_at(global_position + d * 100.0, Vector3.UP)


func _place_commander(p: Tank) -> void:
	fov = cmd_fov
	global_position = LineOfSight.eye_position(p)
	look_at(global_position + _dir(p.global_rotation.y + cmd_yaw, cmd_pitch) * 100.0, Vector3.UP)


## 방위 yaw(+ = 좌, 0 = -Z), 앙각 pitch 의 단위 벡터
static func _dir(yaw: float, pitch: float) -> Vector3:
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


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
