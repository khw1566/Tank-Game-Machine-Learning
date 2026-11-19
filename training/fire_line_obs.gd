class_name FireLineObs
extends RefCounted
## V6 사격선 관측: 지금 포를 쏘면 탄이 지나갈 선 위에 아군·적이 있는지.
## 팀킬 방지(FINAL-V5run1: 아군 격파 184 > 적 격파 130). 아군 위치는 무전으로 아는 정보로 보고 실제 위치를 쓰고,
## 적은 지금 보이는(perception visible_now) 전차만 쓴다 — 보이지 않는 적의 위치는 알려 주지 않는다.
##
##   fireline.ally_in_line   포 사선(차체 폭 + 4mrad 여유) 안 1500m 이내에 살아 있는 아군이 있으면 1
##   fireline.ally_dist      그 아군까지 거리 / 500 (최대 1)
##   fireline.ally_offset    사선에서 벗어난 정도(0 = 정중앙, 1 = 가장자리)
##   fireline.enemy_in_line  사선 안에 지금 보이는 적이 있으면 1
##   fireline.enemy_dist     그 적까지 거리 / 500 (최대 1)
##   fireline.ally_blocks    아군이 적보다 앞에 있거나(적이 없으면 아군만 있으면) 1 — 쏘면 아군이 맞는다

const VERSION := 1
const LABELS := ["fireline.ally_in_line", "fireline.ally_dist", "fireline.ally_offset", "fireline.enemy_in_line", "fireline.enemy_dist",
	"fireline.ally_blocks"]
const RANGE := 1500.0
const HALF_WIDTH := 2.0
const MARGIN_MRAD := 4.0


static func compute(observer: Tank, perception: TankPerception, tanks: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(LABELS.size())
	if not observer.damage.is_combat_effective():
		return out
	var origin := observer.muzzle_position()
	var dir := observer.gun_direction()
	var ally_d := INF
	var ally_off := 0.0
	var enemy_d := INF
	for t in tanks:
		if t == observer or not t.damage.is_combat_effective():
			continue
		var enemy: bool = t.team != observer.team
		if enemy:
			var c: Dictionary = perception.contacts.get(t.name, {})
			if c.is_empty() or not bool(c.get("visible_now", false)):
				continue
		var center: Vector3 = t.global_position + Vector3.UP * t.spec.total_height() * 0.5
		var rel := center - origin
		var along := rel.dot(dir)
		if along <= 0.0 or along > RANGE:
			continue
		var perp := (rel - dir * along).length()
		var limit := HALF_WIDTH + along * MARGIN_MRAD / 1000.0
		if perp > limit:
			continue
		if enemy:
			enemy_d = minf(enemy_d, along)
		elif along < ally_d:
			ally_d = along
			ally_off = perp / limit
	if ally_d < INF:
		out[0] = 1.0
		out[1] = minf(ally_d / 500.0, 1.0)
		out[2] = clampf(ally_off, 0.0, 1.0)
		out[5] = 1.0 if ally_d < enemy_d else 0.0
	if enemy_d < INF:
		out[3] = 1.0
		out[4] = minf(enemy_d / 500.0, 1.0)
	return out
