extends Node3D
## 메인 씬: 구릉지 + 티거 1대 vs 셔먼·T-34 여러 대.
## 사람은 키보드로 한 대를 조종(Tab 으로 전환). 나머지는 F7 로 규칙 AI 를 켤 수 있다.
## 모든 경기는 MatchRecorder 가 user://logs/replays/ep####_<시각>/ 에 기록하고,
## 끝나면(전멸·시간초과·F4) 보고서 report.html 을 만든다. F3 = 리플레이 뷰어.
##
## 헤드리스 일괄 실행(전원 AI, 끝나면 다음 에피소드):
##   godot --headless --path . -- --episodes=10 [--seed=1] [--time-limit=600] [--log-obs=60] [--spawn-distance=500]
##
## 강화학습(커리큘럼·Python 연결)은 training/ 참고:  godot --headless --fixed-fps 30 --path . -- --train --port=11008
##
## 사람과 AI 는 같은 정보만 받는다(TankAgent = 시점 + 관측). 공정 시야(K, 기본 켬)에서는
## 사람 화면에도 탐지된 적만 그려지고, HUD 에 정확한 거리가 나오지 않는다. 전원 AI 관전 중에는 꺼진다.

const AI_OFF := 0
const AI_OTHERS := 1   # 내가 조종하는 전차 외 전원 AI
const AI_ALL := 2      # 전원 AI(관전)
const AI_LABELS := ["AI 꺼짐(정지)", "AI: 다른 전차", "AI 관전: 전원"]

static var ai_mode := AI_OFF
static var episodes_left := -1
static var cli_parsed := false
static var cli_seed := -1
static var cli_time_limit := -1.0
## 관측 벡터 전체를 몇 틱마다 기록할지(0 = 요약만). 요약(보인 적·들린 소리)은 판단 기록마다 남는다.
static var cli_log_obs_every := 60
## 양 팀 출발점 사이 거리(m). 0 이하 = 맵 기본(900m)
static var cli_spawn_distance := -1.0

@export var map_seed := 1
@export var allied_lineup: Array[String] = ["sherman75", "sherman75", "sherman75", "t34_76", "t34_76"]
@export var time_limit_s := 900.0

var map: HillMap
var tanks: Array = []
## 전차별 TankAgent(시점·관측·규칙 AI). 사람이 조종하는 전차도 같은 시점·관측을 쓴다.
var agents: Array = []
var sounds := SoundField.new()
## 공정 시야: 사람에게도 AI 와 같은 정보만(미탐지 적 숨김, 거리 숨김)
var fair_view := true
var player_index := 0
var camera: TankViewCamera
var hud: Label
var recorder: MatchRecorder
var markers: WorldMarkers
var overlay: CanvasLayer
var minimap: MinimapView
var impact_view: ImpactView
var score_graph: ScoreGraph
var score_label: Label
var feed_label: Label
var minimap_big := false
var detailed_hud := false
var last_event := ""
var banner := ""
var _restart_timer := -1.0
var grid: RangeGrid
## 분석용(공정 시야 끔): 조종 전차 기준 모든 적의 시야 판정(LineOfSight.spotted_enemies), 0.2초마다 갱신
var vision: Array = []
var _vision_timer := 0.0
var _show_sight_lines := true
var _sight_mesh: MeshInstance3D
var _headless := DisplayServer.get_name() == "headless"


func _ready() -> void:
	if "--train" in OS.get_cmdline_user_args() or "--reproduce" in " ".join(OS.get_cmdline_user_args()):
		# 학습/재현 모드: 학습 환경 씬으로 넘긴다(내보낸 exe 에서도 같은 인자로 동작)
		get_tree().change_scene_to_file.call_deferred("res://training/training_env.tscn")
		return
	_parse_cli()
	if cli_seed >= 0:
		map_seed = cli_seed
	if cli_time_limit >= 0.0:
		time_limit_s = cli_time_limit
	map = HillMap.new()
	map.map_seed = map_seed
	if cli_spawn_distance > 0.0:
		map.spawn_points = [Vector3(0, 0, cli_spawn_distance * 0.5), Vector3(0, 0, -cli_spawn_distance * 0.5)]
	add_child(map)
	if not _spawn("tiger1", 0, map.spawn_points[0], 0):
		return
	var n := allied_lineup.size()
	for i in n:
		var offset := Vector3((i - (n - 1) * 0.5) * 25.0, 0, 0)
		if not _spawn(allied_lineup[i], 1, map.spawn_points[1] + offset, i + 1):
			return
	var team_idx := [0, 0]
	var views := {}
	for t in tanks:
		var ag := TankAgent.new(map, t, sounds, ScriptedAI.for_tank(t, team_idx[t.team], map.spawn_points[1 - t.team]))
		agents.append(ag)
		views[t.name] = ag.view
		t.shot_fired.connect(sounds.on_shot)
		team_idx[t.team] += 1
	recorder = MatchRecorder.new()
	recorder.time_limit_s = time_limit_s
	recorder.views = views
	add_child(recorder)
	recorder.start(map, tanks, {"scene": "main", "map_seed": map_seed, "lineup": ["tiger1"] + Array(allied_lineup),
		"ai_mode": AI_LABELS[ai_mode], "controller": "keyboard+scripted_ai", "observation": "perception_v1",
		"fair_view": fair_view and ai_mode != AI_ALL})
	recorder.shot_recorded.connect(_on_shot_recorded)
	recorder.episode_ended.connect(_on_episode_ended)
	if not _headless:
		_setup_view()


func _parse_cli() -> void:
	if cli_parsed:
		return
	cli_parsed = true
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--episodes="):
			episodes_left = int(a.get_slice("=", 1))
			ai_mode = AI_ALL
		elif a.begins_with("--seed="):
			cli_seed = int(a.get_slice("=", 1))
		elif a.begins_with("--time-limit="):
			cli_time_limit = float(a.get_slice("=", 1))
		elif a.begins_with("--spawn-distance="):
			cli_spawn_distance = float(a.get_slice("=", 1))
		elif a.begins_with("--log-obs="):
			cli_log_obs_every = int(a.get_slice("=", 1))
		elif a == "--ai":
			ai_mode = AI_ALL
	if _headless and episodes_left < 0:
		episodes_left = 1
		ai_mode = AI_ALL


## yaw = 0 이면 -Z 방향을 바라본다. 티거는 +Z 끝에서 -Z(연합군 쪽)를 보므로 0,
## 연합군은 -Z 끝에서 +Z 를 봐야 하므로 PI.
func _spawn(id: String, team: int, at: Vector3, seed_v: int) -> bool:
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed * 100 + seed_v
	var reserved := tanks.map(func(t): return Vector2(t.position.x, t.position.z))
	var spot := map.find_safe_spawn(Vector2(at.x, at.z), rng, reserved)
	if spot == Vector2.INF:
		push_error("No safe spawn with a clear exit for " + id)
		get_tree().quit(2)
		return false
	var t := Tank.new()
	t.name = "%s_%d" % [id, tanks.size()]
	t.setup(id, team, 0)
	t.position = Vector3(spot.x, map.height_at(spot.x, spot.y) + 0.5, spot.y)
	t.rotation.y = 0.0 if team == 0 else PI
	add_child(t)
	t.shot_fired.connect(_on_shot)
	t.knocked_out.connect(_on_knocked_out)
	tanks.append(t)
	return true


func _setup_view() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = false
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.72, 0.85)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	add_child(env)
	grid = RangeGrid.new(map)
	add_child(grid)
	_sight_mesh = MeshInstance3D.new()
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.vertex_color_use_as_albedo = true
	sm.no_depth_test = true
	_sight_mesh.material_override = sm
	add_child(_sight_mesh)
	camera = TankViewCamera.new()
	camera.map = map
	camera.view = agents[player_index].view
	add_child(camera)
	camera.current = true
	camera.update_view(tanks[player_index], 0.0)
	markers = WorldMarkers.new()
	add_child(markers)
	for t in tanks:
		WorldMarkers.attach_label(t, MinimapView.TEAM_COLORS[t.team])
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(10, 10)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.clip_text = true
	_outline(hud)
	layer.add_child(camera.reticle)
	layer.add_child(hud)
	# 관찰 오버레이(F2)
	overlay = CanvasLayer.new()
	overlay.layer = 2
	add_child(overlay)
	minimap = MinimapView.new()
	minimap.set_map(map.to_record())
	overlay.add_child(minimap)
	minimap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	impact_view = ImpactView.new()
	overlay.add_child(impact_view)
	score_graph = ScoreGraph.new()
	overlay.add_child(score_graph)
	score_label = Label.new()
	_outline(score_label)
	overlay.add_child(score_label)
	feed_label = Label.new()
	_outline(feed_label)
	feed_label.add_theme_font_size_override("font_size", 13)
	feed_label.clip_text = true
	score_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	feed_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(feed_label)
	_layout_overlay()
	get_viewport().size_changed.connect(_layout_overlay)


func _outline(l: Label) -> void:
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)


func _layout_overlay() -> void:
	if minimap == null:
		return
	var vs := get_viewport().get_visible_rect().size
	hud.size = Vector2(maxf(260, vs.x - 280), vs.y - 20)
	var s := maxf(140.0, minf(vs.y - 360.0, 620.0)) if minimap_big else minf(240.0, vs.y * .34)
	minimap.size = Vector2(s, s)
	minimap.position = Vector2(vs.x - s - 10.0, 10.0)
	impact_view.position = Vector2(vs.x - 250.0, minimap.position.y + s + 6.0)
	impact_view.size = Vector2(240, minf(210, vs.y * .29))
	score_graph.size = Vector2(240, 70)
	score_graph.position = Vector2(vs.x - 250.0, impact_view.position.y + impact_view.size.y + 6.0)
	score_label.position = Vector2(vs.x - 250.0, score_graph.position.y + 72.0)
	feed_label.position = Vector2(vs.x - 250.0, score_label.position.y + 26.0)
	feed_label.size = Vector2(240, maxf(20, vs.y - feed_label.position.y - 10))


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.physical_keycode:
		KEY_TAB:
			tanks[player_index].control = TankControlInput.new()
			player_index = (player_index + 1) % tanks.size()
			if camera:
				camera.view = agents[player_index].view
		KEY_K:
			fair_view = not fair_view
			banner = "공정 시야 %s" % ("켬: 사람도 AI 와 같은 정보만" if fair_view else "끔: 모든 전차·거리 표시(분석용)")
		KEY_1, KEY_2, KEY_3:
			tanks[player_index].select_ammo(event.physical_keycode - KEY_1)
		KEY_G:
			grid.mode = grid.mode + 1
		KEY_V:
			_show_sight_lines = not _show_sight_lines
		KEY_F1:
			_finish_and("res://tanks/lab/armor_lab.tscn")
		KEY_F2:
			if overlay:
				overlay.visible = not overlay.visible
		KEY_M:
			minimap_big = not minimap_big
			_layout_overlay()
		KEY_F3:
			_finish_and("res://recording/replay_viewer.tscn")
		KEY_F4:
			if not recorder.ended:
				recorder.end_episode("manual", -1)
		KEY_F5:
			_finish_and("")
		KEY_F6:
			OS.shell_open(ProjectSettings.globalize_path(recorder.dir if recorder.dir != "" else recorder.log_root))
		KEY_F7:
			ai_mode = (ai_mode + 1) % 3
			banner = AI_LABELS[ai_mode]
		KEY_F8:
			detailed_hud = not detailed_hud
		KEY_H:
			if markers:
				markers.show_hits = not markers.show_hits
		KEY_P:
			if markers:
				markers.show_paths = not markers.show_paths
				minimap.show_paths = markers.show_paths


## 기록을 마무리(보고서 생성)하고 씬 전환. path = "" 이면 새 에피소드
func _finish_and(path: String) -> void:
	if not recorder.ended:
		recorder.end_episode("manual", -1)
	if path == "":
		get_tree().reload_current_scene()
	else:
		get_tree().change_scene_to_file(path)


func _physics_process(delta: float) -> void:
	if tanks.is_empty():
		return
	sounds.advance(delta)
	var log_now := recorder.tick % 15 == 0 and not recorder.ended
	var log_obs := cli_log_obs_every > 0 and recorder.tick % cli_log_obs_every == 0
	for i in tanks.size():
		var t: Tank = tanks[i]
		var ag: TankAgent = agents[i]
		var human := i == player_index and not _headless and ai_mode != AI_ALL
		var a: Array = []
		var who := ""
		if human:
			# 사람: 화면 카메라(camera.view == ag.view)가 시점을 바꾸고, 관측은 기록·HUD 용으로 같이 만든다
			ag.update(tanks, delta)
			t.control = camera.human_control(t, delta)
			a = Array(t.control.to_array())
			who = "human"
		elif ai_mode != AI_OFF and t.damage.is_combat_effective():
			a = ag.step_ai(tanks, delta)
			who = "scripted_ai"
		else:
			ag.update(tanks, delta)
			t.control = TankControlInput.new()
		if log_now and who != "" and t.damage.is_combat_effective():
			var info: Dictionary = ag.ai.last_info.duplicate() if who == "scripted_ai" else {}
			info["controller"] = who
			info["perception"] = ag.perception.summary()
			recorder.log_decision(t, ag.perception.vector if log_obs else PackedFloat32Array(), a, info)


func _process(delta: float) -> void:
	if _restart_timer > 0.0:
		_restart_timer -= delta
		if _restart_timer <= 0.0:
			get_tree().reload_current_scene()
			return
	if camera == null or tanks.is_empty():
		return
	var p: Tank = tanks[player_index]
	_update_vision(p, delta)
	# 전원 AI 관전: 그 전차의 AI 가 고른 시점 그대로 보여준다(조작 불가)
	camera.follow_only = ai_mode == AI_ALL
	camera.update_view(p, delta)
	_apply_fair_view(p)
	# 조준경에는 자체 거리 눈금이 있으므로 거리 격자 글자가 가리지 않게 숨긴다
	grid.visible = camera.mode != TankViewCamera.GUNNER
	var d := p.damage
	hud.text = "[%s] %s  팀 %d   (Tab: 전차 전환)   %s   ep%d  %s\n%s\n%s\n상태: %s  재장전 %.1fs  탄 %d  [%s] (1/2/3 탄종)\n궤도 L %.1f / R %.1f m/s  기어 %s   포탑 %.0f°  포 %.1f° (%+.0f°~%+.0f°)  차체 피치 %.1f°\n조준 오차 %.2f mrad (1000m에서 %.1fm)%s\n승무원: %s\n모듈: %s\n최근: %s\n조작: Q/A 좌궤도, E/D 우궤도, W/S 양쪽, Space 브레이크, 마우스 조준, 좌클릭/F 발사, R 조준 전환, 방향키 미세 조준, G 거리 격자/링, V 시선 표시\nShift 포수 조준경  C/우클릭(누른 채) 자유 시선·포 고정  B 전차장 시점·포 고정  휠/+- 확대  마우스·방향키 시선\nF1 장갑 시험장  F2 오버레이  M 지도 크기  H 탄착  P 경로  F3 리플레이  F4 경기 종료·보고서  F5 새 경기  F6 기록 폴더  F7 AI 전환  K 공정 시야(%s)\n%s" % [
		p.name, p.spec.display_name, p.team, AI_LABELS[ai_mode], recorder.episode, ReportBuilder._mmss(recorder.sim_time()),
		camera.status_text(), _vision_text(p), d.status_label(), p.reload_timer, d.ammo_remaining, p.current_shell().shell_name,
		p.track_speed_left, p.track_speed_right, p.gear_label(),
		rad_to_deg(p.turret_yaw), rad_to_deg(p.gun_pitch), p.spec.gun_depression_deg, p.spec.gun_elevation_max_deg,
		p.hull_pitch_deg(), p.aim_error_mrad, p.aim_error_mrad, "  [안정장치]" if p.damage.stabilizer_working() else "",
		", ".join(d.crew.map(func(c): return "%s:%s" % [c.id, c.status])),
		_damaged_modules(d), last_event, "켬" if _fair() else "끔", banner]
	if not detailed_hud:
		var lines := hud.text.split("\n")
		hud.text = "\n".join([lines[0], lines[1], lines[4], lines[5], lines[9],
			"마우스 조준 · 좌클릭/F 발사 · 우클릭/C 둘러보기 · Shift 조준경 · R 커서 조준 전환",
			"W/S 전후진 · Q/A 좌궤도 · E/D 우궤도 · Space 제동 · Tab 전차 전환 · G 거리 표시 · F8 상세 HUD"])
		if banner != "":
			hud.text += "\n" + banner
	_update_overlay()


func _update_overlay() -> void:
	if overlay == null or not overlay.visible:
		return
	var tl := []
	var paths := {}
	var now := recorder.sim_time()
	var known := _known_enemies(tanks[player_index])
	for i in tanks.size():
		var t: Tank = tanks[i]
		if _fair() and t.team != tanks[player_index].team and not known.has(t.name):
			continue
		tl.append({"pos": t.global_position, "yaw": t.global_rotation.y, "turret": t.global_rotation.y + t.turret_yaw,
			"team": t.team, "alive": t.damage.is_combat_effective(), "name": t.name, "selected": i == player_index})
		var pts: PackedVector3Array = recorder.paths[t.name].duplicate()
		pts.append(t.global_position)
		paths[t.name] = {"points": pts, "team": t.team}
	var shots := recorder.shots.map(func(s): return {"from": s.from, "to": s.to, "kind": s.kind, "age": now - s.t})
	minimap.set_state(tl, paths, shots)
	var hist := recorder.score_history.duplicate()
	hist.append([now, recorder.team_scores[0], recorder.team_scores[1]])
	score_graph.set_history(hist)
	score_label.text = "점수  독일 %.2f   연합군 %.2f" % [recorder.team_scores[0], recorder.team_scores[1]]
	var lines := []
	for e in recorder.recent_rewards:
		lines.append("%s %+.2f %s %s" % [ReportBuilder._mmss(e.t), e.value, e.tank_name, RewardModel.short_reason(e.reason)])
	feed_label.text = "\n".join(lines)
	if markers and markers.show_paths:
		var pl := []
		for n in paths:
			var pts3 := PackedVector3Array()
			for v in paths[n].points:
				pts3.append(Vector3(v.x, map.height_at(v.x, v.z) + 0.4, v.z))
			pl.append({"points": pts3, "color": MinimapView.TEAM_COLORS[paths[n].team]})
		markers.set_paths(pl)


func _fair() -> bool:
	return fair_view and ai_mode != AI_ALL


## 조종 전차가 지금 화면에서 보고 있는(탐지한) 적 이름 집합
func _known_enemies(p: Tank) -> Dictionary:
	var out := {}
	var pc: TankPerception = agents[player_index].perception
	for n in pc.contacts:
		if pc.contacts[n].enemy and pc.contacts[n].visible_now:
			out[n] = true
	return out


## 공정 시야: 탐지하지 못한 적은 그리지 않고, 적 이름표는 숨긴다(이름표는 숲·능선 너머로도 보이므로).
## 사람 화면에 보이는 것 = AI 관측에 들어가는 것.
func _apply_fair_view(p: Tank) -> void:
	var fair := _fair()
	var known := _known_enemies(p) if fair else {}
	for t in tanks:
		var enemy: bool = t.team != p.team
		t.visible = not fair or not enemy or known.has(t.name)
		var tag: Node3D = t.get_node_or_null("NameTag")
		if tag and t != p:
			tag.visible = not (fair and enemy)


## 거리 링 + (분석용) 시선 표시. 공정 시야에서는 시선 표시를 끈다(가려진 적 위치가 드러나므로).
func _update_vision(p: Tank, delta: float) -> void:
	grid.set_ring_center(p.global_position, p.global_rotation.y + p.turret_yaw)
	_vision_timer -= delta
	if _vision_timer > 0.0:
		return
	_vision_timer = 0.2
	vision = [] if _fair() else LineOfSight.spotted_enemies(map, p, tanks)
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	if _show_sight_lines:
		var eye := LineOfSight.eye_position(p)
		for v in vision:
			var t: Tank = get_node(NodePath(v.target))
			# 초록 = 탐지, 노랑 = 일부 보이나 미탐지, 빨강 = 가려짐
			var col := Color(0.2, 1, 0.2) if v.detected else (Color(1, 0.9, 0.2) if v.visible_fraction > 0.01 else Color(1, 0.2, 0.2, 0.5))
			verts.append(eye)
			verts.append(t.global_position + Vector3.UP * t.spec.hull_top_y())
			cols.append(col)
			cols.append(col)
	var am := ArrayMesh.new()
	if not verts.is_empty():
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_COLOR] = cols
		am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	_sight_mesh.mesh = am


## HUD 시야·소리 줄. 공정 시야 = AI 관측과 같은 내용(거리 없음), 끄면 분석용 전체 정보
func _vision_text(p: Tank) -> String:
	if _fair():
		return agents[player_index].perception.hud_text()
	var parts := []
	for v in vision:
		var why := ""
		if not v.detected and not v.blocked_by.is_empty():
			why = " (" + ",".join(v.blocked_by.keys()) + ")"
		parts.append("%s %.0fm %s%d%%%s" % [v.target, v.distance, "●" if v.detected else "○", int(v.visible_fraction * 100), why])
	return "[분석용] 시야(● 탐지 ○ 미탐지, 보임%%): %s\n%s" % ["  |  ".join(parts) if not parts.is_empty() else "-",
		agents[player_index].perception.hud_text().get_slice("\n", 1)]


func _damaged_modules(d: TankDamageState) -> String:
	var out := []
	for k in d.modules:
		if d.modules[k] != TankDamageState.MOD_OK:
			out.append("%s:%s" % [k, d.modules[k]])
	return "정상" if out.is_empty() else ", ".join(out)


func _on_shot_recorded(e: Dictionary) -> void:
	if markers == null:
		return
	var r: Dictionary = e.r
	var from := ReplayData.vec3(r.get("from", []))
	var to: Vector3 = ReplayData.vec3(r.hit_pos) if r.has("hit_pos") else from + ReplayData.vec3(r.get("dir", [0, 0, -1])) * 600.0
	markers.add_tracer(from, to)
	if r.has("hit_pos"):
		var target: Tank = tanks[int(e.target)] if int(e.get("target", -1)) >= 0 and int(e.target) < tanks.size() else null
		var attachment: Node3D = target.hit_attachment(str(r.get("part", "hull"))) if target else null
		markers.add_hit(to, MatchRecorder.shot_kind(r), -ReplayData.vec3(r.get("dir", [0, 0, -1])), attachment)
		if impact_view and (int(e.shooter) == player_index or int(e.get("target", -1)) == player_index):
			impact_view.show_shot(r, target, tanks[int(e.shooter)].current_shell().muzzle_velocity_ms)


func _on_shot(shooter: Tank, result: Dictionary) -> void:
	if result.get("hit", false):
		last_event = "%s → %s: %s %s (유효 %smm / 관통 %smm) %s" % [shooter.name, result.target_name,
			ImpactView.zone_label(result), "관통" if result.penetrated else ("도탄" if result.ricochet else "불관통"),
			result.effective_mm, result.pen_roll_mm, ""]
	else:
		last_event = "%s: 빗나감/차단 (%s)" % [shooter.name, result.get("blocked_by", "")]
	if not _headless:
		print(last_event)


func _on_knocked_out(tank: Tank, cause: String) -> void:
	print("%s 전투불능: %s" % [tank.name, cause])


func _on_episode_ended(s: Dictionary) -> void:
	var w := int(s.winner)
	var who: String = "무승부" if w < 0 else ReportBuilder.TEAM_LABELS[w] + " 승리"
	print("에피소드 %d 종료(%s): %s  점수 %s  보고서: %s" % [s.episode, s.reason, who, s.team_scores, recorder.last_report_path])
	banner = "에피소드 %d 종료: %s — 보고서 저장됨(F6 폴더 열기), F5 새 경기, F3 리플레이" % [s.episode, who]
	if _headless:
		episodes_left -= 1
		if episodes_left > 0:
			get_tree().reload_current_scene.call_deferred()
		else:
			get_tree().quit.call_deferred()
	elif ai_mode == AI_ALL:
		_restart_timer = 5.0
