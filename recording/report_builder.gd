class_name ReportBuilder
extends RefCounted
## events.jsonl → 보고서(report.html) + 표(shots.csv, paths.csv, score.csv).
## 외부 프로그램 없이 Godot 안에서 만든다(게임 종료 시 자동, 또는 도구 스크립트로 다시 생성).
## report.html 은 그림(SVG/PNG)까지 한 파일에 들어 있어 브라우저로 열고 인쇄·PDF 저장할 수 있다.
##
##   1. 요약: 전차별 사격·명중·관통·격파·이동거리·점수
##   2. 맵상 동선: 지형 음영 위에 전차 경로, 사격선, 탄착 표시, 격파 위치
##   3. 체류 히트맵: 팀별로 오래 머문 위치
##   4. 점수(목표값) 그래프: 시간에 따른 팀·전차 누적 점수
##   5. 에피소드별 점수 곡선(episodes.csv): 학습 진행 확인용
##   6. 피탄 분석: 표적 전차·구역별 명중/관통, 입사각 분포(비스듬한 대면 효과 확인)
##   7. 타격 기록 표: 모든 사격의 판정 내역

const TEAM_COLORS := [
	["#e8590c", "#c2255c", "#f59f00", "#a61e4d"],
	["#1c7ed6", "#0ca678", "#7048e8", "#1098ad", "#5c940d", "#4263eb"],
]
const TEAM_LABELS := ["독일(티거)", "연합군"]
const KIND_LABEL := {"penetration": "관통", "non_penetration": "불관통", "ricochet": "도탄",
	"blocked": "차단", "miss": "빗나감"}
const MAP_W := 640.0


## 보고서와 CSV 를 events.jsonl 옆에 쓴다. 반환: report.html 의 절대 경로("" = 실패)
static func build_files(events_path: String, episodes_csv := "") -> String:
	var d := ReplayData.load_file(events_path)
	if not d.ok():
		push_error("ReportBuilder: " + (d.error if d.error != "" else "프레임 없음"))
		return ""
	var out_dir := events_path.get_base_dir()
	_write_text(out_dir + "/shots.csv", shots_csv(d))
	_write_text(out_dir + "/paths.csv", paths_csv(d))
	_write_text(out_dir + "/score.csv", score_csv(d))
	ShotImpactReport.write_assets(out_dir, d.shots)
	var html := build_html(d, _read_episodes(episodes_csv))
	var rp := out_dir + "/report.html"
	_write_text(rp, html)
	return ProjectSettings.globalize_path(rp)


static func build_html(d: ReplayData, episodes: Array) -> String:
	var h := d.header
	var s := PackedStringArray()
	var summary: Dictionary = d.end.get("summary", {})
	var winner := int(d.end.get("winner", -1))
	s.append("<!doctype html><html lang='ko'><head><meta charset='utf-8'><title>전투 보고서 ep%d</title>" % int(h.get("episode", 0)))
	s.append("<style>" + _css() + "</style></head><body>")
	s.append("<h1>전투 보고서 — 에피소드 %d</h1>" % int(h.get("episode", 0)))
	s.append("<p class='meta'>기록 %s · 맵 시드 %s · 경과 %s · 종료: %s · 결과: <b>%s</b> · 기록 형식 %s v%s</p>" % [
		h.get("created", ""), h.get("map", {}).get("seed", "?"), _mmss(d.duration()),
		d.end.get("reason", "기록 중단"), ("무승부" if winner < 0 else TEAM_LABELS[winner] + " 승리"),
		h.get("format", ""), h.get("version", "")])
	var sc: Array = d.frames[-1].get("score", [0, 0])
	s.append("<div class='tiles'>%s%s%s%s</div>" % [
		_tile(TEAM_LABELS[0] + " 점수", "%.2f" % sc[0], TEAM_COLORS[0][0]),
		_tile(TEAM_LABELS[1] + " 점수", "%.2f" % sc[1], TEAM_COLORS[1][0]),
		_tile("사격 / 명중", "%d / %d" % [d.shots.size(), d.shots.filter(func(e): return e.r.get("hit", false)).size()], "#495057"),
		_tile("전투불능", "%d대" % d.knockouts.size(), "#495057")])

	s.append("<h2>1. 전차별 요약</h2>")
	s.append(_summary_table(d))

	s.append("<h2>2. 맵상 동선과 타격 위치</h2>")
	s.append("<p class='note'>위쪽 = −Z(연합군 출발), 아래쪽 = +Z(티거 출발). 선 = 이동 경로(○ 출발, ■ 마지막 위치, ✕ 전투불능). 가는 선 = 사격선, 점 = 탄착(빨강 관통 · 노랑 불관통 · 흰색 도탄 · 회색 차단). 점에 마우스를 올리면 판정 내역.</p>")
	s.append(_map_svg(d))
	s.append(_legend(d))

	s.append("<h2>3. 체류 히트맵</h2>")
	s.append("<div class='row'>%s%s</div>" % [_heatmap_svg(d, 0), _heatmap_svg(d, 1)])

	s.append("<h2>4. 점수(목표값) 그래프</h2>")
	s.append("<p class='note'>보상 규칙(가중치)은 맨 아래 표. 점선 = 전투불능 시각.</p>")
	s.append(_score_chart(d, true))
	s.append(_score_chart(d, false))

	s.append("<h2>5. 에피소드별 점수 곡선</h2>")
	s.append(_episode_chart(episodes))

	s.append("<h2>6. 피탄 분석</h2>")
	s.append(_zone_table(d))
	s.append(_angle_table(d))

	s.append("<h2>7. 타격 기록</h2>")
	s.append(_shot_table(d))
	s.append(ShotImpactReport.gallery(d.shots))

	s.append("<h2>부록. 보상 가중치</h2><table class='small'><tr><th>항목</th><th>값</th></tr>")
	var w: Dictionary = h.get("reward_weights", {}).duplicate(true)
	if h.get("score_source", "game") == "training":
		var training: Dictionary = h.get("meta", {}).get("training", {}).get("reward", {})
		w.merge(training, true)
		w.merge(training.get("combat", {}), true)
		w.erase("combat")
		s.append("<tr><td colspan='2'>점수는 각 개체의 실제 PPO 훈련 보상입니다. 지근탄·접근·시간·승패 보상을 포함하며 중복 합산하지 않습니다.</td></tr>")
	for k in w:
		s.append("<tr><td>%s</td><td>%s</td></tr>" % [k, w[k]])
	s.append("</table><p class='note'>원본: %s</p></body></html>" % _esc(ProjectSettings.globalize_path(d.path)))
	return "\n".join(s)


# ------------------------------------------------------------------ 표

static func _summary_table(d: ReplayData) -> String:
	var per := {}
	for t in d.end.get("summary", {}).get("tanks", []):
		per[int(t.id)] = t
	var last: Array = d.frames[-1].get("r", [])
	var s := PackedStringArray(["<table><tr><th></th><th>전차</th><th>팀</th><th>최종 상태</th><th>사격</th><th>명중</th><th>관통</th><th>격파</th><th>이동(m)</th><th>점수</th></tr>"])
	for t in d.tanks():
		var id := int(t.id)
		var st := _tank_stats(d, id)
		var p: Dictionary = per.get(id, {})
		s.append("<tr><td><span class='sw' style='background:%s'></span></td><td>%s <small>(%s)</small></td><td>%s</td><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%d</td><td>%.0f</td><td>%.2f</td></tr>" % [
			_tank_color(d, id), t.name, t.display_name, TEAM_LABELS[int(t.team)], p.get("status", _status_name(d, id)),
			st.shots, st.hits, st.pens, st.kills, _path_length(d, id), float(last[id]) if id < last.size() else 0.0])
	s.append("</table>")
	return "".join(s)


static func _tank_stats(d: ReplayData, id: int) -> Dictionary:
	var st := {"shots": 0, "hits": 0, "pens": 0, "kills": 0}
	for e in d.shots:
		if int(e.shooter) != id:
			continue
		st.shots += 1
		if e.r.get("hit", false):
			st.hits += 1
			if e.r.get("penetrated", false):
				st.pens += 1
			if int(e.target) >= 0 and d.tank_team(int(e.target)) != d.tank_team(id):
				for ev in e.r.get("events", []):
					if str(ev).begins_with("knocked_out:"):
						st.kills += 1
	return st


static func _status_name(d: ReplayData, id: int) -> String:
	var code := int(d.field(d.frames[-1].s[id], "status"))
	return ["operational", "damaged", "knocked_out", "destroyed"][clampi(code, 0, 3)]


static func _path_length(d: ReplayData, id: int) -> float:
	var p := d.path_of(id)
	var L := 0.0
	for i in range(1, p.size()):
		L += Vector2(p[i].x, p[i].y).distance_to(Vector2(p[i - 1].x, p[i - 1].y))
	return L


static func _shot_table(d: ReplayData) -> String:
	if d.shots.is_empty():
		return "<p class='note'>사격 없음</p>"
	var s := PackedStringArray(["<div class='scroll'><table class='small'><tr><th>타격 상세</th><th>시각</th><th>사격</th><th>표적</th><th>거리(m)</th><th>탄종</th><th>구역</th><th>입사각°</th><th>유효장갑mm</th><th>관통력mm</th><th>관통확률</th><th>결과</th><th>피해</th><th>점수</th></tr>"])
	var rew_by_tick := {}
	for rw in d.rewards:
		var k := "%d_%d" % [int(rw.tick), int(rw.tank)]
		rew_by_tick[k] = rew_by_tick.get(k, 0.0) + float(rw.value)
	var i := 0
	for e in d.shots:
		i += 1
		var r: Dictionary = e.r
		var kind := MatchRecorder.shot_kind(r)
		var dmg := []
		for x in r.get("damage", []):
			if x.get("before", "") != x.get("after", ""):
				dmg.append("%s:%s" % [x.id, x.after])
		for ev in r.get("events", []):
			if str(ev).begins_with("knocked_out") or ev == "ammo_detonation" or ev == "crew_bailed_out":
				dmg.append("<b>%s</b>" % ev)
		var rk := "%d_%d" % [int(e.tick), int(e.shooter)]
		var hit: bool = r.get("hit", false)
		var detail := "<a href='impacts/shot_%04d.html' target='_blank'>#%d · 타격 시뮬레이션</a>" % [i, i] if ShotImpactReport.effective(r) else str(i)
		s.append("<tr class='%s'><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td></tr>" % [
			kind, detail, _mmss(e.t), d.tank_name(int(e.shooter)), d.tank_name(int(e.target)) if hit else r.get("blocked_by", "-"),
			("%.0f" % r.distance_m) if hit else "-", r.get("shell", ""), r.get("zone", "-") if hit else "-",
			("%.0f" % r.impact_angle_deg) if hit else "-", ("%.0f" % r.effective_mm) if hit else "-",
			("%.0f" % r.pen_roll_mm) if hit else "-", ("%.0f%%" % (float(r.pen_probability) * 100.0)) if hit else "-",
			KIND_LABEL.get(kind, kind), ", ".join(dmg), ("%+.2f" % rew_by_tick[rk]) if rew_by_tick.has(rk) else ""])
	s.append("</table></div>")
	return "".join(s)


static func _zone_table(d: ReplayData) -> String:
	var by := {}  # target tank type -> zone -> [hits, pens, angle_sum]
	for e in d.shots:
		var r: Dictionary = e.r
		if not r.get("hit", false) or r.get("zone", "") == "":
			continue
		var tt: String = r.get("target", "?")
		if not by.has(tt):
			by[tt] = {}
		if not by[tt].has(r.zone):
			by[tt][r.zone] = [0, 0, 0.0]
		var z: Array = by[tt][r.zone]
		z[0] += 1
		z[1] += 1 if r.get("penetrated", false) else 0
		z[2] += float(r.get("impact_angle_deg", 0.0))
	if by.is_empty():
		return "<p class='note'>명중 없음</p>"
	var s := PackedStringArray(["<table class='small'><tr><th>표적 전차</th><th>구역</th><th>명중</th><th>관통</th><th>관통률</th><th>평균 입사각°</th></tr>"])
	for tt in by:
		for z in by[tt]:
			var v: Array = by[tt][z]
			s.append("<tr><td>%s</td><td>%s</td><td>%d</td><td>%d</td><td>%.0f%%</td><td>%.0f</td></tr>" % [tt, z, v[0], v[1], 100.0 * v[1] / v[0], v[2] / v[0]])
	s.append("</table>")
	return "".join(s)


## 입사각 분포: 피격 팀별, 10° 구간. 티거가 비스듬히 대면하면 큰 각도 쪽으로 몰린다.
static func _angle_table(d: ReplayData) -> String:
	var bins := [[], []]
	for t in 2:
		bins[t].resize(9)
		bins[t].fill(0)
	var pens := [[], []]
	for t in 2:
		pens[t].resize(9)
		pens[t].fill(0)
	var any := false
	for e in d.shots:
		var r: Dictionary = e.r
		if not r.get("hit", false) or int(e.target) < 0:
			continue
		var team := d.tank_team(int(e.target))
		var b := clampi(int(float(r.get("impact_angle_deg", 0.0)) / 10.0), 0, 8)
		bins[team][b] += 1
		pens[team][b] += 1 if r.get("penetrated", false) else 0
		any = true
	if not any:
		return ""
	var s := PackedStringArray(["<p class='note'>입사각 분포(피격 팀별, 0° = 장갑에 수직). 칸 = 명중 수 (관통 수)</p><table class='small'><tr><th>피격 팀</th>"])
	for b in 9:
		s.append("<th>%d–%d°</th>" % [b * 10, b * 10 + 10])
	s.append("</tr>")
	for t in 2:
		s.append("<tr><td>%s</td>" % TEAM_LABELS[t])
		for b in 9:
			s.append("<td>%s</td>" % (("%d (%d)" % [bins[t][b], pens[t][b]]) if bins[t][b] > 0 else ""))
		s.append("</tr>")
	s.append("</table>")
	return "".join(s)


# ------------------------------------------------------------------ 그림

static func _tank_color(d: ReplayData, id: int) -> String:
	var team := d.tank_team(id)
	var k := 0
	for t in d.tanks():
		if int(t.id) == id:
			break
		if int(t.team) == team:
			k += 1
	var pal: Array = TEAM_COLORS[clampi(team, 0, 1)]
	return pal[k % pal.size()]


static func _px(d: ReplayData, x: float) -> float:
	var half := d.map_half()
	return (x + half) / (2.0 * half) * MAP_W


static func _map_base(d: ReplayData, img_px := 256) -> PackedStringArray:
	var s := PackedStringArray()
	s.append("<image href='data:image/png;base64,%s' x='0' y='0' width='%d' height='%d' preserveAspectRatio='none'/>" % [terrain_png_base64(d, img_px), MAP_W, MAP_W])
	var k := MAP_W / (2.0 * d.map_half())
	for o in d.header.get("map", {}).get("obstacles", []):
		var c: Color = MinimapView.OBSTACLE_COLORS.get(o.type, Color(0.53, 0.56, 0.59, 0.8))
		var col := "#" + c.to_html(false)
		if o.has("a") and o.has("b"):
			s.append("<line x1='%.1f' y1='%.1f' x2='%.1f' y2='%.1f' stroke='%s' stroke-width='2.5'><title>%s</title></line>" % [_px(d, o.a[0]), _px(d, o.a[2]), _px(d, o.b[0]), _px(d, o.b[2]), col, o.type])
		elif o.has("blobs"):
			for b in o.blobs:
				s.append("<circle cx='%.1f' cy='%.1f' r='%.1f' fill='%s' fill-opacity='%.2f'/>" % [_px(d, b[0][0]), _px(d, b[0][2]), float(b[1]) * k, col, c.a])
		elif o.type != "village":
			s.append("<circle cx='%.1f' cy='%.1f' r='%.1f' fill='%s' fill-opacity='%.2f'/>" % [_px(d, o.pos[0]), _px(d, o.pos[2]), maxf(float(o.radius) * k, 1.2), col, c.a])
	return s


static func _map_svg(d: ReplayData) -> String:
	var s := PackedStringArray(["<svg class='map' viewBox='0 0 %d %d' width='%d' height='%d'>" % [MAP_W, MAP_W, MAP_W, MAP_W]])
	s.append_array(_map_base(d))
	# 사격선
	for e in d.shots:
		var pts := d.shot_points(e)
		var col := _tank_color(d, int(e.shooter))
		s.append("<line x1='%.1f' y1='%.1f' x2='%.1f' y2='%.1f' stroke='%s' stroke-width='0.8' stroke-opacity='0.45'%s/>" % [
			_px(d, pts[0].x), _px(d, pts[0].z), _px(d, pts[1].x), _px(d, pts[1].z), col,
			"" if e.r.get("hit", false) else " stroke-dasharray='3 3'"])
	# 동선
	for t in d.tanks():
		var id := int(t.id)
		var p := d.path_of(id)
		if p.is_empty():
			continue
		var col := _tank_color(d, id)
		var pts := PackedStringArray()
		for v in p:
			pts.append("%.1f,%.1f" % [_px(d, v.x), _px(d, v.y)])
		s.append("<polyline points='%s' fill='none' stroke='#fff' stroke-width='4' stroke-opacity='0.6'/>" % " ".join(pts))
		s.append("<polyline points='%s' fill='none' stroke='%s' stroke-width='2.2'><title>%s</title></polyline>" % [" ".join(pts), col, t.name])
		s.append("<circle cx='%.1f' cy='%.1f' r='4' fill='#fff' stroke='%s' stroke-width='2'/>" % [_px(d, p[0].x), _px(d, p[0].y), col])
		var lx := _px(d, p[-1].x)
		var ly := _px(d, p[-1].y)
		var code := int(d.field(d.frames[-1].s[id], "status"))
		if code >= MatchRecorder.STATUS_KO:
			s.append("<path d='M%.1f %.1fl10 10m0 -10l-10 10' stroke='#212529' stroke-width='3'/><path d='M%.1f %.1fl10 10m0 -10l-10 10' stroke='%s' stroke-width='1.6'/>" % [lx - 5, ly - 5, lx - 5, ly - 5, col])
		else:
			s.append("<rect x='%.1f' y='%.1f' width='8' height='8' fill='%s' stroke='#fff'/>" % [lx - 4, ly - 4, col])
		s.append("<text x='%.1f' y='%.1f' class='lbl'>%s</text>" % [lx + 7, ly - 6, t.name])
	# 탄착
	for e in d.shots:
		var r: Dictionary = e.r
		if not r.has("hit_pos"):
			continue
		var p: Vector3 = ReplayData.vec3(r.hit_pos)
		var kind := MatchRecorder.shot_kind(r)
		var tip := "%s %s → %s\n%s %s, 입사각 %s°, 유효 %smm / 관통 %smm\n%s" % [_mmss(e.t), d.tank_name(int(e.shooter)),
			d.tank_name(int(e.target)) if r.get("hit", false) else r.get("blocked_by", ""), KIND_LABEL.get(kind, kind),
			r.get("zone", ""), r.get("impact_angle_deg", "-"), r.get("effective_mm", "-"), r.get("pen_roll_mm", "-"),
			", ".join(r.get("events", []))]
		var cx := _px(d, p.x)
		var cy := _px(d, p.z)
		match kind:
			"penetration":
				s.append("<circle cx='%.1f' cy='%.1f' r='4.5' fill='#e03131' stroke='#fff'><title>%s</title></circle>" % [cx, cy, _esc(tip)])
			"non_penetration":
				s.append("<circle cx='%.1f' cy='%.1f' r='4' fill='#fab005' stroke='#212529' stroke-width='0.8'><title>%s</title></circle>" % [cx, cy, _esc(tip)])
			"ricochet":
				s.append("<circle cx='%.1f' cy='%.1f' r='3.5' fill='#fff' stroke='#212529'><title>%s</title></circle>" % [cx, cy, _esc(tip)])
			_:
				s.append("<rect x='%.1f' y='%.1f' width='5' height='5' fill='#adb5bd' stroke='#495057' stroke-width='0.6'><title>%s</title></rect>" % [cx - 2.5, cy - 2.5, _esc(tip)])
	s.append("</svg>")
	return "".join(s)


static func _legend(d: ReplayData) -> String:
	var s := PackedStringArray(["<div class='legend'>"])
	for t in d.tanks():
		s.append("<span><i style='background:%s'></i>%s</span>" % [_tank_color(d, int(t.id)), t.name])
	s.append("</div>")
	return "".join(s)


static func _heatmap_svg(d: ReplayData, team: int) -> String:
	const G := 40
	var grid := PackedInt32Array()
	grid.resize(G * G)
	var half := d.map_half()
	var mx := 1
	for fr in d.frames:
		for t in d.tanks():
			if int(t.team) != team:
				continue
			var row: Array = fr.s[int(t.id)]
			if int(d.field(row, "status")) >= MatchRecorder.STATUS_KO:
				continue
			var gx := clampi(int((float(d.field(row, "x")) + half) / (2.0 * half) * G), 0, G - 1)
			var gz := clampi(int((float(d.field(row, "z")) + half) / (2.0 * half) * G), 0, G - 1)
			grid[gz * G + gx] += 1
			mx = maxi(mx, grid[gz * G + gx])
	var W := 320.0
	var cell := W / G
	var col: String = TEAM_COLORS[team][0]
	var s := PackedStringArray(["<figure><svg class='map' viewBox='0 0 %d %d' width='%d' height='%d'><g transform='scale(%f)'>" % [W, W, W, W, W / MAP_W]])
	s.append_array(_map_base(d, 128))
	s.append("</g>")
	for i in grid.size():
		if grid[i] == 0:
			continue
		s.append("<rect x='%.1f' y='%.1f' width='%.1f' height='%.1f' fill='%s' fill-opacity='%.2f'/>" % [
			(i % G) * cell, (i / G) * cell, cell, cell, col, 0.15 + 0.8 * sqrt(float(grid[i]) / mx)])
	s.append("</svg><figcaption>%s 체류 시간(진할수록 오래 머묾)</figcaption></figure>" % TEAM_LABELS[team])
	return "".join(s)


## 시간-점수 선 그래프. teams=true 면 팀 합계, false 면 전차별
static func _score_chart(d: ReplayData, teams: bool) -> String:
	var W := 900.0
	var H := 260.0
	var L := 52.0
	var B := 28.0
	var T := d.duration()
	var series := []  # [label, color, PackedVector2Array]
	if teams:
		for team in 2:
			var pts := PackedVector2Array()
			for fr in d.frames:
				pts.append(Vector2(fr.t, fr.get("score", [0, 0])[team]))
			series.append([TEAM_LABELS[team], TEAM_COLORS[team][0], pts])
	else:
		for t in d.tanks():
			var pts := PackedVector2Array()
			for fr in d.frames:
				var r: Array = fr.get("r", [])
				pts.append(Vector2(fr.t, r[int(t.id)] if int(t.id) < r.size() else 0.0))
			series.append([t.name, _tank_color(d, int(t.id)), pts])
	var lo := 0.0
	var hi := 0.0
	for se in series:
		for p in se[2]:
			lo = minf(lo, p.y)
			hi = maxf(hi, p.y)
	if hi - lo < 1.0:
		hi = lo + 1.0
	var pad := (hi - lo) * 0.08
	lo -= pad
	hi += pad
	var fx := func(t): return L + (t / maxf(T, 1.0)) * (W - L - 10.0)
	var fy := func(v): return 10.0 + (hi - v) / (hi - lo) * (H - B - 10.0)
	var s := PackedStringArray(["<figure><svg viewBox='0 0 %d %d' width='100%%' class='chart'>" % [W, H]])
	for v in nice_ticks(lo, hi):
		s.append("<line x1='%.0f' x2='%.0f' y1='%.1f' y2='%.1f' class='grid'/><text x='%.0f' y='%.1f' class='ax' text-anchor='end'>%s</text>" % [L, W - 10, fy.call(v), fy.call(v), L - 6, fy.call(v) + 4, str(snappedf(v, 0.01))])
	s.append("<line x1='%.0f' x2='%.0f' y1='%.1f' y2='%.1f' class='zero'/>" % [L, W - 10, fy.call(0.0), fy.call(0.0)])
	for k in 6:
		var t := T * k / 5.0
		s.append("<text x='%.1f' y='%.0f' class='ax' text-anchor='middle'>%s</text>" % [fx.call(t), H - 8, _mmss(t)])
	for ko in d.knockouts:
		var x: float = fx.call(float(ko.t))
		s.append("<line x1='%.1f' x2='%.1f' y1='10' y2='%.0f' class='ko'/><text x='%.1f' y='20' class='ax'>✕%s</text>" % [x, x, H - B, x + 3, d.tank_name(int(ko.tank))])
	for se in series:
		var pts := PackedStringArray()
		var step := maxi(1, se[2].size() / 900)
		for i in range(0, se[2].size(), step):
			pts.append("%.1f,%.1f" % [fx.call(se[2][i].x), fy.call(se[2][i].y)])
		pts.append("%.1f,%.1f" % [fx.call(se[2][-1].x), fy.call(se[2][-1].y)])
		s.append("<polyline points='%s' fill='none' stroke='%s' stroke-width='%s'><title>%s</title></polyline>" % [" ".join(pts), se[1], "2.5" if teams else "1.6", se[0]])
	s.append("</svg><figcaption>")
	for se in series:
		s.append("<span class='key'><i style='background:%s'></i>%s %.2f</span>" % [se[1], se[0], se[2][-1].y])
	s.append(" — %s</figcaption></figure>" % ("팀 누적 점수" if teams else "전차별 누적 점수"))
	return "".join(s)


static func _episode_chart(rows: Array) -> String:
	if rows.size() < 1:
		return "<p class='note'>episodes.csv 없음</p>"
	var W := 900.0
	var H := 240.0
	var L := 52.0
	var B := 28.0
	var lo := 0.0
	var hi := 1.0
	for r in rows:
		lo = minf(lo, minf(r.s0, r.s1))
		hi = maxf(hi, maxf(r.s0, r.s1))
	var n := rows.size()
	var fx := func(i): return L + (float(i) / maxf(n - 1, 1)) * (W - L - 10.0)
	var fy := func(v): return 10.0 + (hi - v) / maxf(hi - lo, 1e-6) * (H - B - 10.0)
	var s := PackedStringArray(["<figure><svg viewBox='0 0 %d %d' width='100%%' class='chart'>" % [W, H]])
	for v in nice_ticks(lo, hi):
		s.append("<line x1='%.0f' x2='%.0f' y1='%.1f' y2='%.1f' class='grid'/><text x='%.0f' y='%.1f' class='ax' text-anchor='end'>%s</text>" % [L, W - 10, fy.call(v), fy.call(v), L - 6, fy.call(v) + 4, str(snappedf(v, 0.01))])
	s.append("<line x1='%.0f' x2='%.0f' y1='%.1f' y2='%.1f' class='zero'/>" % [L, W - 10, fy.call(0.0), fy.call(0.0)])
	for team in 2:
		var pts := PackedStringArray()
		for i in n:
			pts.append("%.1f,%.1f" % [fx.call(i), fy.call(rows[i]["s%d" % team])])
		s.append("<polyline points='%s' fill='none' stroke='%s' stroke-width='2'/>" % [" ".join(pts), TEAM_COLORS[team][0]])
		if n <= 200:
			for i in n:
				s.append("<circle cx='%.1f' cy='%.1f' r='%s' fill='%s'><title>ep%d %s %.2f</title></circle>" % [fx.call(i), fy.call(rows[i]["s%d" % team]), "4" if rows[i].winner == team else "2",
					TEAM_COLORS[team][0], rows[i].ep, TEAM_LABELS[team], rows[i]["s%d" % team]])
	var wins := [0, 0, 0]
	for r in rows:
		wins[r.winner if r.winner >= 0 else 2] += 1
	for k in mini(n, 6):
		var i := int(round((n - 1) * k / maxf(mini(n, 6) - 1, 1)))
		s.append("<text x='%.1f' y='%.0f' class='ax' text-anchor='middle'>ep%d</text>" % [fx.call(i), H - 8, rows[i].ep])
	s.append("</svg><figcaption><span class='key'><i style='background:%s'></i>%s</span><span class='key'><i style='background:%s'></i>%s</span> — 에피소드 %d개, 승리 %s %d / %s %d / 무승부 %d (큰 점 = 승리)</figcaption></figure>" % [
		TEAM_COLORS[0][0], TEAM_LABELS[0], TEAM_COLORS[1][0], TEAM_LABELS[1], n, TEAM_LABELS[0], wins[0], TEAM_LABELS[1], wins[1], wins[2]])
	return "".join(s)


## 보기 좋은 눈금(1·2·5 × 10^n 간격, 4~6개)
static func nice_ticks(lo: float, hi: float) -> Array:
	var span := maxf(hi - lo, 1e-6)
	var raw := span / 5.0
	var mag: float = pow(10.0, floor(log(raw) / log(10.0)))
	var step := mag
	for m in [1.0, 2.0, 5.0, 10.0]:
		if mag * m >= raw:
			step = mag * m
			break
	var out := []
	var v: float = ceil(lo / step) * step
	while v <= hi + 1e-9:
		out.append(v)
		v += step
	return out


## 기록된 지형 높이로 음영 기복도 PNG(base64)
static func terrain_png_base64(d: ReplayData, px := 256) -> String:
	var img := terrain_image(d.header.get("map", {}), px)
	return Marshalls.raw_to_base64(img.save_png_to_buffer()) if img else ""


static func terrain_image(m: Dictionary, px := 256) -> Image:
	var hs: Array = m.get("heights", [])
	if hs.is_empty():
		var blank := Image.create(4, 4, false, Image.FORMAT_RGB8)
		blank.fill(Color(0.8, 0.84, 0.74))
		return blank
	var n := int(sqrt(hs.size()))
	var lo := INF
	var hi := -INF
	for v in hs:
		lo = minf(lo, v)
		hi = maxf(hi, v)
	var img := Image.create(n, n, false, Image.FORMAT_RGB8)
	var cell := float(m.get("cell_m", 10.0))
	var light := Vector3(-1, 2.2, -1).normalized()
	for iz in n:
		for ix in n:
			var h: float = hs[iz * n + ix]
			var hx: float = hs[iz * n + mini(ix + 1, n - 1)] - hs[iz * n + maxi(ix - 1, 0)]
			var hz: float = hs[mini(iz + 1, n - 1) * n + ix] - hs[maxi(iz - 1, 0) * n + ix]
			var nrm := Vector3(-hx, 2.0 * cell, -hz).normalized()
			var shade := clampf(nrm.dot(light), 0.0, 1.0)
			var e := (h - lo) / maxf(hi - lo, 0.01)
			var base := Color(0.62, 0.70, 0.50).lerp(Color(0.86, 0.82, 0.66), e)
			img.set_pixel(ix, iz, base * (0.55 + 0.5 * shade))
	img.resize(px, px, Image.INTERPOLATE_BILINEAR)
	return img


# ------------------------------------------------------------------ CSV

static func shots_csv(d: ReplayData) -> String:
	var s := PackedStringArray(["t_s,shooter,shooter_team,target,target_team,shell,hit,result,zone,distance_m,impact_angle_deg,plate_mm,effective_mm,pen_mean_mm,pen_roll_mm,pen_probability,from_x,from_z,hit_x,hit_y,hit_z,events,damage"])
	for e in d.shots:
		var r: Dictionary = e.r
		var hp: Vector3 = ReplayData.vec3(r.hit_pos) if r.has("hit_pos") else Vector3(NAN, NAN, NAN)
		var fr := ReplayData.vec3(r.get("from", []))
		var dmg := []
		for x in r.get("damage", []):
			dmg.append("%s:%s>%s" % [x.id, x.before, x.after])
		s.append("%.3f,%s,%d,%s,%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%s,%s" % [
			float(e.t), d.tank_name(int(e.shooter)), d.tank_team(int(e.shooter)), d.tank_name(int(e.target)), d.tank_team(int(e.target)),
			r.get("shell", ""), r.get("hit", false), MatchRecorder.shot_kind(r), r.get("zone", ""), r.get("distance_m", ""),
			r.get("impact_angle_deg", ""), r.get("plate_mm", ""), r.get("effective_mm", ""), r.get("pen_mean_mm", ""),
			r.get("pen_roll_mm", ""), r.get("pen_probability", ""), fr.x, fr.z, hp.x, hp.y, hp.z,
			"|".join(r.get("events", [])), "|".join(dmg)])
	return "\n".join(s) + "\n"


static func paths_csv(d: ReplayData) -> String:
	var s := PackedStringArray(["t_s,tank,team,x,y,z,hull_yaw_deg,turret_yaw_deg,gun_pitch_deg,speed_mps,status," + ",".join(TankControlInput.ACTION_LABELS)])
	for fr in d.frames:
		for t in d.tanks():
			var id := int(t.id)
			var row: Array = fr.s[id]
			var q := Quaternion(d.field(row, "qx"), d.field(row, "qy"), d.field(row, "qz"), d.field(row, "qw"))
			var yaw := rad_to_deg(Basis(q).get_euler().y)
			s.append("%.3f,%s,%d,%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%.2f,%d,%s,%s,%s,%s,%s,%s" % [float(fr.t), t.name, int(t.team),
				d.field(row, "x"), d.field(row, "y"), d.field(row, "z"), yaw, rad_to_deg(d.field(row, "turret_yaw")),
				rad_to_deg(d.field(row, "gun_pitch")), (float(d.field(row, "track_l")) + float(d.field(row, "track_r"))) * 0.5,
				int(d.field(row, "status")), d.field(row, "a_left"), d.field(row, "a_right"), d.field(row, "a_brake"),
				d.field(row, "a_traverse"), d.field(row, "a_elev"), d.field(row, "a_fire")])
	return "\n".join(s) + "\n"


static func score_csv(d: ReplayData) -> String:
	var names := d.tanks().map(func(t): return t.name)
	var s := PackedStringArray(["t_s,score_team0,score_team1," + ",".join(names)])
	for fr in d.frames:
		var sc: Array = fr.get("score", [0, 0])
		var r: Array = fr.get("r", [])
		s.append("%.3f,%s,%s,%s" % [float(fr.t), sc[0], sc[1], ",".join(r.map(func(v): return str(v)))])
	return "\n".join(s) + "\n"


static func _read_episodes(p: String) -> Array:
	var rows := []
	if p == "" or not FileAccess.file_exists(p):
		return rows
	var lines := FileAccess.get_file_as_string(p).strip_edges().split("\n")
	for i in range(1, lines.size()):
		var c := lines[i].split(",")
		if c.size() < 7:
			continue
		rows.append({"ep": int(c[0]), "winner": int(c[4]), "s0": float(c[5]), "s1": float(c[6])})
	return rows


# ------------------------------------------------------------------ 기타

static func _write_text(p: String, txt: String) -> void:
	var f := FileAccess.open(p, FileAccess.WRITE)
	if f:
		f.store_string(txt)
		f.close()


static func _tile(label: String, value: String, color: String) -> String:
	return "<div class='tile' style='border-color:%s'><div class='tl'>%s</div><div class='tv'>%s</div></div>" % [color, label, value]


static func _mmss(t) -> String:
	var s := int(float(t))
	return "%d:%02d" % [s / 60, s % 60]


static func _esc(s: String) -> String:
	return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("'", "&#39;")


static func _css() -> String:
	return """
body{font-family:'Malgun Gothic','Apple SD Gothic Neo',sans-serif;margin:24px auto;max-width:980px;color:#212529;background:#fff;padding:0 16px}
h1{font-size:22px;margin-bottom:4px}h2{font-size:17px;margin-top:32px;border-bottom:2px solid #dee2e6;padding-bottom:4px}
.meta,.note{color:#495057;font-size:13px}table{border-collapse:collapse;font-size:13px;margin:8px 0}
th,td{border:1px solid #dee2e6;padding:3px 7px;text-align:right}th{background:#f1f3f5}td:nth-child(2),td:nth-child(3){text-align:left}
table.small{font-size:12px}.scroll{max-height:520px;overflow:auto}.scroll td{white-space:nowrap}
tr.penetration td{background:#fff5f5}tr.non_penetration td{background:#fff9db}tr.blocked td,tr.miss td{color:#868e96}
.tiles{display:flex;gap:10px;flex-wrap:wrap;margin:12px 0}.tile{border-left:5px solid;padding:6px 12px;background:#f8f9fa;min-width:150px}
.tl{font-size:12px;color:#495057}.tv{font-size:20px;font-weight:bold}
.sw,.legend i,.key i{display:inline-block;width:12px;height:12px;border-radius:2px;vertical-align:middle;margin-right:4px}
.legend span,.key{margin-right:14px;font-size:13px}svg.map{border:1px solid #ced4da;max-width:100%;height:auto}
.lbl{font-size:11px;fill:#212529;paint-order:stroke;stroke:#fff;stroke-width:3px}
.chart{border:1px solid #e9ecef;background:#fff}.grid{stroke:#e9ecef}.zero{stroke:#adb5bd}.ax{font-size:11px;fill:#495057}
.ko{stroke:#868e96;stroke-dasharray:4 3}figure{margin:8px 0}figcaption{font-size:13px;color:#495057}.row{display:flex;gap:16px;flex-wrap:wrap}
@media print{.scroll{max-height:none;overflow:visible}}
"""
