class_name TrainingProjectileField
extends RefCounted
## Opt-in, tick-based ballistics for under-fire lessons. Legacy battles keep their original resolver.
## Collision uses the current target pose; damage is never precomputed at launch.

const VERSION := 1
var owner_env: WeakRef
var active: Array = []
var near_passes := {}
var launched := 0
var resolved := 0
var time := 0.0


func _init(env) -> void:
	owner_env = weakref(env)


func launch(shooter: Tank, origin: Vector3, direction: Vector3, shell: GunSpec, result: Dictionary) -> void:
	var random := RandomNumberGenerator.new()
	random.seed = shooter.rng.randi()
	var env = owner_env.get_ref()
	var visible_targets: Variant = null
	if bool(env.config.get("reward", {}).get("near_miss_visible_pass_only", false)):
		visible_targets = {}
		var observer: TankAgent = env.agents[env.tanks.find(shooter)]
		for contact in observer.perception.contacts.values():
			if contact.enemy and contact.visible_now and not contact.knocked_out:
				visible_targets[contact.target_name] = true
	active.append({"id": launched, "shooter": weakref(shooter), "pos": origin, "previous": origin,
		"velocity": direction * shell.muzzle_velocity_ms, "shell": shell, "result": result.duplicate(true),
		"distance": 0.0, "age": 0.0, "rng": random, "near": {}, "visible_targets": visible_targets})
	launched += 1
	env.sounds.add(SoundField.GUNFIRE, origin, str(shooter.name))


func step(dt: float) -> void:
	time += dt
	var env = owner_env.get_ref()
	if env == null:
		return
	var survivors := []
	for projectile in active:
		var shooter: Tank = projectile.shooter.get_ref()
		if not is_instance_valid(shooter):
			continue
		var p: Vector3 = projectile.pos
		var velocity: Vector3 = projectile.velocity
		var end := p + velocity * dt + Vector3.DOWN * (0.5 * Tank.GRAVITY * dt * dt)
		var segment := end - p
		var length := segment.length()
		var direction := segment / maxf(length, 0.000001)
		var best_distance := length
		var collision := {}
		var space = env.map.get_world_3d().direct_space_state
		var query := PhysicsRayQueryParameters3D.create(p, end, Tank.LAYER_GROUND, [shooter.get_rid()])
		query.hit_from_inside = true
		var ground: Dictionary = space.intersect_ray(query)
		if not ground.is_empty():
			best_distance = p.distance_to(ground.position)
			collision = {"blocked_by": str(ground.collider.name), "position": ground.position,
				"collider": ground.collider, "shape": ground.shape}
		for target in env.tanks:
			if target == shooter:
				continue
			var center: Vector3 = target.global_position + Vector3.UP * 1.2
			if Geometry3D.get_closest_point_to_segment(center, p, end).distance_to(center) > 8:
				continue
			var inverse: Transform3D = target.global_transform.affine_inverse()
			var origin: Vector3 = inverse * p
			var local_dir: Vector3 = (inverse.basis * direction).normalized()
			var hit := HitGeometry.trace(target.spec, target.turret_yaw, origin, local_dir, target.gun_pitch)
			if hit.hit and float(hit.t) <= best_distance:
				best_distance = hit.t
				collision = {"tank": target, "local_origin": origin, "local_dir": local_dir,
					"position": p + direction * best_distance}
		var visible_end := p + direction * best_distance
		for target in env.tanks:
			if target.team == shooter.team or not target.damage.is_combat_effective():
				continue
			var center: Vector3 = target.global_position + Vector3.UP * target.spec.hull_top_y() * 0.6
			var visible_targets = projectile.visible_targets
			if visible_targets != null:
				var along := (center - p).dot(direction)
				# Reject a shell that stops short even if its impact is close to the target.
				if not visible_targets.has(str(target.name)) or along < 0.0 or along > best_distance:
					continue
			var closest := Geometry3D.get_closest_point_to_segment(center, p, visible_end)
			var miss := closest.distance_to(center)
			if miss > 12 or miss >= float(projectile.near.get("miss_distance_m", INF)):
				continue
			var q := PhysicsRayQueryParameters3D.create(closest, center, Tank.LAYER_GROUND, [shooter.get_rid(), target.get_rid()])
			q.hit_from_inside = true
			if not space.intersect_ray(q).is_empty():
				continue
			projectile.near = {"target_name": str(target.name), "target_team": target.team,
				"miss_distance_m": miss, "point": TankSpec._v(closest),
				"local_point": TankSpec._v(target.global_transform.affine_inverse() * closest), "sample_time_s": time,
				"range_m": float(projectile.distance) + p.distance_to(closest),
				"penetration_ratio": _near_penetration_ratio(target, p, center, projectile)}
			if visible_targets != null:
				projectile.near["visible_pass"] = true
			near_passes[str(target.name)] = {"time": time, "position": closest}
		projectile.previous = p
		projectile.pos = end
		projectile.velocity = velocity + Vector3.DOWN * Tank.GRAVITY * dt
		projectile.distance += best_distance
		projectile.age += dt
		if not collision.is_empty() or projectile.distance >= Tank.MAX_SHOT_RANGE or end.y < -200:
			_resolve(shooter, projectile, collision)
		else:
			survivors.append(projectile)
	active = survivors


func _near_penetration_ratio(target: Tank, origin: Vector3, center: Vector3, projectile: Dictionary) -> float:
	var inverse := target.global_transform.affine_inverse()
	var direction := (center - origin).normalized()
	var hit := HitGeometry.trace(target.spec, target.turret_yaw, inverse * origin,
		(inverse.basis * direction).normalized(), target.gun_pitch)
	if not hit.hit:
		return 0.0
	var shell: GunSpec = projectile.shell
	var plate := float(target.spec.plate(str(hit.zone)).t)
	if plate <= 0:
		return 1.0
	var effective := Ballistics.effective_thickness_mm(shell, plate, float(hit.impact_angle_deg))
	var range_m := float(projectile.distance) + origin.distance_to(center)
	return shell.penetration_mm(range_m) / maxf(effective, 1.0)


func _resolve(shooter: Tank, projectile: Dictionary, collision: Dictionary) -> void:
	var result: Dictionary = projectile.result.duplicate(true)
	var shell: GunSpec = projectile.shell
	if collision.has("tank"):
		var target: Tank = collision.tank
		var was_alive := target.damage.is_combat_effective()
		var env = owner_env.get_ref()
		var hit: Dictionary
		if bool(env.config.get("scenario", {}).get("practice_rounds", false)):
			hit = {"hit": true, "penetrated": false, "ricochet": false, "zone": "practice",
				"distance": projectile.distance, "events": ["practice_hit"]}
		else:
			hit = DamageModel.resolve_shot(target.damage, target.turret_yaw, collision.local_origin,
				collision.local_dir, projectile.distance, shell, projectile.rng, target.gun_pitch)
		hit.merge(result, false)
		hit["target_name"] = str(target.name)
		if not hit.has("entry_local"):
			hit["entry_local"] = TankSpec._v(target.global_transform.affine_inverse() * collision.position)
		hit["ray_origin_local"] = TankSpec._v(collision.local_origin)
		hit["ray_dir_local"] = TankSpec._v(collision.local_dir)
		hit["distance_m"] = snappedf(float(projectile.distance), 0.1)
		hit["target_team"] = target.team
		hit["target_was_combat_effective"] = was_alive
		result = hit
	elif collision.has("blocked_by"):
		result["blocked_by"] = collision.blocked_by
		var collider: Object = collision.collider
		var map = collider.get_meta("hill_map") if collider.has_meta("hill_map") else null
		if map != null:
			result["obstacle_damage"] = map.destruction.damage(collider, int(collision.shape),
				0.5 * shell.shell_mass_kg * shell.muzzle_velocity_ms * shell.muzzle_velocity_ms / 1000.0 + shell.filler_g * 2,
				"shell:" + str(shooter.name))
	else:
		result["blocked_by"] = "none"
	result["flight_time_s"] = snappedf(float(projectile.age), 0.001)
	result["projectile_version"] = VERSION
	result["hit_pos"] = TankSpec._v(collision.get("position", projectile.pos))
	if not projectile.near.is_empty():
		result["near_miss"] = projectile.near
	resolved += 1
	shooter.shot_fired.emit(shooter, result)


func summary() -> Dictionary:
	return {"version": VERSION, "launched": launched, "resolved": resolved, "in_flight": active.size()}


func snapshot() -> Array:
	var rows := []
	for projectile in active:
		rows.append({"id": projectile.id, "from": TankSpec._v(projectile.previous), "to": TankSpec._v(projectile.pos)})
	return rows
