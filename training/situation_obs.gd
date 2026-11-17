class_name SituationObs
extends RefCounted
## 커리큘럼 v4 의 목적 관측 블록(--obs=situation 일 때 기본 관측 뒤에 붙는다).
## 정답 정보는 쓰지 않는다: 노출 여부는 "내가 기억하는 적의 방향 + 보이는 크기로 어림한 거리"에서
## 나를 볼 수 있는지로 계산하고, 엄폐물은 내 주변 지형·장애물(승무원이 직접 보는 것)만 본다.
##
##   sit.known_enemies       기억 중인(격파 안 된) 적 수 / 4
##   sit.exposed_hull        그중 차체가 보이는 위치에 있을 적 수 / 4
##   sit.exposed_turret_only 포탑만 보이는(헐다운) 적 수 / 4
##   sit.exposed_any         한 대라도 나를 볼 수 있으면 1
##   sit.threat_*            가장 최근에 본 적의 방향(차체 기준). 차체 각도 판단(앵글링)에 쓴다
##   sit.hit_recent          내가 맞은 지 얼마나 됐나(exp(-초/3))
##   sit.incoming_recent     내 근처 탄착 소리(exp(-초/3))
##   sit.obj_*               목표 지점(있을 때) 방향·거리·도착 여부
##   cover_low/high k        차체 기준 8방위 60m 안 장애물까지 가까움(1 - 거리/60). low = 차체 중간 높이,
##                           high = 포탑 높이. low 만 막힘 = 헐다운 엄폐, 둘 다 막힘 = 완전 엄폐

const VERSION := 1
const COVER_RANGE := 60.0
const SECTORS := 8
const MAX_ENEMIES := 4.0
const BASE_LABELS := ["sit.known_enemies", "sit.exposed_hull", "sit.exposed_turret_only", "sit.exposed_any",
	"sit.threat_present", "sit.threat_sin", "sit.threat_cos", "sit.hit_recent", "sit.incoming_recent",
	"sit.obj_present", "sit.obj_dist", "sit.obj_sin", "sit.obj_cos", "sit.obj_inside"]


static func labels() -> Array:
	var out := BASE_LABELS.duplicate()
	for k in SECTORS:
		out.append("sit.cover_low%d" % k)
	for k in SECTORS:
		out.append("sit.cover_high%d" % k)
	return out


static func size() -> int:
	return BASE_LABELS.size() + SECTORS * 2


## 눈 위치 eye 에서 전차 t 의 차체·포탑이 보이는가 {hull, turret}
static func exposure_from(map: HillMap, eye: Vector3, t: Tank, exclude: Array) -> Dictionary:
	var pts := LineOfSight.sample_points(t)
	var turret := false
	var hull := false
	for i in pts.size():
		if (i < 2 and turret) or (i >= 2 and hull):
			continue
		var r := LineOfSight.ray(map, eye, pts[i], exclude)
		if float(r.transmittance) >= LineOfSight.POINT_VISIBLE:
			if i < 2:
				turret = true
			else:
				hull = true
	return {"hull": hull, "turret": turret}


static func compute(map: HillMap, t: Tank, p: TankPerception, objective: Vector3, obj_radius: float) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var hull_yaw := t.global_rotation.y
	var known := 0
	var exp_hull := 0
	var exp_turret := 0
	var newest: Dictionary = {}
	for c in p.contacts.values():
		if not c.enemy or c.knocked_out:
			continue
		known += 1
		if newest.is_empty() or float(c.t) > float(newest.t):
			newest = c
		var est := clampf(TankPerception.estimate_range(c), 20.0, 2500.0)
		var pos: Vector3 = c.seen_from + TankView.dir(float(c.world_yaw), float(c.elev)) * est
		var eye := Vector3(pos.x, map.height_at(pos.x, pos.z) + 2.6, pos.z)
		var e := exposure_from(map, eye, t, [t.get_rid()])
		if e.hull:
			exp_hull += 1
		elif e.turret:
			exp_turret += 1
	out.append(minf(known / MAX_ENEMIES, 1.0))
	out.append(minf(exp_hull / MAX_ENEMIES, 1.0))
	out.append(minf(exp_turret / MAX_ENEMIES, 1.0))
	out.append(1.0 if exp_hull + exp_turret > 0 else 0.0)
	if newest.is_empty():
		out.append_array(PackedFloat32Array([0.0, 0.0, 0.0]))
	else:
		var b := wrapf(float(newest.world_yaw) - hull_yaw, -PI, PI)
		out.append_array(PackedFloat32Array([1.0, sin(b), cos(b)]))
	var hit := 0.0
	var incoming := 0.0
	for s in p.last_sounds:
		if s.kind == SoundField.HIT_ME:
			hit = maxf(hit, exp(-float(s.age) / 3.0))
			incoming = maxf(incoming, exp(-float(s.age) / 3.0))
		elif s.kind == SoundField.IMPACT and float(s.loud) > 0.5:
			incoming = maxf(incoming, exp(-float(s.age) / 3.0))
	out.append(hit)
	out.append(incoming)
	if objective == Vector3.INF:
		out.append_array(PackedFloat32Array([0.0, 0.0, 0.0, 0.0, 0.0]))
	else:
		var d := objective - t.global_position
		var dist := Vector2(d.x, d.z).length()
		var b := wrapf(atan2(-d.x, -d.z) - hull_yaw, -PI, PI)
		out.append_array(PackedFloat32Array([1.0, clampf(dist / 300.0, 0.0, 2.0) * 0.5, sin(b), cos(b),
			1.0 if dist <= obj_radius else 0.0]))
	var low_h := t.spec.hull_top_y() * 0.6
	var high_h := t.spec.total_height() * 0.9
	var space := map.get_world_3d().direct_space_state
	var base := t.global_position
	var g := map.height_at(base.x, base.z)
	for h in [low_h, high_h]:
		for k in SECTORS:
			var a := hull_yaw + TAU * k / SECTORS
			var from := Vector3(base.x, g + h, base.z)
			var to := from + Vector3(-sin(a), 0.0, -cos(a)) * COVER_RANGE
			var q := PhysicsRayQueryParameters3D.create(from, to, 1, [t.get_rid()])
			var hit_r := space.intersect_ray(q)
			if hit_r.is_empty():
				out.append(0.0)
			else:
				out.append(snappedf(1.0 - from.distance_to(hit_r.position) / COVER_RANGE, 0.01))
	return out
