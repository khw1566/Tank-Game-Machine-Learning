class_name ScriptedAI
extends RefCounted
## 기준선(규칙 기반) AI. 학습 AI 가 생기기 전까지 관전·기록·보고서 시험용 상대.
## 학습 정책과 똑같이 액션 벡터 6개만 출력하고, 판단 근거를 info 로 남긴다(MatchRecorder.log_decision).
##
##  - 티거(방어): 제자리에서 가장 가까운 적에게 차체를 angle_deg 만큼 비스듬히 돌리고 사격
##  - 연합군(공격): 측면 오프셋을 둔 접근점으로 이동, engage_range 안에 들면 정지 후 사격

var angle_deg := 30.0
var engage_range := 550.0
var flank_offset := 0.0       # 연합군 접근 시 표적 기준 좌우 오프셋(m)
var max_fire_range := 1500.0
var last_info := {}


static func for_tank(t: Tank, index_in_team: int) -> ScriptedAI:
	var ai := ScriptedAI.new()
	if t.team == 1:
		ai.flank_offset = [-260.0, 260.0, -140.0, 140.0, 0.0, -380.0, 380.0][index_in_team % 7]
		ai.engage_range = 450.0 + 60.0 * (index_in_team % 3)
	return ai


## 이번 스텝 액션 벡터. tanks = 전장의 모든 Tank
func act(me: Tank, tanks: Array) -> Array:
	var target := _nearest_enemy(me, tanks)
	if target == null:
		last_info = {"mode": "idle"}
		return [0, 0, 1, 0, 0, 0]
	var to_t := target.global_position - me.global_position
	var dist := Vector2(to_t.x, to_t.z).length()
	var drive := [0.0, 0.0, 1.0]
	var mode := ""
	var aim_point := visible_point(me, target)
	var los := aim_point != Vector3.INF
	if me.team == 0:
		# 비스듬한 대면: 적 방향에서 angle_deg 만큼 틀어진 방위를 유지
		var want := atan2(-to_t.x, -to_t.z) + deg_to_rad(angle_deg)
		drive = _turn_to(me, want, 0.0)
		mode = "angle_hold"
	else:
		var side := Vector3(-to_t.z, 0, to_t.x).normalized()
		var goal := target.global_position + side * flank_offset * clampf((dist - engage_range) / 400.0, 0.0, 1.0)
		var g := goal - me.global_position
		if dist > engage_range or not los:
			drive = _turn_to(me, atan2(-g.x, -g.z), 1.0)
			mode = ("advance_flank" if absf(flank_offset) > 1.0 else "advance") if dist > engage_range else "seek_los"
		else:
			drive = _turn_to(me, atan2(-to_t.x, -to_t.z), 0.0)
			mode = "engage"
	var aim := aim_action(me, target, aim_point if los else Vector3.INF)
	var fire: bool = aim[2] > 0.5 and dist < max_fire_range and los
	last_info = {"mode": mode, "target": target.name, "dist_m": snappedf(dist, 0.1), "los": los,
		"aim_err_deg": snappedf(aim[3], 0.01)}
	return [drive[0], drive[1], drive[2], aim[0], aim[1], 1.0 if fire else 0.0]


## 가장 가까운 적. 이미 포를 못 쓰는 적(화력 상실)은 거리를 3배로 쳐서 뒤로 미룬다.
func _nearest_enemy(me: Tank, tanks: Array) -> Tank:
	var best: Tank = null
	var bd := INF
	for t in tanks:
		if t == me or t.team == me.team or not t.damage.is_combat_effective():
			continue
		var d := me.global_position.distance_to(t.global_position) * (1.0 if t.damage.can_fire() else 3.0)
		if d < bd:
			bd = d
			best = t
	return best


## 원하는 차체 방위(yaw)로 회전하며 throttle 로 전진. 반환 [left, right, brake]
static func _turn_to(me: Tank, want_yaw: float, throttle: float) -> Array:
	var err := wrapf(want_yaw - me.global_rotation.y, -PI, PI)
	if throttle <= 0.0 and absf(err) < deg_to_rad(4.0):
		return [0.0, 0.0, 1.0]
	var k := clampf(err * 2.5, -1.0, 1.0)
	var thr := throttle * clampf(1.0 - absf(err) / 1.2, 0.2, 1.0)
	return [clampf(thr - k, -1.0, 1.0), clampf(thr + k, -1.0, 1.0), 0.0]


## 포구에서 보이는 표적 지점(차체 중앙 → 포탑 중앙 → 포탑 윗부분 순). 지형·바위·나무줄기만 가림(수관 무시).
## 안 보이면 Vector3.INF
static func visible_point(me: Tank, target: Tank) -> Vector3:
	var up := target.global_transform.basis.y
	var s := target.spec
	var cands := [s.hull_bottom_y + s.hull_size.y * 0.6, s.turret_origin().y + s.turret_size.y * 0.5,
		s.turret_origin().y + s.turret_size.y * 0.85]
	var space := me.get_world_3d().direct_space_state
	var from := me.muzzle_position()
	for h in cands:
		var p: Vector3 = target.global_position + up * h
		if space.intersect_ray(PhysicsRayQueryParameters3D.create(from, p, Tank.LAYER_GROUND)).is_empty():
			return p
	return Vector3.INF


## 비례 조준기. 반환 [traverse, elevation, on_target(0/1), 오차(도)]
static func aim_action(me: Tank, target: Tank, aim := Vector3.INF) -> Array:
	if aim == Vector3.INF:
		aim = target.global_position + target.global_transform.basis.y * (target.spec.hull_bottom_y + target.spec.hull_size.y * 0.6)
	var ld := me.global_transform.basis.inverse() * (aim - me.muzzle_position())
	var want_yaw := atan2(-ld.x, -ld.z)
	var want_pitch := atan2(ld.y, Vector2(ld.x, ld.z).length())
	var e_yaw := wrapf(want_yaw - me.turret_yaw, -PI, PI)
	var e_pitch := want_pitch - me.gun_pitch
	var trav := clampf(-e_yaw * 20.0, -1.0, 1.0)
	var elev := clampf(e_pitch * 40.0, -1.0, 1.0)
	var on_target := absf(e_yaw) < 0.002 and absf(e_pitch) < 0.002
	return [trav, elev, 1.0 if on_target else 0.0, rad_to_deg(Vector2(e_yaw, e_pitch).length())]
