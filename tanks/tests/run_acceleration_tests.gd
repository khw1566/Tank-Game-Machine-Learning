extends SceneTree
## Flat-ground acceleration and drivetrain regression checks. -- --baseline only records old timings.

const DT := 1.0 / 30.0
const IDS := ["tiger1", "sherman75", "t34_76"]
var checks := 0
var failures := 0
var ran := false


func _initialize() -> void:
	var ground := StaticBody3D.new()
	ground.collision_layer = Tank.LAYER_GROUND
	var collision := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(10000, 1, 10000)
	collision.shape = box
	ground.add_child(collision)
	ground.position.y = -0.5
	root.add_child(ground)


func check(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures += 1
	print("PASS " if condition else "FAIL ", message)


func make_tank(id: String, x: float) -> Tank:
	var tank := Tank.new()
	tank.name = "%s_%d" % [id, root.get_child_count()]
	tank.setup(id, 0, 1234)
	tank.position = Vector3(x, 0, 0)
	root.add_child(tank)
	tank.set_physics_process(false)
	return tank


func measure(id: String, x: float, direction: float) -> Dictionary:
	var tank := make_tank(id, x)
	var target := tank.spec.sustained_speed_kmh(0.0) if direction > 0 else tank.spec.max_reverse_kmh
	var t10 := -1.0
	var t95 := -1.0
	var peak := 0.0
	var shifts := 0
	var previous_gear := tank.gear_index
	tank.control = TankControlInput.from_array([direction, direction, 0, 0, 0, 0])
	for tick in int(45.0 / DT):
		tank.step(DT)
		var speed := tank.forward_speed() * direction * 3.6
		peak = maxf(peak, speed)
		if t10 < 0 and speed >= 10.0:
			t10 = (tick + 1) * DT
		if t95 < 0 and speed >= target * 0.95:
			t95 = (tick + 1) * DT
		if tank.gear_index != previous_gear:
			shifts += 1
			previous_gear = tank.gear_index
	var result := {"tank": id, "direction": direction, "target_kmh": target,
		"t10_s": t10, "t95_s": t95, "peak_kmh": peak, "shifts": shifts}
	print("ACCEL_RESULT ", JSON.stringify(result))
	check(t95 > 0, "%s reaches 95%% of %s top speed" % [id, "forward" if direction > 0 else "reverse"])
	check(peak <= target + 0.15, "%s top-speed limit remains %.1f km/h" % [id, target])
	if direction > 0:
		check(shifts > 0, "%s automatic upshifts remain active" % id)
	if not "--baseline" in OS.get_cmdline_user_args():
		check(t95 <= 10.0, "%s reaches 95%% top speed within 10s (%.2fs)" % [id, t95])
	# Braking and track damage must still override the faster drivetrain.
	tank.control = TankControlInput.from_array([0, 0, 1, 0, 0, 0])
	for tick in int(4.0 / DT):
		tank.step(DT)
	check(absf(tank.forward_speed()) < 0.01, "%s full brake stops the tank" % id)
	tank.damage.modules.track_left = TankDamageState.MOD_DESTROYED
	tank.control = TankControlInput.from_array([1, 1, 0, 0, 0, 0])
	for tick in int(2.0 / DT):
		tank.step(DT)
	check(absf(tank.track_speed_left) < 0.01, "%s destroyed left track receives no drive" % id)
	tank.free()
	return result


func _physics_process(_delta: float) -> bool:
	if ran:
		return true
	ran = true
	for i in IDS.size():
		measure(IDS[i], i * 100.0, 1.0)
		measure(IDS[i], i * 100.0 + 40.0, -1.0)
	print("Acceleration tests: %d checks, %d failures" % [checks, failures])
	for child in root.get_children():
		child.free()
	quit(1 if failures else 0)
	return true
