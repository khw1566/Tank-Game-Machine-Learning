class_name ImpactView
extends Control
## A visual snapshot approached along the shell's arrival direction. No gameplay entities leak into the world.

var viewport: SubViewport
var camera: Camera3D
var scene: Node3D
var caption := "사격하면 탄착 위치를 표시합니다"
var age := 10.0
var focus := Vector3.ZERO
var direction := Vector3.FORWARD
var hit_color := Color.WHITE
var active := false
var _render_frozen := false
const ZONES := {"hull_front_upper": "차체 전면 상부", "hull_front_lower": "차체 전면 하부",
	"hull_side_upper": "차체 측면 상부", "hull_side_lower": "차체 측면 하부", "hull_rear": "차체 후면",
	"hull_top": "차체 상판", "hull_bottom": "차체 하부", "turret_front": "포탑 전면", "turret_side": "포탑 측면",
	"turret_rear": "포탑 후면", "turret_top": "포탑 상판", "mantlet": "포방패", "gun_barrel": "포신", "track": "궤도"}


static func zone_label(result: Dictionary) -> String:
	var label: String = ZONES.get(result.get("zone", ""), "장갑 명중")
	if result.has("track_hit"):
		label = ("좌측 궤도" if result.track_hit == "track_left" else "우측 궤도") + " → " + label
	return label


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true
	viewport = SubViewport.new()
	viewport.size = Vector2i(480, 270)
	viewport.own_world_3d = true
	viewport.disable_3d = false
	viewport.gui_disable_input = true
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(viewport)
	var picture := TextureRect.new()
	picture.texture = viewport.get_texture()
	picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	picture.stretch_mode = TextureRect.STRETCH_SCALE
	picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(picture)
	resized.connect(func():
		picture.position = Vector2(2, 27)
		picture.size = Vector2(size.x - 4, maxf(20, size.y - 70)))
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("17212a")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(.8, .85, .9)
	env.environment.ambient_light_energy = .7
	viewport.add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -25, 0)
	light.light_energy = 1.5
	viewport.add_child(light)
	camera = Camera3D.new()
	camera.fov = 46
	camera.near = .05
	viewport.add_child(camera)
	camera.current = true


func show_shot(result: Dictionary, target: Tank = null, muzzle_speed := 700.0) -> void:
	if not result.has("hit_pos"):
		return
	if scene:
		scene.free()
	scene = Node3D.new()
	viewport.add_child(scene)
	var point := ReplayData.vec3(result.hit_pos)
	focus = point - target.global_position if target else Vector3.ZERO
	direction = (ReplayData.vec3(result.get("dir", [0, 0, -1])) * muzzle_speed + Vector3.DOWN * 9.8 * float(result.get("flight_time_s", 0.0))).normalized()
	if direction.length_squared() < .1:
		direction = Vector3.FORWARD
	var kind := MatchRecorder.shot_kind(result)
	hit_color = MinimapView.KIND_COLORS.get(kind, Color.WHITE)
	if target:
		var clone := Tank.new()
		clone.visuals_enabled = true
		clone.setup(target.spec.id, target.team, 1)
		clone.remove_from_group(Tank.GROUP)
		scene.add_child(clone)
		clone.apply_replay_pose(Transform3D(target.global_basis, Vector3.ZERO), target.turret_yaw, target.gun_pitch, false)
		# Highlight the actual struck part without changing armor or damage calculations.
		var part := str(result.get("track_hit", result.get("part", "")))
		var geometry := target.shape.get_part(part)
		if not geometry.is_empty():
			var highlight := clone._mesh_from_faces(geometry.faces, hit_color)
			clone.hit_attachment(part).add_child(highlight)
			highlight.scale *= 1.002
			var mat := highlight.material_override as StandardMaterial3D
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = .28
		var outcome := "관통" if result.get("penetrated", false) else "도탄" if result.get("ricochet", false) else "불관통"
		caption = "%s · %s\n%s" % [target.spec.display_name, outcome, zone_label(result)]
	else:
		var floor := MeshInstance3D.new()
		var plane := PlaneMesh.new()
		plane.size = Vector2(30, 30)
		floor.mesh = plane
		scene.add_child(floor)
		caption = "장애물 탄착 · %s" % result.get("blocked_by", "terrain")
	var marker := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = .13
	sphere.height = .26
	marker.mesh = sphere
	marker.position = focus - direction * .05
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = hit_color
	material.no_depth_test = true
	marker.material_override = material
	scene.add_child(marker)
	age = 0.0
	active = true
	_render_frozen = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_update_camera()
	queue_redraw()


func _update_camera() -> void:
	var progress := smoothstep(0, 1, minf(age / .9, 1.0))
	var distance := lerpf(18.0, 4.2, progress)
	camera.position = focus - direction * distance
	var up := Vector3.UP if absf(direction.dot(Vector3.UP)) < .98 else Vector3.RIGHT
	camera.look_at(focus, up)


func _process(delta: float) -> void:
	if not active:
		return
	age += delta
	if is_visible_in_tree():
		_update_camera()
		if age < 1.1:
			viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		elif not _render_frozen:
			viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
			_render_frozen = true
		else:
			viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	else:
		viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_render_frozen = false


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("111a22"))
	draw_rect(Rect2(Vector2.ZERO, size), hit_color.darkened(.4) if active else Color("49545e"), false, 1)
	var font := get_theme_default_font()
	draw_string(font, Vector2(9, 18), "탄착 카메라 · 포탄 진행 시점", HORIZONTAL_ALIGNMENT_LEFT, size.x - 18, 13, Color("e5e9ed"))
	var lines := caption.split("\n")
	for i in mini(lines.size(), 2):
		draw_string(font, Vector2(8, size.y - 26 + i * 16), lines[i], HORIZONTAL_ALIGNMENT_LEFT, size.x - 16, 12, hit_color if active else Color.GRAY)
