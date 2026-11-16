extends Node3D
## 장갑 시험장: 장갑 구역을 색으로 보고, 탄종·거리를 골라 원하는 지점에 쏴 보는 씬.
##
## 조작: 좌클릭 = 마우스 지점에 사격(카메라 방향이 곧 사격 방향)
##       우클릭 드래그 = 시점 회전, 휠 = 확대/축소, Esc = 게임으로 돌아가기
## 표시 모드: 두께 / 유효장갑(현재 시점 기준) / 관통확률(선택 탄종·거리, 현재 시점 기준)
## 판정은 게임과 같은 DamageModel.resolve_shot() 을 그대로 쓴다.

const MODES := ["장갑 두께", "유효장갑 (현재 시점)", "관통확률 (현재 시점)"]
const PRESETS := [["정면", 0.0], ["티타임 35°", 35.0], ["측면 60°", 60.0], ["측면 90°", 90.0], ["후면", 180.0]]

var target_id := "tiger1"
var spec: TankSpec
var state: TankDamageState
var shells: Array = []
var shell: GunSpec
var distance_m := 500.0
var mode := 0
var show_internals := false
var rng := RandomNumberGenerator.new()

var target_root: Node3D
var turret_node: Node3D
var gun_node: Node3D
var internals_root: Node3D
var markers_root: Node3D
var faces: Array = [] # [{"zone", "mesh", "mat", "label", "parent", "normal"}]
var internal_nodes: Array = [] # [{"kind": "crew"/"module", "index"/"id", "mat"}]

var camera: Camera3D
var cam_yaw := 0.0      # 월드 기준 카메라 방위(°). 표적 정면 기준 방위 = cam_yaw + 차체 회전

var cam_pitch := 8.0
var cam_dist := 11.0
var _dragging := false

# UI
var target_opt: OptionButton
var shell_opt: OptionButton
var dist_slider: HSlider
var dist_label: Label
var hull_slider: HSlider
var turret_slider: HSlider
var mode_opt: OptionButton
var hover_label: Label
var result_text: RichTextLabel
var legend_label: Label
var chart: PenetrationChart
var _hover_eff := 0.0
var _hover_zone := ""

var _marker_mesh := SphereMesh.new()
var _marker_mats := {}


func _ready() -> void:
	rng.randomize()
	_marker_mesh.radius = 0.06
	_marker_mesh.height = 0.12
	for k in ["pen", "nonpen", "ricochet"]:
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = {"pen": Color(0.1, 1, 0.2), "nonpen": Color(1, 0.15, 0.1), "ricochet": Color(1, 0.9, 0.1)}[k]
		m.no_depth_test = true
		_marker_mats[k] = m
	_build_world()
	_build_ui()
	shells = TankDatabase.all_ammo()
	for i in shells.size():
		shell_opt.add_item(_shell_label(shells[i]), i)
	shell = shells[0]
	_load_target("tiger1")


# ---------------------------------------------------------------- 월드
func _build_world() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.16, 0.18, 0.21)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.75, 0.75, 0.75)
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, 35, 0)
	sun.light_energy = 0.8
	add_child(sun)
	var ground := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	ground.mesh = pm
	var gm := StandardMaterial3D.new()
	gm.albedo_color = Color(0.25, 0.28, 0.22)
	ground.material_override = gm
	add_child(ground)
	camera = Camera3D.new()
	camera.fov = 50
	add_child(camera)
	camera.current = true


func _load_target(id: String) -> void:
	target_id = id
	spec = TankDatabase.get_spec(id)
	state = TankDamageState.new(spec)
	if target_root:
		target_root.queue_free()
	faces.clear()
	internal_nodes.clear()
	target_root = Node3D.new()
	target_root.rotation.y = deg_to_rad(hull_slider.value) if hull_slider else 0.0
	add_child(target_root)
	turret_node = Node3D.new()
	turret_node.position = spec.turret_origin()
	target_root.add_child(turret_node)
	internals_root = Node3D.new()
	target_root.add_child(internals_root)
	markers_root = Node3D.new()
	target_root.add_child(markers_root)
	gun_node = Node3D.new()
	gun_node.position = spec.shape().trunnion
	turret_node.add_child(gun_node)
	_build_faces()
	_build_internals()
	turret_node.rotation.y = deg_to_rad(turret_slider.value)
	_update_result("표적: [b]%s[/b]  (전고 %.2fm · 정면 피탄면적 %.1fm² · 포 %+.0f°~%+.0f°)\n%s\n좌클릭으로 사격하세요. 카메라 방향이 사격 방향입니다." % [
		spec.display_name, spec.total_height(), spec.shape().projected_area(Vector3.FORWARD, 0.0, 0.1),
		spec.gun_depression_deg, spec.gun_elevation_max_deg, "\n".join(spec.traits.map(func(x): return "• " + x))])
	_refresh_all()


func _build_faces() -> void:
	# TankShape 의 부품(차체·궤도·포탑·포방패·포신) 면을 그대로 그린다. 경사면은 실제로 기울어져 있다.
	var sh := spec.shape()
	for part in sh.parts:
		var parent: Node3D = target_root
		match part.frame:
			"turret":
				parent = turret_node
			"gun":
				parent = gun_node
		for f in part.faces:
			_face(parent, f.zone, f.points, f.normal)


func _face(parent: Node3D, zone: String, pts: PackedVector3Array, normal: Vector3) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in range(1, pts.size() - 1):
		for p in [pts[0], pts[k], pts[k + 1]]:
			st.set_normal(normal)
			st.add_vertex(p)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	parent.add_child(mi)
	# 테두리
	var edge := MeshInstance3D.new()
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
	for k in pts.size() + 1:
		im.surface_add_vertex(pts[k % pts.size()] + normal * 0.003)
	im.surface_end()
	edge.mesh = im
	var em := StandardMaterial3D.new()
	em.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	em.albedo_color = Color(0, 0, 0, 0.8)
	edge.material_override = em
	parent.add_child(edge)
	var label := Label3D.new()
	var c := Vector3.ZERO
	for p in pts:
		c += p
	label.position = c / pts.size() + normal * 0.02
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.font_size = 40
	label.pixel_size = 0.004
	label.outline_size = 10
	label.no_depth_test = true
	parent.add_child(label)
	if zone == "gun_barrel" or zone == "track":
		label.font_size = 24
	faces.append({"zone": zone, "mesh": mi, "mat": mat, "label": label, "parent": parent, "normal": normal,
		"slope": rad_to_deg(asin(clampf(normal.y, -1.0, 1.0)))})


func _build_internals() -> void:
	var sm := SphereMesh.new()
	sm.radius = 1.0
	sm.height = 2.0
	for i in spec.crew.size():
		var c: Dictionary = spec.crew[i]
		_internal_sphere(sm, c.pos, c.radius, c.in_turret, "crew", i, c.id)
	for m in spec.modules:
		_internal_sphere(sm, m.pos, m.radius, m.in_turret, "module", -1, m.id)
	internals_root.visible = show_internals


func _internal_sphere(sm: SphereMesh, pos: Vector3, r: float, in_turret: bool, kind: String, index: int, id: String) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = sm
	mi.scale = Vector3.ONE * r
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	var lbl := Label3D.new()
	lbl.text = id
	lbl.font_size = 32
	lbl.pixel_size = 0.004
	lbl.no_depth_test = true
	lbl.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	if in_turret:
		# 포탑과 같이 돌도록 포탑 노드 아래 별도 그룹에 둔다
		var holder := Node3D.new()
		holder.position = pos
		holder.visible = show_internals
		turret_node.add_child(holder)
		holder.add_child(mi)
		holder.add_child(lbl)
		internal_nodes.append({"kind": kind, "index": index, "id": id, "mat": mat, "holder": holder})
	else:
		var holder := Node3D.new()
		holder.position = pos
		internals_root.add_child(holder)
		holder.add_child(mi)
		holder.add_child(lbl)
		internal_nodes.append({"kind": kind, "index": index, "id": id, "mat": mat, "holder": holder})


# ---------------------------------------------------------------- UI
func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.position = Vector2(8, 8)
	panel.custom_minimum_size = Vector2(300, 0)
	layer.add_child(panel)
	var v := VBoxContainer.new()
	panel.add_child(v)
	var title := Label.new()
	title.text = "장갑 시험장"
	title.add_theme_font_size_override("font_size", 20)
	v.add_child(title)

	v.add_child(_caption("표적 전차"))
	target_opt = OptionButton.new()
	for i in TankDatabase.IDS.size():
		target_opt.add_item(TankDatabase.get_spec(TankDatabase.IDS[i]).display_name, i)
	target_opt.item_selected.connect(func(i): _load_target(TankDatabase.IDS[i]))
	v.add_child(target_opt)

	v.add_child(_caption("탄종 (사격하는 포)"))
	shell_opt = OptionButton.new()
	shell_opt.item_selected.connect(func(i):
		shell = shells[i]
		_refresh_all())
	v.add_child(shell_opt)

	dist_label = _caption("")
	v.add_child(dist_label)
	dist_slider = _slider(50, 2500, 50, distance_m, func(x):
		distance_m = x
		_refresh_all())
	v.add_child(dist_slider)

	v.add_child(_caption("표적 차체 회전 (°)"))
	hull_slider = _slider(-180, 180, 5, 0, func(x):
		target_root.rotation.y = deg_to_rad(x)
		_refresh_all())
	v.add_child(hull_slider)
	v.add_child(_caption("포탑 회전 (°, + = 좌)"))
	turret_slider = _slider(-180, 180, 5, 0, func(x):
		turret_node.rotation.y = deg_to_rad(x)
		_refresh_all())
	v.add_child(turret_slider)

	v.add_child(_caption("시점 (사수 위치)"))
	var presets := HBoxContainer.new()
	for p in PRESETS:
		var b := Button.new()
		b.text = p[0]
		b.pressed.connect(func():
			cam_yaw = wrapf(p[1] - hull_slider.value, -180.0, 180.0)
			cam_pitch = 5.0)
		presets.add_child(b)
	var flow := HFlowContainer.new()
	for ch in presets.get_children():
		presets.remove_child(ch)
		flow.add_child(ch)
	v.add_child(flow)

	v.add_child(_caption("표시"))
	mode_opt = OptionButton.new()
	for i in MODES.size():
		mode_opt.add_item(MODES[i], i)
	mode_opt.item_selected.connect(func(i):
		mode = i
		_refresh_all())
	v.add_child(mode_opt)
	var cb := CheckBox.new()
	cb.text = "내부(승무원·모듈) 보기"
	cb.toggled.connect(func(on):
		show_internals = on
		internals_root.visible = on
		for n in internal_nodes:
			if (n.holder as Node3D).get_parent() == turret_node:
				(n.holder as Node3D).visible = on
		_refresh_all())
	v.add_child(cb)
	legend_label = Label.new()
	legend_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	legend_label.custom_minimum_size = Vector2(290, 0)
	legend_label.add_theme_font_size_override("font_size", 12)
	v.add_child(legend_label)

	var row := HBoxContainer.new()
	var repair := Button.new()
	repair.text = "수리·탄착 지우기"
	repair.pressed.connect(func():
		state = TankDamageState.new(spec)
		for ch in markers_root.get_children():
			ch.queue_free()
		_update_result("수리 완료.")
		_refresh_all())
	row.add_child(repair)
	var mc := Button.new()
	mc.text = "현재 시점 200발"
	mc.tooltip_text = "현재 카메라 방향에서 실루엣 전체에 무작위로 200발(매 발 새 전차) 쏴서 통계를 냅니다."
	mc.pressed.connect(_monte_carlo)
	row.add_child(mc)
	v.add_child(row)
	var back := Button.new()
	back.text = "게임으로 돌아가기 (Esc)"
	back.pressed.connect(_back_to_game)
	v.add_child(back)
	var help := _caption("좌클릭: 사격 · 우클릭 드래그: 회전 · 휠: 확대")
	v.add_child(help)

	# 오른쪽 결과
	var rp := PanelContainer.new()
	rp.anchor_left = 1.0
	rp.anchor_right = 1.0
	rp.offset_left = -400
	rp.offset_right = -8
	rp.offset_top = 8
	rp.offset_bottom = 470
	layer.add_child(rp)
	result_text = RichTextLabel.new()
	result_text.bbcode_enabled = true
	result_text.scroll_following = false
	result_text.add_theme_font_size_override("normal_font_size", 13)
	result_text.add_theme_font_size_override("bold_font_size", 13)
	rp.add_child(result_text)

	# 아래 그래프
	var cp := PanelContainer.new()
	cp.anchor_left = 1.0
	cp.anchor_right = 1.0
	cp.anchor_top = 1.0
	cp.anchor_bottom = 1.0
	cp.offset_left = -440
	cp.offset_right = -8
	cp.offset_top = -236
	cp.offset_bottom = -8
	layer.add_child(cp)
	chart = PenetrationChart.new()
	cp.add_child(chart)

	hover_label = Label.new()
	hover_label.anchor_left = 0.5
	hover_label.anchor_right = 0.5
	hover_label.offset_left = -300
	hover_label.offset_right = 140
	hover_label.offset_top = 10
	hover_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hover_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hover_label.add_theme_color_override("font_outline_color", Color.BLACK)
	hover_label.add_theme_constant_override("outline_size", 5)
	layer.add_child(hover_label)


func _caption(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	return l


func _slider(lo: float, hi: float, step: float, val: float, cb: Callable) -> HSlider:
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = val
	s.custom_minimum_size = Vector2(280, 18)
	s.value_changed.connect(cb)
	return s


func _shell_label(g: GunSpec) -> String:
	for s in TankDatabase.all_specs():
		for a in s.ammo_types:
			if a.id == g.id:
				return "%s · %s" % [s.display_name, g.shell_name]
	return g.label()


func _shooter_shells() -> Array:
	for s in TankDatabase.all_specs():
		for a in s.ammo_types:
			if a.id == shell.id:
				return s.ammo_types
	return [shell]


# ---------------------------------------------------------------- 갱신
func _refresh_all() -> void:
	if spec == null or dist_label == null:
		return
	dist_label.text = "사격 거리: %d m   (평균 관통력 %.0f mm)" % [distance_m, shell.penetration_mm(distance_m)]
	match mode:
		0:
			legend_label.text = "색: 빨강(얇음 10mm) → 노랑 → 초록 → 파랑(두꺼움 150mm+). 글자: 두께@경사"
		1:
			legend_label.text = "색: 빨강(약함) → 파랑(유효 250mm+). 유효장갑 = 두께 / cos(현재 시점에서의 입사각 − 피모 보정)"
		2:
			legend_label.text = "색: 빨강 = 관통 못함, 노랑 = 반반, 초록 = 확실히 관통. %s, %dm 기준 (도탄 포함)" % [shell.shell_name, distance_m]
	_update_faces()
	_update_internals()
	_update_chart()


func _plate_global_normal(f: Dictionary) -> Vector3:
	return ((f.parent as Node3D).global_transform.basis * (f.normal as Vector3)).normalized()


func _impact_angle_from_camera(f: Dictionary) -> float:
	var center: Vector3 = (f.label as Node3D).global_position
	var d := (center - camera.global_position).normalized()
	var n := _plate_global_normal(f)
	return rad_to_deg(acos(clampf(-d.dot(n), 0.0, 1.0)))


func _update_faces() -> void:
	for f in faces:
		var t: float = spec.plate(f.zone).t
		var col: Color
		var txt := ""
		var angle := _impact_angle_from_camera(f)
		var facing := angle < 89.5
		var special: bool = f.zone == "track" or f.zone == "gun_barrel"
		match mode if not special else 0:
			0:
				col = _scale_color(t, 10.0, 150.0)
				txt = "%dmm\n@%d°" % [t, f.slope]
				if f.zone == "track":
					col = Color(0.3, 0.3, 0.3)
					txt = "궤도\n-%dmm" % spec.track_armor_mm
				elif f.zone == "gun_barrel":
					col = Color(0.5, 0.5, 0.5)
					txt = ""
			1:
				var eff := Ballistics.effective_thickness_mm(shell, t, angle)
				col = _scale_color(eff, 10.0, 250.0)
				txt = "%.0fmm" % eff if facing else ""
			2:
				var p := Ballistics.penetration_probability(shell, distance_m, t, angle)
				col = Color.from_hsv(0.33 * p, 0.85, 0.9)
				txt = "%.0f%%" % (p * 100.0) if facing else ""
		var mat: StandardMaterial3D = f.mat
		if show_internals:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			col.a = 0.18
		else:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
		mat.albedo_color = col
		(f.label as Label3D).text = txt
		(f.label as Label3D).visible = facing and not show_internals


static func _scale_color(v: float, lo: float, hi: float) -> Color:
	var k := clampf((v - lo) / (hi - lo), 0.0, 1.0)
	return Color.from_hsv(0.66 * k, 0.8, 0.9)


func _update_internals() -> void:
	for n in internal_nodes:
		var mat: StandardMaterial3D = n.mat
		var c := Color(0.3, 0.6, 1.0, 0.75)
		if n.kind == "crew":
			match state.crew[n.index].status:
				TankDamageState.CREW_WOUNDED:
					c = Color(1.0, 0.85, 0.1, 0.85)
				TankDamageState.CREW_KIA:
					c = Color(0.1, 0.1, 0.1, 0.9)
		else:
			c = Color(1.0, 0.55, 0.15, 0.6)
			match state.modules.get(n.id, "ok"):
				TankDamageState.MOD_DAMAGED:
					c = Color(1.0, 0.2, 0.1, 0.8)
				TankDamageState.MOD_DESTROYED:
					c = Color(0.25, 0.25, 0.25, 0.9)
		mat.albedo_color = c


func _update_chart() -> void:
	chart.refresh(_shooter_shells(), shell, distance_m, _hover_eff, _hover_zone)


func _update_result(bb: String) -> void:
	result_text.text = bb + "\n\n" + _state_text()


func _state_text() -> String:
	var lines := ["[b]표적 상태[/b]: %s %s" % [state.status_label(),
		("(%s)" % state.knockout_cause) if state.knockout_cause != "" else ""]]
	lines.append("명중 %d · 관통 %d" % [state.hits_taken, state.penetrations_taken])
	var crew := []
	for c in state.crew:
		var col: String = {"ok": "#9fd3ff", "wounded": "#ffd84a", "kia": "#ff5a5a"}[c.status]
		crew.append("[color=%s]%s:%s[/color]" % [col, c.id, c.status])
	lines.append("승무원: " + ", ".join(crew))
	var roles := []
	for r in state.roles:
		roles.append("%s←%s" % [r, state.roles[r] if state.roles[r] != "" else "공석"])
	lines.append("역할: " + ", ".join(roles))
	var mods := []
	for k in state.modules:
		if state.modules[k] != "ok":
			mods.append("%s:%s" % [k, state.modules[k]])
	lines.append("손상 모듈: " + (", ".join(mods) if not mods.is_empty() else "없음"))
	lines.append("기동 %s · 사격 %s · 재장전 %s" % ["가능" if state.can_move() else "불가",
		"가능" if state.can_fire() else "불가",
		("%.1fs" % state.reload_time_s()) if state.can_fire() else "-"])
	return "\n".join(lines)


# ---------------------------------------------------------------- 입력·카메라
func _process(_delta: float) -> void:
	var center := Vector3(0, spec.total_height() * 0.5, 0) if spec else Vector3.ZERO
	var yaw := deg_to_rad(cam_yaw)
	var pitch := deg_to_rad(cam_pitch)
	var off := Vector3(sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch)) * cam_dist
	camera.global_position = center + off
	camera.look_at(center, Vector3.UP)
	if mode != 0:
		_update_faces()
	_hover()


func _hover() -> void:
	var mp := get_viewport().get_mouse_position()
	var r := _local_ray(mp)
	var tr := HitGeometry.trace(spec, turret_node.rotation.y, r[0], r[1])
	var via_track := ""
	if tr.hit and tr.zone == "track":
		via_track = " (궤도 통과 −%dmm)" % spec.track_armor_mm
		tr = HitGeometry.trace(spec, turret_node.rotation.y, r[0], r[1], 0.0, ["track_left", "track_right"])
	if tr.hit and tr.zone == "gun_barrel":
		hover_label.text = "포신 — 맞으면 포신 손상(분산 2배) 또는 파괴(사격 불가)"
		return
	if not tr.hit:
		hover_label.text = "사수 방위 %.0f° · 고각 %.0f° (표적 정면 기준, + = 표적 우측)" % [_rel_bearing(), cam_pitch]
		if _hover_eff != 0.0:
			_hover_eff = 0.0
			_update_chart()
		return
	var pl := spec.plate(tr.zone)
	var eff := Ballistics.effective_thickness_mm(shell, pl.t, tr.impact_angle_deg)
	var pen := shell.penetration_mm(distance_m) - (spec.track_armor_mm if via_track != "" else 0.0)
	var sigma := maxf(pen * shell.penetration_sigma, 0.001)
	var ric := Ballistics.ricochet_chance(shell, pl.t, tr.impact_angle_deg)
	var p := Ballistics.normal_cdf((pen - eff) / sigma) * (1.0 - ric)
	hover_label.text = "%s%s · %dmm @%d° · 입사각 %.0f° · 유효 %.0fmm · 관통력 %.0fmm → 관통확률 %.0f%%%s" % [
		tr.zone, via_track, pl.t, tr.slope_deg, tr.impact_angle_deg, eff, pen, p * 100.0,
		"  (도탄 %.0f%%)" % (ric * 100.0) if ric > 0 else ""]
	if absf(eff - _hover_eff) > 0.5 or _hover_zone != tr.zone:
		_hover_eff = eff
		_hover_zone = tr.zone
		_update_chart()


## 표적 정면 기준 사수 방위(°, + = 표적의 우측)
func _rel_bearing() -> float:
	return wrapf(cam_yaw + hull_slider.value, -180.0, 180.0)


func _local_ray(screen_pos: Vector2) -> Array:
	var o := camera.project_ray_origin(screen_pos)
	var d := camera.project_ray_normal(screen_pos)
	var inv := target_root.global_transform.affine_inverse()
	return [inv * o, (inv.basis * d).normalized()]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_RIGHT:
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			cam_dist = maxf(cam_dist * 0.9, 5.0)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			cam_dist = minf(cam_dist * 1.1, 40.0)
		elif mb.button_index == MOUSE_BUTTON_LEFT and mb.pressed:
			_shoot_at(mb.position)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		cam_yaw = wrapf(cam_yaw - mm.relative.x * 0.4, -180.0, 180.0)
		cam_pitch = clampf(cam_pitch + mm.relative.y * 0.3, -5.0, 80.0)
	elif event is InputEventKey and event.pressed and (event as InputEventKey).physical_keycode == KEY_ESCAPE:
		_back_to_game()


func _back_to_game() -> void:
	get_tree().change_scene_to_file("res://main.tscn")


# ---------------------------------------------------------------- 사격
func _shoot_at(screen_pos: Vector2) -> void:
	var r := _local_ray(screen_pos)
	var res := DamageModel.resolve_shot(state, turret_node.rotation.y, r[0], r[1], distance_m, shell, rng)
	if not res.hit:
		return
	_add_marker(res)
	var verdict := "[color=#5f5]관통[/color]" if res.penetrated else ("[color=#ff5]도탄[/color]" if res.ricochet else "[color=#f55]불관통[/color]")
	var dmg := []
	for d in res.damage:
		dmg.append("%s %s: %s→%s" % ["승무원" if d.kind == "crew" else "모듈", d.id, d.before, d.after])
	if "hit_wreck" in res.events:
		verdict = "[color=#aaa]잔해 명중(이미 파괴됨, 수리 버튼으로 초기화)[/color]"
	var bb := "[b]%s[/b]  %s, %dm\n" % [verdict, shell.shell_name, distance_m]
	if res.has("track_hit"):
		bb += "궤도 명중(%s) → 관통력 −%dmm 후 차체로 진행\n" % [res.track_hit, spec.track_armor_mm]
	bb += "구역 %s (%dmm @%d°)\n입사각 %.1f° → 유효장갑 %.1fmm\n" % [res.zone, res.plate_mm, res.slope_deg, res.impact_angle_deg, res.effective_mm]
	bb += "평균 관통력 %.1fmm, 이번 탄 %.1fmm (사전 관통확률 %.0f%%)\n" % [res.pen_mean_mm, res.pen_roll_mm, res.pen_probability * 100.0]
	bb += "사건: %s\n" % ", ".join(res.events)
	bb += "피해: %s" % ("\n  " + "\n  ".join(dmg) if not dmg.is_empty() else "없음")
	_update_result(bb)
	_refresh_all()


func _add_marker(res: Dictionary) -> void:
	var e: Array = res.entry_local
	var mi := MeshInstance3D.new()
	mi.mesh = _marker_mesh
	mi.position = Vector3(e[0], e[1], e[2])
	mi.material_override = _marker_mats["pen" if res.penetrated else ("ricochet" if res.ricochet else "nonpen")]
	markers_root.add_child(mi)


## 현재 시점에서 실루엣 전체에 무작위 사격(매 발 새 전차). 결과 통계 + 탄착점 표시.
func _monte_carlo() -> void:
	for ch in markers_root.get_children():
		ch.queue_free()
	var inv := target_root.global_transform.affine_inverse()
	var center := Vector3(0, spec.total_height() * 0.5, 0)
	var dir := (inv.basis * (-camera.global_transform.basis.z)).normalized()
	var up := (inv.basis * camera.global_transform.basis.y).normalized()
	var right := dir.cross(up).normalized()
	var radius := Vector2(spec.hull_length, spec.total_height()).length() * 0.55
	var n_hit := 0
	var n_pen := 0
	var n_ric := 0
	var n_ko := 0
	var zones := {}
	var tries := 0
	while n_hit < 200 and tries < 2000:
		tries += 1
		var off := right * rng.randf_range(-radius, radius) + up * rng.randf_range(-radius, radius)
		var origin := center + off - dir * 40.0
		var st := TankDamageState.new(spec)
		var res := DamageModel.resolve_shot(st, turret_node.rotation.y, origin, dir, distance_m, shell, rng)
		if not res.hit:
			continue
		n_hit += 1
		_add_marker(res)
		var z: Dictionary = zones.get(res.zone, {"n": 0, "pen": 0})
		z.n += 1
		if res.penetrated:
			n_pen += 1
			z.pen += 1
		if res.ricochet:
			n_ric += 1
		if st.is_knocked_out():
			n_ko += 1
		zones[res.zone] = z
	var bb := "[b]현재 시점 200발 통계[/b]  %s, %dm\n" % [shell.shell_name, distance_m]
	bb += "사수 방위 %.0f° · 고각 %.0f° (표적 정면 기준)\n" % [_rel_bearing(), cam_pitch]
	bb += "관통 %.0f%% · 도탄 %.0f%% · 한 발에 전투불능 %.0f%%\n" % [100.0 * n_pen / maxf(n_hit, 1), 100.0 * n_ric / maxf(n_hit, 1), 100.0 * n_ko / maxf(n_hit, 1)]
	bb += "구역별 (명중 수 / 관통률):\n"
	var keys := zones.keys()
	keys.sort_custom(func(a, b): return zones[a].n > zones[b].n)
	for k in keys:
		bb += "  %s: %d발 / %.0f%%\n" % [k, zones[k].n, 100.0 * zones[k].pen / zones[k].n]
	bb += "(초록 = 관통, 빨강 = 불관통, 노랑 = 도탄)"
	result_text.text = bb
