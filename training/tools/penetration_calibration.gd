extends SceneTree
## 연합군 주포 → 티거 관통확률 표(거리 × 방위 × 조준 부위). 관통력 표를 바꿔 보며 균형을 맞출 때 쓴다.
## 실행: godot --headless --path . -s res://training/tools/penetration_calibration.gd -- [--table=<JSON>] [--sigma=0.04] [--shooter=sherman75]
##   --table : 수직 관통력 표 [[거리m, mm], ...] (생략하면 현재 제원 그대로)
## DamageModel.resolve_shot 의 pen_probability 를 그대로 쓴다(tanks/tests/run_tank_tests.gd 와 같은 규칙).

const BEARINGS := [0, 15, 30, 45, 60, 75, 90, 135, 180]
const DISTANCES := [100, 250, 400, 600, 1000]
var detail := false


func _init() -> void:
	var opts := {}
	for a in OS.get_cmdline_user_args():
		var kv := str(a).trim_prefix("--").split("=", true, 1)
		opts[kv[0]] = kv[1] if kv.size() > 1 else "1"
	detail = opts.has("detail")
	var tiger := TankDatabase.tiger1()
	var shooter: TankSpec = TankDatabase.get_spec(opts.get("shooter", "sherman75"))
	var gun: GunSpec = shooter.gun
	if opts.has("table"):
		gun.penetration_table_30deg = TankDatabase._training_pen_table(JSON.parse_string(opts.table))
	if opts.has("sigma"):
		gun.penetration_sigma = float(opts.sigma)
	print("# %s → Tiger I, sigma %.3f, 표(30° 기준) %s" % [gun.display_name, gun.penetration_sigma, JSON.stringify(gun.penetration_table_30deg)])
	var out := {}
	for where in ["hull_high", "hull_low", "turret"]:
		print("\n## %s  (방위 = 티거 정면 기준 사수 각도)" % where)
		print("거리 | " + " | ".join(BEARINGS.map(func(b): return "%d°" % b)))
		var table := {}
		for d in DISTANCES:
			var vals := []
			for b in BEARINGS:
				vals.append(snappedf(_pen(tiger, gun, d, b, where), 0.001))
			table[str(d)] = vals
			print("%dm | %s" % [d, " | ".join(vals.map(func(p): return "%3.0f%%" % (p * 100.0)))])
		out[where] = table
	print("\nJSON " + JSON.stringify({"bearings": BEARINGS, "matrix": out}))
	quit(0)


func _pen(target: TankSpec, gun: GunSpec, dist: float, bearing: float, where: String) -> float:
	var hh := target.hull_roof_y - target.hull_bottom_y
	var aim := Vector3(0, target.hull_bottom_y + hh * 0.75, 0)
	if where == "hull_low":
		aim = Vector3(0, target.hull_bottom_y + hh * 0.2, 0)
	elif where == "turret":
		aim = target.turret_origin() + Vector3(0, target.turret_height * 0.93, 0)
	var b := deg_to_rad(bearing)
	var origin := aim + Vector3(sin(b), 0.0, -cos(b)) * 60.0
	var rng := RandomNumberGenerator.new()
	var res := DamageModel.resolve_shot(TankDamageState.new(target), 0.0, origin, (aim - origin).normalized(), dist, gun, rng)
	if detail and res.hit and dist == 250:
		print("   %s %d°: zone %s, 입사 %.0f°, 유효 %.0fmm, 판 %.0fmm, p %.2f" % [where, bearing, res.zone, res.impact_angle_deg, res.effective_mm, res.plate_mm, res.pen_probability])
	return float(res.pen_probability) if res.hit else 0.0
