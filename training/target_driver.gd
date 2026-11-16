class_name TargetDriver
extends RefCounted
## 사격 훈련용 "움직이는 표적" 조종사. 몇 초마다 새 속도·선회를 골라 몰고, 맵 가장자리에 가까우면 가운데로 돈다.
## 난수는 에피소드 시드에서 만든 rng 를 쓰므로 같은 설정이면 똑같이 움직인다(재현 가능).

var rng := RandomNumberGenerator.new()
var half_size := 550.0
var speed_range := Vector2(0.4, 1.0)
var _throttle := 0.7
var _turn := 0.0
var _left_s := 0.0


func _init(p_seed: int, p_half_size := 550.0) -> void:
	rng.seed = p_seed
	half_size = p_half_size


## 한 틱 조작(길이 6)
func act(me: Tank, dt: float) -> Array:
	_left_s -= dt
	if _left_s <= 0.0:
		_left_s = rng.randf_range(3.0, 7.0)
		_throttle = rng.randf_range(speed_range.x, speed_range.y)
		_turn = rng.randf_range(-0.45, 0.45) if rng.randf() < 0.6 else 0.0
	var p := me.global_position
	var turn := _turn
	if absf(p.x) > half_size - 120.0 or absf(p.z) > half_size - 120.0:
		# 가운데 쪽으로 선회(전차 로컬 -Z = 정면, yaw + = 좌)
		var want := atan2(p.x, p.z)
		var err := wrapf(want - me.global_rotation.y, -PI, PI)
		turn = clampf(err * 2.0, -0.8, 0.8)
	return [_throttle - turn, _throttle + turn, 0.0, 0.0, 0.0, 0.0]
