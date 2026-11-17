class_name MatchRecorder
extends Node
## 경기(에피소드) 기록기. 그래픽과 무관한 "상태 기록"을 JSONL 로 남긴다.
##
## 한 에피소드 = 폴더 하나:  user://logs/replays/ep0001_<시각>/
##   events.jsonl  모든 기록(아래 형식). 리플레이 뷰어와 보고서는 이 파일 하나만 읽는다.
##   report.html   보고서(동선 지도, 타격 기록, 점수 그래프) — ReportBuilder 가 생성
##   shots.csv / paths.csv / score.csv  엑셀·파이썬용 표
## user://logs/episodes.csv  에피소드별 요약 한 줄씩(에피소드-점수 학습곡선용)
##
## events.jsonl 한 줄 = JSON 객체 1개, "type" 으로 구분 (형식 이름 tankgame-replay, 버전 FORMAT_VERSION):
##   header    맵 전체(지형 높이 격자 + 장애물 치수), 전차 목록·제원 치수, 보상 가중치, 프레임 필드 이름
##   frame     tick, t(초), s = 전차별 [FRAME_FIELDS...] 배열, score = 팀 누적 점수, r = 전차별 누적 점수
##   shot      사격 1발 전체 판정(DamageModel 결과 + 발사 위치·방향·탄착점) + 공격자/표적 id
##   reward    점수 사건(시간 경과 점수는 frame.score 에만 누적)
##   knockout  전차 전투불능(원인 + 그 순간 전체 상태)
##   decision  관측·행동·판단 정보(log_decision 으로 기록). 사람 조종도 controller = "human" 으로 남는다(모방 학습용).
##             info.perception = 그 순간 보인 적(방위·화면 크기·식별)·들린 소리 요약, obs = 관측 벡터 전체(주기적으로)
## frame 의 view_* = 그 전차의 시점(TankView.state_array) → 리플레이에서 "탑승 시점"으로 그 화면을 다시 만든다.
##   end       종료 사유, 승리 팀, 요약
##
## 위치·자세는 물리 결과를 그대로 저장하므로 다시 시뮬레이션하지 않고도 언제든 똑같이 재구성된다.
## 그래픽(모델·지형 재질)이 바뀌어도 기록은 그대로 쓸 수 있다.

signal reward_added(e: Dictionary)
signal shot_recorded(e: Dictionary)
signal episode_ended(summary: Dictionary)

const FORMAT := "tankgame-replay"
const FORMAT_VERSION := 2
## frame.s 의 전차별 배열 항목(순서 고정, 새 항목은 뒤에만 추가)
const FRAME_FIELDS := ["x", "y", "z", "qx", "qy", "qz", "qw", "turret_yaw", "gun_pitch",
	"track_l", "track_r", "status", "ammo_index", "reload",
	"a_left", "a_right", "a_brake", "a_traverse", "a_elev", "a_fire",
	"view_mode", "view_yaw", "view_pitch", "view_fov"]
## status 코드
const STATUS_OK := 0
const STATUS_DAMAGED := 1      # 기동불능 또는 화력상실(아직 전투가능 판정)
const STATUS_KO := 2           # 전투불능(승무원 탈출·사상 등)
const STATUS_DESTROYED := 3    # 파괴(화재·탄약 유폭)

## 몇 물리 틱마다 프레임을 남길지(30 Hz / 3 = 10 Hz). 리플레이는 사이를 보간한다.
@export var sample_every := 3
## 이 시간이 지나면 무승부로 종료(0 = 제한 없음)
@export var time_limit_s := 900.0
@export var write_files := true
var external_rewards := false  # TrainingReward is the sole score source when enabled.
var projectile_field: RefCounted = null
var observation_labels: Array = []
@export var write_report := true
@export var log_root := "user://logs"
## 전멸·시간초과로 스스로 끝낼지. 학습 환경은 단계별 종료 조건을 직접 판단하므로 끈다.
@export var auto_end := true
## 오버레이용 동선 기억 간격(프레임 수)
@export var path_every := 5

var map: HillMap
var tanks: Array = []
## 전차 이름 -> TankView (없으면 3인칭 기본값으로 기록)
var views := {}
var rewards := RewardModel.new()
var meta := {}
var tick := 0
var episode := 0
var dir := ""
var events_path := ""
var ended := false
var winner := -1
var end_reason := ""
var tank_scores := {}            # name -> 누적 점수
var team_scores := [0.0, 0.0]
# 화면 오버레이가 읽는 최근 정보(파일과 별개, 메모리만)
var paths := {}                  # name -> PackedVector3Array
var shots: Array = []            # {"t", "from", "to", "kind", "shooter_team"}
var score_history: Array = []    # [t, team0, team1]
var recent_rewards: Array = []   # 최근 reward 사건
var last_report_path := ""

var _f: FileAccess
var _ids := {}                   # name -> id(정수)
var _stats := {}                 # name -> {"shots", "hits", "pens", "kills", "dist"}
var _last_pos := {}


func _init() -> void:
	# 전차가 그 틱의 이동·사격을 끝낸 뒤 기록하도록 늦게 처리
	process_physics_priority = 100


## 기록 시작. tanks 는 Tank 노드 배열(순서 = id). 이미 트리에 들어간 뒤 호출.
func start(p_map: HillMap, p_tanks: Array, p_meta := {}, p_rewards: RewardModel = null) -> void:
	map = p_map
	if map and not map.obstacle_destroyed.is_connected(_on_obstacle_destroyed):
		map.obstacle_destroyed.connect(_on_obstacle_destroyed)
	tanks = p_tanks
	meta = p_meta
	if p_rewards:
		rewards = p_rewards
	for i in tanks.size():
		var t: Tank = tanks[i]
		_ids[t.name] = i
		tank_scores[t.name] = 0.0
		paths[t.name] = PackedVector3Array([t.global_position])
		_stats[t.name] = {"shots": 0, "hits": 0, "pens": 0, "kills": 0, "dist": 0.0}
		_last_pos[t.name] = t.global_position
		t.shot_fired.connect(_on_shot)
		t.knocked_out.connect(_on_knocked_out)
	episode = _next_episode_number()
	if write_files:
		var stamp := Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
		dir = "%s/replays/ep%04d_%s" % [log_root, episode, stamp]
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
		events_path = dir + "/events.jsonl"
		_f = FileAccess.open(events_path, FileAccess.WRITE)
	_write(_header())
	_write_frame()


func sim_time() -> float:
	return float(tick) / Engine.physics_ticks_per_second


func tank_id(t: Tank) -> int:
	return _ids.get(t.name, -1)


func _physics_process(delta: float) -> void:
	if ended or tanks.is_empty():
		return
	tick += 1
	for t in tanks:
		if t.damage.is_combat_effective() and not external_rewards:
			_add_reward(rewards.time_reward(t.name, t.team, delta), false)
	if tick % sample_every == 0:
		_write_frame()
	if tick % Engine.physics_ticks_per_second == 0:
		score_history.append([sim_time(), team_scores[0], team_scores[1]])
	_check_end()


func _on_obstacle_destroyed(event: Dictionary) -> void:
	if not ended:
		_write({"type": "obstacle_destroyed", "tick": tick, "t": snappedf(sim_time(), 0.001), "event": event})


func _check_end() -> void:
	if not auto_end:
		return
	var alive := [0, 0]
	for t in tanks:
		if t.damage.is_combat_effective():
			alive[t.team] += 1
	if alive[0] == 0 or alive[1] == 0:
		end_episode("elimination", -1 if alive[0] == alive[1] else (0 if alive[0] > 0 else 1))
	elif time_limit_s > 0.0 and sim_time() >= time_limit_s:
		end_episode("time_limit", -1)


## 에피소드 종료(전멸·시간초과 시 자동, 사람이 수동으로도 호출 가능). 보고서 경로를 돌려준다.
func end_episode(reason: String, p_winner := -1) -> String:
	if ended:
		return last_report_path
	_write_frame()
	ended = true
	winner = p_winner
	end_reason = reason
	if not external_rewards:
		for e in rewards.end_rewards(tanks, winner):
			_add_reward(e, true)
	var summary := summary_dict()
	_write({"type": "end", "tick": tick, "t": snappedf(sim_time(), 0.001), "reason": reason,
		"winner": winner, "summary": summary, "final": tanks.map(func(t): return t.state_dict())})
	if _f:
		_f.close()
		_f = null
		_append_episode_index(summary)
		if write_report:
			last_report_path = ReportBuilder.build_files(events_path, episodes_index_path())
	episode_ended.emit(summary)
	return last_report_path


func summary_dict() -> Dictionary:
	var per := []
	for t in tanks:
		var s: Dictionary = _stats[t.name]
		per.append({"id": _ids[t.name], "name": t.name, "tank": t.spec.id, "team": t.team,
			"status": t.damage.status_label(), "score": snappedf(tank_scores[t.name], 0.001),
			"shots": s.shots, "hits": s.hits, "pens": s.pens, "kills": s.kills,
			"distance_m": snappedf(s.dist, 0.1)})
	return {"episode": episode, "duration_s": snappedf(sim_time(), 0.01), "reason": end_reason,
		"winner": winner, "team_scores": [snappedf(team_scores[0], 0.001), snappedf(team_scores[1], 0.001)],
		"tanks": per}


## AI 관측·행동·판단 기록. obs/action 은 숫자 배열, info 는 자유 형식(가치 추정, 목표, 설명 등).
func log_decision(t: Tank, obs, action, info := {}) -> void:
	_write({"type": "decision", "tick": tick, "t": snappedf(sim_time(), 0.001), "tank": tank_id(t),
		"obs": Array(obs).map(func(v): return snappedf(v, 0.001)),
		"action": Array(action).map(func(v): return snappedf(v, 0.0001)), "info": info})


func episodes_index_path() -> String:
	return log_root + "/episodes.csv"


# ---------------------------------------------------------------- 내부

func _header() -> Dictionary:
	var tl := []
	for t in tanks:
		tl.append({"id": _ids[t.name], "name": t.name, "tank": t.spec.id, "display_name": t.spec.display_name,
			"team": t.team, "nation": t.spec.nation, "hull_size": TankSpec._v(t.spec.hull_size),
			"hull_bottom_y": t.spec.hull_bottom_y, "turret_size": TankSpec._v(t.spec.turret_size),
			"turret_origin": TankSpec._v(t.spec.turret_origin()), "caliber_mm": t.spec.gun.caliber_mm,
			"rng_seed": t.rng.seed, "initial": t.state_dict()})
	return {"type": "header", "format": FORMAT, "version": FORMAT_VERSION, "episode": episode,
		"created": Time.get_datetime_string_from_system(), "engine": Engine.get_version_info().string,
		"physics_hz": Engine.physics_ticks_per_second, "sample_every": sample_every,
		"frame_fields": FRAME_FIELDS, "action_labels": TankControlInput.ACTION_LABELS,
		"agent_action_labels": TankAgent.action_labels(), "observation_labels": observation_labels if not observation_labels.is_empty() else TankPerception.labels(),
		"teams": ["Germany", "Allies"], "reward_weights": rewards.weights, "time_limit_s": time_limit_s,
		"score_source": "training" if external_rewards else "game",
		"meta": meta, "map": map.to_record() if map else {}, "tanks": tl}


func _write_frame() -> void:
	var s := []
	for t in tanks:
		var tr: Transform3D = t.global_transform
		var q := tr.basis.get_rotation_quaternion()
		var a: PackedFloat32Array = t.control.to_array()
		s.append([snappedf(tr.origin.x, 0.001), snappedf(tr.origin.y, 0.001), snappedf(tr.origin.z, 0.001),
			snappedf(q.x, 0.0001), snappedf(q.y, 0.0001), snappedf(q.z, 0.0001), snappedf(q.w, 0.0001),
			snappedf(t.turret_yaw, 0.0001), snappedf(t.gun_pitch, 0.0001),
			snappedf(t.track_speed_left, 0.01), snappedf(t.track_speed_right, 0.01),
			status_code(t.damage), t.ammo_index, snappedf(t.reload_timer, 0.01),
			snappedf(a[0], 0.001), snappedf(a[1], 0.001), snappedf(a[2], 0.001),
			snappedf(a[3], 0.001), snappedf(a[4], 0.001), a[5]])
		var v: TankView = views.get(t.name)
		var vs: Array = v.state_array(t) if v else [0, 0.0, 0.0, TankView.THIRD_FOV]
		s[-1].append_array([vs[0], snappedf(vs[1], 0.001), snappedf(vs[2], 0.001), snappedf(vs[3], 0.01)])
		var p: Vector3 = tr.origin
		_stats[t.name].dist += Vector2(p.x, p.z).distance_to(Vector2(_last_pos[t.name].x, _last_pos[t.name].z))
		_last_pos[t.name] = p
		if (tick / sample_every) % path_every == 0:
			paths[t.name].append(p)
	var frame := {"type": "frame", "tick": tick, "t": snappedf(sim_time(), 0.001), "s": s,
		"destroyed": map.destruction.destroyed_ids() if map else [],
		"score": [snappedf(team_scores[0], 0.001), snappedf(team_scores[1], 0.001)],
		"r": tanks.map(func(t): return snappedf(tank_scores[t.name], 0.001))}
	if projectile_field != null:
		frame["projectiles"] = projectile_field.snapshot()
	_write(frame)


static func status_code(d: TankDamageState) -> int:
	if d.is_destroyed():
		return STATUS_DESTROYED
	if d.is_knocked_out():
		return STATUS_KO
	if not d.can_move() or not d.can_fire():
		return STATUS_DAMAGED
	return STATUS_OK


func _on_shot(shooter: Tank, r: Dictionary) -> void:
	if ended:
		return
	var target_name: String = r.get("target_name", "")
	var target_team: int = r.get("target_team", -1)
	var st: Dictionary = _stats[shooter.name]
	st.shots += 1
	if r.get("hit", false):
		st.hits += 1
		if r.get("penetrated", false):
			st.pens += 1
		for ev in r.get("events", []):
			if str(ev).begins_with("knocked_out:") and target_team != shooter.team:
				st.kills += 1
	var e := {"type": "shot", "tick": tick, "t": snappedf(sim_time(), 0.001), "shooter": _ids[shooter.name],
		"target": _ids.get(target_name, -1), "r": r}
	_write(e)
	var from := _vec(r.get("from", []))
	var to: Vector3 = _vec(r.hit_pos) if r.has("hit_pos") else from + _vec(r.get("dir", [0, 0, -1])) * 600.0
	shots.append({"t": sim_time(), "from": from, "to": to, "kind": shot_kind(r), "shooter_team": shooter.team})
	if shots.size() > 300:
		shots.pop_front()
	shot_recorded.emit(e)
	if not external_rewards:
		for re in rewards.shot_rewards(shooter.name, shooter.team, target_name, target_team, r):
			_add_reward(re, true)


func training_reward(tank: String, team: int, value: float, reason: String) -> void:
	if external_rewards and not ended:
		_add_reward({"tank": tank, "team": team, "value": value, "reason": reason}, true)


## 탄착 종류: penetration / non_penetration / ricochet / blocked / miss
static func shot_kind(r: Dictionary) -> String:
	if r.get("hit", false):
		if r.get("penetrated", false):
			return "penetration"
		return "ricochet" if r.get("ricochet", false) else "non_penetration"
	return "miss" if r.get("blocked_by", "none") == "none" else "blocked"


func _on_knocked_out(t: Tank, cause: String) -> void:
	if ended:
		return
	_write({"type": "knockout", "tick": tick, "t": snappedf(sim_time(), 0.001), "tank": _ids[t.name],
		"cause": cause, "state": t.state_dict()})


func _add_reward(e: Dictionary, log_it: bool) -> void:
	if e.value == 0.0:
		return
	tank_scores[e.tank] = tank_scores.get(e.tank, 0.0) + e.value
	team_scores[e.team] += e.value
	if log_it:
		var line := e.duplicate()
		line["type"] = "reward"
		line["tick"] = tick
		line["t"] = snappedf(sim_time(), 0.001)
		line["tank"] = _ids.get(e.tank, -1)
		line["tank_name"] = e.tank
		_write(line)
		recent_rewards.append(line)
		if recent_rewards.size() > 8:
			recent_rewards.pop_front()
		reward_added.emit(line)


func _write(d: Dictionary) -> void:
	if _f:
		_f.store_line(JSON.stringify(d))


## 다음 에피소드 번호 = 기록 폴더 수 + 1 (중단된 경기도 번호를 차지)
func _next_episode_number() -> int:
	var da := DirAccess.open(log_root + "/replays")
	return (da.get_directories().size() if da else 0) + 1


func _append_episode_index(s: Dictionary) -> void:
	var p := episodes_index_path()
	var exists := FileAccess.file_exists(p)
	var f := FileAccess.open(p, FileAccess.READ_WRITE if exists else FileAccess.WRITE)
	if f == null:
		return
	if exists:
		f.seek_end()
	else:
		f.store_line("episode,date,duration_s,reason,winner,score_team0,score_team1,alive_team0,alive_team1,kills_team0,kills_team1,dir")
	var alive := [0, 0]
	var kills := [0, 0]
	for t in s.tanks:
		if t.status != "knocked_out" and t.status != "destroyed":
			alive[t.team] += 1
		kills[t.team] += t.kills
	f.store_line("%d,%s,%.2f,%s,%d,%.3f,%.3f,%d,%d,%d,%d,%s" % [s.episode, Time.get_datetime_string_from_system(),
		s.duration_s, s.reason, s.winner, s.team_scores[0], s.team_scores[1], alive[0], alive[1],
		kills[0], kills[1], dir.get_file()])
	f.close()


static func _vec(a) -> Vector3:
	return Vector3(a[0], a[1], a[2]) if a is Array and a.size() >= 3 else Vector3.ZERO
