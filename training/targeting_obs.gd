class_name TargetingObs
extends RefCounted
## 새 전투 정책 전용 부위 관측. 내부 손상·정확한 거리·관통 정답은 제공하지 않는다.
## 실제 외부 장갑면에서 보이는 점만 투영한다. 화면 밖/가려진 점은 전부 0.

const VERSION := 1
const POINTS := ["hull_upper", "hull_lower", "turret", "mantlet", "barrel", "track_left", "track_right"]
const FIELDS := ["visible", "screen_x", "screen_y", "gun_err_x", "gun_err_y", "facing"]


static func labels() -> Array:
	var out := []
	for i in TankPerception.ENEMY_SLOTS:
		for point in POINTS:
			for field in FIELDS:
				out.append("aim%d.%s.%s" % [i, point, field])
	return out


static func size() -> int:
	return TankPerception.ENEMY_SLOTS * POINTS.size() * FIELDS.size()


static func _group(part: String, zone: String) -> String:
	if part.begins_with("track_"):
		return part
	if part == "gun_barrel":
		return "barrel"
	if part == "mantlet":
		return "mantlet"
	if part == "turret" and zone != "turret_top":
		return "turret"
	if part == "hull":
		if zone in ["hull_front_lower", "hull_side_lower"]:
			return "hull_lower"
		if zone in ["hull_front_upper", "hull_side_upper", "hull_rear"]:
			return "hull_upper"
	return ""


static func compute(map: HillMap, observer: Tank, perception: TankPerception, tanks: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(size())
	var contacts := perception.sorted_contacts(true)
	var view := perception.view
	var eye := view.sensor_position(observer)
	var camera := view.eye_transform(observer, map)
	var gun_basis := Basis.looking_at(observer.gun_direction(), Vector3.UP).inverse()
	for slot in mini(contacts.size(), TankPerception.ENEMY_SLOTS):
		var contact: Dictionary = contacts[slot]
		if not contact.visible_now or contact.knocked_out or float(contact.size_px) < perception.identify_px:
			continue
		var target: Tank = null
		for candidate in tanks:
			if str(candidate.name) == str(contact.get("target_name", "")):
				target = candidate
				break
		if target == null:
			continue
		var shape := target.spec.shape()
		var target_inverse := target.global_transform.affine_inverse()
		var local_eye := target_inverse * eye
		var best := {}
		for part in shape.parts:
			var frame := shape.frame_transform(str(part.frame), target.turret_yaw, target.gun_pitch)
			for face in part.faces:
				var group := _group(str(part.name), str(face.zone))
				if group == "":
					continue
				var center := Vector3.ZERO
				for vertex in face.points:
					center += vertex / float(face.points.size())
				# 포탑 정면 중앙의 포방패가 볼을 가리는 경우도 검사한다.
				var samples := [center]
				if group == "turret":
					for vertex in face.points:
						samples.append(center.lerp(vertex, 0.6))
				for sample in samples:
					var local: Vector3 = frame * sample
					var world: Vector3 = target.global_transform * local
					var normal: Vector3 = (target.global_basis * frame.basis * face.normal).normalized()
					var facing := normal.dot((eye - world).normalized())
					if facing <= float(best.get(group, {}).get("facing", 0.05)):
						continue
					var screen = TankView.screen_point(camera, view.fov(), world)
					if not view.on_screen(screen):
						continue
					var direction := (local - local_eye).normalized()
					var first := shape.trace(target.turret_yaw, target.gun_pitch, local_eye, direction)
					if not first.hit or first.part != part.name or absf(float(first.t) - local_eye.distance_to(local)) > 0.15:
						continue
					var sight := LineOfSight.ray(map, eye, world, [observer.get_rid(), target.get_rid()])
					if float(sight.transmittance) < LineOfSight.POINT_VISIBLE:
						continue
					var gun_local: Vector3 = gun_basis * (world - observer.muzzle_position()).normalized()
					if gun_local.z >= 0:
						continue
					best[group] = {"facing": facing, "screen": screen,
						"x": clampf(atan2(gun_local.x, -gun_local.z) * 20.0, -1, 1),
						"y": clampf(atan2(gun_local.y, -gun_local.z) * 20.0, -1, 1)}
		for index in POINTS.size():
			if not best.has(POINTS[index]):
				continue
			var point: Dictionary = best[POINTS[index]]
			var offset := (slot * POINTS.size() + index) * FIELDS.size()
			var values := [1.0, point.screen.x / TankView.ASPECT, point.screen.y, point.x, point.y, point.facing]
			for field in FIELDS.size():
				out[offset + field] = float(values[field])
	return out
