class_name TrainingReward
extends RefCounted
## 커리큘럼 단계별 보상·종료 판정. 사격 결과 보상은 게임 점수와 같은 RewardModel 을 쓰고(가중치는 config.reward.combat),
## 그 위에 단계별 보조 보상(shaping)을 더한다. 보조 보상은 보상 계산에만 쓰는 "정답" 정보(실제 거리·방향)를 써도 된다 —
## 정책의 관측에는 들어가지 않는다.
##
##   drive    웨이포인트 쪽으로 가까워진 거리 × progress, 도착(radius 안) arrive → 성공·종료
##   gunnery  사격 보상 + 포 방향 정렬 퍼텐셜(aim) — 명중 success_hits 회 이상 또는 표적 격파 → 성공·종료
##   combat   사격 보상(+피격 감점) + 첫 탐지(spot) + 승패(win/loss) — 한 팀 전멸 → 종료
## 모든 단계: time_per_s(초당), 시간 제한 → 종료(실패/무승부)

const DEFAULTS := {
	"event_scale": 1.0,
	"progress": 0.02,        # 웨이포인트에 가까워진 1m 당
	"arrive": 5.0,
	"arrive_radius": 12.0,
	"aim": 1.0,              # 포 방향 오차 퍼텐셜(π rad → 0) 변화량 배율
	"spot": 0.2,             # 적을 처음 탐지할 때마다(전차당 1회)
	"time_per_s": -0.005,
	"win": 5.0,
	"loss": -5.0,
	"success_bonus": 2.0,    # 사격 단계 성공 시
	"combat": {},            # RewardModel 가중치 덮어쓰기(hit, penetration, knockout, miss, victim_scale ...)
}

var w := DEFAULTS.duplicate(true)
var env
var model: RewardModel
var hits := {}
var pens := {}
var kills := {}
var _pending := {}
var _total := {}
var _prev_dist := {}
var _prev_aim := {}
var _spotted := {}
var _course_initial := 0.0
var _course_best := 0.0
var _course_anchor := 0.0
var _course_idle := 0.0
var _course_hold := 0.0
var _course_blocked := 0.0
var _course_path := 0.0
var _course_last := Vector3.ZERO
var _course_parts := {}
var _course_checkpoints := 0
var _battle_parts := {}
var _battle_prev_pos := {}
var _battle_best := {}
var _battle_milestones := {}
var _near_best := {}
var _near_paid := {}
var _closing_paid := {}
# 커리큘럼 v4 전투 상황(config.scenario): 결과 보상 + 감쇠하는 목표 진행 보조 보상
var _sc_best := INF
var _sc_hold := 0.0
var _sc_zone := 0.0
var _sc_objective := false
var _sc_exposed := 0.0
var _sc_hull := 0.0
var _sc_turret := 0.0
var _sc_checks := 0
var _sc_taken := {"hits": 0, "pens": 0}
var _sc_path := 0.0
var _sc_last := Vector3.ZERO
var _sc_forward := 0.0
var _sc_reverse := 0.0
var _sc_route: ScenarioRoute
var _sc_route_best := INF
var _sc_cover_routes: Array = []
var _sc_cover_initial := INF
var _sc_cover_best := INF
var _sc_best_shield := 0.0
var _sc_cover_hold := 0.0
var _sc_longest_cover := 0.0
var _sc_fire_cue := false
var _sc_enemy_seen := false
var _sc_enemy_shots := 0
var _sc_spawn := Vector3.ZERO


func _init(p_env, overrides := {}) -> void:
	env = p_env
	w.merge(overrides, true)
	if config_kind() == "drive" and not overrides.has("time_per_s"):
		w.time_per_s = -0.01
	model = RewardModel.new(w.combat)


func config_kind() -> String:
	return str(env.config.get("kind", "combat"))


func _parts_on() -> bool:
	return bool(w.get("battle_shaping", false)) or env.config.has("scenario")


func learner_team() -> int:
	return int(env.config.get("learner_team", 0))


func start() -> void:
	for t in env.tanks:
		_pending[t.name] = 0.0
		_total[t.name] = 0.0
		_spotted[t.name] = {}
		_prev_dist[t.name] = _wp_dist(t)
		_prev_aim[t.name] = _aim_potential(t)
		if _parts_on():
			_battle_parts[t.name] = {}
		if bool(w.get("battle_shaping", false)):
			_battle_prev_pos[t.name] = t.global_position
			_battle_best[t.name] = {}
			_near_best[t.name] = {}
			_near_paid[t.name] = 0.0
			_closing_paid[t.name] = 0.0
			var closest := INF
			for enemy in env.tanks:
				if enemy.team == t.team or not enemy.damage.is_combat_effective():
					continue
				var distance := Vector2(t.global_position.x - enemy.global_position.x, t.global_position.z - enemy.global_position.z).length()
				_battle_best[t.name][enemy.name] = distance
				closest = minf(closest, distance)
			_battle_milestones[t.name] = {}
			for threshold in w.get("close_distances", [150, 100, 60, 30]):
				if closest <= threshold:
					_battle_milestones[t.name][str(threshold)] = true
	if env.config.has("scenario"):
		_sc_best = _wp_dist(env.tanks[0]) if env.waypoint != Vector3.INF else INF
		_sc_last = env.tanks[0].global_position
		_sc_spawn = _sc_last
		for region in env.config.scenario.get("cover_regions", []):
			var cover_config: Dictionary = env.config.scenario.duplicate(true)
			cover_config["objective"] = {"p": region.p}
			var route := ScenarioRoute.new(cover_config, env.tanks[0].spec)
			_sc_cover_routes.append(route)
			_sc_cover_initial = minf(_sc_cover_initial, route.remaining(_sc_last))
		_sc_cover_best = _sc_cover_initial
		var driving: Dictionary = env.config.scenario.get("driving", {})
		if driving.get("route_progress", false) and env.config.scenario.has("objective"):
			_sc_route = ScenarioRoute.new(env.config.scenario, env.tanks[0].spec)
			_sc_route_best = _sc_route.remaining(_sc_last)
	if env.config.has("terrain_course"):
		_course_initial = _remaining_route(env.tanks[0])
		_course_best = _course_initial
		_course_anchor = _course_initial
		_course_last = env.tanks[0].global_position


func _add(name: String, v: float, reason := "other") -> void:
	_pending[name] = _pending.get(name, 0.0) + v
	_total[name] = _total.get(name, 0.0) + v
	if _parts_on() and v != 0.0:
		var parts: Dictionary = _battle_parts.get(name, {})
		parts[reason] = parts.get(reason, 0.0) + v
		_battle_parts[name] = parts
		if env.recorder != null:
			for tank in env.tanks:
				if str(tank.name) == name:
					env.recorder.training_reward(name, tank.team, v, reason)
					break


func pending(name: String) -> float:
	return _pending.get(name, 0.0)


## 지난 결정 이후 쌓인 보상을 꺼낸다(0 으로 초기화)
func taken(name: String) -> float:
	var v: float = _pending.get(name, 0.0)
	_pending[name] = 0.0
	return snappedf(v, 0.00001)


func total(name: String) -> float:
	return _total.get(name, 0.0)


func on_launch(shooter: Tank, result: Dictionary) -> void:
	if not env.config.has("scenario") or not env.config.scenario.has("evade") or shooter.team == env.tanks[0].team:
		return
	_sc_enemy_shots += 1
	var origin := SoundField._v(result.get("from", []))
	if SoundField.loudness(SoundField.GUNFIRE, env.tanks[0].global_position.distance_to(origin)) >= SoundField.AUDIBLE:
		_sc_fire_cue = true


func on_shot(shooter: Tank, r: Dictionary) -> void:
	var target: String = r.get("target_name", "")
	var tteam := int(r.get("target_team", -1))
	for e in model.shot_rewards(shooter.name, shooter.team, target, tteam, r):
		_add(e.tank, float(e.value) * float(w.event_scale), str(e.reason))
	if bool(w.get("battle_shaping", false)) and not r.get("hit", false):
		_near_miss(shooter, r.get("near_miss", {}))
	var live_hit := not bool(w.combat.get("live_target_only", false)) or bool(r.get("target_was_combat_effective", true))
	if env.config.has("scenario") and r.get("hit", false) and target == str(env.tanks[0].name) and tteam != shooter.team:
		_sc_taken.hits += 1
		if float(w.get("hit_taken", 0.0)) != 0.0:
			_add(str(env.tanks[0].name), float(w.hit_taken), "hit_taken")
		if r.get("penetrated", false):
			_sc_taken.pens += 1
	if r.get("hit", false) and tteam != shooter.team and live_hit:
		hits[shooter.name] = hits.get(shooter.name, 0) + 1
		if r.get("penetrated", false):
			pens[shooter.name] = pens.get(shooter.name, 0) + 1
		for ev in r.get("events", []):
			if str(ev).begins_with("knocked_out:"):
				kills[shooter.name] = kills.get(shooter.name, 0) + 1


## 결정 시점마다 호출: 보조 보상을 더하고 종료 여부를 돌려준다
func decision() -> Dictionary:
	var dt := float(TankAgent.PERCEIVE_EVERY) / Engine.physics_ticks_per_second
	if env.config.has("terrain_course"):
		return _course_decision(dt)
	if env.config.has("scenario"):
		return _scenario_decision(dt)
	var kind := config_kind()
	var out := {"done": false}
	var arrived := false
	var scoring: Array = range(env.tanks.size()) if bool(w.get("battle_shaping", false)) else env.ext
	for i in scoring:
		var t: Tank = env.tanks[i]
		if not t.damage.is_combat_effective():
			continue
		_add(t.name, float(w.time_per_s) * dt, "time")
		if kind == "combat" and bool(w.get("battle_shaping", false)):
			_battle_approach(t)
		if kind == "drive":
			var d := _wp_dist(t)
			_add(t.name, (float(_prev_dist[t.name]) - d) * float(w.progress))
			_prev_dist[t.name] = d
			if d < float(env.config.get("waypoint", {}).get("radius", w.arrive_radius)):
				_add(t.name, float(w.arrive))
				arrived = true
		elif kind == "gunnery":
			var a := _aim_potential(t)
			_add(t.name, (a - float(_prev_aim[t.name])) * float(w.aim))
			_prev_aim[t.name] = a
		if kind != "drive" and float(w.spot) != 0.0:
			for n in env.agents[i].perception.contacts:
				var c: Dictionary = env.agents[i].perception.contacts[n]
				if c.enemy and c.visible_now and not _spotted[t.name].has(n):
					_spotted[t.name][n] = true
					_add(t.name, float(w.spot), "spot")
	var alive := [0, 0]
	for t in env.tanks:
		if t.damage.is_combat_effective():
			alive[t.team] += 1
	var lt := learner_team()
	var timeout: bool = env.tick >= env.time_limit_ticks
	match kind:
		"drive":
			if arrived:
				return _done("arrived", true, lt)
		"gunnery":
			var need := int(env.config.get("success_hits", 2))
			var h := 0
			var ammo := 0
			for i in env.ext:
				var t: Tank = env.tanks[i]
				if t.team == lt:
					h += hits.get(t.name, 0)
					ammo += t.damage.ammo_remaining
			if h >= need or alive[1 - lt] == 0:
				for i in env.ext:
					if env.tanks[i].team == lt:
						_add(env.tanks[i].name, float(w.success_bonus))
				return _done("target_hit" if alive[1 - lt] > 0 else "target_destroyed", true, lt)
			if ammo <= 0:
				return _done("out_of_ammo", false, -1)
		_:
			if alive[0] == 0 or alive[1] == 0:
				var winner := -1 if alive[0] == alive[1] else (0 if alive[0] > 0 else 1)
				for t in env.tanks:
					if winner >= 0:
						_add(t.name, float(w.win) if t.team == winner else float(w.loss), "win" if t.team == winner else "loss")
				return _done("elimination", winner == lt, winner)
	if timeout:
		if kind == "combat" and bool(w.get("battle_shaping", false)):
			for tank in env.tanks:
				if tank.damage.is_combat_effective():
					_add(tank.name, float(w.get("timeout_penalty", -4)), "timeout")
		return _done("time_limit", false, -1)
	return out


func _done(reason: String, success: bool, winner: int) -> Dictionary:
	return {"done": true, "reason": reason, "success": success, "winner": winner}


func _near_miss(shooter: Tank, near: Dictionary) -> void:
	if near.is_empty() or int(near.get("target_team", shooter.team)) == shooter.team or float(near.get("range_m", 0)) < 20:
		return
	var target := str(near.get("target_name", ""))
	var radius := float(w.get("near_miss_radius_m", 12))
	var quality := clampf(1.0 - float(near.get("miss_distance_m", radius)) / radius, 0.0, 1.0)
	var previous := float(_near_best[shooter.name].get(target, 0))
	_near_best[shooter.name][target] = maxf(previous, quality)
	# Each enemy supplies at most one point, and all near misses together at most three.
	var reward := minf(maxf(0, quality - previous) * float(w.get("near_miss_bonus", 1)), maxf(0, float(w.get("near_miss_budget", 3)) - float(_near_paid[shooter.name])))
	_near_paid[shooter.name] += reward
	_add(shooter.name, reward, "near_miss")


func _battle_approach(t: Tank) -> void:
	var before: Vector3 = _battle_prev_pos[t.name]
	var movement := Vector2(t.global_position.x - before.x, t.global_position.z - before.z)
	_battle_prev_pos[t.name] = t.global_position
	var closest: Tank = null
	var nearest := INF
	for enemy in env.tanks:
		if enemy.team == t.team or not enemy.damage.is_combat_effective():
			continue
		var distance := Vector2(t.global_position.x - enemy.global_position.x, t.global_position.z - enemy.global_position.z).length()
		if distance < nearest:
			nearest = distance
			closest = enemy
	if closest == null:
		return
	var direction := Vector2(closest.global_position.x - t.global_position.x, closest.global_position.z - t.global_position.z).normalized()
	var own_closing := maxf(0, movement.dot(direction))
	var best: Dictionary = _battle_best[t.name]
	var previous := float(best.get(closest.name, nearest))
	var improvement := maxf(0, maxf(previous, 25) - maxf(nearest, 25))
	best[closest.name] = minf(previous, nearest)
	var progress := minf(own_closing, improvement)
	var reward := minf(progress * float(w.get("closing_per_m", 0.03)), maxf(0, float(w.get("closing_budget", 4)) - float(_closing_paid[t.name])))
	_closing_paid[t.name] += reward
	_add(t.name, reward, "closing")
	if progress <= 0.001:
		return
	var values: Array = w.get("close_bonuses", [0.5, 0.75, 1.0, 1.5])
	var thresholds: Array = w.get("close_distances", [150, 100, 60, 30])
	for i in thresholds.size():
		var key := str(thresholds[i])
		if nearest <= float(thresholds[i]) and not _battle_milestones[t.name].has(key):
			_battle_milestones[t.name][key] = true
			_add(t.name, values[i], "close_" + key + "m")


func battle_summary() -> Dictionary:
	return _battle_parts.duplicate(true)


func _course_add(t: Tank, component: String, value: float) -> void:
	_course_parts[component] = float(_course_parts.get(component, 0.0)) + value
	_add(t.name, value)


func _remaining_route(t: Tank) -> float:
	var remaining := _wp_dist(t)
	for i in range(env.course_index, env.course_route.size() - 1):
		var a: Vector3 = env.course_route[i]
		var b: Vector3 = env.course_route[i + 1]
		remaining += Vector2(a.x - b.x, a.z - b.z).length()
	return remaining


func _course_fail(t: Tank, reason: String) -> Dictionary:
	_course_add(t, "failure", float(w.get("failure", -2.0)))
	return _done(reason, false, -1)


func _course_decision(dt: float) -> Dictionary:
	var t: Tank = env.tanks[0]
	var lesson: Dictionary = env.config.terrain_course
	var moved := Vector2(t.global_position.x - _course_last.x, t.global_position.z - _course_last.z).length()
	_course_last = t.global_position
	_course_path += moved
	var speed := moved / dt
	_course_add(t, "time", float(w.time_per_s) * dt)
	if not t.damage.can_move():
		return _course_fail(t, "immobilized")
	if TerrainCourse.outside(env.config.terrain_layout, t.global_position):
		return _course_fail(t, "out_of_bounds")
	var final: bool = env.course_index == env.course_route.size() - 1
	var radius := float(lesson.goal_radius if final else lesson.checkpoint_radius)
	# Every task waypoint uses the same observable rule: approach, slow down, hold.
	if _wp_dist(t) <= radius and speed <= float(lesson.stop_speed) and absf(t.forward_speed()) <= float(lesson.stop_speed):
		_course_hold += dt
	else:
		_course_hold = 0.0
	if _course_hold + 0.000001 >= float(lesson.hold_s):
		if final:
			_course_add(t, "arrive", float(w.arrive))
		else:
			_course_add(t, "checkpoint", float(w.get("checkpoint", 1.0)))
			_course_checkpoints += 1
			env.course_index += 1
			env.waypoint = env.course_route[env.course_index]
			_course_hold = 0.0
			_course_idle = 0.0
	var remaining := _remaining_route(t)
	# Reward only NEW best route progress; reversing/oscillating cannot harvest it again.
	var improvement := maxf(0.0, _course_best - remaining)
	_course_best = minf(_course_best, remaining)
	_course_add(t, "progress", float(w.progress) * improvement / maxf(_course_initial, 1.0))
	_course_idle += dt
	if _course_anchor - _course_best >= 0.5:
		_course_anchor = _course_best
		_course_idle = 0.0
	var pushing := maxf(absf(t.control.left_track), absf(t.control.right_track)) > 0.5 and t.control.brake < 0.2
	_course_blocked = _course_blocked + dt if speed < 0.15 and pushing else 0.0
	if _course_blocked > 2.0:
		_course_add(t, "blocked", float(w.get("stalled_per_s", -0.1)) * dt)
	if final and _course_hold + 0.000001 >= float(lesson.hold_s):
		return _done("arrived_stopped", true, learner_team())
	if _course_idle >= float(lesson.no_progress_s):
		return _course_fail(t, "no_progress")
	if env.tick >= env.time_limit_ticks:
		return _course_fail(t, "time_limit")
	return {"done": false}


## 커리큘럼 v4: 학습 전차(tanks[0]) 기준. 행동(엄폐 도착 등) 보상은 없고 결과만 본다
##   reach    목표 지점에서 hold_s 동안 거의 정지 → 성공(objective)
##   survive  제한 시간까지 전투 가능 → 성공(survive)
##   destroy  적 전멸 → 성공(win)
##   zone     목표 구역 안 누적 zone_s → 성공(objective)
## 보조 보상: 목표까지 새로 줄인 거리 × progress × shaping_scale(Python 이 단계 진행에 따라 1→0 으로 줄임)
func _scenario_decision(dt: float) -> Dictionary:
	var sc: Dictionary = env.config.scenario
	var me: Tank = env.tanks[0]
	var goal := str(sc.get("goal", "reach"))
	_add(me.name, float(w.time_per_s) * dt, "time")
	var movement := Vector2(me.global_position.x - _sc_last.x, me.global_position.z - _sc_last.z)
	_sc_path += movement.length()
	var speed := movement.length() / dt
	var forward := Vector2(-sin(me.global_rotation.y), -cos(me.global_rotation.y))
	var signed_m := movement.dot(forward)
	_sc_forward += maxf(0.0, signed_m)
	_sc_reverse += maxf(0.0, -signed_m)
	var driving: Dictionary = sc.get("driving", {})
	if not driving.is_empty():
		_add(me.name, maxf(0.0, -signed_m) * float(driving.get("reverse_per_m", -0.08)), "reverse")
	elif float(w.get("reverse_excess_per_m", 0.0)) != 0.0 and signed_m < 0.0:
		# 주행 단계 뒤: 짧은 후퇴(엄폐로 물러나기)는 허용하고, 누적 후진이 여유를 넘은 만큼만 약하게 감점
		var allowance := float(w.get("reverse_allowance_m", 15.0))
		var before := maxf(0.0, _sc_reverse + signed_m - allowance)
		var after := maxf(0.0, _sc_reverse - allowance)
		if after > before:
			_add(me.name, (after - before) * float(w.reverse_excess_per_m), "reverse_excess")
	_sc_last = me.global_position
	if env.decisions % 5 == 0:
		_sc_exposure(me, dt * 5.0)
	if not me.damage.is_combat_effective():
		_add(me.name, float(w.loss), "loss")
		return _done("learner_knocked_out", false, 1 - learner_team())
	var enemies_alive := 0
	for i in range(1, env.tanks.size()):
		if env.tanks[i].team != me.team and env.tanks[i].damage.is_combat_effective():
			enemies_alive += 1
	if goal == "take_cover":
		return _sc_evade(me, dt, enemies_alive)
	if env.waypoint != Vector3.INF:
		var d := _wp_dist(me)
		var remaining := _sc_route.remaining(me.global_position) if _sc_route else d
		var best := _sc_route_best if _sc_route else _sc_best
		if best < INF and remaining < best and (driving.is_empty() or signed_m > 0.0):
			_add(me.name, (best - remaining) * float(w.get("progress", 0.02)) * float(w.get("shaping_scale", 1.0)), "shaping_progress")
		# Consume new-best progress even when reversing: turning around cannot collect it later.
		_sc_route_best = minf(_sc_route_best, remaining)
		_sc_best = minf(_sc_best, d)
		var radius := float(sc.get("objective", {}).get("radius", 10.0))
		var inside := d <= radius
		if inside:
			_sc_zone += dt
		_sc_hold = _sc_hold + dt if inside and speed < 1.0 else 0.0
		if goal == "reach" and _sc_hold + 0.000001 >= float(sc.get("objective", {}).get("hold_s", 1.0)):
			if not driving.is_empty() and not _sc_forward_pass(driving):
				_add(me.name, float(w.get("timeout_penalty", -3.0)), "invalid_drive")
				return _done("arrival_requires_forward_drive", false, -1)
			_sc_objective = true
			_add(me.name, float(w.get("objective", 8.0)), "objective")
			return _sc_finish("objective_reached", learner_team())
		if goal == "zone" and _sc_zone + 0.000001 >= float(sc.get("zone_s", 20.0)):
			_sc_objective = true
			_add(me.name, float(w.get("objective", 8.0)), "objective")
			return _sc_finish("zone_held", learner_team())
	if goal == "hits" and int(hits.get(me.name, 0)) >= int(sc.get("hits", 2)):
		_sc_objective = true
		_add(me.name, float(w.get("objective", 8.0)), "objective")
		return _done("target_hit", true, learner_team())
	if enemies_alive == 0 and env.tanks.size() > 1 and goal in ["destroy", "survive", "hits"]:
		_add(me.name, float(w.win), "win")
		return _sc_finish("enemies_destroyed", learner_team())
	if env.tick >= env.time_limit_ticks:
		if goal == "survive":
			_add(me.name, float(w.get("survive", 6.0)), "survive")
			return _sc_finish("survived", -1)
		_add(me.name, float(w.get("timeout_penalty", -3.0)), "timeout")
		return _done("time_limit", false, -1)
	return {"done": false}


func _sc_forward_pass(driving: Dictionary) -> bool:
	var allowance := float(driving.get("reverse_allowance_m", 2.0))
	var counted_reverse := maxf(0.0, _sc_reverse - allowance)
	return _sc_forward / maxf(0.001, _sc_forward + counted_reverse) >= float(driving.get("min_forward_fraction", 0.85))


func _sc_evade(me: Tank, dt: float, enemies_alive: int) -> Dictionary:
	var rules: Dictionary = env.config.scenario.evade
	for contact in env.agents[0].perception.contacts.values():
		if contact.enemy and contact.visible_now and not contact.knocked_out:
			_sc_enemy_seen = true
	var displacement := Vector2(me.global_position.x - _sc_spawn.x, me.global_position.z - _sc_spawn.z).length()
	if int(_sc_taken.hits) > int(env.config.scenario.get("max_hits", 4)):
		_add(me.name, _sc_early_end_penalty(rules), "too_many_hits")
		return _done("evade_too_many_hits", false, -1)
	if displacement > float(rules.get("arena_radius_m", 240)):
		_add(me.name, _sc_early_end_penalty(rules), "outside")
		return _done("evade_outside_area", false, -1)
	if enemies_alive == 0:
		return _done("no_threat_to_evade", false, -1)
	var shield := 0.0
	var fully_blocked := true
	for enemy in env.tanks:
		if enemy.team == me.team or not enemy.damage.is_combat_effective():
			continue
		var seen := SituationObs.exposure_from(env.map, LineOfSight.eye_position(enemy), me, [me.get_rid(), enemy.get_rid()])
		fully_blocked = fully_blocked and not seen.hull and not seen.turret
		shield += (0.0 if seen.hull else 0.5) + (0.0 if seen.turret else 0.5)
	shield /= enemies_alive
	var scale := float(w.get("shaping_scale", 1))
	var cue_ok: bool = _sc_fire_cue or not bool(rules.get("require_fire_cue", true))
	var remaining := INF
	for route in _sc_cover_routes:
		remaining = minf(remaining, route.remaining(me.global_position))
	if cue_ok and _sc_cover_best < INF and remaining < _sc_cover_best:
		_add(me.name, (_sc_cover_best - remaining) / maxf(1, _sc_cover_initial)
			* float(rules.get("cover_progress_budget", 2)) * scale, "cover_progress")
	_sc_cover_best = minf(_sc_cover_best, remaining)
	if cue_ok and shield > _sc_best_shield:
		_add(me.name, (shield - _sc_best_shield) * float(rules.get("concealment_budget", 2)) * scale, "concealment")
	_sc_best_shield = maxf(_sc_best_shield, shield)
	if cue_ok and not fully_blocked:
		_add(me.name, float(rules.get("exposed_per_s", -0.04)) * dt, "exposure")
	var sheltered := fully_blocked and _sc_near_cover(me) and displacement >= float(rules.get("min_displacement_m", 35))
	var eligible: bool = (_sc_fire_cue and _sc_enemy_seen) or not bool(rules.get("require_fire_cue", true))
	_sc_cover_hold = _sc_cover_hold + dt if sheltered and eligible else 0.0
	_sc_longest_cover = maxf(_sc_longest_cover, _sc_cover_hold)
	if _sc_cover_hold + 0.000001 >= float(rules.get("hold_s", 4)):
		_sc_objective = true
		_add(me.name, float(w.get("objective", 8)), "objective")
		return _sc_finish("covered_after_fire", learner_team())
	if env.tick >= env.time_limit_ticks:
		_add(me.name, float(w.get("timeout_penalty", -3)), "timeout")
		return _done("evade_time_limit", false, -1)
	return {"done": false}


## 일찍 끝난 실패가 끝까지 버틴 실패보다 이득이 되지 않게: 시간 초과 감점 + 남은 시간 동안 받았을 시간·노출 감점
func _sc_early_end_penalty(rules: Dictionary) -> float:
	var remaining_s := maxf(0.0, float(env.time_limit_ticks - env.tick) / Engine.physics_ticks_per_second)
	return float(w.get("timeout_penalty", -3)) + remaining_s * (float(w.time_per_s) + float(rules.get("exposed_per_s", -0.04)))


func _sc_near_cover(me: Tank) -> bool:
	var pos := Vector2(me.global_position.x, me.global_position.z)
	for obstacle in env.config.scenario.get("obstacles", []):
		if obstacle.get("type", "stone") != "stone":
			continue
		var p: Array = obstacle.p
		var size: Array = obstacle.size
		var local := (pos - Vector2(p[0], p[1])).rotated(float(obstacle.get("yaw", 0)))
		var offset := (local.abs() - Vector2(size[0], size[2]) * 0.5).max(Vector2.ZERO)
		if offset.length() <= 18 and float(size[1]) >= me.spec.total_height():
			return true
	return false


## 목표를 이뤘어도 scenario.max_hits 보다 많이 맞았으면 실패(맞지 않는 법이 그 단계의 목표다)
func _sc_finish(reason: String, winner: int) -> Dictionary:
	var limit := int(env.config.scenario.get("max_hits", -1))
	if limit >= 0 and int(_sc_taken.hits) > limit:
		return _done(reason + "_too_many_hits", false, winner)
	return _done(reason, true, winner)


## 보고서용(정책 관측 아님): 실제 적 눈 위치에서 학습 전차가 보이는지
func _sc_exposure(me: Tank, span: float) -> void:
	var hull := false
	var turret := false
	for i in range(1, env.tanks.size()):
		var e: Tank = env.tanks[i]
		if e.team == me.team or not e.damage.is_combat_effective():
			continue
		var r := SituationObs.exposure_from(env.map, LineOfSight.eye_position(e), me, [me.get_rid(), e.get_rid()])
		hull = hull or r.hull
		turret = turret or r.turret
	_sc_checks += 1
	if hull or turret:
		_sc_exposed += span
	if hull:
		_sc_hull += span
	elif turret:
		_sc_turret += span


func scenario_summary() -> Dictionary:
	var sc: Dictionary = env.config.scenario
	var me: Tank = env.tanks[0]
	return {"version": ScenarioLayout.VERSION, "id": sc.get("id", ""), "variant": sc.get("variant", ""),
		"goal": sc.get("goal", ""), "objective_reached": _sc_objective,
		"zone_s": snappedf(_sc_zone, 0.01), "exposed_s": snappedf(_sc_exposed, 0.01),
		"hull_exposed_s": snappedf(_sc_hull, 0.01), "turret_only_s": snappedf(_sc_turret, 0.01),
		"hits_taken": _sc_taken.hits, "pens_taken": _sc_taken.pens, "path_m": snappedf(_sc_path, 0.01),
		"status": me.damage.status_label(), "shaping_scale": float(w.get("shaping_scale", 1.0)),
		"best_objective_m": snappedf(_sc_best, 0.01) if _sc_best < INF else -1.0,
		"forward_m": snappedf(_sc_forward, 0.01), "reverse_m": snappedf(_sc_reverse, 0.01),
		"route_remaining_m": snappedf(_sc_route_best, 0.01) if _sc_route_best < INF else -1.0,
		"driving_version": sc.get("driving", {}).get("version", 1),
		"evade_version": sc.get("evade", {}).get("version", 0), "fire_cue_received": _sc_fire_cue,
		"enemy_seen": _sc_enemy_seen,
		"enemy_shots": _sc_enemy_shots, "cover_hold_s": snappedf(_sc_cover_hold, 0.01),
		"longest_cover_s": snappedf(_sc_longest_cover, 0.01),
		"projectiles": env.projectiles.summary() if env.projectiles != null else {},
		"reward_components": _battle_parts.get(str(me.name), {}).duplicate(),
		"relocated": env.config.get("scenario_relocated", [])}


func course_summary() -> Dictionary:
	return {"version": TerrainCourse.VERSION, "course": env.config.terrain_course.id,
		"initial_route_m": snappedf(_course_initial, 0.01), "best_remaining_m": snappedf(_course_best, 0.01),
		"path_m": snappedf(_course_path, 0.01), "checkpoints": _course_checkpoints,
		"checkpoints_total": env.course_route.size() - 1, "hold_s": snappedf(_course_hold, 0.01),
		"reward_components": _course_parts.duplicate()}


func _wp_dist(t: Tank) -> float:
	if env.waypoint == Vector3.INF:
		return 0.0
	var d: Vector3 = env.waypoint - t.global_position
	return Vector2(d.x, d.z).length()


## 1 - (포 방향과 가장 가까운 살아 있는 적 중심 방향의 각도 / π). 적이 없으면 0
func _aim_potential(t: Tank) -> float:
	var best: Tank = null
	var bd := INF
	for o in env.tanks:
		if o.team != t.team and o.damage.is_combat_effective():
			var d: float = o.global_position.distance_to(t.global_position)
			if d < bd:
				bd = d
				best = o
	if best == null:
		return 0.0
	var to: Vector3 = (best.global_position + Vector3.UP * best.spec.hull_top_y() * 0.7) - t.muzzle_position()
	var ang := t.gun_direction().angle_to(to.normalized())
	return 1.0 - ang / PI
