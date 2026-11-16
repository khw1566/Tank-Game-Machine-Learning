extends SceneTree
## 기록에서 보고서를 다시 만든다(보고서 양식을 고친 뒤 지난 경기에 다시 적용할 때).
##   godot --headless --path . -s res://recording/tools/make_report.gd -- <events.jsonl 또는 그 폴더> [...]
##   godot --headless --path . -s res://recording/tools/make_report.gd -- --all      (user://logs/replays 전체)


func _initialize() -> void:
	var targets := []
	for a in OS.get_cmdline_user_args():
		if a == "--all":
			var da := DirAccess.open("user://logs/replays")
			if da:
				for d in da.get_directories():
					targets.append("user://logs/replays/%s/events.jsonl" % d)
		elif a.ends_with(".jsonl"):
			targets.append(a)
		else:
			targets.append(a.path_join("events.jsonl"))
	if targets.is_empty():
		print("사용법: -- <events.jsonl|폴더> ... 또는 -- --all")
	for p in targets:
		var out := ReportBuilder.build_files(p, "user://logs/episodes.csv")
		print(("OK  " + out) if out != "" else ("실패 " + p))
	quit()
