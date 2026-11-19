"""전투부터 시작하는 자기 대전: 평지 → 지형 → 전차별 최종 전투."""
from __future__ import annotations

from collections import deque
import copy
import json
import math
import random

from . import curriculum, curriculum_v4, scenarios

VERSION = 5
BALANCE_VERSION = 2
REWARD_VERSION = 2
SHARED = curriculum_v4.SHARED
TANKS = curriculum_v4.SHARED_TANKS
STAGES = [
    {"id": "battle_flat", "label": "평지 자기 대전", "part": "공통 전투", "scope": "common",
     "variants": ["close", "wide"], "min_steps": 2_000_000, "time_limit_s": 90},
    {"id": "battle_terrain", "label": "장애물·굴곡 자기 대전", "part": "공통 전투", "scope": "common",
     "variants": ["walls", "hills", "mixed"], "min_steps": 3_000_000, "time_limit_s": 120},
    {"id": "battle_roles", "label": "전차별 최종 전투", "part": "전차별 전술", "scope": "tank",
     "variants": ["duel", "team"], "min_steps": 0, "time_limit_s": 180},
]
for _s in STAGES:
    _s.update(kind="combat", view_lock=-1, lineup="battle_selfplay",
              lesson=_s["label"], learn="실제 전투에서 사격·회피·피해 교환·전술을 함께 학습",
              goal="적 팀 전멸. 시간 초과는 무승부이며 승리 보상이 없다.",
              promote={"window": 40, "threshold": None, "min_episodes": 0, "max_episodes": None})
STAGE_IDS = [s["id"] for s in STAGES]


def arena(stage_id: str, variant: str, tank: str, seed: int):
    """항상 학습 전차가 첫 번째. 지역 좌표를 회전해 양쪽 시작 방향을 무작위화한다."""
    rng = random.Random(seed)
    frame = scenarios.Frame(rng.uniform(-math.pi, math.pi))
    team = rng.randrange(2) if stage_id != "battle_roles" else scenarios.TEAM_OF[tank]
    distance = rng.uniform(60, 110) if variant == "close" else rng.uniform(130, 230)
    lu = [{"type": tank, "team": team, "ctrl": "external", "role": "learner"}]
    positions = [(0, -distance / 2)]
    if stage_id == "battle_roles" and variant == "team":
        other = (["tiger1"] if team == 1 else []) + ["sherman75"] * 3 + ["t34_76"] * 3
        if team == 1:
            other.remove(tank)
        for typ in other:
            lu.append({"type": typ, "team": scenarios.TEAM_OF[typ], "ctrl": "external", "role": "opponent"})
        counts = {0: 0, 1: 0}
        for item in lu:
            side = item["team"]
            n = counts[side]
            counts[side] += 1
            positions.append(((n % 3 - 1) * 22, (-1 if side == team else 1) * distance / 2 + (n // 3) * 20))
        positions = positions[1:]
    else:
        enemy = tank if stage_id != "battle_roles" else rng.choice(scenarios.ENEMIES_OF[tank])
        lu.append({"type": enemy, "team": 1 - team, "ctrl": "external", "role": "opponent"})
        positions.append((0, distance / 2))
    places = []
    for item, uv in zip(lu, positions):
        p = frame.p(*uv)
        target = frame.p(0, distance / 2 if item["team"] == team else -distance / 2)
        places.append({"p": p, "yaw": round(scenarios.yaw_to(p, target) + rng.uniform(-0.22, 0.22), 4)})
    obstacles = []
    terrain = stage_id != "battle_flat"
    if terrain and variant != "hills":
        # 중앙에 선택 가능한 두 엄폐물. 양쪽 스폰에서 같은 거리이며 우회로는 열려 있다.
        for side in (-1, 1):
            obstacles.append(scenarios._stone(frame, side * rng.uniform(22, 35), 0,
                                               rng.uniform(14, 22), 3.5, rng.uniform(8, 14)))
        for side in (-1, 1):
            obstacles.append(scenarios._berm(frame, side * 35, side * 30, 18, 6, 0.85))
    hills = terrain and variant != "walls"
    mc = {"features": False, "amplitude": rng.uniform(5, 11) if hills else 0.0,
          "size_m": 600, "cell_m": 6, "ridge_count": 2 if hills else 0, "seeds": [1]}
    if not hills:
        mc["profile"] = "flat"
    sc = {"version": 1, "id": stage_id, "variant": variant, "goal": "battle",
          "observation_version": 3, "projectile_version": 1, "learner": places[0],
          "enemies": places[1:], "obstacles": obstacles}
    return lu, sc, mc


class BattleCurriculum:
    version = VERSION
    assessment_version = 2
    balance_version = BALANCE_VERSION
    reward_version = REWARD_VERSION
    obs = "battle"
    stages = STAGES
    stage_ids = STAGE_IDS
    dashboard_offset = len(curriculum.STAGES) + len(curriculum_v4.STAGES)

    def __init__(self, tank, start_stage=0, review_prob=0.1, seed=0,
                 entropy_boost=0.003, entropy_steps=300_000):
        if tank not in TANKS + [SHARED]:
            raise ValueError(f"Unknown tank: {tank}")
        if tank == SHARED and start_stage > 1:
            raise ValueError("공통 모델은 지형 전투 후 전차별로 분화해야 합니다")
        self.tank = tank
        self.tanks = list(TANKS) if tank == SHARED else [tank]
        self.stage_idx = start_stage
        self.review_prob = review_prob
        self.rng = random.Random(seed)
        self.entropy_boost, self.entropy_steps = entropy_boost, entropy_steps
        self.episodes_in_stage = self.stage_start_step = 0
        self.common_complete = False
        self.branched_from = ""
        self.terrain_fixed = ""
        self.history = []
        self.results = {s["id"]: {self.key(v, t): deque(maxlen=80) for v in s["variants"] for t in self.tanks}
                        for s in STAGES}
        self.metrics = copy.deepcopy(self.results)

    @staticmethod
    def key(variant, tank):
        return f"{variant}@{tank}"

    @property
    def stage(self):
        return STAGES[self.stage_idx]

    @property
    def training_complete(self):
        # 최종 전투는 계속 개선하며, 공통 단계만 분화 시점에 멈춘다.
        return self.tank == SHARED and self.common_complete

    def shaping_scale(self, stage_id):
        return 0.0  # 엄폐 위치나 주행 거리 자체에는 점수를 주지 않는다.

    def entropy_coef(self, base, step):
        frac = max(0, 1 - (step - self.stage_start_step) / max(1, self.entropy_steps))
        return base + (max(base, self.entropy_boost) - base) * frac

    def variant_rates(self, sid, window):
        return {k: sum(list(v)[-window:]) / min(len(v), window) if v else 0.0
                for k, v in self.results[sid].items()}

    def success_rate(self, sid, window):
        values = [v for k, v in self.variant_rates(sid, window).items() if self.results[sid][k]]
        return sum(values) / len(values) if values else 0.0

    def combat_metrics(self):
        out = {}
        for key, values in self.metrics[self.stage["id"]].items():
            recent = list(values)[-40:]
            out[key] = {"episodes": len(recent), **{
                k: sum(row[k] for row in recent) / len(recent) if recent else 0.0
                for k in ("hit", "pen", "resolved")}}
        return out

    def build_episode(self, learner, rng, seed):
        st = self.stage
        if self.stage_idx and rng.random() < self.review_prob:
            st = rng.choice(STAGES[:self.stage_idx])
        # 덜 경험한 전차·배치를 우선해 일부 조합만 잘하는 현상을 줄인다.
        counts = self.metrics[st["id"]]
        minimum = min(len(v) for v in counts.values())
        key = rng.choice([k for k, v in counts.items() if len(v) == minimum])
        variant, actual = key.split("@")
        lu, sc, mc = arena(st["id"], variant, actual, seed)
        st = dict(st, map=mc)
        reward = {"battle_shaping": True, "progressive_combat_v2": True, "reward_version": REWARD_VERSION,
                  "time_per_s": -0.02, "win": 200.0, "loss": -80.0,
                  "timeout_penalty": -35.0, "spot": 0.0, "shaping_scale": 0.0,
                  "near_miss_radius_m": 4.0, "near_miss_bonus": 2.0, "near_miss_budget": 3.0,
                  "near_pen_bonus": 2.0, "near_pen_budget": 4.0,
                  "close_after_failures": 2, "close_after_stall_s": 20.0,
                  "closing_per_m": 0.05, "closing_budget": 7.0,
                  "close_distances": [150, 100, 60, 30], "close_bonuses": [0.5, 1.0, 1.5, 2.0],
                  "combat": {"hit": 0.2, "penetration": 8.0, "knockout": 25.0,
                             "module_damaged": 1.5, "module_destroyed": 5.0,
                             "crew_wounded": 2.0, "crew_kia": 5.0,
                             "miss": -0.05, "victim_scale": 1.0, "live_target_only": True}}
        return st, lu, {"scenario": sc, "learner": actual, "model": self.tank, "selfplay": True,
                        "reward": reward, "kind": "combat", "time_limit_s": st["time_limit_s"],
                        "curriculum_version": VERSION, "stageset": "battle-2", "balance_version": BALANCE_VERSION,
                        "learning_objective": {"id": st["id"], "label": st["label"], "version": 1}}

    def report_battle(self, sid, success, global_step, variant, learner, stats, episode):
        key = self.key(variant, learner)
        if key not in self.results.get(sid, {}):
            return None
        self.results[sid][key].append(int(success))
        self.metrics[sid][key].append({"hit": int(stats.get("hits", 0) > 0),
                                      "pen": int(stats.get("pens", 0) > 0),
                                      "resolved": int(episode.get("winner", -1) in (0, 1))})
        if sid != self.stage["id"] or self.stage_idx == 2 or self.common_complete:
            return None
        self.episodes_in_stage += 1
        if global_step - self.stage_start_step < self.stage["min_steps"]:
            return None
        for values in self.metrics[sid].values():
            recent = list(values)[-40:]
            if len(recent) < 40:
                return None
            # 동등 정책의 승률은 약 50%: 승률 대신 실제 교전 성립 여부를 확인한다.
            if any(sum(r[k] for r in recent) / 40 < limit
                   for k, limit in (("hit", 0.35), ("pen", 0.15), ("resolved", 0.25))):
                return None
        if self.stage_idx == 1 and self.tank == SHARED:
            self.common_complete = True
            return self._event("branch_tanks", global_step, "combat_ready")
        event = self._event(STAGE_IDS[self.stage_idx + 1], global_step, "combat_ready")
        self.stage_idx += 1
        self.stage_start_step, self.episodes_in_stage = global_step, 0
        return event

    def _event(self, target, step, reason):
        ev = {"tank": self.tank, "from": self.stage["id"], "to": target, "reason": reason,
              "global_step": step, "episodes": self.episodes_in_stage,
              "success_rate": self.success_rate(self.stage["id"], 40), "curriculum_version": VERSION}
        self.history.append(ev)
        return ev

    def set_stage(self, sid, global_step):
        idx = STAGE_IDS.index(sid)
        if self.tank == SHARED and idx == 2:
            raise ValueError("최종 전투는 전차별 분화 후 시작하세요")
        if idx == self.stage_idx:
            return None
        event = self._event(sid, global_step, "manual")
        self.stage_idx, self.stage_start_step, self.episodes_in_stage = idx, global_step, 0
        self.common_complete = False
        return event

    def branch(self, tank, global_step, source):
        if not self.common_complete:
            raise ValueError("공통 평지·지형 전투를 먼저 마쳐야 합니다")
        c = BattleCurriculum(tank, 2, self.review_prob, entropy_boost=self.entropy_boost,
                             entropy_steps=self.entropy_steps)
        c.stage_start_step, c.branched_from = global_step, source
        c.history = copy.deepcopy(self.history)
        c._event(STAGE_IDS[2], global_step, "branch")
        c.history[-1]["from"] = self.stage["id"]
        c.history[-1]["source"] = source
        for sid in STAGE_IDS[:2]:
            for v in STAGES[STAGE_IDS.index(sid)]["variants"]:
                k = self.key(v, tank)
                c.results[sid][k].extend(self.results[sid][k])
                c.metrics[sid][k].extend(copy.deepcopy(self.metrics[sid][k]))
        return c

    def state(self):
        return {"curriculum_version": VERSION, "balance_version": BALANCE_VERSION, "reward_version": REWARD_VERSION,
                "tank": self.tank, "stage": self.stage["id"],
                "stage_idx": self.stage_idx, "common_complete": self.common_complete,
                "episodes_in_stage": self.episodes_in_stage, "stage_start_step": self.stage_start_step,
                "branched_from": self.branched_from, "history": self.history,
                "results": {s: {k: list(v) for k, v in vals.items()} for s, vals in self.results.items()},
                "metrics": {s: {k: list(v) for k, v in vals.items()} for s, vals in self.metrics.items()},
                "recent_success": {s: self.success_rate(s, 40) for s in STAGE_IDS}}

    def save(self, path):
        with open(path, "w", encoding="utf-8") as f:
            json.dump(self.state(), f, ensure_ascii=False, indent=2)

    @classmethod
    def load(cls, path, tank, **kw):
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
        if state.get("curriculum_version") != VERSION or state.get("tank") != tank:
            raise ValueError("전투 자기 대전 상태/전차가 일치하지 않습니다")
        c = cls(tank, start_stage=STAGE_IDS.index(state["stage"]), **kw)
        for name in ("common_complete", "episodes_in_stage", "stage_start_step", "branched_from", "history"):
            setattr(c, name, state.get(name, getattr(c, name)))
        for name in ("results", "metrics"):
            for sid, vals in state.get(name, {}).items():
                for k, values in vals.items():
                    getattr(c, name)[sid][k].extend(values)
        if state.get("balance_version", 1) < BALANCE_VERSION or state.get("reward_version", 1) < REWARD_VERSION:
            previous = c.stage["id"]
            c.stage_idx = 0 if tank == SHARED else 2
            c.common_complete = False
            c.episodes_in_stage = 0
            for values in (c.results, c.metrics):
                for pairs in values.values():
                    for rows in pairs.values():
                        rows.clear()
            event = c._event(c.stage["id"], 0, "assessment_upgrade")
            event.update({"from": previous, "assessment_version": c.assessment_version,
                          "previous_balance": state.get("balance_version", 1)})
        return c
