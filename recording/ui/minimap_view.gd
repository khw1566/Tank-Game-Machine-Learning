class_name MinimapView
extends Control
## 위에서 본 전장 지도(게임 중 관찰 오버레이와 리플레이 뷰어가 같이 사용).
## 소유자가 매 프레임 set_state() 로 그릴 내용을 넘긴다. 좌표: 화면 위 = −Z, 오른쪽 = +X.

const TEAM_COLORS := [Color("#e8590c"), Color("#1c7ed6")]
const KIND_COLORS := {"penetration": Color("#e03131"), "non_penetration": Color("#fab005"),
	"ricochet": Color.WHITE, "blocked": Color("#adb5bd"), "miss": Color(0.7, 0.7, 0.7, 0.5)}

const OBSTACLE_COLORS := {"tree": Color(0.17, 0.45, 0.2, 0.75), "woods": Color(0.15, 0.4, 0.17, 0.55),
	"treeline": Color(0.15, 0.4, 0.17, 0.55), "hedge": Color(0.2, 0.38, 0.12, 0.9), "wall": Color(0.75, 0.73, 0.68, 0.95),
	"building": Color(0.62, 0.35, 0.25, 0.95), "rock": Color(0.45, 0.45, 0.45, 0.85)}

var half := 600.0
var terrain_tex: Texture2D
var obstacles: Array = []
## [{"pos": Vector3, "yaw": float, "turret": float(월드), "team": int, "alive": bool, "name": String, "selected": bool}]
var tanks: Array = []
## name -> {"points": PackedVector3Array/PackedVector2Array(x,z), "team": int}
var paths := {}
## [{"from": Vector3, "to": Vector3, "kind": String, "age": float(초, 0 = 방금)}]
var shots: Array = []
var show_paths := true
var show_shots := true
var shot_fade_s := 6.0


## 맵 기록(HillMap.to_record())으로 배경 준비
func set_map(rec: Dictionary) -> void:
	half = float(rec.get("size_m", 1200.0)) * 0.5
	obstacles = rec.get("obstacles", [])
	var img := ReportBuilder.terrain_image(rec, 256)
	terrain_tex = ImageTexture.create_from_image(img)
	queue_redraw()


func set_state(p_tanks: Array, p_paths: Dictionary, p_shots: Array) -> void:
	tanks = p_tanks
	paths = p_paths
	shots = p_shots
	queue_redraw()


func to_px(p: Vector3) -> Vector2:
	return Vector2((p.x + half) / (2.0 * half) * size.x, (p.z + half) / (2.0 * half) * size.y)


func _draw() -> void:
	var r := Rect2(Vector2.ZERO, size)
	if terrain_tex:
		draw_texture_rect(terrain_tex, r, false, Color(1, 1, 1, 0.92))
	else:
		draw_rect(r, Color(0.2, 0.25, 0.18, 0.8))
	var k := size.x / (2.0 * half)
	for o in obstacles:
		var c: Color = OBSTACLE_COLORS.get(o.type, Color(0.45, 0.45, 0.45, 0.8))
		if o.has("a") and o.has("b"):   # 생울타리·돌담: 선
			draw_line(to_px(Vector3(o.a[0], 0, o.a[2])), to_px(Vector3(o.b[0], 0, o.b[2])), c, 2.0)
		elif o.has("blobs"):            # 숲: 덩어리 원 여러 개
			for b in o.blobs:
				draw_circle(to_px(Vector3(b[0][0], 0, b[0][2])), maxf(float(b[1]) * k, 1.0), c)
		elif o.type != "village":
			draw_circle(to_px(Vector3(o.pos[0], 0, o.pos[2])), maxf(float(o.radius) * k, 1.0), c)
	if show_paths:
		for n in paths:
			var pts: PackedVector2Array = PackedVector2Array()
			for v in paths[n].points:
				pts.append(to_px(Vector3(v.x, 0, v.z)) if v is Vector3 else to_px(Vector3(v.x, 0, v.y)))
			if pts.size() >= 2:
				var col: Color = TEAM_COLORS[clampi(paths[n].team, 0, 1)]
				col.a = 0.85
				draw_polyline(pts, col, 1.5, true)
	if show_shots:
		for s in shots:
			var col: Color = KIND_COLORS.get(s.kind, Color.WHITE)
			var a := clampf(1.0 - s.age / shot_fade_s, 0.0, 1.0)
			if a > 0.0:
				draw_line(to_px(s.from), to_px(s.to), Color(1, 1, 0.8, 0.6 * a), 1.0)
			if s.kind != "miss":
				draw_circle(to_px(s.to), 2.6, Color(0, 0, 0, 0.6))
				draw_circle(to_px(s.to), 2.0, col)
	for t in tanks:
		var p := to_px(t.pos)
		var col: Color = TEAM_COLORS[clampi(t.team, 0, 1)]
		if not t.alive:
			draw_line(p + Vector2(-4, -4), p + Vector2(4, 4), Color.BLACK, 2.5)
			draw_line(p + Vector2(-4, 4), p + Vector2(4, -4), Color.BLACK, 2.5)
			draw_line(p + Vector2(-4, -4), p + Vector2(4, 4), col, 1.5)
			draw_line(p + Vector2(-4, 4), p + Vector2(4, -4), col, 1.5)
			continue
		# 차체 방향 삼각형(−Z = 정면 → 화면 위), 포탑 방향 선
		var fwd := Vector2(-sin(t.yaw), -cos(t.yaw))
		var right := Vector2(-fwd.y, fwd.x)
		var tri := PackedVector2Array([p + fwd * 7.0, p - fwd * 4.0 + right * 4.5, p - fwd * 4.0 - right * 4.5])
		if t.get("selected", false):
			draw_circle(p, 9.0, Color(1, 1, 1, 0.35))
		draw_colored_polygon(tri, col)
		draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color.BLACK, 1.0)
		var tf := Vector2(-sin(t.turret), -cos(t.turret))
		draw_line(p, p + tf * 11.0, Color.WHITE, 1.5)
	draw_rect(r, Color(0, 0, 0, 0.8), false, 2.0)
