extends Node3D
## 리플레이 뷰어: 지난 경기(사람 플레이·AI 학습 에피소드)를 열어 여러 시점에서 다시 본다.
##
## events.jsonl 에 저장된 상태(지형 격자, 장애물 치수, 전차 자세, 사격)만으로 장면을 다시 만든다.
## 물리를 다시 돌리지 않으므로 그래픽(모델·재질·카메라)을 바꿔도 같은 경기가 똑같이 재구성된다.
##
## 시점: 1 자유 카메라  2 추적(3인칭)  3 포수 시점  4 위에서 보기  5 궤도(선택 전차 주위)
## 실행: 게임에서 F3, 또는 godot --path . res://recording/replay_viewer.tscn -- --replay=<events.jsonl>

const CAM_FREE := 0
const CAM_CHASE := 1
const CAM_GUNNER := 2
const CAM_TOP := 3
const CAM_ORBIT := 4
const CAM_LABELS := ["자유 카메라", "추적", "포수 시점", "위에서 보기", "궤도"]
const SPEEDS := [0.1, 0.25, 0.5, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0]
const PATH_STRIDE := 5

var data: ReplayData
var t := 0.0
var playing := true
var speed_i := 3
var selected := 0
var cam_mode := CAM_CHASE

var world: Node3D
var map: HillMap
var puppets: Array = []
var markers: WorldMarkers
var camera: Camera3D
# 자유/궤도 카메라 상태
var free_pos := Vector3(0, 120, 300)
var free_yaw := 0.0
var free_pitch := -0.5
var free_speed := 40.0
var orbit_yaw := 0.6
var orbit_pitch := -0.35
var orbit_dist := 25.0
var top_height := 600.0
var gunner_fov := 25.0          # 포수 조준경 시야각(휠로 확대/축소)
var _looking := false
var _hits_until := -1          # 탄착 표시가 반영된 마지막 사격 인덱스
var _last_t := -1.0
var _full_paths: Array = []    # 전차별 PackedVector3Array(지면 위)
var _path_frames: Array = []   # 경로 점의 프레임 인덱스

# UI
var ui: CanvasLayer
var info: Label
var help: Label
var minimap: MinimapView
var score_graph: ScoreGraph
var slider: HSlider
var time_label: Label
var file_panel: PanelContainer
var file_list: ItemList
var file_paths: Array = []
var _slider_dragging := false
var _setting_slider := false


func _ready() -> void:
	_setup_env()
	_setup_ui()
	var arg := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--replay="):
			arg = a.get_slice("=", 1)
	_refresh_file_list()
	if arg != "":
		open_replay(arg)
	elif not file_paths.is_empty():
		open_replay(file_paths[0])
	file_panel.visible = data == null


func _setup_env() -> void:
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.62, 0.72, 0.85)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.6, 0.6, 0.6)
	add_child(env)
	camera = Camera3D.new()
	camera.far = 4000.0
	add_child(camera)
	camera.current = true


func _setup_ui() -> void:
	ui = CanvasLayer.new()
	add_child(ui)
	info = _label(Vector2(10, 10), 14)
	help = _label(Vector2(10, 0), 13)
	help.text = "Space 재생/정지   ←/→ 5초 (Shift 30초)   , . 한 프레임   -/+ 속도   Home/End 처음/끝\n1 자유  2 추적  3 포수  4 위에서  5 궤도   Tab 다음 전차   우클릭 드래그 = 시점 회전, 휠 = 거리·속도·조준경 배율, 자유 카메라 WASD·Q/E\nH 탄착  P 경로  O 파일 목록  R 보고서 열기  F2 화면 표시 숨김  Esc 게임으로"
	minimap = MinimapView.new()
	ui.add_child(minimap)
	score_graph = ScoreGraph.new()
	ui.add_child(score_graph)
	slider = HSlider.new()
	slider.step = 0.01
	slider.drag_started.connect(func(): _slider_dragging = true)
	slider.drag_ended.connect(func(_c): _slider_dragging = false)
	slider.value_changed.connect(_on_slider)
	ui.add_child(slider)
	time_label = _label(Vector2.ZERO, 14)
	# 파일 목록
	file_panel = PanelContainer.new()
	file_panel.position = Vector2(10, 180)
	file_panel.custom_minimum_size = Vector2(420, 360)
	var vb := VBoxContainer.new()
	file_panel.add_child(vb)
	var title := Label.new()
	title.text = "지난 경기 (더블클릭으로 열기)"
	vb.add_child(title)
	file_list = ItemList.new()
	file_list.custom_minimum_size = Vector2(400, 290)
	file_list.item_activated.connect(func(i): open_replay(file_paths[i]); file_panel.visible = false)
	vb.add_child(file_list)
	var hb := HBoxContainer.new()
	vb.add_child(hb)
	for b in [["새로고침", _refresh_file_list], ["기록 폴더 열기", func(): OS.shell_open(ProjectSettings.globalize_path("user://logs"))],
			["닫기", func(): file_panel.visible = false]]:
		var btn := Button.new()
		btn.text = b[0]
		btn.pressed.connect(b[1])
		hb.add_child(btn)
	ui.add_child(file_panel)
	_layout()
	get_viewport().size_changed.connect(_layout)


func _label(pos: Vector2, fs: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 4)
	ui.add_child(l)
	return l


func _layout() -> void:
	var vs := get_viewport().get_visible_rect().size
	minimap.size = Vector2(260, 260)
	minimap.position = Vector2(vs.x - 270, 10)
	score_graph.size = Vector2(260, 80)
	score_graph.position = Vector2(vs.x - 270, 276)
	slider.position = Vector2(10, vs.y - 34)
	slider.size = Vector2(vs.x - 200, 24)
	time_label.position = Vector2(vs.x - 180, vs.y - 36)
	help.position = Vector2(10, vs.y - 100)


func _refresh_file_list() -> void:
	file_list.clear()
	file_paths.clear()
	var root := "user://logs/replays"
	var da := DirAccess.open(root)
	if da == null:
		file_list.add_item("(기록 없음 — 게임을 한 판 하면 생깁니다)")
		return
	var dirs := Array(da.get_directories())
	dirs.sort()
	dirs.reverse()
	for d in dirs:
		var p := "%s/%s/events.jsonl" % [root, d]
		if FileAccess.file_exists(p):
			file_paths.append(p)
			file_list.add_item(d)


func open_replay(p: String) -> void:
	var d := ReplayData.load_file(p)
	if not d.ok():
		info.text = "열 수 없음: %s\n%s" % [p, d.error]
		return
	data = d
	if world:
		world.queue_free()
	world = Node3D.new()
	add_child(world)
	map = HillMap.new()
	map.load_record(data.header.map)
	world.add_child(map)
	puppets.clear()
	for td in data.tanks():
		var tk := Tank.new()
		tk.name = td.name
		tk.setup(td.tank, int(td.team), 1)
		world.add_child(tk)
		tk.set_physics_process(false)
		WorldMarkers.attach_label(tk, MinimapView.TEAM_COLORS[int(td.team)])
		puppets.append(tk)
	markers = WorldMarkers.new()
	world.add_child(markers)
	minimap.set_map(data.header.map)
	_build_paths()
	t = 0.0
	_last_t = -1.0
	_hits_until = -1
	selected = 0
	_setting_slider = true
	slider.max_value = data.duration()
	slider.value = 0.0
	_setting_slider = false
	playing = true
	var p0: Vector3 = data.pose(0, 0.0).xform.origin
	free_pos = p0 + Vector3(0, 60, 120)
	_apply(0.0)


func _build_paths() -> void:
	_full_paths.clear()
	_path_frames.clear()
	for td in data.tanks():
		var id := int(td.id)
		var pts := PackedVector3Array()
		var idx := PackedInt32Array()
		for i in range(0, data.frames.size(), PATH_STRIDE):
			var row: Array = data.frames[i].s[id]
			var x: float = data.field(row, "x")
			var z: float = data.field(row, "z")
			pts.append(Vector3(x, map.height_at(x, z) + 0.4, z))
			idx.append(i)
		_full_paths.append(pts)
		_path_frames.append(idx)


func _process(delta: float) -> void:
	if data == null:
		return
	if playing and not _slider_dragging:
		t = minf(t + delta * SPEEDS[speed_i], data.duration())
		if t >= data.duration():
			playing = false
	_apply(delta)


func _apply(delta: float) -> void:
	t = clampf(t, 0.0, data.duration())
	for i in puppets.size():
		var ps := data.pose(i, t)
		puppets[i].apply_replay_pose(ps.xform, ps.turret_yaw, ps.gun_pitch, ps.status >= MatchRecorder.STATUS_KO)
	_update_markers()
	_update_camera(delta)
	_update_ui()
	_last_t = t


func _update_markers() -> void:
	if t < _last_t:
		markers.clear_hits()
		_hits_until = -1
	while _hits_until + 1 < data.shots.size() and float(data.shots[_hits_until + 1].t) <= t:
		_hits_until += 1
		var e: Dictionary = data.shots[_hits_until]
		if e.r.has("hit_pos"):
			markers.add_hit(ReplayData.vec3(e.r.hit_pos), MatchRecorder.shot_kind(e.r))
	var tracers := []
	for i in range(_hits_until, -1, -1):
		var e: Dictionary = data.shots[i]
		var age := t - float(e.t)
		if age > WorldMarkers.TRACER_S:
			break
		var pts := data.shot_points(e)
		tracers.append({"from": pts[0], "to": pts[1], "age": age})
	markers.set_tracers(tracers)
	if markers.show_paths:
		var fi := data.frame_index(t)
		var pl := []
		for id in _full_paths.size():
			var n: int = _path_frames[id].bsearch(fi, false)
			var pts: PackedVector3Array = _full_paths[id].slice(0, n)
			pts.append(puppets[id].global_position + Vector3.UP * 0.4)
			pl.append({"points": pts, "color": MinimapView.TEAM_COLORS[data.tank_team(id)]})
		markers.set_paths(pl)


func _update_camera(delta: float) -> void:
	var tk: Tank = puppets[selected]
	camera.fov = 70.0
	match cam_mode:
		CAM_FREE:
			var dir := Vector3.ZERO
			if Input.is_physical_key_pressed(KEY_W): dir.z -= 1
			if Input.is_physical_key_pressed(KEY_S): dir.z += 1
			if Input.is_physical_key_pressed(KEY_A): dir.x -= 1
			if Input.is_physical_key_pressed(KEY_D): dir.x += 1
			if Input.is_physical_key_pressed(KEY_E): dir.y += 1
			if Input.is_physical_key_pressed(KEY_Q): dir.y -= 1
			var b := Basis.from_euler(Vector3(free_pitch, free_yaw, 0))
			var mult := 4.0 if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0
			free_pos += (b * Vector3(dir.x, 0, dir.z) + Vector3.UP * dir.y) * free_speed * mult * delta
			camera.global_transform = Transform3D(b, free_pos)
		CAM_CHASE:
			var yaw := tk.global_rotation.y + tk.turret_yaw
			var back := Vector3(sin(yaw), 0, cos(yaw))
			var target := tk.global_position + Vector3.UP * 3.0
			camera.global_position = target + back * 14.0 + Vector3.UP * 4.0
			camera.look_at(target - back * 30.0, Vector3.UP)
		CAM_GUNNER:
			var g := tk.gun_direction()
			# 포구 바로 앞(자기 포탑 표면의 탄착 표시가 시야를 가리지 않도록)
			var eye := tk.muzzle_position() + g * 0.5 + Vector3.UP * 0.25
			camera.global_position = eye
			camera.look_at(eye + g * 100.0, Vector3.UP)
			camera.fov = gunner_fov
		CAM_TOP:
			var c := tk.global_position
			camera.global_position = c + Vector3(0, top_height, 0.001)
			camera.look_at(c, Vector3.FORWARD)
		CAM_ORBIT:
			var c2 := tk.global_position + Vector3.UP * 2.0
			var off := Basis.from_euler(Vector3(orbit_pitch, orbit_yaw, 0)) * Vector3(0, 0, orbit_dist)
			camera.global_position = c2 + off
			camera.look_at(c2, Vector3.UP)


func _update_ui() -> void:
	if not _slider_dragging:
		_setting_slider = true
		slider.value = t
		_setting_slider = false
	time_label.text = "%s / %s  ×%s%s" % [ReportBuilder._mmss(t), ReportBuilder._mmss(data.duration()), SPEEDS[speed_i], "" if playing else "  ❚❚"]
	var ps := data.pose(selected, t)
	var td: Dictionary = data.tanks()[selected]
	var fr: Dictionary = data.frames[data.frame_index(t)]
	var r: Array = fr.get("r", [])
	var a: Array = ps.action
	var lines := ["리플레이 ep%d  %s   시점: %s (1~5)" % [int(data.header.get("episode", 0)), data.path.get_base_dir().get_file(), CAM_LABELS[cam_mode]],
		"선택 [Tab]: %s (%s, %s)  상태 %s  속도 %.1f m/s  재장전 %.1fs  점수 %.2f" % [td.name, td.display_name,
			ReportBuilder.TEAM_LABELS[int(td.team)], ["정상", "손상", "전투불능", "파괴"][clampi(ps.status, 0, 3)], ps.speed,
			float(ps.reload), float(r[selected]) if selected < r.size() else 0.0],
		"입력: 좌궤도 %+.2f  우궤도 %+.2f  브레이크 %.2f  포탑 %+.2f  포 %+.2f  발사 %d" % [a[0], a[1], a[2], a[3], a[4], int(a[5])],
		"팀 점수: 독일 %.2f   연합군 %.2f" % [float(fr.score[0]), float(fr.score[1])], ""]
	var dec := _decision_at(selected, t)
	if not dec.is_empty():
		lines.insert(3, "AI 판단: %s" % JSON.stringify(dec.get("info", {})))
	for e in _recent_events(10.0):
		lines.append(e)
	info.text = "\n".join(lines)
	# 미니맵
	var tl := []
	var paths := {}
	for i in puppets.size():
		var pk: Tank = puppets[i]
		var st := int(data.pose(i, t).status)
		tl.append({"pos": pk.global_position, "yaw": pk.global_rotation.y, "turret": pk.global_rotation.y + pk.turret_yaw,
			"team": data.tank_team(i), "alive": st < MatchRecorder.STATUS_KO, "name": pk.name, "selected": i == selected})
		var n: int = _path_frames[i].bsearch(data.frame_index(t), false)
		var pts: PackedVector3Array = _full_paths[i].slice(0, n)
		pts.append(pk.global_position)
		paths[pk.name] = {"points": pts, "team": data.tank_team(i)}
	var shots := []
	for i in range(0, _hits_until + 1):
		var e: Dictionary = data.shots[i]
		var sp := data.shot_points(e)
		shots.append({"from": sp[0], "to": sp[1], "kind": MatchRecorder.shot_kind(e.r), "age": t - float(e.t)})
	minimap.set_state(tl, paths, shots)
	if score_graph.history.is_empty() or score_graph.t_max != data.duration():
		var h := []
		for f in data.frames:
			h.append([float(f.t), float(f.score[0]), float(f.score[1])])
		score_graph.set_history(h, t, data.duration())
	else:
		score_graph.cursor_t = t
		score_graph.queue_redraw()


func _decision_at(id: int, at: float) -> Dictionary:
	var best := {}
	for d in data.decisions:
		if float(d.t) > at:
			break
		if int(d.tank) == id:
			best = d
	return best if not best.is_empty() and at - float(best.t) < 1.0 else {}


func _recent_events(window: float) -> Array:
	var out := []
	for i in range(_hits_until, -1, -1):
		var e: Dictionary = data.shots[i]
		if t - float(e.t) > window:
			break
		var r: Dictionary = e.r
		var kind := MatchRecorder.shot_kind(r)
		out.append("%s  %s → %s  %s %s %s" % [ReportBuilder._mmss(e.t), data.tank_name(int(e.shooter)),
			data.tank_name(int(e.target)) if r.get("hit", false) else r.get("blocked_by", "-"),
			ReportBuilder.KIND_LABEL.get(kind, kind), r.get("zone", ""), ",".join(r.get("events", []).filter(func(x): return str(x).begins_with("knocked_out")))])
		if out.size() >= 6:
			break
	return out


func _on_slider(v: float) -> void:
	if _setting_slider or data == null:
		return
	t = v


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			_looking = event.pressed
		elif event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var k := 0.85 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 0.85
			match cam_mode:
				CAM_FREE: free_speed = clampf(free_speed / k, 5.0, 400.0)
				CAM_TOP: top_height = clampf(top_height * k, 40.0, 1600.0)
				CAM_ORBIT: orbit_dist = clampf(orbit_dist * k, 6.0, 400.0)
				CAM_GUNNER: gunner_fov = clampf(gunner_fov * k, 4.0, 70.0)
		return
	if event is InputEventMouseMotion and _looking:
		if cam_mode == CAM_FREE:
			free_yaw -= event.relative.x * 0.005
			free_pitch = clampf(free_pitch - event.relative.y * 0.005, -1.5, 1.5)
		elif cam_mode == CAM_ORBIT:
			orbit_yaw -= event.relative.x * 0.005
			orbit_pitch = clampf(orbit_pitch - event.relative.y * 0.005, -1.5, 0.3)
		return
	if not (event is InputEventKey and event.pressed):
		return
	var shift: bool = event.shift_pressed
	match event.physical_keycode:
		KEY_ESCAPE:
			get_tree().change_scene_to_file("res://main.tscn")
		KEY_O:
			_refresh_file_list()
			file_panel.visible = not file_panel.visible
		KEY_F2:
			for c in ui.get_children():
				if c != file_panel:
					c.visible = not c.visible
	if data == null:
		return
	match event.physical_keycode:
		KEY_SPACE:
			if t >= data.duration():
				t = 0.0
			playing = not playing
		KEY_LEFT:
			t = maxf(t - (30.0 if shift else 5.0), 0.0)
		KEY_RIGHT:
			t = minf(t + (30.0 if shift else 5.0), data.duration())
		KEY_COMMA:
			playing = false
			t = maxf(t - 1.0 / data.header.physics_hz * data.header.sample_every, 0.0)
		KEY_PERIOD:
			playing = false
			t = minf(t + 1.0 / data.header.physics_hz * data.header.sample_every, data.duration())
		KEY_HOME:
			t = 0.0
		KEY_END:
			t = data.duration()
		KEY_MINUS, KEY_KP_SUBTRACT:
			speed_i = maxi(speed_i - 1, 0)
		KEY_EQUAL, KEY_KP_ADD:
			speed_i = mini(speed_i + 1, SPEEDS.size() - 1)
		KEY_TAB:
			selected = (selected + (puppets.size() - 1 if shift else 1)) % puppets.size()
		KEY_1, KEY_2, KEY_3, KEY_4, KEY_5:
			var m: int = event.physical_keycode - KEY_1
			if m == CAM_FREE and cam_mode != CAM_FREE:
				free_pos = camera.global_position
				var e := camera.global_transform.basis.get_euler()
				free_pitch = e.x
				free_yaw = e.y
			cam_mode = m
		KEY_H:
			markers.show_hits = not markers.show_hits
		KEY_P:
			markers.show_paths = not markers.show_paths
			minimap.show_paths = markers.show_paths
		KEY_R:
			var rp := data.path.get_base_dir() + "/report.html"
			if not FileAccess.file_exists(rp):
				ReportBuilder.build_files(data.path, "user://logs/episodes.csv")
			OS.shell_open(ProjectSettings.globalize_path(rp))
