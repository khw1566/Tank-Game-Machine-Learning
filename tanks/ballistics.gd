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


## 도탄 확률. 입사각이 (임계각 − 18°) 부터 서서히 오르고 (임계각 + 5°) 에서 확실해진다.
## 판이 탄 구경에 비해 얇을수록(과구경) 잘 튕기지 않는다. 고폭탄은 임계각이 89° 라 사실상 도탄 없음.
## → 경사가 큰 T-34 전면(60°)은 비스듬히 맞으면 도탄 가능성이 눈에 띄게 생긴다.
const RICOCHET_RAMP_DEG := 18.0
const RICOCHET_FULL_DEG := 5.0

static func ricochet_chance(gun: GunSpec, plate_mm: float, impact_angle_deg: float) -> float:
	if gun.caliber_mm >= 3.0 * plate_mm:
		return 0.0
	var start := gun.ricochet_angle_deg - RICOCHET_RAMP_DEG
	var full := gun.ricochet_angle_deg + RICOCHET_FULL_DEG
	var k := clampf((impact_angle_deg - start) / (full - start), 0.0, 1.0)
	var overmatch := clampf(1.6 - 0.4 * gun.caliber_mm / maxf(plate_mm, 1.0), 0.2, 1.0)
	return pow(k, 1.5) * overmatch


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


const GRAVITY := 9.8


## 거리 range_m 의 같은 높이 표적을 맞히려면 조준선보다 포를 얼마나 더 올려야 하는가(라디안, 공기저항 무시).
## 포구초속이 빠를수록 작다 → 88mm 는 원거리에서 거리 오차에 덜 민감(탄도가 평탄).
static func superelevation_rad(gun: GunSpec, range_m: float) -> float:
	var v := maxf(gun.muzzle_velocity_ms, 1.0)
	return 0.5 * asin(clampf(GRAVITY * range_m / (v * v), -1.0, 1.0))


## 조준선 대비 낙차(m): 포를 수평으로 쐈을 때 range_m 에서 탄이 떨어지는 높이
static func drop_at_m(gun: GunSpec, range_m: float) -> float:
	var t := range_m / maxf(gun.muzzle_velocity_ms, 1.0)
	return 0.5 * GRAVITY * t * t
