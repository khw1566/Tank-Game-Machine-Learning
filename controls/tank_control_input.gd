class_name TankControlInput
extends RefCounted
## 모든 전차가 공유하는 조작 입력 1프레임 분량.
## 사람(키보드)과 AI(액션 벡터)가 같은 형식을 쓰므로, 학습된 정책과 사람 조작을 그대로 비교·기록할 수 있다.
##
## 액션 벡터 (길이 6, ACTION_LABELS 순서):
##   0 left_track       -1(후진) ~ +1(전진)   왼쪽 무한궤도 스로틀
##   1 right_track      -1 ~ +1               오른쪽 무한궤도 스로틀
##   2 brake             0 ~ 1                 브레이크(양쪽 궤도 감속)
##   3 turret_traverse  -1(반시계/좌) ~ +1(시계/우)
##   4 gun_elevation    -1(내림) ~ +1(올림)
##   5 fire              > 0.5 이면 발사(재장전 완료 시)

const ACTION_SIZE := 6
const ACTION_LABELS := ["left_track", "right_track", "brake", "turret_traverse", "gun_elevation", "fire"]

var left_track := 0.0
var right_track := 0.0
var brake := 0.0
var turret_traverse := 0.0
var gun_elevation := 0.0
var fire := false


static func from_array(a) -> TankControlInput:
	var c := TankControlInput.new()
	if a.size() < ACTION_SIZE:
		push_error("TankControlInput: action vector needs %d values" % ACTION_SIZE)
		return c
	c.left_track = clampf(a[0], -1.0, 1.0)
	c.right_track = clampf(a[1], -1.0, 1.0)
	c.brake = clampf(a[2], 0.0, 1.0)
	c.turret_traverse = clampf(a[3], -1.0, 1.0)
	c.gun_elevation = clampf(a[4], -1.0, 1.0)
	c.fire = float(a[5]) > 0.5
	return c


func to_array() -> PackedFloat32Array:
	return PackedFloat32Array([left_track, right_track, brake, turret_traverse, gun_elevation, 1.0 if fire else 0.0])


func to_dict() -> Dictionary:
	var a := to_array()
	var d := {}
	for i in ACTION_SIZE:
		d[ACTION_LABELS[i]] = snappedf(a[i], 0.001)
	return d
