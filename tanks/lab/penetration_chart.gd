class_name PenetrationChart
extends Control
## 거리-관통력 그래프. 선택한 포의 모든 탄종 곡선 + 현재 거리(세로선) + 기준 장갑(가로선).

const MAX_DIST := 2500.0
const COLORS := [Color(1.0, 0.75, 0.2), Color(0.4, 0.85, 1.0), Color(0.9, 0.45, 0.9)]

var shells: Array = []
var selected: GunSpec
var distance_m := 500.0
## 마우스가 가리키는 구역의 유효장갑(mm). 0 이면 표시 안 함
var ref_mm := 0.0
var ref_label := ""


func _ready() -> void:
	custom_minimum_size = Vector2(420, 210)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func refresh(p_shells: Array, p_selected: GunSpec, p_dist: float, p_ref: float, p_ref_label: String) -> void:
	shells = p_shells
	selected = p_selected
	distance_m = p_dist
	ref_mm = p_ref
	ref_label = p_ref_label
	queue_redraw()


func _draw() -> void:
	var font := get_theme_default_font()
	var fs := 12
	var area := Rect2(Vector2(42, 8), size - Vector2(52, 34))
	draw_rect(area, Color(0, 0, 0, 0.35))
	var max_mm := 50.0
	for g in shells:
		max_mm = maxf(max_mm, g.penetration_mm(0.0))
	max_mm = maxf(max_mm, ref_mm)
	max_mm = ceilf(max_mm * 1.1 / 50.0) * 50.0
	var to_px := func(d: float, mm: float) -> Vector2:
		return Vector2(area.position.x + area.size.x * d / MAX_DIST, area.end.y - area.size.y * mm / max_mm)
	# 격자
	for d in range(0, int(MAX_DIST) + 1, 500):
		var x: float = to_px.call(d, 0.0).x
		draw_line(Vector2(x, area.position.y), Vector2(x, area.end.y), Color(1, 1, 1, 0.12))
		draw_string(font, Vector2(x - 14, area.end.y + 14), "%dm" % d, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color(1, 1, 1, 0.7))
	for mm in range(0, int(max_mm) + 1, 50):
		var y: float = to_px.call(0.0, mm).y
		draw_line(Vector2(area.position.x, y), Vector2(area.end.x, y), Color(1, 1, 1, 0.12))
		draw_string(font, Vector2(4, y + 4), "%d" % mm, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color(1, 1, 1, 0.7))
	# 곡선
	for i in shells.size():
		var g: GunSpec = shells[i]
		var pts := PackedVector2Array()
		for k in 51:
			var d := MAX_DIST * k / 50.0
			pts.append(to_px.call(d, g.penetration_mm(d)))
		var c: Color = COLORS[i % COLORS.size()]
		var w := 3.0 if g == selected else 1.5
		if g != selected:
			c.a = 0.55
		draw_polyline(pts, c, w, true)
		draw_string(font, area.position + Vector2(area.size.x - 210, 14 + 14 * i), g.shell_name, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)
	# 기준 장갑선
	if ref_mm > 0.0:
		var y: float = to_px.call(0.0, ref_mm).y
		draw_dashed_line(Vector2(area.position.x, y), Vector2(area.end.x, y), Color(1, 0.3, 0.3), 1.5, 6.0)
		draw_string(font, Vector2(area.position.x + 4, y - 4), "%s 유효 %.0fmm" % [ref_label, ref_mm], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(1, 0.5, 0.5))
	# 현재 거리
	var x := area.position.x + area.size.x * clampf(distance_m / MAX_DIST, 0.0, 1.0)
	draw_line(Vector2(x, area.position.y), Vector2(x, area.end.y), Color(1, 1, 1, 0.8), 1.0)
	if selected:
		var p := selected.penetration_mm(distance_m)
		var py: float = to_px.call(distance_m, p).y
		draw_circle(Vector2(x, py), 4.0, Color.WHITE)
		draw_string(font, Vector2(x + 6, py - 6), "%.0fmm" % p, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
	draw_string(font, Vector2(area.position.x, size.y - 2), "관통력(수직 0° 환산, mm) vs 거리", HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 1, Color(1, 1, 1, 0.6))
