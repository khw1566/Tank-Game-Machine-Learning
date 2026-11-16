class_name TankView
extends RefCounted
## 전차 1대의 "시점" 상태(그래픽 없음). 사람의 화면 카메라(TankViewCamera)와 AI 관측(TankPerception)이 같은 것을 쓴다.
## 헤드리스·학습에서도 동작하며, 매 프레임 기록되어 리플레이에서 그 전차가 보던 화면을 다시 만들 수 있다.
##
##   THIRD     3인칭: 포탑 뒤 위에서 포 방향을 본다. free_look(C) 동안 카메라만 돌린다(포 고정).
##   GUNNER    포수 조준경: 포구에서 포 방향 그대로, 배율 2단(약 3배/6배), 원형 시야.
##   COMMANDER 전차장: 큐폴라 높이에서 차체 기준으로 둘러본다(포 고정). 쌍안경 확대 최대 약 8배.
##
## AI 시점 행동(길이 ACTION_SIZE, TankControlInput 6개 뒤에 붙여 총 11개를 출력):
##   0 view_mode   0 = 3인칭, 1 = 포수, 2 = 전차장 (반올림)
##   1 free_look   > 0.5 이면 3인칭 자유 시선(포 고정). 3인칭에서만 의미 있음
##   2 look_yaw    -1 ~ +1  시선 좌우 회전 속도(+ = 좌, 최대 KEY_LOOK_RATE rad/s × 배율 보정). 전차장·자유 시선에서만
##   3 look_pitch  -1 ~ +1  시선 상하(+ = 위)
##   4 zoom        -1 ~ +1  전차장: 연속 확대/축소 속도. 포수: > 0.5 고배율, < -0.5 저배율

const THIRD := 0
const GUNNER := 1
const COMMANDER := 2
const MODE_LABELS := ["3인칭", "포수 조준경", "전차장"]
const MODE_IDS := ["third", "gunner", "commander"]

const THIRD_FOV := 70.0
## 포수 조준경 배율 단계(수직 시야각°). 약 3배 / 6배
const GUNNER_FOVS := [24.0, 12.0]
const COMMANDER_FOV_MAX := 70.0
const COMMANDER_FOV_MIN := 9.0
const ZOOM_STEP := 1.25
## AI zoom 행동 1.0 일 때 초당 확대 단계 수
const ZOOM_RATE := 4.0
const KEY_LOOK_RATE := 1.4   # rad/s
## 화면 비율(가로/세로). 관측의 화면 좌표와 시야 판정에 쓴다.
const ASPECT := 16.0 / 9.0
## 포수 조준경 원형 시야 반지름(화면 세로 절반 = 1 기준). TankViewReticle 의 r_view(0.47 × 높이)와 같다.
const GUNSIGHT_RADIUS := 0.94
## 3인칭 카메라 위치(포탑 뒤 거리, 위 높이)
const THIRD_BACK := 14.0
const THIRD_UP := 4.0

const ACTION_SIZE := 5
const ACTION_LABELS := ["view_mode", "free_look", "look_yaw", "look_pitch", "zoom"]
## 기록용 상태(MatchRecorder frame 의 view_* 필드)
const STATE_LABELS := ["view_mode", "view_yaw", "view_pitch", "view_fov"]

var mode := THIRD
var free_look := false
## 3인칭 자유 시선: 포탑 방향 기준 오프셋(rad, + = 좌)
var orbit_yaw := 0.0
var orbit_pitch := 0.0
## 전차장 시선: 차체 기준 방위(rad, + = 좌), 수평 기준 앙각
var cmd_yaw := 0.0
var cmd_pitch := 0.0
var cmd_fov := COMMANDER_FOV_MAX
var gunner_zoom := 0


func locks_gun() -> bool:
	return free_look or mode == COMMANDER


## 시선이 포와 분리된 동안 포탑 선회·포 고저 입력을 막는다(사람·AI 공통).
func apply_locks(c: TankControlInput) -> TankControlInput:
	if locks_gun():
		c.turret_traverse = 0.0
		c.gun_elevation = 0.0
	return c


func set_mode(m: int, tank: Tank = null) -> void:
	m = clampi(m, THIRD, COMMANDER)
	if m == COMMANDER and mode != COMMANDER and tank:
		# 처음에는 포가 향한 쪽을 본다
		cmd_yaw = tank.turret_yaw
		cmd_pitch = 0.0
	if m != THIRD:
		free_look = false
	mode = m
	orbit_yaw = 0.0
	orbit_pitch = 0.0


func zoom(step: int) -> void:
	if mode == GUNNER:
		gunner_zoom = clampi(gunner_zoom + step, 0, GUNNER_FOVS.size() - 1)
	elif mode == COMMANDER:
		cmd_fov = clampf(cmd_fov / pow(ZOOM_STEP, step), COMMANDER_FOV_MIN, COMMANDER_FOV_MAX)


## 지금 수직 시야각(°)
func fov() -> float:
	match mode:
		GUNNER:
			return GUNNER_FOVS[gunner_zoom]
		COMMANDER:
			return cmd_fov
	return THIRD_FOV


## 3인칭 대비 배율
func magnification() -> float:
	return tan(deg_to_rad(THIRD_FOV) * 0.5) / tan(deg_to_rad(fov()) * 0.5)


## 시선 회전(rad). 전차장 / 3인칭 자유 시선에서만 움직인다.
func look(d_yaw: float, d_pitch: float) -> void:
	if mode == COMMANDER:
		cmd_yaw = wrapf(cmd_yaw + d_yaw, -PI, PI)
		cmd_pitch = clampf(cmd_pitch + d_pitch, deg_to_rad(-25.0), deg_to_rad(30.0))
	elif mode == THIRD and free_look:
		orbit_yaw = wrapf(orbit_yaw + d_yaw, -PI, PI)
		orbit_pitch = clampf(orbit_pitch + d_pitch, deg_to_rad(-25.0), deg_to_rad(35.0))


## 자유 시선을 놓으면 포 뒤로 부드럽게 복귀
func relax(delta: float) -> void:
	if mode == THIRD and not free_look:
		var k := 1.0 - exp(-delta * 8.0)
		orbit_yaw = lerpf(orbit_yaw, 0.0, k)
		orbit_pitch = lerpf(orbit_pitch, 0.0, k)


## AI 시점 행동 적용(ACTION_LABELS 순서, 길이 5). 사람의 Shift/B/C/마우스/휠과 같은 효과.
func apply_action(a, tank: Tank, delta: float) -> void:
	if a == null or a.size() < ACTION_SIZE:
		return
	var m := clampi(roundi(float(a[0])), THIRD, COMMANDER)
	if m != mode:
		set_mode(m, tank)
	free_look = mode == THIRD and float(a[1]) > 0.5
	var s := fov() / THIRD_FOV
	look(clampf(float(a[2]), -1.0, 1.0) * KEY_LOOK_RATE * s * delta, clampf(float(a[3]), -1.0, 1.0) * KEY_LOOK_RATE * s * delta)
	var z := clampf(float(a[4]), -1.0, 1.0)
	if mode == COMMANDER:
		cmd_fov = clampf(cmd_fov / pow(ZOOM_STEP, z * ZOOM_RATE * delta), COMMANDER_FOV_MIN, COMMANDER_FOV_MAX)
	elif mode == GUNNER:
		if z > 0.5:
			gunner_zoom = GUNNER_FOVS.size() - 1
		elif z < -0.5:
			gunner_zoom = 0
	relax(delta)


## 시선 방위(차체 기준, rad, + = 좌)
func yaw_rel_hull(tank: Tank) -> float:
	match mode:
		GUNNER:
			return tank.turret_yaw
		COMMANDER:
			return cmd_yaw
	return wrapf(tank.turret_yaw + orbit_yaw, -PI, PI)


## 시선 앙각(rad, 수평 기준)
func pitch(tank: Tank) -> float:
	match mode:
		GUNNER:
			return asin(clampf(tank.gun_direction().y, -1.0, 1.0))
		COMMANDER:
			return cmd_pitch
	return orbit_pitch


## 실제로 "보는 눈"의 위치: 탐지(가림 판정)는 여기서 한다.
## 포수 = 조준경(포구 쪽), 전차장·3인칭 = 큐폴라. 3인칭 카메라는 높이 떠 있지만 그 위치로 엿보지는 못한다.
func sensor_position(tank: Tank) -> Vector3:
	if mode == GUNNER:
		return tank.muzzle_position()
	return LineOfSight.eye_position(tank)


## 화면 카메라 자세(전역). map 이 있으면 3인칭 카메라가 지면 아래로 들어가지 않게 한다.
func eye_transform(tank: Tank, map: HillMap = null) -> Transform3D:
	match mode:
		GUNNER:
			var d := tank.gun_direction()
			return _look(tank.muzzle_position() + d * 0.3, d)
		COMMANDER:
			return _look(LineOfSight.eye_position(tank), dir(tank.global_rotation.y + cmd_yaw, cmd_pitch))
	var fwd := dir(tank.global_rotation.y + tank.turret_yaw + orbit_yaw, orbit_pitch)
	var target := tank.global_position + Vector3.UP * 3.0
	var pos := target - fwd * THIRD_BACK + Vector3.UP * THIRD_UP
	if map:
		pos.y = maxf(pos.y, map.height_at(pos.x, pos.z) + 1.0)
	return _look(pos, (target + fwd * 30.0 - pos).normalized())


## [mode, yaw(차체 기준), pitch, fov°] — 기록용
func state_array(tank: Tank) -> Array:
	return [mode, yaw_rel_hull(tank), pitch(tank), fov()]


## 기록된 상태를 되살린다(리플레이). 포수 시점은 포 자세에서 저절로 정해진다.
func apply_state(s: Array, tank: Tank) -> void:
	if s.size() < 4:
		return
	mode = clampi(int(s[0]), THIRD, COMMANDER)
	free_look = false
	orbit_yaw = 0.0
	orbit_pitch = 0.0
	match mode:
		COMMANDER:
			cmd_yaw = float(s[1])
			cmd_pitch = float(s[2])
			cmd_fov = float(s[3])
		GUNNER:
			gunner_zoom = 1 if float(s[3]) < (GUNNER_FOVS[0] + GUNNER_FOVS[1]) * 0.5 else 0
		_:
			orbit_yaw = wrapf(float(s[1]) - tank.turret_yaw, -PI, PI)
			orbit_pitch = float(s[2])
			free_look = absf(orbit_yaw) > 0.01 or absf(orbit_pitch) > 0.01


## 전역 점 p 의 화면 좌표. 화면 세로 절반 = 1 (가로는 ±ASPECT). 뒤쪽이면 null
static func screen_point(xf: Transform3D, fov_deg: float, p: Vector3):
	var l := xf.affine_inverse() * p
	if l.z >= -0.01:
		return null
	var k := 1.0 / tan(deg_to_rad(fov_deg) * 0.5)
	return Vector2(l.x / -l.z * k, l.y / -l.z * k)


## 화면 좌표가 이 시점에서 보이는 영역 안인가(포수는 원형 조준경)
func on_screen(sp, margin := 0.0) -> bool:
	if sp == null:
		return false
	if mode == GUNNER:
		return (sp as Vector2).length() <= GUNSIGHT_RADIUS + margin
	return absf(sp.x) <= ASPECT + margin and absf(sp.y) <= 1.0 + margin


## 방위 yaw(+ = 좌, 0 = -Z), 앙각 pitch 의 단위 벡터
static func dir(yaw: float, p: float) -> Vector3:
	return Vector3(-sin(yaw) * cos(p), sin(p), -cos(yaw) * cos(p))


static func _look(pos: Vector3, fwd: Vector3) -> Transform3D:
	var up := Vector3.UP if absf(fwd.y) < 0.999 else Vector3.BACK
	return Transform3D(Basis.looking_at(fwd, up), pos)
