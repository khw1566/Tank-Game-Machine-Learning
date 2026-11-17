class_name TankTrackVisual
extends Node3D
## Visual-only tread circulation and road wheels. Never instantiated by headless training.

const LINKS := 48
var tank
var belts := []
var phases := [0.0, 0.0]
var materials := []
var _last_state := ["", ""]


func setup(p_tank) -> void:
	tank = p_tank
	name = "TrackDetail"
	var spec: TankSpec = tank.spec
	for side in 2:
		var sign_x := -1.0 if side == 0 else 1.0
		var links := MultiMesh.new()
		links.transform_format = MultiMesh.TRANSFORM_3D
		var block := BoxMesh.new()
		block.size = Vector3(spec.track_width + .10, .085, perimeter() / LINKS * .80)
		links.mesh = block
		links.instance_count = LINKS
		var belt := MultiMeshInstance3D.new()
		belt.name = "LeftTreads" if side == 0 else "RightTreads"
		belt.multimesh = links
		var material := StandardMaterial3D.new()
		material.albedo_color = Color(.40, .43, .40)
		material.roughness = .85
		material.metallic = .35
		belt.material_override = material
		materials.append(material)
		add_child(belt)
		belts.append(links)
		var radius := spec.track_height * .32
		var wheel_mesh := CylinderMesh.new()
		wheel_mesh.top_radius = radius
		wheel_mesh.bottom_radius = radius
		wheel_mesh.height = .14
		wheel_mesh.radial_segments = 14
		var wheel_mm := MultiMesh.new()
		wheel_mm.transform_format = MultiMesh.TRANSFORM_3D
		wheel_mm.mesh = wheel_mesh
		wheel_mm.instance_count = 8
		var hub_mm := MultiMesh.new()
		hub_mm.transform_format = MultiMesh.TRANSFORM_3D
		var hub := CylinderMesh.new()
		hub.top_radius = radius * .35
		hub.bottom_radius = radius * .35
		hub.height = .17
		hub.radial_segments = 10
		hub_mm.mesh = hub
		hub_mm.instance_count = 8
		for i in 8:
			var z := lerpf(-spec.track_length * .40, spec.track_length * .40, float(i) / 7.0)
			var xf := Transform3D(Basis(Vector3.FORWARD, PI * .5), Vector3(sign_x * (spec.hull_width * .5 + .035), spec.track_height * .5, z))
			wheel_mm.set_instance_transform(i, xf)
			xf.origin.x += sign_x * .035
			hub_mm.set_instance_transform(i, xf)
		for pair in [[wheel_mm, Color(.17, .19, .17)], [hub_mm, Color(.64, .61, .47)]]:
			var node := MultiMeshInstance3D.new()
			node.multimesh = pair[0]
			var mat := StandardMaterial3D.new()
			mat.albedo_color = pair[1]
			node.material_override = mat
			add_child(node)
	update_belts(0.0)


func perimeter() -> float:
	var radius: float = tank.spec.track_height * .45
	return 2.0 * (tank.spec.track_length - radius * 2.0) + TAU * radius


func sample_belt(distance: float) -> Transform3D:
	var radius: float = tank.spec.track_height * .45
	var half: float = tank.spec.track_length * .5 - radius
	var straight := half * 2.0
	var d := fposmod(distance, perimeter())
	var point := Vector3(0, tank.spec.track_height * .5, 0)
	var tangent := Vector2(0, -1)
	if d < straight:
		point += Vector3(0, radius, half - d)
	elif d < straight + PI * radius:
		var angle := (d - straight) / radius
		point += Vector3(0, radius * cos(angle), -half - radius * sin(angle))
		tangent = Vector2(-sin(angle), -cos(angle))
	elif d < straight * 2.0 + PI * radius:
		point += Vector3(0, -radius, -half + d - straight - PI * radius)
		tangent = Vector2(0, 1)
	else:
		var angle := (d - straight * 2.0 - PI * radius) / radius
		point += Vector3(0, -radius * cos(angle), half + radius * sin(angle))
		tangent = Vector2(sin(angle), cos(angle))
	return Transform3D(Basis(Vector3.RIGHT, atan2(-tangent.x, tangent.y)), point)


func _process(delta: float) -> void:
	update_belts(delta)


func update_belts(delta: float) -> void:
	if not is_instance_valid(tank):
		return
	for side in 2:
		var speed: float = tank.track_speed_left if side == 0 else tank.track_speed_right
		var state: String = tank.damage.modules.get("track_left" if side == 0 else "track_right", "ok")
		if delta > 0 and absf(speed) < .001 and state == _last_state[side]:
			continue
		_last_state[side] = state
		phases[side] = fposmod(phases[side] + (speed * delta if state != "destroyed" else 0.0), perimeter())
		materials[side].albedo_color = Color(.53, .16, .09) if state == "destroyed" else Color(.75, .45, .13) if state == "damaged" else Color(.40, .43, .40)
		for i in LINKS:
			var xf := sample_belt(perimeter() * i / LINKS + phases[side])
			xf.origin.x = (-1.0 if side == 0 else 1.0) * (tank.spec.hull_width * .5 - tank.spec.track_width * .5)
			belts[side].set_instance_transform(i, xf)
