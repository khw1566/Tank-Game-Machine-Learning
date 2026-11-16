class_name ScoreGraph
extends Control
## 팀 누적 점수 그래프(시간축). history = [[t, team0, team1], ...]. cursor_t >= 0 이면 세로선 표시(리플레이).

var history: Array = []
var cursor_t := -1.0
var t_max := 0.0


func set_history(h: Array, p_cursor := -1.0, p_t_max := 0.0) -> void:
	history = h
	cursor_t = p_cursor
	t_max = p_t_max
	queue_redraw()


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	draw_rect(r, Color(0, 0, 0, 0.55))
	if history.size() < 2:
		return
	var T := maxf(t_max, float(history[-1][0]))
	var lo := 0.0
	var hi := 1.0
	for h in history:
		lo = minf(lo, minf(h[1], h[2]))
		hi = maxf(hi, maxf(h[1], h[2]))
	var pad := (hi - lo) * 0.1
	lo -= pad
	hi += pad
	var fy := func(v): return 4.0 + (hi - v) / (hi - lo) * (size.y - 8.0)
	var fx := func(t): return 4.0 + t / maxf(T, 1.0) * (size.x - 8.0)
	draw_line(Vector2(4, fy.call(0.0)), Vector2(size.x - 4, fy.call(0.0)), Color(1, 1, 1, 0.3))
	for team in 2:
		var pts := PackedVector2Array()
		var step := maxi(1, history.size() / int(maxf(size.x, 50.0)))
		for i in range(0, history.size(), step):
			pts.append(Vector2(fx.call(history[i][0]), fy.call(history[i][team + 1])))
		pts.append(Vector2(fx.call(history[-1][0]), fy.call(history[-1][team + 1])))
		draw_polyline(pts, MinimapView.TEAM_COLORS[team], 2.0, true)
	if cursor_t >= 0.0:
		var x: float = fx.call(cursor_t)
		draw_line(Vector2(x, 0), Vector2(x, size.y), Color.WHITE, 1.0)
	draw_rect(r, Color(1, 1, 1, 0.3), false, 1.0)
