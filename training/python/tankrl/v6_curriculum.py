"""V6 커리큘럼: 티거 1대 vs 연합군, 적 수 사다리(1 → 2 → 3 → 6), 엄폐 맵 5종, 비례 보상(전력 교환).

- 전차 종류마다 모델 하나(티거·셔먼·T-34). 같은 종류 전차들은 그 종류 모델(학습 중이면 과거 스냅숏)을 쓴다.
- 연합군 일부는 게임의 규칙 AI(ScriptedAI, ctrl "scripted")가 조종한다:
    우회조 = 측면 오프셋을 크게 두고 접근해 근거리에서 사격, 견제조 = 정면에서 중거리 정지 사격.
  학습 전차가 연합군이면 그 전차는 항상 모델이 조종한다.
- 보상 = 전력 교환(config.reward.exchange, Godot training_reward.gd):
    enemy × Δ적 팀 전력손실 − own × Δ내 팀 전력손실 + 결말(승리 win / 패배·시간 초과 loss) + 시간 감점.
  팀 전력손실은 시작 전차 수로 나눈 비율이라 적 수가 달라도 같은 척도다.
  명중·근접 탄·조준 같은 보조 보상은 사다리 아래 단계에서만 주고 단계가 오를수록 줄인다(1대6 에서 0).
- 관통 balance v3(tank_database.gd): 연합군 포는 티거 정면을 근거리에서만, 측면은 교전 거리에서 관통.
- 승급: 학습 전차의 맵별 최근 판에서 결판(시간 초과 아님) 비율과 승률이 기준 이상, 첫 단계는 이동 거리도 본다.
"""
from __future__ import annotations

import math
import random
from collections import deque

from . import battle_curriculum, final_curriculum, scenarios
from .final_curriculum import FinalCurriculum, MAP_IDS, MAPS, build_map

VERSION = 7                    # curriculum_version (final = 6)
REWARD_VERSION = 1
BALANCE_VERSION = 3
TANKS = final_curriculum.TANKS
ALLIED = ["sherman75", "t34_76"]

# 단계별 보조 보상 배율(사다리를 오를수록 결과 보상만 남긴다)
STAGES = [
    {"id": "v6_1v1", "label": "V6-1 · 1대1 엄폐 맵", "allies": 1, "rule": [0, 1], "distance": (120, 250),
     "time_limit_s": 150, "shaping": 1.0,
     "promote": {"window": 60, "resolved": 0.6, "win": 0.4, "path_m": 30.0, "min_episodes": 60}},
    {"id": "v6_1v2", "label": "V6-2 · 1대2", "allies": 2, "rule": [1, 1], "distance": (180, 300),
     "time_limit_s": 180, "shaping": 0.6,
     "promote": {"window": 60, "resolved": 0.6, "win": 0.35, "path_m": 0.0, "min_episodes": 60}},
    {"id": "v6_1v3", "label": "V6-3 · 1대3", "allies": 3, "rule": [1, 1], "distance": (220, 360),
     "time_limit_s": 210, "shaping": 0.3,
     "promote": {"window": 60, "resolved": 0.55, "win": 0.35, "path_m": 0.0, "min_episodes": 60}},
    {"id": "v6_1v6", "label": "V6-4 · 1대6", "allies": 6, "rule": [2, 2], "distance": (260, 420),
     "time_limit_s": 240, "shaping": 0.0, "promote": None},
]
for _s in STAGES:
    _s.update({"part": "V6", "scope": "tank", "variants": MAP_IDS, "variants_desc": MAPS, "min_steps": 0,
               "kind": "combat", "view_lock": -1, "lineup": "v6_ladder",
               "lesson": f"티거 1 vs 연합군 {_s['allies']} (규칙 AI {_s['rule'][0]}~{_s['rule'][1]}대)",
               "learn": "엄폐 맵에서 움직여 사선을 잡고, 전력을 덜 잃으며 더 많이 줄이기",
               "goal": "적 팀 전멸. 시간 초과는 패배와 같다."})
STAGE_IDS = [s["id"] for s in STAGES]

# 규칙 AI 성향(ScriptedAI 파라미터, training_env.gd SCENARIO_AI_KEYS)
RULE_FLANK = {"advance": True, "engage_range": 200.0, "max_fire_range": 350.0, "fire_delay_s": 0.6, "aim_noise_mrad": 1.0}
RULE_PIN = {"advance": True, "flank_offset": 0.0, "engage_range": 320.0, "max_fire_range": 600.0, "fire_delay_s": 0.8,
            "aim_noise_mrad": 1.2}


def allied_lineup(n: int, rng: random.Random) -> list[str]:
    if n == 6:
        out = ["sherman75"] * 3 + ["t34_76"] * 3
    elif n == 1:
        out = [rng.choice(ALLIED)]
    else:
        out = [ALLIED[k % 2] for k in range(n)]
        if n % 2:
            out[-1] = rng.choice(ALLIED)
    rng.shuffle(out)
    return out


def spawn(rng: random.Random, n: int, distance_range: tuple[float, float]):
    """final_curriculum.spawn_positions 와 같은 방식, 거리 범위만 단계별."""
    theta = rng.uniform(-math.pi, math.pi)
    frame = scenarios.Frame(theta, (rng.uniform(-50, 50), rng.uniform(-50, 50)))
    distance = rng.uniform(*distance_range)
    tiger = final_curriculum._clamp(frame.p(rng.uniform(-90, 90), -distance / 2 + rng.uniform(-20, 20)))
    center_u = rng.uniform(-60, 60)
    spread = rng.uniform(30, 40 + 25 * n)
    allies, tries = [], 0
    min_gap = min(150.0, distance * 0.6)
    while len(allies) < n and tries < 400:
        tries += 1
        p = final_curriculum._clamp(frame.p(center_u + rng.uniform(-spread, spread), distance / 2 + rng.uniform(-35, 35)))
        if all(math.dist(p, q) >= 18 for q in allies) and math.dist(p, tiger) > min_gap:
            allies.append(p)
    while len(allies) < n:
        allies.append(final_curriculum._clamp(frame.p(center_u + 20 * len(allies), distance / 2)))
    return tiger, allies, theta, distance


def arena(stage: dict, map_id: str, tank: str, seed: int):
    """학습 전차가 항상 첫 번째. 반환 (lineup, scenario, map config, rule AI 수)."""
    rng = random.Random(seed)
    mc, obstacles = build_map(map_id)
    n = int(stage["allies"])
    types = allied_lineup(n, rng)
    if tank != "tiger1" and tank not in types:
        types[rng.randrange(n)] = tank
    tiger, allies, theta, distance = spawn(rng, n, stage["distance"])
    order = [("tiger1", tiger)] + list(zip(types, allies))
    if tank != "tiger1":
        k = next(i for i, (t, _) in enumerate(order) if t == tank)
        order.insert(0, order.pop(k))
    lo, hi = stage["rule"]
    n_rule = rng.randint(lo, hi)
    allied_idx = [i for i, (t, _) in enumerate(order) if t != "tiger1" and i != 0]
    rng.shuffle(allied_idx)
    rule_idx = set(allied_idx[:min(n_rule, len(allied_idx))])
    allied_c = (sum(p[0] for p in allies) / n, sum(p[1] for p in allies) / n)
    lu, places = [], []
    flank_side = rng.choice([-1.0, 1.0])
    for i, (typ, p) in enumerate(order):
        rule = i in rule_idx
        lu.append({"type": typ, "team": scenarios.TEAM_OF[typ], "ctrl": "scripted" if rule else "external",
                   "role": "learner" if i == 0 else ("rule" if rule else "opponent")})
        target = allied_c if typ == "tiger1" else tiger
        place = {"p": p, "yaw": round(scenarios.yaw_to(p, target) + rng.uniform(-0.45, 0.45), 4)}
        if rule:
            # 첫 규칙 AI 는 우회조, 1대6 의 두 번째는 견제조
            if len([j for j in rule_idx if j < i]) == 0:
                place["ai"] = dict(RULE_FLANK, flank_offset=flank_side * rng.uniform(180.0, 260.0))
            else:
                place["ai"] = dict(RULE_PIN)
        places.append(place)
    sc = {"version": 1, "id": stage["id"], "variant": map_id, "goal": "battle", "observation_version": 3,
          "projectile_version": 1, "learner": places[0], "enemies": places[1:], "obstacles": obstacles,
          "final": {"version": final_curriculum.VERSION, "map": map_id, "map_version": final_curriculum.MAP_VERSION,
                    "entry_angle": round(theta, 4), "distance_m": round(distance, 1)},
          "v6": {"version": VERSION, "allies": n, "rule_ai": len(rule_idx)}}
    return lu, sc, mc, len(rule_idx)


def reward_config(stage: dict) -> dict:
    """전력 교환 + 단계별로 줄어드는 보조 보상. 기존 승패·격파·관통 보상은 끈다(교환 점수가 대신한다)."""
    k = float(stage["shaping"])
    attack = battle_curriculum.attack_shaping_config()
    for name in ("near_miss_bonus", "aim_alignment_bonus", "aim_overlap_per_s", "aimed_fire_bonus"):
        attack[name] = attack[name] * k
    reward = {"battle_shaping": True, "progressive_combat_v2": True, "reward_version": battle_curriculum.REWARD_VERSION,
              "v6_reward_version": REWARD_VERSION, "time_per_s": -0.02, "win": 0.0, "loss": 0.0,
              "timeout_penalty": 0.0, "survive_win": 0.0, "spot": 0.0, "shaping_scale": k,
              "near_miss_radius_m": 4.0, "near_miss_bonus": 2.0 * k, "near_miss_budget": 3.0 * k,
              "near_pen_bonus": 2.0 * k, "near_pen_budget": 4.0 * k,
              "close_after_failures": 2, "close_after_stall_s": 15.0, "closing_per_m": 0.0, "closing_budget": 0.0,
              "close_distances": [150, 100, 60, 30], "close_bonuses": [0.0, 0.0, 0.0, 0.0],
              "exchange": {"version": 1, "enemy": 200.0, "own": 120.0, "win": 100.0, "loss": -60.0, "contrib": 0.2,
                           "weights": {"gun": 0.5, "mobility": 0.3, "crew_kia": 0.15, "crew_wounded": 0.05}},
              "combat": {"hit": 0.2 * k, "penetration": 0.0, "knockout": 0.0, "module_damaged": 0.0,
                         "module_destroyed": 0.0, "crew_wounded": 0.0, "crew_kia": 0.0,
                         "miss": -0.05 * k, "victim_scale": 0.0, "live_target_only": True}}
    reward.update(attack)
    reward["combat"].update(friendly_fire=-3.0, friendly_knockout=-60.0)
    return reward


class V6Curriculum(FinalCurriculum):
    version = VERSION
    assessment_version = 1
    balance_version = BALANCE_VERSION
    reward_version = REWARD_VERSION
    obs = "battle"
    stages = STAGES
    stage_ids = STAGE_IDS

    def __init__(self, tank, start_stage=0, review_prob=0.1, seed=0, entropy_boost=0.003, entropy_steps=300_000):
        super().__init__(tank, review_prob=review_prob, seed=seed, entropy_boost=entropy_boost,
                         entropy_steps=entropy_steps)
        self.stage_idx = int(start_stage)
        self.results = {s["id"]: {self.key(v, tank): deque(maxlen=200) for v in s["variants"]} for s in STAGES}
        self.metrics = {s["id"]: {self.key(v, tank): deque(maxlen=200) for v in s["variants"]} for s in STAGES}

    @property
    def stage(self):
        return STAGES[self.stage_idx]

    def shaping_scale(self, stage_id):
        return float(next(s for s in STAGES if s["id"] == stage_id)["shaping"])

    def combat_metrics(self):
        out = {}
        for key, values in self.metrics[self.stage["id"]].items():
            recent = list(values)[-60:]
            fields = ("win", "resolved", "survived", "path_m", "enemy_lost", "own_lost", "hit")
            out[key] = {"episodes": len(recent), **{
                k: sum(row.get(k, 0) for row in recent) / len(recent) if recent else 0.0 for k in fields}}
        return out

    def build_episode(self, learner, rng, seed):
        st = self.stage
        if self.stage_idx > 0 and self.review_prob > 0 and rng.random() < self.review_prob:
            st = STAGES[rng.randrange(self.stage_idx)]     # 이전 단계 복습
        counts = self.metrics[st["id"]]
        minimum = min(len(v) for v in counts.values())
        key = rng.choice([k for k, v in counts.items() if len(v) == minimum])
        variant, actual = key.split("@")
        lu, sc, mc, n_rule = arena(st, variant, actual, seed)
        st = dict(st, map=mc)
        return st, lu, {"scenario": sc, "learner": actual, "model": self.tank, "selfplay": True,
                        "reward": reward_config(st), "kind": "combat", "time_limit_s": st["time_limit_s"],
                        "curriculum_version": VERSION, "stageset": "v6-ladder", "map_seed": mc["seed"],
                        "balance_version": BALANCE_VERSION, "final_battle_version": 1, "v6_version": 1,
                        "learning_objective": {"id": st["id"], "label": st["label"], "version": REWARD_VERSION}}

    def report_battle(self, sid, success, global_step, variant, learner, stats, episode):
        key = self.key(variant, learner)
        if key not in self.results.get(sid, {}):
            return None
        self.results[sid][key].append(int(success))
        scen = episode.get("scenario", {}) or {}
        ex = episode.get("exchange", {}) or {}
        lost = ex.get("team_lost", [0.0, 0.0])
        team = 0 if learner == "tiger1" else 1
        alive = str(scen.get("status", "")) not in ("destroyed", "knocked_out")
        self.metrics[sid][key].append({
            "win": int(success), "resolved": int(episode.get("winner", -1) in (0, 1)), "survived": int(alive),
            "path_m": float(scen.get("path_m", 0) or 0), "hit": int(stats.get("hits", 0) > 0),
            "enemy_lost": float(lost[1 - team]) if len(lost) == 2 else 0.0,
            "own_lost": float(lost[team]) if len(lost) == 2 else 0.0})
        if sid != self.stage["id"]:
            return None
        self.episodes_in_stage += 1
        return self._maybe_promote(global_step)

    def _maybe_promote(self, global_step):
        rule = self.stage.get("promote")
        if not rule or self.stage_idx >= len(STAGES) - 1:
            return None
        window = int(rule["window"])
        rows_by_map = [list(v)[-window:] for v in self.metrics[self.stage["id"]].values()]
        if any(len(rows) < min(window, int(rule["min_episodes"])) for rows in rows_by_map):
            return None
        for rows in rows_by_map:
            resolved = sum(r["resolved"] for r in rows) / len(rows)
            win = sum(r["win"] for r in rows) / len(rows)
            path = sorted(r["path_m"] for r in rows)[len(rows) // 2]
            if resolved < rule["resolved"] or win < rule["win"] or path < rule.get("path_m", 0.0):
                return None
        old = self.stage["id"]
        rate = self.success_rate(old, window)
        self.stage_idx += 1
        self.episodes_in_stage = 0
        self.stage_start_step = global_step
        ev = {"tank": self.tank, "from": old, "to": self.stage["id"], "reason": "promoted",
              "global_step": global_step, "episodes": sum(len(r) for r in rows_by_map), "success_rate": rate,
              "curriculum_version": VERSION}
        self.history.append(ev)
        return ev

    def set_stage(self, sid, global_step):
        if sid not in STAGE_IDS:
            raise ValueError(f"V6 단계가 아닙니다: {sid}")
        old = self.stage["id"]
        self.stage_idx = STAGE_IDS.index(sid)
        self.episodes_in_stage = 0
        self.stage_start_step = global_step
        ev = {"tank": self.tank, "from": old, "to": sid, "reason": "manual", "global_step": global_step,
              "episodes": 0, "success_rate": self.success_rate(old, 60), "curriculum_version": VERSION}
        self.history.append(ev)
        return ev

    def state(self):
        return {"curriculum_version": VERSION, "reward_version": REWARD_VERSION, "map_version": final_curriculum.MAP_VERSION,
                "balance_version": BALANCE_VERSION, "tank": self.tank, "stage": self.stage["id"],
                "stage_idx": self.stage_idx, "common_complete": False,
                "episodes_in_stage": self.episodes_in_stage, "stage_start_step": self.stage_start_step,
                "branched_from": self.branched_from, "initialized_from": self.initialized_from,
                "history": self.history,
                "results": {s: {k: list(v) for k, v in vals.items()} for s, vals in self.results.items()},
                "metrics": {s: {k: list(v) for k, v in vals.items()} for s, vals in self.metrics.items()},
                "recent_success": {s: self.success_rate(s, 60) for s in STAGE_IDS}}

    @classmethod
    def load(cls, path, tank, **kw):
        import json
        with open(path, encoding="utf-8") as f:
            state = json.load(f)
        if state.get("curriculum_version") != VERSION or state.get("tank") != tank:
            raise ValueError("V6 학습 상태/전차가 일치하지 않습니다")
        kw.pop("start_stage", None)
        c = cls(tank, start_stage=int(state.get("stage_idx", 0)), **kw)
        for name in ("episodes_in_stage", "stage_start_step", "branched_from", "initialized_from", "history"):
            setattr(c, name, state.get(name, getattr(c, name)))
        for name in ("results", "metrics"):
            for sid, vals in state.get(name, {}).items():
                for k, values in vals.items():
                    if sid in getattr(c, name) and k in getattr(c, name)[sid]:
                        getattr(c, name)[sid][k].extend(values)
        return c

    def initialize_from(self, source: str, global_step: int):
        self.initialized_from = source
        self.stage_start_step = global_step
        ev = {"tank": self.tank, "from": "battle(V5) shared", "to": STAGE_IDS[self.stage_idx], "reason": "v6_init",
              "source": source, "global_step": global_step, "episodes": 0, "success_rate": 0.0,
              "curriculum_version": VERSION}
        self.history.append(ev)
        return ev
