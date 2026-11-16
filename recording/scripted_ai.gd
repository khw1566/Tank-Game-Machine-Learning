class_name ScriptedAI
extends RefCounted
## 기준선(규칙 기반) AI. 학습 AI 가 생기기 전까지 관전·기록·보고서 시험용 상대.
## 학습 정책과 똑같은 조건으로 움직인다:
##   입력 = TankPerception(지금 시점에서 보이고 들리는 것 + 자기 전차 계기)만. 다른 전차 객체·정확한 거리·자동 탄도해를 쓰지 않는다.
##   출력 = 조작 6개(TankControlInput) + 시점 5개(TankView) = 11개.
## 판단 근거는 last_info 로 남긴다(MatchRecorder.log_decision).
##
##  - 적을 모르면: 전차장 시점으로 적 진영(또는 포성이 들린 쪽)을 둘러본다
##  - 적을 찾으면: 포수 조준경으로 바꾸고 기억한 방향으로 포탑을 돌린 뒤, 십자선 오차와
##    "보이는 크기로 어림한 거리"의 거리 눈금(초과앙각)으로 조준해 쏜다
##  - 티거(방어): 제자리에서 적 방향에 차체를 angle_deg 만큼 비스듬히
##  - 연합군(공격): 측면 오프셋을 둔 접근점으로 이동, 어림 거리가 engage_range 안이면 정지 후 사격

const STEP_S := 1.0 / 30.0
const ACTION_SIZE := TankControlInput.ACTION_SIZE + TankView.ACTION_SIZE

var angle_deg := 30.0
var engage_range := 550.0
var flank_offset := 0.0       # 연합군 접근 시 표적 기준 좌우 오프셋(m)
var max_fire_range := 1500.0
## 적 진영 위치(맵 공개 정보: 양 팀 출발 지역)
var enemy_base := Vector3.ZERO
## 이만큼 못 본 적은 다시 찾는다(전차장 시점 수색)
var reacquire_s := 4.0
var last_info := {}
# 막힘 탈출: 전진 명령인데 거의 안 움직이면 잠시 후진하며 방향을 튼다
var _stuck_s := 0.0
var _escape_s := 0.0
var _escape_dir := 1.0
var _detour_s := 0.0           # 탈출 후 옆으로 돌아가는 시간
var _stuck_count := 0
var _scan_t := 0.0
var _cue_yaw := INF            # 마지막으로 들은 포성·피탄 방향(월드 방위)
var _cue_age := 99.0


static func for_tank(t: Tank, index_in_team: int, p_enemy_base := Vector3.ZERO) -> ScriptedAI:
	var ai := ScriptedAI.new()
	ai.enemy_base = p_enemy_base
	if t.team == 1:
		ai.flank_offset = [-260.0, 260.0, -140.0, 140.0, 0.0, -380.0, 380.0][index_in_team % 7]
		ai.engage_range = 450.0 + 60.0 * (index_in_team % 3)
	return ai


## 이번 스텝 행동(길이 11): [left, right, brake, traverse, elevation, fire, view_mode, free_look, look_yaw, look_pitch, zoom]
func act(me: Tank, p: TankPerception) -> Array:
	_scan_t += STEP_S
	_cue_age += STEP_S
	_listen(me, p)
	var hull_yaw := me.global_rotation.y
	var target := _pick_target(p)
	var drive := [0.0, 0.0, 1.0]
	var gun := [0.0, 0.0, 0.0]
	var view := [TankView.COMMANDER, 0.0, 0.0, 0.0, 0.0]
	var mode := ""
	var info := {}
	if target.is_empty():
		# 수색: 들은 소리 쪽, 없으면 적 진영 쪽을 전차장 시점으로 둘러본다
		var to_base := enemy_base - me.global_position
		var base_yaw := atan2(-to_base.x, -to_base.z)
		var cue := _cue_yaw != INF and _cue_age < 15.0
		var focus := _cue_yaw if cue else base_yaw
		var sweep := deg_to_rad(20.0 if cue else 60.0) * sin(_scan_t * 0.6)
		view = _look_at(p, wrapf(focus + sweep - hull_yaw, -PI, PI), 0.0, 30.0)
		if me.team == 0:
			drive = _turn_to(me, focus + deg_to_rad(angle_deg), 0.0)
			mode = "search_hold"
		else:
			var side := Vector3(-to_base.z, 0, to_base.x).normalized()
			var dist := Vector2(to_base.x, to_base.z).length()
			var g := enemy_base + side * flank_offset * clampf((dist - engage_range) / 400.0, 0.0, 1.0) - me.global_position
			drive = _turn_to(me, _detour(atan2(-g.x, -g.z)), 1.0)
			mode = "search_advance"
		info = {"cue": "sound" if cue else "base"}
	else:
		var est_r := TankPerception.estimate_range(target)
		var t_yaw: float = target.world_yaw
		var est_pos: Vector3 = target.seen_from + TankView.dir(t_yaw, target.elev) * est_r
		var to_t := est_pos - me.global_position
		var dist := Vector2(to_t.x, to_t.z).length()
		var age := p.time - float(target.t)
		if me.team == 0:
			drive = _turn_to(me, atan2(-to_t.x, -to_t.z) + deg_to_rad(angle_deg), 0.0)
			mode = "angle_hold"
		elif dist > engage_range or age > reacquire_s:
			var side := Vector3(-to_t.z, 0, to_t.x).normalized()
			var goal := est_pos + side * flank_offset * clampf((dist - engage_range) / 400.0, 0.0, 1.0)
			var gg := goal - me.global_position
			drive = _turn_to(me, _detour(atan2(-gg.x, -gg.z)), 1.0)
			mode = "advance" if dist > engage_range else "seek_los"
		else:
			drive = _turn_to(me, atan2(-to_t.x, -to_t.z), 0.0)
			mode = "engage"
		if age > reacquire_s:
			# 놓쳤다: 기억한 방향 주변을 전차장 시점으로 다시 찾는다
			view = _look_at(p, wrapf(t_yaw + deg_to_rad(25.0) * sin(_scan_t * 0.8) - hull_yaw, -PI, PI), target.elev, 20.0)
			mode += "+reacquire"
		else:
			view = [TankView.GUNNER, 0.0, 0.0, 0.0, 1.0 if est_r > 500.0 else -1.0]
			gun = _aim(me, p, target, est_r)
			mode += "+aim" if target.gun_err == null else "+gunsight"
		info = {"track": target.track, "type": target.get("type", "?"), "px": int(target.size_px),
			"est_range_m": snappedf(est_r, 1.0), "seen_age_s": snappedf(age, 0.1)}
		if gun.size() > 3:
			info["aim_err_mrad"] = gun[3]
	drive = _unstick(me, drive)
	if _escape_s > 0.0:
		mode = "unstick"
	info["mode"] = mode
	info["view"] = TankView.MODE_IDS[int(view[0])]
	last_info = info
	return [drive[0], drive[1], drive[2], gun[0], gun[1], gun[2], view[0], view[1], view[2], view[3], view[4]]


## 쏠 적: 기억 중 격파되지 않은 것 중 우선순위가 가장 높은 것
func _pick_target(p: TankPerception) -> Dictionary:
	for c in p.sorted_contacts(true):
		if not c.knocked_out:
			return c
	return {}


## 들린 포성·피탄 방향 기억(월드 방위)
func _listen(me: Tank, p: TankPerception) -> void:
	var head := me.global_rotation.y + p.view.yaw_rel_hull(me)
	for s in p.last_sounds:
		if s.kind == SoundField.GUNFIRE or s.kind == SoundField.HIT_ME:
			if s.age < 0.5:
				_cue_yaw = wrapf(head + float(s.bearing), -PI, PI)
				_cue_age = 0.0
			return


## 시점 행동: 전차장 시점으로 차체 기준 방위 want_rel, 앙각 want_pitch 를 향하고 시야각 want_fov 로 확대
func _look_at(p: TankPerception, want_rel: float, want_pitch: float, want_fov: float) -> Array:
	var v := p.view
	if v.mode != TankView.COMMANDER:
		return [TankView.COMMANDER, 0.0, 0.0, 0.0, 0.0]
	var ey := wrapf(want_rel - v.cmd_yaw, -PI, PI)
	var ep := want_pitch - v.cmd_pitch
	var z := clampf(log(v.cmd_fov / want_fov) * 2.0, -1.0, 1.0)
	return [TankView.COMMANDER, 0.0, clampf(ey * 4.0, -1.0, 1.0), clampf(ep * 4.0, -1.0, 1.0), z]


## 포 조작 [traverse, elevation, fire(, 오차 mrad)]
func _aim(me: Tank, p: TankPerception, c: Dictionary, est_r: float) -> Array:
	var se := Ballistics.superelevation_rad(me.current_shell(), est_r)
	var ge = c.gun_err
	if ge == null or p.view.mode != TankView.GUNNER:
		# 조준경에 아직 없음: 기억한 방향으로 포탑을 돌린다(포탑 각·포 각은 자기 계기)
		var e_yaw := wrapf(wrapf(float(c.world_yaw) - me.global_rotation.y, -PI, PI) - me.turret_yaw, -PI, PI)
		var e_pitch := float(c.elev) + se - asin(clampf(me.gun_direction().y, -1.0, 1.0))
		return [clampf(-e_yaw * 20.0, -1.0, 1.0), clampf(e_pitch * 40.0, -1.0, 1.0), 0.0]
	# 조준경 안: 십자선 오차 + 거리 눈금(어림 거리의 초과앙각만큼 표적을 십자선 아래에 둔다)
	var ex: float = ge.x
	var ey: float = ge.y + se
	var half := maxf(float(c.size_px) / TankPerception.SCREEN_H_PX * deg_to_rad(float(c.fov)) * 0.5, 0.0005)
	var on := absf(ex) < half * 0.5 and absf(ey) < half * 0.5 \
		and me.aim_error_mrad < me.current_shell().dispersion_mrad * 1.5 and est_r < max_fire_range \
		and me.reload_timer <= 0.0
	return [clampf(ex * 25.0, -1.0, 1.0), clampf(ey * 40.0, -1.0, 1.0), 1.0 if on else 0.0,
		snappedf(Vector2(ex, ey).length() * 1000.0, 0.01)]


## 막혔다가 빠져나온 직후 옆으로 돌아가는 방향 보정
func _detour(want_yaw: float) -> float:
	if _detour_s > 0.0:
		_detour_s -= STEP_S
		return want_yaw + _escape_dir * deg_to_rad(80.0)
	return want_yaw


func _unstick(me: Tank, drive: Array) -> Array:
	if _escape_s > 0.0:
		# 1단계: 비스듬히 후진(기어 변환 시간 포함)  2단계: 반대쪽으로 크게 돌며 전진
		_escape_s -= STEP_S
		if _escape_s > 2.5:
			return [-1.0 if _escape_dir > 0 else -0.3, -0.3 if _escape_dir > 0 else -1.0, 0.0]
		return [1.0 if _escape_dir > 0 else 0.2, 0.2 if _escape_dir > 0 else 1.0, 0.0]
	if drive[0] + drive[1] > 1.0:
		var v := Vector2(me.velocity.x, me.velocity.z).length()
		_stuck_s = _stuck_s + STEP_S if v < 0.5 else 0.0
		if _stuck_s > 2.0:
			_stuck_s = 0.0
			_escape_s = 8.0
			_stuck_count += 1
			if _stuck_count % 2 == 1:
				_escape_dir = -_escape_dir
			_detour_s = 8.0 + 4.0 * _stuck_count
	return drive


## 원하는 차체 방위(yaw)로 회전하며 throttle 로 전진. 반환 [left, right, brake]
static func _turn_to(me: Tank, want_yaw: float, throttle: float) -> Array:
	var err := wrapf(want_yaw - me.global_rotation.y, -PI, PI)
	if throttle <= 0.0 and absf(err) < deg_to_rad(4.0):
		return [0.0, 0.0, 1.0]
	var k := clampf(err * 2.5, -1.0, 1.0)
	var thr := throttle * clampf(1.0 - absf(err) / 1.2, 0.2, 1.0)
	return [clampf(thr - k, -1.0, 1.0), clampf(thr + k, -1.0, 1.0), 0.0]
