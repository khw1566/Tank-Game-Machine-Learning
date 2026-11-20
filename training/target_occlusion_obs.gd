class_name TargetOcclusionObs
extends RefCounted
## Sample each currently detected enemy's silhouette from the active observation point.
## The two fractions share the same slot ordering as the enemy contacts.

const VERSION := 1
const FIELDS := ["hull_occluded", "turret_occluded"]
const GRID := [-0.34, 0.0, 0.34]


static func labels() -> Array:
	var out := []
	for slot in TankPerception.ENEMY_SLOTS:
		for field in FIELDS:
			out.append("cover%d.%s" % [slot, field])
	return out


static func size() -> int:
	return TankPerception.ENEMY_SLOTS * FIELDS.size()


static func part_occlusion(map: HillMap, eye: Vector3, pose: Transform3D, dimensions: Vector3, exclude: Array) -> float:
	var local_eye := pose.affine_inverse() * eye
	var facing := Vector3(local_eye.x, 0, local_eye.z).normalized()
	if facing.is_zero_approx():
		facing = Vector3.BACK
	var lateral := Vector3(facing.z, 0, -facing.x)
	var width := absf(lateral.x) * dimensions.x + absf(lateral.z) * dimensions.z
	var box := AABB(-dimensions * 0.5, dimensions)
	var visible := 0.0
	for y in GRID:
		for x in GRID:
			var sample := lateral * width * float(x) + Vector3.UP * dimensions.y * float(y)
			var surface = box.intersects_ray(sample + facing * dimensions.length(), -facing)
			if surface != null:
				visible += float(LineOfSight.ray(map, eye, pose * surface, exclude).transmittance)
	return clampf(1.0 - visible / float(GRID.size() * GRID.size()), 0.0, 1.0)


static func compute(map: HillMap, observer: Tank, perception: TankPerception, tanks: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(size())
	var contacts := perception.sorted_contacts(true)
	var eye := perception.view.sensor_position(observer)
	for slot in mini(contacts.size(), TankPerception.ENEMY_SLOTS):
		var contact: Dictionary = contacts[slot]
		if not contact.visible_now or contact.knocked_out:
			continue
		for target: Tank in tanks:
			if str(target.name) != contact.target_name:
				continue
			var spec := target.spec
			var exclude := [observer.get_rid(), target.get_rid()]
			var hull := target.global_transform.translated_local(Vector3.UP * (spec.hull_bottom_y + spec.hull_size.y * 0.5))
			var turret := target.global_transform * Transform3D(Basis(Vector3.UP, target.turret_yaw), spec.turret_origin() + Vector3.UP * spec.turret_size.y * 0.5)
			out[slot * 2] = part_occlusion(map, eye, hull, spec.hull_size, exclude)
			out[slot * 2 + 1] = part_occlusion(map, eye, turret, spec.turret_size, exclude)
			break
	return out
