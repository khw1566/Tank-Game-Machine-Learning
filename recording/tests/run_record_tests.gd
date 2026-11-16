extends SceneTree
## 기록·리플레이·보고서 검증(헤드리스).
## 실행: godot --headless --fixed-fps 30 --path . -s res://recording/tests/run_record_tests.gd
##  1) 보상 규칙  2) 맵 기록 → 재구성 일치  3) 규칙 AI 끼리 짧은 경기 기록
##  4) 기록 다시 읽기: 사격·점수·자세가 원본과 같은지  5) 보고서·CSV 생성

const LOG_ROOT := "user://test_logs"
const MAX_S := 300.0

var failures := 0
var map: HillMap
var tanks: Array = []
var ais: Array = []          # TankAgent
var sounds := SoundField.new()
var rec: MatchRecorder
var live_shots := 0
var live_poses := {}   # tick -> [Transform3D...] 일부 표본
var done := false


func check(cond: bool, msg: String) -> void:
	print("  ", "PASS  " if cond else "FAIL  ", msg)
	if not cond:
		failures += 1


func _initialize() -> void:
	print("== 1) 보상 규칙")
	var rm := RewardModel.new()
	var miss := rm.shot_rewards("a", 0, "", -1, {"hit": false})
	check(miss.size() == 1 and miss[0].value < 0.0, "빗나감 = 감점 %.2f" % miss[0].value)
	var ko := rm.shot_rewards("a", 0, "b", 1, {"hit": true, "penetrated": true,
		"damage": [{"kind": "crew", "id": "driver", "before": "ok", "after": "kia"}], "events": ["penetration", "knocked_out:crew_casualties"]})
	check(ko.size() == 2 and is_equal_approx(ko[0].value, 0.2 + 1.0 + 0.5 + 5.0), "관통+전사+격파 = %.2f" % ko[0].value)
	check(ko[1].tank == "b" and is_equal_approx(ko[1].value, -(1.0 + 0.5 + 5.0)), "피격 전차 감점 %.2f" % ko[1].value)
	var ff := rm.shot_rewards("a", 0, "c", 0, {"hit": true, "penetrated": true, "damage": [], "events": []})
	check(ff[0].value < 0.0, "아군 사격 = 감점 %.2f" % ff[0].value)


## _initialize 시점에는 root 가 아직 트리 밖이라 _ready 가 늦게 불린다 → 첫 물리 프레임에서 준비
func _setup() -> void:
	print("== 2) 맵 기록 → 재구성")
	var m1 := HillMap.new()
	m1.map_seed = 7
	root.add_child(m1)
	var record := m1.to_record()
	var txt := JSON.stringify(record)
	var m2 := HillMap.new()
	m2.load_record(JSON.parse_string(txt))
	root.add_child(m2)
	check(m2.obstacles.size() == m1.obstacles.size() and m1.obstacles.size() > 50, "장애물 %d개 동일" % m2.obstacles.size())
	var max_dh := 0.0
	for p in [Vector2(0, 0), Vector2(123.4, -321.0), Vector2(-500, 480), Vector2(250, 10)]:
		max_dh = maxf(max_dh, absf(m1.height_at(p.x, p.y) - m2.height_at(p.x, p.y)))
	check(max_dh < 0.6, "지형 높이 차이 최대 %.3fm (격자 보간)" % max_dh)
	var same := true
	for i in m1.obstacles.size():
		if m1.obstacles[i].pos.distance_to(m2.obstacles[i].pos) > 0.01 or absf(m1.obstacles[i].radius - m2.obstacles[i].radius) > 0.01:
			same = false
	check(same, "장애물 위치·크기 일치")
	m1.free()
	m2.free()

	print("== 3) 규칙 AI 경기 기록")
	map = HillMap.new()
	map.map_seed = 2
	# 기록 검증이 목적이라 지형(능선)만 두고 숲·울타리는 뺀다(규칙 AI 가 우회를 못 해도 교전이 일어나도록)
	map.features_enabled = false
	root.add_child(map)
	map.add_building(Vector2(60, 0), Vector3(10, 6, 8), 0.3)
	map.add_wall(Vector2(-80, 50), Vector2(-20, 60))
	var lineup := ["tiger1", "sherman75", "sherman75", "t34_76"]
	var idx := [0, 0]
	for i in lineup.size():
		var team := 0 if i == 0 else 1
		var sp: Vector3 = map.spawn_points[team] + Vector3((idx[team] - 1) * 25.0 if team == 1 else 0.0, 0, 0)
		var t := Tank.new()
		t.name = "%s_%d" % [lineup[i], i]
		t.setup(lineup[i], team, 100 + i)
		t.position = Vector3(sp.x, map.height_at(sp.x, sp.z) + 0.5, sp.z)
		t.rotation.y = 0.0 if team == 0 else PI
		root.add_child(t)
		tanks.append(t)
		ais.append(TankAgent.new(map, t, sounds, ScriptedAI.for_tank(t, idx[team], map.spawn_points[1 - team])))
		t.shot_fired.connect(sounds.on_shot)
		idx[team] += 1
		t.shot_fired.connect(func(_s, _r): live_shots += 1)
	rec = MatchRecorder.new()
	rec.log_root = LOG_ROOT
	rec.time_limit_s = MAX_S
	root.add_child(rec)
	var views := {}
	for ag in ais:
		views[ag.tank.name] = ag.view
	rec.views = views
	rec.start(map, tanks, {"test": true})
	rec.episode_ended.connect(_on_end)


var _started := false


func _physics_process(_delta: float) -> bool:
	if done:
		return true
	if not _started:
		_started = true
		_setup()
		return false
	if rec.ended:
		return false
	sounds.advance(1.0 / 30.0)
	for i in tanks.size():
		var t: Tank = tanks[i]
		if t.damage.is_combat_effective():
			var a: Array = ais[i].step_ai(tanks, 1.0 / 30.0)
			if rec.tick % 30 == 0:
				var info: Dictionary = ais[i].ai.last_info.duplicate()
				info["perception"] = ais[i].perception.summary()
				rec.log_decision(t, ais[i].perception.vector, a, info)
		else:
			t.control = TankControlInput.new()
	# 실제 자세 표본: 이 시점의 자세 = 직전 틱(rec.tick) 이동 후 = 그 틱에 기록된 프레임
	if rec.tick > 0 and rec.tick % 90 == 0:
		live_poses[rec.tick] = tanks.map(func(t): return t.global_transform)
	return false


func _on_end(s: Dictionary) -> void:
	print("  경기 종료: %s, 승리 팀 %d, %.0f초, 점수 %s" % [s.reason, s.winner, s.duration_s, s.team_scores])
	check(live_shots > 0, "사격 %d발" % live_shots)
	print("== 4) 기록 다시 읽기")
	var d := ReplayData.load_file(rec.events_path)
	check(d.ok(), "events.jsonl 읽기 (%d프레임, %d사격, %d점수사건, %d판단)" % [d.frames.size(), d.shots.size(), d.rewards.size(), d.decisions.size()])
	check(d.shots.size() == live_shots, "기록된 사격 수 = 실제 %d" % live_shots)
	check(not d.end.is_empty() and d.end.reason == s.reason, "종료 기록")
	var sc: Array = d.end.summary.team_scores
	check(absf(sc[0] - rec.team_scores[0]) < 0.01 and absf(sc[1] - rec.team_scores[1]) < 0.01, "팀 점수 일치 %s" % [sc])
	var sum_r := 0.0
	for r in d.rewards:
		sum_r += float(r.value)
	var time_part: float = rec.team_scores[0] + rec.team_scores[1] - sum_r
	check(time_part <= 0.0 and time_part > -10.0, "점수 = 사건 합 %.2f + 시간 점수 %.2f" % [sum_r, time_part])
	var max_err := 0.0
	var n := 0
	for tk in live_poses:
		var tsec := float(tk) / Engine.physics_ticks_per_second
		for i in tanks.size():
			var p := d.pose(i, tsec)
			max_err = maxf(max_err, (p.xform.origin - live_poses[tk][i].origin).length())
			n += 1
	check(n > 0 and max_err < 0.01, "재구성 자세 오차 최대 %.4fm (%d표본)" % [max_err, n])
	var modes := {}
	for fr in d.frames:
		modes[int(d.field(fr.s[0], "view_mode", -1))] = true
	check(modes.has(TankView.GUNNER) and modes.has(TankView.COMMANDER), "프레임에 시점 기록(티거가 쓴 시점 %s)" % [modes.keys()])
	var with_pc := d.decisions.filter(func(e): return e.info.has("perception") and e.obs.size() == TankPerception.size())
	check(with_pc.size() == d.decisions.size() and d.header.observation_labels.size() == TankPerception.size(), "판단 기록마다 관측 벡터 %d개 + 요약" % TankPerception.size())
	var hz := 0
	for td in d.tanks():
		hz += 1 if td.has("hull_size") else 0
	check(hz == tanks.size() and d.header.map.heights.size() > 1000, "header 에 맵 격자·전차 치수 포함")
	print("== 5) 보고서")
	var rp := ReportBuilder.build_files(rec.events_path, rec.episodes_index_path())
	var html := FileAccess.get_file_as_string(rec.dir + "/report.html")
	check(rp != "" and html.length() > 10000, "report.html %d KB" % (html.length() / 1024))
	for key in ["맵상 동선", "점수(목표값) 그래프", "타격 기록", "피탄 분석", "에피소드별 점수 곡선", "data:image/png;base64"]:
		check(html.contains(key), "보고서에 '%s'" % key)
	var shots_csv := FileAccess.get_file_as_string(rec.dir + "/shots.csv")
	check(shots_csv.split("\n", false).size() == live_shots + 1, "shots.csv %d행" % live_shots)
	check(FileAccess.file_exists(rec.dir + "/paths.csv") and FileAccess.file_exists(rec.dir + "/score.csv"), "paths.csv, score.csv")
	check(FileAccess.file_exists(rec.episodes_index_path()), "episodes.csv")
	print("  보고서: ", rp)
	print("\n== record tests: %d failures ==" % failures)
	done = true
