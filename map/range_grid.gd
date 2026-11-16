class_name RangeGrid
extends Node3D
## 거리 감각용 표시(그래픽 전용, 헤드리스에서는 만들지 않는다).
##  - 지면 격자: 100m 간격 선(500m 마다 굵은 색) + 맵 중심 기준 좌표 라벨
##  - 거리 링: 지정한 전차 주위 100m 간격 원(1km 까지) + 거리 라벨
## mode: 0 = 끔, 1 = 격자, 2 = 격자 + 거리 링, 3 = 거리 링만   (main 에서 G 키로 순환)

@export var spacing := 100.0
@export var ring_max := 1000.0
@export var lift := 0.35

var map: HillMap
var mode := 2:
	set(v):
		mode = v % 4
		if _grid:
			_grid.visible = mode == 1 or mode == 2
		if _rings:
			_rings.visible = mode >= 2

var _grid: Node3D
var _rings: Node3D
var _ring_mesh: MeshInstance3D
var _ring_labels: Array = []
var _ring_center := Vector3(INF, 0, INF)
var _ring_yaw := 0.0


func _init(p_map: HillMap = null) -> void:
	map = p_map


func _ready() -> void:
	_build_grid()
	_build_rings()
	mode = mode


func _line_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m


func _label(text: String, pos: Vector3, col: Color, px := 0.06) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.pixel_size = px
	l.font_size = 48
	l.outline_size = 12
	l.modulate = col
	l.no_depth_test = false
	return l


func _h(x: float, z: float) -> float:
	return map.height_at(x, z) + lift


func _build_grid() -> void:
	_grid = Node3D.new()
	_grid.name = "Grid"
	add_child(_grid)
	var half := map.size_m * 0.5
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var step := 5.0
	var n := int(half / spacing)
	for i in range(-n, n + 1):
		var c := i * spacing
		var major := i % 5 == 0
		var col := Color(1, 1, 0.6, 0.85) if major else Color(1, 1, 1, 0.45)
		var s := -half
		while s < half - 0.01:
			# X 방향 선(z = c)
			verts.append(Vector3(s, _h(s, c), c))
			verts.append(Vector3(s + step, _h(s + step, c), c))
			# Z 방향 선(x = c)
			verts.append(Vector3(c, _h(c, s), s))
			verts.append(Vector3(c, _h(c, s + step), s + step))
			for k in 4:
				cols.append(col)
			s += step
		if i != 0:
			var t := "%+dm" % int(c)
			# 중심선 위 라벨(가로·세로), 그리고 맵 양쪽 가장자리
			_grid.add_child(_label("z " + t, Vector3(0, _h(0, c) + 2.0, c), Color(1, 1, 0.7)))
			_grid.add_child(_label("x " + t, Vector3(c, _h(c, 0) + 2.0, 0), Color(1, 1, 0.7)))
	_grid.add_child(_label("0, 0", Vector3(0, _h(0, 0) + 2.0, 0), Color(1, 0.9, 0.5)))
	var mi := MeshInstance3D.new()
	mi.mesh = _lines_mesh(verts, cols)
	mi.material_override = _line_mat()
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_grid.add_child(mi)


func _build_rings() -> void:
	_rings = Node3D.new()
	_rings.name = "Rings"
	add_child(_rings)
	_ring_mesh = MeshInstance3D.new()
	_ring_mesh.material_override = _line_mat()
	_ring_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_rings.add_child(_ring_mesh)
	var r := spacing
	while r <= ring_max + 0.1:
		var l := _label("%dm" % int(r), Vector3.ZERO, Color(0.6, 1.0, 1.0), 0.08)
		_rings.add_child(l)
		_ring_labels.append(l)
		r += spacing


## 거리 링 중심을 옮긴다(전차 위치·포탑 방향). 5m 이상 움직였거나 방향이 바뀌었을 때만 다시 그림
func set_ring_center(p: Vector3, facing_yaw: float) -> void:
	if _rings == null or not _rings.visible:
		return
	var moved := Vector2(p.x - _ring_center.x, p.z - _ring_center.z).length() > 5.0
	if not moved and absf(wrapf(facing_yaw - _ring_yaw, -PI, PI)) < 0.15:
		return
	_ring_center = p
	_ring_yaw = facing_yaw
	var verts := PackedVector3Array()
	var cols := PackedColorArray()
	var half := map.size_m * 0.5
	var fwd := Vector2(-sin(facing_yaw), -cos(facing_yaw))
	var i := 0
	var r := spacing
	while r <= ring_max + 0.1:
		var segs := maxi(int(TAU * r / 12.0), 24)
		var col := Color(0.4, 1.0, 1.0, 0.9) if int(r) % 500 == 0 else Color(0.4, 1.0, 1.0, 0.5)
		for s in segs:
			var a0 := TAU * s / segs
			var a1 := TAU * (s + 1) / segs
			var q0 := Vector2(p.x + cos(a0) * r, p.z + sin(a0) * r)
			var q1 := Vector2(p.x + cos(a1) * r, p.z + sin(a1) * r)
			if absf(q0.x) > half or absf(q0.y) > half or absf(q1.x) > half or absf(q1.y) > half:
				continue
			verts.append(Vector3(q0.x, _h(q0.x, q0.y), q0.y))
			verts.append(Vector3(q1.x, _h(q1.x, q1.y), q1.y))
			cols.append(col)
			cols.append(col)
		# 라벨: 포탑이 향한 쪽 링 위
		var lp := Vector2(p.x, p.z) + fwd * r
		var lbl: Label3D = _ring_labels[i]
		lbl.visible = absf(lp.x) < half and absf(lp.y) < half
		lbl.position = Vector3(lp.x, _h(lp.x, lp.y) + 2.5, lp.y)
		i += 1
		r += spacing
	_ring_mesh.mesh = _lines_mesh(verts, cols)


func _lines_mesh(verts: PackedVector3Array, cols: PackedColorArray) -> ArrayMesh:
	var am := ArrayMesh.new()
	if verts.is_empty():
		return am
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	am.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return am
