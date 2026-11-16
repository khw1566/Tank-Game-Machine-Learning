class_name Ballistics
extends RefCounted
## 관통 판정 수식 모음(정적 함수만, 상태 없음 → 헤드리스·병렬 학습에 안전).


## 입사각(°, 판 법선 기준)에 피모 효과(normalization)와 과구경(overmatch)을 반영한 유효 각도.
static func effective_angle_deg(gun: GunSpec, plate_mm: float, impact_angle_deg: float) -> float:
	var norm := gun.normalization_deg
	# 포 구경이 판 두께의 2배를 넘으면 판이 탄두를 "잡아채지" 못하고 쉽게 꺾여 들어간다.
	var overmatch := gun.caliber_mm / maxf(plate_mm, 1.0)
	if overmatch > 2.0:
		norm *= minf(overmatch / 2.0, 3.0)
	return maxf(impact_angle_deg - norm, 0.0)


## 유효 장갑 두께(mm) = t / cos(θ). 80° 이상은 상한을 둔다.
static func effective_thickness_mm(gun: GunSpec, plate_mm: float, impact_angle_deg: float) -> float:
	var a := minf(effective_angle_deg(gun, plate_mm, impact_angle_deg), 80.0)
	return plate_mm / cos(deg_to_rad(a))


## 도탄 확률. 과구경(구경 ≥ 3×두께)이면 도탄하지 않는다.
static func ricochet_chance(gun: GunSpec, plate_mm: float, impact_angle_deg: float) -> float:
	if gun.caliber_mm >= 3.0 * plate_mm:
		return 0.0
	var start := gun.ricochet_angle_deg - 5.0
	var full := gun.ricochet_angle_deg + 5.0
	return clampf((impact_angle_deg - start) / (full - start), 0.0, 1.0)


## 관통 확률(도탄 포함). AI 관측값이나 보고서용 기대값으로 사용.
static func penetration_probability(gun: GunSpec, distance_m: float, plate_mm: float, impact_angle_deg: float) -> float:
	var pen := gun.penetration_mm(distance_m)
	var eff := effective_thickness_mm(gun, plate_mm, impact_angle_deg)
	var sigma := maxf(pen * gun.penetration_sigma, 0.001)
	var p_pen := normal_cdf((pen - eff) / sigma)
	return p_pen * (1.0 - ricochet_chance(gun, plate_mm, impact_angle_deg))


## 표준정규분포 누적분포함수(Abramowitz-Stegun 7.1.26, 오차 < 1.5e-7).
static func normal_cdf(x: float) -> float:
	var z := absf(x) / sqrt(2.0)
	var t := 1.0 / (1.0 + 0.3275911 * z)
	var y := 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * exp(-z * z)
	return 0.5 * (1.0 + (y if x >= 0.0 else -y))
