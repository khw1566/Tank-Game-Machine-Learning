class_name SoundField
extends RefCounted
## 전장의 소리 사건(포성·탄착·피탄). 오디오를 재생하지 않고 "누가 어디서 무엇을 들었나"만 계산한다.
## 사람에게 들리는 정보를 AI 관측(TankPerception)에 같은 형태로 넣기 위한 것.
##
##   gunfire  발사음. 수 km 까지 들리고 방향을 대략 알 수 있다(적이 안 보여도 "어디선가 쐈다")
##   impact   포탄이 땅·바위·전차에 맞는 소리(가까이 떨어지면 "나를 노리고 있다")
##   hit_me   내 전차가 맞은 충격음. 맞은 쪽 방향을 안다(어느 면을 맞았는지)
## 엔진 소리는 사건이 아니라 연속음이라 TankPerception 이 매번 주변 전차 속도로 계산한다.

const GUNFIRE := 0
const IMPACT := 1
const HIT_ME := 2
const KIND_IDS := ["gunfire", "impact", "hit_me"]
## 이만큼 지난 사건은 버린다(초)
const KEEP_S := 4.0
## 이보다 작은 크기는 안 들림
const AUDIBLE := 0.05

var events: Array = []   # {"t", "kind", "pos": Vector3, "src": 발사 전차 이름, "target": 맞은 전차 이름}
var time := 0.0


func advance(dt: float) -> void:
	time += dt
	while not events.is_empty() and time - float(events[0].t) > KEEP_S:
		events.pop_front()


func add(kind: int, pos: Vector3, src := "", target := "") -> void:
	events.append({"t": time, "kind": kind, "pos": pos, "src": src, "target": target})


## Tank.shot_fired 에 연결
func on_shot(shooter: Tank, r: Dictionary) -> void:
	add(GUNFIRE, _v(r.get("from", [])) if r.has("from") else shooter.muzzle_position(), shooter.name)
	if r.has("hit_pos"):
		add(IMPACT, _v(r.hit_pos), shooter.name, str(r.get("target_name", "")) if r.get("hit", false) else "")


## 들리는 크기(0~1). 거리에 따라 로그로 줄어든다: 발사음은 ~4km, 탄착음은 ~1.5km 에서 사라진다.
static func loudness(kind: int, d: float) -> float:
	match kind:
		GUNFIRE:
			return clampf(1.0 - log(maxf(d, 10.0) / 10.0) / log(10.0) / 2.6, 0.0, 1.0)
		IMPACT:
			return clampf(0.8 - log(maxf(d, 5.0) / 5.0) / log(10.0) / 3.1, 0.0, 1.0)
	return 1.0


## 엔진·궤도 소리 크기(0~1): 빠를수록 크고 ~500m 에서 사라진다
static func engine_loudness(speed_mps: float, d: float) -> float:
	var s := clampf(0.3 + 0.7 * absf(speed_mps) / 8.0, 0.0, 1.0)
	return s * clampf(1.0 - log(maxf(d, 20.0) / 20.0) / log(10.0) / 1.4, 0.0, 1.0)


static func _v(a) -> Vector3:
	return Vector3(a[0], a[1], a[2]) if a is Array and a.size() >= 3 else Vector3.ZERO
