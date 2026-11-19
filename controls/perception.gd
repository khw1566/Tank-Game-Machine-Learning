class_name TankPerception
extends RefCounted
## AI 관측: "사람이 그 시점 화면에서 보고 듣는 것"만 담은 고정 길이 벡터.
##
## 사람이 3인칭 / 포수 조준경 / 전차장 시점으로 보는 화면을 픽셀 대신 특징값으로 요약한다
## (헤드리스 학습에서는 렌더링을 하지 않으므로 픽셀 관측은 수십 배 느리다).
## 원칙:
##   - 지금 시점의 시야(화면·조준경 원) 안에 있고, LineOfSight 로 탐지된 전차만 보인다.
##     탐지는 실제 눈 위치(전차장 큐폴라 / 포수 조준경)에서, 광학 배율(확대)만큼 멀리 본다.
##   - 정확한 거리는 주지 않는다. 대신 화면에 보이는 크기(픽셀, 정수로 반올림)를 준다 → 확대할수록 거리 추정이 정확해진다.
##   - 전차 종류·차체/포탑 방향은 충분히 크게 보일 때(IDENTIFY_PX 이상)만 알 수 있다.
##   - 화면 밖으로 나간 전차는 MEMORY_S 초 동안 "마지막으로 본 방향"으로 기억한다(사람의 기억).
##   - 포수 조준경에서는 표적이 십자선에서 얼마나 벗어났는지(mrad)가 보인다. 거리 눈금은 탄종별로 고정이라
##     정책이 탄종 정보와 함께 배울 수 있다(자동 탄도해·정확한 거리 없음).
##   - 소리: 포성·탄착·피탄 방향과 크기, 주변 엔진 소리(8방위). 방향은 머리(시선) 기준.
##   - 자기 전차 계기(속도·기어·포탑 각·재장전·승무원/모듈 상태)는 HUD 에 보이므로 포함.
##
## 벡터 구성(labels() 와 같은 순서, 총 SIZE 개):
##   self     Tank.observation() 12 + TankDamageState.observation() 13 + 장전 탄종 3 + 내 전차 종류 3
##   view     시점 3(원핫) + free_look + 시선 방위 sin/cos(차체 기준) + 시선 앙각 + 배율(log)
##   contact  적 슬롯 ENEMY_SLOTS 개 + 아군 슬롯 ALLY_SLOTS 개 × CONTACT_LABELS
##   scan     화면 격자 SCAN_ROWS × SCAN_COLS 시선마다 [거리(로그, 양자화), 장애물, 수풀 밀도] (지형 윤곽·엄폐물)
##   sound    최근 소리 SOUND_SLOTS 개 × SOUND_LABELS + 엔진 소리 8방위

const ENEMY_SLOTS := 6   # V6: 1대6 에서 적 6대 모두를 관측(이전 4)
const ALLY_SLOTS := 3
const MEMORY_S := 12.0
## 화면 높이(px) 기준. 보이는 크기를 픽셀로 바꿔 반올림한다(1080p 화면에서 사람이 보는 크기)
const SCREEN_H_PX := 1080.0
## 이 이상 크게 보여야 전차 종류·방향을 식별
const IDENTIFY_PX := 18.0
const TANK_TYPES := ["tiger1", "sherman75", "t34_76"]
const SCAN_ROWS := 3
const SCAN_COLS := 15
const SCAN_RANGE := 2000.0
## 화면 격자는 관측 SCAN_EVERY 번마다 한 번 갱신(사이에는 직전 값)
const SCAN_EVERY := 2
const SOUND_SLOTS := 4
const ENGINE_SECTORS := 8
## 포수 조준경 오차 정규화(mrad)
const GUN_ERR_SCALE := 50.0

const CONTACT_LABELS := [
	"present", "visible_now", "age", "bearing_sin", "bearing_cos", "elevation",
	"screen_x", "screen_y", "size_px_log", "visible_frac", "moving", "knocked_out", "identified",
	"type_tiger1", "type_sherman75", "type_t34_76",
	"hull_aspect_sin", "hull_aspect_cos", "turret_aspect_sin", "turret_aspect_cos",
	"in_gunsight", "gun_err_x", "gun_err_y",
	"team",   # V6: 적 +1, 아군 -1 (슬롯 위치와 별개로 명시. 자기 대전에서 같은 차종이 적이었던 V5 의 팀킬 대책)
]
const SOUND_LABELS := ["present", "gunfire", "impact", "hit_me", "bearing_sin", "bearing_cos", "loudness", "age"]

var map: HillMap
var tank: Tank
var view: TankView
var sounds: SoundField
## 기억: 표적 노드 이름(내부 식별용, 관측에는 track 번호만 나간다) -> 접촉 사전
var contacts := {}
var vector := PackedFloat32Array()
var last_sounds: Array = []
var last_enemy_flash := {}
var last_engine := PackedFloat32Array()
var time := 0.0
var _next_track := 1
var _scan_cache := PackedFloat32Array()
var _scan_count := 0
## 게임 속도 설정(configure). 기본값 = 원래 상수(설정이 없는 옛 에피소드도 그대로 재현)
var memory_s := MEMORY_S
var identify_px := IDENTIFY_PX
var detect_range_scale := 1.0
var min_fraction := LineOfSight.MIN_FRACTION


## 탐지·식별을 쉽게 하는 게임 속도 설정. pace = {memory_s, identify_px, detect_range, min_fraction}
func configure(pace: Dictionary) -> void:
	memory_s = float(pace.get("memory_s", MEMORY_S))
	identify_px = float(pace.get("identify_px", IDENTIFY_PX))
	detect_range_scale = float(pace.get("detect_range", 1.0))
	min_fraction = float(pace.get("min_fraction", LineOfSight.MIN_FRACTION))


func _init(p_map: HillMap, p_tank: Tank, p_view: TankView, p_sounds: SoundField = null) -> void:
	map = p_map
	tank = p_tank
	view = p_view
	sounds = p_sounds


## 라벨 389개를 만드는 데 문자열 포맷이 수백 번 들어가므로 한 번만 만든다(매 관측마다 부르면 학습 시간의 ~30%)
static var _labels_cache: Array = []


static func size() -> int:
	if _labels_cache.is_empty():
		_labels_cache = _build_labels()
	return _labels_cache.size()


static func labels() -> Array:
	if _labels_cache.is_empty():
		_labels_cache = _build_labels()
	return _labels_cache.duplicate()


static func _build_labels() -> Array:
	var out := []
	for l in Tank.OBSERVATION_LABELS:
		out.append("self." + l)
	for l in TankDamageState.OBSERVATION_LABELS:
		out.append("dmg." + l)
	for i in 3:
		out.append("self.ammo_%d" % i)
	for ty in TANK_TYPES:
		out.append("self.type_" + ty)
	for l in ["mode_third", "mode_gunner", "mode_commander", "free_look", "yaw_sin", "yaw_cos", "pitch", "zoom_log"]:
		out.append("view." + l)
	for i in ENEMY_SLOTS + ALLY_SLOTS:
		var p := ("enemy%d." % i) if i < ENEMY_SLOTS else ("ally%d." % (i - ENEMY_SLOTS))
		for l in CONTACT_LABELS:
			out.append(p + l)
	for r in SCAN_ROWS:
		for c in SCAN_COLS:
			for l in ["depth", "obstacle", "foliage"]:
				out.append("scan%d_%d.%s" % [r, c, l])
	for i in SOUND_SLOTS:
		for l in SOUND_LABELS:
			out.append("sound%d.%s" % [i, l])
	for i in ENGINE_SECTORS:
		out.append("engine.sector%d" % i)
	return out


## 관측 갱신. tanks = 전장의 전차(시뮬레이터가 넘김; 정책에는 결과 벡터만 간다), dt = 지난 갱신 후 시간
func observe(tanks: Array, dt: float) -> PackedFloat32Array:
	time += dt
	var out := PackedFloat32Array()
	var t0 := Time.get_ticks_usec()
	_self_features(out)
	_view_features(out)
	var t1 := Time.get_ticks_usec()
	_update_contacts(tanks)
	_contact_features(out)
	var t2 := Time.get_ticks_usec()
	_scan_features(out)
	var t3 := Time.get_ticks_usec()
	_sound_features(out, tanks)
	var t4 := Time.get_ticks_usec()
	perf_self_us += t1 - t0
	perf_contacts_us += t2 - t1
	perf_scan_us += t3 - t2
	perf_sound_us += t4 - t3
	perf_observations += 1
	vector = out
	return out


## 학습 성능 계측(µs 누적, 모든 관측 합). training_env 가 에피소드마다 읽고 0 으로 돌린다
static var perf_self_us := 0
static var perf_contacts_us := 0
static var perf_scan_us := 0
static var perf_sound_us := 0
static var perf_observations := 0
static var perf_los_rays := 0
static var perf_scans := 0


# ---------------------------------------------------------------- 자기·시점

func _self_features(out: PackedFloat32Array) -> void:
	out.append_array(tank.observation())
	out.append_array(tank.damage.observation())
	for i in 3:
		out.append(1.0 if tank.ammo_index == i else 0.0)
	for ty in TANK_TYPES:
		out.append(1.0 if tank.spec.id == ty else 0.0)


func _view_features(out: PackedFloat32Array) -> void:
	for m in 3:
		out.append(1.0 if view.mode == m else 0.0)
	out.append(1.0 if view.free_look else 0.0)
	var y := view.yaw_rel_hull(tank)
	out.append(sin(y))
	out.append(cos(y))
	out.append(clampf(view.pitch(tank) / 0.5, -1.0, 1.0))
	out.append(log(view.magnification()) / log(2.0) / 3.5)


# ---------------------------------------------------------------- 보이는 전차

## 지금 시점에서 화면에 들어오고 탐지된 전차를 기억에 반영
func _update_contacts(tanks: Array) -> void:
	var xf := view.eye_transform(tank, map)
	var fov := view.fov()
	var fov_rad := deg_to_rad(fov)
	var sensor := view.sensor_position(tank)
	var mag := view.magnification()
	for c in contacts.values():
		c.visible_now = false
		c.screen = null
		c.gun_err = null
	for t in tanks:
		if t == tank or not is_instance_valid(t):
			continue
		var center: Vector3 = t.global_transform * Vector3(0.0, t.spec.total_height() * 0.5, t.spec.turret_offset_z * 0.5)
		var sp = TankView.screen_point(xf, fov, center)
		if not view.on_screen(sp, 0.03):
			continue
		var s := LineOfSight.spot(map, tank, t, sensor, mag, detect_range_scale, min_fraction)
		perf_los_rays += int(s.get("rays", 0))
		if not s.detected:
			continue
		var to := center - sensor
		var dist := maxf(to.length(), 1.0)
		var ang_h := 2.0 * atan(t.spec.total_height() * 0.5 / dist)
		var px := roundf(ang_h / fov_rad * SCREEN_H_PX)
		var c: Dictionary = contacts.get(t.name, {})
		if c.is_empty():
			c = {"track": _next_track, "gun_err": null, "screen": null}
			_next_track += 1
			contacts[t.name] = c
		var identified := px >= identify_px
		c.enemy = t.team != tank.team
		c.target_name = str(t.name)  # 내부 대응용. 관측에는 이름이나 노드 참조가 나가지 않는다.
		c.t = time
		c.visible_now = true
		c.screen = sp
		c.world_yaw = atan2(-to.x, -to.z)
		c.elev = asin(clampf(to.y / dist, -1.0, 1.0))
		c.size_px = px
		c.fov = fov
		c.seen_from = sensor
		c.visible_frac = float(s.visible_fraction)
		c.moving = Vector2(t.velocity.x, t.velocity.z).length() > 1.0
		c.knocked_out = not t.damage.is_combat_effective()
		if identified:
			c.type = t.spec.id
			var back := atan2(to.x, to.z)  # 표적 → 나 방위
			c.hull_aspect = wrapf(t.global_rotation.y - back, -PI, PI)
			c.turret_aspect = wrapf(t.global_rotation.y + t.turret_yaw - back, -PI, PI)
		if view.mode == TankView.GUNNER:
			var gb := Basis.looking_at(tank.gun_direction(), Vector3.UP)
			var l := gb.inverse() * (center - tank.muzzle_position()).normalized()
			if l.z < 0.0:
				# + x = 십자선 오른쪽, + y = 위 (rad)
				c.gun_err = Vector2(atan2(l.x, -l.z), atan2(l.y, -l.z))
	for k in contacts.keys():
		if time - float(contacts[k].t) > memory_s:
			contacts.erase(k)


## 적/아군 접촉을 우선순위(지금 보임 → 최근 → 크게 보임) 순으로
func sorted_contacts(enemy: bool) -> Array:
	var arr := contacts.values().filter(func(c): return c.enemy == enemy)
	arr.sort_custom(func(a, b):
		if a.visible_now != b.visible_now:
			return a.visible_now
		if a.knocked_out != b.knocked_out:
			return not a.knocked_out
		if absf(float(a.t) - float(b.t)) > 0.01:
			return float(a.t) > float(b.t)
		return float(a.size_px) > float(b.size_px))
	return arr


func _contact_features(out: PackedFloat32Array) -> void:
	var hull_yaw := tank.global_rotation.y
	for pass_i in 2:
		var arr := sorted_contacts(pass_i == 0)
		var n := ENEMY_SLOTS if pass_i == 0 else ALLY_SLOTS
		for i in n:
			if i >= arr.size():
				for k in CONTACT_LABELS.size():
					out.append(0.0)
				continue
			var c: Dictionary = arr[i]
			var b := wrapf(float(c.world_yaw) - hull_yaw, -PI, PI)
			var sp = c.screen
			var ty: String = c.get("type", "")
			var ha: float = c.get("hull_aspect", 0.0)
			var ta: float = c.get("turret_aspect", 0.0)
			var known := ty != ""
			var ge = c.gun_err
			out.append_array(PackedFloat32Array([
				1.0, 1.0 if c.visible_now else 0.0, clampf((time - float(c.t)) / memory_s, 0.0, 1.0),
				sin(b), cos(b), clampf(float(c.elev) / 0.2, -1.0, 1.0),
				sp.x / TankView.ASPECT if sp != null else 0.0, sp.y if sp != null else 0.0,
				log(maxf(float(c.size_px), 1.0)) / log(2.0) / 10.0, float(c.visible_frac),
				1.0 if c.moving else 0.0, 1.0 if c.knocked_out else 0.0, 1.0 if known else 0.0,
				1.0 if ty == TANK_TYPES[0] else 0.0, 1.0 if ty == TANK_TYPES[1] else 0.0, 1.0 if ty == TANK_TYPES[2] else 0.0,
				sin(ha) if known else 0.0, cos(ha) if known else 0.0, sin(ta) if known else 0.0, cos(ta) if known else 0.0,
				1.0 if ge != null else 0.0,
				clampf(ge.x * 1000.0 / GUN_ERR_SCALE, -1.0, 1.0) if ge != null else 0.0,
				clampf(ge.y * 1000.0 / GUN_ERR_SCALE, -1.0, 1.0) if ge != null else 0.0,
				1.0 if c.enemy else -1.0,
			]))


# ---------------------------------------------------------------- 화면 격자(지형·엄폐물)

func _scan_features(out: PackedFloat32Array) -> void:
	# 화면 윤곽은 천천히 변하므로 SCAN_EVERY 번에 한 번만 다시 잰다(학습 속도)
	_scan_count += 1
	if _scan_cache.size() == SCAN_ROWS * SCAN_COLS * 3 and _scan_count % SCAN_EVERY != 1:
		out.append_array(_scan_cache)
		return
	perf_scans += 1
	var cache := PackedFloat32Array()
	var xf := view.eye_transform(tank, map)
	var th := tan(deg_to_rad(view.fov()) * 0.5)
	var space := map.get_world_3d().direct_space_state
	var w := TankView.GUNSIGHT_RADIUS * 0.7 if view.mode == TankView.GUNNER else TankView.ASPECT * 0.9
	var h := TankView.GUNSIGHT_RADIUS * 0.7 if view.mode == TankView.GUNNER else 0.8
	var exclude := [tank.get_rid()]
	var lmax := log(1.0 + SCAN_RANGE)
	var o := xf.origin
	var cells := []
	cells.resize(SCAN_ROWS * SCAN_COLS * 3)
	for c in SCAN_COLS:
		var sx := w * (-1.0 + 2.0 * float(c) / float(SCAN_COLS - 1))
		var ends := []
		for r in SCAN_ROWS:
			var sy := h * (1.0 - 2.0 * float(r) / float(SCAN_ROWS - 1))
			var d := (xf.basis * Vector3(sx * th, sy * th, -1.0)).normalized()
			var to := o + d * SCAN_RANGE
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(o, to, Tank.LAYER_GROUND, exclude))
			var obstacle := 0.0
			if not hit.is_empty():
				var col: Object = hit.collider
				obstacle = 0.0 if col and str(col.get_meta("kind", "")) == "terrain" else 1.0
				to = hit.position
			ends.append([to, obstacle])
		# 수풀 밀도는 가운데 줄 시선 하나로 재서 열 전체에 쓴다(잎 볼륨 계산이 가장 비싸다)
		var mid: Vector3 = ends[SCAN_ROWS / 2][0]
		var fol := 1.0 - float(LineOfSight.foliage(map, o, mid).transmittance)
		for r in SCAN_ROWS:
			var to: Vector3 = ends[r][0]
			var k := (r * SCAN_COLS + c) * 3
			cells[k] = snappedf(log(1.0 + o.distance_to(to)) / lmax, 1.0 / 32.0)
			cells[k + 1] = ends[r][1]
			cells[k + 2] = snappedf(fol, 0.1)
	for v in cells:
		cache.append(v)
	_scan_cache = cache
	out.append_array(cache)


# ---------------------------------------------------------------- 소리

func notice_launch(shooter: Tank, result: Dictionary) -> void:
	if shooter.team == tank.team:
		return
	var point := SoundField._v(result.get("from", []))
	var eye := view.eye_transform(tank, map)
	if eye.origin.distance_to(point) > 1800 or not view.on_screen(TankView.screen_point(eye, view.fov(), point)):
		return
	var visible := LineOfSight.ray(map, eye.origin, point, [tank.get_rid(), shooter.get_rid()])
	if float(visible.transmittance) >= LineOfSight.POINT_VISIBLE:
		last_enemy_flash = {"time": time, "position": point}


func _sound_features(out: PackedFloat32Array, tanks: Array) -> void:
	var me := tank.global_position
	var head := tank.global_rotation.y + view.yaw_rel_hull(tank)
	last_sounds = []
	if sounds:
		for i in range(sounds.events.size() - 1, -1, -1):
			var e: Dictionary = sounds.events[i]
			var kind: int = e.kind
			var age := sounds.time - float(e.t)
			if age > SoundField.KEEP_S:
				break
			if kind == SoundField.GUNFIRE and e.src == tank.name:
				continue
			var pos: Vector3 = e.pos
			var loud := 0.0
			if kind == SoundField.IMPACT and e.target == tank.name:
				kind = SoundField.HIT_ME
				loud = 1.0
			else:
				loud = SoundField.loudness(kind, me.distance_to(pos))
			if loud < SoundField.AUDIBLE:
				continue
			var to := pos - me
			var b := wrapf(atan2(-to.x, -to.z) - head, -PI, PI)
			last_sounds.append({"kind": kind, "bearing": b, "loud": snappedf(loud, 0.05), "age": age})
			if last_sounds.size() >= SOUND_SLOTS:
				break
	for i in SOUND_SLOTS:
		if i < last_sounds.size():
			var s: Dictionary = last_sounds[i]
			out.append_array(PackedFloat32Array([1.0, 1.0 if s.kind == 0 else 0.0, 1.0 if s.kind == 1 else 0.0,
				1.0 if s.kind == 2 else 0.0, sin(s.bearing), cos(s.bearing), s.loud, clampf(s.age / SoundField.KEEP_S, 0.0, 1.0)]))
		else:
			for k in SOUND_LABELS.size():
				out.append(0.0)
	var eng := PackedFloat32Array()
	eng.resize(ENGINE_SECTORS)
	eng.fill(0.0)
	for t in tanks:
		if t == tank or not is_instance_valid(t) or not t.damage.can_move():
			continue
		var to: Vector3 = t.global_position - me
		var loud := SoundField.engine_loudness(Vector2(t.velocity.x, t.velocity.z).length(), to.length())
		if loud <= 0.0:
			continue
		var b := wrapf(atan2(-to.x, -to.z) - head, -PI, PI)
		var k := clampi(int((b + PI) / TAU * ENGINE_SECTORS), 0, ENGINE_SECTORS - 1)
		eng[k] = minf(eng[k] + loud, 1.0)
	for k in ENGINE_SECTORS:
		eng[k] = snappedf(eng[k], 0.05)
	last_engine = eng
	out.append_array(eng)


# ---------------------------------------------------------------- 사람이 읽는 요약(HUD·기록·규칙 AI)

## 도수법 방위(차체 기준, + = 좌)
func bearing_deg(c: Dictionary) -> float:
	return rad_to_deg(wrapf(float(c.world_yaw) - tank.global_rotation.y, -PI, PI))


## 보이는 크기로 거리를 어림한다(조준경 거리 눈금으로 재는 것과 같은 방식).
## 종류를 알면 그 전차 높이(type_height), 모르면 평균 높이 2.7m 를 가정. 화면 픽셀을 반올림하므로 확대할수록 정확.
static func estimate_range(c: Dictionary) -> float:
	if c.is_empty():
		return INF
	var h := type_height(str(c.get("type", "")))
	var ang := maxf(float(c.size_px), 0.5) / SCREEN_H_PX * deg_to_rad(float(c.fov))
	return h * 0.5 / tan(ang * 0.5)


## 식별한 전차 종류의 높이(m, 승무원이 아는 적 전차 제원). 모르면 평균 2.7m
static func type_height(ty: String) -> float:
	if ty == "":
		return 2.7
	if not _heights.has(ty):
		var sp := TankDatabase.get_spec(ty)
		_heights[ty] = sp.total_height() if sp else 2.7
	return _heights[ty]

static var _heights := {}


## 기록·HUD 용 요약(벡터와 같은 정보만, 사람이 읽기 쉽게)
func summary() -> Dictionary:
	var seen := []
	for enemy in [true, false]:
		for c in sorted_contacts(enemy):
			var d := {"track": c.track, "enemy": c.enemy, "now": c.visible_now,
				"age_s": snappedf(time - float(c.t), 0.1), "bearing_deg": snappedf(bearing_deg(c), 1.0),
				"elev_deg": snappedf(rad_to_deg(float(c.elev)), 0.1), "px": int(c.size_px),
				"type": c.get("type", "?"), "vis": snappedf(float(c.visible_frac), 0.01)}
			if c.knocked_out:
				d["ko"] = true
			if c.gun_err != null:
				d["gun_err_mrad"] = [snappedf(c.gun_err.x * 1000.0, 0.1), snappedf(c.gun_err.y * 1000.0, 0.1)]
			seen.append(d)
	var heard := []
	for s in last_sounds:
		heard.append({"kind": SoundField.KIND_IDS[s.kind], "bearing_deg": snappedf(rad_to_deg(s.bearing), 1.0), "loud": s.loud})
	return {"view": TankView.MODE_IDS[view.mode], "fov": snappedf(view.fov(), 0.1), "seen": seen, "heard": heard,
		"engine": Array(last_engine)}


## 화면 HUD 한 줄(사람에게도 AI 와 같은 정보만)
func hud_text() -> String:
	var parts := []
	for c in sorted_contacts(true):
		var what: String = {"tiger1": "티거", "sherman75": "셔먼", "t34_76": "T-34"}.get(c.get("type", ""), "미식별 전차")
		var where := "방위 %+.0f°" % bearing_deg(c)
		if c.visible_now:
			parts.append("● %s %s 크기 %dpx 보임 %d%%%s" % [what, where, int(c.size_px), int(float(c.visible_frac) * 100), " 격파됨" if c.knocked_out else ""])
		else:
			parts.append("○ %s %s (%.0f초 전)" % [what, where, time - float(c.t)])
	var snd := []
	for s in last_sounds:
		snd.append("%s %s" % [["포성", "탄착", "피탄!"][s.kind], _dir_word(s.bearing)])
	return "시야(● 보임 ○ 기억): %s\n소리: %s" % ["  |  ".join(parts) if not parts.is_empty() else "-", ", ".join(snd) if not snd.is_empty() else "-"]


static func _dir_word(b: float) -> String:
	var d := rad_to_deg(b)
	if absf(d) < 30.0:
		return "앞"
	if absf(d) > 150.0:
		return "뒤"
	return ("왼쪽" if d > 0.0 else "오른쪽") + ("앞" if absf(d) < 75.0 else ("뒤" if absf(d) > 105.0 else ""))
