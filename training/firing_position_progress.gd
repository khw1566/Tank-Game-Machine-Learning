class_name FiringPositionProgress
extends RefCounted
## Reward-only local search. Never supplies a waypoint, target or action to the policy.
## Progress is paid only beyond the best distance so far, with a shared episode budget.

var env
var cfg: Dictionary
var states := {}

func _init(p_env, config: Dictionary) -> void:
	env = p_env
	cfg = config

static func origin(t: Tank, p: Vector3) -> Vector3:
	return p + Vector3.UP * (t.spec.hull_top_y() + t.spec.turret_size.y * 0.45)

func clear_fraction(t: Tank, enemy: Tank, p: Vector3) -> float:
	if p.distance_to(enemy.global_position) > Tank.MAX_SHOT_RANGE:
		return 0.0
	var pts := LineOfSight.sample_points(enemy)
	var clear := 0.0
	# Two aimable surfaces, not the commander's eye or the top of the cupola.
	for i in [1, 2]:
		var ray := LineOfSight.ray(env.map, origin(t, p), pts[i], [t.get_rid(), enemy.get_rid()])
		if float(ray.transmittance) >= LineOfSight.POINT_VISIBLE:
			clear += 0.5
	return clear

func _walkable(t: Tank, from: Vector3, to: Vector3) -> bool:
	var previous := from
	var width := t.spec.hull_width * 0.6
	var side := Vector3(to.z - from.z, 0, from.x - to.x).normalized() * width
	var steps := maxi(1, ceili(from.distance_to(to) / 4.0))
	for i in range(1, steps + 1):
		var p := from.lerp(to, float(i) / steps)
		p.y = env.map.height_at(p.x, p.z)
		var horizontal := Vector2(p.x - previous.x, p.z - previous.z).length()
		if absf(p.y - previous.y) > maxf(0.5, horizontal * 0.45):
			return false
		for offset in [Vector3.ZERO, side, -side]:
			var a: Vector3 = previous + offset + Vector3.UP
			var b: Vector3 = p + offset + Vector3.UP
			var q := PhysicsRayQueryParameters3D.create(a, b, LineOfSight.RAY_MASK, [t.get_rid()])
			if not env.map.get_world_3d().direct_space_state.intersect_ray(q).is_empty():
				return false
		previous = p
	return true

func _goal(t: Tank, enemy: Tank) -> Vector3:
	var here := t.global_position
	here.y = env.map.height_at(here.x, here.z)
	var goal := here
	var best := -INF
	var toward := Vector2(enemy.global_position.x - here.x, enemy.global_position.z - here.z)
	for radius in [12.0, 25.0, 50.0]:
		for i in 12:
			var a := toward.angle() + TAU * i / 12.0
			var p: Vector3 = here + Vector3(cos(a), 0, sin(a)) * float(radius)
			if absf(p.x) > 270 or absf(p.z) > 270:
				continue
			p.y = env.map.height_at(p.x, p.z)
			if not _walkable(t, here, p):
				continue
			var sight := clear_fraction(t, enemy, p)
			# Prefer a nearby clear shot. If none exists, seek a traversable approach.
			var score: float = 1000.0 * sight - p.distance_to(enemy.global_position) * 0.1 - float(radius)
			if score > best:
				best = score
				goal = p
	return goal

func step(t: Tank, now: float, dt: float) -> Array:
	var enemy: Tank = null
	var nearest := INF
	var sight := 0.0
	for other in env.tanks:
		if other.team == t.team or not other.damage.is_combat_effective():
			continue
		sight = maxf(sight, clear_fraction(t, other, t.global_position))
		var d := t.global_position.distance_to(other.global_position)
		if d < nearest:
			nearest = d
			enemy = other
	if enemy == null:
		return []
	if not states.has(t.name):
		states[t.name] = {"goal": t.global_position, "anchor": t.global_position, "best": 0.0,
			"paid": 0.0, "opened": false, "next_search": now, "hidden_s": 0.0,
			"has_goal": false, "was_blocked": false, "target_position": enemy.global_position}
	var s: Dictionary = states[t.name]
	var out := []
	if sight > 0:
		s.hidden_s = 0.0
		if s.was_blocked and not s.opened and t.global_position.distance_to(s.anchor) >= 5.0:
			s.opened = true
			out.append({"reason": "fireline_open", "value": float(cfg.get("open_bonus", 8.0))})
		return out
	s.hidden_s += dt
	s.was_blocked = true
	# Keep the goal fixed while approaching it. Replanning every few metres would
	# reset the distance high-water mark and pay the same back-and-forth movement.
	if not s.has_goal or (now >= float(s.next_search) and
		(t.global_position.distance_to(s.goal) < 3.0 or enemy.global_position.distance_to(s.target_position) > 25.0)):
		s.next_search = now + 8.0
		s.goal = _goal(t, enemy)
		s.best = t.global_position.distance_to(s.goal)
		s.has_goal = true
		s.target_position = enemy.global_position
	var remaining := t.global_position.distance_to(s.goal)
	var gain := maxf(0.0, float(s.best) - remaining)
	s.best = minf(float(s.best), remaining)
	var value := minf(gain * float(cfg.get("per_m", 0.4)), maxf(0, float(cfg.get("budget", 20.0)) - float(s.paid)))
	if value > 0:
		s.paid += value
		out.append({"reason": "fireline_progress", "value": value})
	if float(s.hidden_s) > float(cfg.get("stall_after_s", 10.0)):
		out.append({"reason": "fireline_stall", "value": -float(cfg.get("stall_per_s", 0.1)) * dt})
	var drive := maxf(absf(t.control.left_track), absf(t.control.right_track))
	if drive > 0.1 and t.control.brake > 0.1:
		out.append({"reason": "maneuver_conflict", "value": -0.2 * drive * t.control.brake * dt})
	return out
