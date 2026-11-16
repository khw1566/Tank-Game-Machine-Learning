class_name TankAgent
extends RefCounted
## 전차 1대의 "탑승자" 묶음: 시점(TankView) + 관측(TankPerception) + (선택) 규칙 AI.
## 사람·규칙 AI·학습 정책이 모두 같은 경로를 쓴다:
##   관측  = perception.vector (PERCEIVE_EVERY 틱마다 갱신, 사이에는 직전 값 유지 = 사람의 반응 지연 정도)
##   행동  = 길이 ACTION_SIZE(11): TankControlInput 6 + TankView 5. apply_action() 이 시점을 바꾸고
##           전차장·자유 시선이면 포탑·포 입력을 막는다(사람이 B/C 를 눌렀을 때와 같음).
##
## 학습 정책 연결 예:
##   var ag := TankAgent.new(map, tank, sounds)
##   매 물리 틱: if ag.update(tanks, dt): obs = ag.perception.vector  → 정책 → action(11)
##              ag.apply_action(action, dt)

const PERCEIVE_EVERY := 3
const ACTION_SIZE := TankControlInput.ACTION_SIZE + TankView.ACTION_SIZE

var tank: Tank
var view: TankView
var perception: TankPerception
var ai: ScriptedAI
var last_action: Array = []
var _tick := 0
var _since := 0.0


func _init(map: HillMap, p_tank: Tank, sounds: SoundField = null, p_ai: ScriptedAI = null) -> void:
	tank = p_tank
	view = TankView.new()
	perception = TankPerception.new(map, tank, view, sounds)
	ai = p_ai


static func action_labels() -> Array:
	return TankControlInput.ACTION_LABELS + TankView.ACTION_LABELS


## 관측 갱신 주기 관리. 이번 틱에 관측을 새로 만들었으면 true
func update(tanks: Array, dt: float) -> bool:
	_since += dt
	var fresh := _tick % PERCEIVE_EVERY == 0
	_tick += 1
	if fresh:
		perception.observe(tanks, _since)
		_since = 0.0
	return fresh


## 행동 11개 적용(6개만 주면 시점은 그대로)
func apply_action(a: Array, dt: float) -> void:
	if a.size() >= ACTION_SIZE:
		view.apply_action(a.slice(TankControlInput.ACTION_SIZE, ACTION_SIZE), tank, dt)
	tank.control = view.apply_locks(TankControlInput.from_array(a))
	last_action = a


## 규칙 AI 한 틱: 관측 갱신 → 행동 → 적용. 반환 = 행동
func step_ai(tanks: Array, dt: float) -> Array:
	update(tanks, dt)
	var a := ai.act(tank, perception)
	apply_action(a, dt)
	return a
