class_name LineOfSight
extends RefCounted
## 전차 시야·탐지 판정. AI 관측 벡터와 HUD 가 같은 함수를 쓴다(사람과 AI 가 보는 정보가 같도록).
##
## 1) 관측자 눈(전차장 큐폴라 높이)에서 표적 전차의 표본점 6곳(포탑 위·포탑 중앙·차체 앞/뒤/좌/우)으로 선을 긋는다.
## 2) 각 선마다
##    - 물리 레이캐스트(레이어 1 = 지형·바위·건물·흙둑·돌담·나무줄기, 레이어 2 = 다른 전차)에 걸리면 0 (완전 차단)
##    - 아니면 HillMap.vision_volumes(숲·덤불·수목선·수관)를 통과한 거리로 투과율 exp(-Σ 밀도×거리)
## 3) visible_fraction = 표본점 투과율 평균 (0~1).  능선 뒤 hull-down 이면 차체 점은 0, 포탑 점만 남아 ~0.3.
## 4) 탐지: 유효 탐지거리 = BASE_DETECT_RANGE × 표적 크기 × 표적 이동 × 관측자 요인.
##    visible_fraction ≥ MIN_FRACTION 이고 거리 ≤ 유효 탐지거리 × visible_fraction 이면 탐지.
##    (반쯤 가려진 전차는 절반 거리까지 다가가야 찾는다)

const RAY_MASK := 1 | 2
const BASE_DETECT_RANGE := 1400.0
const MIN_FRACTION := 0.12
## 표본점별 투과율이 이 이상이면 "보이는 점"으로 센다(보고서·HUD 용)
const POINT_VISIBLE := 0.3


## 전차장 눈 위치(전역 좌표)
static func eye_position(t: Tank) -> Vector3:
	return t.global_transform * Vector3(0.0, t.spec.total_height() + 0.25, t.spec.turret_offset_z)


## 표적 표본점(전역 좌표) 6개: 포탑 위, 포탑 중앙, 차체 앞·뒤·좌·우 (차체 중앙 높이)
static func sample_points(t: Tank) -> Array:
	var s := t.spec
	var hy := s.hull_bottom_y + s.hull_size.y * 0.55
	var hx := s.hull_size.x * 0.42
	var hz := s.hull_size.z * 0.42
	var ty := s.hull_top_y()
	var xf := t.global_transform
	return [
		xf * Vector3(0.0, ty + s.turret_size.y * 0.9, s.turret_offset_z),
		xf * Vector3(0.0, ty + s.turret_size.y * 0.45, s.turret_offset_z),
		xf * Vector3(0.0, hy, -hz),
		xf * Vector3(0.0, hy, hz),
		xf * Vector3(-hx, hy, 0.0),
		xf * Vector3(hx, hy, 0.0),
	]


## 두 점 사이 시선. exclude: 무시할 RID 목록(관측자·표적 자신)
## 반환 {"transmittance": 0~1, "blocked_by": ""/"terrain"/"rock"/"building"/"hedge"/"wall"/"tree"/"tank"/"foliage:<종류>"}
static func ray(map: HillMap, from: Vector3, to: Vector3, exclude: Array = []) -> Dictionary:
	var space := map.get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to, RAY_MASK, exclude)
	var hit := space.intersect_ray(q)
	if not hit.is_empty():
		var col: Object = hit.collider
		var kind := "tank" if col is Tank else str(col.get_meta("kind", "obstacle")) if col else "obstacle"
		return {"transmittance": 0.0, "blocked_by": kind}
	var f := foliage(map, from, to)
	return {"transmittance": f.transmittance, "blocked_by": ("foliage:" + f.main) if f.transmittance < POINT_VISIBLE else ""}


## 잎 볼륨만으로 본 투과율(물리 쿼리 없이 해석적으로 계산; 학습 중 대량 호출용)
## 반환 {"transmittance", "optical_depth", "main": 가장 많이 가린 볼륨 종류}
static func foliage(map: HillMap, from: Vector3, to: Vector3) -> Dictionary:
	var a := Vector2(from.x, from.z)
	var b := Vector2(to.x, to.z)
	var seg_len := from.distance_to(to)
	var bb := Rect2(a, Vector2.ZERO).expand(b)
	var depth := 0.0
	var main := ""
	var main_depth := 0.0
	for v in map.vision_volumes:
		if bool(v.get("destroyed", false)):
			continue
		if not bb.intersects(v.aabb, true):
			continue
		var iv: Vector2
		if v.kind == "cyl":
			iv = _seg_circle(a, b, v.c, v.r)
		else:
			iv = _seg_box(a, b, v.c, v.half, v.yaw)
		if iv.x >= iv.y:
			continue
		iv = _clip_y(iv, from.y, to.y, v.y0, v.y1)
		if iv.x >= iv.y:
			continue
		var intervals := [iv]
		for hole in map.foliage_clearings if v.type in ["woods", "treeline"] else []:
			var cut := _seg_circle(a, b, hole.c, float(hole.r))
			if cut.x >= cut.y:
				continue
			var remaining := []
			for piece in intervals:
				if cut.y <= piece.x or cut.x >= piece.y:
					remaining.append(piece)
				else:
					if cut.x > piece.x:
						remaining.append(Vector2(piece.x, cut.x))
					if cut.y < piece.y:
						remaining.append(Vector2(cut.y, piece.y))
			intervals = remaining
		var fraction := 0.0
		for piece in intervals:
			fraction += piece.y - piece.x
		var d: float = fraction * seg_len * v.density
		depth += d
		if d > main_depth:
			main_depth = d
			main = v.type
	return {"transmittance": exp(-depth), "optical_depth": depth, "main": main}


## 관측자 → 표적 가시성. eye = 보는 눈 위치(기본: 전차장 큐폴라. 포수 조준경이면 TankView.sensor_position)
static func target_visibility(map: HillMap, observer: Tank, target: Tank, eye := Vector3.INF) -> Dictionary:
	if eye == Vector3.INF:
		eye = eye_position(observer)
	var exclude := [observer.get_rid(), target.get_rid()]
	var total := 0.0
	var seen := 0
	var blockers := {}
	for p in sample_points(target):
		var r := ray(map, eye, p, exclude)
		total += r.transmittance
		if r.transmittance >= POINT_VISIBLE:
			seen += 1
		elif r.blocked_by != "":
			blockers[r.blocked_by] = blockers.get(r.blocked_by, 0) + 1
	return {"visible_fraction": total / 6.0, "points_visible": seen, "blocked_by": blockers,
		"distance": eye.distance_to(target.global_position)}


## 광학 배율 → 탐지거리 배수. 맨눈(x1) 1.0, 조준경 x3 ≈ 1.8, x6.7 ≈ 2.4, 쌍안경 x8.9 ≈ 2.6
static func optics_factor(magnification: float) -> float:
	return 1.0 + 0.5 * log(maxf(magnification, 1.0)) / log(2.0)


## 관측자가 표적을 탐지하는가. 반환에 target_visibility 결과 + detected, detect_range 포함
## eye: 보는 눈 위치(기본 큐폴라), optics: 광학 배율(TankView.magnification(), 기본 맨눈 x1)
static func spot(map: HillMap, observer: Tank, target: Tank, eye := Vector3.INF, optics := 1.0) -> Dictionary:
	var vis := target_visibility(map, observer, target, eye)
	var size_f := clampf(target.spec.total_height() / 2.7, 0.75, 1.25)
	var speed := Vector2(target.velocity.x, target.velocity.z).length()
	var motion_f := 1.0 + 0.5 * clampf(speed / 6.0, 0.0, 1.0)
	var obs_f := 1.0
	if observer.spec.commander_is_gunner:
		obs_f *= 0.8 # T-34/76: 전차장이 포수 겸임 → 상황인식 저하
	if not observer.damage.is_combat_effective():
		obs_f = 0.0
	var detect_range := BASE_DETECT_RANGE * size_f * motion_f * obs_f * optics_factor(optics)
	vis["detect_range"] = detect_range
	vis["detected"] = vis.visible_fraction >= MIN_FRACTION and vis.distance <= detect_range * vis.visible_fraction
	return vis


## observer 가 보는 모든 적(다른 팀) 목록. AI 관측·HUD·로그 공용
static func spotted_enemies(map: HillMap, observer: Tank, tanks: Array) -> Array:
	var out := []
	for t in tanks:
		if t == observer or t.team == observer.team:
			continue
		var s := spot(map, observer, t)
		s["target"] = t.name
		out.append(s)
	return out


# ---------------------------------------------------------------- 기하

## 선분 a→b 와 원(c, r)의 교차 구간 [t0, t1] (0~1). 교차 없으면 x >= y
static func _seg_circle(a: Vector2, b: Vector2, c: Vector2, r: float) -> Vector2:
	var d := b - a
	var f := a - c
	var A := d.dot(d)
	if A < 1e-9:
		return Vector2(0, 1) if f.length() <= r else Vector2(1, 0)
	var B := 2.0 * f.dot(d)
	var C := f.dot(f) - r * r
	var disc := B * B - 4.0 * A * C
	if disc <= 0.0:
		return Vector2(1, 0)
	var sq := sqrt(disc)
	return Vector2(maxf((-B - sq) / (2.0 * A), 0.0), minf((-B + sq) / (2.0 * A), 1.0))


## 선분 a→b 와 회전 상자(중심 c, 반폭 half, 각 yaw)의 교차 구간
static func _seg_box(a: Vector2, b: Vector2, c: Vector2, half: Vector2, yaw: float) -> Vector2:
	var la := (a - c).rotated(-yaw)
	var lb := (b - c).rotated(-yaw)
	var d := lb - la
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		var o: float = la[axis]
		var dd: float = d[axis]
		var h: float = half[axis]
		if absf(dd) < 1e-9:
			if absf(o) > h:
				return Vector2(1, 0)
			continue
		var ta := (-h - o) / dd
		var tb := (h - o) / dd
		if ta > tb:
			var tmp := ta
			ta = tb
			tb = tmp
		t0 = maxf(t0, ta)
		t1 = minf(t1, tb)
		if t0 >= t1:
			return Vector2(1, 0)
	return Vector2(t0, t1)


## 높이 범위 [y0, y1] 로 구간을 자른다(선분 높이는 ya→yb 선형)
static func _clip_y(iv: Vector2, ya: float, yb: float, y0: float, y1: float) -> Vector2:
	var dy := yb - ya
	if absf(dy) < 1e-6:
		return iv if ya >= y0 and ya <= y1 else Vector2(1, 0)
	var ta := (y0 - ya) / dy
	var tb := (y1 - ya) / dy
	if ta > tb:
		var tmp := ta
		ta = tb
		tb = tmp
	return Vector2(maxf(iv.x, ta), minf(iv.y, tb))
