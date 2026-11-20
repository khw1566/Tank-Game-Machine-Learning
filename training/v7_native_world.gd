extends Node3D
## The visible collector and headless trainer both call this world on Godot physics ticks.

const SCHEMA_FILE := "res://training/v7_native_schema.json"
const STAGES := {"v7_target": [0, 3], "v7_side": [0, 3], "v7_1v1": [1, 3],
	"v7_1v2": [2, 4], "v7_1v3": [3, 5], "v7_1v6": [6, 6]}
const ROUND_SECONDS := {"v7_target": 90, "v7_side": 240, "v7_1v1": 300,
	"v7_1v2": 360, "v7_1v3": 420, "v7_1v6": 480}
const RIVAL_FINISH_FRACTION := 0.8
const OBSERVATION_RANGE := 220.0
const CURSOR_RATE := 0.85  # metres per 0.1 s decision
const TAG_RADIUS := 1.6
const GATE_RADIUS := 4.2
const PULSE_INTERVAL := 30
const SHIELD_BUDGET := 0.90
const LAYOUT_FILE := "res://training/v7_training_layouts.json"
static var layout_catalog: Dictionary

static func catalog() -> Dictionary:
	if layout_catalog.is_empty():
		layout_catalog = JSON.parse_string(FileAccess.get_file_as_string(LAYOUT_FILE))
	return layout_catalog

var schema: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(SCHEMA_FILE))
var player: Tank
var map: HillMap
var focus_target: Vector3:
	get: return ring_position if gate_open else gate_position
var ring_position := Vector3.ZERO
var gate_position := Vector3.ZERO
var gate_open := false
var tank_id := ""
var stage_id := ""
var round_seed := 0
var score := 0
var goal := 0
var turn := 0
var limit_steps := 0
var finished := true

var _gated := false
var _seats := 0
var _ally_count := 0
var _rival_count := 0
var _gates := 0
var _gate_side := 1
var _cursor := Vector2(0, 7)
var _gate_best := 0.0
var _gate_initial := 0.0
var _ring_best := 0.0
var _ring_initial := 0.0
var _actors: Array[Dictionary] = []
var _seen := {}
var _pulse_turn := 0
var _shield_paid := 0.0
var _shield_held := false
var _blocks := 0
var _reflects := 0
var _action := PackedFloat32Array()
var _rng := RandomNumberGenerator.new()
var _ring_marker: Node3D
var _gate_marker: Node3D
var _cursor_marker: Node3D
var _objects: Node3D
var _observation_lines: MeshInstance3D
var _visible_rivals := {}
var layout_info := {}
var _map_key := ""


static func seed_for_map(value: int, map_index: int) -> int:
	var count: int = catalog().map_ids.size()
	return value if map_index < 0 else value - posmod(value, count) + map_index


func reset_round(vehicle: String, stage: String, seed_value: int) -> void:
	assert(vehicle in ["sherman75", "t34_76", "tiger1"] and STAGES.has(stage))
	if _objects != null:
		remove_child(_objects)
		_objects.free()
	_actors.clear()
	_seen.clear()
	_visible_rivals.clear()
	_objects = Node3D.new()
	add_child(_objects)
	_rng.seed = seed_value
	tank_id = vehicle
	stage_id = stage
	round_seed = seed_value
	_seats = STAGES[stage][0]
	goal = STAGES[stage][1]
	_gated = stage != "v7_target"
	_ally_count = _seats - 1 if vehicle != "tiger1" and _seats > 1 else 0
	_rival_count = _seats - _ally_count
	turn = 0
	score = 0
	_gates = 0
	_blocks = 0
	_reflects = 0
	_shield_paid = 0.0
	_shield_held = false
	_pulse_turn = _rng.randi_range(12, PULSE_INTERVAL)
	_gate_side = -1 if _rng.randi_range(0, 1) == 0 else 1
	limit_steps = int(ROUND_SECONDS[stage]) * 10
	finished = false
	_cursor = Vector2(0, 7)
	_action.resize(schema.action_labels.size())
	_action.fill(0)
	var data := catalog()
	var source_stage := "v6_1v1" if _seats == 0 else stage.replace("v7_", "v6_")
	var candidates: Array = data.layouts[source_stage][vehicle]
	var row: Dictionary = candidates[posmod(seed_value, candidates.size())]
	layout_info = {"map_id": row.map_id, "source_stage": row.source_stage,
		"source_seed": int(row.source_seed), "layout_id": row.layout_id}
	var terrain: Dictionary = data.maps[row.map_key]
	var next_key := str(row.map_key) + "/" + vehicle
	if map == null or _map_key != next_key:
		if map != null:
			remove_child(map)
			map.free()
		map = ScenarioLayout.build_map(self, terrain.map,
			{"scenario": {"learner_type": vehicle, "obstacles": terrain.obstacles}})
		_map_key = next_key
	var spawn_rng := RandomNumberGenerator.new()
	spawn_rng.seed = int(row.source_seed)
	var reserved := []
	for i in (1 if stage == "v7_target" else row.tanks.size()):
		var pose: Dictionary = row.tanks[i]
		var p := ScenarioLayout.resolve_spawn(map, Vector2(pose.p[0], pose.p[1]), spawn_rng, reserved)
		assert(p != Vector2.INF, "The training spawn could not be resolved")
		var car := _new_tank(str(pose.type), int(pose.team), p, float(pose.yaw), spawn_rng.randi_range(1, 2147483646))
		reserved.append(p)
		if i == 0:
			player = car
			player.name = "Player"
			continue
		var axis := Vector2(-sin(car.heading), -cos(car.heading))
		var actor := {"tank": car, "ally": car.team == player.team, "points": 0, "anchor": p, "axis": axis,
			"direction": 1.0 if _route_clear(p, p + axis * 24.0) else -1.0,
			"pace": _rng.randf_range(0.25, 0.37), "badge_phase": _rng.randi_range(0, 29)}
		if DisplayServer.get_name() != "headless":
			var badge := Label3D.new()
			badge.position.y = 4.0
			badge.billboard = BaseMaterial3D.BILLBOARD_ENABLED
			badge.pixel_size = 0.024
			badge.font_size = 45
			badge.outline_size = 10
			car.add_child(badge)
			actor["badge"] = badge
		_actors.append(actor)
	if DisplayServer.get_name() != "headless":
		_gate_marker = _marker(GATE_RADIUS, Color("#9671ef"))
		_ring_marker = _marker(TAG_RADIUS, Color("#ff9870"))
		_cursor_marker = _marker(0.56, Color.WHITE)
		_observation_lines = MeshInstance3D.new()
		_observation_lines.mesh = ImmediateMesh.new()
		var red := StandardMaterial3D.new()
		red.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		red.albedo_color = Color("#ff3948")
		_observation_lines.material_override = red
		_observation_lines.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_objects.add_child(_observation_lines)
	_refresh_visibility()
	_make_objective()


func _new_tank(id: String, team: int, p: Vector2, yaw: float, seed_value: int) -> Tank:
	var t := Tank.new()
	t.setup(id, team, seed_value)
	t.ground_map = map
	t.position = _ground(p) + Vector3.UP * 0.5
	t.rotation.y = yaw
	t.heading = yaw
	_objects.add_child(t)
	t.set_physics_process(false)
	return t


func _ground(p: Vector2) -> Vector3:
	return Vector3(p.x, map.height_at(p.x, p.y), p.y)


func _flat(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


func _local(p: Vector3) -> Vector2:
	var delta := _flat(p) - _flat(player.position)
	return Vector2(delta.dot(Vector2(cos(player.heading), -sin(player.heading))),
		delta.dot(Vector2(-sin(player.heading), -cos(player.heading))))


func _to_world(offset: Vector2) -> Vector3:
	var p := _flat(player.position) + offset.x * Vector2(cos(player.heading), -sin(player.heading))
	p += offset.y * Vector2(-sin(player.heading), -cos(player.heading))
	return _ground(p)


func cursor_position() -> Vector3:
	return _to_world(_cursor)


func _marker(radius: float, color: Color) -> MeshInstance3D:
	var mark := MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = radius * 0.83
	torus.outer_radius = radius
	torus.rings = 40
	torus.ring_segments = 8
	mark.mesh = torus
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	mark.material_override = material
	mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_objects.add_child(mark)
	return mark


func _make_objective() -> void:
	gate_open = not _gated
	var lateral := _gate_side * _rng.randf_range(4.0, 8.0)
	var distance := _rng.randf_range(12.0, 17.0)
	var start := _flat(player.position)
	var p := start
	for local in [Vector2(lateral, distance), Vector2(-lateral, distance), Vector2(0.0, distance),
		Vector2(lateral, 7.0), Vector2(-lateral, 7.0), Vector2(lateral, -8.0), Vector2(-lateral, -8.0)]:
		var candidate := _flat(_to_world(local))
		if _route_clear(start, candidate):
			p = candidate
			break
	if p == start:
		var safe := map.find_safe_spawn(_flat(_to_world(Vector2(lateral, 9))), _rng)
		if safe != Vector2.INF:
			p = safe
	gate_position = _ground(p)
	if not _gated:
		p = _flat(_to_world(Vector2(_rng.randf_range(-5, 5), _rng.randf_range(3, 12))))
	# Keep the ring in camera range on entering the gate.
	ring_position = _ground(p + Vector2(-sin(player.heading), -cos(player.heading)) * 3.0)
	_gate_side *= -1
	_gate_initial = _flat(player.position).distance_to(_flat(gate_position))
	_gate_best = _gate_initial
	_ring_initial = _flat(cursor_position()).distance_to(_flat(ring_position))
	_ring_best = _ring_initial
	_update_visuals()


func _route_clear(start: Vector2, finish: Vector2) -> bool:
	for sample in range(1, 9):
		var point := start.lerp(finish, float(sample) / 8.0)
		if not map.is_clear(point, 3.5) or map.normal_at(point.x, point.y).y < 0.88:
			return false
	return true


func apply_action(requested: PackedFloat32Array) -> PackedFloat32Array:
	assert(not finished and requested.size() == schema.action_labels.size())
	_action = requested.duplicate()
	for i in _action.size():
		_action[i] = clampf(requested[i], -1, 1)
	_action[2] = clampf(_action[2], 0, 1)
	_action[5] = 1.0 if _action[5] > 0.5 else 0.0
	_action[6] = 1.0 if _action[6] > 0.5 and _shield_enabled() else 0.0
	player.control.left_track = _action[0]
	player.control.right_track = _action[1]
	player.control.brake = _action[2]
	player.control.turret_traverse = _action[7]
	player.control.gun_elevation = _action[8]
	player.control.fire = false
	_cursor = (_cursor + Vector2(_action[3], _action[4]) * CURSOR_RATE).clamp(Vector2(-10, -4), Vector2(10, 16))
	return _action.duplicate()


func physics_tick(delta: float) -> void:
	if finished:
		return
	player.step(delta)
	for actor in _actors:
		var t: Tank = actor.tank
		var parked: bool = _seats == 0 or (actor.ally and actor.points >= 1)
		var direction := float(actor.direction)
		t.control.left_track = 0.0 if parked else direction * float(actor.pace)
		t.control.right_track = t.control.left_track
		t.control.brake = 1.0 if parked else 0.0
		t.step(delta)
		var limit := 24.0 if actor.points == 0 else 12.0
		if not parked and _flat(t.position).distance_to(actor.anchor) >= limit:
			actor.points += 1
			actor.anchor = _flat(t.position)
			actor.direction = -direction


func _visible_token(t: Tank) -> bool:
	return _visible_rivals.has(t)


func _refresh_visibility() -> void:
	_visible_rivals.clear()
	var start := LineOfSight.eye_position(player)
	for actor in _actors:
		if actor.ally:
			continue
		var rival: Tank = actor.tank
		var relative := _local(rival.position)
		if relative.length_squared() > OBSERVATION_RANGE * OBSERVATION_RANGE or relative.y < -3.0:
			continue
		var end := LineOfSight.eye_position(rival)
		var ray := LineOfSight.ray(map, start, end, [player.get_rid(), rival.get_rid()])
		if float(ray.transmittance) >= LineOfSight.POINT_VISIBLE:
			_visible_rivals[rival] = end


func _side_badge(actor: Dictionary) -> bool:
	return (turn + int(actor.badge_phase)) % 30 >= 15


func _update_visuals() -> void:
	if not is_instance_valid(_ring_marker):
		return
	_gate_marker.visible = _gated and not gate_open
	_gate_marker.position = gate_position + Vector3.UP * 0.26
	_ring_marker.visible = gate_open
	_ring_marker.position = ring_position + Vector3.UP * 0.72
	_cursor_marker.position = cursor_position() + Vector3.UP * 0.83
	for actor in _actors:
		var label: Label3D = actor.badge
		if actor.ally:
			label.text = "◆ 연합"
			label.modulate = Color("#70eda9")
		else:
			label.visible = _visible_token(actor.tank)
			actor.tank.visible = label.visible
			label.text = "▨ 옆면" if _side_badge(actor) else "■"
			label.modulate = Color("#ffc64d") if _side_badge(actor) else Color("#81bdff")
	var lines := _observation_lines.mesh as ImmediateMesh
	lines.clear_surfaces()
	if not _visible_rivals.is_empty():
		lines.surface_begin(Mesh.PRIMITIVE_LINES)
		var eye := LineOfSight.eye_position(player)
		for end in _visible_rivals.values():
			lines.surface_add_vertex(eye)
			lines.surface_add_vertex(end)
		lines.surface_end()


func _shield_enabled() -> bool:
	return _gated and tank_id == "tiger1"


func _shield_bonus(parts: Dictionary) -> void:
	if not _shield_enabled():
		return
	var pressed := _action[6] > 0.5
	if turn == _pulse_turn:
		if pressed:
			var amount := 0.15 if _shield_held else 0.35
			var paid := minf(amount, maxf(0, SHIELD_BUDGET - _shield_paid))
			if _shield_held:
				_blocks += 1
				parts.shield_block = paid
			else:
				_reflects += 1
				parts.shield_reflect = paid
			_shield_paid += paid
		_pulse_turn += PULSE_INTERVAL
	_shield_held = pressed


func _released_points(actor: Dictionary) -> int:
	if actor.ally:
		return mini(1, int(actor.points))
	if _seats == 0:
		return 0
	# Distance can earn points early, with the same release schedule in visible and headless play.
	var time_available := float(limit_steps) * RIVAL_FINISH_FRACTION
	return mini(int(actor.points), floori(float(turn * goal) / maxf(1.0, time_available)))


func round_status() -> Dictionary:
	var team_score := score
	var rival_score := 0
	for actor in _actors:
		if actor.ally:
			team_score += _released_points(actor)
		else:
			rival_score = maxi(rival_score, _released_points(actor))
	return {"tank": tank_id, "stage": stage_id, "seed": round_seed, "layout": layout_info, "score": score, "goal": goal,
		"team_score": team_score, "team_goal": goal + _ally_count, "rival_score": rival_score,
		"allies": _ally_count, "rivals": _rival_count, "allied_team": _ally_count > 0,
		"gate_open": gate_open, "side_checkpoints": _gates, "side_seen_count": _seen.size(),
		"visible_rivals": _visible_rivals.size(),
		"shield_blocks": _blocks, "shield_reflects": _reflects, "elapsed_steps": turn, "limit_steps": limit_steps}


func observation() -> PackedFloat32Array:
	var stats := round_status()
	var gate := _local(gate_position) / 90.0
	var ring := _local(ring_position) / 90.0
	var result := PackedFloat32Array([player.track_speed_left / 16.0, player.track_speed_right / 16.0,
		player.forward_speed() / 16.0, player.yaw_rate / PI, player.hull_pitch / PI, player.hull_roll / PI,
		sin(player.heading), cos(player.heading), player.gear, _cursor.x / 10.0, _cursor.y / 16.0,
		ring.x, ring.y, gate.x if _gated else 0.0, gate.y if _gated else 0.0, float(_gated), float(gate_open),
		float(score) / goal, 1.0 - float(turn) / limit_steps, float(stats.team_score) / stats.team_goal,
		float(stats.rival_score) / goal, _ally_count / 5.0, _rival_count / 6.0, float(_shield_enabled()),
		float(_pulse_turn - turn) / PULSE_INTERVAL if _shield_enabled() else 0.0, float(_shield_held),
		1.0 - _shield_paid / SHIELD_BUDGET if _shield_enabled() else 0.0])
	for i in 6:
		if i >= _actors.size():
			result.append_array(PackedFloat32Array([0, 0, 0, 0, 0, 0, 0, 0]))
			continue
		var actor: Dictionary = _actors[i]
		var visible_now: bool = actor.ally or _visible_token(actor.tank)
		var pos := _local(actor.tank.position) / OBSERVATION_RANGE if visible_now else Vector2.ZERO
		result.append_array(PackedFloat32Array([1, float(actor.ally), float(visible_now), pos.x, pos.y,
			float(visible_now and not actor.ally and _side_badge(actor)), float(_seen.has(i)), float(_released_points(actor)) / goal]))
	result.append_array(PackedFloat32Array([sin(player.turret_yaw), cos(player.turret_yaw), player.gun_pitch / (PI * 0.5)]))
	for i in result.size():
		result[i] = clampf(result[i], -1, 1)
	return result


func advance_decision() -> Dictionary:
	assert(not finished)
	turn += 1
	_refresh_visibility()
	var parts := {"time": -1.2 / float(limit_steps), "side_seen": 0.0}
	var fresh: Array = []
	for i in _actors.size():
		var actor: Dictionary = _actors[i]
		if not actor.ally and not _seen.has(i) and _visible_token(actor.tank) and _side_badge(actor):
			fresh.append(i)
			_seen[i] = true
			parts.side_seen += 0.5
	_shield_bonus(parts)
	if not gate_open:
		var d := _flat(player.position).distance_to(_flat(gate_position))
		if d < _gate_best:
			parts.side_progress = (_gate_best - d) * 0.7 / maxf(_gate_initial, 0.01)
			_gate_best = d
		if d <= GATE_RADIUS:
			gate_open = true
			_gates += 1
			parts.side_checkpoint = 4.0
	if gate_open and score < goal:
		var d := _flat(cursor_position()).distance_to(_flat(ring_position))
		if d < _ring_best:
			parts.cursor_progress = (_ring_best - d) * 0.35 / maxf(_ring_initial, 0.01)
			_ring_best = d
		if d <= TAG_RADIUS and _action[5] > 0.5:
			score += 1
			parts.ring_tag = 1.0
	var stats := round_status()
	var won: bool = stats.team_score >= stats.team_goal
	var lost: bool = stats.rival_score >= goal
	var out := maxf(absf(player.position.x), absf(player.position.z)) > map.size_m * 0.5 - 2.0
	var terminated: bool = won or lost or out
	var truncated := not terminated and turn >= limit_steps
	finished = terminated or truncated
	if finished:
		var success := won and not lost and not out
		parts["success" if success else "loss"] = 4.0 if success else -2.0
		stats.is_success = success
		stats.reason = "time_limit"
		if out:
			stats.reason = "out_of_bounds"
		elif won and lost:
			stats.reason = "race_tie"
		elif success:
			stats.reason = "rings_complete"
		elif lost:
			stats.reason = "rival_finished"
	elif parts.has("ring_tag") and score < goal:
		_make_objective()
		stats.gate_open = gate_open
	stats.reward_components = parts
	stats.side_seen_new_ids = fresh
	var total := 0.0
	for v in parts.values():
		total += float(v)
	_update_visuals()
	return {"reward": total, "terminated": terminated, "truncated": truncated, "info": stats}
