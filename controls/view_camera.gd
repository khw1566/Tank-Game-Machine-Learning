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
	view.set_mode(m, tank)
	_mouse_delta = Vector2.ZERO


## 휠·+/- : 포수 조준경 배율 단계 / 전차장 쌍안경 확대
func zoom(step: int) -> void:
	view.zoom(step)


## 3인칭 대비 배율
func magnification() -> float:
	return view.magnification()


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
	if follow_only:
		return
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
	if looking:
		view.look(look.x, look.y)
	view.relax(delta)
	fov = view.fov()
	global_transform = view.eye_transform(p, map)
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
