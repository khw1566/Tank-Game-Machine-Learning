class_name WorldMarkers
extends Node3D
## 3D 장면 속 관찰 표시: 탄착 구슬(종류별 색), 사격 궤적(잠시 보였다 사라짐), 전차 이동 경로 선.
## 게임과 리플레이 뷰어가 같이 쓴다. 그래픽 전용이라 기록에는 영향 없음.

const TRACER_S := 1.2
const MAX_HIT_MARKERS := 128

var show_hits := true:
	set(v):
		show_hits = v
		_hits_root.visible = v
var show_paths := true:
	set(v):
		show_paths = v
		_paths_mesh.visible = v

var _hits_root := Node3D.new()
var _tracer_mesh := MeshInstance3D.new()
var _paths_mesh := MeshInstance3D.new()
var _tracers: Array = []   # {"from", "to", "age"}
var _mats := {}
var _hit_anchors := []


func _ready() -> void:
	add_child(_hits_root)
	for mi in [_tracer_mesh, _paths_mesh]:
		mi.mesh = ImmediateMesh.new()
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override = _vertex_color_mat()
		add_child(mi)


## 전차 머리 위 이름표(멀리서도 같은 크기, 지형에 가려지지 않음)
static func attach_label(t: Tank, color: Color) -> Label3D:
	var l := Label3D.new()
	l.name = "NameTag"
	l.text = t.name
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.fixed_size = true
	l.pixel_size = 0.0012
	l.font_size = 22
	l.outline_size = 8
	l.no_depth_test = true
	l.modulate = color.lightened(0.3)
	l.position = Vector3(0, t.spec.turret_origin().y + t.spec.turret_size.y + 1.5, 0)
	t.add_child(l)
	return l


func clear_hits() -> void:
	_hit_anchors.clear()
	for c in _hits_root.get_children():
		c.queue_free()


func add_hit(pos: Vector3, kind: String, normal := Vector3.UP, target: Node3D = null) -> void:
	if kind == "miss":
		return
	if _hits_root.get_child_count() >= MAX_HIT_MARKERS:
		var oldest := _hits_root.get_child(0)
		_hit_anchors = _hit_anchors.filter(func(h): return h.anchor != oldest)
		_hits_root.remove_child(oldest)
		oldest.queue_free()
	var anchor := Node3D.new()
	_hits_root.add_child(anchor)
	anchor.global_position = pos + normal.normalized() * .035
	anchor.quaternion = Quaternion(Vector3.UP, normal.normalized())
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = .12
	sm.height = sm.radius * 2.0
	sm.radial_segments = 8
	sm.rings = 4
	mi.mesh = sm
	mi.material_override = _flat(MinimapView.KIND_COLORS.get(kind, Color.WHITE))
	anchor.add_child(mi)
	var ring := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = .24
	torus.outer_radius = .29
	torus.rings = 16
	torus.ring_segments = 8
	ring.mesh = torus
	ring.material_override = mi.material_override
	anchor.add_child(ring)
	if target:
		_hit_anchors.append({"anchor": anchor, "target": target, "local": target.global_transform.affine_inverse() * anchor.global_transform})


func add_tracer(from: Vector3, to: Vector3, age := 0.0) -> void:
	_tracers.append({"from": from, "to": to, "age": age})


## 리플레이용: 현재 보이는 궤적 목록을 통째로 교체
func set_tracers(list: Array) -> void:
	_tracers = list


## paths: [{"points": PackedVector3Array, "color": Color}] (y 는 지면 높이 + 약간)
func set_paths(paths: Array) -> void:
	var im: ImmediateMesh = _paths_mesh.mesh
	im.clear_surfaces()
	for p in paths:
		if p.points.size() < 2:
			continue
		im.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for v in p.points:
			im.surface_set_color(p.color)
			im.surface_add_vertex(v)
		im.surface_end()


func _process(delta: float) -> void:
	for hit in _hit_anchors:
		if is_instance_valid(hit.target) and is_instance_valid(hit.anchor):
			hit.anchor.global_transform = hit.target.global_transform * hit.local
	var im: ImmediateMesh = _tracer_mesh.mesh
	im.clear_surfaces()
	var keep := []
	for t in _tracers:
		t.age += delta
		if t.age < TRACER_S:
			keep.append(t)
	_tracers = keep
	if _tracers.is_empty():
		return
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	for t in _tracers:
		var a: float = 1.0 - t.age / TRACER_S
		im.surface_set_color(Color(1.0, 0.85, 0.4, a))
		im.surface_add_vertex(t.from)
		im.surface_set_color(Color(1.0, 0.5, 0.2, a))
		im.surface_add_vertex(t.to)
	im.surface_end()


func _flat(c: Color) -> StandardMaterial3D:
	if not _mats.has(c):
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = c
		m.no_depth_test = false
		_mats[c] = m
	return _mats[c]


static func _vertex_color_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.vertex_color_use_as_albedo = true
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return m
