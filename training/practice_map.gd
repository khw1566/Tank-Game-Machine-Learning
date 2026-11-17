class_name PracticeMap
extends HillMap
## Bounded slopes isolate terrain skills without random ridges at the spawn.
var profile := "flat"
var course_angle := 0.0
var course_center := Vector2.ZERO

func height_at(x: float, z: float) -> float:
	if not _record.is_empty():
		return super.height_at(x, z)
	var p := Vector2(x, z) - course_center
	var along := p.dot(Vector2(-sin(course_angle), cos(course_angle)))
	var across := p.dot(Vector2(cos(course_angle), sin(course_angle)))
	match profile:
		"slope": return along * 0.035
		"rolling": return 1.2 * sin(along / 20.0)
		"rough": return 1.8 * sin(along / 12.0) + 0.35 * sin(across / 10.0)
	return 0.0
