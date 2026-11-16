extends Node3D
## 임시 메인 씬: 구릉지 + 티거 1대 vs 셔먼·T-34 여러 대.
## 사람은 키보드로 한 대를 조종(Tab 으로 전환). 나머지는 아직 AI 가 없어 정지.
## 모든 사격 결과는 user://logs/combat_<시각>.jsonl 에 한 줄씩 기록된다.
##
## 헤드리스: godot --headless --path .  (카메라/HUD 생략)

@export var map_seed := 1
@export var allied_lineup: Array[String] = ["sherman75", "sherman75", "sherman75", "t34_76", "t34_76"]

var map: HillMap
var tanks: Array = []
var player_index := 0
var camera: Camera3D
var hud: Label
var last_event := ""
var _log: FileAccess
var _headless := DisplayServer.get_name() == "headless"


func _ready() -> void:
	map = HillMap.new()
	map.map_seed = map_seed
	add_child(map)
	_open_log()
	_spawn("tiger1", 0, map.spawn_points[0], 0)
	var n := allied_lineup.size()
	for i in n:
		var offset := Vector3((i - (n - 1) * 0.5) * 25.0, 0, 0)
		_spawn(allied_lineup[i], 1, map.spawn_points[1] + offset, i + 1)
	if not _headless:
		_setup_view()


## yaw = 0 이면 -Z 방향을 바라본다. 티거는 +Z 끝에서 -Z(연합군 쪽)를 보므로 0,
## 연합군은 -Z 끝에서 +Z 를 봐야 하므로 PI.
func _spawn(id: String, team: int, at: Vector3, seed_v: int) -> void:
	var t := Tank.new()
	t.name = "%s_%d" % [id, tanks.size()]
	t.setup(id, team, 1000 + seed_v)
	t.position = Vector3(at.x, map.height_at(at.x, at.z) + 0.5, at.z)
	t.rotation.y = 0.0 if team == 0 else PI
	add_child(t)
	t.shot_fired.connect(_on_shot)
	t.knocked_out.connect(_on_knocked_out)
	tanks.append(t)


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
	camera = Camera3D.new()
	camera.far = 3000.0
	add_child(camera)
	camera.current = true
	var layer := CanvasLayer.new()
	add_child(layer)
	hud = Label.new()
	hud.position = Vector2(10, 10)
	hud.add_theme_color_override("font_outline_color", Color.BLACK)
	hud.add_theme_constant_override("outline_size", 4)
	layer.add_child(hud)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	match event.physical_keycode:
		KEY_TAB:
			tanks[player_index].control = TankControlInput.new()
			player_index = (player_index + 1) % tanks.size()
		KEY_1, KEY_2, KEY_3:
			tanks[player_index].select_ammo(event.physical_keycode - KEY_1)
		KEY_F1:
			get_tree().change_scene_to_file("res://tanks/lab/armor_lab.tscn")


func _physics_process(_delta: float) -> void:
	if _headless or tanks.is_empty():
		return
	var p: Tank = tanks[player_index]
	p.control = KeyboardController.read()


func _process(_delta: float) -> void:
	if camera == null or tanks.is_empty():
		return
	var p: Tank = tanks[player_index]
	var yaw := p.global_rotation.y + p.turret_yaw
	var back := Vector3(sin(yaw), 0, cos(yaw))
	var target := p.global_position + Vector3.UP * 3.0
	camera.global_position = target + back * 14.0 + Vector3.UP * 4.0
	camera.look_at(target - back * 30.0, Vector3.UP)
	var d := p.damage
	hud.text = "[%s] %s  팀 %d   (Tab: 전차 전환)\n상태: %s  재장전 %.1fs  탄 %d  [%s] (1/2/3 탄종)\n궤도 L %.1f / R %.1f m/s   포탑 %.0f°  포 %.1f°\n승무원: %s\n모듈: %s\n최근: %s\n조작: Q/A 좌궤도, E/D 우궤도, W/S 양쪽, Space 브레이크, ←→ 포탑, ↑↓ 포, F 발사, F1 장갑 시험장" % [
		p.name, p.spec.display_name, p.team, d.status_label(), p.reload_timer, d.ammo_remaining, p.current_shell().shell_name,
		p.track_speed_left, p.track_speed_right, rad_to_deg(p.turret_yaw), rad_to_deg(p.gun_pitch),
		", ".join(d.crew.map(func(c): return "%s:%s" % [c.id, c.status])),
		_damaged_modules(d), last_event]


func _damaged_modules(d: TankDamageState) -> String:
	var out := []
	for k in d.modules:
		if d.modules[k] != TankDamageState.MOD_OK:
			out.append("%s:%s" % [k, d.modules[k]])
	return "정상" if out.is_empty() else ", ".join(out)


func _on_shot(shooter: Tank, result: Dictionary) -> void:
	result["t_ms"] = Time.get_ticks_msec()
	if _log:
		_log.store_line(JSON.stringify({"type": "shot", "data": result}))
		_log.flush()
	if result.get("hit", false):
		last_event = "%s → %s: %s %s (유효 %smm / 관통 %smm) %s" % [shooter.name, result.target_name,
			result.zone, "관통" if result.penetrated else ("도탄" if result.ricochet else "불관통"),
			result.effective_mm, result.pen_roll_mm, ",".join(result.events)]
	else:
		last_event = "%s: 빗나감/차단 (%s)" % [shooter.name, result.get("blocked_by", "")]
	print(last_event)


func _on_knocked_out(tank: Tank, cause: String) -> void:
	if _log:
		_log.store_line(JSON.stringify({"type": "knocked_out", "tank": tank.name, "cause": cause,
			"t_ms": Time.get_ticks_msec(), "state": tank.state_dict()}))
	print("%s 전투불능: %s" % [tank.name, cause])


func _open_log() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://logs"))
	var stamp := Time.get_datetime_string_from_system().replace(":", "-")
	_log = FileAccess.open("user://logs/combat_%s.jsonl" % stamp, FileAccess.WRITE)
