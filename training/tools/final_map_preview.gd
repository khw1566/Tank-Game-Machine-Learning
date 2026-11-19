extends SceneTree
## 최종 1대6 맵 미리보기(문서용). Python 이 만든 맵 JSON 을 읽어 지형·장애물을 놓고 비스듬한 위 시점으로 찍는다.
##   python -c "from tankrl.final_curriculum import dump_maps; dump_maps('maps.json')"   (training/python 에서)
##   godot --path . -s res://training/tools/final_map_preview.gd -- --maps=maps.json --out=dir
var args := {}
var maps: Dictionary
var ids: Array
var idx := 0
var frames := 0
var holder: Node3D


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	maps = JSON.parse_string(FileAccess.get_file_as_string(args.get("maps", "maps.json")))
	ids = maps.keys()
	DirAccess.make_dir_recursive_absolute(args.get("out", "."))


func _build(id: String) -> void:
	if holder:
		holder.free()
	holder = Node3D.new()
	root.add_child(holder)
	var m: Dictionary = maps[id]
	var mc: Dictionary = m.map
	var map := HillMap.new()
	map.map_seed = int(mc.seed)
	map.features_enabled = false
	map.height_amplitude = float(mc.amplitude)
	map.noise_frequency = float(mc.noise_frequency)
	map.size_m = float(mc.size_m)
	map.cell_m = float(mc.cell_m)
	map.ridge_count = 0
	map.custom_ridges = mc.custom_ridges
	map.mounds = mc.mounds
	holder.add_child(map)
	ScenarioLayout.populate(map, {"obstacles": m.obstacles, "learner_type": "tiger1"})
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-50, 30, 0)
	sun.shadow_enabled = true
	holder.add_child(sun)
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color(0.7, 0.8, 0.9)
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color(0.55, 0.55, 0.55)
	holder.add_child(env)
	var cam := Camera3D.new()
	cam.fov = 50
	cam.far = 3000
	holder.add_child(cam)
	cam.global_position = Vector3(0, 430, 470)
	cam.look_at(Vector3(0, 0, 20), Vector3.UP)
	cam.current = true


func _process(_d: float) -> bool:
	frames += 1
	if frames == 2:
		_build(ids[idx])
	if frames == 12:
		var img := root.get_viewport().get_texture().get_image()
		img.save_png("%s/final_map_%d_%s.png" % [args.get("out", "."), idx + 1, ids[idx]])
		idx += 1
		frames = 0
		if idx >= ids.size():
			return true
	return false
