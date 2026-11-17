"""Small, seeded terrain lessons. Stage IDs and policy tensor shapes stay unchanged."""
from copy import deepcopy

VERSION = 3
COURSES = [
    dict(id="approach", label="짧은 직진·정지", distance=[12, 20], yaw_jitter=8, time_limit_s=35, threshold=.85),
    dict(id="turn_gentle", label="완만한 방향 전환", distance=[20, 30], yaw_jitter=25, time_limit_s=40, threshold=.85),
    dict(id="turn_wide", label="큰 방향 전환", distance=[25, 40], yaw_jitter=60, time_limit_s=50, threshold=.80),
    dict(id="parking", label="방향 정렬·정지", distance=[35, 50], yaw_jitter=90, time_limit_s=60, threshold=.80),
    dict(id="slope", label="완만한 경사", distance=[35, 50], yaw_jitter=30, profile="slope", time_limit_s=60, threshold=.80),
    dict(id="low_step", label="낮은 턱 한 개", distance=[35, 55], yaw_jitter=30, time_limit_s=65, threshold=.80),
    dict(id="one_tree", label="나무 한 그루 우회", distance=[40, 55], yaw_jitter=30, time_limit_s=70, threshold=.75),
    dict(id="detour", label="작은 바위 우회", distance=[45, 65], yaw_jitter=35, rock_width=[4, 7], rock_depth=[4, 6], time_limit_s=80, threshold=.75),
    dict(id="gate_wide", label="넓은 통로 한 개", distance=[55, 75], yaw_jitter=35, gap=[22, 26], time_limit_s=80, threshold=.75),
    dict(id="gates", label="엇갈린 통로 두 개", distance=[65, 85], yaw_jitter=40, gap=[16, 20], time_limit_s=95, threshold=.75),
    dict(id="grove", label="성긴 숲길", distance=[65, 85], yaw_jitter=40, time_limit_s=100, threshold=.75),
    dict(id="rough", label="완만한 굴곡·턱", distance=[70, 100], yaw_jitter=40, profile="rough", time_limit_s=110, threshold=.70),
    dict(id="mixed", label="경사·우회·통로 복합", distance=[90, 120], yaw_jitter=40, profile="rolling", time_limit_s=125, threshold=.70),
]
COURSE_IDS = [c["id"] for c in COURSES]
WINDOW = 40


def lesson(stage: dict, index: int) -> dict:
    stage = deepcopy(stage)
    stage.pop("waypoint", None)
    stage.pop("spawn", None)
    course = COURSES[index]
    stage.update(time_limit_s=course["time_limit_s"],
                 terrain_course=dict(version=VERSION, id=course["id"], distance=course["distance"],
                                     goal_radius=5.0, checkpoint_radius=5.0,
                                     stop_speed=1.0, hold_s=.6, no_progress_s=20.0))
    for key in ("yaw_jitter", "rock_width", "rock_depth", "gap"):
        if key in course:
            stage["terrain_course"][key] = deepcopy(course[key])
    stage["map"] = dict(features=False, amplitude=0, profile=course.get("profile", "flat"), size_m=240.0,
                        cell_m=4.0, ridge_count=0, seeds=stage["map"]["seeds"])
    stage["reward"] = dict(progress=4.0, checkpoint=1.0, arrive=8.0, time_per_s=-.02,
                           stalled_per_s=-.1, failure=-2.0, combat=dict(miss=0.0))
    return stage
