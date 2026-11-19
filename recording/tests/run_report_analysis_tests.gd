extends SceneTree

var failures := 0
var checks := 0

func check(ok: bool, label: String) -> void:
	checks += 1
	if not ok:
		failures += 1
		push_error(label)

func _initialize() -> void:
	var data := ReplayData.new()
	data.header = {"tanks": [{"id": 0, "name": "tiger", "team": 0, "tank": "tiger1", "hull_size": [2, 2, 4], "hull_bottom_y": 1},
		{"id": 1, "name": "sherman", "team": 1, "tank": "sherman75", "hull_size": [2, 2, 4], "hull_bottom_y": 1}]}
	data.shots = [{"tick": 10, "t": 1.0, "shooter": 0, "target": 1, "r": {"hit": true, "entry_local": [0.5, 2, 1]}},
		{"tick": 20, "t": 2.0, "shooter": 0, "target": -1, "r": {"hit": false, "near_miss": {"target_name": "sherman", "local_point": [1, 3, -2], "miss_distance_m": 2.0}}},
		{"tick": 30, "t": 3.0, "shooter": 0, "target": -1, "r": {"hit": false, "near_miss": {"target_name": "sherman"}}}]
	data.rewards = [{"tick": 10, "tank": 0, "value": 8.2, "reason": "hit+penetration"},
		{"tick": 10, "tank": 0, "value": 200, "reason": "win"}, {"tick": 10, "tank": 1, "value": -8, "reason": "took_hit+penetration"}]
	var payload := ShotDistribution.collect(data)
	check(payload.samples.size() == 2 and payload.missing_coordinates == 1, "missing coordinates do not generate fictitious points")
	check(is_equal_approx(payload.samples[0].nx, .5) and is_equal_approx(payload.samples[0].ny, 0) and is_equal_approx(payload.samples[0].nz, .5), "impact coordinates normalized around hull center")
	check(payload.samples[1].nx == 1 and payload.samples[1].ny == 1 and payload.samples[1].nz == -1, "near miss uses exact target-local position")
	check(ShotDistribution.csv_text(payload).split("\n", false).size() == 3, "CSV contains header and all plotted samples")
	data.fields = {"x": 0, "y": 1, "z": 2, "qx": 3, "qy": 4, "qz": 5, "qw": 6}
	data.frames = [{"t": 0.0, "s": [[0, 0, 0, 0, 0, 0, 1], [10, 5, 20, 0, sqrt(.5), 0, sqrt(.5)]]}]
	data.shots.append({"tick": 40, "t": 4.0, "shooter": 0, "target": -1, "r": {"hit": false,
		"near_miss": {"target_name": "sherman", "point": [10, 7, 19]}}})
	var fallback := ShotDistribution.collect(data)
	var last: Dictionary = fallback.samples[-1]
	check(fallback.estimated_coordinates == 1 and is_equal_approx(last.nx, 1) and is_zero_approx(last.ny) and is_zero_approx(last.nz), "legacy world coordinates correctly undo target translation and rotation and flag estimation")
	ShotRewardAnalysis.enrich(data)
	check(is_equal_approx(ShotRewardAnalysis.total(data.shots[0], "tiger"), 8.2), "shot change excludes coincident victory reward")
	check(ShotRewardAnalysis.html(data.shots[0]).contains("추정치"), "legacy reward attribution is labeled as an estimate")
	var event: Dictionary = data.shots[0].duplicate(true)
	event.r.reward_source = "recorded"
	event.r.reward_events = [{"tank": "tiger", "team": 0, "reason": "hit+penetration", "value": 8.2, "before": -2.0, "after": 6.2}]
	var html := ShotImpactReport.page(event, 1)
	check(html.contains("-2.000") and html.contains("6.200") and html.contains("+8.200"), "impact page shows actual before/delta/after")
	check(html.contains(ReportTheme.css()) and html.contains("판정 해설"), "impact page uses shared theme and recorded-physics explanations")
	var csv := ShotDistribution.html(payload)
	check(csv.contains("data-front") and csv.contains("data-top") and csv.contains("전체 발사탄의 명중 확률"), "distribution provides two projections and an explicit probability interpretation")
	print("Report analysis: %d checks, %d failures" % [checks, failures])
	quit(1 if failures else 0)
