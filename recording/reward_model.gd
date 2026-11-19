class_name RewardModel
extends RefCounted
## 점수(보상) 계산 규칙. 게임 관찰용 점수와 나중의 강화학습 보상이 같은 함수를 쓴다.
##
## 사격 결과(DamageModel.resolve_shot 의 Dictionary)와 시간 경과를 받아
## [{"tank": 이름, "team": 팀, "value": 점수, "reason": 사유}] 목록을 돌려준다.
## 가중치는 weights 사전 하나에 모여 있고, 기록 파일 머리(header)에 그대로 저장되므로
## 나중에 어떤 규칙으로 학습했는지 재현할 수 있다.

const DEFAULT_WEIGHTS := {
	"hit": 0.2,                 # 적에게 명중(관통 여부 무관)
	"penetration": 1.0,         # 적 장갑 관통
	"crew_wounded": 0.25,       # 적 승무원 부상 1명
	"crew_kia": 0.5,            # 적 승무원 전사 1명
	"module_damaged": 0.1,      # 적 모듈 손상
	"module_destroyed": 0.3,    # 적 모듈 파괴
	"knockout": 5.0,            # 적 전차 전투불능
	"miss": -0.05,              # 빗나감/차단(탄 소모)
	"friendly_fire": -1.0,      # 아군 피격 시 위 점수에 곱하는 배율(음수 = 감점)
	"friendly_knockout": 0.0,   # 아군 격파 시 추가 감점(음수). 기존 기록은 0으로 재현.
	"victim_scale": 1.0,        # 피격 전차는 공격자가 얻은 피해 점수 × 이 값만큼 감점(0 이면 감점 없음)
	"time_per_s": -0.002,       # 살아 있는 전차 1대당 초당 점수(교착 방지용 작은 감점)
	"win": 10.0,                # 에피소드 승리 팀 전원
	"loss": -10.0,              # 에피소드 패배 팀 전원
}

var weights := DEFAULT_WEIGHTS.duplicate()


func _init(overrides := {}) -> void:
	weights.merge(overrides, true)


## 사격 1발에서 생기는 점수. target_team 은 명중한 전차의 팀(-1 = 명중 없음)
func shot_rewards(shooter: String, shooter_team: int, target: String, target_team: int, r: Dictionary) -> Array:
	var out := []
	if not r.get("hit", false):
		out.append(_e(shooter, shooter_team, weights.miss, "miss"))
		return out
	if bool(weights.get("live_target_only", false)) and not bool(r.get("target_was_combat_effective", true)):
		out.append(_e(shooter, shooter_team, weights.miss, "wreck_hit"))
		return out
	var dmg := 0.0
	var reasons := []
	dmg += weights.hit
	reasons.append("hit")
	if r.get("penetrated", false):
		dmg += weights.penetration
		reasons.append("penetration")
	for d in r.get("damage", []):
		if d.get("before", "") == d.get("after", ""):
			continue
		if d.kind == "crew":
			if d.after == TankDamageState.CREW_KIA:
				dmg += weights.crew_kia
				reasons.append("crew_kia")
			elif d.after == TankDamageState.CREW_WOUNDED:
				dmg += weights.crew_wounded
				reasons.append("crew_wounded")
		elif d.kind == "module":
			if d.after == TankDamageState.MOD_DESTROYED:
				dmg += weights.module_destroyed
				reasons.append("module_destroyed")
			elif d.after == TankDamageState.MOD_DAMAGED:
				dmg += weights.module_damaged
				reasons.append("module_damaged")
	for ev in r.get("events", []):
		if str(ev).begins_with("knocked_out:"):
			dmg += weights.knockout
			reasons.append("knockout")
	var reason := "+".join(reasons)
	if target_team == shooter_team:
		out.append(_e(shooter, shooter_team, dmg * absf(weights.friendly_fire) * -1.0, "friendly_" + reason))
		if "knockout" in reasons and float(weights.friendly_knockout) < 0:
			out.append(_e(shooter, shooter_team, float(weights.friendly_knockout), "friendly_knockout"))
	else:
		out.append(_e(shooter, shooter_team, dmg, reason))
	if weights.victim_scale != 0.0 and target != "":
		# 명중 보너스(hit)는 피격자 감점에서 뺀다: 맞았다는 사실보다 실제 피해에 반응하도록
		var loss: float = (dmg - weights.hit) * weights.victim_scale
		if loss > 0.0:
			out.append(_e(target, target_team, -loss, "took_" + reason))
	return out


## 시간 경과 점수(살아 있는 전차마다)
func time_reward(tank: String, team: int, dt: float) -> Dictionary:
	return _e(tank, team, weights.time_per_s * dt, "time")


## 에피소드 종료 점수. winner = -1 이면 무승부(점수 없음)
func end_rewards(tanks: Array, winner: int) -> Array:
	var out := []
	if winner < 0:
		return out
	for t in tanks:
		out.append(_e(t.name, t.team, weights.win if t.team == winner else weights.loss,
			"win" if t.team == winner else "loss"))
	return out


## 화면 표시용 짧은 한국어 사유("took_hit+penetration+knockout" → "피격: 격파")
static func short_reason(reason: String) -> String:
	var names := {"knockout": "격파", "crew_kia": "승무원 전사", "penetration": "관통", "module_destroyed": "모듈 파괴",
		"crew_wounded": "승무원 부상", "module_damaged": "모듈 손상", "hit": "명중", "miss": "빗나감",
		"win": "승리", "loss": "패배", "time": "시간"}
	names.merge({"near_miss": "지근탄", "closing": "거리 단축", "close_150m": "150m 접근", "close_100m": "100m 접근",
		"close_60m": "60m 접근", "close_30m": "30m 접근", "timeout": "교전 시간 초과", "wreck_hit": "잔해 사격"})
	names.merge({"aim_alignment": "적 방향 조준", "aim_overlap": "조준점 일치", "aimed_fire": "유효 조준 사격",
		"friendly_aim_fire": "아군 방향 발포", "friendly_knockout": "아군 격파 추가 감점"})
	if names.has(reason):
		return names[reason]
	var prefix := ""
	var body := reason
	if body.begins_with("took_"):
		prefix = "피격: "
		body = body.trim_prefix("took_")
	elif body.begins_with("friendly_"):
		prefix = "아군 사격: "
		body = body.trim_prefix("friendly_")
	var parts := body.split("+")
	for k in names:
		if k in parts:
			return prefix + names[k]
	return prefix + body


static func _e(tank: String, team: int, value: float, reason: String) -> Dictionary:
	return {"tank": tank, "team": team, "value": snappedf(value, 0.0001), "reason": reason}
