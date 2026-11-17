"""커리큘럼 v4: 결과 기반 보상 + 변형 혼합 + 변형별 승급 + 감쇠하는 보조 보상 + 단계 진입 시 탐색 재개.

기존 커리큘럼(curriculum.py)과 같은 인터페이스(stage, pick_stage, report, set_stage, state, save, load)를 갖고,
에피소드 설정은 build_episode() 가 직접 만든다. 계획 문서: training/CURRICULUM_V4.md

1부 기동    m1_move_basic → m2_move_obstacles → m3_move_under_fire → m4_ambush → m5_crossing
2부 사격    g1_gunnery → g2_gunnery_moving → g4_return_fire → g6_close_front
(3부 전술·4부 최종단계는 다음 단계에서 추가한다)
"""
from __future__ import annotations

import collections
import json
import random

from . import curriculum as _v1, scenarios

VERSION = 4
OBS = "situation"            # Godot --obs=situation (SituationObs) 이 필요하다

BASE_REWARD = {"time_per_s": -0.01, "progress": 0.03, "objective": 8.0, "survive": 6.0, "win": 8.0,
               "loss": -8.0, "timeout_penalty": -3.0,
               "combat": {"hit": 0.5, "penetration": 2.0, "knockout": 8.0, "miss": -0.05,
                          "victim_scale": 1.0, "live_target_only": True}}


def _map(size: float) -> dict:
    return {"features": False, "profile": "flat", "amplitude": 0.0, "size_m": size, "cell_m": 8.0,
            "ridge_count": 0, "seeds": [1]}


def stage(sid, part, label, builder, variants, kind, time_limit, size, threshold, enemy_ctrl="scripted",
          min_eps=300, max_eps=8000, view_lock=-1, decay=1500):
    return {"id": sid, "part": part, "label": label, "builder": builder, "variants": variants, "kind": kind,
            "time_limit_s": time_limit, "map": _map(size), "view_lock": view_lock, "enemy_ctrl": enemy_ctrl,
            "lineup": "scenario", "reward": BASE_REWARD,
            "promote": {"window": 40, "threshold": threshold, "min_episodes": min_eps, "max_episodes": max_eps},
            "shaping_decay_episodes": decay}


STAGES = [
    stage("m1_move_basic", "기동", "기본 주행·정지", "move_basic", ["near", "far", "behind"], "drive", 60, 600, .8,
          min_eps=200, decay=800),
    stage("m2_move_obstacles", "기동", "장애물 지대 통과", "move_obstacles", ["clear", "wall", "gates"], "drive", 90, 600, .7),
    stage("m3_move_under_fire", "기동", "포화 속 이동", "move_under_fire", ["screened", "open_cover", "long_detour"],
          "combat", 120, 2400, .6),
    stage("m4_ambush", "기동", "기습 대응·생존", "ambush", ["near_cover", "far_cover", "reverse"], "combat", 40, 2000, .6),
    stage("m5_crossing", "기동", "개활지 횡단", "crossing", ["steady", "sloppy", "woods"], "combat", 90, 2400, .6),
    stage("g1_gunnery", "사격", "정지 표적·은폐 표적", "gunnery", ["static", "hidden"], "gunnery", 45, 1800, .7,
          enemy_ctrl="static", view_lock=1),
    stage("g2_gunnery_moving", "사격", "이동 표적", "gunnery", ["moving"], "gunnery", 60, 1800, .6, enemy_ctrl="mover",
          view_lock=1),
    stage("g4_return_fire", "사격", "반격하는 적과 대결(헐다운/개활지)", "return_fire", ["berm", "open"], "combat", 90, 1800, .55),
    stage("g6_close_front", "사격", "근거리 정면(앵글링)", "close_front", ["close", "medium"], "combat", 60, 1200, .55),
]
STAGE_IDS = [s["id"] for s in STAGES]


class CurriculumV4:
    version = VERSION
    obs = OBS
    stages = STAGES
    stage_ids = STAGE_IDS
    dashboard_offset = len(_v1.STAGE_IDS)   # 대시보드는 v1 10단계 뒤에 v4 단계를 이어 표시한다

    def __init__(self, tank: str, start_stage: int = 0, review_prob: float = 0.1, seed: int = 0,
                 entropy_boost: float = 0.02, entropy_steps: int = 300_000):
        self.tank = tank
        self.stage_idx = start_stage
        self.review_prob = review_prob
        self.rng = random.Random(seed)
        self.episodes_in_stage = 0
        self.stage_start_step = 0
        self.entropy_boost = entropy_boost
        self.entropy_steps = entropy_steps
        self.history: list[dict] = []
        self.results = {s["id"]: {v: collections.deque(maxlen=200) for v in s["variants"]} for s in STAGES}
        self.terrain_fixed = ""      # 기존 인터페이스 호환(사용 안 함)

    @property
    def stage(self) -> dict:
        return STAGES[self.stage_idx]

    def pick_stage(self) -> dict:
        if self.stage_idx > 0 and self.rng.random() < self.review_prob:
            return STAGES[self.rng.randrange(self.stage_idx)]
        return self.stage

    def shaping_scale(self, stage_id: str) -> float:
        """보조 보상 배율(복습 단계는 0 = 결과 보상만).
        현재 단계는 실력에 따라 줄인다: 1 - (가장 약한 변형의 성공률 / 승급 기준). 실력이 붙기 전에 보조 보상이
        먼저 사라지지 않게 하고, 그래도 shaping_decay_episodes × 4 판이 지나면 상한을 0 까지 내려 끝낸다."""
        if stage_id != self.stage["id"]:
            return 0.0
        p = self.stage["promote"]
        skill = 1.0 - min(1.0, self.success_rate(stage_id, p["window"]) / p["threshold"])
        cap = max(0.0, 1.0 - self.episodes_in_stage / max(1, 4 * self.stage["shaping_decay_episodes"]))
        return round(min(skill, cap), 4)

    def entropy_coef(self, base: float, step: int) -> float:
        """단계 진입 직후 탐색 계수를 올렸다가 entropy_steps 동안 선형으로 기본값까지 줄인다."""
        frac = max(0.0, 1.0 - (step - self.stage_start_step) / max(1, self.entropy_steps))
        return base + (max(base, self.entropy_boost) - base) * frac

    def build_episode(self, learner: str, rng: random.Random, seed: int) -> tuple[dict, list[dict], dict]:
        st = self.pick_stage()
        variant = rng.choice(st["variants"])
        sc = scenarios.build(st["builder"], variant, learner, seed)
        team = scenarios.TEAM_OF[learner]
        lu = [{"type": learner, "team": team, "ctrl": "external", "role": "learner"}]
        for _ in sc["enemies"]:
            t = rng.choice(scenarios.ENEMIES_OF[learner])
            lu.append({"type": t, "team": 1 - team, "ctrl": st["enemy_ctrl"], "role": st["enemy_ctrl"]})
        reward = json.loads(json.dumps(st["reward"]))
        reward["shaping_scale"] = self.shaping_scale(st["id"])
        extra = {"scenario": sc, "reward": reward, "kind": st["kind"], "time_limit_s": sc.get("survive_s", st["time_limit_s"]),
                 "learning_objective": {"id": f"{st['id']}:{variant}", "label": f"{st['label']} · {variant}",
                                        "version": VERSION, "part": st["part"]},
                 "curriculum_version": VERSION}
        return st, lu, extra

    def success_rate(self, stage_id: str, window: int) -> float:
        rates = self.variant_rates(stage_id, window)
        return min(rates.values()) if rates else 0.0

    def variant_rates(self, stage_id: str, window: int) -> dict:
        out = {}
        for v, d in self.results.get(stage_id, {}).items():
            r = list(d)[-window:]
            out[v] = sum(r) / len(r) if r else 0.0
        return out

    def report(self, stage_id: str, success: bool, global_step: int, course: str = "", variant: str = "") -> dict | None:
        if stage_id not in self.results:
            return None
        if variant in self.results[stage_id]:
            self.results[stage_id][variant].append(int(success))
        if stage_id != self.stage["id"]:
            return None
        self.episodes_in_stage += 1
        p = self.stage["promote"]
        if self.stage_idx >= len(STAGES) - 1:
            return None
        window = p["window"]
        enough = self.episodes_in_stage >= p["min_episodes"] and all(len(d) >= window for d in self.results[stage_id].values())
        rates = self.variant_rates(stage_id, window)
        rate = min(rates.values())
        forced = p.get("max_episodes") is not None and self.episodes_in_stage >= p["max_episodes"]
        if (enough and rate >= p["threshold"]) or forced:
            return self._advance(self.stage_idx + 1, global_step, "threshold" if enough and rate >= p["threshold"] else "max_episodes", rates)
        return None

    def _advance(self, idx: int, global_step: int, reason: str, rates: dict) -> dict:
        ev = {"tank": self.tank, "from": self.stage["id"], "to": STAGES[idx]["id"], "episodes": self.episodes_in_stage,
              "success_rate": round(min(rates.values()) if rates else 0.0, 4),
              "variant_rates": {k: round(v, 4) for k, v in rates.items()}, "reason": reason,
              "global_step": global_step, "curriculum_version": VERSION}
        self.stage_idx = idx
        self.episodes_in_stage = 0
        self.stage_start_step = global_step
        self.history.append(ev)
        return ev

    def set_stage(self, stage_id: str, global_step: int) -> dict | None:
        idx = STAGE_IDS.index(stage_id)
        if idx == self.stage_idx:
            return None
        return self._advance(idx, global_step, "manual", self.variant_rates(self.stage["id"], 40))

    def state(self) -> dict:
        return {"curriculum_version": VERSION, "tank": self.tank, "stage_idx": self.stage_idx, "stage": self.stage["id"],
                "episodes_in_stage": self.episodes_in_stage, "stage_start_step": self.stage_start_step,
                "history": self.history,
                "recent_success": {k: self.success_rate(k, 40) for k in STAGE_IDS if any(self.results[k].values())},
                "variant_success": {k: self.variant_rates(k, 40) for k in STAGE_IDS if any(self.results[k].values())},
                "results": {k: {v: list(d) for v, d in vs.items()} for k, vs in self.results.items()},
                "shaping_scale": self.shaping_scale(self.stage["id"]),
                "entropy": {"boost": self.entropy_boost, "steps": self.entropy_steps}}

    def save(self, path) -> None:
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.state(), f, ensure_ascii=False, indent=2)

    @classmethod
    def load(cls, path, tank: str, **kw) -> "CurriculumV4":
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
        if st.get("curriculum_version") != VERSION:
            raise ValueError(f"커리큘럼 v{VERSION} 상태가 아닙니다: {path}")
        c = cls(tank, start_stage=int(st.get("stage_idx", 0)), **kw)
        c.episodes_in_stage = int(st.get("episodes_in_stage", 0))
        c.stage_start_step = int(st.get("stage_start_step", 0))
        c.history = st.get("history", [])
        for sid, vs in st.get("results", {}).items():
            for v, values in vs.items():
                if sid in c.results and v in c.results[sid]:
                    c.results[sid][v].extend(values)
        return c


def make_config(stage: dict, extra: dict, learner: str, lu: list[dict], seed: int, uid: str,
                record: bool, meta: dict, reward_overrides: dict | None = None) -> dict:
    reward = extra["reward"]
    for k, v in (reward_overrides or {}).items():
        if isinstance(v, dict):
            reward.setdefault(k, {}).update(v)
        else:
            reward[k] = v
    m = {k: v for k, v in stage["map"].items() if k != "seeds"} | {"seed": seed}
    return {"uid": uid, "seed": seed, "stage": stage["id"], "kind": extra["kind"], "time_limit_s": extra["time_limit_s"],
            "view_lock": stage.get("view_lock", -1), "map": m,
            "tanks": [{"type": d["type"], "team": d["team"], "ctrl": d["ctrl"]} for d in lu],
            "spawn": {}, "learner_team": scenarios.TEAM_OF[learner], "record": record, "meta": meta,
            "scenario": extra["scenario"], "reward": reward, "learning_objective": extra["learning_objective"],
            "curriculum_version": VERSION}
