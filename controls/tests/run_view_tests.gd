extends SceneTree
## 시점 카메라(TankViewCamera) 검증(헤드리스).
## 실행: godot --headless --path . -s res://controls/tests/run_view_tests.gd
## 1) 포수 조준경: 카메라가 포구 앞에서 포 방향을 본다, 배율 변경
## 2) 전차장: 해치 높이, 시선을 돌려도 포탑·포가 그대로, 확대, 포탑·포 입력 차단
## 3) 3인칭: 기본 시점은 포 방향, 잠금 없음

var failures := 0
var _frame := 0


func _process(_delta: float) -> bool:
	_frame += 1
	if _frame == 2:
		_run()
	return false


func _run() -> void:
	var map := HillMap.new()
	map.features_enabled = false
	root.add_child(map)
	var t := Tank.new()
	t.setup("tiger1", 0, 1)
	t.position = Vector3(0, map.height_at(0, 0) + 0.5, 0)
	root.add_child(t)
	t.turret_yaw = deg_to_rad(30.0)
	t.gun_pitch = deg_to_rad(3.0)
	t._sync_turret()
	var cam := TankViewCamera.new()
	cam.capture_mouse = false
	cam.map = map
	root.add_child(cam)

	# 3인칭
	cam.update_view(t, 1.0 / 30.0)
	_check(not cam.locks_gun(), "3인칭은 포를 잠그지 않음")
	var fwd := -cam.global_basis.z
	_check(absf(wrapf(cam.view_yaw() - (t.global_rotation.y + t.turret_yaw), -PI, PI)) < 0.01, "3인칭은 포탑 방향을 봄 (%.3f)" % cam.view_yaw())

	# 포수 조준경
	cam.toggle_gunner()
	cam.update_view(t, 1.0 / 30.0)
	fwd = -cam.global_basis.z
	_check(cam.mode == TankViewCamera.GUNNER, "Shift → 포수 조준경")
	_check(fwd.dot(t.gun_direction()) > 0.9999, "조준경 시선 = 포 방향 (dot %.5f)" % fwd.dot(t.gun_direction()))
	_check(cam.global_position.distance_to(t.muzzle_position()) < 0.5, "조준경 위치 = 포구 앞")
	var f0 := cam.fov
	cam.zoom(1)
	cam.update_view(t, 1.0 / 30.0)
	_check(cam.fov < f0 and cam.magnification() > 4.0, "조준경 고배율 x%.1f" % cam.magnification())
	_check(not cam.locks_gun(), "조준경에서는 포 조작 가능")

	# 전차장
	cam.toggle_commander()
	cam.update_view(t, 1.0 / 30.0)
	_check(cam.mode == TankViewCamera.COMMANDER and cam.locks_gun(), "B → 전차장, 포 잠금")
	_check(absf(cam.global_position.y - LineOfSight.eye_position(t).y) < 0.01, "전차장 눈높이 = 해치 위")
	_check(absf(wrapf(cam.view_yaw() - (t.global_rotation.y + t.turret_yaw), -PI, PI)) < 0.01, "전차장은 처음에 포 방향을 봄")
	var yaw0 := t.turret_yaw
	var pitch0 := t.gun_pitch
	cam.cmd_yaw += deg_to_rad(90.0)
	cam.update_view(t, 1.0 / 30.0)
	var c := TankControlInput.new()
	c.turret_traverse = 1.0
	c.gun_elevation = 1.0
	c.left_track = 0.5
	t.control = cam.apply_locks(c)
	for i in 10:
		t.step(1.0 / 30.0)
	_check(absf(wrapf(cam.view_yaw() - (t.global_rotation.y + yaw0), -PI, PI) - deg_to_rad(90.0)) < 0.05, "전차장 시선 90° 회전")
	_check(t.turret_yaw == yaw0 and t.gun_pitch == pitch0, "시선을 돌려도 포탑·포 고정 (%.3f/%.3f)" % [t.turret_yaw, t.gun_pitch])
	_check(t.control.left_track == 0.5, "주행 입력은 그대로")
	for i in 20:
		cam.zoom(1)
	cam.update_view(t, 1.0 / 30.0)
	_check(is_equal_approx(cam.fov, TankViewCamera.COMMANDER_FOV_MIN), "전차장 확대 최대 x%.1f" % cam.magnification())

	# 다시 3인칭
	cam.toggle_commander()
	cam.update_view(t, 1.0 / 30.0)
	_check(cam.mode == TankViewCamera.THIRD and not cam.locks_gun() and is_equal_approx(cam.fov, TankViewCamera.THIRD_FOV), "B 다시 → 3인칭")

	cam.reticle.free()
	print("VIEW TESTS: %s" % ("PASS" if failures == 0 else "%d FAILED" % failures))
	quit(1 if failures else 0)


func _check(ok: bool, what: String) -> void:
	print(("  ok  " if ok else "  FAIL ") + what)
	if not ok:
		failures += 1
