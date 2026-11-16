class_name HitGeometry
extends RefCounted
## 탄 궤적(광선)이 어느 부품·장갑구역에 맞았는지, 입사각이 얼마인지 계산하는 진입점.
## 실제 형상은 TankShape(볼록 다면체 부품: 차체·궤도·포탑·포방패·포신)가 가진다.


## 전차 로컬 좌표의 광선으로 명중 구역을 판정.
## origin, dir: 전차 로컬 좌표. 빗나가면 {"hit": false}.
## 반환 키: hit, part, zone, t, entry(차체좌표), path_len, plate_normal(차체좌표), impact_angle_deg, slope_deg
static func trace(spec: TankSpec, turret_yaw: float, origin: Vector3, dir: Vector3,
		gun_pitch := 0.0, skip: Array = []) -> Dictionary:
	return spec.shape().trace(turret_yaw, gun_pitch, origin, dir, skip)


## 포탑 회전 기저(포탑 좌표 -> 차체 좌표). turret_yaw: 라디안, + = 위에서 볼 때 반시계 = 좌회전.
static func turret_basis(turret_yaw: float) -> Basis:
	return Basis(Vector3.UP, turret_yaw)


## 포탑 좌표계 위치를 차체 좌표로.
static func turret_to_hull(spec: TankSpec, turret_yaw: float, p: Vector3) -> Vector3:
	return spec.turret_origin() + turret_basis(turret_yaw) * p


## 사수 위치(월드)와 표적 Transform 으로 "aim_world 를 조준했을 때" 로컬 광선을 만든다.
static func local_ray_to_point(target_xform: Transform3D, shooter_world: Vector3, aim_world: Vector3) -> Array:
	var inv := target_xform.affine_inverse()
	var o := inv * shooter_world
	var a := inv * aim_world
	return [o, (a - o).normalized()]
