class_name HillMap
extends Node3D
## 전술 지형 생성기. 시드 하나로 완전히 재현된다(학습 에피소드마다 바꿔 쓸 수 있음).
##
## 구성 (전차 시야를 가리는 요소 위주):
##  - 능선(ridge): 진격축(Z)을 가로지르는 긴 둔덕. 반사면(reverse slope)에서 차체를 숨기는 hull-down 용. 군데군데 안부(saddle) 통로.
##  - 숲(woods): 큰 숲 덩어리. 안에 들어가면 은폐, 숲 너머는 거의 안 보임(관목층 포함).
##  - 수목선(tree line): 일부 능선 마루를 따라 늘어선 나무 띠.
##  - 생울타리(hedgerow): 흙둑(1.2m, 포탄·시야 차단) + 그 위 덤불(3.5m, 시야만 차단). 출입구 틈 있음.
##  - 돌담(wall): 1.4m. 차체는 가리고 포탑만 드러남(hull-down 자리).
##  - 건물: 마을 1곳(교차로 주변) + 외딴 농가. 포탄·시야 모두 차단.
##  - 바위 무더기, 외딴 나무.
##  - 낮은 장애물: 돌(0.3~0.75m)·쓰러진 통나무(0.45~0.6m). 전차가 넘을 수 있는 높이(obstacle_step_m)면 타고 넘으며
##    차체가 피치/롤로 기운다(포를 다시 맞춰야 함). 전차마다 넘는 한계가 달라 같은 돌이 셔먼(0.61m)에겐 벽일 수 있다.
##  - 잔굴곡(micro relief): 30m 안팎 파장의 ±0.6m 기복 → 주행 중 차체가 계속 조금씩 출렁인다.
##
## 충돌 레이어:  1 = 지형·바위·나무줄기·건물·흙둑·돌담(포탄·시야 차단),  4 = 수관·덤불·숲 관목층(시야만 차단)
## 시야 판정은 LineOfSight(map/line_of_sight.gd) 가 한다: 레이어 1·2 는 물리 레이캐스트,
## 레이어 4 는 vision_volumes 로 해석적으로 "잎을 통과한 거리"를 구해 투과율로 바꾼다.
##
## height_at(x, z) 로 아무 지점의 지면 높이를 얻는다(스폰·AI 지형 판단용).

## 시야만 가리는 볼륨 종류별 밀도(1m 통과당 감쇠 계수). 투과율 = exp(-Σ 밀도 × 통과거리)
const DENSITY_WOODS := 0.09      # 숲 25m 통과 → 10%
const DENSITY_HEDGE := 0.9       # 덤불 2.5m 통과 → 10%
const DENSITY_TREELINE := 0.35   # 수목선 6m 통과 → 12%
const DENSITY_CROWN := 0.3       # 외딴 나무 수관 6m 통과 → 17%

const LAYER_GROUND := 1
## 돌담 높이: 차체 중간까지 가림(포탑은 보임) → hull-down 자리
const WALL_HEIGHT := 1.4
const LAYER_FOLIAGE := 4

@export var map_seed := 1
@export var size_m := 1200.0
## 지형 격자 간격(m). 능선 마루 모양을 살리려고 5m.
@export var cell_m := 5.0
## 0 이면 완전 평지(능선 포함)
@export var height_amplitude := 15.0
@export var noise_frequency := 0.0025
## false 면 지형만 만들고 장애물은 하나도 두지 않는다(테스트용)
@export var features_enabled := true
@export var ridge_count := 3
@export var ridge_height := 7.0
@export var forest_patches := 8
@export var tree_lines := 2
@export var hedgerow_count := 9
@export var wall_count := 5
@export var village := true
@export var farm_count := 3
@export var lone_trees := 35
@export var rock_count := 60
## 낮은 돌·쓰러진 통나무 수(전차가 타고 넘는 장애물)
@export var stone_count := 90
@export var log_count := 30
## 잔굴곡 진폭(m, height_amplitude 15 기준). 0 이면 없음
@export var micro_relief_m := 0.6
## 스폰 지역(맵 양 끝)은 X ±spawn_clear_half_width, Z ±spawn_clear_radius 를 비워 둔다
@export var spawn_clear_radius := 60.0
@export var spawn_clear_half_width := 110.0
@export var spawn_points: Array[Vector3] = [Vector3(0, 0, 450), Vector3(0, 0, -450)]

var noise := FastNoiseLite.new()
var _rough := FastNoiseLite.new()
## 헤드리스(학습)에서는 메시 생략(충돌체만 생성)
var visuals_enabled := DisplayServer.get_name() != "headless"
## 보고서·리플레이용 장애물 목록: {"type", "pos": Vector3, "radius", ...}
## type: tree, woods, treeline, hedge, wall, building, rock
var obstacles: Array = []
## 시야만 가리는 볼륨(LineOfSight 가 사용):
## {"kind": "cyl"/"box", "type", "c": Vector2, "r": float(cyl), "half": Vector2(box), "yaw": float(box),
##  "y0", "y1", "density", "aabb": Rect2}
var vision_volumes: Array = []
## 능선 정보: {"z0", "amp", "freq", "phase", "height", "sigma", "gaps": [[x, depth], ...]}
var ridges: Array = []

var _occupied: Array = [] # [[Vector2, r]] 건물 자리(다른 장애물 배치 금지)
var _bodies := {}          # kind -> StaticBody3D
var _foliage_area: Area3D
var _mm := {}              # visual key -> Array[Transform3D]
var _mm_col := {}          # visual key -> Array[Color]


var _generated := false
## 배치 기록: 충돌체·시야 볼륨·외형 하나하나(리플레이 재구성용, to_record 로 저장)
var _journal: Array = []
## 지형 높이 격자((n+1)×(n+1), 행 = z)
var _heights := PackedFloat32Array()
## 리플레이에서 불러온 맵 기록(비어 있으면 시드로 생성)
var _record := {}


func _ready() -> void:
	# 트리에 넣기 전에 generate() 를 직접 불렀다면(테스트·시나리오) 다시 만들지 않는다
	if not _record.is_empty():
		_build_from_record()
	elif not _generated:
		generate()


func generate() -> void:
	_generated = true
	for ch in get_children():
		ch.free()
	_foliage_area = null
	obstacles.clear()
	vision_volumes.clear()
	ridges.clear()
	_occupied.clear()
	_bodies.clear()
	_mm.clear()
	_mm_col.clear()
	_journal.clear()
	noise.seed = map_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = noise_frequency
	noise.fractal_octaves = 3
	_rough.seed = map_seed + 101
	_rough.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_rough.frequency = 0.03
	_rough.fractal_octaves = 2
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed * 7919 + 13
	_plan_ridges(rng)
	_build_terrain()
	if features_enabled:
		_foliage_area = Area3D.new()
		_foliage_area.name = "Foliage"
		_foliage_area.collision_layer = LAYER_FOLIAGE
		_foliage_area.collision_mask = 0
		_foliage_area.monitoring = false
		_foliage_area.monitorable = false
		add_child(_foliage_area)
		_scatter(rng)
		if visuals_enabled:
			_flush_multimeshes()


# ---------------------------------------------------------------- 지형

func height_at(x: float, z: float) -> float:
	if not _record.is_empty():
		return _grid_height(x, z)
	if height_amplitude == 0.0:
		return 0.0
	var h := noise.get_noise_2d(x, z) * height_amplitude * 0.6
	var k := height_amplitude / 15.0
	h += _rough.get_noise_2d(x, z) * micro_relief_m * k
	for r in ridges:
		var cz: float = r.z0 + r.amp * sin(x * r.freq + r.phase)
		var d: float = z - cz
		var bump: float = exp(-d * d / (2.0 * r.sigma * r.sigma))
		if bump < 0.01:
			continue
		var g := 1.0
		for gap in r.gaps:
			var dx: float = x - gap[0]
			g -= gap[1] * exp(-dx * dx / (2.0 * 35.0 * 35.0))
		h += r.height * k * bump * maxf(g, 0.0)
	return h


func normal_at(x: float, z: float) -> Vector3:
	var e := 1.0
	var hx := height_at(x + e, z) - height_at(x - e, z)
	var hz := height_at(x, z + e) - height_at(x, z - e)
	return Vector3(-hx, 2.0 * e, -hz).normalized()


## 그 지점의 시야 차단 잎 볼륨 이름 목록(AI 관측: "숲 속에 있는가" 등)
func cover_at(p: Vector3) -> Array:
	var out := []
	var q := Vector2(p.x, p.z)
	for v in vision_volumes:
		if not v.aabb.has_point(q) or p.y < v.y0 or p.y > v.y1:
			continue
		if v.kind == "cyl":
			if q.distance_to(v.c) <= v.r:
				out.append(v.type)
		else:
			var l: Vector2 = (q - v.c).rotated(-v.yaw)
			if absf(l.x) <= v.half.x and absf(l.y) <= v.half.y:
				out.append(v.type)
	return out


func _plan_ridges(rng: RandomNumberGenerator) -> void:
	if ridge_count <= 0:
		return
	# 진격축(Z)을 고르게 나눠 배치, 스폰 지역과는 떨어지게
	var span := absf(spawn_points[0].z - spawn_points[1].z) - 2.0 * (spawn_clear_radius + 60.0)
	var mid := (spawn_points[0].z + spawn_points[1].z) * 0.5
	for i in ridge_count:
		var t := 0.5 if ridge_count == 1 else float(i) / float(ridge_count - 1)
		var z0 := mid - span * 0.5 + span * t + rng.randf_range(-30.0, 30.0)
		var gaps := []
		for g in rng.randi_range(1, 2):
			gaps.append([rng.randf_range(-size_m * 0.4, size_m * 0.4), rng.randf_range(0.5, 0.85)])
		ridges.append({"z0": z0, "amp": rng.randf_range(15.0, 45.0), "freq": rng.randf_range(0.004, 0.009),
			"phase": rng.randf() * TAU, "height": ridge_height * rng.randf_range(0.7, 1.25),
			"sigma": rng.randf_range(22.0, 38.0), "gaps": gaps})


func ridge_crest_z(r: Dictionary, x: float) -> float:
	return r.z0 + r.amp * sin(x * r.freq + r.phase)


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
	var w := n + 1
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	verts.resize(w * w)
	normals.resize(w * w)
	colors.resize(w * w)
	var low := Color(0.36, 0.46, 0.24)
	var high := Color(0.55, 0.56, 0.32)
	var amp := maxf(height_amplitude, 1.0)
	for iz in w:
		for ix in w:
			var i := iz * w + ix
			var h := heights[i]
			verts[i] = Vector3(-half + ix * cell_m, h, -half + iz * cell_m)
			var hl := heights[iz * w + maxi(ix - 1, 0)]
			var hr := heights[iz * w + mini(ix + 1, n)]
			var hd := heights[maxi(iz - 1, 0) * w + ix]
			var hu := heights[mini(iz + 1, n) * w + ix]
			var nrm := Vector3(hl - hr, 2.0 * cell_m, hd - hu).normalized()
			normals[i] = nrm
			var c := low.lerp(high, clampf((h / amp + 0.6) * 0.6, 0.0, 1.0))
			# 경사면은 약간 어둡게: 능선 윤곽이 잘 보이도록
			c = c.darkened(clampf((1.0 - nrm.y) * 6.0, 0.0, 0.35))
			# 체커 무늬(50m)로 거리감 보조
			if (int(floor(verts[i].x / 50.0)) + int(floor(verts[i].z / 50.0))) % 2 == 0:
				c = c.darkened(0.04)
			colors[i] = c
	var idx := PackedInt32Array()
	idx.resize(n * n * 6)
	var k := 0
	for iz in n:
		for ix in n:
			var a := iz * w + ix
			idx[k] = a
			idx[k + 1] = a + 1
			idx[k + 2] = a + w
			idx[k + 3] = a + 1
			idx[k + 4] = a + w + 1
			idx[k + 5] = a + w
			k += 6
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mi := MeshInstance3D.new()
	mi.name = "TerrainMesh"
	mi.mesh = am
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	add_child(mi)


func _build_terrain_collision(n: int, heights: PackedFloat32Array) -> void:
	var body := StaticBody3D.new()
	body.name = "Terrain"
	body.collision_layer = LAYER_GROUND
	body.collision_mask = 0
	body.set_meta("kind", "terrain")
	var cs := CollisionShape3D.new()
	var hs := HeightMapShape3D.new()
	hs.map_width = n + 1
	hs.map_depth = n + 1
	hs.map_data = heights
	cs.shape = hs
	cs.scale = Vector3(cell_m, 1.0, cell_m)
	body.add_child(cs)
	add_child(body)


# ---------------------------------------------------------------- 배치

func _scatter(rng: RandomNumberGenerator) -> void:
	# 순서 고정(시드 재현성): 건물 → 생울타리·돌담 → 숲 → 수목선 → 외딴 나무 → 바위
	if village:
		_place_village(rng)
	for i in farm_count:
		_place_farm(rng)
	for i in hedgerow_count:
		_place_linear(rng, "hedge")
	for i in wall_count:
		_place_linear(rng, "wall")
	for i in forest_patches:
		_place_woods(rng, i)
	for i in mini(tree_lines, ridges.size()):
		_place_tree_line(rng, ridges[(i * 2) % ridges.size()])
	var half := size_m * 0.5 - 20.0
	for i in lone_trees:
		var p := Vector2(rng.randf_range(-half, half), rng.randf_range(-half, half))
		if _is_free(p, 3.0):
			_add_lone_tree(p, rng)
	var clusters := maxi(int(rock_count / 4.0), 1) if rock_count > 0 else 0
	var placed := 0
	for c in clusters:
		var cc := Vector2(rng.randf_range(-half, half), rng.randf_range(-half, half))
		var per := rng.randi_range(2, 6)
		for j in per:
			if placed >= rock_count:
				break
			var p := cc + Vector2(rng.randfn(0.0, 6.0), rng.randfn(0.0, 6.0))
			if _is_free(p, 3.0):
				_add_rock(p, rng)
			placed += 1
	# 낮은 장애물은 별도 난수열(기존 배치의 시드 재현성을 그대로 유지)
	var srng := RandomNumberGenerator.new()
	srng.seed = map_seed * 104729 + 71
	for i in stone_count:
		var p := Vector2(srng.randf_range(-half, half), srng.randf_range(-half, half))
		if _is_free(p, 1.5):
			_add_stone(p, srng)
	for i in log_count:
		var p := Vector2(srng.randf_range(-half, half), srng.randf_range(-half, half))
		if _is_free(p, 4.0):
			_add_log(p, srng)


func _in_spawn_zone(p: Vector2, margin := 0.0) -> bool:
	for sp in spawn_points:
		if absf(p.x - sp.x) < spawn_clear_half_width + margin and absf(p.y - sp.z) < spawn_clear_radius + margin:
			return true
	return false


func _in_bounds(p: Vector2, margin := 5.0) -> bool:
	return absf(p.x) < size_m * 0.5 - margin and absf(p.y) < size_m * 0.5 - margin


func _is_free(p: Vector2, r: float) -> bool:
	if not _in_bounds(p, r) or _in_spawn_zone(p, r):
		return false
	for o in _occupied:
		if p.distance_to(o[0]) < o[1] + r:
			return false
	return true


## 학습·시나리오용: 반지름 r 안에 장애물(바위·나무·건물·숲 등)이 없고 맵 안이면 true (출발 구역 여부는 무시)
func is_clear(p: Vector2, r: float) -> bool:
	if not _in_bounds(p, r + 20.0):
		return false
	for o in _occupied:
		if p.distance_to(o[0]) < o[1] + r:
			return false
	return true


func _body(kind: String) -> StaticBody3D:
	if not _bodies.has(kind):
		var b := StaticBody3D.new()
		b.name = kind.capitalize().replace(" ", "")
		b.collision_layer = LAYER_GROUND
		b.collision_mask = 0
		b.set_meta("kind", kind)
		add_child(b)
		_bodies[kind] = b
	return _bodies[kind]


func _add_box_shape(kind: String, center: Vector3, size: Vector3, yaw: float) -> void:
	_journal.append(["box", kind, center, size, yaw])
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = size
	cs.shape = bs
	cs.transform = Transform3D(Basis(Vector3.UP, yaw), center)
	_body(kind).add_child(cs)


func _add_cyl_shape(kind: String, center: Vector3, radius: float, height: float) -> void:
	_journal.append(["cyl", kind, center, radius, height])
	var cs := CollisionShape3D.new()
	var c := CylinderShape3D.new()
	c.radius = radius
	c.height = height
	cs.shape = c
	cs.position = center
	_body(kind).add_child(cs)


## 시야 볼륨 등록(+ 레이어 4 충돌체: 다른 코드가 물리 쿼리로도 쓸 수 있게)
func _add_vision_cyl(type: String, c: Vector2, r: float, y0: float, y1: float, density: float) -> void:
	_journal.append(["vcyl", type, c, r, y0, y1, density])
	vision_volumes.append({"kind": "cyl", "type": type, "c": c, "r": r, "y0": y0, "y1": y1,
		"density": density, "aabb": Rect2(c - Vector2(r, r), Vector2(2 * r, 2 * r))})
	var cs := CollisionShape3D.new()
	var s := CylinderShape3D.new()
	s.radius = r
	s.height = y1 - y0
	cs.shape = s
	cs.position = Vector3(c.x, (y0 + y1) * 0.5, c.y)
	_foliage_area.add_child(cs)


func _add_vision_box(type: String, c: Vector2, half: Vector2, yaw: float, y0: float, y1: float, density: float) -> void:
	_journal.append(["vbox", type, c, half, yaw, y0, y1, density])
	var ext := Vector2(absf(half.x * cos(yaw)) + absf(half.y * sin(yaw)), absf(half.x * sin(yaw)) + absf(half.y * cos(yaw)))
	vision_volumes.append({"kind": "box", "type": type, "c": c, "half": half, "yaw": yaw, "y0": y0, "y1": y1,
		"density": density, "aabb": Rect2(c - ext, ext * 2.0)})
	var cs := CollisionShape3D.new()
	var s := BoxShape3D.new()
	s.size = Vector3(half.x * 2.0, y1 - y0, half.y * 2.0)
	cs.shape = s
	# 2D 회전(yaw)은 x→z 평면에서 반시계. Godot Basis(UP, a)는 x 를 -z 쪽으로 돌리므로 부호 반전
	cs.transform = Transform3D(Basis(Vector3.UP, -yaw), Vector3(c.x, (y0 + y1) * 0.5, c.y))
	_foliage_area.add_child(cs)


func _visual(key: String, xf: Transform3D, col: Color) -> void:
	_journal.append(["vis", key, xf, col])
	if not visuals_enabled:
		return
	if not _mm.has(key):
		_mm[key] = []
		_mm_col[key] = []
	_mm[key].append(xf)
	_mm_col[key].append(col)


## Godot 의 Basis(UP, a) 와 2D 방향 각(atan2(dir.y, dir.x)) 사이 변환
func _yaw_basis(yaw2d: float, scale: Vector3) -> Basis:
	return Basis(Vector3.UP, -yaw2d) * Basis.from_scale(scale)


# --- 건물

func _place_village(rng: RandomNumberGenerator) -> void:
	var center := Vector2(rng.randf_range(-size_m * 0.25, size_m * 0.25), rng.randf_range(-80.0, 80.0))
	var road_yaw := rng.randf_range(-0.4, 0.4)
	var houses := rng.randi_range(7, 11)
	for i in houses:
		# 두 도로(교차로)를 따라 양쪽에 집
		var along := rng.randf_range(-70.0, 70.0)
		var side := 1.0 if rng.randf() < 0.5 else -1.0
		var axis := road_yaw if i % 2 == 0 else road_yaw + PI * 0.5
		var dir := Vector2(cos(axis), sin(axis))
		var nrm := Vector2(-dir.y, dir.x)
		var p := center + dir * along + nrm * side * rng.randf_range(10.0, 16.0)
		_try_building(p, axis, rng, rng.randf_range(4.5, 7.5))
	obstacles.append({"type": "village", "pos": _v3(center), "radius": 80.0})


func _place_farm(rng: RandomNumberGenerator) -> void:
	for attempt in 10:
		var half := size_m * 0.5 - 60.0
		var p := Vector2(rng.randf_range(-half, half), rng.randf_range(-half * 0.75, half * 0.75))
		if not _is_free(p, 30.0):
			continue
		var yaw := rng.randf() * TAU
		_try_building(p, yaw, rng, rng.randf_range(5.0, 7.0))
		var dir := Vector2(cos(yaw), sin(yaw))
		_try_building(p + dir * 18.0 + Vector2(-dir.y, dir.x) * 6.0, yaw, rng, rng.randf_range(6.0, 8.5)) # 헛간
		# 농가를 두르는 돌담 두 면
		var a := p - dir * 14.0 - Vector2(-dir.y, dir.x) * 14.0
		_add_wall_line(a, a + dir * 40.0)
		_add_wall_line(a, a + Vector2(-dir.y, dir.x) * 30.0)
		return


func _try_building(p: Vector2, yaw: float, rng: RandomNumberGenerator, h: float) -> void:
	var size := Vector3(rng.randf_range(8.0, 13.0), h, rng.randf_range(6.0, 9.0))
	var r := Vector2(size.x, size.z).length() * 0.5
	if not _is_free(p, r):
		return
	var g := minf(minf(height_at(p.x - r, p.y), height_at(p.x + r, p.y)), minf(height_at(p.x, p.y - r), height_at(p.x, p.y + r)))
	var top := maxf(maxf(height_at(p.x - r, p.y), height_at(p.x + r, p.y)), maxf(height_at(p.x, p.y - r), height_at(p.x, p.y + r)))
	var wall_h := size.y + (top - g)
	var center := Vector3(p.x, g + wall_h * 0.5, p.y)
	_add_box_shape("building", center, Vector3(size.x, wall_h, size.z), -yaw)
	_occupied.append([p, r + 3.0])
	obstacles.append({"type": "building", "pos": Vector3(p.x, g, p.y), "radius": r, "size": size, "yaw": yaw, "height": wall_h})
	# 외형 배치도 항상 계산(헤드리스 학습에서도 같은 난수 순서 + 리플레이 기록용)
	var wall_col := Color(0.78, 0.74, 0.64).darkened(rng.randf() * 0.15)
	_visual("box", Transform3D(_yaw_basis(yaw, Vector3(size.x, wall_h, size.z)), center), wall_col)
	var roof_h := size.z * 0.45
	_visual("roof", Transform3D(Basis(Vector3.UP, -yaw) * Basis(Vector3.UP, PI * 0.5) * Basis.from_scale(Vector3(size.z + 0.8, roof_h, size.x + 0.6)),
		Vector3(p.x, g + wall_h + roof_h * 0.5, p.y)), Color(0.55, 0.25, 0.18).darkened(rng.randf() * 0.2))


# --- 생울타리·돌담

func _place_linear(rng: RandomNumberGenerator, kind: String) -> void:
	var half := size_m * 0.5 - 40.0
	var a := Vector2(rng.randf_range(-half, half), rng.randf_range(-half * 0.85, half * 0.85))
	# 70%: 진격축을 가로지름(X 방향, 앞을 가리는 차폐선), 30%: Z 방향(측면 우회로 차폐)
	var yaw := rng.randf_range(-0.35, 0.35) if rng.randf() < 0.7 else PI * 0.5 + rng.randf_range(-0.35, 0.35)
	var length := rng.randf_range(90.0, 240.0)
	var bend := rng.randf_range(-0.5, 0.5)
	var mid := a + Vector2(cos(yaw), sin(yaw)) * length * 0.5
	var b := mid + Vector2(cos(yaw + bend), sin(yaw + bend)) * length * 0.5
	if kind == "hedge":
		_add_hedge_line(a, mid, rng)
		_add_hedge_line(mid, b, rng)
	else:
		_add_wall_line(a, mid)
		_add_wall_line(mid, b)


func _segments(a: Vector2, b: Vector2, piece: float) -> Array:
	var out := []
	var n := maxi(int(ceil(a.distance_to(b) / piece)), 1)
	for i in n:
		out.append([a.lerp(b, float(i) / n), a.lerp(b, float(i + 1) / n)])
	return out


func _add_hedge_line(a: Vector2, b: Vector2, rng: RandomNumberGenerator) -> void:
	var yaw := (b - a).angle()
	obstacles.append({"type": "hedge", "pos": _v3((a + b) * 0.5), "radius": a.distance_to(b) * 0.5,
		"a": _v3(a), "b": _v3(b)})
	for s in _segments(a, b, 12.0):
		var p0: Vector2 = s[0]
		var p1: Vector2 = s[1]
		var c := (p0 + p1) * 0.5
		var len := p0.distance_to(p1)
		if not _is_free(c, 2.0) or rng.randf() < 0.1: # 출입구(틈)
			continue
		var g := minf(height_at(p0.x, p0.y), height_at(p1.x, p1.y))
		var gmax := maxf(height_at(p0.x, p0.y), height_at(p1.x, p1.y))
		var bank_h := 1.2 + (gmax - g)
		var bush_top := gmax + rng.randf_range(3.0, 4.2)
		_add_box_shape("hedge", Vector3(c.x, g + bank_h * 0.5 - 0.3, c.y), Vector3(len + 0.4, bank_h + 0.6, 2.2), -yaw)
		_add_vision_box("hedge", c, Vector2(len * 0.5 + 0.2, 1.3), yaw, g, bush_top, DENSITY_HEDGE)
		# 외형 배치도 항상 계산(헤드리스 학습에서도 같은 난수 순서 + 리플레이 기록용)
		_visual("box", Transform3D(_yaw_basis(yaw, Vector3(len + 0.4, bank_h + 0.6, 2.4)),
			Vector3(c.x, g + bank_h * 0.5 - 0.3, c.y)), Color(0.42, 0.36, 0.24))
		var bush_bottom := g + bank_h - 0.3
		_visual("bush", Transform3D(_yaw_basis(yaw, Vector3(len + 0.6, bush_top - bush_bottom, 2.8)),
			Vector3(c.x, (bush_bottom + bush_top) * 0.5, c.y)), Color(0.2, 0.36, 0.16).darkened(rng.randf() * 0.15))


func _add_wall_line(a: Vector2, b: Vector2) -> void:
	var yaw := (b - a).angle()
	obstacles.append({"type": "wall", "pos": _v3((a + b) * 0.5), "radius": a.distance_to(b) * 0.5,
		"a": _v3(a), "b": _v3(b)})
	for s in _segments(a, b, 10.0):
		var p0: Vector2 = s[0]
		var p1: Vector2 = s[1]
		var c := (p0 + p1) * 0.5
		if not _in_bounds(c) or _in_spawn_zone(c, 1.0) or not _is_free(c, 0.5):
			continue
		var len := p0.distance_to(p1)
		var g := minf(height_at(p0.x, p0.y), height_at(p1.x, p1.y))
		var top := maxf(height_at(p0.x, p0.y), height_at(p1.x, p1.y)) + WALL_HEIGHT
		var center := Vector3(c.x, (g - 0.3 + top) * 0.5, c.y)
		var size := Vector3(len + 0.3, top - g + 0.3, 0.7)
		_add_box_shape("wall", center, size, -yaw)
		# 외형 배치도 항상 계산(헤드리스 학습에서도 같은 난수 순서 + 리플레이 기록용)
		_visual("box", Transform3D(_yaw_basis(yaw, size), center), Color(0.6, 0.58, 0.54))


# --- 숲·나무

func _place_woods(rng: RandomNumberGenerator, i: int) -> void:
	for attempt in 12:
		var half := size_m * 0.5 - 60.0
		# 절반은 양 측면(우회로를 가리는 숲), 절반은 아무 곳
		var x := rng.randf_range(size_m * 0.18, half) * (1.0 if rng.randf() < 0.5 else -1.0) if i % 2 == 0 else rng.randf_range(-half, half)
		var c := Vector2(x, rng.randf_range(-half * 0.8, half * 0.8))
		var r := rng.randf_range(35.0, 75.0)
		if _in_spawn_zone(c, r) or not _is_free(c, r * 0.6):
			continue
		_add_woods(c, r, rng)
		return


## 숲 하나: 관목층+수관 시야 볼륨(원기둥 여러 개로 불규칙 윤곽) + 나무 줄기 충돌체
func add_woods(c: Vector2, r: float, rng_seed := 0) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = rng_seed
	_ensure_foliage_area()
	_add_woods(c, r, rng)
	if visuals_enabled:
		_flush_multimeshes()


func _add_woods(c: Vector2, r: float, rng: RandomNumberGenerator) -> void:
	var blobs := [[c, r]]
	for k in rng.randi_range(1, 3):
		var off := Vector2.from_angle(rng.randf() * TAU) * r * rng.randf_range(0.4, 0.8)
		blobs.append([c + off, r * rng.randf_range(0.45, 0.75)])
	var canopy := 11.0
	for bl in blobs:
		var bc: Vector2 = bl[0]
		var br: float = bl[1]
		var gmin := INF
		var gmax := -INF
		for a in 8:
			var q := bc + Vector2.from_angle(a * TAU / 8.0) * br
			var hq := height_at(q.x, q.y)
			gmin = minf(gmin, hq)
			gmax = maxf(gmax, hq)
		var hc := height_at(bc.x, bc.y)
		gmin = minf(gmin, hc)
		gmax = maxf(gmax, hc)
		_add_vision_cyl("woods", bc, br, gmin - 0.5, gmax + canopy, DENSITY_WOODS)
	obstacles.append({"type": "woods", "pos": _v3(c), "radius": r, "blobs": blobs.map(func(b): return [_v3(b[0]), b[1]])})
	# 나무: 지터 격자(간격 7m)로 블롭 내부에 배치
	var spacing := 8.0
	var ext := r * 1.8
	var gx := -ext
	while gx <= ext:
		var gz := -ext
		while gz <= ext:
			var p := c + Vector2(gx, gz) + Vector2(rng.randf_range(-2.5, 2.5), rng.randf_range(-2.5, 2.5))
			gz += spacing
			var inside := false
			for bl in blobs:
				if p.distance_to(bl[0]) < bl[1] - 1.5:
					inside = true
					break
			if not inside or not _is_free(p, 1.0):
				continue
			_add_tree_body(p, rng.randf_range(9.0, 14.0), rng.randf_range(0.25, 0.4), rng.randf_range(2.5, 3.8), rng, false)
			if rng.randf() < 0.6:
				var bs := rng.randf_range(1.5, 3.0)
				var q := p + Vector2(rng.randf_range(-3, 3), rng.randf_range(-3, 3))
				_visual("shrub", Transform3D(Basis().scaled(Vector3(bs * 1.4, bs, bs * 1.4)),
					Vector3(q.x, height_at(q.x, q.y) + bs * 0.35, q.y)), Color(0.22, 0.34, 0.15).darkened(rng.randf() * 0.2))
		gx += spacing


func _place_tree_line(rng: RandomNumberGenerator, ridge: Dictionary) -> void:
	# 능선 마루를 따라 120~250m 나무 띠
	var length := rng.randf_range(120.0, 250.0)
	var x0 := rng.randf_range(-size_m * 0.4, size_m * 0.4 - length)
	var step := 15.0
	var x := x0
	obstacles.append({"type": "treeline", "pos": Vector3(x0 + length * 0.5, 0, ridge_crest_z(ridge, x0 + length * 0.5)),
		"radius": length * 0.5, "x0": x0, "x1": x0 + length})
	while x < x0 + length:
		var p0 := Vector2(x, ridge_crest_z(ridge, x))
		var p1 := Vector2(x + step, ridge_crest_z(ridge, x + step))
		var c := (p0 + p1) * 0.5
		x += step
		if not _is_free(c, 3.0):
			continue
		var g := minf(height_at(p0.x, p0.y), height_at(p1.x, p1.y))
		_add_vision_box("treeline", c, Vector2(step * 0.5, 3.5), (p1 - p0).angle(), g + 0.5, g + 12.0, DENSITY_TREELINE)
		for t in 3:
			var p := p0.lerp(p1, (t + rng.randf()) / 3.0) + Vector2(0, rng.randf_range(-2.0, 2.0))
			_add_tree_body(p, rng.randf_range(9.0, 13.0), rng.randf_range(0.25, 0.4), rng.randf_range(2.8, 3.6), rng, false)


func _add_lone_tree(p: Vector2, rng: RandomNumberGenerator) -> void:
	var h := rng.randf_range(7.0, 12.0)
	var crown_r := rng.randf_range(2.0, 3.5)
	_add_tree_body(p, h, rng.randf_range(0.25, 0.45), crown_r, rng, true)
	var g := height_at(p.x, p.y)
	_add_vision_cyl("crown", p, crown_r * 0.85, g + h * 0.4, g + h, DENSITY_CROWN)


func _add_tree_body(p: Vector2, h: float, trunk_r: float, crown_r: float, rng: RandomNumberGenerator, lone: bool) -> void:
	var g := height_at(p.x, p.y)
	_add_cyl_shape("tree", Vector3(p.x, g + h * 0.25, p.y), trunk_r, h * 0.5)
	if lone:
		obstacles.append({"type": "tree", "pos": Vector3(p.x, g, p.y), "radius": crown_r, "height": h})
	# 외형 배치도 항상 계산(헤드리스 학습에서도 같은 난수 순서 + 리플레이 기록용)
	_visual("trunk", Transform3D(Basis().scaled(Vector3(trunk_r, h * 0.5, trunk_r)), Vector3(p.x, g + h * 0.25, p.y)),
		Color(0.35, 0.25, 0.15))
	_visual("crown", Transform3D(Basis().scaled(Vector3(crown_r, h * 0.7, crown_r)), Vector3(p.x, g + h * 0.62, p.y)),
		Color(0.16, 0.31, 0.13).lightened(rng.randf() * 0.12))


func _add_rock(p: Vector2, rng: RandomNumberGenerator) -> void:
	var s := Vector3(rng.randf_range(2.0, 5.0), rng.randf_range(1.5, 3.2), rng.randf_range(2.0, 5.0))
	var g := height_at(p.x, p.y)
	var yaw := rng.randf() * TAU
	var center := Vector3(p.x, g + s.y * 0.35, p.y)
	_add_box_shape("rock", center, s, yaw)
	obstacles.append({"type": "rock", "pos": center, "radius": maxf(s.x, s.z) * 0.5})
	# 외형 배치도 항상 계산(헤드리스 학습에서도 같은 난수 순서 + 리플레이 기록용)
	_visual("box", Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(s), center), Color(0.5, 0.5, 0.48).darkened(rng.randf() * 0.2))


## 낮은 돌: 높이 0.3~0.75m → 전차마다 넘을 수 있는지가 다르다(티거 0.79 / T-34 0.73 / 셔먼 0.61)
func _add_stone(p: Vector2, rng: RandomNumberGenerator) -> void:
	add_stone(p, Vector3(rng.randf_range(0.8, 2.2), rng.randf_range(0.3, 0.75), rng.randf_range(0.8, 2.2)), rng.randf() * TAU,
		Color(0.52, 0.5, 0.47).darkened(rng.randf() * 0.2))


## 쓰러진 통나무: 지름 0.45~0.6m, 길이 4~9m → 모두 넘을 수 있지만 비스듬히 넘으면 크게 기운다
func _add_log(p: Vector2, rng: RandomNumberGenerator) -> void:
	var d := rng.randf_range(0.45, 0.6)
	add_log(p, rng.randf_range(4.0, 9.0), d, rng.randf() * TAU)


## 테스트·시나리오용: 지면 위 높이 size.y 의 낮은 돌(상자)
func add_stone(p: Vector2, size: Vector3, yaw := 0.0, col := Color(0.52, 0.5, 0.47)) -> void:
	var g := height_at(p.x, p.y)
	# 지면 경사에 묻히도록 아래로 0.3m 더 내려 둔다(윗면 = 지면 + size.y)
	var center := Vector3(p.x, g + (size.y - 0.3) * 0.5, p.y)
	var full := Vector3(size.x, size.y + 0.3, size.z)
	_add_box_shape("stone", center, full, yaw)
	obstacles.append({"type": "stone", "pos": Vector3(p.x, g, p.y), "radius": maxf(size.x, size.z) * 0.5, "height": size.y})
	_visual("box", Transform3D(Basis(Vector3.UP, yaw) * Basis.from_scale(full), center), col)


## 테스트·시나리오용: 길이 length, 지름 d 의 쓰러진 통나무(상자 근사), 방향 yaw(라디안, 2D 각도)
func add_log(p: Vector2, length: float, d: float, yaw := 0.0) -> void:
	var g := height_at(p.x, p.y)
	var center := Vector3(p.x, g + (d - 0.2) * 0.5, p.y)
	var size := Vector3(length, d + 0.2, d)
	_add_box_shape("log", center, size, -yaw)
	obstacles.append({"type": "log", "pos": Vector3(p.x, g, p.y), "radius": length * 0.5, "height": d,
		"a": _v3(p + Vector2(cos(yaw), sin(yaw)) * length * 0.5), "b": _v3(p - Vector2(cos(yaw), sin(yaw)) * length * 0.5)})
	_visual("box", Transform3D(_yaw_basis(yaw, size), center), Color(0.4, 0.3, 0.2))


## 테스트·시나리오용 공개 헬퍼(features_enabled=false 인 빈 맵에 하나씩 놓기)
func add_building(p: Vector2, size: Vector3, yaw := 0.0) -> void:
	var g := height_at(p.x, p.y)
	_add_box_shape("building", Vector3(p.x, g + size.y * 0.5, p.y), size, -yaw)
	obstacles.append({"type": "building", "pos": Vector3(p.x, g, p.y), "radius": Vector2(size.x, size.z).length() * 0.5,
		"size": size, "yaw": yaw, "height": size.y})


func add_wall(a: Vector2, b: Vector2) -> void:
	_add_wall_line(a, b)


func add_hedge(a: Vector2, b: Vector2) -> void:
	_ensure_foliage_area()
	var yaw := (b - a).angle()
	for s in _segments(a, b, 12.0):
		var p0: Vector2 = s[0]
		var p1: Vector2 = s[1]
		var c := (p0 + p1) * 0.5
		var len := p0.distance_to(p1)
		var g := height_at(c.x, c.y)
		_add_box_shape("hedge", Vector3(c.x, g + 0.45, c.y), Vector3(len + 0.4, 1.8, 2.2), -yaw)
		_add_vision_box("hedge", c, Vector2(len * 0.5 + 0.2, 1.3), yaw, g, g + 3.6, DENSITY_HEDGE)
	obstacles.append({"type": "hedge", "pos": _v3((a + b) * 0.5), "radius": a.distance_to(b) * 0.5, "a": _v3(a), "b": _v3(b)})


func _ensure_foliage_area() -> void:
	if _foliage_area != null:
		return
	_foliage_area = Area3D.new()
	_foliage_area.name = "Foliage"
	_foliage_area.collision_layer = LAYER_FOLIAGE
	_foliage_area.collision_mask = 0
	_foliage_area.monitoring = false
	_foliage_area.monitorable = false
	add_child(_foliage_area)


func _v3(p: Vector2) -> Vector3:
	return Vector3(p.x, height_at(p.x, p.y), p.y)


# ---------------------------------------------------------------- 외형(MultiMesh: 수천 개라도 노드 몇 개)

func _flush_multimeshes() -> void:
	var meshes := {
		"box": BoxMesh.new(),
		"roof": _roof_mesh(),
		"bush": BoxMesh.new(),
		"trunk": _cyl(1.0, 0.8, 1.0, 6),
		"crown": _cyl(0.0, 1.0, 1.0, 8),
		"shrub": SphereMesh.new(),
	}
	(meshes["shrub"] as SphereMesh).radial_segments = 8
	(meshes["shrub"] as SphereMesh).rings = 4
	(meshes["shrub"] as SphereMesh).radius = 0.5
	(meshes["shrub"] as SphereMesh).height = 1.0
	for key in _mm:
		var xs: Array = _mm[key]
		if xs.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = meshes[key]
		mm.instance_count = xs.size()
		for i in xs.size():
			mm.set_instance_transform(i, xs[i])
			mm.set_instance_color(i, _mm_col[key][i])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "MM_" + key
		mmi.multimesh = mm
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mmi.material_override = mat
		add_child(mmi)
	_mm.clear()
	_mm_col.clear()


func _cyl(top: float, bottom: float, h: float, seg: int) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = h
	m.radial_segments = seg
	m.rings = 1
	return m


func _roof_mesh() -> PrismMesh:
	# 용마루가 x 축을 따라가도록: PrismMesh 의 꼭짓점은 x 방향 → z 로 돌려 쓴다
	var m := PrismMesh.new()
	m.size = Vector3(1, 1, 1)
	return m


# ---------------------------------------------------------------- 리플레이 기록/재구성

## 리플레이 기록용: 지형 높이 격자 + 모든 배치(충돌체·시야 볼륨·외형)의 정확한 값 + 장애물 목록.
## 생성 알고리즘이 나중에 바뀌어도 이 기록만으로 같은 맵을 다시 만든다.
func to_record() -> Dictionary:
	var hs := []
	for v in _heights:
		hs.append(snappedf(v, 0.001))
	return {"generator": "HillMap", "seed": map_seed, "size_m": size_m, "cell_m": cell_m,
		"features_enabled": features_enabled, "spawn_points": _ser(spawn_points),
		"heights": hs, "obstacles": _ser(obstacles), "prims": _ser(_journal)}


## 기록에서 맵 재구성(리플레이 뷰어용). add_child 전에 부르면 _ready 에서 만든다.
func load_record(rec: Dictionary) -> void:
	_record = rec
	if is_inside_tree():
		_build_from_record()


func _build_from_record() -> void:
	_generated = true
	for ch in get_children():
		ch.free()
	_foliage_area = null
	obstacles.clear()
	vision_volumes.clear()
	_bodies.clear()
	_mm.clear()
	_mm_col.clear()
	_journal.clear()
	map_seed = int(_record.get("seed", map_seed))
	size_m = float(_record.size_m)
	cell_m = float(_record.cell_m)
	_heights = PackedFloat32Array(_record.heights)
	var n := int(size_m / cell_m)
	if visuals_enabled:
		_build_terrain_mesh(n, size_m * 0.5, _heights)
	_build_terrain_collision(n, _heights)
	_ensure_foliage_area()
	for e in _record.get("prims", []):
		match e[0]:
			"box": _add_box_shape(e[1], _v3a(e[2]), _v3a(e[3]), e[4])
			"cyl": _add_cyl_shape(e[1], _v3a(e[2]), e[3], e[4])
			"vcyl": _add_vision_cyl(e[1], _v2a(e[2]), e[3], e[4], e[5], e[6])
			"vbox": _add_vision_box(e[1], _v2a(e[2]), _v2a(e[3]), e[4], e[5], e[6], e[7])
			"vis": _visual(e[1], _xfa(e[2]), Color(e[3][0], e[3][1], e[3][2]))
	for o in _record.get("obstacles", []):
		var d: Dictionary = o.duplicate(true)
		d.pos = _v3a(o.pos)
		obstacles.append(d)
	if visuals_enabled:
		_flush_multimeshes()


## 기록된 격자에서 쌍선형 보간
func _grid_height(x: float, z: float) -> float:
	var n := int(size_m / cell_m)
	var fx := clampf((x + size_m * 0.5) / cell_m, 0.0, n - 0.0001)
	var fz := clampf((z + size_m * 0.5) / cell_m, 0.0, n - 0.0001)
	var ix := int(fx)
	var iz := int(fz)
	var w := n + 1
	var a := lerpf(_heights[iz * w + ix], _heights[iz * w + ix + 1], fx - ix)
	var b := lerpf(_heights[(iz + 1) * w + ix], _heights[(iz + 1) * w + ix + 1], fx - ix)
	return lerpf(a, b, fz - iz)


## JSON 으로 옮기기 쉬운 값으로 변환(Vector/Color/Transform → 숫자 배열)
static func _ser(v):
	match typeof(v):
		TYPE_VECTOR3:
			return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]
		TYPE_VECTOR2:
			return [snappedf(v.x, 0.001), snappedf(v.y, 0.001)]
		TYPE_COLOR:
			return [snappedf(v.r, 0.001), snappedf(v.g, 0.001), snappedf(v.b, 0.001)]
		TYPE_TRANSFORM3D:
			var b: Basis = v.basis
			var o: Vector3 = v.origin
			return [b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z, o.x, o.y, o.z].map(func(f): return snappedf(f, 0.0001))
		TYPE_FLOAT:
			return snappedf(v, 0.0001)
		TYPE_RECT2:
			return [v.position.x, v.position.y, v.size.x, v.size.y]
		TYPE_ARRAY:
			return v.map(func(x): return _ser(x))
		TYPE_DICTIONARY:
			var d := {}
			for k in v:
				d[k] = _ser(v[k])
			return d
	if v is Array:  # Packed 배열·타입 배열
		return Array(v).map(func(x): return _ser(x))
	return v


static func _v3a(a) -> Vector3:
	return Vector3(a[0], a[1], a[2])


static func _v2a(a) -> Vector2:
	return Vector2(a[0], a[1])


static func _xfa(a) -> Transform3D:
	return Transform3D(Basis(Vector3(a[0], a[1], a[2]), Vector3(a[3], a[4], a[5]), Vector3(a[6], a[7], a[8])), Vector3(a[9], a[10], a[11]))

