class_name ShotImpactReport
extends RefCounted
## Capture actual impact geometry, then export an offline image and recorded-impact replay.
## The replay keeps the recorded random outcome; it does not roll a different penetration result.


static func effective(result: Dictionary) -> bool:
	return bool(result.get("hit", false)) and bool(result.get("target_was_combat_effective", true))


static func capture(target: Tank) -> Dictionary:
	var faces := []
	for part in target.shape.parts:
		var transform := target.shape.frame_transform(str(part.frame), target.turret_yaw, target.gun_pitch)
		for face in part.faces:
			var points := []
			for point in face.points:
				points.append(TankSpec._v(transform * point))
			faces.append({"part": part.name, "zone": face.zone, "points": points,
				"normal": TankSpec._v(transform.basis * face.normal)})
	var internals := []
	for item in target.spec.crew + target.spec.modules:
		var point: Vector3 = item.pos
		if item.in_turret:
			point = HitGeometry.turret_to_hull(target.spec, target.turret_yaw, point)
		internals.append({"id": item.id, "point": TankSpec._v(point)})
	return {"version": 1, "balance_version": target.spec.balance_version, "name": target.spec.display_name,
		"turret_yaw": target.turret_yaw, "gun_pitch": target.gun_pitch, "faces": faces, "internals": internals}


static func _esc(value) -> String:
	return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


static func _damage_name(id: String) -> String:
	return {"commander": "전차장", "gunner": "포수", "loader": "장전수", "driver": "조종수", "radio": "무전수",
		"engine": "엔진", "transmission": "변속기", "fuel": "연료통", "fuel_l": "좌 연료통", "fuel_r": "우 연료통",
		"ammo_l": "좌 탄약고", "ammo_r": "우 탄약고", "ammo_floor": "하부 탄약고", "gun_mount": "고저장치",
		"recoil": "주퇴기", "gun_breech": "포미", "sight": "조준경", "traverse_drive": "선회장치",
		"turret_ring": "포탑 링", "gun_barrel": "포신", "track_left": "좌 궤도", "track_right": "우 궤도"}.get(id, id)


static func _state_name(state: String) -> String:
	return {"ok": "정상", "operational": "정상", "wounded": "부상", "kia": "전사", "damaged": "손상", "destroyed": "파괴",
		"knocked_out": "전투불능", "bailed_out": "탈출"}.get(state, state)


static func _text(x: float, y: float, value, size := 16, color := "#17324d") -> String:
	return "<text x='%s' y='%s' font-size='%s' fill='%s'>%s</text>" % [x, y, size, color, _esc(value)]


static func _project(point: Vector3, basis: Basis) -> Vector2:
	return Vector2(250 + point.dot(basis.x) * 42, 347 - point.dot(basis.y) * 42)


static func _pair(point: Vector2) -> String:
	return "%.2f,%.2f" % [point.x, point.y]


static func svg(event: Dictionary, index: int) -> String:
	var r: Dictionary = event.r
	var snapshot: Dictionary = r.get("impact_snapshot", {})
	var entry := ReplayData.vec3(r.get("entry_local", [0, 1, 0]))
	var has_point: bool = r.get("entry_local", []).size() == 3
	var has_ray: bool = r.get("ray_dir_local", []).size() == 3
	var direction := ReplayData.vec3(r.get("ray_dir_local", [0, 0, 1])).normalized()
	if direction.length_squared() < 0.5:
		direction = Vector3.BACK
	var side := (-direction).cross(Vector3.UP).normalized()
	var view := (-direction + Vector3.UP * 0.55 + side * 0.35).normalized()
	var right := view.cross(Vector3.UP).normalized()
	if right.length_squared() < 0.5:
		right = Vector3.RIGHT
	var basis := Basis(right, right.cross(view).normalized(), view)
	var color := "#16796c" if r.get("penetrated", false) else "#9a660f"
	var verdict := "관통" if r.get("penetrated", false) else "도탄" if r.get("ricochet", false) else "비관통"
	var out := PackedStringArray(["<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 1000 560' role='img' aria-label='기록된 타격 지점과 피해 분석'>",
		"<rect width='1000' height='560' fill='#fff'/><g font-family='Malgun Gothic,Arial,sans-serif'>"])
	out.append(_text(28, 36, "타격 #%d · %s · %s" % [index, snapshot.get("name", r.get("target", "표적")), verdict], 23, color))
	out.append(_text(28, 64, "%s  /  거리 %.1fm  /  기록 시각 %.2fs" % [r.get("shell", "탄종 미기록"),
		float(r.get("distance_m", 0)), float(event.get("t", 0))], 16))
	out.append("<rect x='20' y='87' width='455' height='372' rx='5' fill='#edf2f7'/>")
	out.append(_text(36, 115, "실제 형상 · 탄 도착 방향 기준", 15, "#576b80"))
	var faces: Array = snapshot.get("faces", []).duplicate()
	for face in faces:
		var center := Vector3.ZERO
		for p in face.points:
			center += ReplayData.vec3(p) / float(face.points.size())
		face["depth"] = center.dot(view)
	faces.sort_custom(func(a, b): return float(a.depth) < float(b.depth))
	for face in faces:
		var normal := ReplayData.vec3(face.normal)
		if normal.dot(view) <= 0.02:
			continue
		var points := PackedStringArray()
		for point in face.points:
			points.append(_pair(_project(ReplayData.vec3(point), basis)))
		var struck := str(face.part) == str(r.get("part", "")) and str(face.zone) == str(r.get("zone", ""))
		var fill := color if struck else ("#a4b9c9" if face.part == "turret" else "#c5d2dc")
		out.append("<polygon points='%s' fill='%s' fill-opacity='%s' stroke='#8ba3b6' stroke-width='0.7'/>" % [
			" ".join(points), fill, "0.7" if struck else "1"])
	if faces.is_empty():
		out.append(_text(45, 205, "기존 기록에는 당시 형상 스냅숏이 없습니다", 16, "#9a660f"))
		out.append(_text(45, 235, "타격 좌표와 판정 수치만 표시합니다", 14))
	var point := _project(entry, basis)
	var start := _project(entry - direction * 5, basis)
	start = Vector2(clampf(start.x, 36, 455), clampf(start.y, 145, 410))
	if has_point:
		out.append("<circle cx='%s' cy='%s' r='7' fill='%s' stroke='#fff' stroke-width='2'/>" % [point.x, point.y, color])
	if has_point and has_ray:
		out.append("<path id='trajectory' d='M %s L %s' fill='none' stroke='%s' stroke-width='3' stroke-dasharray='7 5'/>" % [_pair(start), _pair(point), color])
		out.append("<circle r='5' fill='#fff' opacity='0'><set attributeName='opacity' to='1' begin='shell-motion.begin' dur='1.3s'/><animateMotion id='shell-motion' dur='1.3s' begin='indefinite' fill='freeze' path='M %s L %s'/></circle>" % [_pair(start), _pair(point)])
	var changes := {}
	var damage_rows := []
	for damage in r.get("damage", []):
		if damage.get("before", "") != damage.get("after", ""):
			changes[str(damage.id)] = true
			damage_rows.append("%s: %s → %s" % [_damage_name(str(damage.id)), _state_name(str(damage.before)), _state_name(str(damage.after))])
	for item in snapshot.get("internals", []):
		if changes.has(str(item.id)):
			var damaged := _project(ReplayData.vec3(item.point), basis)
			out.append("<circle cx='%s' cy='%s' r='5' fill='#fb7185'/><path d='M %s L %s' stroke='#fb7185' stroke-dasharray='3 4'/>" % [
				damaged.x, damaged.y, _pair(point), _pair(damaged)])
	out.append(_text(36, 432, "표시점 = 장갑 입사 위치 · 분홍 점 = 손상 승무원/모듈", 12, "#576b80"))
	out.append(_text(502, 116, "탄종과 장갑 판정", 20))
	var rows := ["부위: " + ImpactView.zone_label(r),
		"장갑 %.1fmm · 입사각 %.1f° · 유효장갑 %.1fmm" % [float(r.get("plate_mm", 0)), float(r.get("impact_angle_deg", 0)), float(r.get("effective_mm", 0))],
		"관통력 평균 %.1fmm / 이번 탄 %.1fmm" % [float(r.get("pen_mean_mm", 0)), float(r.get("pen_roll_mm", 0))],
		"관통 확률 %.1f%% · 결과 %s" % [float(r.get("pen_probability", 0)) * 100, verdict],
		"상태: %s → %s" % [_state_name(str(r.get("status_before", "미기록"))), _state_name(str(r.get("status_after", "미기록")))]]
	for i in rows.size():
		out.append(_text(502, 148 + i * 27, rows[i], 15))
	out.append(_text(502, 310, "실제 피해 변화", 20))
	if damage_rows.is_empty():
		damage_rows.append("승무원·모듈 상태 변화 없음")
	for i in mini(damage_rows.size(), 6):
		out.append(_text(502, 341 + i * 23, damage_rows[i], 14, "#b84242"))
	if damage_rows.size() > 6:
		out.append(_text(502, 479, "외 %d건 · 타격 기록 표에 전체 피해 표시" % (damage_rows.size() - 6), 13, "#576b80"))
	out.append(_text(28, 493, "타격 좌표(표적 차체 기준): x %.3f / y %.3f / z %.3fm" % [entry.x, entry.y, entry.z] if has_point else "타격 좌표: 기존 기록에 없음", 15))
	out.append(_text(28, 526, "기록된 물리 판정과 탄착을 재생합니다 · 사격 조건을 바꾸거나 결과를 재추첨하지 않습니다", 13, "#576b80"))
	out.append("</g></svg>")
	return "".join(out)


static func image_data(event: Dictionary, index: int) -> String:
	return "data:image/svg+xml;base64," + Marshalls.raw_to_base64(svg(event, index).to_utf8_buffer())


static func page(event: Dictionary, index: int) -> String:
	var damage := PackedStringArray()
	for item in event.r.get("damage", []):
		if item.get("before", "") != item.get("after", ""):
			var extra := ""
			if item.has("cause"):
				extra += " · 원인: " + str({"he_spall": "장갑 안쪽 파편", "penetration": "관통 피해", "spall": "내부 파편", "fire": "화재"}.get(str(item.cause), str(item.cause)))
			if item.has("chance"):
				extra += " · 피해 판정 확률 %.1f%%" % (float(item.chance) * 100)
			damage.append("<li>%s: %s → %s <span class='note'>%s</span></li>" % [_esc(_damage_name(str(item.id))), _esc(_state_name(str(item.before))), _esc(_state_name(str(item.after))), _esc(extra)])
	if damage.is_empty():
		damage.append("<li>승무원·모듈 상태 변화 없음</li>")
	var r: Dictionary = event.r
	var verdict := "관통" if r.get("penetrated", false) else "도탄" if r.get("ricochet", false) else "비관통"
	var narrative := "이 탄은 장갑을 통과했습니다. 아래 피해 목록은 관통 뒤 실제로 바뀐 승무원·모듈 상태입니다." if r.get("penetrated", false) else "이 탄은 도탄 판정을 받아 장갑을 통과하지 못했습니다." if r.get("ricochet", false) else "이 탄은 표적에 명중했지만 관통 판정은 통과하지 못했습니다. 명중과 관통은 서로 다른 결과입니다."
	var out := PackedStringArray(["<!doctype html><html lang='ko'><head><meta charset='utf-8'><meta name='viewport' content='width=device-width,initial-scale=1'><title>타격 보고서 #%d</title><style>%s</style></head><body>" % [index, ReportTheme.css()]])
	out.append("<nav class='report-nav'><a href='../report.html#impact-%d'>전투 보고서로 돌아가기</a></nav><h1>타격 보고서 #%d <span class='badge'>%s</span></h1>" % [index, index, verdict])
	out.append("<p class='meta'>기록 시각 %.3f초 · %s → %s · %s</p>" % [float(event.get("t", 0)), _esc(event.get("shooter_name", r.get("shooter", "사격 전차"))), _esc(event.get("target_name", r.get("target_name", "표적"))), _esc(r.get("shell", "탄종 미기록"))])
	out.append("<div class='actions'><button id='play'>탄착 재생</button><a class='button' download='shot_%04d.svg' href='%s'>분석 이미지 SVG 저장</a></div><div class='impact-visual'>%s</div>" % [index, image_data(event, index), svg(event, index)])
	out.append("<h2>판정 해설</h2><div class='explanation'><p>%s</p><ul><li>실제 장갑 %.1fmm에 입사각 %.1f°가 적용되어 유효장갑은 %.1fmm로 기록됐습니다. 입사각 0°는 장갑에 수직인 방향입니다.</li><li>해당 거리의 평균 관통력 %.1fmm와 이번 탄의 관통력 %.1fmm, 기록된 관통 확률 %.1f%%를 함께 봅니다. 확률 100%%가 아닌 한 같은 조건에서도 결과가 달라질 수 있습니다.</li><li>이번 페이지는 당시의 판정과 좌표를 재생합니다. 재생 버튼으로 결과를 다시 추첨하지 않습니다.</li></ul></div>" % [narrative, float(r.get("plate_mm", 0)), float(r.get("impact_angle_deg", 0)), float(r.get("effective_mm", 0)), float(r.get("pen_mean_mm", 0)), float(r.get("pen_roll_mm", 0)), float(r.get("pen_probability", 0)) * 100])
	out.append(ShotRewardAnalysis.html(event))
	out.append("<details open><summary>전체 피해 기록</summary><p class='note'>피해 판정 확률은 해당 승무원·모듈에 적용된 조건부 확률이며, 장갑 관통 확률과 구분합니다.</p><ul>%s</ul></details><script>const motion=document.getElementById('shell-motion');document.getElementById('play').disabled=!motion;document.getElementById('play').onclick=()=>motion.beginElement();</script></body></html>" % "".join(damage))
	return "".join(out)


static func write_assets(directory: String, shots: Array) -> void:
	DirAccess.make_dir_recursive_absolute(directory + "/impacts")
	for i in shots.size():
		if not effective(shots[i].r):
			continue
		for extension in ["svg", "html"]:
			var file := FileAccess.open(directory + "/impacts/shot_%04d.%s" % [i + 1, extension], FileAccess.WRITE)
			if file:
				file.store_string(svg(shots[i], i + 1) if extension == "svg" else page(shots[i], i + 1))
				file.close()


static func gallery(shots: Array) -> String:
	var out := PackedStringArray(["<h2>8. 유효 명중 타격 시뮬레이션과 분석 이미지</h2><p class='note'>각 이미지를 누르면 해당 타격의 탄착 재생·확대 이미지가 열립니다. 색상과 피해는 기록된 물리 판정입니다.</p>"])
	for i in shots.size():
		if effective(shots[i].r):
			var delta := "보상 내역 미기록"
			if not shots[i].r.get("reward_events", []).is_empty():
				delta = "사격자 보상 Δ %+.3f%s" % [ShotRewardAnalysis.total(shots[i], str(shots[i].get("shooter_name", shots[i].r.get("shooter", "")))), " (이전 기록 추정)" if shots[i].r.get("reward_source", "") == "legacy_tick" else ""]
			out.append("<figure id='impact-%d'><a href='impacts/shot_%04d.html' target='_blank'><img alt='타격 %d: 탄종·거리·타격 지점·피해' style='width:100%%;max-width:1000px' src='%s'/></a><figcaption>타격 #%d · %s · <a href='impacts/shot_%04d.html'>타격 보고서 열기</a></figcaption></figure>" % [
				i + 1, i + 1, i + 1, image_data(shots[i], i + 1), i + 1, delta, i + 1])
	return "".join(out)
