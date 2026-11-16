class_name TankShape
extends RefCounted
## 전차 형상: 볼록 다면체 부품 여러 개(차체, 궤도 ×2, 포탑, 포방패, 포신).
## 각 부품은 평면(법선 n, 거리 d: n·p ≤ d 가 내부) 목록이고, 평면마다 장갑 구역(zone)이 붙는다.
## 광선 교차는 해석적으로 계산하므로 물리엔진 없이 헤드리스에서도 똑같이 동작한다.
##
## 부품 좌표계(frame):
##   "hull"   : 전차 로컬 그대로
##   "turret" : 포탑 링 중심(spec.turret_origin()) 기준, turret_yaw 만큼 Y 회전
##   "gun"    : 포탑 좌표계의 포이(trunnion) 기준, gun_pitch 만큼 X 회전 (포신만)

const EPS := 1e-6

## 제원에서 복사한 값(TankSpec ↔ TankShape 순환 참조를 피하려고 spec 자체는 보관하지 않는다)
var turret_origin: Vector3
var total_height: float
var max_extent: float
## [{"name", "frame", "planes": [{"n": Vector3, "d": float, "zone": String, "split_y"?: float, "zone_low"?: String}],
##   "verts": PackedVector3Array, "faces": [{"zone", "normal", "points": PackedVector3Array}]}]
var parts: Array = []
## 포이(trunnion) 위치(포탑 좌표계)
var trunnion: Vector3


func _init(p_spec: TankSpec) -> void:
	turret_origin = p_spec.turret_origin()
	total_height = p_spec.total_height()
	max_extent = maxf(p_spec.hull_length, p_spec.hull_width) * 0.5 + p_spec.barrel_length + 0.5
	_build(p_spec)


# ------------------------------------------------------------------ 생성
func _build(s: TankSpec) -> void:
	var L := s.hull_length * 0.5
	var W := s.hull_width * 0.5
	# 차체
	var hp := []
	hp.append(_pl(Vector3.DOWN, -s.hull_bottom_y, "hull_bottom"))
	hp.append(_pl(Vector3.UP, s.hull_top_y, "hull_top"))
	var a := deg_to_rad(s.front_upper_slope_deg)
	hp.append(_pl(Vector3(0, sin(a), -cos(a)), s.nose_y * sin(a) + L * cos(a), "hull_front_upper"))
	var b := deg_to_rad(s.front_lower_slope_deg)
	hp.append(_pl(Vector3(0, -sin(b), -cos(b)), -s.nose_y * sin(b) + L * cos(b), "hull_front_lower"))
	var r := deg_to_rad(s.rear_upper_slope_deg)
	hp.append(_pl(Vector3(0, sin(r), cos(r)), s.rear_y * sin(r) + L * cos(r), "hull_rear"))
	var r2 := deg_to_rad(s.rear_lower_slope_deg)
	hp.append(_pl(Vector3(0, -sin(r2), cos(r2)), -s.rear_y * sin(r2) + L * cos(r2), "hull_rear"))
	var ss := deg_to_rad(s.side_upper_slope_deg)
	for sx in [-1.0, 1.0]:
		if s.side_upper_slope_deg > 0.5:
			hp.append(_pl(Vector3(sx, 0, 0), W, "hull_side_lower"))
			hp.append(_pl(Vector3(sx * cos(ss), sin(ss), 0), W * cos(ss) + s.side_split_y * sin(ss), "hull_side_upper"))
		else:
			var p := _pl(Vector3(sx, 0, 0), W, "hull_side_upper")
			p["split_y"] = s.side_split_y
			p["zone_low"] = "hull_side_lower"
			hp.append(p)
	_add_part("hull", "hull", hp)

	# 궤도(차체 옆 하부를 덮는 상자, 바깥으로 3cm 튀어나옴)
	var tl := s.track_length * 0.5
	for side in ["left", "right"]:
		var sx := -1.0 if side == "left" else 1.0
		var x_in := W - s.track_width
		var x_out := W + 0.03
		var bmin := Vector3(minf(sx * x_in, sx * x_out), 0.0, -tl)
		var bmax := Vector3(maxf(sx * x_in, sx * x_out), s.track_height, tl)
		_add_part("track_" + side, "hull", _box_planes(bmin, bmax, "track"))

	# 포탑
	var tw := s.turret_width * 0.5
	var tln := s.turret_length * 0.5
	var tp := []
	tp.append(_pl(Vector3.DOWN, 0.0, "turret_top"))   # 바닥(차체에 가려짐)
	tp.append(_pl(Vector3.UP, s.turret_height, "turret_top"))
	var f := deg_to_rad(s.turret_front_slope_deg)
	tp.append(_pl(Vector3(0, sin(f), -cos(f)), tln * cos(f), "turret_front"))
	var rr := deg_to_rad(s.turret_rear_slope_deg)
	tp.append(_pl(Vector3(0, sin(rr), cos(rr)), tln * cos(rr), "turret_rear"))
	var ts := deg_to_rad(s.turret_side_slope_deg)
	for sx in [-1.0, 1.0]:
		tp.append(_pl(Vector3(sx * cos(ts), sin(ts), 0), tw * cos(ts), "turret_side"))
	_add_part("turret", "turret", tp)

	# 포방패: 포탑 정면판(포이 높이) 앞에 대부분 튀어나온 상자
	var gy := s.gun_height
	var zf := gy * tan(f) - tln
	var m := s.mantlet_size
	var mz := zf - m.z * 0.4
	trunnion = Vector3(0, gy, zf)
	_add_part("mantlet", "turret", _box_planes(Vector3(-m.x * 0.5, gy - m.y * 0.5, mz - m.z * 0.5),
		Vector3(m.x * 0.5, gy + m.y * 0.5, mz + m.z * 0.5), "mantlet"))

	# 포신: 포방패 앞면에서 barrel_length 만큼(포 좌표계, 포이 기준)
	var br := maxf(s.gun.caliber_mm * 0.001 * 1.1, 0.06) if s.gun else 0.08
	var z0 := (mz - m.z * 0.5) - zf
	_add_part("gun_barrel", "gun", _box_planes(Vector3(-br, -br, z0 - s.barrel_length), Vector3(br, br, z0 + 0.05), "gun_barrel"))


static func _pl(n: Vector3, d: float, zone: String) -> Dictionary:
	return {"n": n.normalized(), "d": d, "zone": zone}


static func _box_planes(bmin: Vector3, bmax: Vector3, zone: String) -> Array:
	return [
		_pl(Vector3.LEFT, -bmin.x, zone), _pl(Vector3.RIGHT, bmax.x, zone),
		_pl(Vector3.DOWN, -bmin.y, zone), _pl(Vector3.UP, bmax.y, zone),
		_pl(Vector3.FORWARD, -bmin.z, zone), _pl(Vector3.BACK, bmax.z, zone),
	]


func _add_part(p_name: String, frame: String, planes: Array) -> void:
	var verts := _vertices(planes)
	var faces := []
	for pl in planes:
		var pts := []
		for v in verts:
			if absf((pl.n as Vector3).dot(v) - float(pl.d)) < 1e-4:
				pts.append(v)
		if pts.size() < 3:
			continue
		pts = _sort_ccw(pts, pl.n)
		if pl.has("split_y"):
			# 높이로 나뉘는 면(수직 측면의 상·하부)은 두 다각형으로 자른다
			var lo := _clip_y(pts, pl.split_y, false)
			var hi := _clip_y(pts, pl.split_y, true)
			if lo.size() >= 3:
				faces.append({"zone": pl.zone_low, "normal": pl.n, "points": PackedVector3Array(lo)})
			if hi.size() >= 3:
				faces.append({"zone": pl.zone, "normal": pl.n, "points": PackedVector3Array(hi)})
		else:
			faces.append({"zone": pl.zone, "normal": pl.n, "points": PackedVector3Array(pts)})
	parts.append({"name": p_name, "frame": frame, "planes": planes, "verts": PackedVector3Array(verts), "faces": faces})


## 평면 3개씩 교점 → 모든 평면 안쪽에 있는 점만(볼록 다면체의 꼭짓점)
static func _vertices(planes: Array) -> Array:
	var out := []
	var n := planes.size()
	for i in n:
		for j in range(i + 1, n):
			for k in range(j + 1, n):
				var p = _intersect3(planes[i], planes[j], planes[k])
				if p == null:
					continue
				var inside := true
				for pl in planes:
					if (pl.n as Vector3).dot(p) - float(pl.d) > 1e-4:
						inside = false
						break
				if not inside:
					continue
				var dup := false
				for q in out:
					if (q as Vector3).distance_to(p) < 1e-4:
						dup = true
						break
				if not dup:
					out.append(p)
	return out


static func _intersect3(a: Dictionary, b: Dictionary, c: Dictionary):
	var n1: Vector3 = a.n
	var n2: Vector3 = b.n
	var n3: Vector3 = c.n
	var det := n1.dot(n2.cross(n3))
	if absf(det) < 1e-9:
		return null
	return (n2.cross(n3) * float(a.d) + n3.cross(n1) * float(b.d) + n1.cross(n2) * float(c.d)) / det


static func _sort_ccw(pts: Array, n: Vector3) -> Array:
	var c := Vector3.ZERO
	for p in pts:
		c += p
	c /= pts.size()
	var u: Vector3 = (pts[0] - c).normalized()
	var v := n.cross(u)
	var arr := pts.duplicate()
	arr.sort_custom(func(p, q):
		var dp: Vector3 = p - c
		var dq: Vector3 = q - c
		return atan2(dp.dot(v), dp.dot(u)) < atan2(dq.dot(v), dq.dot(u)))
	return arr


## 다각형을 y = h 로 잘라 위(keep_above) 또는 아래 부분만 남김
static func _clip_y(poly: Array, h: float, keep_above: bool) -> Array:
	var out := []
	var n := poly.size()
	for i in n:
		var p: Vector3 = poly[i]
		var q: Vector3 = poly[(i + 1) % n]
		var pin := (p.y >= h) == keep_above
		var qin := (q.y >= h) == keep_above
		if pin:
			out.append(p)
		if pin != qin and absf(q.y - p.y) > EPS:
			out.append(p.lerp(q, (h - p.y) / (q.y - p.y)))
	return out


# ------------------------------------------------------------------ 좌표계
## 부품 좌표 → 차체 좌표 변환
func frame_transform(frame: String, turret_yaw: float, gun_pitch: float) -> Transform3D:
	match frame:
		"turret":
			return Transform3D(Basis(Vector3.UP, turret_yaw), turret_origin)
		"gun":
			var t := Transform3D(Basis(Vector3.UP, turret_yaw), turret_origin)
			return t * Transform3D(Basis(Vector3.RIGHT, gun_pitch), trunnion)
	return Transform3D.IDENTITY


func get_part(p_name: String) -> Dictionary:
	for p in parts:
		if p.name == p_name:
			return p
	return {}


# ------------------------------------------------------------------ 광선 교차
## 광선-볼록다면체. 반환: {} 또는 {"t_enter", "t_exit", "plane"(진입 평면, 원점이 안이면 null)}
static func ray_convex(planes: Array, o: Vector3, d: Vector3) -> Dictionary:
	var t_enter := -INF
	var t_exit := INF
	var enter_pl = null
	for pl in planes:
		var n: Vector3 = pl.n
		var denom := n.dot(d)
		var dist := float(pl.d) - n.dot(o)
		if absf(denom) < 1e-9:
			if dist < 0.0:
				return {}
			continue
		var t := dist / denom
		if denom < 0.0:
			if t > t_enter:
				t_enter = t
				enter_pl = pl
		else:
			t_exit = minf(t_exit, t)
		if t_enter > t_exit:
			return {}
	if t_exit < 0.0:
		return {}
	if t_enter < 0.0:
		enter_pl = null
	return {"t_enter": t_enter, "t_exit": t_exit, "plane": enter_pl}


## 차체 좌표 광선이 처음 맞는 부품/구역.
## skip: 건너뛸 부품 이름 목록(예: 궤도를 지난 뒤 다시 추적할 때 ["track_left", "track_right"])
## 반환: {"hit": false} 또는 {"hit", "part", "zone", "t", "entry", "path_len", "plate_normal", "impact_angle_deg", "slope_deg"}
func trace(turret_yaw: float, gun_pitch: float, origin: Vector3, dir: Vector3, skip: Array = []) -> Dictionary:
	dir = dir.normalized()
	var best := {"hit": false}
	var best_t := INF
	for part in parts:
		if part.name in skip:
			continue
		var xf := frame_transform(part.frame, turret_yaw, gun_pitch)
		var inv := xf.affine_inverse()
		var o := inv * origin
		var d := inv.basis * dir
		var h := ray_convex(part.planes, o, d)
		if h.is_empty() or h.plane == null:
			continue
		var t: float = h.t_enter
		if t >= best_t:
			continue
		best_t = t
		var pl: Dictionary = h.plane
		var entry_local := o + d * t
		var zone: String = pl.zone
		if pl.has("split_y") and entry_local.y < float(pl.split_y):
			zone = pl.zone_low
		var n_hull := (xf.basis * (pl.n as Vector3)).normalized()
		best = {"hit": true, "part": part.name, "zone": zone, "t": t,
			"entry": origin + dir * t, "path_len": float(h.t_exit) - t,
			"plate_normal": n_hull}
	if best.hit:
		var n: Vector3 = best.plate_normal
		best["impact_angle_deg"] = rad_to_deg(acos(clampf(-dir.dot(n), 0.0, 1.0)))
		best["slope_deg"] = rad_to_deg(asin(clampf(n.y, -1.0, 1.0)))
	return best


## 점 p(차체 좌표)에서 dir 방향으로 차체·포탑 내부를 빠져나갈 때까지의 거리(최댓값). 관통 후 파편 경로 길이.
func interior_length(turret_yaw: float, p: Vector3, dir: Vector3) -> float:
	var best := 0.0
	for pname in ["hull", "turret"]:
		var part := get_part(pname)
		var xf := frame_transform(part.frame, turret_yaw, 0.0)
		var inv := xf.affine_inverse()
		var h := ray_convex(part.planes, inv * (p + dir * 0.001), inv.basis * dir)
		if not h.is_empty():
			best = maxf(best, float(h.t_exit))
	return best


## 방향 view_dir(차체 좌표, 표적을 바라보는 방향의 반대 = 사수 쪽)에서 본 실루엣 면적(m²). 격자 표본.
func projected_area(toward_shooter: Vector3, turret_yaw := 0.0, cell := 0.05) -> float:
	var d := -toward_shooter.normalized()
	var up := Vector3.UP if absf(d.y) < 0.9 else Vector3.FORWARD
	var right := d.cross(up).normalized()
	up = right.cross(d).normalized()
	var center := Vector3(0, total_height * 0.5, 0)
	var half := max_extent
	var hits := 0
	var n := int(half * 2.0 / cell)
	for i in n:
		for j in n:
			var off := right * (-half + (i + 0.5) * cell) + up * (-half + (j + 0.5) * cell)
			if off.dot(up) + center.y < 0.0:
				continue # 지면 아래
			var o := center + off - d * 30.0
			if trace(turret_yaw, 0.0, o, d, ["gun_barrel"]).hit:
				hits += 1
	return hits * cell * cell
