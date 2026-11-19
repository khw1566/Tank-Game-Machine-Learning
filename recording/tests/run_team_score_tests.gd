extends SceneTree

var failures := 0
var checks := 0

func check(ok: bool, message: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(message)

func _initialize() -> void:
	var rm := RewardModel.new({"hit": 0.2, "penetration": 8.0, "knockout": 25.0})
	var result := {"hit": true, "penetrated": true, "events": ["knocked_out:ammo_detonation"],
		"damage": [], "distance_m": 100.0, "impact_angle_deg": 0.0, "effective_mm": 40.0,
		"pen_roll_mm": 100.0, "pen_probability": 1.0}
	var rewards := rm.shot_rewards("a", 1, "b", 1, result)
	for reward in rewards:
		check(float(reward.value) < 0, "friendly knockout never pays a positive reward")
	check(rewards[0].reason.begins_with("friendly_"), "friendly reward reason is explicit")
	var d := ReplayData.new()
	d.header = {"tanks": [{"id": 0, "team": 0, "name": "tiger"}, {"id": 1, "team": 1, "name": "a"}, {"id": 2, "team": 1, "name": "b"}]}
	d.shots = [{"tick": 10, "t": 1.0, "shooter": 1, "target": 2, "r": result}]
	d.rewards = [{"tick": 10, "tank": 1, "value": -33.2, "reason": "friendly_hit+penetration+knockout"},
		{"tick": 10, "tank": 1, "value": 200.0, "reason": "win"},
		{"tick": 10, "tank": 1, "value": 1.0, "reason": "closing"}]
	var stats := ReportBuilder._tank_stats(d, 1)
	check(stats.hits == 0 and stats.pens == 0 and stats.kills == 0, "friendly fire excluded from enemy combat stats")
	check(stats.friendly_hits == 1 and stats.friendly_kills == 1, "friendly hits and kills tracked separately")
	var table := ReportBuilder._shot_table(d)
	check(table.contains("아군 오사"), "shot table labels friendly fire")
	check(table.contains("-33.20") and not table.contains("+167.80"), "shot reward excludes coincident win and shaping bonuses")
	var tanks: Array = [{"team": 0}]
	for i in 6:
		tanks.append({"team": 1})
	var label := ReportBuilder.team_score_text(tanks, [200.0, 1200.0])
	check(label.contains("1대, 대당 평균 200.00") and label.contains("6대, 대당 평균 200.00"), "team averages use initial lineup counts")
	for path in OS.get_cmdline_user_args():
		if path.ends_with("events.jsonl"):
			print("REBUILT ", ReportBuilder.build_files(path))
	print("Team score checks: %d, failures: %d" % [checks, failures])
	quit(1 if failures else 0)
