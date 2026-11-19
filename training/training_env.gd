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
const FINAL_BATTLE_VERSION := 1   # 최종 1대6: 지정 지형(custom_ridges·mounds), 생울타리·돌담·건물 배치, 엄폐 보상
const EPISODE_FORMAT := "tankgame-train-episode"
## 결정(행동 선택) 간격 = 관측 갱신 간격(3틱 = 0.1초, 10Hz)
const REPEAT := TankAgent.PERCEIVE_EVERY
const TASK_SIZE := 8
const TASK_LABELS := ["task.has_waypoint", "task.wp_bearing_sin", "task.wp_bearing_cos", "task.wp_dist",
	"task.time_left", "task.kind_drive", "task.kind_gunnery", "task.kind_combat"]
const ACT_SIZE := TankAgent.ACTION_SIZE
const KINDS := ["drive", "gunnery", "combat"]
const TEAM_BASE_SIGN := [1.0, -1.0]   # 팀0(독일) = +축 쪽, 팀1(연합군) = -축 쪽 (main 과 같음)

## --obs=situation: 커리큘럼 v4 목적 관측(SituationObs)을 뒤에 붙인다. 기존 실행·체크포인트는 그대로 쓴다
static var situation := false
static var threat_inputs := false
static var targeting_inputs := false


static func obs_size() -> int:
	return TankPerception.size() + TASK_SIZE + (SituationObs.size() if situation else 0) + (ThreatObs.LABELS.size() if threat_inputs else 0) + (TargetingObs.size() if targeting_inputs else 0)


static func obs_labels() -> Array:
	return TankPerception.labels() + TASK_LABELS + (SituationObs.labels() if situation else []) + (ThreatObs.LABELS if threat_inputs else []) + (TargetingObs.labels() if targeting_inputs else [])


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
var projectiles: TrainingProjectileField
var rewarder: TrainingReward
var recorder: MatchRecorder
var waypoint := Vector3.INF
var course_route: Array[Vector3] = []
var course_index := 0
var _spawn_error := ""
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
## 성능 계측(µs 누적). 에피소드 결과(result.perf)에 ms 로 남긴다. 시뮬레이션 결과에는 영향이 없다
var _perf := {}
var _frame_t := 0

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
		elif a == "--obs=situation":
			situation = true
		elif a == "--obs=situation_v3":
			situation = true
			threat_inputs = true
		elif a == "--obs=battle":
			situation = true
			threat_inputs = true
			targeting_inputs = true
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
		"repeat": REPEAT, "engine": Engine.get_version_info().string,
		"terrain_course_version": TerrainCourse.VERSION, "spawn_safety_version": 1, "destruction_version": 1,
		"compact_battle_version": 1, "fast_combat_reward_version": 1, "battle_selfplay_version": 1,
		"targeting_obs_version": TargetingObs.VERSION if targeting_inputs else 0,
		"battle_balance_version": TankDatabase.BALANCE_VERSION,
		"scenario_version": ScenarioLayout.VERSION, "situation_obs_version": SituationObs.VERSION if situation else 0,
		"driving_reward_version": 2,
		"threat_obs_version": ThreatObs.VERSION if threat_inputs else 0, "projectile_version": TrainingProjectileField.VERSION,
		"pace_version": 1, "perf_version": 1, "final_battle_version": FINAL_BATTLE_VERSION})
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
	# Wait on the socket itself. Polling with micro-sleeps adds Windows timer
	# latency to every action and needlessly spins during PPO updates/pauses.
	if n <= 0:
		return PackedByteArray()
	var received := _peer.get_data(n)
	return received[1] if received[0] == OK else PackedByteArray()


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
		var tw := Time.get_ticks_usec()
		var msg := _recv()
		_perf_add("wait_python", tw)
		if msg.is_empty():
			print("training env %d: python disconnected" % env_id)
			get_tree().quit()
			set_physics_process(false)
			return
		var h: Dictionary = msg.header
		match str(h.get("type", "")):
			"reset":
				var tr := Time.get_ticks_usec()
				reset_episode(h.get("config", {}))
				_perf_add("reset", tr)
				if _spawn_error != "":
					_send({"type": "error", "message": _spawn_error})
				else:
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
	var t0 := Time.get_ticks_usec()
	var obs := PackedFloat32Array()
	var meta := []
	for k in ext.size():
		var i: int = ext[k]
		var t: Tank = tanks[i]
		obs.append_array(_observation(i))
		meta.append({"name": t.name, "tank": t.spec.id, "team": t.team,
			"alive": t.damage.is_combat_effective(),
			"reward": rewarder.taken(t.name) if nrew > 0 else 0.0})
	_perf_add("obs_build", t0)
	var tb := Time.get_ticks_usec()
	var h := {"type": "obs", "tick": tick, "decision": decisions, "done": done, "agents": meta}
	if done:
		_end["perf"] = perf_summary()
		h["episode"] = _end
	var bytes := obs.to_byte_array()
	_perf_add("obs_header", tb)
	var ts := Time.get_ticks_usec()
	_send(h, bytes)
	_perf_add("obs_write", ts)


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
	_perf_reset()
	config = p_config.duplicate(true)
	_spawn_error = ""
	var rng := RandomNumberGenerator.new()
	rng.seed = int(config.get("seed", 1))
	config["seed"] = rng.seed
	if config.has("terrain_course") and not config.has("terrain_layout"):
		config["terrain_layout"] = TerrainCourse.plan(config)
	if config.has("scenario"):
		var first: Array = config.get("tanks", [{}])
		config.scenario["learner_type"] = str(first[0].get("type", "tiger1")) if first.size() > 0 else "tiger1"
	_ensure_map(config.get("map", {}))
	_clear_tanks()
	sounds = SoundField.new()
	projectiles = TrainingProjectileField.new(self) if int(config.get("scenario", {}).get("projectile_version", 0)) >= 1 else null
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
	if _spawn_error != "":
		active = false
		return
	config["spawn_safety_version"] = 1
	config["spawn_positions"] = tanks.map(func(t): return TankSpec._v(t.global_position))
	waypoint = Vector3.INF
	course_route.clear()
	course_index = 0
	var kind := str(config.get("kind", "combat"))
	if config.has("scenario"):
		waypoint = ScenarioLayout.objective_point(map, config.scenario)
	elif config.has("terrain_layout"):
		for p in config.terrain_layout.route:
			course_route.append(Vector3(p[0], map.height_at(p[0], p[1]), p[1]))
		waypoint = course_route[0]
	elif kind == "drive" and not config.has("scenario"):
		waypoint = _pick_waypoint(rng)
		if waypoint == Vector3.INF:
			_spawn_error = "No safe drive waypoint for seed %s" % config.seed
			active = false
			return
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
	var sc: Dictionary = config.get("scenario", {})
	var key := JSON.stringify([mc, config.get("terrain_layout", {}), sc.get("obstacles", []), sc.get("learner_type", "")])
	if key == _map_key and map != null:
		map.destruction.reset()
		return
	if map:
		remove_child(map)
		map.free()
	if mc.has("profile"):
		var practice := PracticeMap.new()
		practice.profile = str(mc.profile)
		var layout: Dictionary = config.get("terrain_layout", {})
		practice.course_angle = float(layout.get("angle", 0))
		var center: Array = layout.get("center", [0, 0])
		practice.course_center = Vector2(center[0], center[1])
		map = practice
	else:
		map = HillMap.new()
	map.map_seed = int(mc.get("seed", 1))
	map.features_enabled = bool(mc.get("features", false))
	map.height_amplitude = float(mc.get("amplitude", 15.0))
	map.size_m = float(mc.get("size_m", 1200.0))
	map.cell_m = float(mc.get("cell_m", 5.0))
	map.ridge_count = int(mc.get("ridge_count", 3))
	map.noise_frequency = float(mc.get("noise_frequency", 0.0025))
	map.custom_ridges = mc.get("custom_ridges", [])
	map.mounds = mc.get("mounds", [])
	add_child(map)
	if mc.get("profile", "") == "battle_compact":
		CompactBattle.populate(map)
	if config.has("terrain_layout"):
		TerrainCourse.populate(map, config.terrain_layout)
	if config.has("scenario"):
		ScenarioLayout.populate(map, config.scenario)
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
	if config.has("scenario"):
		_spawn_scenario(specs, rng)
		return
	if config.has("terrain_layout"):
		var layout: Dictionary = config.terrain_layout
		var s: Dictionary = specs[0]
		if not map.is_spawn_safe(Vector2(layout.spawn[0], layout.spawn[1])):
			_spawn_error = "Unsafe terrain course spawn for seed %s" % config.seed
			return
		_spawn_one(str(s.type), int(s.team), Vector2(layout.spawn[0], layout.spawn[1]),
			float(layout.yaw), rng.randi_range(1, 2147483646), "external", 0)
		agents.append(TankAgent.new(map, tanks[0], sounds))
		agents[-1].perception.configure(config.get("pace", {}))
		config["spawn_distance_m"] = layout.length_m
		return
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
			if p == Vector2.INF:
				_spawn_error = "No safe spawn with a clear exit for seed %s" % config.seed
				return
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
		agents[-1].perception.configure(config.get("pace", {}))
		if ctrls[i] == "mover":
			var d := TargetDriver.new(rng.randi_range(1, 2147483646), map.size_m * 0.5)
			drivers[t.name] = d


const SCENARIO_AI_KEYS := ["aim_noise_mrad", "fire_delay_s", "max_fire_range", "engage_range", "angle_deg",
	"flank_offset", "reacquire_s", "suppression_cone_mrad"]


## 커리큘럼 v4: Python 이 정한 위치·방향 그대로(안전하지 않으면 가장 가까운 안전 지점으로 옮기고 기록)
func _spawn_scenario(specs: Array, rng: RandomNumberGenerator) -> void:
	var sc: Dictionary = config.scenario
	var places: Array = [sc.learner] + sc.get("enemies", [])
	if places.size() != specs.size():
		_spawn_error = "Scenario tank count mismatch for seed %s" % config.seed
		return
	var moved := []
	for i in specs.size():
		var s: Dictionary = specs[i]
		var pl: Dictionary = places[i]
		var p := Vector2(float(pl.p[0]), float(pl.p[1]))
		if not map.is_spawn_safe(p, 4.0, 6.0):
			var q := _clear_spot(p, rng)
			if q == Vector2.INF:
				_spawn_error = "No safe scenario spawn for seed %s" % config.seed
				return
			moved.append({"index": i, "from": [p.x, p.y], "to": [q.x, q.y]})
			p = q
		_spawn_one(str(s.get("type", "tiger1")), int(s.get("team", 0)), p, float(pl.get("yaw", 0.0)),
			rng.randi_range(1, 2147483646), str(s.get("ctrl", "scripted")), i)
	config["scenario_relocated"] = moved
	var lp := Vector2(tanks[0].global_position.x, tanks[0].global_position.z)
	var centroid := Vector2.ZERO
	var nearest := INF
	for i in range(1, tanks.size()):
		var q := Vector2(tanks[i].global_position.x, tanks[i].global_position.z)
		centroid += q / float(tanks.size() - 1)
		nearest = minf(nearest, q.distance_to(lp))
	config["spawn_distance_m"] = snappedf(nearest, 0.01) if nearest < INF else 0.0
	for i in tanks.size():
		var t: Tank = tanks[i]
		var base := centroid if i == 0 else lp
		var ai := ScriptedAI.for_tank(t, i, Vector3(base.x, 0, base.y))
		ai.rng.seed = t.rng.seed + 7919
		if i > 0:
			var params: Dictionary = places[i].get("ai", {})
			ai.hold = bool(params.get("hold", false))
			ai.advance = bool(params.get("advance", false))
			for k in SCENARIO_AI_KEYS:
				if params.has(k):
					ai.set(k, float(params[k]))
		agents.append(TankAgent.new(map, t, sounds, ai))
		agents[-1].perception.configure(config.get("pace", {}))
		if ctrls[i] == "mover":
			drivers[t.name] = TargetDriver.new(rng.randi_range(1, 2147483646), map.size_m * 0.5)


func _clear_spot(p: Vector2, rng: RandomNumberGenerator) -> Vector2:
	var reserved := tanks.map(func(t): return Vector2(t.global_position.x, t.global_position.z))
	return map.find_safe_spawn(p, rng, reserved)


func _spawn_one(id: String, team: int, p: Vector2, yaw: float, seed_v: int, ctrl: String, idx: int) -> void:
	var t := Tank.new()
	t.name = "%s_%d" % [id, idx]
	t.setup(id, team, seed_v, config.get("pace", {}))
	t.ground_map = map
	t.position = Vector3(p.x, map.height_at(p.x, p.y) + 0.5, p.y)
	t.rotation.y = yaw
	add_child(t)
	t.shot_fired.connect(_on_shot)
	t.shot_fired.connect(sounds.on_shot)
	t.shot_launched.connect(_on_launch)
	t.projectile_field = projectiles
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
	for k in 80:
		var d := rng.randf_range(float(dr[0]), float(dr[1]))
		var a := rng.randf_range(-PI, PI)
		var q := from + Vector2(sin(a), cos(a)) * d
		if absf(q.x) < half and absf(q.y) < half and map.is_spawn_safe(q, 6.0, 12.0):
			return Vector3(q.x, map.height_at(q.x, q.y), q.y)
	return Vector3.INF


func _start_recorder() -> void:
	recorder = MatchRecorder.new()
	recorder.external_rewards = bool(config.get("reward", {}).get("battle_shaping", false)) or int(config.get("scenario", {}).get("observation_version", 0)) >= 3
	recorder.projectile_field = projectiles
	if threat_inputs:
		recorder.observation_labels = obs_labels()
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
	var tf := Time.get_ticks_usec()
	if _frame_t > 0:
		_perf["frame"] = _perf.get("frame", 0) + tf - _frame_t
	_frame_t = tf
	if tick > 0 and tick % REPEAT == 0:
		var te := Time.get_ticks_usec()
		_evaluate()
		_perf_add("reward", te)
		if done:
			_end["perf"] = perf_summary()   # 에피소드 파일에도 남긴다
			var tff := Time.get_ticks_usec()
			_finish_files("done")   # 에피소드 파일·리플레이 경로를 결과에 넣은 뒤 보낸다
			_perf_add("files", tff)
		var to := Time.get_ticks_usec()
		_send_obs(1)
		_perf_add("obs_send", to)
		_serve()   # step 을 받을 때까지(끝났으면 reset → 새 에피소드 첫 step)
		if not active:
			return
	var ta := Time.get_ticks_usec()
	_advance(dt)
	_perf_add("agents", ta)


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
		_end["destroyed_obstacles"] = map.destruction.destroyed_ids()
		if bool(config.get("reward", {}).get("battle_shaping", false)):
			_end["combat_rewards"] = rewarder.battle_summary()
		if config.has("terrain_course"):
			_end["terrain"] = rewarder.course_summary()
		if config.has("scenario"):
			_end["scenario"] = rewarder.scenario_summary()
		_end["spawn_distance_m"] = config.get("spawn_distance_m", 0.0)
		_end["tanks"] = tanks.map(func(t): return {"name": t.name, "tank": t.spec.id, "team": t.team,
			"status": t.damage.status_label(), "return": snappedf(rewarder.total(t.name), 0.0001),
			"shots": t.shots_fired, "hits": rewarder.hits.get(t.name, 0), "pens": rewarder.pens.get(t.name, 0),
			"kills": rewarder.kills.get(t.name, 0)})
		if _end.has("combat_rewards"):
			for tank in _end.tanks:
				tank["reward_components"] = _end.combat_rewards.get(tank.name, {})


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
	if projectiles != null:
		projectiles.step(dt)
	sounds.advance(dt)
	var log_now := recorder != null and tick % _log_ticks == 0
	for i in tanks.size():
		var t: Tank = tanks[i]
		var ag: TankAgent = agents[i]
		var alive := t.damage.is_combat_effective()
		var a: Array = []
		# 전투불능 전차의 관측은 아무도 쓰지 않는다(Python 은 살아 있는 개체만 추론·학습, 기록도 생존 전차만)
		# → 관측 계산을 건너뛴다. 시뮬레이션 결과는 같다.
		match ctrls[i]:
			"external":
				if alive:
					ag.update(tanks, dt)
				a = _last_actions[ext.find(i)]
				ag.apply_action(a, dt)
			"scripted":
				if alive:
					a = ag.step_ai(tanks, dt)
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
	if situation:
		var sc: Dictionary = config.get("scenario", {})
		var radius := float(sc.get("objective", {}).get("radius", 0.0))
		o.append_array(SituationObs.compute(map, t, agents[i].perception, waypoint if sc.has("objective") else Vector3.INF, radius,
			int(sc.get("observation_version", 1))))
	if threat_inputs:
		o.append_array(ThreatObs.compute(agents[i].perception, projectiles))
	if targeting_inputs:
		o.append_array(TargetingObs.compute(map, t, agents[i].perception, tanks))
	return o


## 임무 방향: 주행 = 웨이포인트, 전투 = 적 출발 지역(공개 정보), 사격 = 표적이 있는 방향(사수에게 지시된 구역)
func _task_waypoint(t: Tank) -> Vector3:
	if config.get("scenario", {}).get("goal", "") == "take_cover":
		return Vector3.INF
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


func _on_launch(shooter: Tank, result: Dictionary) -> void:
	for agent in agents:
		agent.perception.notice_launch(shooter, result)
	if rewarder != null:
		rewarder.on_launch(shooter, result)


func _on_shot(shooter: Tank, r: Dictionary) -> void:
	if rewarder:
		rewarder.on_shot(shooter, r)
	var e := {"t": snappedf(float(tick) / Engine.physics_ticks_per_second, 0.01), "shooter": shooter.name,
		"target": r.get("target_name", ""), "hit": r.get("hit", false), "shell": r.get("shell", "")}
	if r.get("hit", false):
		e.merge({"zone": r.get("zone", ""), "penetrated": r.get("penetrated", false), "ricochet": r.get("ricochet", false),
			"effective_mm": r.get("effective_mm", 0), "distance_m": snappedf(float(r.get("distance_m", r.get("distance", 0.0))), 0.1),
			"pen_mean_mm": r.get("pen_mean_mm", 0), "entry_local": r.get("entry_local", []),
			"damage": r.get("damage", []), "events": r.get("events", [])})
	else:
		e["blocked_by"] = r.get("blocked_by", "")
		if r.has("near_miss"):
			e["near_miss"] = r.near_miss
	_shots.append(e)


## 끝 상태 요약 해시(재현 검증용)
func final_hash() -> String:
	var parts := []
	for t in tanks:
		var p: Vector3 = t.global_position
		parts.append("%s:%.3f,%.3f,%.3f,%.4f,%.4f,%s,%d,%d" % [t.name, p.x, p.y, p.z, t.turret_yaw, t.gun_pitch,
			t.damage.status_label(), t.damage.ammo_remaining, t.shots_fired])
	var damage_state: Array = map.destruction.damage_state()
	if not damage_state.is_empty():
		parts.append("obstacles:" + JSON.stringify(damage_state))
	if projectiles != null:
		var flight := []
		for projectile in projectiles.active:
			flight.append([TankSpec._v(projectile.pos), TankSpec._v(projectile.velocity), projectile.age, projectile.rng.state])
		parts.append("flight:" + JSON.stringify(flight))
	return ("|".join(parts)).md5_text()


# ================================================================ 성능 계측

func _perf_add(key: String, t0: int) -> void:
	_perf[key] = _perf.get(key, 0) + Time.get_ticks_usec() - t0


func _perf_reset() -> void:
	_perf = {}
	_frame_t = 0
	Tank.perf_step_us = 0
	Tank.perf_ground_us = 0
	TankPerception.perf_self_us = 0
	TankPerception.perf_contacts_us = 0
	TankPerception.perf_scan_us = 0
	TankPerception.perf_sound_us = 0
	TankPerception.perf_observations = 0
	TankPerception.perf_los_rays = 0
	TankPerception.perf_scans = 0


## 에피소드 동안의 구간별 시간(ms). frame = 물리 프레임 전체(Python 대기 포함),
## engine_other = frame 에서 계측된 구간을 뺀 나머지(Godot 물리 서버·씬 트리 처리)
func perf_summary() -> Dictionary:
	var ms := func(us): return snappedf(float(us) / 1000.0, 0.01)
	var frame: int = _perf.get("frame", 0)
	var wait: int = _perf.get("wait_python", 0)
	var measured: int = wait + int(_perf.get("agents", 0)) + int(_perf.get("reward", 0)) \
		+ int(_perf.get("obs_send", 0)) + int(_perf.get("files", 0)) + Tank.perf_step_us
	return {"version": 1, "ticks": tick, "decisions": decisions, "tanks": tanks.size(),
		"frame_ms": ms.call(frame), "wait_python_ms": ms.call(wait),
		"sim_ms": ms.call(frame - wait),
		"agents_ms": ms.call(_perf.get("agents", 0)), "reward_ms": ms.call(_perf.get("reward", 0)),
		"obs_send_ms": ms.call(_perf.get("obs_send", 0)), "obs_build_ms": ms.call(_perf.get("obs_build", 0)), "obs_header_ms": ms.call(_perf.get("obs_header", 0)), "obs_write_ms": ms.call(_perf.get("obs_write", 0)), "files_ms": ms.call(_perf.get("files", 0)),
		"tank_step_ms": ms.call(Tank.perf_step_us), "tank_ground_ms": ms.call(Tank.perf_ground_us),
		"engine_other_ms": ms.call(frame - measured),
		"perception": {"observations": TankPerception.perf_observations, "self_ms": ms.call(TankPerception.perf_self_us),
			"contacts_ms": ms.call(TankPerception.perf_contacts_us), "scan_ms": ms.call(TankPerception.perf_scan_us),
			"sound_ms": ms.call(TankPerception.perf_sound_us), "los_rays": TankPerception.perf_los_rays,
			"scans": TankPerception.perf_scans}}


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
	if int(c.get("scenario", {}).get("observation_version", 0)) >= 3:
		situation = true
		threat_inputs = true
	if int(c.get("curriculum_version", 0)) == 5:
		targeting_inputs = true
	c["record"] = true
	c["save_episode"] = false
	reset_episode(c)
	if _spawn_error != "":
		push_error(_spawn_error)
		get_tree().quit(2)
		return
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
