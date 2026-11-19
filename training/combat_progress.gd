class_name CombatProgress
extends RefCounted
## Bounded learning signals for an unresolved fight. Outcome rewards remain dominant.

var weights: Dictionary
var pressure := {}
var pen_best := {}
var miss_best := {}
var pen_paid := {}
var miss_paid := {}
var aim_best := {}
var attack_paid := {}


func _init(config: Dictionary) -> void:
	weights = config


func _state(name: String) -> Dictionary:
	if not pressure.has(name):
		pressure[name] = {"failures": 0, "last_progress": 0.0}
	return pressure[name]


func pressure_active(name: String, now: float) -> bool:
	var state := _state(name)
	return int(state.failures) >= int(weights.get("close_after_failures", 2)) \
		or now - float(state.last_progress) >= float(weights.get("close_after_stall_s", 20.0))


func shot(name: String, target: String, result: Dictionary, now: float) -> Array:
	var state := _state(name)
	var meaningful := bool(result.get("penetrated", false))
	for damage in result.get("damage", []):
		meaningful = meaningful or damage.get("before", "") != damage.get("after", "")
	if meaningful:
		state.last_progress = now
		state.failures = 0
		return []
	state.failures += 1
	if not result.get("hit", false):
		return []
	var armor := float(result.get("effective_mm", 0.0))
	var penetration := float(result.get("pen_mean_mm", 0.0))
	if armor <= 0 or penetration <= 0:
		return []
	var ratio := penetration / armor
	if ratio > 1.1:
		return []  # A random bounce from an otherwise overpowered gun is not a range problem.
	var quality := clampf((ratio - 0.65) / 0.35, 0, 1)
	var key := name + ":" + target
	var improvement := maxf(0, quality - float(pen_best.get(key, 0.0)))
	pen_best[key] = maxf(quality, float(pen_best.get(key, 0.0)))
	var reward := minf(improvement * float(weights.get("near_pen_bonus", 2.0)),
		maxf(0, float(weights.get("near_pen_budget", 4.0)) - float(pen_paid.get(name, 0.0))))
	pen_paid[name] = float(pen_paid.get(name, 0.0)) + reward
	return [{"reason": "near_penetration", "value": reward}] if reward > 0 else []


func near_miss(name: String, near: Dictionary) -> float:
	var distance := float(near.get("range_m", 0.0))
	if distance < 20 or str(near.get("target_name", "")) == "":
		return 0.0
	var radius := float(weights.get("near_miss_radius_m", 4.0))
	var attack := int(weights.get("attack_shaping_version", 0)) > 0
	if attack:
		radius = clampf(distance * float(weights.get("near_miss_radius_ratio", 0.03)), radius,
			float(weights.get("near_miss_max_radius_m", 12.0)))
	var aim := clampf(1.0 - float(near.get("miss_distance_m", radius)) / radius, 0, 1)
	# The hypothetical armor ray is reward-only; it never enters policy observations.
	var ratio := maxf(0, float(near.get("penetration_ratio", 0.0)))
	var armor_quality := clampf((ratio - 0.5) / 0.5, 0, 1)
	if attack:
		armor_quality = lerpf(0.25, 1.0, armor_quality)
	var quality := aim * armor_quality
	var key := name + ":" + str(near.target_name)
	var improvement := maxf(0, quality - float(miss_best.get(key, 0.0)))
	miss_best[key] = maxf(quality, float(miss_best.get(key, 0.0)))
	var reward := minf((quality if attack else improvement) * float(weights.get("near_miss_bonus", 2.0)),
		maxf(0, float(weights.get("near_miss_budget", 3.0)) - float(miss_paid.get(name, 0.0))))
	miss_paid[name] = float(miss_paid.get(name, 0.0)) + reward
	return reward


## Reward-only ballistic aim error. Radius is the target's projected half-size.
func aim_quality(direction: Vector3, offset: Vector3, radius: float) -> Dictionary:
	if offset.length_squared() < 0.01 or direction.dot(offset) <= 0:
		return {"alignment": 0.0, "overlap": 0.0}
	var angle := direction.angle_to(offset.normalized())
	return {"alignment": clampf(1.0 - angle / deg_to_rad(float(weights.get("aim_cone_deg", 30.0))), 0, 1),
		"overlap": clampf(1.0 - direction.cross(offset).length() / maxf(radius, 0.1), 0, 1)}


func _attack_pay(name: String, reason: String, value: float, budget: float) -> float:
	var key := name + ":" + reason
	var reward := minf(maxf(0, value), maxf(0, budget - float(attack_paid.get(key, 0))))
	attack_paid[key] = float(attack_paid.get(key, 0)) + reward
	return reward


func aim(name: String, target: String, alignment: float, overlap: float, dt: float) -> Array:
	var key := name + ":" + target
	var improvement := maxf(0, alignment - float(aim_best.get(key, 0)))
	aim_best[key] = maxf(alignment, float(aim_best.get(key, 0)))
	return [
		{"reason": "aim_alignment", "value": _attack_pay(name, "aim_alignment",
			improvement * float(weights.get("aim_alignment_bonus", 2.0)), float(weights.get("aim_alignment_budget", 6.0)))},
		{"reason": "aim_overlap", "value": _attack_pay(name, "aim_overlap",
			overlap * dt * float(weights.get("aim_overlap_per_s", 0.3)), float(weights.get("aim_overlap_budget", 8.0)))}]


func aimed_fire(name: String, overlap: float) -> float:
	return _attack_pay(name, "aimed_fire", overlap * float(weights.get("aimed_fire_bonus", 2.0)),
		float(weights.get("aimed_fire_budget", 8.0)))
