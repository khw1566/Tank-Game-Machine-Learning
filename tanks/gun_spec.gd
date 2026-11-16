class_name GunSpec
extends RefCounted
## 주포 + 주력 철갑탄 1종의 정적 제원.
##
## 관통력 원자료는 "수직에서 30° 경사진 균질압연장갑(RHA)" 기준 표를 사용한다.
## (세 포 모두 같은 기준의 자료가 널리 인용되므로 상호 비교가 일관된다.)
## 모델은 유효장갑 = 두께 / cos(입사각) 을 쓰므로, 30° 표를 1/cos(30°) 로 나눠
## 0°(수직 명중) 환산 관통력을 만든다. 그러면 30° 판을 쏘는 경우 원자료와 정확히 일치한다.

const REFERENCE_ANGLE_DEG := 30.0

var id: String = ""
var display_name: String = ""
var caliber_mm: float = 0.0
var muzzle_velocity_ms: float = 0.0
var shell_name: String = ""
## APCBC(피모철갑), APHE(철갑고폭), AP(고체철갑), APCR(고속철갑), HE(고폭)
var shell_type: String = "APCBC"
var shell_mass_kg: float = 0.0
## 작약(폭약) 질량. 0 이면 고체탄(관통 후 폭발 없음).
var filler_g: float = 0.0
## 관통 후 신관 작동까지 진행 거리(m). 단순화한 지연신관.
var fuse_delay_m: float = 1.2
## [[거리 m, 관통 mm @30°], ...] 거리 오름차순.
var penetration_table_30deg: Array = []
## 피모(캡) 효과로 입사각이 줄어드는 정도(°).
var normalization_deg: float = 4.0
## 이 각도를 넘기면 도탄이 확실해진다(±5° 구간에서 선형 확률).
var ricochet_angle_deg: float = 70.0
## 관통력의 탄마다 편차(정규분포 표준편차, 평균 대비 비율).
var penetration_sigma: float = 0.05
## 숙련 승무원 기준 재장전 시간(초).
var reload_s: float = 6.0
## 수평 분산(1σ, 밀리라디안). 명중 판정 쪽에서 사용.
var dispersion_mrad: float = 0.5
var sources: Array = []


## 수직 명중(0°) 기준 평균 관통력(mm). 표 바깥 거리는 끝 구간 기울기로 외삽.
func penetration_mm(distance_m: float) -> float:
	var t := penetration_table_30deg
	if t.is_empty():
		return 0.0
	var pen30: float
	if t.size() == 1:
		pen30 = t[0][1]
	else:
		var i := 0
		while i < t.size() - 2 and distance_m > float(t[i + 1][0]):
			i += 1
		var d0: float = t[i][0]
		var p0: float = t[i][1]
		var d1: float = t[i + 1][0]
		var p1: float = t[i + 1][1]
		var k := (distance_m - d0) / (d1 - d0)
		if distance_m < d0:
			k = maxf(k, -1.0) # 아주 가까운 거리도 과도하게 외삽하지 않음
		pen30 = lerpf(p0, p1, k)
	return maxf(pen30, 0.0) / cos(deg_to_rad(REFERENCE_ANGLE_DEG))


func label() -> String:
	return "%s · %s" % [display_name, shell_name]


func is_he() -> bool:
	return shell_type == "HE"


## 같은 포의 다른 탄종을 만들 때: 포 공통값을 복사
func variant(p_id: String, p_shell: String, p_type: String) -> GunSpec:
	var g := GunSpec.new()
	g.display_name = display_name
	g.caliber_mm = caliber_mm
	g.reload_s = reload_s
	g.dispersion_mrad = dispersion_mrad
	g.muzzle_velocity_ms = muzzle_velocity_ms
	g.id = p_id
	g.shell_name = p_shell
	g.shell_type = p_type
	return g


func to_dict() -> Dictionary:
	return {
		"id": id, "display_name": display_name, "caliber_mm": caliber_mm,
		"shell_type": shell_type,
		"muzzle_velocity_ms": muzzle_velocity_ms, "shell_name": shell_name,
		"shell_mass_kg": shell_mass_kg, "filler_g": filler_g,
		"fuse_delay_m": fuse_delay_m,
		"penetration_table_30deg": penetration_table_30deg,
		"normalization_deg": normalization_deg,
		"ricochet_angle_deg": ricochet_angle_deg,
		"penetration_sigma": penetration_sigma, "reload_s": reload_s,
		"dispersion_mrad": dispersion_mrad, "sources": sources,
	}
