class_name MapDestruction
extends RefCounted
## Individual shapes remain in grouped bodies; stable journal IDs survive replay and seeking.

const STRENGTH := {"tree": 25.0, "wall": 100.0, "hedge": 12.0}
var map
var items := {}
var current := -1
var _replay_key := ""


func _init(p_map) -> void:
	map = p_map


func clear() -> void:
	items.clear()
	current = -1
	_replay_key = ""


func begin(kind: String, shape: CollisionShape3D, id: int) -> void:
	current = -1
	if not STRENGTH.has(kind):
		return
	current = id
	shape.set_meta("obstacle_id", id)
	items[id] = {"kind": kind, "shape": shape, "hp": STRENGTH[kind], "visuals": [], "foliage": []}


func visual(journal_id: int) -> void:
	if current >= 0:
		items[current].visuals.append(journal_id)


func foliage(volume: Dictionary, shape: CollisionShape3D) -> void:
	if current < 0:
		return
	var kind: String = items[current].kind
	if (kind == "tree" and volume.type == "crown") or (kind == "hedge" and volume.type == "hedge"):
		items[current].foliage.append([volume, shape])


func id_for(collider: Object, shape_index: int) -> int:
	if not collider is CollisionObject3D or not collider.has_meta("hill_map") or collider.get_meta("hill_map") != map:
		return -1
	var owner: int = collider.shape_find_owner(shape_index)
	var node: Object = collider.shape_owner_get_owner(owner)
	return int(node.get_meta("obstacle_id", -1)) if node else -1


func damage(collider: Object, shape_index: int, energy_kj: float, source: String) -> Dictionary:
	var id := id_for(collider, shape_index)
	if id < 0 or energy_kj <= 0.0:
		return {}
	var item: Dictionary = items[id]
	var was_destroyed: bool = item.hp <= 0.0
	item.hp = maxf(0.0, float(item.hp) - energy_kj)
	if item.hp <= 0.0 and not was_destroyed:
		_set_destroyed(id, true)
		map.obstacle_destroyed.emit({"id": id, "kind": item.kind, "source": source})
	return {"id": id, "kind": item.kind, "hp": snappedf(float(item.hp), 0.001), "destroyed": item.hp <= 0.0}


func destroyed_ids() -> Array:
	var ids := []
	for id in items:
		if items[id].hp <= 0.0:
			ids.append(id)
	ids.sort()
	return ids


func damage_state() -> Array:
	var state := []
	var ids: Array = items.keys()
	ids.sort()
	for id in ids:
		if float(items[id].hp) < float(STRENGTH[items[id].kind]):
			state.append([id, snappedf(float(items[id].hp), 0.001)])
	return state


func reset() -> void:
	for id in items:
		if float(items[id].hp) < float(STRENGTH[items[id].kind]):
			_set_destroyed(id, false)
		items[id].hp = STRENGTH[items[id].kind]
	map.foliage_clearings.clear()


func set_destroyed(ids: Array) -> void:
	var key := JSON.stringify(ids)
	if key == _replay_key:
		return
	var requested := {}
	for id in ids:
		requested[int(id)] = true
	for id in items:
		var destroyed := requested.has(id)
		if (float(items[id].hp) <= 0.0) != destroyed:
			_set_destroyed(id, destroyed)
			items[id].hp = 0.0 if destroyed else STRENGTH[items[id].kind]
	_replay_key = key


func _set_destroyed(id: int, destroyed: bool) -> void:
	_replay_key = ""
	var item: Dictionary = items[id]
	item.shape.disabled = destroyed
	for entry in item.foliage:
		entry[0]["destroyed"] = destroyed
		entry[1].disabled = destroyed
	for journal_id in item.visuals:
		if not map._visual_refs.has(journal_id):
			continue
		var ref: Array = map._visual_refs[journal_id]
		var xf: Transform3D = map._journal[journal_id][2]
		if destroyed:
			xf.basis = Basis.from_scale(Vector3.ZERO)
		map._mm[ref[0]][ref[1]] = xf
		if map._mm_nodes.has(ref[0]):
			map._mm_nodes[ref[0]].multimesh.set_instance_transform(int(ref[1]), xf)
	if item.kind == "tree":
		map.foliage_clearings = map.foliage_clearings.filter(func(h): return int(h.id) != id)
		if destroyed:
			var pos: Vector3 = item.shape.position
			map.foliage_clearings.append({"id": id, "c": Vector2(pos.x, pos.z), "r": 3.5})
