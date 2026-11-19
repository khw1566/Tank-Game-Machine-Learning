extends SceneTree

var failures := 0
var checks := 0


func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
	print("PASS " if ok else "FAIL ", label)


func shot(target: TankSpec, gun: GunSpec, distance: float, bearing: float, low := false, mantlet := false, seed_value := 1) -> Dictionary:
	var aim := Vector3(0, target.hull_bottom_y + (target.hull_roof_y - target.hull_bottom_y) * (0.2 if low else 0.75), 0)
	if mantlet:
		aim = target.turret_origin() + Vector3(target.mantlet_size.x * 0.3, target.gun_height, 0)
	var angle := deg_to_rad(bearing)
	var origin := aim + Vector3(sin(angle), 0, -cos(angle)) * 60
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return DamageModel.resolve_shot(TankDamageState.new(target), 0, origin, (aim - origin).normalized(), distance, gun, rng)


func _init() -> void:
	var tiger := TankDatabase.tiger1()
	var summary := []
	for attacker in [TankDatabase.sherman75(), TankDatabase.t34_76()]:
		for gun in attacker.ammo_types.slice(0, 2):
			for distance in [50.0, 100.0, 250.0, 500.0]:
				for low in [false, true]:
					var front := shot(tiger, gun, distance, 0, low)
					var angled := shot(tiger, gun, distance, 35, low)
					check(front.hit and float(front.pen_probability) >= 0.95,
						"%s %s %.0fm front %s p=%.3f" % [attacker.id, gun.shell_type, distance, "lower" if low else "upper", front.pen_probability])
					check(angled.hit and float(angled.pen_probability) <= 0.01,
						"%s %s %.0fm 35deg %s p=%.3f" % [attacker.id, gun.shell_type, distance, "lower" if low else "upper", angled.pen_probability])
					summary.append({"attacker": attacker.display_name, "shell": gun.shell_type, "distance_m": distance,
						"low": low, "front_p": front.pen_probability, "angled_p": angled.pen_probability,
						"front_zone": front.zone, "angled_zone": angled.zone})
			var mask := shot(tiger, gun, 100, 0, false, true)
			check(mask.zone == "mantlet" and mask.pen_probability < 0.01, "Tiger mantlet blocks allied shell: " + gun.id)
		var self_hit := shot(attacker, attacker.gun, 200, 0)
		check(float(self_hit.pen_probability) > 0.6, "Self-play frontal penetration available: " + attacker.id)
	check(TankDatabase.t34_76().gun.caliber_mm == 85 and not TankDatabase.t34_76().commander_is_gunner, "T-34-85 gun and separate commander/gunner")
	check(TankDatabase.sherman75().gun.caliber_mm == 76.2, "Sherman long 76mm")
	var progress := CombatProgress.new({"near_pen_budget": 4.0, "near_miss_budget": 3.0})
	check(not progress.pressure_active("a", 1), "No immediate charge bonus")
	var weak := {"hit": true, "penetrated": false, "effective_mm": 100, "pen_mean_mm": 40}
	check(progress.shot("a", "b", weak, 1).is_empty(), "Hopeless armor hits do not earn near-penetration reward")
	var close := {"hit": true, "penetrated": false, "effective_mm": 100, "pen_mean_mm": 90}
	var bonus := progress.shot("a", "b", close, 2)
	check(not bonus.is_empty() and bonus[0].value > 0, "Near penetration earns intermediate reward")
	check(progress.shot("a", "b", close, 3).is_empty(), "Repeated identical bounce cannot farm reward")
	check(progress.pressure_active("a", 3), "Repeated failure unlocks closing reward")
	progress.shot("a", "b", {"penetrated": true}, 4)
	check(not progress.pressure_active("a", 5), "Useful damage disables forced approach")
	check(progress.pressure_active("a", 25), "20 seconds without useful damage unlocks approach")
	var near := {"target_name": "b", "range_m": 150, "miss_distance_m": 1, "penetration_ratio": 0.95}
	check(progress.near_miss("a", near) > 0, "Armor-aware near miss earns reward")
	check(progress.near_miss("a", near) == 0, "Repeated identical near miss cannot farm reward")
	for i in 20:
		progress.shot("a", str(i), close, 30)
		near.target_name = str(i)
		progress.near_miss("a", near)
	check(float(progress.pen_paid.a) <= 4.00001 and float(progress.miss_paid.a) <= 3.00001, "Per-episode auxiliary budgets enforced")
	var directory := ProjectSettings.globalize_path("res://_sync/balance_v2_checks")
	DirAccess.make_dir_recursive_absolute(directory)
	var file := FileAccess.open(directory + "/calibration.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "  "))
	file.close()
	var target := Tank.new()
	target.setup("tiger1", 1, 1)
	var gun := TankDatabase.sherman75().gun
	var events := []
	for mantlet in [false, true]:
		var result := shot(tiger, gun, 200, 0, false, mantlet, 11)
		result["impact_snapshot"] = ShotImpactReport.capture(target)
		events.append({"type": "shot", "tick": events.size() * 30, "t": events.size() + 1,
			"shooter": 0, "target": 1, "r": result})
	ShotImpactReport.write_assets(directory, events)
	var data := ReplayData.new()
	data.header = {"tanks": [{"name": "Sherman 76", "display_name": "Sherman 76", "team": 0},
		{"name": "Tiger I", "display_name": "Tiger I", "team": 1}]}
	data.shots = events
	var table := ReportBuilder._shot_table(data)
	check(table.contains("impacts/shot_0001.html"), "Hit row links to its recorded simulation")
	var gallery := ShotImpactReport.gallery(events)
	check(gallery.contains("data:image/svg+xml;base64,"), "Report embeds an analysis image")
	check(FileAccess.file_exists(directory + "/impacts/shot_0001.svg"), "Standalone annotated SVG saved")
	file = FileAccess.open(directory + "/report_preview.html", FileAccess.WRITE)
	file.store_string("<!doctype html><html lang='ko'><meta charset='utf-8'><title>Balance v2 impact preview</title><style>" + ReportBuilder._css() + "</style><h1>타격 보고서 검증</h1>" + table + gallery + "</html>")
	file.close()
	target.free()
	print("%d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
