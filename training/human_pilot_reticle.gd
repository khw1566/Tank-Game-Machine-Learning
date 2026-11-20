class_name HumanPilotReticle
extends TankViewReticle
## 실제 전투 시범 화면 표시. 카메라 중앙 조준(centered_pointer)에서는 화면 중앙 = 겨누려는 곳,
## 포가 실제로 향한 곳은 따로 움직이므로 둘을 나눠 그린다.
##  - 가운데 원: 조준점(마우스). 포탑·포가 여기를 따라간다
##  - 노란 십자 + 거리 눈금: 포 축(현재 탄종 탄도). 거리 r 의 표적은 r 눈금에 놓고 쏜다
##  - 포수 조준경에서는 바깥을 어둡게 해 실제 조준경 시야만 보인다

var pilot: HumanPilot


func _draw() -> void:
	if rig == null or rig.tank == null or not is_instance_valid(rig.tank):
		return
	var p := rig.tank
	var c := size * 0.5
	if rig.mode == TankViewCamera.GUNNER:
		var r_view := minf(size.x, size.y) * 0.47
		var w := maxf(size.x, size.y)
		draw_arc(c, r_view + w * 0.5, 0.0, TAU, 72, Color(0, 0, 0, 0.88), w)
		draw_arc(c, r_view, 0.0, TAU, 72, INK, 3.0)
	if rig.mode == TankViewCamera.COMMANDER or rig.free_look:
		draw_line(c - Vector2(8, 0), c + Vector2(8, 0), MARK, 1.5)
		draw_line(c - Vector2(0, 8), c + Vector2(0, 8), MARK, 1.5)
		_draw_gun_marker(p)
	else:
		draw_arc(c, 10.0, 0.0, TAU, 32, Color(1, 1, 1, 0.9), 2.0)
		draw_circle(c, 1.5, Color(1, 1, 1, 0.9))
		_draw_gun_axis(p)
	_draw_compass(p)


## 포 축과 거리 눈금(현재 탄종)
func _draw_gun_axis(p: Tank) -> void:
	var pt := p.muzzle_position() + p.gun_direction() * 1000.0
	if rig.is_position_behind(pt):
		return
	var s := rig.unproject_position(pt)
	var f := _px_per_rad()
	var gap := 6.0
	draw_line(s + Vector2(-26, 0), s + Vector2(-gap, 0), MARK, 2.0)
	draw_line(s + Vector2(gap, 0), s + Vector2(26, 0), MARK, 2.0)
	draw_line(s + Vector2(0, -18), s + Vector2(0, -gap), MARK, 2.0)
	var shell := p.current_shell()
	var font := get_theme_default_font()
	var last_y := s.y
	for r in TankViewCamera.RANGE_MARKS:
		var y := s.y + tan(Ballistics.superelevation_rad(shell, r)) * f
		if y - s.y > size.y * 0.4:
			break
		var big: bool = r % 400 == 0
		var half := 12.0 if big else 6.0
		draw_line(Vector2(s.x - half, y), Vector2(s.x + half, y), MARK, 1.5)
		if big and y - last_y > 9.0:
			draw_string(font, Vector2(s.x + half + 4.0, y + 5.0), str(r / 100), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, MARK)
			last_y = y
	draw_line(Vector2(s.x, s.y + gap), Vector2(s.x, last_y), MARK, 1.0)
	var spread := maxf(p.aim_error_mrad * 0.001 * f, 2.0)
	draw_arc(s, spread, 0.0, TAU, 32, Color(0.95, 0.15, 0.1, 0.85), 1.5)
	var loaded := p.reload_timer <= 0.0 and p.damage.can_fire()
	draw_string(font, Vector2(s.x - 90.0, s.y + 44.0 + (last_y - s.y)), "%s %s" % [shell.shell_name,
		"장전" if loaded else "%.1fs" % p.reload_timer], HORIZONTAL_ALIGNMENT_CENTER, 180, 13,
		Color(0.2, 0.9, 0.2) if loaded else Color(0.95, 0.6, 0.2))
