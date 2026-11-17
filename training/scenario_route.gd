class_name ScenarioRoute
extends RefCounted
## Reward-only visibility graph around tank-sized, rotated obstacle footprints.
## It never supplies a waypoint or a route to the policy.

var boxes: Array = []
var nodes: Array[Vector2] = []
var distances: Array[float] = []


func _init(sc: Dictionary, spec: TankSpec) -> void:
	var goal: Array = sc.objective.p
	nodes.append(Vector2(goal[0], goal[1]))
	var margin := Vector2(spec.hull_width, spec.hull_length).length() * 0.5 + 0.5
	for obstacle in sc.get("obstacles", []):
		if obstacle.get("type", "stone") != "stone":
			continue
		var p: Array = obstacle.p
		var size: Array = obstacle.size
		var box := {"center": Vector2(p[0], p[1]), "half": Vector2(size[0], size[2]) * 0.5 + Vector2.ONE * margin,
			"yaw": float(obstacle.get("yaw", 0.0))}
		boxes.append(box)
	for box in boxes:
		for sx in [-1, 1]:
			for sz in [-1, 1]:
				var corner: Vector2 = Vector2(sx, sz) * (box.half + Vector2.ONE * 0.05)
				nodes.append(box.center + corner.rotated(-box.yaw))
	distances.resize(nodes.size())
	distances.fill(INF)
	distances[0] = 0.0
	var visited := {}
	for iteration in nodes.size():
		var nearest := -1
		var best := INF
		for i in nodes.size():
			if not visited.has(i) and distances[i] < best:
				nearest = i
				best = distances[i]
		if nearest < 0:
			break
		visited[nearest] = true
		for j in nodes.size():
			if not visited.has(j) and clear(nodes[nearest], nodes[j]):
				distances[j] = minf(distances[j], best + nodes[nearest].distance_to(nodes[j]))


func clear(a: Vector2, b: Vector2) -> bool:
	for box in boxes:
		var start: Vector2 = (a - box.center).rotated(box.yaw)
		var delta: Vector2 = (b - a).rotated(box.yaw)
		var enter := 0.0
		var leave := 1.0
		var intersects := true
		for axis in 2:
			if absf(delta[axis]) < 0.000001:
				if absf(start[axis]) >= box.half[axis]:
					intersects = false
					break
			else:
				var t1: float = (-box.half[axis] - start[axis]) / delta[axis]
				var t2: float = (box.half[axis] - start[axis]) / delta[axis]
				enter = maxf(enter, minf(t1, t2))
				leave = minf(leave, maxf(t1, t2))
				if enter >= leave:
					intersects = false
					break
		if intersects:
			return false
	return true


func remaining(position: Vector3) -> float:
	var p := Vector2(position.x, position.z)
	var best := INF
	for i in nodes.size():
		if distances[i] < INF and clear(p, nodes[i]):
			best = minf(best, p.distance_to(nodes[i]) + distances[i])
	return best
