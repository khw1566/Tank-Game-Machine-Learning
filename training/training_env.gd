extends Node3D
## 강화학습 환경(헤드리스 Godot ↔ Python). 커리큘럼 단계·보상·종료 조건은 Python 이 reset 설정으로 넘기고,
## 이 씬은 그 설정대로 맵·전차를 놓고 lockstep 으로 시뮬레이션한다. 규격은 training/README.md.
##
## 실행(보통 Python 이 띄움):
##   godot --headless --fixed-fps 30 --path . -- --train --port=11008 [--env-id=0] [--log-dir=절대경로]
## 재현(지난 학습 에피소드를 똑같이 다시 돌려 전체 기록·보고서·관측을 만든다):
##   godot --headless --fixed-fps 30 --path . -- --reproduce=<에피소드.json> [--out-dir=폴더] [--log-obs=1]
##
## 재현 가능성: 에피소드 하나는 (reset 설정 + 시드 + 결정마다의 외부 행동)으로 완전히 결정된다.
## 맵·출발 위치·전차 rng·움직이는 표적은 모두 config.seed 에서 나오고, 규칙 AI 는 난수를 쓰지 않는다.
## 외부(Python) 행동은 1/127 단위로 양자화한 값을 그대로 적용·저장하므로 다시 넣으면 같은 결과가 나온다.
## 끝 상태 해시(final_hash)로 재현이 맞았는지 확인한다.

const PROTOCOL := "tankgame-train"
const PROTOCOL_VERSION := 1
const EPISODE_FORMAT := "tankgame-train-episode"
## 결정(행동 선택) 간격 = 관측 갱신 간격(3틱 = 0.1초, 10Hz)
const REPEAT := TankAgent.PERCEIVE_EVERY
const TASK_SIZE := 8
const TASK_LABELS := ["task.has_waypoint", "task.wp_bearing_sin", "task.wp_bearing_cos", "task.wp_dist",
	"task.time_left", "task.kind_drive", "task.kind_gunnery", "task.kind_combat"]
const ACT_SIZE := TankAgent.ACTION_SIZE
const KINDS := ["drive", "gunnery", "combat"]
const TEAM_BASE_SIGN := [1.0, -1.0]   # 팀0(독일) = +축 쪽, 팀1(연합군) = -축 쪽 (main 과 같음)

static func obs_size() -> int:
	return TankPerception.size() + TASK_SIZE


static func obs_labels() -> Array:
	return TankPerception.labels() + TASK_LABELS


var port := 11008
var env_id := 0
var log_dir := "user://logs/training"
var _peer: StreamPeerTCP
var _headless := DisplayServer.get_name() == "headless"

# 에피소드 상태
var config := {}
var map: HillMap
var _map_key := ""
var tanks: Array = []
var agents: Array = []
var ctrls: Array = []          # 전차별 "external" | "scripted" | "mover" | "static"
var drivers := {}              # 전차 이름 -> TargetDriver
var ext: Array = []            # 외부 조종 전차 인덱스(순서 = Python 행동 순서)
var sounds := SoundField.new()
var rewarder: TrainingReward
var recorder: MatchRecorder
var waypoint := Vector3.INF
var tick := 0
var decisions := 0
var active := false
var done := false
var time_limit_ticks := 0
var view_lock := -1
var _last_actions: Array = []    # ext 순서, 각 11개(양자화·변환된 값)
var _act_bytes := PackedByteArray()
var _rew_bytes := PackedByteArray()
var _shots: Array = []
var _paths: Array = []
var _end := {}

# 재현 모드
var _repro := {}
var _repro_actions := PackedByteArray()
var _repro_i := 0
var _repro_out := ""
var _log_obs_every := 1
## 기록(record) 에피소드의 판단 기록 간격(틱). 학습 중 = 0.5초, 재현 = 매 결정(0.1초)
var _log_ticks := REPEAT * 5


func _init() -> void:
	# 전차보다 먼저: 이번 틱의 행동을 정한 뒤 전차가 움직인다
	process_physics_priority = -10


func _ready() -> void:
	var repro_path := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--port="):
			port = int(a.get_slice("=", 1))
		elif a.begins_with("--env-id="):
			env_id = int(a.get_slice("=", 1))
		elif a.begins_with("--log-dir="):
			log_dir = a.get_slice("=", 1)
		elif a.begins_with("--reproduce="):
			repro_path = a.get_slice("=", 1)
		elif a.begins_with("--out-dir="):
			_repro_out = a.get_slice("=", 1)
		elif a.begins_with("--log-obs="):
			_log_obs_every = int(a.get_slice("=", 1))
	if repro_path != "":
		_start_reproduce(repro_path)
		return
	_peer = StreamPeerTCP.new()
	if _peer.connect_to_host("127.0.0.1", port) != OK:
		push_error("training: cannot connect to port %d" % port)
		get_tree().quit(2)
		return
	var waited := 0
	while _peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and waited < 20000:
		_peer.poll()
		OS.delay_msec(1)
		waited += 1
	if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("training: connection to port %d failed" % port)
		get_tree().quit(2)
		return
	_peer.set_no_delay(true)
	_send({"type": "hello", "protocol": PROTOCOL, "version": PROTOCOL_VERSION, "env_id": env_id,
		"obs_size": obs_size(), "act_size": ACT_SIZE, "obs_labels": obs_labels(),
		"action_labels": TankAgent.action_labels(), "physics_hz": Engine.physics_ticks_per_second,
		"repeat": REPEAT, "engine": Engine.get_version_info().string})
	_serve()   # 첫 reset 을 받을 때까지 대기


# ================================================================ 통신

func _send(header: Dictionary, bin := PackedByteArray()) -> void:
	var j := JSON.stringify(header).to_utf8_buffer()
	var buf := StreamPeerBuffer.new()
	buf.big_endian = false
	buf.put_u32(j.size())
	buf.put_data(j)
	buf.put_u32(bin.size())
	buf.put_data(bin)
	_peer.put_data(buf.data_array)


func _read_exact(n: int) -> PackedByteArray:
	var out := PackedByteArray()
	while out.size() < n:
		_peer.poll()
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return PackedByteArray()
		var avail := _peer.get_available_bytes()
		if avail <= 0:
			OS.delay_usec(20)
			continue
		var r := _peer.get_partial_data(mini(avail, n - out.size()))
		if r[0] != OK:
			return PackedByteArray()
		out.append_array(r[1])
	return out


func _u32(b: PackedByteArray) -> int:
	return b.decode_u32(0) if b.size() >= 4 else -1


## 메시지 하나: {header, bin}. 연결이 끊기면 {}
func _recv() -> Dictionary:
	var n := _u32(_read_exact(4))
	if n < 0:
		return {}
	var j := _read_exact(n).get_string_from_utf8()
	var m := _u32(_read_exact(4))
	if m < 0:
		return {}
	var bin := _read_exact(m) if m > 0 else PackedByteArray()
	var h = JSON.parse_string(j)
	return {"header": h if h is Dictionary else {}, "bin": bin}


## step 을 받을 때까지 메시지를 처리한다(reset 은 처리 후 관측을 보내고 계속 대기)
func _serve() -> void:
	while true:
		var msg := _recv()
		if msg.is_empty():
			print("training env %d: python disconnected" % env_id)
			get_tree().quit()
			set_physics_process(false)
			return
		var h: Dictionary = msg.header
		match str(h.get("type", "")):
			"reset":
				reset_episode(h.get("config", {}))
				_send_obs(0)
			"step":
				if not active or done:
					_send({"type": "error", "message": "step without active episode"})
					continue
				_apply_external(msg.bin)
				return
			"close":
				_finish_files("closed")
				get_tree().quit()
				set_physics_process(false)
				return
			"ping":
				_send({"type": "pong"})
			_:
				_send({"type": "error", "message": "unknown message %s" % h.get("type", "")})


func _send_obs(nrew: int) -> void:
	var obs := PackedFloat32Array()
	var meta := []
	for k in ext.size():
		var i: int = ext[k]
		var t: Tank = tanks[i]
		obs.append_array(_observation(i))
		meta.append({"name": t.name, "tank": t.spec.id, "team": t.team,
			"alive": t.damage.is_combat_effective(),
			"reward": rewarder.taken(t.name) if nrew > 0 else 0.0})
	var h := {"type": "obs", "tick": tick, "decision": decisions, "done": done, "agents": meta}
	if done:
		h["episode"] = _end
	_send(h, obs.to_byte_array())


# ================================================================ 에피소드

## config 키(모두 선택, 기본값 있음):
##   seed, uid, kind("drive"|"gunnery"|"combat"), stage, time_limit_s, view_lock(-1|0|1|2)
##   map: {seed, features, amplitude}
##   tanks: [{type, team, ctrl("external"|"scripted"|"mover"|"static")}]
##   spawn: {distance:[min,max], spacing, axis_jitter_deg, yaw_jitter_deg, random_yaw(bool), center_jitter}
##   waypoint: {distance:[min,max], radius}   (drive)
##   reward: TrainingReward 가중치 덮어쓰기
##   success_hits, record(bool: 전체 리플레이·보고서 기록), meta(자유: 모델 버전 등 기록용)
func reset_episode(p_config: Dictionary) -> void:
	_finish_files("reset")
	config = p_config.duplicate(true)
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.get("seed", 1))
	config["seed"] = rng.seed
	_ensure_map(config.get("map", {}))
	_clear_tanks()
	sounds = SoundField.new()
	tick = 0
	decisions = 0
	done = false
	_end = {}
	_shots.clear()
	_paths.clear()
	_act_bytes = PackedByteArray()
	_rew_bytes = PackedByteArray()
	view_lock = int(config.get("view_lock", -1))
	time_limit_ticks = int(float(config.get("time_limit_s", 60.0)) * Engine.physics_ticks_per_second)
	var specs: Array = config.get("tanks", [{"type": "tiger1", "team": 0, "ctrl": "external"}])
	_spawn_all(specs, rng)
	waypoint = Vector3.INF
	var kind := str(config.get("kind", "combat"))
	if kind == "drive":
		waypoint = _pick_waypoint(rng)
	elif kind == "combat":
		# 목표 = 적 출발 지역(맵 공개 정보). 도착 보너스는 없다
		waypoint = Vector3.INF
	rewarder = TrainingReward.new(self, config.get("reward", {}))
	rewarder.start()
	ext.clear()
	_last_actions.clear()
	for i in tanks.size():
		if ctrls[i] == "external":
			ext.append(i)
			_last_actions.append(_neutral_action())
	if bool(config.get("record", false)):
		_start_recorder()
	active = true
	for ag in agents:
		ag.update(tanks, 0.0)
	_record_path_point()


func _neutral_action() -> Array:
	var a := []
	a.resize(ACT_SIZE)
	a.fill(0.0)
	a[2] = 1.0
	return a


func _ensure_map(mc: Dictionary) -> void:
	var key := JSON.stringify([int(mc.get("seed", 1)), bool(mc.get("features", false)), float(mc.get("amplitude", 15.0))])
	if key == _map_key and map != null:
		return
	if map:
		remove_child(map)
		map.free()
	map = HillMap.new()
	map.map_seed = int(mc.get("seed", 1))
	map.features_enabled = bool(mc.get("features", false))
	map.height_amplitude = float(mc.get("amplitude", 15.0))
	add_child(map)
	_map_key = key


func _clear_tanks() -> void:
	if recorder:
		remove_child(recorder)
		recorder.free()
		recorder = null
	for t in tanks:
		remove_child(t)
		t.free()
	tanks.clear()
	agents.clear()
	ctrls.clear()
	drivers.clear()


## 팀별로 축 양 끝에 놓는다. 축 방향·중심·간격은 시드로 흔든다.
func _spawn_all(specs: Array, rng: RandomNumberGenerator) -> void:
	var sp: Dictionary = config.get("spawn", {})
	var dr: Array = sp.get("distance", [300.0, 300.0])
	var dist := rng.randf_range(float(dr[0]), float(dr[1]))
	config["spawn_distance_m"] = snappedf(dist, 0.01)
	var axis_yaw := deg_to_rad(rng.randf_range(-1.0, 1.0) * float(sp.get("axis_jitter_deg", 0.0)))
	var cj := float(sp.get("center_jitter", 100.0))
	var center := Vector2(rng.randf_range(-cj, cj), rng.randf_range(-cj, cj))
	var axis := Vector2(sin(axis_yaw), cos(axis_yaw))   # 팀0 쪽 방향(+Z 기준 회전)
	var side := Vector2(axis.y, -axis.x)
	var spacing := float(sp.get("spacing", 25.0))
	var per_team := [[], []]
	for s in specs:
		per_team[int(s.get("team", 0))].append(s)
	var bases := [center + axis * dist * 0.5, center - axis * dist * 0.5]
	var idx := 0
	for team in 2:
		var n: int = per_team[team].size()
		for j in n:
			var s: Dictionary = per_team[team][j]
			var p: Vector2 = bases[team] + side * (j - (n - 1) * 0.5) * spacing
			p = _clear_spot(p, rng)
			var face: Vector2 = bases[1 - team] - p if n > 0 else -axis
			var yaw := atan2(-face.x, -face.y)
			if bool(sp.get("random_yaw", false)) and (s.get("ctrl", "") != "external" or bool(sp.get("random_yaw_learner", false))):
				yaw = rng.randf_range(-PI, PI)
			else:
				yaw += deg_to_rad(rng.randf_range(-1.0, 1.0) * float(sp.get("yaw_jitter_deg", 15.0)))
			_spawn_one(str(s.get("type", "tiger1")), team, p, yaw, rng.randi_range(1, 2147483646), str(s.get("ctrl", "scripted")), idx)
			idx += 1
	# 규칙 AI 는 적 진영 위치(공개 정보)를 안다
	var team_idx := [0, 0]
	for i in tanks.size():
		var t: Tank = tanks[i]
		var b: Vector2 = bases[1 - t.team]
		var ai := ScriptedAI.for_tank(t, team_idx[t.team], Vector3(b.x, 0, b.y))
		team_idx[t.team] += 1
		agents.append(TankAgent.new(map, t, sounds, ai))
		if ctrls[i] == "mover":
			var d := TargetDriver.new(rng.randi_range(1, 2147483646), map.size_m * 0.5)
			drivers[t.name] = d


func _clear_spot(p: Vector2, rng: RandomNumberGenerator) -> Vector2:
	var half := map.size_m * 0.5 - 40.0
	p = Vector2(clampf(p.x, -half, half), clampf(p.y, -half, half))
	if map.is_clear(p, 7.0):
		return p
	for k in 40:
		var q := p + Vector2(rng.randf_range(-1, 1), rng.randf_range(-1, 1)) * (10.0 + k * 3.0)
		q = Vector2(clampf(q.x, -half, half), clampf(q.y, -half, half))
		if map.is_clear(q, 7.0):
			return q
	return p


func _spawn_one(id: String, team: int, p: Vector2, yaw: float, seed_v: int, ctrl: String, idx: int) -> void:
	var t := Tank.new()
	t.name = "%s_%d" % [id, idx]
	t.setup(id, team, seed_v)
	t.position = Vector3(p.x, map.height_at(p.x, p.y) + 0.5, p.y)
	t.rotation.y = yaw
	add_child(t)
	t.shot_fired.connect(_on_shot)
	t.shot_fired.connect(sounds.on_shot)
	tanks.append(t)
	ctrls.append(ctrl)


func _pick_waypoint(rng: RandomNumberGenerator) -> Vector3:
	var learner: Tank = tanks[0]
	for i in tanks.size():
		if ctrls[i] == "external":
			learner = tanks[i]
			break
	var wc: Dictionary = config.get("waypoint", {})
	var dr: Array = wc.get("distance", [80.0, 250.0])
	var half := map.size_m * 0.5 - 60.0
	var from := Vector2(learner.global_position.x, learner.global_position.z)
	var best := from + Vector2(0, -float(dr[0]))
	for k in 30:
		var d := rng.randf_range(float(dr[0]), float(dr[1]))
		var a := rng.randf_range(-PI, PI)
		var q := from + Vector2(sin(a), cos(a)) * d
		if absf(q.x) < half and absf(q.y) < half and map.is_clear(q, 10.0):
			best = q
			break
	return Vector3(best.x, map.height_at(best.x, best.y), best.y)


func _start_recorder() -> void:
	recorder = MatchRecorder.new()
	recorder.auto_end = false
	recorder.time_limit_s = 0.0
	recorder.log_root = _record_root()
	var views := {}
	for i in tanks.size():
		views[tanks[i].name] = agents[i].view
	recorder.views = views
	add_child(recorder)
	recorder.start(map, tanks, {"scene": "training", "training": _config_for_record(),
		"controllers": ctrls, "observation": "perception_v1+task", "lineup": tanks.map(func(t): return t.spec.id)},
		RewardModel.new(config.get("reward", {}).get("combat", {})))


func _record_root() -> String:
	if _repro_out != "":
		return _repro_out
	return "%s/env%d" % [log_dir, env_id]


func _config_for_record() -> Dictionary:
	var c := config.duplicate(true)
	c["env_id"] = env_id
	return c


# ================================================================ 시뮬레이션

func _physics_process(dt: float) -> void:
	if not active:
		return
	if not _repro.is_empty():
		_repro_tick(dt)
		return
	# 결정 시점(첫 결정은 reset 직후 _serve 안에서 이미 받음): 보상·종료 판정 → 관측 전송 → 다음 행동 수신
	if tick > 0 and tick % REPEAT == 0:
		_evaluate()
		if done:
			_finish_files("done")   # 에피소드 파일·리플레이 경로를 결과에 넣은 뒤 보낸다
		_send_obs(1)
		_serve()   # step 을 받을 때까지(끝났으면 reset → 새 에피소드 첫 step)
		if not active:
			return
	_advance(dt)


func _evaluate() -> void:
	var r := rewarder.decision()
	var f := PackedFloat32Array()
	for k in ext.size():
		f.append(rewarder.pending(tanks[ext[k]].name))
	_rew_bytes.append_array(f.to_byte_array())
	if r.done:
		done = true
		_end = r
		_end["ticks"] = tick
		_end["decisions"] = decisions
		_end["duration_s"] = snappedf(float(tick) / Engine.physics_ticks_per_second, 0.01)
		_end["final_hash"] = final_hash()
		_end["uid"] = str(config.get("uid", ""))
		_end["stage"] = str(config.get("stage", ""))
		_end["seed"] = int(config.get("seed", 0))
		_end["spawn_distance_m"] = config.get("spawn_distance_m", 0.0)
		_end["tanks"] = tanks.map(func(t): return {"name": t.name, "tank": t.spec.id, "team": t.team,
			"status": t.damage.status_label(), "return": snappedf(rewarder.total(t.name), 0.0001),
			"shots": t.shots_fired, "hits": rewarder.hits.get(t.name, 0), "pens": rewarder.pens.get(t.name, 0),
			"kills": rewarder.kills.get(t.name, 0)})


func _apply_external(bin: PackedByteArray) -> void:
	var f := bin.to_float32_array()
	var q := PackedByteArray()
	q.resize(ext.size() * ACT_SIZE)
	for k in ext.size():
		var raw := []
		for j in ACT_SIZE:
			var v := clampf(f[k * ACT_SIZE + j] if k * ACT_SIZE + j < f.size() else 0.0, -1.0, 1.0)
			var qi := roundi(v * 127.0)
			q.encode_s8(k * ACT_SIZE + j, qi)
			raw.append(qi / 127.0)
		_last_actions[k] = policy_to_action(raw, view_lock)
	_act_bytes.append_array(q)
	decisions += 1


## 정책 출력(모두 -1~1) → 에이전트 행동 11개. 이산 항목은 구간으로 나눈다.
static func policy_to_action(r: Array, lock := -1) -> Array:
	var a := r.duplicate()
	a[2] = maxf(float(r[2]), 0.0)                              # brake: 0 이하 = 안 밟음, 0~1
	a[5] = 1.0 if float(r[5]) > 0.0 else 0.0                   # fire
	a[6] = 0.0 if float(r[6]) < -1.0 / 3.0 else (1.0 if float(r[6]) < 1.0 / 3.0 else 2.0)   # view_mode
	a[7] = 1.0 if float(r[7]) > 0.0 else 0.0                   # free_look
	if lock >= 0:
		a[6] = float(lock)
		a[7] = 0.0
	return a


## 모든 전차 한 틱(외부 = 직전 결정 유지, 나머지 = 규칙 AI·표적 조종사·정지)
func _advance(dt: float) -> void:
	sounds.advance(dt)
	var log_now := recorder != null and tick % _log_ticks == 0
	for i in tanks.size():
		var t: Tank = tanks[i]
		var ag: TankAgent = agents[i]
		var alive := t.damage.is_combat_effective()
		var a: Array = []
		match ctrls[i]:
			"external":
				ag.update(tanks, dt)
				a = _last_actions[ext.find(i)]
				ag.apply_action(a, dt)
			"scripted":
				if alive:
					a = ag.step_ai(tanks, dt)
				else:
					ag.update(tanks, dt)
			"mover":
				ag.update(tanks, dt)
				a = drivers[t.name].act(t, dt) if alive else []
				t.control = TankControlInput.from_array(a) if alive else TankControlInput.new()
			_:
				ag.update(tanks, dt)
				t.control = TankControlInput.new()
		if log_now and alive and not a.is_empty():
			var info := {"controller": ctrls[i], "stage": config.get("stage", ""), "perception": ag.perception.summary()}
			if ctrls[i] == "external":
				info["policy"] = config.get("meta", {}).get("policies", {}).get(t.name, "")
				info["reward_total"] = snappedf(rewarder.total(t.name), 0.0001)
			elif ctrls[i] == "scripted":
				info.merge(ag.ai.last_info)
			var obs := _observation(i) if _log_obs_every > 0 and (tick / _log_ticks) % _log_obs_every == 0 else PackedFloat32Array()
			recorder.log_decision(t, obs, a, info)
	tick += 1
	if tick % Engine.physics_ticks_per_second == 0:
		_record_path_point()


func _observation(i: int) -> PackedFloat32Array:
	var t: Tank = tanks[i]
	var o: PackedFloat32Array = agents[i].perception.vector.duplicate()
	if o.size() != TankPerception.size():
		o.resize(TankPerception.size())
	var task := PackedFloat32Array()
	task.resize(TASK_SIZE)
	var kind := str(config.get("kind", "combat"))
	var wp := _task_waypoint(t)
	if wp != Vector3.INF:
		var d := wp - t.global_position
		var b := wrapf(atan2(-d.x, -d.z) - t.global_rotation.y, -PI, PI)
		task[0] = 1.0
		task[1] = sin(b)
		task[2] = cos(b)
		task[3] = clampf(Vector2(d.x, d.z).length() / 500.0, 0.0, 2.0) * 0.5 if kind == "drive" else 0.0
	task[4] = clampf(1.0 - float(tick) / maxf(time_limit_ticks, 1.0), 0.0, 1.0)
	task[5 + maxi(KINDS.find(kind), 0)] = 1.0
	o.append_array(task)
	return o


## 임무 방향: 주행 = 웨이포인트, 전투 = 적 출발 지역(공개 정보), 사격 = 표적이 있는 방향(사수에게 지시된 구역)
func _task_waypoint(t: Tank) -> Vector3:
	if waypoint != Vector3.INF:
		return waypoint
	var kind := str(config.get("kind", "combat"))
	if kind == "drive":
		return Vector3.INF
	var sum := Vector3.ZERO
	var n := 0
	for o in tanks:
		if o.team != t.team:
			sum += o.global_position if kind == "gunnery" else _start_pos.get(o.name, o.global_position)
			n += 1
	return sum / n if n > 0 else Vector3.INF

var _start_pos := {}


func _record_path_point() -> void:
	if _start_pos.is_empty() or tick == 0:
		_start_pos.clear()
		for t in tanks:
			_start_pos[t.name] = t.global_position
	var row := [snappedf(float(tick) / Engine.physics_ticks_per_second, 0.01)]
	for t in tanks:
		row.append_array([snappedf(t.global_position.x, 0.1), snappedf(t.global_position.z, 0.1),
			snappedf(rad_to_deg(t.global_rotation.y), 0.1), MatchRecorder.status_code(t.damage)])
	_paths.append(row)


func _on_shot(shooter: Tank, r: Dictionary) -> void:
	if rewarder:
		rewarder.on_shot(shooter, r)
	var e := {"t": snappedf(float(tick) / Engine.physics_ticks_per_second, 0.01), "shooter": shooter.name,
		"target": r.get("target_name", ""), "hit": r.get("hit", false), "shell": r.get("shell", "")}
	if r.get("hit", false):
		e.merge({"zone": r.get("zone", ""), "penetrated": r.get("penetrated", false), "ricochet": r.get("ricochet", false),
			"effective_mm": r.get("effective_mm", 0), "distance_m": snappedf(float(r.get("distance", 0.0)), 0.1),
			"events": r.get("events", [])})
	else:
		e["blocked_by"] = r.get("blocked_by", "")
	_shots.append(e)


## 끝 상태 요약 해시(재현 검증용)
func final_hash() -> String:
	var parts := []
	for t in tanks:
		var p: Vector3 = t.global_position
		parts.append("%s:%.3f,%.3f,%.3f,%.4f,%.4f,%s,%d,%d" % [t.name, p.x, p.y, p.z, t.turret_yaw, t.gun_pitch,
			t.damage.status_label(), t.damage.ammo_remaining, t.shots_fired])
	return ("|".join(parts)).md5_text()


# ================================================================ 기록 파일

## 에피소드 파일: 재현에 필요한 모든 것(설정·시드·행동) + 보고서용 요약(사격·동선·보상)
func _finish_files(reason: String) -> void:
	if not active:
		return
	active = false
	if _end.is_empty():
		_end = {"done": true, "reason": reason, "success": false, "winner": -1, "ticks": tick, "decisions": decisions,
			"final_hash": final_hash(), "uid": str(config.get("uid", "")), "stage": str(config.get("stage", ""))}
	if recorder and not recorder.ended:
		recorder.meta["training_end"] = _end
		recorder.end_episode("training_" + str(_end.get("reason", reason)), int(_end.get("winner", -1)))
		_end["replay_dir"] = recorder.dir
	if not _repro.is_empty():
		return
	if not bool(config.get("save_episode", true)):
		return
	var dir := "%s/episodes/env%d" % [log_dir, env_id]
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir) if dir.begins_with("user://") else dir)
	var uid := str(config.get("uid", "ep%d" % Time.get_ticks_msec()))
	var path := "%s/%s.json" % [dir, uid.validate_filename()]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("training: cannot write %s" % path)
		return
	f.store_string(JSON.stringify({"format": EPISODE_FORMAT, "version": 1, "protocol": PROTOCOL_VERSION,
		"engine": Engine.get_version_info().string, "created": Time.get_datetime_string_from_system(),
		"env_id": env_id, "config": config, "repeat": REPEAT, "act_size": ACT_SIZE,
		"external": ext.map(func(i): return tanks[i].name),
		"tanks": tanks.map(func(t): return {"name": t.name, "tank": t.spec.id, "team": t.team, "rng_seed": t.rng.seed}),
		"controllers": ctrls,
		"waypoint": TankSpec._v(waypoint) if waypoint != Vector3.INF else null,
		"actions_i8_b64": Marshalls.raw_to_base64(_act_bytes),
		"rewards_f32_b64": Marshalls.raw_to_base64(_rew_bytes),
		"shots": _shots, "paths_1hz": _paths, "path_fields": ["t"] + tanks.map(func(t): return t.name + ":x,z,yaw,status"),
		"result": _end}))
	f.close()
	_end["episode_file"] = path


# ================================================================ 재현

func _start_reproduce(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("reproduce: cannot open %s" % path)
		get_tree().quit(2)
		return
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if not (d is Dictionary) or d.get("format", "") != EPISODE_FORMAT:
		push_error("reproduce: not a training episode file")
		get_tree().quit(2)
		return
	_repro = d
	_log_ticks = REPEAT
	_repro_actions = Marshalls.base64_to_raw(d.get("actions_i8_b64", ""))
	if _repro_out == "":
		_repro_out = "user://logs"   # F3 리플레이 뷰어가 바로 여는 위치
	var c: Dictionary = d.config.duplicate(true)
	c["record"] = true
	c["save_episode"] = false
	reset_episode(c)
	print("reproduce: %s  stage=%s seed=%d  external=%s  decisions=%d" % [c.get("uid", ""), c.get("stage", ""),
		int(c.get("seed", 0)), d.get("external", []), _repro_actions.size() / maxi(ext.size() * ACT_SIZE, 1)])


func _repro_tick(dt: float) -> void:
	if tick % REPEAT == 0:
		if tick > 0:
			_evaluate()
			if done:
				_repro_finish()
				return
		var n := ext.size() * ACT_SIZE
		if (_repro_i + 1) * n > _repro_actions.size():
			# 기록이 여기서 끝남(중단된 에피소드)
			done = true
			_end = {"done": true, "reason": "record_end", "success": false, "winner": -1, "ticks": tick,
				"final_hash": final_hash()}
			_repro_finish()
			return
		for k in ext.size():
			var raw := []
			for j in ACT_SIZE:
				raw.append(_repro_actions.decode_s8(_repro_i * n + k * ACT_SIZE + j) / 127.0)
			_last_actions[k] = policy_to_action(raw, view_lock)
		_repro_i += 1
		decisions += 1
	_advance(dt)


func _repro_finish() -> void:
	var want: String = _repro.get("result", {}).get("final_hash", "")
	var got := final_hash()
	_finish_files("done")
	var ok := want == got
	print("reproduce: %s  ticks=%d  result=%s  final_hash %s (%s)" % ["OK — 원래 에피소드와 같음" if ok else "MISMATCH — 다름",
		tick, _end.get("reason", ""), got, want])
	print("reproduce: replay=%s  report=%s" % [_end.get("replay_dir", ""), recorder.last_report_path if recorder else ""])
	var summary := {"ok": ok, "final_hash": got, "expected_hash": want, "result": _end}
	var out_dir: String = _end.get("replay_dir", "")
	if out_dir != "":
		var sf := FileAccess.open(out_dir + "/reproduce.json", FileAccess.WRITE)
		if sf:
			sf.store_string(JSON.stringify(summary, "  "))
			sf.close()
	get_tree().quit(0 if ok else 3)
