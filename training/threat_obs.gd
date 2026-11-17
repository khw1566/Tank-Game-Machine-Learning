class_name ThreatObs
extends RefCounted
## Cues a crew can see/hear. No enemy reload timers, hidden launchers or future hit points.

const VERSION := 1
const LABELS := ["fire.heard_recent", "fire.heard_sin", "fire.heard_cos",
	"fire.enemy_flash_recent", "fire.flash_sin", "fire.flash_cos",
	"fire.impact_recent", "fire.impact_sin", "fire.impact_cos",
	"fire.near_pass_recent", "fire.near_pass_sin", "fire.near_pass_cos",
	"fire.tracer_present", "fire.tracer_sin", "fire.tracer_cos",
	"fire.tracer_motion_sin", "fire.tracer_motion_cos", "fire.tracer_proximity"]


static func _cue(t: Tank, position: Vector3, age: float) -> Array:
	var d := position - t.global_position
	var angle := wrapf(atan2(-d.x, -d.z) - t.global_rotation.y, -PI, PI)
	angle = snappedf(angle, deg_to_rad(5))
	return [exp(-age / 2.0), sin(angle), cos(angle)]


static func compute(p: TankPerception, field: TrainingProjectileField = null) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for kind in [SoundField.GUNFIRE, -1, SoundField.IMPACT, -2]:
		var cue := [0.0, 0.0, 0.0]
		if kind >= 0 and p.sounds != null:
			# Read the event stream rather than four display slots, so impacts cannot erase firing cues.
			for i in range(p.sounds.events.size() - 1, -1, -1):
				var event: Dictionary = p.sounds.events[i]
				if int(event.kind) != kind or str(event.src) == str(p.tank.name):
					continue
				var age := p.sounds.time - float(event.t)
				if age <= SoundField.KEEP_S and SoundField.loudness(kind, p.tank.global_position.distance_to(event.pos)) >= SoundField.AUDIBLE:
					cue = _cue(p.tank, event.pos, age)
					break
		elif kind == -1 and not p.last_enemy_flash.is_empty():
			var age := p.time - float(p.last_enemy_flash.time)
			if age >= 0 and age < 4:
				cue = _cue(p.tank, p.last_enemy_flash.position, age)
		elif kind == -2 and field != null and field.near_passes.has(str(p.tank.name)):
			var event: Dictionary = field.near_passes[str(p.tank.name)]
			var age := field.time - float(event.time)
			if age < 4:
				cue = _cue(p.tank, event.position, age)
		out.append_array(PackedFloat32Array(cue))
	var tracer := [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
	if field != null:
		var eye := p.view.eye_transform(p.tank, p.map)
		var nearest := 1400.0
		for projectile in field.active:
			var shooter: Tank = projectile.shooter.get_ref()
			if shooter == p.tank:
				continue
			var pos: Vector3 = projectile.pos
			var distance := eye.origin.distance_to(pos)
			if distance >= nearest or not p.view.on_screen(TankView.screen_point(eye, p.view.fov(), pos)):
				continue
			var exclude := [p.tank.get_rid()]
			if is_instance_valid(shooter):
				exclude.append(shooter.get_rid())
			var ray := LineOfSight.ray(p.map, eye.origin, pos, exclude)
			if float(ray.transmittance) < LineOfSight.POINT_VISIBLE:
				continue
			nearest = distance
			var bearing := _cue(p.tank, pos, 0)
			var motion: Vector3 = pos - projectile.previous
			var angle := snappedf(wrapf(atan2(-motion.x, -motion.z) - p.tank.global_rotation.y, -PI, PI), deg_to_rad(5))
			tracer = [1.0, bearing[1], bearing[2], sin(angle) if motion.length() > 0.001 else 0.0,
				cos(angle) if motion.length() > 0.001 else 0.0, snappedf(1.0 - distance / 1400.0, 0.05)]
	out.append_array(PackedFloat32Array(tracer))
	return out
