"""커리큘럼: 단계 정의(맵·스폰 거리·상대·보상·종료) + 성공률 기반 자동 승급.

단계 순서(전차 종류마다 따로 진행, 정책도 전차 종류별로 따로):
  1 drive            빈 맵 웨이포인트 주행
  2 drive_terrain    장애물·숲이 있는 맵에서 주행
  3 gunnery_static   정지 표적(포수 조준경 고정)
  4 gunnery_moving   움직이는 표적(포수 조준경 고정)
  5 gunnery_search   시점 자유: 둘러보고 찾아서 쏘기
  6 duel_scripted    1대1 vs 규칙 AI
  7 duel_selfplay    1대1 vs 상대 전차 종류의 학습된 정책(없으면 규칙 AI)
  8 team_scripted    티거 1 vs 연합군 3(학습 전차 외는 규칙 AI / 같은 종류 아군은 현재 정책 복사)
  9 team_selfplay    티거 1 vs 셔먼 3 + T-34 2, 자기대전
 10 final_battle     최종 목표: 티거 1 vs 셔먼 3 + T-34 3, 자기대전

스폰 거리는 단계별로 짧게 시작해 점점 늘린다(원래 게임은 900m).
"""
from __future__ import annotations

import collections
import json
import random

from .pace import GAME_PACE
from .terrain import COURSES, COURSE_IDS, VERSION as TERRAIN_VERSION, WINDOW as TERRAIN_WINDOW, lesson

TEAM_OF = {"tiger1": 0, "sherman75": 1, "t34_76": 1}
ENEMIES_OF = {"tiger1": ["sherman75", "t34_76"], "sherman75": ["tiger1"], "t34_76": ["tiger1"]}
ALLIED_TEAM = ["sherman75", "sherman75", "t34_76"]
FULL_ALLIED = ["sherman75", "sherman75", "sherman75", "t34_76", "t34_76"]
FINAL_ALLIED = ["sherman75"] * 3 + ["t34_76"] * 3

STAGES = [
    {
        "id": "drive", "kind": "drive", "time_limit_s": 60, "view_lock": 0,
        "map": {"features": False, "amplitude": 8.0, "seeds": list(range(1, 21))},
        "spawn": {"distance": [0, 0], "random_yaw": True, "random_yaw_learner": True, "center_jitter": 300},
        "waypoint": {"distance": [60, 200], "radius": 12},
        "reward": {"combat": {"miss": 0.0}},
        "lineup": "solo",
        "promote": {"window": 100, "threshold": 0.8, "min_episodes": 200, "max_episodes": 6000},
    },
    {
        "id": "drive_terrain", "kind": "drive", "time_limit_s": 90, "view_lock": 0,
        "map": {"features": True, "amplitude": 15.0, "seeds": list(range(1, 31))},
        "spawn": {"distance": [0, 0], "random_yaw": True, "random_yaw_learner": True, "center_jitter": 350},
        "waypoint": {"distance": [100, 300], "radius": 15},
        "reward": {"combat": {"miss": 0.0}},
        "lineup": "solo",
        "promote": {"window": 100, "threshold": 0.7, "min_episodes": 200, "max_episodes": 6000},
    },
    {
        "id": "gunnery_static", "kind": "gunnery", "time_limit_s": 45, "view_lock": 1, "success_hits": 2,
        "map": {"features": False, "amplitude": 6.0, "seeds": list(range(1, 21))},
        "spawn": {"distance": [150, 400], "axis_jitter_deg": 180, "yaw_jitter_deg": 50, "random_yaw": True,
                  "center_jitter": 200},
        "lineup": "target_static",
        "promote": {"window": 100, "threshold": 0.7, "min_episodes": 200, "max_episodes": 8000},
    },
    {
        "id": "gunnery_moving", "kind": "gunnery", "time_limit_s": 60, "view_lock": 1, "success_hits": 2,
        "map": {"features": False, "amplitude": 8.0, "seeds": list(range(1, 21))},
        "spawn": {"distance": [200, 600], "axis_jitter_deg": 180, "yaw_jitter_deg": 60, "random_yaw": True,
                  "center_jitter": 150},
        "lineup": "target_moving",
        "promote": {"window": 100, "threshold": 0.6, "min_episodes": 200, "max_episodes": 8000},
    },
    {
        "id": "gunnery_search", "kind": "gunnery", "time_limit_s": 90, "view_lock": -1, "success_hits": 2,
        "map": {"features": True, "amplitude": 12.0, "seeds": list(range(1, 31))},
        "spawn": {"distance": [200, 700], "axis_jitter_deg": 180, "yaw_jitter_deg": 120, "random_yaw": True,
                  "center_jitter": 150},
        "lineup": "target_mixed",
        "promote": {"window": 100, "threshold": 0.5, "min_episodes": 300, "max_episodes": 8000},
    },
    {
        "id": "duel_scripted", "kind": "combat", "time_limit_s": 180, "view_lock": -1,
        "map": {"features": True, "amplitude": 15.0, "seeds": list(range(1, 41))},
        "spawn": {"distance": [300, 700], "axis_jitter_deg": 20, "yaw_jitter_deg": 20, "center_jitter": 150},
        "lineup": "duel_scripted",
        "promote": {"window": 200, "threshold": 0.5, "min_episodes": 400, "max_episodes": 6000},
    },
    {
        "id": "duel_selfplay", "kind": "combat", "time_limit_s": 180, "view_lock": -1,
        "map": {"features": True, "amplitude": 15.0, "seeds": list(range(1, 41))},
        "spawn": {"distance": [300, 800], "axis_jitter_deg": 20, "yaw_jitter_deg": 20, "center_jitter": 150},
        "lineup": "duel_policy",
        "promote": {"window": 200, "threshold": 0.5, "min_episodes": 400, "max_episodes": 6000},
    },
    {
        "id": "team_scripted", "kind": "combat", "time_limit_s": 300, "view_lock": -1,
        "map": {"features": True, "amplitude": 15.0, "seeds": list(range(1, 41))},
        "spawn": {"distance": [500, 800], "axis_jitter_deg": 10, "yaw_jitter_deg": 15, "spacing": 30,
                  "center_jitter": 100},
        "lineup": "team_scripted",
        "promote": {"window": 200, "threshold": 0.5, "min_episodes": 400, "max_episodes": 6000},
    },
    {
        "id": "team_selfplay", "kind": "combat", "time_limit_s": 600, "view_lock": -1,
        "map": {"features": True, "amplitude": 15.0, "seeds": list(range(1, 61))},
        "spawn": {"distance": [600, 900], "axis_jitter_deg": 10, "yaw_jitter_deg": 15, "spacing": 25,
                  "center_jitter": 80},
        "lineup": "team_policy",
        "promote": {"window": 200, "threshold": 0.5, "min_episodes": 400, "max_episodes": None},
    },
    {
        "id": "final_battle", "kind": "combat", "time_limit_s": 180, "view_lock": -1,
        "map": {"features": False, "profile": "battle_compact", "amplitude": 0.0,
                "size_m": 360, "cell_m": 4, "ridge_count": 0, "seeds": list(range(61, 121))},
        "spawn": {"distance": [200, 200], "axis_jitter_deg": 5, "yaw_jitter_deg": 8,
                  "spacing": 18, "center_jitter": 10},
        "lineup": "final_policy",
        "learning_objective": {"id": "tiger1_vs_allies6", "label": "독립 개체 1 대 6 · 빠른 교전", "version": 3},
        "reward": {"battle_shaping": True, "fast_combat_version": 1,
                   "time_per_s": -0.02, "spot": 0.3, "win": 15.0, "loss": -10.0, "timeout_penalty": -4.0,
                   "near_miss_radius_m": 12.0, "near_miss_bonus": 1.0, "near_miss_budget": 3.0,
                   "closing_per_m": 0.03, "closing_budget": 4.0,
                   "close_distances": [150, 100, 60, 30], "close_bonuses": [0.5, 0.75, 1.0, 1.5],
                   "combat": {"hit": 5.0, "penetration": 3.0, "knockout": 12.0,
                              "miss": -0.05, "live_target_only": True}},
        "promote": None,
    },
]
STAGES[0] = lesson(STAGES[0], 0)  # Review must teach the same stop-at-target rule.
STAGES[0]["promote"] = dict(window=TERRAIN_WINDOW, threshold=.85, min_episodes=TERRAIN_WINDOW, max_episodes=None)
STAGE_IDS = [s["id"] for s in STAGES]


def lineup(stage: dict, learner: str, rng: random.Random, have_policy: set[str]) -> list[dict]:
    """단계 + 학습 전차 → [{type, team, ctrl(godot), role(python)}] (팀 0 먼저 — Godot 의 전차 순서와 같게).

    role: learner = 학습 대상(1대), copy = 현재 학습 중 정책으로 움직이는 같은 종류 아군,
          opponent = 다른 종류의 저장된 정책(풀), scripted/mover/static = Godot 안에서 움직임
    """
    me_team = TEAM_OF[learner]
    enemy = rng.choice(ENEMIES_OF[learner])
    kind = stage["lineup"]
    out: list[dict] = []

    def add(t, team, role):
        ctrl = "external" if role in ("learner", "copy", "opponent") else role
        out.append({"type": t, "team": team, "ctrl": ctrl, "role": role})

    def policy_or_scripted(t):
        if t == learner:
            return "copy"
        return "opponent" if t in have_policy else "scripted"

    if kind == "solo":
        add(learner, me_team, "learner")
    elif kind in ("target_static", "target_moving", "target_mixed"):
        add(learner, me_team, "learner")
        role = {"target_static": "static", "target_moving": "mover"}.get(kind) or rng.choice(["static", "mover"])
        add(enemy, 1 - me_team, role)
    elif kind == "duel_scripted":
        add(learner, me_team, "learner")
        add(enemy, 1 - me_team, "scripted")
    elif kind == "duel_policy":
        add(learner, me_team, "learner")
        add(enemy, 1 - me_team, policy_or_scripted(enemy))
    elif kind in ("team_scripted", "team_policy", "final_policy"):
        allies = ALLIED_TEAM if kind == "team_scripted" else (FINAL_ALLIED if kind == "final_policy" else FULL_ALLIED)
        teams = {0: ["tiger1"], 1: list(allies)}
        placed = False
        for team in (0, 1):
            for t in teams[team]:
                if not placed and t == learner:
                    add(t, team, "learner")
                    placed = True
                elif kind == "team_scripted":
                    add(t, team, "copy" if t == learner else "scripted")
                else:
                    add(t, team, policy_or_scripted(t))
    else:
        raise ValueError(kind)
    out.sort(key=lambda d: d["team"])  # 안정 정렬: 팀 안 순서 유지
    return out


def tank_names(lu: list[dict]) -> list[str]:
    """Godot 이 붙이는 이름("tiger1_0" …) — 팀 0 먼저, 팀 안 순서대로 번호."""
    return [f"{d['type']}_{i}" for i, d in enumerate(lu)]


class Curriculum:
    """전차 종류 하나의 커리큘럼 진행 상태. 에피소드 결과를 받아 승급을 결정한다."""

    def __init__(self, tank: str, start_stage: int = 0, review_prob: float = 0.1, seed: int = 0):
        self.tank = tank
        self.stage_idx = start_stage
        self.review_prob = review_prob
        self.rng = random.Random(seed)
        self.results: dict[str, collections.deque] = {s["id"]: collections.deque(maxlen=1000) for s in STAGES}
        self.episodes_in_stage = 0
        self.history: list[dict] = []   # 승급 기록
        self.terrain_idx = 0
        self.terrain_results = {name: collections.deque(maxlen=TERRAIN_WINDOW) for name in COURSE_IDS}
        self.terrain_history = []
        self.terrain_fixed = ""
        self.previous_assessments = []

    @property
    def stage(self) -> dict:
        return STAGES[self.stage_idx]

    def pick_stage(self) -> dict:
        """이번 에피소드 단계: 대개 현재 단계, 가끔(review_prob) 이전 단계 복습(잊지 않게)."""
        if self.terrain_fixed and self.stage["id"] == "drive_terrain":
            return lesson(self.stage, COURSE_IDS.index(self.terrain_fixed))
        if self.stage_idx > 0 and self.rng.random() < self.review_prob:
            stage = STAGES[self.rng.randrange(self.stage_idx)]
        else:
            stage = self.stage
        if stage["id"] == "drive_terrain":
            index = self.terrain_idx
            if index > 0 and self.rng.random() < .2:
                index = self.rng.randrange(index)
            return lesson(stage, index)
        return stage

    def success_rate(self, stage_id: str, window: int) -> float:
        r = list(self.results[stage_id])[-window:]
        return sum(r) / len(r) if r else 0.0

    def report(self, stage_id: str, success: bool, global_step: int, course: str = "") -> dict | None:
        """에피소드 결과 기록. 승급하면 승급 정보 dict 를 돌려준다."""
        self.results[stage_id].append(1 if success else 0)
        if stage_id != self.stage["id"]:
            return None
        self.episodes_in_stage += 1
        if stage_id == "drive_terrain":
            if course not in self.terrain_results:
                return None  # Legacy executables cannot silently pass the new lessons.
            self.terrain_results[course].append(int(success))
            if self.terrain_fixed:
                return None
            current = COURSES[self.terrain_idx]
            results = self.terrain_results[current["id"]]
            if course != current["id"] or len(results) < TERRAIN_WINDOW or sum(results) / len(results) < current["threshold"]:
                return None
            self.terrain_history.append(dict(course=course, global_step=global_step,
                                             success_rate=sum(results) / len(results)))
            if self.terrain_idx < len(COURSES) - 1:
                self.terrain_idx += 1
                return None
            ev = dict(tank=self.tank, **{"from": stage_id, "to": STAGES[self.stage_idx + 1]["id"]},
                      episodes=self.episodes_in_stage, success_rate=sum(results) / len(results),
                      reason="terrain_courses_mastered", global_step=global_step)
            self.stage_idx += 1
            self.episodes_in_stage = 0
            self.history.append(ev)
            return ev
        p = self.stage.get("promote")
        if not p or self.stage_idx >= len(STAGES) - 1:
            return None
        rate = self.success_rate(stage_id, p["window"])
        enough = self.episodes_in_stage >= p["min_episodes"] and len(self.results[stage_id]) >= p["window"]
        forced = p.get("max_episodes") is not None and self.episodes_in_stage >= p["max_episodes"]
        if (enough and rate >= p["threshold"]) or forced:
            ev = {"tank": self.tank, "from": stage_id, "to": STAGES[self.stage_idx + 1]["id"],
                  "episodes": self.episodes_in_stage, "success_rate": round(rate, 4),
                  "reason": "threshold" if not forced or rate >= p["threshold"] else "max_episodes",
                  "global_step": global_step}
            self.stage_idx += 1
            self.episodes_in_stage = 0
            self.history.append(ev)
            return ev
        return None

    def set_stage(self, stage_id: str, global_step: int) -> dict | None:
        """대시보드에서 단계를 직접 바꿀 때(앞·뒤 모두). 승급 기록에 reason = manual 로 남긴다."""
        idx = STAGE_IDS.index(stage_id)
        if idx == self.stage_idx:
            return None
        ev = {"tank": self.tank, "from": self.stage["id"], "to": stage_id, "episodes": self.episodes_in_stage,
              "success_rate": round(self.success_rate(self.stage["id"], 100), 4), "reason": "manual",
              "global_step": global_step}
        self.stage_idx = idx
        self.episodes_in_stage = 0
        self.history.append(ev)
        return ev

    def state(self) -> dict:
        return {"tank": self.tank, "stage_idx": self.stage_idx, "stage": self.stage["id"],
                "episodes_in_stage": self.episodes_in_stage, "history": self.history,
                "recent_success": {k: self.success_rate(k, 100) for k in STAGE_IDS if self.results[k]},
                "results": {k: list(v) for k, v in self.results.items()},
                "previous_assessments": self.previous_assessments,
                "terrain": {"version": TERRAIN_VERSION, "index": self.terrain_idx,
                            "fixed": self.terrain_fixed,
                            "course": COURSES[self.terrain_idx]["id"], "history": self.terrain_history,
                            "results": {k: list(v) for k, v in self.terrain_results.items()}}}

    def save(self, path) -> None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.state(), f, ensure_ascii=False, indent=2)

    @classmethod
    def load(cls, path, tank: str, **kw) -> "Curriculum":
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
        c = cls(tank, start_stage=int(st.get("stage_idx", 0)), **kw)
        c.episodes_in_stage = int(st.get("episodes_in_stage", 0))
        c.history = st.get("history", [])
        for name, values in st.get("results", {}).items():
            if name in c.results:
                c.results[name].extend(values)
        terrain = st.get("terrain", {})
        c.previous_assessments = st.get("previous_assessments", [])
        if terrain.get("version") == TERRAIN_VERSION:
            c.terrain_idx = max(0, min(len(COURSES) - 1, int(terrain.get("index", 0))))
            c.terrain_fixed = terrain.get("fixed", "") if terrain.get("fixed", "") in COURSE_IDS else ""
            c.terrain_history = terrain.get("history", [])
            for name, values in terrain.get("results", {}).items():
                if name in c.terrain_results:
                    c.terrain_results[name].extend(values)
        else:
            c.previous_assessments.append({k: st[k] for k in ("terrain", "results", "episodes_in_stage", "stage") if k in st})
            if c.stage["kind"] == "drive":
                c.episodes_in_stage = 0
                c.results[c.stage["id"]].clear()
        return c


def make_config(stage: dict, learner: str, lu: list[dict], seed: int, map_seed: int, uid: str,
                record: bool, meta: dict, reward_overrides: dict | None = None) -> dict:
    """Godot reset 설정(training_env.gd reset_episode 의 키)."""
    m = stage["map"]
    cfg = {
        "uid": uid, "seed": seed, "stage": stage["id"], "kind": stage["kind"],
        "time_limit_s": stage["time_limit_s"], "view_lock": stage.get("view_lock", -1),
        "map": {k: v for k, v in m.items() if k != "seeds"} | {"seed": map_seed},
        "tanks": [{"type": d["type"], "team": d["team"], "ctrl": d["ctrl"]} for d in lu],
        "spawn": stage.get("spawn", {}), "learner_team": TEAM_OF[learner],
        "record": record, "meta": meta,
        "pace": dict(stage.get("pace", GAME_PACE)),
    }
    if "waypoint" in stage:
        cfg["waypoint"] = stage["waypoint"]
    if "terrain_course" in stage:
        cfg["terrain_course"] = stage["terrain_course"]
        cfg["map"]["seed"] = seed  # Every episode varies; replay retains the exact seed.
    if "learning_objective" in stage:
        cfg["learning_objective"] = json.loads(json.dumps(stage["learning_objective"]))
    if "success_hits" in stage:
        cfg["success_hits"] = stage["success_hits"]
    reward = json.loads(json.dumps(stage.get("reward", {})))
    for k, v in (reward_overrides or {}).items():
        if isinstance(v, dict):
            reward.setdefault(k, {}).update(v)
        else:
            reward[k] = v
    if reward:
        cfg["reward"] = reward
    return cfg
