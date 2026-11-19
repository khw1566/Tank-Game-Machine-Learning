extends SceneTree
## -- --run=<training run directory> --out=<aggregate output directory>

var all_samples: Array = []
var missing := 0
var estimated := 0
var shots := 0
var seen := {}
var rebuilt := 0

func visit(path: String) -> void:
	var directory := DirAccess.open(path)
	if directory == null: return
	for name in directory.get_files():
		if name != "events.jsonl": continue
		var file := path.path_join(name)
		var data := ReplayData.load_file(file)
		if not data.ok() or data.end.is_empty(): continue
		var report := ReportBuilder.build_data(data)
		if report.is_empty(): continue
		rebuilt += 1
		print("Rebuilt ", rebuilt, ": ", path.get_file())
		var uid := str(data.header.get("meta", {}).get("training", {}).get("uid", file))
		if seen.has(uid): continue
		seen[uid] = true
		var payload := ShotDistribution.collect(data)
		for row in payload.samples:
			row["episode_uid"] = uid
			row["report"] = report
			all_samples.append(row)
		missing += int(payload.missing_coordinates)
		estimated += int(payload.estimated_coordinates)
		shots += int(payload.shots_total)
	for name in directory.get_directories():
		if name not in ["opponents", "tiger1", "sherman75", "t34_76", "shared", "sb3", "analysis", "impacts"]:
			visit(path.path_join(name))

func write(path: String, value: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file: file.store_string(value)

func _initialize() -> void:
	var run := ""
	var out := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--run="): run = arg.trim_prefix("--run=")
		if arg.begins_with("--out="): out = arg.trim_prefix("--out=")
	if run.is_empty() or out.is_empty():
		push_error("--run and --out are required")
		quit(1)
		return
	visit(run)
	DirAccess.make_dir_recursive_absolute(out)
	var payload := {"samples": all_samples, "missing_coordinates": missing, "estimated_coordinates": estimated, "shots_total": shots, "episodes": seen.size()}
	write(out.path_join("shot_distribution.json"), JSON.stringify(payload))
	write(out.path_join("shot_distribution.csv"), ShotDistribution.csv_text(payload))
	write(out.path_join("report.html"), "<!doctype html><html lang='ko'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>명중·지근탄 통합 분석</title><style>" + ReportTheme.css() + "</style></head><body><h1>명중·지근탄 통합 분석</h1><p class='meta'>완료된 리플레이 %d개에서 에피소드 UID 기준으로 중복을 제거한 %d경기 · 동일 경기의 재현본은 한 번만 집계합니다.</p>" % [rebuilt, seen.size()] + ShotDistribution.html(payload) + "</body></html>")
	print("Rebuilt %d reports; %d unique episodes, %d samples (%d estimated), %d missing; output=%s" % [rebuilt, seen.size(), all_samples.size(), estimated, missing, out])
	quit()
