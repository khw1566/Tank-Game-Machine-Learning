class_name HumanPilot
extends Node
## 실제 전투 시범 수집: 학습 환경(training_env.gd)의 전차 한 대를 사람이 조종한다.
##
## - 화면·조작은 V7 시범 수집의 카메라 중앙 조준(TankViewCamera.centered_pointer)을 그대로 쓴다.
##   마우스 = 시선, 포탑·포가 화면 중앙의 조준점을 따라간다. 시작 시점은 포수 조준경이다.
## - 결정 주기(0.1초 = 물리 3틱)마다 사람 입력을 PPO 정책과 같은 11개 행동(-1~1)으로 바꾸고,
##   int8 양자화·policy_to_action 을 PPO 와 똑같이 거쳐 3틱 동안 유지한다.
##   → 기록된 (관측, 행동) 쌍은 정책이 그대로 낼 수 있는 행동이다(행동 복제 정답).
## - 관측은 같은 결정 시점에 학습 전차와 같은 함수(_observation)로 만든다.
##
## 조작: W/S 전후진 · A/D 방향(안쪽 궤도를 멈춰 선회) · Space 제동 · 마우스 조준 · 좌클릭/F 발사
##       Shift 포수 조준경 ↔ 3인칭 · B 전차장 · 우클릭/C(3인칭) 둘러보기 · 휠 배율 · 1/2/3 탄종
##       Esc/P 일시정지

const STEP_S := float(TankAgent.PERCEIVE_EVERY) / 30.0

var env: Node
var tank: Tank
var agent: TankAgent
var camera: TankViewCamera
var reticle: HumanPilotReticle
var hud: Label
var banner: Label
var paused := false
## 판이 시작되면 첫 입력이 들어올 때까지 시간을 멈춘다(판 사이 쉬는 시간)
var waiting := true
var decisions := 0
var last_raw: Array = []
var _prev_look := Vector2.ZERO
var _prev_fov := 0.0
var _result_text := ""
## 자동 시험용(--human-autopilot): 사람 대신 전진·선회·주기 사격 입력을 넣는다
var autopilot := "--human-autopilot" in OS.get_cmdline_user_args()
## 사격 표시: 예광탄(비행 중인 포탄), 탄착 표시, 포구 섬광, 사격 기록
var _tracer := MeshInstance3D.new()
var _tracer_mesh := ImmediateMesh.new()
var _marks: Array = []
var _shot_log: Array = []
var log_label: Label
var _flash: OmniLight3D
var _flash_t := 0.0
var _layer: CanvasLayer


func _ready() -> void:
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("#aec9de")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color("#c3ccd4")
	environment.environment.ambient_light_energy = 0.7
	add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)
	camera = TankViewCamera.new()
	camera.reticle.free()
	camera.reticle = null
	camera.centered_pointer = true
	add_child(camera)
	# 입력은 _input 에서 한 번만 넘긴다(add_child 뒤에 꺼야 _ready 가 다시 켜지 않는다: Shift·휠 이중 처리 방지)
	camera.set_process_unhandled_input(false)
	camera.current = true
	var layer := CanvasLayer.new()
	add_child(layer)
	_layer = layer
	reticle = HumanPilotReticle.new()
	reticle.rig = camera
	reticle.pilot = self
	layer.add_child(reticle)
	hud = Label.new()
	hud.position = Vector2(12, 10)
	hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(hud)
	banner = Label.new()
	banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	banner.position = Vector2(-300, 150)
	banner.size = Vector2(600, 120)
	banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	banner.add_theme_font_size_override("font_size", 22)
	banner.add_theme_color_override("font_outline_color", Color.BLACK)
	banner.add_theme_constant_override("outline_size", 6)
	layer.add_child(banner)
	log_label = Label.new()
	log_label.anchor_top = 1.0
	log_label.anchor_bottom = 1.0
	log_label.offset_left = 120
	log_label.offset_top = -190
	log_label.offset_right = 900
	log_label.offset_bottom = -12
	log_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	log_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	log_label.add_theme_font_size_override("font_size", 17)
	log_label.add_theme_color_override("font_outline_color", Color.BLACK)
	log_label.add_theme_constant_override("outline_size", 5)
	layer.add_child(log_label)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_tracer.mesh = _tracer_mesh
	_tracer.material_override = mat
	_tracer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_tracer)
	_flash = OmniLight3D.new()
	_flash.light_color = Color(1.0, 0.8, 0.45)
	_flash.omni_range = 14.0
	_flash.light_energy = 0.0
	add_child(_flash)
	DisplayServer.window_set_title("Tank Game · 실제 전투 시범 수집 (행동 복제)")


## 새 판: 조종 전차와 관측 객체를 다시 연결한다. 시점은 포수 조준경에서 시작한다.
func bind(p_env: Node, p_tank: Tank, p_agent: TankAgent) -> void:
	env = p_env
	tank = p_tank
	agent = p_agent
	camera.reset_pointer()
	camera.view = agent.view       # 화면 시점 = 관측 시점(같은 객체)
	camera.map = env.map
	camera.update_view(tank, 0.0)
	camera.set_mode(TankView.GUNNER)
	camera.pointer_range = 2500.0
	# 조준점은 지금 포가 향한 곳에서 시작(포수 조준경이 땅을 보며 시작하지 않게)
	camera._pointer_angles = Vector2(tank.heading + tank.turret_yaw, tank.gun_pitch)
	camera._pointer_initialized = true
	camera.pointer_active = false
	paused = false
	waiting = true
	decisions = 0
	last_raw = []
	_result_text = ""
	_prev_look = _look_state()
	_prev_fov = agent.view.fov()
	for m in _marks:
		m.node.queue_free()
		if m.label != null:
			m.label.queue_free()
	_marks.clear()
	for t in env.tanks:
		if not t.shot_fired.is_connected(_on_shot):
			t.shot_fired.connect(_on_shot)
	if not tank.shot_launched.is_connected(_on_launch):
		tank.shot_launched.connect(_on_launch)
	_show_banner()


func blocks_time() -> bool:
	return paused or waiting


## 결정 시점마다 1회: 사람 입력 → 정책 공간 행동 11개(-1~1, 양자화 전)
func sample() -> Array:
	var keys := _autopilot_keys() if autopilot else _read_keys()
	var looking := camera.is_free_look_pressed() or camera.mode == TankView.COMMANDER
	camera.pointer_active = true
	camera.update_pointer(tank)
	var aim := Vector2.ZERO if looking else camera.pointer_commands(tank, STEP_S)
	var traverse := keys.turret_traverse if keys.turret_traverse != 0.0 else aim.x
	var elevation := keys.gun_elevation if keys.gun_elevation != 0.0 else aim.y
	if looking:
		traverse = 0.0
		elevation = 0.0
	var fire := keys.fire or (Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) and not autopilot)
	var view: TankView = agent.view
	var mode := view.mode
	# 시선 회전(전차장·3인칭 자유 시선): 이번 결정 동안 바뀐 각도를 TankView.apply_action 의 속도 단위로 되돌린다
	var look := _look_state()
	var scale := view.fov() / TankView.THIRD_FOV
	var per := TankView.KEY_LOOK_RATE * scale * STEP_S
	var d_look := Vector2(wrapf(look.x - _prev_look.x, -PI, PI), look.y - _prev_look.y)
	_prev_look = look
	var look_x := clampf(d_look.x / per, -1.0, 1.0) if looking else 0.0
	var look_y := clampf(d_look.y / per, -1.0, 1.0) if looking else 0.0
	var zoom := 0.0
	if mode == TankView.GUNNER:
		zoom = 0.75 if view.gunner_zoom > 0 else -0.75
	elif mode == TankView.COMMANDER:
		var steps := log(_prev_fov / maxf(view.fov(), 0.001)) / log(TankView.ZOOM_STEP)
		zoom = clampf(steps / (TankView.ZOOM_RATE * STEP_S), -1.0, 1.0)
	_prev_fov = view.fov()
	var raw := [keys.left_track, keys.right_track, 1.0 if keys.brake > 0.0 else -0.5,
		clampf(traverse, -1.0, 1.0), clampf(elevation, -1.0, 1.0), 0.5 if fire else -0.5,
		[-2.0 / 3.0, 0.0, 2.0 / 3.0][mode], 0.5 if view.free_look else -0.5, look_x, look_y, zoom]
	if waiting and (autopilot or _any_input(raw, keys)):
		waiting = false
		banner.text = ""
	return raw


## 사람용 키 배치: W/S 스로틀, A/D 방향.
## 달리면서 A/D = 안쪽 궤도를 멈추고 바깥 궤도로 민다(그쪽을 축으로 선회).
## 멈춰서 A/D = 제자리 선회 가능 전차(티거)는 두 궤도를 반대로, 아니면 바깥 궤도만 지금 기어 방향으로(후진으로 바뀌지 않게).
## 결과는 정책이 낼 수 있는 궤도 명령(-1~1) 그대로다.
func _read_keys() -> TankControlInput:
	var c := KeyboardController.read()
	var t := KeyboardController._axis(KEY_W, KEY_S)
	var s := KeyboardController._axis(KEY_D, KEY_A)
	if t != 0.0:
		c.left_track = 0.0 if s < 0.0 else t
		c.right_track = 0.0 if s > 0.0 else t
	elif s != 0.0:
		if tank.spec.neutral_steer:
			c.left_track = s
			c.right_track = -s
		else:
			var g := float(tank.gear if tank.gear != 0 else 1)
			c.left_track = g if s > 0.0 else 0.0
			c.right_track = g if s < 0.0 else 0.0
	else:
		c.left_track = 0.0
		c.right_track = 0.0
	return c


func _on_launch(shooter: Tank, _result: Dictionary) -> void:
	if shooter == tank:
		_flash.global_position = tank.muzzle_position()
		_flash_t = 0.09
		_flash.light_energy = 6.0


func _on_shot(shooter: Tank, r: Dictionary) -> void:
	if tank == null or not is_instance_valid(tank):
		return
	var mine := shooter == tank
	var at_me := str(r.get("target_name", "")) == str(tank.name)
	var hp: Array = r.get("hit_pos", [])
	var outcome := _outcome(r)
	var color: Color = {"관통": Color(1.0, 0.25, 0.15), "격파": Color(1.0, 0.1, 0.6), "도탄": Color(0.4, 0.8, 1.0),
		"비관통": Color(1.0, 0.85, 0.2)}.get(outcome, Color(0.85, 0.85, 0.8))
	if hp.size() == 3 and (mine or at_me):
		_add_mark(Vector3(hp[0], hp[1], hp[2]), color, outcome if mine else "", 1.0 if mine else 0.6)
	if not (mine or at_me):
		return
	var who := _tank_label(str(r.get("target_name", ""))) if mine else _tank_label(str(shooter.name))
	var zone := _zone_label(str(r.get("zone", "")))
	var dist := float(r.get("distance_m", 0.0))
	var src: Array = r.get("from", [])
	if dist <= 0.0 and hp.size() == 3 and src.size() == 3:
		dist = Vector3(src[0], src[1], src[2]).distance_to(Vector3(hp[0], hp[1], hp[2]))
	var line := ""
	if mine:
		line = "▶ 내 사격: %s" % outcome
		if bool(r.get("hit", false)):
			line += " · %s %s" % [who, zone]
		elif outcome == "엄폐물에 막힘":
			line += " (%s)" % str(r.get("blocked_by"))
	else:
		line = "◀ 피격: %s · %s 의 사격 · %s" % [outcome, who, zone]
	if dist > 0.0:
		line += " · %d m" % int(dist)
	_shot_log.append([line, color])
	if _shot_log.size() > 6:
		_shot_log.pop_front()
	print("[demo] ", line)


func _outcome(r: Dictionary) -> String:
	if not bool(r.get("hit", false)):
		var b := str(r.get("blocked_by", "none"))
		return "빗나감" if b == "none" or b == "" else ("지면" if "ground" in b.to_lower() or "terrain" in b.to_lower() else "엄폐물에 막힘")
	for e in r.get("events", []):
		if str(e).begins_with("knocked_out"):
			return "격파"
	if bool(r.get("penetrated", false)):
		return "관통"
	if bool(r.get("ricochet", false)):
		return "도탄"
	return "비관통"


func _tank_label(n: String) -> String:
	for t in env.tanks:
		if str(t.name) == n:
			return t.spec.display_name if t.spec.display_name != "" else t.spec.id
	return n


static func _zone_label(z: String) -> String:
	if z == "":
		return ""
	var out := z
	for pair in [["hull", "차체"], ["turret", "포탑"], ["mantlet", "포 방패"], ["front", "정면"], ["side", "측면"],
			["rear", "후면"], ["roof", "상면"], ["upper", "상부"], ["lower", "하부"], ["track", "궤도"], ["_", " "]]:
		out = out.replace(pair[0], pair[1])
	return out


func _add_mark(pos: Vector3, color: Color, text: String, size: float) -> void:
	var root := Node3D.new()
	add_child(root)
	root.global_position = pos
	var ball := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.5 * size
	sphere.height = 1.0 * size
	ball.mesh = sphere
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = color
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	ball.material_override = m
	ball.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	root.add_child(ball)
	var label: Label = null
	if text != "":
		# 화면 글씨(조준경 배율과 무관하게 같은 크기): 탄착 지점 위에 띄운다
		label = Label.new()
		label.text = text
		label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		label.add_theme_font_size_override("font_size", 20)
		label.add_theme_color_override("font_color", color)
		label.add_theme_color_override("font_outline_color", Color.BLACK)
		label.add_theme_constant_override("outline_size", 6)
		_layer.add_child(label)
	_marks.append({"node": root, "mat": m, "t": 0.0, "life": 6.0, "label": label, "pos": pos})


func _update_effects(delta: float) -> void:
	if _flash_t > 0.0:
		_flash_t -= delta
		if _flash_t <= 0.0:
			_flash.light_energy = 0.0
	var keep := []
	for mk in _marks:
		mk.t += delta
		var f: float = 1.0 - float(mk.t) / float(mk.life)
		if f <= 0.0:
			mk.node.queue_free()
			if mk.label != null:
				mk.label.queue_free()
			continue
		if mk.label != null:
			var behind := camera.is_position_behind(mk.pos)
			mk.label.visible = not behind
			if not behind:
				mk.label.position = camera.unproject_position(mk.pos) + Vector2(-24, -44 - mk.t * 10.0)
			mk.label.modulate.a = f
		mk.mat.albedo_color.a = f
		mk.node.scale = Vector3.ONE * (1.0 + mk.t * 1.5)
		keep.append(mk)
	_marks = keep
	_tracer_mesh.clear_surfaces()
	var field = env.projectiles if env != null else null
	if field == null or field.active.is_empty():
		return
	var eye := camera.global_position
	_tracer_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES)
	for pr in field.active:
		var shooter = pr.shooter.get_ref()
		var head: Vector3 = pr.pos
		var vel: Vector3 = pr.velocity
		var dir := vel.normalized()
		var tail := head - dir * minf(35.0, maxf(float(pr.distance), 0.5))
		var dist := eye.distance_to(head)
		var w := clampf(dist * 0.0025, 0.06, 2.5)
		var side := dir.cross(eye - head).normalized() * w
		var c := Color(1.0, 0.75, 0.3) if shooter == tank else Color(1.0, 0.4, 0.3)
		var c0 := Color(c, 0.0)
		for v in [[tail - side, c0], [head - side, c], [head + side, c], [tail - side, c0], [head + side, c], [tail + side, c0]]:
			_tracer_mesh.surface_set_color(v[1])
			_tracer_mesh.surface_add_vertex(v[0])
	_tracer_mesh.surface_end()


func _autopilot_keys() -> TankControlInput:
	var k := decisions
	var shot_dir := OS.get_environment("TANKGAME_DEMO_SHOTS")
	if shot_dir != "" and k in [60, 61, 62, 90, 101, 102, 141, 180]:
		get_viewport().get_texture().get_image().save_png(shot_dir.path_join("demo_%03d_%s.png" % [k, TankView.MODE_LABELS[agent.view.mode]]))
	if k == 100:
		camera.set_mode(TankView.THIRD)
	if k == 95:
		camera._pointer_motion += Vector2(0, -40)
	if k == 40:
		camera._pointer_motion += Vector2(-120, 0)   # 마우스를 왼쪽으로 민 것처럼: 포탑이 따라 돈다
	var c := TankControlInput.new()
	c.left_track = 1.0
	c.right_track = 0.6 if (k / 50) % 2 == 0 else 1.0
	c.fire = k % 40 == 20
	return c


func _any_input(raw: Array, keys: TankControlInput) -> bool:
	return keys.to_array().count(0.0) < 6 or absf(raw[3]) > 0.05 or absf(raw[4]) > 0.05 or float(raw[5]) > 0.0


func _look_state() -> Vector2:
	var v: TankView = agent.view
	return Vector2(v.cmd_yaw, v.cmd_pitch) if v.mode == TankView.COMMANDER else Vector2(v.orbit_yaw, v.orbit_pitch)


## 사람 조작은 시점을 카메라가 직접 바꾸므로 조종 입력(6개)만 적용한다.
func apply(action: Array) -> void:
	last_raw = action
	tank.control = agent.view.apply_locks(TankControlInput.from_array(action))


func finish(result: Dictionary) -> void:
	var won := int(result.get("winner", -1)) == tank.team
	_result_text = "%s · %s\n조작 %d개 저장 · 아무 조작이나 하면 다음 판" % [
		"승리" if won else ("무승부·시간 초과" if int(result.get("winner", -1)) < 0 else "패배"),
		str(result.get("reason", "")), decisions]


func _show_banner() -> void:
	banner.text = (_result_text + "\n\n" if _result_text != "" else "") + "준비 · 조작을 시작하면 시간이 흐르고 기록됩니다"


func _input(event: InputEvent) -> void:
	if tank == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		match event.physical_keycode:
			KEY_P, KEY_ESCAPE:
				paused = not paused
				banner.text = "일시정지 · Esc/P 로 계속" if paused else ""
				get_viewport().set_input_as_handled()
				return
			KEY_1, KEY_2, KEY_3:
				tank.select_ammo(event.physical_keycode - KEY_1)
	if paused:
		return
	camera.pointer_active = true
	camera.handle_view_input(event)


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and tank != null and not waiting:
		paused = true
		if banner:
			banner.text = "일시정지 · Esc/P 로 계속"


func _process(delta: float) -> void:
	if tank == null or not is_instance_valid(tank):
		return
	camera.pointer_active = not paused
	camera.update_view(tank, delta)
	if not waiting:
		camera.update_pointer(tank)
	reticle.queue_redraw()
	_update_effects(delta)
	var lines := []
	for e in _shot_log:
		lines.append(e[0])
	log_label.text = "\n".join(lines)
	if not _shot_log.is_empty():
		log_label.add_theme_color_override("font_color", _shot_log[-1][1])
	var d := tank.damage
	var seen := 0
	for n in agent.perception.contacts:
		var c: Dictionary = agent.perception.contacts[n]
		if c.get("enemy", false) and c.get("visible_now", false):
			seen += 1
	var left := maxf(0.0, float(env.time_limit_ticks - env.tick) / Engine.physics_ticks_per_second)
	hud.text = "\n".join([
		"실제 전투 시범 · %s · %s · 남은 시간 %d:%02d · 기록 %d" % [tank.spec.display_name if tank.spec.display_name != "" else tank.spec.id,
			str(env.config.get("stage", "")), int(left) / 60, int(left) % 60, decisions],
		"%s · 속도 %.0f km/h · 기어 %d · 상태 %s · 탄 %d · %s" % [TankView.MODE_LABELS[agent.view.mode],
			absf(tank.forward_speed()) * 3.6, tank.gear, d.status_label(), d.ammo_remaining,
			"장전 완료" if tank.reload_timer <= 0.0 and d.can_fire() else "재장전 %.1fs" % tank.reload_timer],
		"보이는 적 %d" % seen,
		"W/S 전후진 · A/D 방향 · Space 제동 · 마우스 조준 · 좌클릭/F 발사 · Shift 포수↔3인칭 · B 전차장 · 우클릭/C 둘러보기 · 휠 배율 · 1/2/3 탄종 · Esc 일시정지"])
	if waiting and banner.text == "":
		_show_banner()
