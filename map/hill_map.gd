class_name HillMap
extends Node3D
## 완만한 구릉지 + 숲 군락 + 바위. 시드 하나로 완전히 재현된다(학습 에피소드마다 바꿔 쓸 수 있음).
##
## 충돌 레이어:  1 = 지형·바위·나무줄기(포탄 차단),  4 = 나무 수관(시야만 차단)
## height_at(x, z) 로 아무 지점의 지면 높이를 얻는다(스폰·AI 지형 판단용).

@export var map_seed := 1
@export var size_m := 1200.0
@export var cell_m := 10.0
@export var height_amplitude := 15.0
@export var noise_frequency := 0.0025
@export var forest_patches := 10
@export var trees_per_patch := 14
@export var lone_trees := 30
@export var rock_count := 45
## 스폰 지역(맵 양 끝) 주변은 장애물을 비워 둔다
@export var spawn_clear_radius := 60.0
@export var spawn_points: Array[Vector3] = [Vector3(0, 0, 450), Vector3(0, 0, -450)]

var noise := FastNoiseLite.new()
## 헤드리스(학습)에서는 메시 생략(충돌체만 생성)
var visuals_enabled := DisplayServer.get_name() != "headless"
var obstacles: Array = [] # [{"type": "tree"/"rock", "pos": Vector3, "radius": float}]


## 리플레이에서 불러온 맵 기록(비어 있으면 시드로 생성)
var _record := {}
## 지형 높이 격자((n+1)×(n+1), 행 = z)
var _heights := PackedFloat32Array()


func _ready() -> void:
	if _record.is_empty():
		generate()
	else:
		_build_from_record()


func generate() -> void:
	for ch in get_children():
		ch.queue_free()
	obstacles.clear()
	noise.seed = map_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = noise_frequency
	noise.fractal_octaves = 3
	_build_terrain()
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed * 7919 + 13
	_scatter(rng)


func height_at(x: float, z: float) -> float:
	if not _record.is_empty():
		return _grid_height(x, z)
	return noise.get_noise_2d(x, z) * height_amplitude


## 기록된 격자에서 쌍선형 보간
func _grid_height(x: float, z: float) -> float:
	var n := int(size_m / cell_m)
	var fx := clampf((x + size_m * 0.5) / cell_m, 0.0, n - 0.0001)
	var fz := clampf((z + size_m * 0.5) / cell_m, 0.0, n - 0.0001)
	var ix := int(fx)
	var iz := int(fz)
	var tx := fx - ix
	var tz := fz - iz
	var w := n + 1
	var a := lerpf(_heights[iz * w + ix], _heights[iz * w + ix + 1], tx)
	var b := lerpf(_heights[(iz + 1) * w + ix], _heights[(iz + 1) * w + ix + 1], tx)
	return lerpf(a, b, tz)


func normal_at(x: float, z: float) -> Vector3:
	var e := 1.0
	var hx := height_at(x + e, z) - height_at(x - e, z)
	var hz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


func _build_terrain() -> void:
	var n := int(size_m / cell_m)
	var half := size_m * 0.5
	var heights := PackedFloat32Array()
	heights.resize((n + 1) * (n + 1))
	for iz in n + 1:
		for ix in n + 1:
			heights[iz * (n + 1) + ix] = height_at(-half + ix * cell_m, -half + iz * cell_m)
	_heights = heights

	if visuals_enabled:
		_build_terrain_mesh(n, half, heights)
	_build_terrain_collision(n, heights)


func _build_terrain_mesh(n: int, half: float, heights: PackedFloat32Array) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for iz in n:
		for ix in n:
			var p00 := Vector3(-half + ix * cell_m, heights[iz * (n + 1) + ix], -half + iz * cell_m)
			var p10 := Vector3(p00.x + cell_m, heights[iz * (n + 1) + ix + 1], p00.z)
			var p01 := Vector3(p00.x, heights[(iz + 1) * (n + 1) + ix], p00.z + cell_m)
			var p11 := Vector3(p00.x + cell_m, heights[(iz + 1) * (n + 1) + ix + 1], p00.z + cell_m)
			st.add_vertex(p00)
			st.add_vertex(p10)
			st.add_vertex(p01)
			st.add_vertex(p10)
			st.add_vertex(p11)
			st.add_vertex(p01)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.5, 0.28)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	add_child(mi)


func _build_terrain_collision(n: int, heights: PackedFloat32Array) -> void:
	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.collision_layer = 1
	body.collision_mask = 0
	var cs := CollisionShape3D.new()
	var hs := HeightMapShape3D.new()
	hs.map_width = n + 1
	hs.map_depth = n + 1
	hs.map_data = heights
	cs.shape = hs
	cs.scale = Vector3(cell_m, 1.0, cell_m)
	body.add_child(cs)
	add_child(body)


func _scatter(rng: RandomNumberGenerator) -> void:
	var half := size_m * 0.5 - 20.0
	for p in forest_patches:
		var c := Vector2(rng.randf_range(-half, half), rng.randf_range(-half * 0.8, half * 0.8))
		var spread := rng.randf_range(20.0, 45.0)
		for t in trees_per_patch:
			var pos := c + Vector2(rng.randfn(0.0, spread), rng.randfn(0.0, spread))
			_try_tree(pos, rng)
	for t in lone_trees:
		_try_tree(Vector2(rng.randf_range(-half, half), rng.randf_range(-half, half)), rng)
	for r in rock_count:
		var pos := Vector2(rng.randf_range(-half, half), rng.randf_range(-half, half))
		if _clear_of_spawns(pos):
			_add_rock(pos, rng)


func _clear_of_spawns(p: Vector2) -> bool:
	for sp in spawn_points:
		if p.distance_to(Vector2(sp.x, sp.z)) < spawn_clear_radius:
			return false
	return absf(p.x) < size_m * 0.5 - 5.0 and absf(p.y) < size_m * 0.5 - 5.0


func _try_tree(p: Vector2, rng: RandomNumberGenerator) -> void:
	if _clear_of_spawns(p):
		_add_tree(p, rng)


func _add_tree(p: Vector2, rng: RandomNumberGenerator) -> void:
	var h := rng.randf_range(7.0, 12.0)
	var trunk_r := rng.randf_range(0.25, 0.45)
	var crown_r := rng.randf_range(2.0, 3.5)
	_place_tree(Vector3(p.x, height_at(p.x, p.y), p.y), h, trunk_r, crown_r)


## 나무 1그루를 정확한 치수로 배치(생성기와 리플레이 재구성이 같이 사용)
func _place_tree(pos: Vector3, h: float, trunk_r: float, crown_r: float) -> void:
	var root := StaticBody3D.new()
	root.name = "Tree%d" % obstacles.size()
	root.position = pos
	root.collision_layer = 1
	root.collision_mask = 0
	add_child(root)
	# 줄기: 포탄·전차 차단
	var trunk_shape := CollisionShape3D.new()
	var cyl := CylinderShape3D.new()
	cyl.radius = trunk_r
	cyl.height = h * 0.5
	trunk_shape.shape = cyl
	trunk_shape.position.y = h * 0.25
	root.add_child(trunk_shape)
	var crown_y := h * 0.75
	if visuals_enabled:
		_add_tree_visuals(root, h, trunk_r, crown_r, crown_y)
	var foliage := Area3D.new()
	foliage.collision_layer = 4
	foliage.collision_mask = 0
	foliage.monitoring = false
	var fs := CollisionShape3D.new()
	var fcyl := CylinderShape3D.new()
	fcyl.radius = crown_r * 0.8
	fcyl.height = h * 0.7
	fs.shape = fcyl
	fs.position.y = crown_y
	foliage.add_child(fs)
	root.add_child(foliage)
	obstacles.append({"type": "tree", "pos": pos, "radius": crown_r, "h": h, "trunk_r": trunk_r})


func _add_tree_visuals(root: Node3D, h: float, trunk_r: float, crown_r: float, crown_y: float) -> void:
	var trunk := MeshInstance3D.new()
	var tm := CylinderMesh.new()
	tm.top_radius = trunk_r * 0.8
	tm.bottom_radius = trunk_r
	tm.height = h * 0.5
	trunk.mesh = tm
	trunk.position.y = h * 0.25
	trunk.material_override = _color_mat(Color(0.35, 0.25, 0.15))
	root.add_child(trunk)
	# 수관: 시야만 차단(레이어 4, 위 _add_tree 에서 Area3D 로 생성)
	var crown := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.0
	cm.bottom_radius = crown_r
	cm.height = h * 0.7
	crown.mesh = cm
	crown.position.y = crown_y
	crown.material_override = _color_mat(Color(0.18, 0.33, 0.15))
	root.add_child(crown)


func _add_rock(p: Vector2, rng: RandomNumberGenerator) -> void:
	var s := Vector3(rng.randf_range(2.0, 5.0), rng.randf_range(1.5, 3.0), rng.randf_range(2.0, 5.0))
	var ground := height_at(p.x, p.y)
	_place_rock(Vector3(p.x, ground + s.y * 0.35, p.y), s, rng.randf() * TAU)


func _place_rock(pos: Vector3, s: Vector3, rot_y: float) -> void:
	var body := StaticBody3D.new()
	body.name = "Rock%d" % obstacles.size()
	body.position = pos
	body.rotation.y = rot_y
	body.collision_layer = 1
	body.collision_mask = 0
	add_child(body)
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = s
	shape.shape = bs
	body.add_child(shape)
	if visuals_enabled:
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = s
		mi.mesh = bm
		mi.material_override = _color_mat(Color(0.5, 0.5, 0.48))
		body.add_child(mi)
	obstacles.append({"type": "rock", "pos": pos, "radius": maxf(s.x, s.z) * 0.5, "size": s, "rot_y": rot_y})


## 리플레이 기록용: 지형 높이 격자와 장애물의 정확한 치수.
## 생성 알고리즘이 나중에 바뀌어도 이 기록만으로 같은 맵을 다시 만든다.
func to_record() -> Dictionary:
	var obs := []
	for o in obstacles:
		var e := {"type": o.type, "pos": _r3(o.pos), "radius": snappedf(o.radius, 0.001)}
		if o.type == "tree":
			e["h"] = snappedf(o.h, 0.001)
			e["trunk_r"] = snappedf(o.trunk_r, 0.001)
		else:
			e["size"] = _r3(o.size)
			e["rot_y"] = snappedf(o.rot_y, 0.0001)
		obs.append(e)
	var hs := []
	for v in _heights:
		hs.append(snappedf(v, 0.001))
	return {"generator": "HillMap", "seed": map_seed, "size_m": size_m, "cell_m": cell_m,
		"height_amplitude": height_amplitude, "noise_frequency": noise_frequency,
		"spawn_points": spawn_points.map(func(v): return _r3(v)), "heights": hs, "obstacles": obs}


## 기록에서 맵 재구성(리플레이 뷰어용). generate() 대신 호출하고 add_child 전에 불러도 된다.
func load_record(rec: Dictionary) -> void:
	_record = rec
	if is_inside_tree():
		_build_from_record()


func _build_from_record() -> void:
	for ch in get_children():
		ch.queue_free()
	obstacles.clear()
	map_seed = int(_record.get("seed", map_seed))
	size_m = float(_record.size_m)
	cell_m = float(_record.cell_m)
	_heights = PackedFloat32Array(_record.heights)
	var n := int(size_m / cell_m)
	if visuals_enabled:
		_build_terrain_mesh(n, size_m * 0.5, _heights)
	_build_terrain_collision(n, _heights)
	for o in _record.obstacles:
		var p := Vector3(o.pos[0], o.pos[1], o.pos[2])
		if o.type == "tree":
			_place_tree(p, o.h, o.trunk_r, o.radius)
		else:
			_place_rock(p, Vector3(o.size[0], o.size[1], o.size[2]), o.rot_y)


static func _r3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]


var _mat_cache := {}


func _color_mat(c: Color) -> StandardMaterial3D:
	if not _mat_cache.has(c):
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		_mat_cache[c] = m
	return _mat_cache[c]
