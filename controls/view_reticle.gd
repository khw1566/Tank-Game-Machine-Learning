class_name TankViewReticle
extends Control
## TankViewCamera 의 화면 표시.
##  - 포수 조준경: 십자선(포 축), 거리별 조준 눈금(현재 탄종 탄도로 계산), 조준 오차 원, 장전 상태
##  - 전차장 / 자유 시선: 포가 겨눈 지점 표시(◇ 포), 왼쪽 아래 방위판(차체·포탑·시선 방향)

var rig: TankViewCamera

const INK := Color(0.05, 0.05, 0.05, 0.95)
const SIGHT := Color(0.1, 0.1, 0.1, 0.9)
const MARK := Color(1.0, 0.85, 0.2, 0.95)


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if rig == null or rig.tank == null or not is_instance_valid(rig.tank):
		return
	var p := rig.tank
	match rig.mode:
		TankViewCamera.GUNNER:
			_draw_gunner(p)
			_draw_compass(p)
		TankViewCamera.COMMANDER:
			var c := size * 0.5
			draw_line(c - Vector2(8, 0), c + Vector2(8, 0), MARK, 1.5)
			draw_line(c - Vector2(0, 8), c + Vector2(0, 8), MARK, 1.5)
			_draw_gun_marker(p)
			_draw_compass(p)
		_:
			if rig.free_look:
				_draw_gun_marker(p)
				_draw_compass(p)


## 화면 중앙에서 1 rad 가 몇 px 인가(수직 시야각 기준)
func _px_per_rad() -> float:
	return size.y * 0.5 / tan(deg_to_rad(rig.fov) * 0.5)


func _draw_gunner(p: Tank) -> void:
	var c := size * 0.5
	var f := _px_per_rad()
	var r_view := minf(size.x, size.y) * 0.47
	# 조준경 바깥은 어둡게
	var w := maxf(size.x, size.y)
	draw_arc(c, r_view + w * 0.5, 0.0, TAU, 72, Color(0, 0, 0, 0.88), w)
	draw_arc(c, r_view, 0.0, TAU, 72, INK, 3.0)
	# 십자선(가운데는 비움)
	var gap := 10.0
	draw_line(c + Vector2(-r_view, 0), c + Vector2(-gap, 0), SIGHT, 2.0)
	draw_line(c + Vector2(gap, 0), c + Vector2(r_view, 0), SIGHT, 2.0)
	draw_line(c + Vector2(0, -r_view), c + Vector2(0, -gap), SIGHT, 2.0)
	# 거리 눈금: 거리 r 의 표적은 포 축보다 초과앙각만큼 아래에 보인다
	var shell := p.current_shell()
	var font := get_theme_default_font()
	var last_y := c.y
	for r in TankViewCamera.RANGE_MARKS:
		var y := c.y + tan(Ballistics.superelevation_rad(shell, r)) * f
		if y > c.y + r_view - 10.0:
			break
		var big: bool = r % 400 == 0
		var half := 14.0 if big else 7.0
		draw_line(Vector2(c.x - half, y), Vector2(c.x + half, y), SIGHT, 2.0)
		if big and y - last_y > 9.0:
			draw_string(font, Vector2(c.x + half + 4.0, y + 5.0), str(r / 100), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, SIGHT)
			last_y = y
	draw_line(Vector2(c.x, c.y + gap), Vector2(c.x, last_y), SIGHT, 1.0)
	# 조준 오차(1σ) 원
	var spread := maxf(p.aim_error_mrad * 0.001 * f, 2.0)
	draw_arc(c, spread, 0.0, TAU, 32, Color(0.85, 0.1, 0.1, 0.8), 1.5)
	# 장전·탄종
	var loaded := p.reload_timer <= 0.0 and p.damage.can_fire()
	var txt := "%s  %s  (눈금 ×100m)" % [shell.shell_name, "장전 완료" if loaded else "재장전 %.1fs" % p.reload_timer]
	draw_string(font, Vector2(c.x - 140.0, c.y + r_view - 24.0), txt, HORIZONTAL_ALIGNMENT_CENTER, 280, 14,
		Color(0.2, 0.9, 0.2) if loaded else Color(0.95, 0.6, 0.2))


## 포가 겨눈 지점(800m 앞)을 화면에 표시
func _draw_gun_marker(p: Tank) -> void:
	var pt := p.muzzle_position() + p.gun_direction() * 800.0
	if rig.is_position_behind(pt):
		return
	var s := rig.unproject_position(pt)
	var d := 7.0
	draw_polyline(PackedVector2Array([s + Vector2(0, -d), s + Vector2(d, 0), s + Vector2(0, d), s + Vector2(-d, 0), s + Vector2(0, -d)]), MARK, 2.0)
	draw_string(get_theme_default_font(), s + Vector2(10, 5), "포", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, MARK)


## 왼쪽 아래 방위판: 위 = 지금 보는 방향. 차체(사각형)·포(선)·시선(부채꼴)
func _draw_compass(p: Tank) -> void:
	var c := Vector2(60.0, size.y - 60.0)
	var r := 40.0
	draw_circle(c, r, Color(0, 0, 0, 0.45))
	draw_arc(c, r, 0.0, TAU, 40, Color(1, 1, 1, 0.6), 1.5)
	var view := rig.view_yaw()
	var hull := p.global_rotation.y - view
	var fwd := _screen_dir(hull)
	var right := Vector2(-fwd.y, fwd.x)
	var hl := 16.0
	var hw := 9.0
	var corners := PackedVector2Array([c + fwd * hl + right * hw, c + fwd * hl - right * hw,
		c - fwd * hl - right * hw, c - fwd * hl + right * hw, c + fwd * hl + right * hw])
	draw_polyline(corners, Color(0.8, 0.8, 0.8), 2.0)
	draw_line(c, c + _screen_dir(hull + p.turret_yaw) * (r - 2.0), MARK, 3.0)
	var half := atan(tan(deg_to_rad(rig.fov) * 0.5) * size.x / maxf(size.y, 1.0))
	draw_line(c, c + _screen_dir(half) * r, Color(0.4, 0.9, 1.0, 0.8), 1.0)
	draw_line(c, c + _screen_dir(-half) * r, Color(0.4, 0.9, 1.0, 0.8), 1.0)


## 방위(+ = 좌) → 화면 방향(위 = 정면)
static func _screen_dir(a: float) -> Vector2:
	return Vector2(-sin(a), -cos(a))
