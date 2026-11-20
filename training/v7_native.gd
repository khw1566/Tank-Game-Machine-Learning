extends Node3D
## Human and headless controllers submit one action before the same three Tank physics frames.

const NativeWorld = preload("res://training/v7_native_world.gd")
const Interface = preload("res://training/v7_native_hud.gd")
const PROTOCOL := "tankgame-v7-godot-v3"
const DEMO_FORMAT := "tankgame-v7-godot-demo-v3"
const REPEAT := 3
const TANKS := ["tiger1", "sherman75", "t34_76"]
const STAGES := ["v7_target", "v7_side", "v7_1v1", "v7_1v2", "v7_1v3", "v7_1v6"]
const TEAM_STAGES := ["v7_1v2", "v7_1v3", "v7_1v6"]

var world: NativeWorld
var hud: Interface
var camera: TankViewCamera
var peer: StreamPeerTCP
var pending := PackedByteArray()
var tank := "sherman75"
var stage := "v7_1v2"
var round_seed := 0
var demos_dir := ""
var active := false
var waiting_for_input := true
var paused := false
var ticks_left := 0
var observations: Array = []
var actions: Array = []
var result := {}
var saved_path := ""
var save_error := ""
var discard_request: ConfirmationDialog
var close_request := false
var manual_request := false


func _ready() -> void:
	process_physics_priority = -100
	var opts := {}
	for arg in OS.get_cmdline_user_args():
		var split := arg.find("=")
		if split > 0:
			opts[arg.left(split)] = arg.substr(split + 1)
	var training_root := OS.get_environment("TANKGAME_DATA_DIR")
	if training_root.is_empty():
		var local := OS.get_environment("LOCALAPPDATA")
		training_root = local.path_join("TankGameML/training") if not local.is_empty() else OS.get_data_dir().path_join("TankGameML/training")
	demos_dir = str(opts.get("--demos-dir", training_root.path_join("v7_godot_control_demos")))
	world = NativeWorld.new()
	add_child(world)
	if opts.has("--port") or opts.has("--v7-port"):
		var port := int(opts.get("--port", opts.get("--v7-port", 0)))
		_connect_trainer(port)
		return
	if DisplayServer.get_name() == "headless":
		push_error("V7 사람 플레이에는 게임 창이 필요합니다")
		get_tree().quit(2)
		return
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	DisplayServer.window_set_title("Tank Game · V7 카메라 조준 시범 수집")
	get_tree().auto_accept_quit = false
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
	camera.set_process_unhandled_input(false)
	camera.current = true
	hud = Interface.new()
	add_child(hud)
	hud.play_requested.connect(_request_play)
	hud.pause_requested.connect(_toggle_pause)
	hud.retry_save.connect(_save_and_display)
	hud.folder_requested.connect(_open_folder)
	hud.manual_requested.connect(_request_manual)
	discard_request = ConfirmationDialog.new()
	discard_request.title = "진행 중인 시범"
	discard_request.dialog_text = "이 경기의 미저장 조작 기록을 버릴까요?"
	discard_request.ok_button_text = "기록 버리기"
	discard_request.cancel_button_text = "계속하기"
	add_child(discard_request)
	discard_request.confirmed.connect(_confirm_discard)
	discard_request.canceled.connect(func(): close_request = false)
	if opts.has("--tank") or opts.has("--stage"):
		tank = str(opts.get("--tank", tank))
		stage = str(opts.get("--stage", stage))
		if not _valid_human(tank, stage):
			hud.set_message("연합 차종과 경기 인원을 선택하세요.")
			return
		hud.select_round(tank, stage)
		_start_human(int(opts.get("--seed", _new_seed())))
	else:
		world.reset_round(tank, stage, _new_seed())
		hud.set_message("차종과 인원을 선택한 뒤 경기 시작을 누르세요.")


func _valid_human(vehicle: String, lesson: String) -> bool:
	return vehicle in ["sherman75", "t34_76"] and lesson in TEAM_STAGES


func _new_seed() -> int:
	return Crypto.new().generate_random_bytes(4).decode_u32(0) & 0x7fffffff


func _connect_trainer(port: int) -> void:
	peer = StreamPeerTCP.new()
	if port < 1 or port > 65535 or peer.connect_to_host("127.0.0.1", port) != OK:
		push_error("V7 native trainer port unavailable")
		get_tree().quit(2)
		return
	var deadline := Time.get_ticks_msec() + 10000
	while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and Time.get_ticks_msec() < deadline:
		peer.poll()
		OS.delay_msec(1)
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		push_error("V7 native trainer connection failed")
		get_tree().quit(2)
		return
	peer.set_no_delay(true)
	_send({"type": "hello", "protocol": PROTOCOL, "version": 3, "engine": Engine.get_version_info().string,
		"obs_labels": world.schema.obs_labels, "action_labels": world.schema.action_labels,
		"repeat": REPEAT, "physics_hz": Engine.physics_ticks_per_second,
		"layout_catalog_sha256": FileAccess.get_sha256(NativeWorld.LAYOUT_FILE)})


func _send(message: Dictionary) -> void:
	if peer.put_data((JSON.stringify(message, "", false, true) + "\n").to_utf8_buffer()) != OK:
		get_tree().quit()


func _receive() -> Dictionary:
	while true:
		var next := pending.find(10)
		if next >= 0:
			var line := pending.slice(0, next).get_string_from_utf8()
			pending = pending.slice(next + 1)
			var parsed: Variant = JSON.parse_string(line)
			return parsed if parsed is Dictionary else {"type": "invalid"}
		var bytes := peer.get_data(clampi(peer.get_available_bytes(), 1, 4096))
		if bytes[0] != OK or bytes[1].size() == 0:
			return {"type": "close"}
		pending.append_array(bytes[1])
		if pending.size() > 65536:
			return {"type": "close"}
	return {}


func _reset_round(vehicle: String, lesson: String, value: int) -> void:
	tank = vehicle
	stage = lesson
	round_seed = value
	world.reset_round(tank, stage, round_seed)
	ticks_left = 0
	active = true
	paused = false
	if camera:
		camera.reset_pointer()
	waiting_for_input = true
	observations.clear()
	actions.clear()
	result.clear()
	saved_path = ""
	save_error = ""


func _serve() -> void:
	# Do not advance the native physics clock while the trainer is choosing an action.
	while true:
		var command := _receive()
		match command.get("type", ""):
			"close":
				set_physics_process(false)
				get_tree().quit()
				return
			"reset":
				var vehicle := str(command.get("tank", ""))
				var lesson := str(command.get("stage", ""))
				if not vehicle in TANKS or not lesson in STAGES:
					_send({"type": "error", "error": "invalid tank or stage"})
					continue
				_reset_round(vehicle, lesson, int(command.get("seed", 0)))
				_send({"type": "observation", "obs": Array(world.observation()), "info": world.round_status()})
			"step":
				var values: Variant = command.get("action")
				if not active or not values is Array or values.size() != world.schema.action_labels.size():
					_send({"type": "error", "error": "invalid action or inactive round"})
					continue
				var valid := true
				for x: Variant in values:
					if typeof(x) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(x)):
						valid = false
						break
				if not valid:
					_send({"type": "error", "error": "invalid action value"})
					continue
				_begin_action(PackedFloat32Array(values))
				return
			_:
				_send({"type": "error", "error": "unrecognized command"})


func _begin_action(action: PackedFloat32Array) -> void:
	var before := PackedFloat32Array()
	if peer == null:
		before = world.observation().duplicate()
	var applied := world.apply_action(action)
	if peer == null:
		observations.append(Array(before))
		actions.append(Array(applied))
	waiting_for_input = false
	ticks_left = REPEAT


func _physics_process(delta: float) -> void:
	if not world:
		return
	if ticks_left == 0 and peer != null:
		_serve()
	elif ticks_left == 0 and active:
		if paused:
			return
		var a := _human_action()
		if waiting_for_input and a.count(0.0) == a.size():
			return
		_begin_action(a)
	if ticks_left == 0:
		return
	world.physics_tick(delta)
	ticks_left -= 1
	if ticks_left > 0:
		return
	var transition: Dictionary = world.advance_decision()
	var done := bool(transition.terminated) or bool(transition.truncated)
	if done:
		active = false
		result = transition.info
	if peer != null:
		_send({"type": "transition", "obs": Array(world.observation()), "reward": transition.reward,
			"terminated": transition.terminated, "truncated": transition.truncated, "info": transition.info})
	elif done:
		_save_and_display()


func _human_action() -> PackedFloat32Array:
	var keys := KeyboardController.read()
	camera.pointer_active = true
	var looking := camera.is_free_look_pressed() or camera.mode == TankView.COMMANDER
	var tag := (keys.fire or Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)) and not looking
	var shield := Input.is_physical_key_pressed(KEY_X)
	var corrected := camera.take_pointer_input() and not looking
	var marker := world.ring_position + Vector3.UP * 0.72 if world.gate_open else Vector3.INF
	camera.update_pointer(world.player, marker)
	if waiting_for_input and not corrected and not tag and not shield and keys.to_array().count(0.0) == 6:
		return PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0, 0])
	var aim := camera.pointer_commands(world.player, float(REPEAT) / Engine.physics_ticks_per_second)
	var cursor := Vector2(keys.turret_traverse, keys.gun_elevation)
	if looking:
		cursor = Vector2.ZERO
	elif cursor == Vector2.ZERO and camera.aim_point != Vector3.INF:
		var offset: Vector2 = world._local(camera.aim_point).clamp(Vector2(-10, -4), Vector2(10, 16))
		cursor = (offset - world._cursor) / world.CURSOR_RATE
	return PackedFloat32Array([keys.left_track, keys.right_track, keys.brake,
		cursor.x, cursor.y, float(tag), float(shield), aim.x, aim.y])


func _process(delta: float) -> void:
	if not hud or not is_instance_valid(world.player):
		return
	var p: Vector3 = world.player.global_position
	var forward := Vector3.FORWARD.rotated(Vector3.UP, world.player.heading)
	camera.map = world.map
	camera.pointer_active = active and not paused
	camera.update_view(world.player, delta)
	hud.update_view(camera.mode, camera.free_look, camera.magnification(),
		camera.pointer_active and not camera.free_look and camera.mode != TankView.COMMANDER)
	hud.update_round(world.round_status(), world.focus_target - p, forward, active, paused, waiting_for_input)


func _request_play() -> void:
	manual_request = false
	if (active and not actions.is_empty()) or not save_error.is_empty():
		paused = true
		close_request = false
		discard_request.popup_centered()
	else:
		_start_human(_new_seed())


func _confirm_discard() -> void:
	if close_request:
		get_tree().quit()
	elif manual_request:
		_open_manual()
	else:
		_start_human(_new_seed())


func _request_manual() -> void:
	if (active and not actions.is_empty()) or not save_error.is_empty():
		paused = true
		close_request = false
		manual_request = true
		discard_request.popup_centered()
	else:
		_open_manual()


func _open_manual() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	get_tree().set_meta("v7_manual_game", true)
	get_tree().set_meta("v7_manual_tank", hud.selection().tank)
	get_tree().auto_accept_quit = true
	get_tree().change_scene_to_file("res://main.tscn")


func _start_human(value: int) -> void:
	var choice := hud.selection()
	_reset_round(choice.tank, choice.stage, NativeWorld.seed_for_map(value if choice.seed < 0 else choice.seed, choice.map_index))
	hud.set_message("조작을 시작하면 시범이 기록됩니다.")
	hud.enable_retry(false)


func _toggle_pause() -> void:
	if active:
		paused = not paused
		hud.set_message("일시정지" if paused else "시범 기록 중")


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and active and peer == null and not waiting_for_input:
		paused = true
	if what == NOTIFICATION_WM_CLOSE_REQUEST and hud:
		if (active and not actions.is_empty()) or not save_error.is_empty():
			paused = true
			close_request = true
			discard_request.popup_centered()
		else:
			get_tree().quit()


func _input(event: InputEvent) -> void:
	if not hud or not active:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode in [KEY_P, KEY_ESCAPE]:
			_toggle_pause()
			get_viewport().set_input_as_handled()
			return
	if paused:
		return
	camera.handle_view_input(event)


func _open_folder() -> void:
	var dir := demos_dir.path_join(str(hud.selection().tank))
	if DirAccess.make_dir_recursive_absolute(dir) == OK:
		OS.shell_open(ProjectSettings.globalize_path(dir))


func _save_and_display() -> void:
	if active or result.is_empty() or actions.is_empty() or not saved_path.is_empty():
		return
	var directory := demos_dir.path_join(tank)
	var data := {"format": DEMO_FORMAT, "source": "godot-human", "engine": Engine.get_version_info().string,
		"protocol": PROTOCOL, "repeat": REPEAT, "physics_hz": Engine.physics_ticks_per_second,
		"tank": tank, "stage": stage, "seed": round_seed, "allied_team": true, "completed": true,
		"layout": world.layout_info,
		"success": bool(result.get("is_success", false)), "reason": str(result.get("reason", "")),
		"obs_labels": world.schema.obs_labels, "action_labels": world.schema.action_labels,
		"obs": observations, "actions": actions}
	if DirAccess.make_dir_recursive_absolute(directory) != OK:
		_save_failed(directory)
		return
	var base := stage + "_" + Crypto.new().generate_random_bytes(12).hex_encode() + ".json"
	var target := directory.path_join(base)
	var temp := target + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if not file:
		_save_failed(directory)
		return
	file.store_string(JSON.stringify(data, "", false, true))
	file.flush()
	var error := file.get_error()
	file.close()
	if error != OK or DirAccess.rename_absolute(temp, target) != OK:
		DirAccess.remove_absolute(temp)
		_save_failed(directory)
		return
	saved_path = target
	save_error = ""
	hud.enable_retry(false)
	hud.set_message("%s · %d개 조작 저장 완료\n%s" % ["승리" if data.success else "경기 종료", actions.size(), target])
	print("[V7 Godot] saved ", target)


func _save_failed(directory: String) -> void:
	save_error = "시범 저장 실패 · 저장 폴더와 여유 공간을 확인하세요.\n" + directory
	hud.set_message(save_error)
	hud.enable_retry(true)
