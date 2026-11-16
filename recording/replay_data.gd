class_name ReplayData
extends RefCounted
## events.jsonl(MatchRecorder 기록)을 읽어 메모리에 올리고, 임의 시각의 전차 자세를 보간해 준다.
## 리플레이 뷰어와 보고서 생성기가 같이 쓴다. 렌더링과 무관한 순수 데이터.

var path := ""
var header := {}
var frames: Array = []       # {"tick", "t", "s", "score", "r"}
var shots: Array = []
var rewards: Array = []
var knockouts: Array = []
var decisions: Array = []
var end := {}
var fields := {}             # 필드 이름 -> 배열 인덱스
var error := ""


static func load_file(p: String) -> ReplayData:
	var d := ReplayData.new()
	d.path = p
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		d.error = "파일을 열 수 없음: %s" % p
		return d
	while not f.eof_reached():
		var line := f.get_line()
		if line.is_empty():
			continue
		var e = JSON.parse_string(line)
		if typeof(e) != TYPE_DICTIONARY:
			continue
		match e.get("type", ""):
			"header":
				d.header = e
			"frame":
				d.frames.append(e)
			"shot":
				d.shots.append(e)
			"reward":
				d.rewards.append(e)
			"knockout":
				d.knockouts.append(e)
			"decision":
				d.decisions.append(e)
			"end":
				d.end = e
	if d.header.is_empty():
		d.error = "header 없음(형식이 다른 파일): %s" % p
		return d
	if d.header.get("format", "") != MatchRecorder.FORMAT:
		d.error = "알 수 없는 형식: %s" % d.header.get("format", "")
	var ff: Array = d.header.get("frame_fields", MatchRecorder.FRAME_FIELDS)
	for i in ff.size():
		d.fields[ff[i]] = i
	return d


func ok() -> bool:
	return error == "" and not frames.is_empty()


func tanks() -> Array:
	return header.get("tanks", [])


func duration() -> float:
	return float(frames[-1].t) if not frames.is_empty() else 0.0


func tank_name(id: int) -> String:
	var tl := tanks()
	return tl[id].name if id >= 0 and id < tl.size() else "-"


func tank_team(id: int) -> int:
	var tl := tanks()
	return int(tl[id].team) if id >= 0 and id < tl.size() else -1


## t 바로 앞 프레임 인덱스(이진 탐색)
func frame_index(t: float) -> int:
	var lo := 0
	var hi := frames.size() - 1
	if hi < 0:
		return -1
	if t <= frames[0].t:
		return 0
	if t >= frames[hi].t:
		return hi
	while hi - lo > 1:
		var mid := (lo + hi) >> 1
		if frames[mid].t <= t:
			lo = mid
		else:
			hi = mid
	return lo


func field(row: Array, name: String, default = 0.0):
	var i: int = fields.get(name, -1)
	return row[i] if i >= 0 and i < row.size() else default


## 시각 t 의 전차 id 자세: {"xform", "turret_yaw", "gun_pitch", "status", "speed", "action"}
func pose(id: int, t: float) -> Dictionary:
	var i := frame_index(t)
	var a: Array = frames[i].s[id]
	var b: Array = a
	var w := 0.0
	if i + 1 < frames.size():
		var t0: float = frames[i].t
		var t1: float = frames[i + 1].t
		b = frames[i + 1].s[id]
		w = clampf((t - t0) / maxf(t1 - t0, 1e-6), 0.0, 1.0)
	var qa := Quaternion(field(a, "qx"), field(a, "qy"), field(a, "qz"), field(a, "qw")).normalized()
	var qb := Quaternion(field(b, "qx"), field(b, "qy"), field(b, "qz"), field(b, "qw")).normalized()
	var pa := Vector3(field(a, "x"), field(a, "y"), field(a, "z"))
	var pb := Vector3(field(b, "x"), field(b, "y"), field(b, "z"))
	var xf := Transform3D(Basis(qa.slerp(qb, w)), pa.lerp(pb, w))
	return {"xform": xf,
		"turret_yaw": lerp_angle(field(a, "turret_yaw"), field(b, "turret_yaw"), w),
		"gun_pitch": lerpf(field(a, "gun_pitch"), field(b, "gun_pitch"), w),
		"status": int(field(a, "status")),
		"speed": (field(a, "track_l") + field(a, "track_r")) * 0.5,
		"reload": field(a, "reload"),
		"action": [field(a, "a_left"), field(a, "a_right"), field(a, "a_brake"),
			field(a, "a_traverse"), field(a, "a_elev"), field(a, "a_fire")]}


## 시각 t 의 팀 점수 [team0, team1]
func score_at(t: float) -> Array:
	return frames[frame_index(t)].get("score", [0, 0])


## 전차 id 의 2D 동선 [Vector3(x, z, t)] (프레임마다)
func path_of(id: int, until_t := INF) -> PackedVector3Array:
	var out := PackedVector3Array()
	for fr in frames:
		if fr.t > until_t:
			break
		var row: Array = fr.s[id]
		out.append(Vector3(field(row, "x"), field(row, "z"), fr.t))
	return out


## 맵 범위의 절반(m)
func map_half() -> float:
	return float(header.get("map", {}).get("size_m", 1200.0)) * 0.5


static func vec3(a) -> Vector3:
	return Vector3(a[0], a[1], a[2]) if a is Array and a.size() >= 3 else Vector3.ZERO


## 사격 e 의 발사점·탄착점(월드)
func shot_points(e: Dictionary) -> Array:
	var r: Dictionary = e.r
	var from := vec3(r.get("from", []))
	var to: Vector3 = vec3(r.hit_pos) if r.has("hit_pos") else from + vec3(r.get("dir", [0, 0, -1])) * 600.0
	return [from, to]
