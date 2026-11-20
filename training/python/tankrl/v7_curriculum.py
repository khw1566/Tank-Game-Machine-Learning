"""Progression for the native V7 Godot course and team races."""
from __future__ import annotations

from collections import deque
from .final_curriculum import MAPS


VERSION = 8
STAGESET = "v7-godot-turret-controls"
TANKS = ["tiger1", "sherman75", "t34_76"]
WINDOW = 64


def _stage(stage_id, label, kind, opponents, rings, goal, description, variation, threshold):
    return {
        "id": stage_id, "label": label, "kind": kind, "opponents": opponents, "rings": rings,
        "goal": goal, "description": description, "part": "V7 Godot", "scope": "tank",
        "variants": list(MAPS), "variants_desc": {key: f"{description} · {variation}" for key, description in MAPS.items()},
        "promote": None if threshold is None else {
            "window": WINDOW, "min_episodes": WINDOW, "threshold": threshold},
    }


STAGES = [
    _stage("v7_target", "V7-1 · 링 태그", "target", 0, 3,
           "제한 시간 안에 링 3개 태그", "커서를 링에 맞춘 뒤 태그 버튼을 누릅니다.",
           "시드에 따라 링의 위치가 달라집니다.", 0.75),
    _stage("v7_side", "V7-2 · 사이드 체크포인트", "side", 0, 3,
           "체크포인트를 통과하고 링 3개 태그",
           "차량을 체크포인트로 이동해 링을 엽니다. 상대의 옆면 표시를 발견하면 보너스를 한 번 받습니다.",
           "시드에 따라 체크포인트와 링의 위치가 달라집니다.", 0.70),
]
for _opponents, _rings, _threshold in ((1, 3, 0.60), (2, 4, 0.60), (3, 5, 0.55), (6, 6, None)):
    _goal = f"상대보다 먼저 링 {_rings}개 태그"
    _lineup = "각자 한 명씩 링 경주를 합니다."
    if _opponents > 1:
        _goal = f"티거는 링 {_rings}개, 연합팀은 동료의 릴레이 점수를 합쳐 {_rings + _opponents - 1}점 먼저 달성"
        _lineup = f"티거는 라이벌 {_opponents}명과 경주합니다. 연합 플레이어는 동료 {_opponents - 1}명과 함께 상대 한 명과 겨룹니다."
    STAGES.append(_stage(
        f"v7_1v{_opponents}", f"V7-{len(STAGES) + 1} · 1대{_opponents} 링 경주",
        "competition", _opponents, _rings, _goal,
        _lineup + " 옆면 표시 발견 보너스는 라이벌마다 한 번입니다.",
        "시드에 따라 링과 체크포인트 위치, 라이벌의 득점 시점이 달라집니다.", _threshold))

STAGE_IDS = [stage["id"] for stage in STAGES]


class V7Curriculum:
    """Promote on completed episodes in the current stage, independently for each avatar."""

    version = VERSION
    stages = STAGES
    stage_ids = STAGE_IDS

    def __init__(self, tank):
        if tank not in TANKS:
            raise ValueError(f"Unknown arcade avatar: {tank!r}")
        self.tank = tank
        self.stage_idx = 0
        self.history = []
        self.stage_stats = {
            sid: {"episodes": 0, "successes": 0, "recent": deque(maxlen=WINDOW)} for sid in STAGE_IDS
        }

    @property
    def stage(self):
        return STAGES[self.stage_idx]

    @property
    def episodes_in_stage(self):
        return self.stage_stats[self.stage["id"]]["episodes"]

    @property
    def total_episodes(self):
        return sum(row["episodes"] for row in self.stage_stats.values())

    def success_rate(self, stage_id, window=WINDOW):
        if window <= 0:
            raise ValueError("window must be positive")
        recent = list(self.stage_stats[stage_id]["recent"])[-window:]
        return sum(recent) / len(recent) if recent else 0.0

    def record(self, stage_id, success):
        """Count late results against their original stage without advancing the current one."""
        if stage_id not in self.stage_stats or STAGE_IDS.index(stage_id) > self.stage_idx:
            raise ValueError(f"No episode of {stage_id!r} has been started in this curriculum")
        stats = self.stage_stats[stage_id]
        stats["episodes"] += 1
        stats["successes"] += int(bool(success))
        stats["recent"].append(bool(success))
        rule = self.stage["promote"]
        if stage_id != self.stage["id"] or rule is None or len(stats["recent"]) < rule["min_episodes"]:
            return False
        rate = self.success_rate(stage_id, rule["window"])
        if rate < rule["threshold"]:
            return False
        self.stage_idx += 1
        self.history.append({"from": stage_id, "to": self.stage["id"], "episodes": stats["episodes"],
                             "total_episodes": self.total_episodes, "window": rule["window"],
                             "success_rate": rate})
        return True

    def state(self):
        return {
            "stageset": STAGESET, "curriculum_version": VERSION, "tank": self.tank,
            "stage": self.stage["id"], "stage_idx": self.stage_idx,
            "episodes_in_stage": self.episodes_in_stage, "total_episodes": self.total_episodes,
            "history": [entry.copy() for entry in self.history],
            "stage_stats": {sid: {**row, "recent": list(row["recent"])} for sid, row in self.stage_stats.items()},
        }

    @classmethod
    def from_state(cls, data):
        if data.get("stageset") != STAGESET or data.get("curriculum_version") != VERSION:
            raise ValueError("This state does not belong to the V7 arcade curriculum")
        instance = cls(data["tank"])
        instance.stage_idx = STAGE_IDS.index(data["stage"])
        if instance.stage_idx != data["stage_idx"] or set(data["stage_stats"]) != set(STAGE_IDS):
            raise ValueError("Inconsistent stage catalog in arcade checkpoint")
        for sid, stats in data["stage_stats"].items():
            episodes, successes, recent = stats["episodes"], stats["successes"], stats["recent"]
            if (type(episodes) is not int or type(successes) is not int or not 0 <= successes <= episodes
                    or not isinstance(recent, list) or len(recent) != min(episodes, WINDOW)
                    or any(type(result) is not bool for result in recent)
                    or successes < sum(recent) or episodes - successes < recent.count(False)
                    or (STAGE_IDS.index(sid) > instance.stage_idx and episodes)):
                raise ValueError(f"Invalid episode history for {sid}")
            instance.stage_stats[sid].update(episodes=episodes, successes=successes)
            instance.stage_stats[sid]["recent"].extend(recent)
        instance.history = [entry.copy() for entry in data["history"]]
        if instance.episodes_in_stage != data["episodes_in_stage"] or instance.total_episodes != data["total_episodes"]:
            raise ValueError("Inconsistent episode counts in arcade checkpoint")
        return instance
