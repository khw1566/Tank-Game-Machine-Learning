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
## 조작: W/S 전후진 · Q/A 왼쪽 궤도 · E/D 오른쪽 궤도 · Space 제동 · 마우스 조준 · 좌클릭/F 발사
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
	camera.set_process_unhandled_input(false)
	add_child(camera)
	camera.current = true
	var layer := CanvasLayer.new()
	add_child(layer)
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
	_show_banner()


func blocks_time() -> bool:
	return paused or waiting


## 결정 시점마다 1회: 사람 입력 → 정책 공간 행동 11개(-1~1, 양자화 전)
func sample() -> Array:
	var keys := _autopilot_keys() if autopilot else KeyboardController.read()
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


func _autopilot_keys() -> TankControlInput:
	var k := decisions
	var shot_dir := OS.get_environment("TANKGAME_DEMO_SHOTS")
	if shot_dir != "" and k in [60, 90, 180]:
		get_viewport().get_texture().get_image().save_png(shot_dir.path_join("demo_%03d_%s.png" % [k, TankView.MODE_LABELS[agent.view.mode]]))
	if k == 100:
		camera.set_mode(TankView.THIRD)
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
		"W/S 전후진 · Q/A·E/D 궤도 · Space 제동 · 마우스 조준 · 좌클릭/F 발사 · Shift 포수↔3인칭 · B 전차장 · 우클릭/C 둘러보기 · 휠 배율 · 1/2/3 탄종 · Esc 일시정지"])
	if waiting and banner.text == "":
		_show_banner()
