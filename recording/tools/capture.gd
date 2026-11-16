extends SceneTree
## 화면 캡처(문서·보고서 그림용). 그래픽 환경에서 실행:
##   godot --path . -s res://recording/tools/capture.gd -- --scene=res://main.tscn --wait=600 --out=user://shot.png [--ai]
##   godot --path . -s res://recording/tools/capture.gd -- --scene=res://recording/replay_viewer.tscn --t=120 --cam=4 --out=...
##   ... -- --scene=res://main.tscn --view=gunner|commander [--zoom=2] [--look=30]   (게임 시점 캡처)
## --wait = 물리 프레임 수, --t = 리플레이 시각(초), --cam = 리플레이 시점 1~6, --select = 선택 전차, --bigmap

var args := {}
var node: Node
var frames := 0


func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		var kv := a.trim_prefix("--").split("=")
		args[kv[0]] = kv[1] if kv.size() > 1 else "1"
	if args.has("ai"):
		load("res://main.gd").ai_mode = 2


func _process(_d: float) -> bool:
	frames += 1
	if frames == 2:
		node = load(args.get("scene", "res://main.tscn")).instantiate()
		root.add_child(node)
	if frames == 5 and node.has_method("open_replay"):
		node.playing = false
		node.t = float(args.get("t", "0"))
		node.cam_mode = int(args.get("cam", "2")) - 1
		node.selected = int(args.get("select", "0"))
		if args.has("orbit"):
			node.orbit_dist = float(args.orbit)
		if args.has("top"):
			node.top_height = float(args.top)
	if frames == 5 and args.has("bigmap") and "minimap_big" in node:
		node.minimap_big = true
		node._layout_overlay()
	if frames == 5 and args.has("view") and "camera" in node:
		node.camera.capture_mouse = false
		node.camera.set_mode({"gunner": TankViewCamera.GUNNER, "commander": TankViewCamera.COMMANDER}.get(args.view, 0))
		node.camera.cmd_yaw += deg_to_rad(float(args.get("look", "0")))
		node.camera.zoom(int(args.get("zoom", "0")))
	if frames == int(args.get("wait", "30")) + 5:
		var img := root.get_texture().get_image()
		img.save_png(args.get("out", "user://capture.png"))
		print("saved ", ProjectSettings.globalize_path(args.get("out", "user://capture.png")))
		return true
	return false
