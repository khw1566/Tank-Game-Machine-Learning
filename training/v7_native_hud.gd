extends CanvasLayer
## Native controls and score display for recording a human demonstration.

signal play_requested
signal pause_requested
signal retry_save
signal folder_requested
signal manual_requested

const TANK_IDS := ["sherman75", "t34_76"]
const STAGE_IDS := ["v7_1v2", "v7_1v3", "v7_1v6"]

var tank_select := OptionButton.new()
var stage_select := OptionButton.new()
var map_select := OptionButton.new()
var round_seed := LineEdit.new()
var layout_detail := Label.new()
var play := Button.new()
var pause_button := Button.new()
var retry := Button.new()
var message := Label.new()
var scores := Label.new()
var direction := Label.new()
var view_text := Label.new()
var sight := Label.new()
var _lobby := true


func _ready() -> void:
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var panel := PanelContainer.new()
	root.add_child(panel)
	panel.position = Vector2(16, 14)
	var box := StyleBoxFlat.new()
	box.bg_color = Color(0.052, 0.082, 0.103, 0.93)
	box.set_corner_radius_all(6)
	box.content_margin_left = 14.0
	box.content_margin_right = 14.0
	box.content_margin_top = 10.0
	box.content_margin_bottom = 10.0
	panel.add_theme_stylebox_override("panel", box)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 6)
	panel.add_child(layout)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	layout.add_child(row)
	var title := Label.new()
	title.text = "V7 시범 수집"
	title.add_theme_font_size_override("font_size", 19)
	row.add_child(title)
	for label in ["셔먼 75", "T-34 76"]:
		tank_select.add_item(label)
	for label in ["1대2", "1대3", "1대6"]:
		stage_select.add_item(label)
	tank_select.tooltip_text = "직접 조종할 연합 전차"
	stage_select.tooltip_text = "상대 1대와 연합팀 인원"
	row.add_child(tank_select)
	row.add_child(stage_select)
	play.text = "경기 시작"
	play.pressed.connect(func(): play_requested.emit())
	row.add_child(play)
	pause_button.text = "일시정지"
	pause_button.disabled = true
	pause_button.pressed.connect(func(): pause_requested.emit())
	row.add_child(pause_button)
	var folder := Button.new()
	folder.text = "시범 폴더"
	folder.pressed.connect(func(): folder_requested.emit())
	row.add_child(folder)
	var manual := Button.new()
	manual.text = "일반 전투"
	manual.tooltip_text = "기본 게임을 엽니다. 좌클릭 또는 F로 포탄을 발사합니다."
	manual.pressed.connect(func(): manual_requested.emit())
	row.add_child(manual)
	retry.text = "저장 재시도"
	retry.visible = false
	retry.pressed.connect(func(): retry_save.emit())
	row.add_child(retry)
	for control in [play, pause_button, folder, manual, retry, tank_select, stage_select]:
		control.focus_mode = Control.FOCUS_NONE
	var settings := HBoxContainer.new()
	settings.add_theme_constant_override("separation", 8)
	layout.add_child(settings)
	var map_label := Label.new()
	map_label.text = "맵"
	settings.add_child(map_label)
	for label in ["학습 맵 무작위", "구릉과 숲", "중앙 능선", "마을", "계곡", "바위 지대"]:
		map_select.add_item(label)
	map_select.focus_mode = Control.FOCUS_NONE
	settings.add_child(map_select)
	round_seed.placeholder_text = "재현 시드 (선택)"
	round_seed.tooltip_text = "같은 전차와 인원에서 경기 시드를 입력하면 맵과 배치가 재현됩니다."
	round_seed.max_length = 10
	round_seed.custom_minimum_size.x = 148
	settings.add_child(round_seed)
	layout.add_child(layout_detail)
	scores.visible = false
	direction.visible = false
	layout.add_child(scores)
	layout.add_child(direction)
	layout.add_child(view_text)
	message.add_theme_color_override("font_color", Color("#a6e6c5"))
	message.add_theme_font_size_override("font_size", 15)
	message.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	layout.add_child(message)
	var driving := Label.new()
	driving.mouse_filter = Control.MOUSE_FILTER_IGNORE
	driving.text = "W/S 전후진 · Q/A/E/D 궤도 · Space 제동 · 마우스 카메라 조준 · 클릭/F 태그\nShift 포수 · B 전차장 · 우클릭/C 자유 시점 · 휠 배율 · P/Esc 마우스 해제"
	driving.add_theme_font_size_override("font_size", 16)
	driving.add_theme_color_override("font_outline_color", Color("#142127"))
	driving.add_theme_constant_override("outline_size", 6)
	driving.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(driving)
	driving.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	driving.offset_left = 18
	driving.offset_right = -18
	driving.offset_top = -79
	driving.offset_bottom = -10
	driving.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	sight.text = "⊕"
	sight.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sight.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	sight.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sight.add_theme_font_size_override("font_size", 26)
	sight.add_theme_color_override("font_outline_color", Color("#142127"))
	sight.add_theme_constant_override("outline_size", 4)
	root.add_child(sight)
	sight.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	sight.hide()


func update_view(mode: int, free_look: bool, magnification: float, tracking: bool) -> void:
	var current := "3인칭 자유 시점" if free_look else str(TankView.MODE_LABELS[mode])
	view_text.text = "%s  ×%.1f" % [current, magnification]
	sight.visible = tracking


func select_round(tank: String, stage: String) -> void:
	tank_select.select(TANK_IDS.find(tank))
	stage_select.select(STAGE_IDS.find(stage))


func selection() -> Dictionary:
	var value := round_seed.text.strip_edges()
	var seed_value := clampi(int(value), 0, 4294967295) if value.is_valid_int() else -1
	round_seed.release_focus()
	return {"tank": TANK_IDS[tank_select.selected], "stage": STAGE_IDS[stage_select.selected],
		"map_index": map_select.selected - 1, "seed": seed_value}


func enable_retry(on: bool) -> void:
	retry.visible = on


func set_message(value: String) -> void:
	message.text = value


func update_round(state: Dictionary, to_goal: Vector3, forward: Vector3, active: bool, paused: bool, waiting: bool) -> void:
	if active:
		_lobby = false
	scores.visible = not _lobby
	direction.visible = active
	play.text = "새 경기" if not _lobby else "경기 시작"
	pause_button.disabled = not active
	pause_button.text = "계속하기" if paused else "일시정지"
	if _lobby:
		return
	var geometry: Dictionary = state.get("layout", {})
	layout_detail.text = "%s   경기 시드 %s   원본 배치 시드 %s" % [
		geometry.get("map_id", ""), state.get("seed", ""), geometry.get("source_seed", "")]
	scores.text = "내 링 %d / %d     팀 %d / %d     상대 %d     관측 %d     옆면 %d     남은 시간 %d초" % [
		state.get("score", 0), state.get("goal", 0), state.get("team_score", 0), state.get("team_goal", 0),
		state.get("rival_score", 0), state.get("visible_rivals", 0), state.get("side_seen_count", 0),
		ceili(maxi(0, state.get("limit_steps", 0) - state.get("elapsed_steps", 0)) * 0.1)]
	if not active:
		return
	var right := forward.cross(Vector3.UP)
	var flat := Vector3(to_goal.x, 0.0, to_goal.z)
	var degrees := rad_to_deg(atan2(flat.dot(right), flat.dot(forward)))
	var bearing := "앞"
	if absf(degrees) > 145.0:
		bearing = "뒤"
	elif absf(degrees) > 22.5:
		bearing = "오른쪽" if degrees > 0 else "왼쪽"
	var objective := "링 · 커서를 맞추고 클릭 또는 F" if state.get("gate_open", false) else "체크포인트 · 전차를 이동하세요"
	direction.text = "%s     %s %.0f m" % [objective, bearing, flat.length()]
	if paused:
		message.text = "일시정지 · 계속하려면 P 또는 계속하기"
	elif not waiting:
		message.text = "시범 기록 중 · 경기가 끝나면 자동 저장됩니다."
