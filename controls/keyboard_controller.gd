class_name KeyboardController
extends RefCounted
## 키보드 -> TankControlInput. InputMap 설정 없이 물리 키로 바로 읽는다.
##
##   Q / A : 왼쪽 궤도 전진 / 후진
##   E / D : 오른쪽 궤도 전진 / 후진
##   W / S : 양쪽 궤도 함께 전진 / 후진 (편의 키)
##   Space : 브레이크
##   ← / → : 포탑 좌/우 선회
##   ↑ / ↓ : 포 올림/내림
##   F 또는 Enter : 발사


static func read() -> TankControlInput:
	var c := TankControlInput.new()
	var both := _axis(KEY_W, KEY_S)
	c.left_track = clampf(_axis(KEY_Q, KEY_A) + both, -1.0, 1.0)
	c.right_track = clampf(_axis(KEY_E, KEY_D) + both, -1.0, 1.0)
	c.brake = 1.0 if Input.is_physical_key_pressed(KEY_SPACE) else 0.0
	c.turret_traverse = _axis(KEY_RIGHT, KEY_LEFT)
	c.gun_elevation = _axis(KEY_UP, KEY_DOWN)
	c.fire = Input.is_physical_key_pressed(KEY_F) or Input.is_physical_key_pressed(KEY_ENTER)
	return c


static func _axis(pos_key: Key, neg_key: Key) -> float:
	var v := 0.0
	if Input.is_physical_key_pressed(pos_key):
		v += 1.0
	if Input.is_physical_key_pressed(neg_key):
		v -= 1.0
	return v
