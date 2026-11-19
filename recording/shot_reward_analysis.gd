class_name ShotRewardAnalysis
extends RefCounted

static func esc(value) -> String:
	return str(value).replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")

static func is_shot_reason(reason: String) -> bool:
	return reason.begins_with("hit") or reason.begins_with("friendly_") or reason.begins_with("took_hit") \
		or reason in ["miss", "wreck_hit", "near_miss", "near_penetration", "aimed_fire"]

static func enrich(data: ReplayData) -> void:
	var by_tick := {}
	for reward in data.rewards:
		if not is_shot_reason(str(reward.reason)): continue
		var tick := int(reward.tick)
		if not by_tick.has(tick): by_tick[tick] = []
		by_tick[tick].append(reward)
	for shot in data.shots:
		shot["shooter_name"] = data.tank_name(int(shot.shooter))
		shot["target_name"] = data.tank_name(int(shot.target))
		if shot.r.has("reward_events"):
			shot.r["reward_source"] = "recorded"
			continue
		var events := []
		for reward in by_tick.get(int(shot.tick), []):
			var actor := int(reward.tank)
			if actor == int(shot.shooter) or (actor == int(shot.target) and str(reward.reason).begins_with("took_")):
				events.append({"tank": data.tank_name(actor), "team": reward.get("team", data.tank_team(actor)),
					"value": reward.value, "reason": reward.reason})
		shot.r["reward_events"] = events
		shot.r["reward_source"] = "legacy_tick" if not events.is_empty() else "missing"

static func total(event: Dictionary, tank: String) -> float:
	var value := 0.0
	for reward in event.r.get("reward_events", []):
		if str(reward.tank) == tank:
			value += float(reward.value)
	return value

static func explanation(reason: String) -> String:
	if reason == "friendly_knockout": return "아군을 전투불능으로 만들어 기본 아군 피해 감점에 추가된 팀킬 감점입니다."
	if reason == "friendly_aim_fire": return "발사 순간 아군과 조준점이 겹친 정도에 비례하는 감점입니다. 실제 명중 여부와 별개입니다."
	if reason == "aimed_fire": return "보이는 적의 예상 위치에 탄도·이동 보정 조준점이 일치한 상태에서 발포한 보상입니다."
	if reason == "near_miss": return "표적까지 거리로 정한 유효 반경 안에서, 탄과 표적 사이 최근접 거리가 작을수록 보상합니다. 에피소드 상한이 적용됩니다."
	if reason == "near_penetration": return "관통력이 유효장갑에 가까워진 비관통 사격의 개선 보상입니다. 에피소드 상한이 적용됩니다."
	if reason == "miss": return "명중하지 않은 사격의 탄약 소모 감점입니다."
	if reason == "wreck_hit": return "이미 전투불능인 잔해를 맞힌 사격입니다. 유효 명중 보상은 없습니다."
	var parts := PackedStringArray()
	if reason.begins_with("friendly_"): parts.append("아군 사격자에게 피해 점수의 배율을 적용한 감점입니다.")
	elif reason.begins_with("took_"): parts.append("피격 전차가 받은 실제 피해에 대한 감점입니다. 명중 자체의 보너스는 제외합니다.")
	else: parts.append("사격자에게 적용된 실제 타격 보상입니다.")
	if "penetration" in reason: parts.append("장갑 관통")
	if "crew_" in reason: parts.append("승무원 피해")
	if "module_" in reason: parts.append("모듈 손상·파괴")
	if "knockout" in reason: parts.append("전투불능")
	return " · ".join(parts)

static func html(event: Dictionary) -> String:
	var rows: Array = event.r.get("reward_events", [])
	var source := str(event.r.get("reward_source", "recorded" if event.r.has("reward_events") else "missing"))
	var out := PackedStringArray(["<h2>이 사격의 점수 변동</h2>"])
	if rows.is_empty():
		return "".join(out) + "<p class='note'>이 기록에는 사격별 보상 내역이 없습니다. 0점으로 간주하거나 현재 규칙으로 다시 계산하지 않습니다.</p>"
	var names := []
	for reward in rows:
		if str(reward.tank) not in names: names.append(str(reward.tank))
	out.append("<div class='tiles'>")
	for actor in names:
		var delta := total(event, actor)
		out.append("<div class='tile'><div class='tl'>%s · 이 사격으로 변한 보상</div><div class='tv %s'>%+.3f</div></div>" % [esc(actor), "positive" if delta >= 0 else "negative", delta])
	out.append("</div><p class='note'>%s 승패·시간·지속 조준 보상은 이 사격의 피해 점수에 합치지 않습니다.</p>" % ("발사·탄착 시점에 기록한 내역입니다." if source == "recorded" else "이전 기록은 같은 물리 틱의 보상으로 연결한 추정치입니다. 동시 사격은 정확히 분리되지 않을 수 있습니다."))
	out.append("<div class='table-wrap'><table><thead><tr><th>전차</th><th>항목</th><th>변동</th><th>직전 누적</th><th>직후 누적</th><th>적용 이유</th></tr></thead><tbody>")
	for reward in rows:
		var value := float(reward.value)
		out.append("<tr><td>%s</td><td>%s</td><td class='%s'>%+.3f</td><td>%s</td><td>%s</td><td style='text-align:left;min-width:260px;white-space:normal'>%s</td></tr>" % [esc(reward.tank), esc(RewardModel.short_reason(str(reward.reason))), "positive" if value >= 0 else "negative", value,
			"%.3f" % float(reward.before) if reward.has("before") else "미기록", "%.3f" % float(reward.after) if reward.has("after") else "미기록", esc(explanation(str(reward.reason)))])
	out.append("</tbody></table></div>")
	return "".join(out)
