class_name HitGeometry
extends RefCounted
## 탄 궤적(광선)이 차체/포탑 상자의 어느 면·어느 장갑구역에 맞았는지, 입사각이 얼마인지 계산.
## 물리엔진 없이 해석적으로 계산하므로 헤드리스 학습에서도 동일하게 동작한다.


## 광선-상자(AABB) 교차. 원점이 상자 밖이어야 함.
## 반환: {} (빗나감) 또는 {"t": 진입거리, "exit_t": 이탈거리, "normal": 진입면 법선(축 정렬)}
static func ray_box(origin: Vector3, dir: Vector3, bmin: Vector3, bmax: Vector3) -> Dictionary:
	var tmin := -INF
	var tmax := INF
	var normal := Vector3.ZERO
	for i in 3:
		var o: float = origin[i]
		var d: float = dir[i]
		if absf(d) < 1e-9:
			if o < bmin[i] or o > bmax[i]:
				return {}
			continue
		var t1: float = (bmin[i] - o) / d
		var t2: float = (bmax[i] - o) / d
		var n1 := Vector3.ZERO
		n1[i] = -1.0
		var n2 := Vector3.ZERO
		n2[i] = 1.0
		if t1 > t2:
			var tt := t1
			t1 = t2
			t2 = tt
			var nn := n1
			n1 = n2
			n2 = nn
		if t1 > tmin:
			tmin = t1
			normal = n1
		tmax = minf(tmax, t2)
		if tmin > tmax:
			return {}
	if tmin < 0.0:
		return {}
	return {"t": tmin, "exit_t": tmax, "normal": normal}


## 포탑 회전 기저(포탑 좌표 -> 차체 좌표). turret_yaw: 라디안, Godot 규약(+ = 위에서 볼 때 반시계 = 좌회전).
static func turret_basis(turret_yaw: float) -> Basis:
	return Basis(Vector3.UP, turret_yaw)


## 포탑 좌표계 위치를 차체 좌표로.
static func turret_to_hull(spec: TankSpec, turret_yaw: float, p: Vector3) -> Vector3:
	return spec.turret_origin() + turret_basis(turret_yaw) * p


## 상자 면 법선 + 경사 -> 실제 장갑판 법선. slope 는 수직으로부터의 각(+ = 윗부분이 안쪽으로 기움).
static func sloped_normal(face_normal: Vector3, slope_deg: float) -> Vector3:
	if absf(face_normal.y) > 0.5:
		return face_normal
	var s := deg_to_rad(slope_deg)
	return (face_normal * cos(s) + Vector3.UP * sin(s)).normalized()


## 전차 로컬 좌표의 광선으로 명중 구역을 판정.
## origin, dir: 전차 로컬 좌표(dir 은 정규화). 빗나가면 {"hit": false}.
## 반환 키: hit, part("hull"/"turret"), zone, entry(차체좌표), path_len(내부 통과길이),
##         plate_normal(차체좌표), impact_angle_deg
static func trace(spec: TankSpec, turret_yaw: float, origin: Vector3, dir: Vector3) -> Dictionary:
	dir = dir.normalized()
	var best := {"hit": false}
	var best_t := INF

	# 포탑(회전한 상자): 광선을 포탑 좌표로 옮겨 계산
	var tb := turret_basis(turret_yaw)
	var tb_inv := tb.inverse()
	var o_t := tb_inv * (origin - spec.turret_origin())
	var d_t := tb_inv * dir
	var th := ray_box(o_t, d_t, spec.turret_min(), spec.turret_max())
	if not th.is_empty():
		best_t = th.t
		var n: Vector3 = th.normal
		var zone := "turret_top"
		if n.z < -0.5:
			zone = "turret_front"
		elif n.z > 0.5:
			zone = "turret_rear"
		elif absf(n.x) > 0.5:
			zone = "turret_side"
		elif n.y < -0.5:
			zone = "turret_top" # 포탑 바닥면은 차체 상판 뒤에 가려지므로 사실상 발생 안 함
		var pl := spec.plate(zone)
		var pn := tb * sloped_normal(n, pl.slope)
		best = {"hit": true, "part": "turret", "zone": zone, "t": th.t,
			"entry": origin + dir * float(th.t),
			"path_len": float(th.exit_t) - float(th.t), "plate_normal": pn,
			"face_normal": tb * n}

	var hh := ray_box(origin, dir, spec.hull_min(), spec.hull_max())
	if not hh.is_empty() and float(hh.t) < best_t:
		var n: Vector3 = hh.normal
		var entry := origin + dir * float(hh.t)
		var zone := "hull_top"
		if n.z < -0.5:
			zone = "hull_front_lower" if entry.y < spec.front_lower_split_y else "hull_front_upper"
		elif n.z > 0.5:
			zone = "hull_rear"
		elif absf(n.x) > 0.5:
			zone = "hull_side_lower" if entry.y < spec.side_lower_split_y else "hull_side_upper"
		elif n.y < -0.5:
			zone = "hull_bottom"
		var pl := spec.plate(zone)
		best = {"hit": true, "part": "hull", "zone": zone, "t": hh.t, "entry": entry,
			"path_len": float(hh.exit_t) - float(hh.t),
			"plate_normal": sloped_normal(n, pl.slope), "face_normal": n}

	if best.hit:
		var pn: Vector3 = best.plate_normal
		var c := clampf(-dir.dot(pn), 0.0, 1.0)
		best["impact_angle_deg"] = rad_to_deg(acos(c))
	return best


## 사수 위치(월드)와 표적 Transform 으로 "표적 중심을 조준했을 때" 로컬 광선을 만든다.
## AI 관측(현재 각도에서 관통 가능성) 계산이나 테스트에 사용.
static func local_ray_to_point(target_xform: Transform3D, shooter_world: Vector3, aim_world: Vector3) -> Array:
	var inv := target_xform.affine_inverse()
	var o := inv * shooter_world
	var a := inv * aim_world
	return [o, (a - o).normalized()]
