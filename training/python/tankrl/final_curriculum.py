"""최종 학습: 티거 I 1대 대 연합군 6대(셔먼 3 + T-34 3), 굴곡·장애물 맵 5종, 매 판 무작위 스폰.

- 시작 모델: V5 전투 자기 대전의 공통(shared) 모델(예: "V5run 1"). 전차 종류마다 그 가중치를 복사해
  티거·셔먼·T-34 모델을 따로 학습한다(같은 종류 전차들은 한 모델을 쓴다).
- 한 판에서 학습 전차는 1대. 나머지 6대는 상대 풀(opponents/)의 고정 스냅숏이 조종한다:
  같은 종류 = 자기 모델의 과거/최신 스냅숏, 아직 스냅숏이 없는 종류 = V5 공통 모델.
- 맵 5종은 지형·장애물이 고정(맵 시드 고정 → Godot 이 맵을 다시 만들지 않아 빠르다).
  양 팀이 들어오는 방향·거리·전차별 위치·차체 방향은 매 판 무작위다.
- 보상 = V5 전투 보상(balance v2) + 엄폐 보상(config.reward.cover, Godot training_reward.gd):
  차체가 여러 적에게 동시에 보이면 감점, 적을 보면서 차체를 가리면(헐다운·수풀) 보상, 이긴 팀 생존 보너스.
"""
from __future__ import annotations

from collections import deque
import copy
import json
import math
import random

from . import battle_curriculum, curriculum, curriculum_v4, scenarios

VERSION = 6
REWARD_VERSION = 2
MAP_VERSION = 1
TANKS = ["tiger1", "sherman75", "t34_76"]
ALLIED_LINEUP = ["sherman75"] * 3 + ["t34_76"] * 3
MAP_SIZE = 600.0
HALF = MAP_SIZE / 2
PLAY = HALF - 30.0          # 스폰이 들어갈 수 있는 범위(경계벽 안쪽)
TIME_LIMIT_S = 240

MAPS = {
    "rolling_woods": "구릉과 숲 — 완만한 언덕 여러 개, 숲 덩어리와 외딴 나무",
    "ridgeline": "중앙 능선 — 통로가 둘 있는 능선, 능선 위 바위(헐다운 자리), 뒷사면 숲",
    "village": "마을 — 집과 돌담·생울타리, 과수원, 거의 평지",
    "valley": "계곡 — 양쪽 높은 능선과 능선 위 숲, 계곡 바닥의 바위·생울타리",
    "boulder_field": "바위 지대 — 울퉁불퉁한 지면, 큰 바위 수십 개와 나무 무리",
}
MAP_IDS = list(MAPS)

STAGES = [
    {"id": "final_1v6", "label": "최종 1대6 · 엄폐 전투", "part": "최종 학습", "scope": "tank",
     "variants": MAP_IDS, "variants_desc": MAPS, "min_steps": 0, "time_limit_s": TIME_LIMIT_S,
     "kind": "combat", "view_lock": -1, "lineup": "battle_selfplay", "lesson": "티거 1 vs 셔먼 3 + T-34 3",
     "learn": "여러 적을 상대로 지형·장애물을 엄폐·은폐에 쓰며 싸우기(헐다운, 노출 최소화, 측면 기동)",
     "goal": "적 팀 전멸. 시간 초과는 무승부이며 승리 보상이 없다.",
     "promote": {"window": 40, "threshold": None, "min_episodes": 0, "max_episodes": None}},
]
STAGE_IDS = [s["id"] for s in STAGES]


# ---------------------------------------------------------------- 맵 5종 (고정 배치)

def _r(v):
    return round(float(v), 2)


def _stone(x, z, w, h, d, yaw=0.0):
    return {"type": "stone", "p": [_r(x), _r(z)], "size": [_r(w), _r(h), _r(d)], "yaw": _r(yaw)}


def _house(x, z, w, h, d, yaw=0.0):
    return {"type": "house", "p": [_r(x), _r(z)], "size": [_r(w), _r(h), _r(d)], "yaw": _r(yaw)}


def _line(kind, a, b):
    return {"type": kind, "p": [_r(a[0]), _r(a[1])], "b": [_r(b[0]), _r(b[1])]}


def _tree(x, z, seed):
    return {"type": "tree", "p": [_r(x), _r(z)], "seed": int(seed)}


def _woods(x, z, r, seed):
    return {"type": "woods", "p": [_r(x), _r(z)], "r": _r(r), "seed": int(seed)}


def _boundary():
    """맵 밖으로 나가지 않게 네 변에 낮은 벽(시야는 거의 안 가림)."""
    e = HALF - 3
    return [_stone(-e, 0, 4, 4, MAP_SIZE, 0), _stone(e, 0, 4, 4, MAP_SIZE, 0),
            _stone(0, -e, MAP_SIZE, 4, 4, 0), _stone(0, e, MAP_SIZE, 4, 4, 0)]


def _scatter(rng, n, avoid=(), spread=PLAY - 20, min_gap=14.0):
    pts = []
    tries = 0
    while len(pts) < n and tries < n * 60:
        tries += 1
        p = (rng.uniform(-spread, spread), rng.uniform(-spread, spread))
        if any(math.dist(p, q) < min_gap for q in pts) or any(math.dist(p, c) < r for c, r in avoid):
            continue
        pts.append(p)
    return pts


def build_map(map_id: str) -> tuple[dict, list[dict]]:
    """(map config, obstacles). 같은 맵 = 항상 같은 결과(고정 시드)."""
    rng = random.Random(f"final-map-{map_id}-v{MAP_VERSION}")
    mc = {"features": False, "size_m": MAP_SIZE, "cell_m": 4, "ridge_count": 0,
          "seed": 7000 + MAP_IDS.index(map_id), "amplitude": 0.0, "noise_frequency": 0.0025,
          "custom_ridges": [], "mounds": []}
    obs: list[dict] = []
    if map_id == "rolling_woods":
        mc.update(amplitude=4.0, noise_frequency=0.006)
        mc["mounds"] = [[-120, -80, 9, 45], [110, 60, 10, 50], [0, 160, 7, 40], [-70, 150, 6, 35],
                        [150, -140, 8, 45], [-175, 45, 7, 40], [40, -45, 5, 30], [-20, -175, 6, 38]]
        for i, (x, z, r) in enumerate([(-55, 20, 24), (90, -60, 22), (25, 110, 18), (-150, -170, 22),
                                       (175, 150, 20), (-200, 120, 18), (160, 10, 16)]):
            obs.append(_woods(x, z, r, 11 + i))
        for i, (x, z) in enumerate(_scatter(rng, 22, avoid=[((-55, 20), 34), ((90, -60), 32), ((25, 110), 28)])):
            obs.append(_tree(x, z, 100 + i))
        for x, z in _scatter(rng, 16, min_gap=30):
            obs.append(_stone(x, z, rng.uniform(4, 8), rng.uniform(2.0, 3.2), rng.uniform(4, 8), rng.uniform(-1, 1)))
    elif map_id == "ridgeline":
        mc.update(amplitude=2.0, noise_frequency=0.005)
        yaw = 0.25
        mc["custom_ridges"] = [
            {"c": [0, 0], "yaw": yaw, "len": 400, "h": 8.0, "sigma": 28, "gaps": [[-140, 0.75], [120, 0.65]]},
            {"c": [-170 * math.sin(yaw) * -1, -170 * math.cos(yaw)], "yaw": yaw, "len": 250, "h": 4.0, "sigma": 20,
             "gaps": [[30, 0.6]]},
            {"c": [170 * math.sin(yaw) * -1, 170 * math.cos(yaw)], "yaw": yaw, "len": 250, "h": 4.0, "sigma": 20,
             "gaps": [[-40, 0.6]]},
        ]
        ca, sa = math.cos(yaw), math.sin(yaw)

        def world(along, across):
            return along * ca - across * sa, along * sa + across * ca
        for along in (-230, -185, -90, -50, -5, 40, 75, 170, 215):
            x, z = world(along + rng.uniform(-8, 8), rng.uniform(-6, 6))
            obs.append(_stone(x, z, rng.uniform(4, 7), rng.uniform(1.4, 2.2), rng.uniform(3, 5), yaw + rng.uniform(-0.4, 0.4)))
        for i, (along, across) in enumerate([(-200, 70), (-20, 65), (150, 75), (-120, -70), (60, -65), (220, -70)]):
            x, z = world(along, across)
            obs.append(_woods(x, z, rng.uniform(14, 20), 31 + i))
        for i in range(14):
            x, z = world(rng.uniform(-250, 250), rng.choice([-1, 1]) * rng.uniform(100, 220))
            obs.append(_tree(x, z, 300 + i))
    elif map_id == "village":
        mc.update(amplitude=2.0, noise_frequency=0.004)
        mc["mounds"] = [[-200, -180, 5, 40], [210, 190, 5, 40]]
        streets = [-60, 0, 60]
        for gx in (-90, -30, 30, 90):
            for gz in (-85, -30, 30, 85):
                if rng.random() < 0.18 or (gx in (-30, 30) and gz in (-30, 30) and rng.random() < 0.5):
                    continue   # 광장·빈터
                obs.append(_house(gx + rng.uniform(-6, 6), gz + rng.uniform(-6, 6), rng.uniform(9, 14),
                                  rng.uniform(5, 7.5), rng.uniform(9, 13), rng.choice([0, math.pi / 2]) + rng.uniform(-0.1, 0.1)))
        del streets
        for a, b in [((-140, -130), (-40, -130)), ((40, 130), (140, 130)), ((-130, 40), (-130, 140)),
                     ((130, -140), (130, -40)), ((-60, 125), (20, 125)), ((-20, -125), (60, -125))]:
            obs.append(_line("wall", a, b))
        for a, b in [((-260, -60), (-150, -60)), ((150, 60), (260, 60)), ((-60, -260), (-60, -170)),
                     ((60, 170), (60, 260)), ((-250, 120), (-170, 200)), ((170, -200), (250, -120))]:
            obs.append(_line("hedge", a, b))
        for i, (cx, cz) in enumerate([(-200, 20), (200, -20), (0, 210), (0, -210)]):
            for k in range(6):
                obs.append(_tree(cx + (k % 3) * 14 - 14, cz + (k // 3) * 14 - 7, 500 + i * 10 + k))
    elif map_id == "valley":
        mc.update(amplitude=2.5, noise_frequency=0.006)
        mc["custom_ridges"] = [
            {"c": [-160, 0], "yaw": math.pi / 2, "len": 400, "h": 11.0, "sigma": 42, "gaps": [[-90, 0.6], [140, 0.5]]},
            {"c": [160, 0], "yaw": math.pi / 2, "len": 400, "h": 11.0, "sigma": 42, "gaps": [[110, 0.6], [-150, 0.5]]},
        ]
        mc["mounds"] = [[0, 0, 4, 30], [-30, 150, 3, 25], [35, -150, 3, 25]]
        for i, (x, z) in enumerate([(-170, -180), (-165, 40), (-175, 200), (170, -200), (165, -10), (175, 170)]):
            obs.append(_woods(x, z, rng.uniform(16, 24), 41 + i))
        for x, z in _scatter(rng, 12, spread=PLAY - 30, min_gap=30):
            obs.append(_stone(x * 0.35, z, rng.uniform(4, 8), rng.uniform(2.0, 3.0), rng.uniform(4, 8), rng.uniform(-1, 1)))
        for a, b in [((-90, -100), (-10, -95)), ((20, 95), (95, 100)), ((-80, 200), (0, 205)), ((10, -205), (85, -200))]:
            obs.append(_line("hedge", a, b))
        for i in range(10):
            obs.append(_tree(rng.uniform(-90, 90), rng.uniform(-260, 260), 600 + i))
    elif map_id == "boulder_field":
        mc.update(amplitude=5.5, noise_frequency=0.010)
        mc["mounds"] = [[-100, 100, 4, 30], [120, -90, 4, 30], [-140, -150, 3, 25], [150, 160, 3, 25]]
        for x, z in _scatter(rng, 45, min_gap=20):
            big = rng.random() < 0.4
            obs.append(_stone(x, z, rng.uniform(5, 10) if big else rng.uniform(3, 6), rng.uniform(2.4, 4.0) if big else rng.uniform(1.6, 2.6),
                              rng.uniform(5, 10) if big else rng.uniform(3, 6), rng.uniform(-1.5, 1.5)))
        for i, (cx, cz) in enumerate([(-60, -40), (70, 50), (-180, 60), (190, -50), (0, 190), (10, -190)]):
            for k in range(4):
                obs.append(_tree(cx + rng.uniform(-14, 14), cz + rng.uniform(-14, 14), 700 + i * 10 + k))
        for a, b in [((-40, 120), (40, 125)), ((-30, -125), (45, -120))]:
            obs.append(_line("wall", a, b))
    else:
        raise ValueError(f"Unknown final map: {map_id}")
    return mc, obs + _boundary()


# ---------------------------------------------------------------- 배치(매 판 무작위)

def _clamp(p):
    return [_r(max(-PLAY, min(PLAY, p[0]))), _r(max(-PLAY, min(PLAY, p[1])))]


def spawn_positions(rng: random.Random, n_allies: int):
    """(tiger 위치, 연합군 위치 목록, 진입 각도, 거리). 축 방향·거리·옆 위치·흩어짐 모두 무작위."""
    theta = rng.uniform(-math.pi, math.pi)
    frame = scenarios.Frame(theta, (rng.uniform(-50, 50), rng.uniform(-50, 50)))
    distance = rng.uniform(260, 420)
    tiger = _clamp(frame.p(rng.uniform(-90, 90), -distance / 2 + rng.uniform(-25, 25)))
    center_u = rng.uniform(-60, 60)
    spread = rng.uniform(50, 140)       # 몰려 있거나 넓게 흩어져 있거나
    allies = []
    tries = 0
    while len(allies) < n_allies and tries < 400:
        tries += 1
        p = _clamp(frame.p(center_u + rng.uniform(-spread, spread), distance / 2 + rng.uniform(-45, 45)))
        if all(math.dist(p, q) >= 18 for q in allies) and math.dist(p, tiger) > 180:
            allies.append(p)
    while len(allies) < n_allies:     # 거의 일어나지 않음: Godot 이 안전한 자리로 옮긴다
        allies.append(_clamp(frame.p(center_u + 20 * len(allies), distance / 2)))
    return tiger, allies, theta, distance


def arena(map_id: str, tank: str, seed: int):
    """학습 전차가 항상 첫 번째. 반환 (lineup, scenario, map config)."""
    rng = random.Random(seed)
    mc, obstacles = build_map(map_id)
    tiger, allies, theta, distance = spawn_positions(rng, len(ALLIED_LINEUP))
    allied_types = list(ALLIED_LINEUP)
    rng.shuffle(allied_types)
    order = [("tiger1", tiger)] + list(zip(allied_types, allies))
    if tank != "tiger1":
        k = next(i for i, (t, _) in enumerate(order) if t == tank)
        order.insert(0, order.pop(k))
    lu, places = [], []
    allied_c = (sum(p[0] for p in allies) / len(allies), sum(p[1] for p in allies) / len(allies))
    for i, (typ, p) in enumerate(order):
        lu.append({"type": typ, "team": scenarios.TEAM_OF[typ], "ctrl": "external",
                   "role": "learner" if i == 0 else "opponent"})
        target = allied_c if typ == "tiger1" else tiger
        places.append({"p": p, "yaw": round(scenarios.yaw_to(p, target) + rng.uniform(-0.45, 0.45), 4)})
    sc = {"version": 1, "id": "final_1v6", "variant": map_id, "goal": "battle", "observation_version": 3,
          "projectile_version": 1, "learner": places[0], "enemies": places[1:], "obstacles": obstacles,
          "final": {"version": VERSION, "map": map_id, "map_version": MAP_VERSION, "entry_angle": round(theta, 4),
                    "distance_m": round(distance, 1)}}
    return lu, sc, mc


def reward_config() -> dict:
    reward = {"battle_shaping": True, "progressive_combat_v2": True, "reward_version": battle_curriculum.REWARD_VERSION,
            "final_reward_version": REWARD_VERSION,
            "time_per_s": -0.02, "win": 200.0, "loss": -80.0, "timeout_penalty": -35.0, "spot": 0.0,
            "shaping_scale": 0.0, "survive_win": 30.0,
            "near_miss_radius_m": 4.0, "near_miss_bonus": 2.0, "near_miss_budget": 3.0,
            "near_pen_bonus": 2.0, "near_pen_budget": 4.0,
            # 1대6 에서는 무작정 돌격보다 엄폐가 중요: 접근 보조 보상을 V5 의 절반으로
            "close_after_failures": 2, "close_after_stall_s": 15.0,
            "closing_per_m": 0.03, "closing_budget": 3.5,
            "close_distances": [150, 100, 60, 30], "close_bonuses": [0.25, 0.5, 0.75, 1.0],
            "cover": {"version": 1, "every": 5, "seen_hull_per_s": -0.1, "max_observers": 3,
                      "exposure_budget": -20.0, "overwatch_per_s": 0.05, "overwatch_budget": 8.0},
            "combat": {"hit": 0.2, "penetration": 8.0, "knockout": 25.0,
                       "module_damaged": 1.5, "module_destroyed": 5.0,
                       "crew_wounded": 2.0, "crew_kia": 5.0,
                       "miss": -0.05, "victim_scale": 1.0, "live_target_only": True}}
    reward.update(battle_curriculum.attack_shaping_config())
    reward["combat"].update(friendly_fire=-3.0, friendly_knockout=-60.0)
    return reward


class FinalCurriculum:
    version = VERSION
    assessment_version = 1
    balance_version = battle_curriculum.BALANCE_VERSION
    reward_version = REWARD_VERSION
    obs = "battle"
    stages = STAGES
    stage_ids = STAGE_IDS
    dashboard_offset = len(curriculum.STAGES) + len(curriculum_v4.STAGES) + len(battle_curriculum.STAGES)

    def __init__(self, tank, start_stage=0, review_prob=0.0, seed=0,
                 entropy_boost=0.003, entropy_steps=300_000):
        if tank not in TANKS:
            raise ValueError(f"최종 학습은 전차별 모델입니다(공통 모델 불가): {tank}")
        self.tank = tank
        self.tanks = [tank]
        self.stage_idx = 0
        self.review_prob = review_prob
        self.rng = random.Random(seed)
        self.entropy_boost, self.entropy_steps = entropy_boost, entropy_steps
        self.episodes_in_stage = self.stage_start_step = 0
        self.common_complete = False
        self.branched_from = ""
        self.initialized_from = ""
        self.terrain_fixed = ""
        self.history = []
        self.results = {s["id"]: {self.key(v, tank): deque(maxlen=80) for v in s["variants"]} for s in STAGES}
        self.metrics = copy.deepcopy(self.results)

    @staticmethod
    def key(variant, tank):
        return f"{variant}@{tank}"

    @property
    def stage(self):
        return STAGES[self.stage_idx]

    @property
    def training_complete(self):
        return False   # 설정한 스텝만큼 계속 개선

    def shaping_scale(self, stage_id):
        return 0.0

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
            fields = ("hit", "pen", "resolved", "survived", "overwatch", "multi_seen")
            out[key] = {"episodes": len(recent), **{
                k: sum(row.get(k, 0) for row in recent) / len(recent) if recent else 0.0 for k in fields}}
        return out

    def build_episode(self, learner, rng, seed):
        st = self.stage
        counts = self.metrics[st["id"]]
        minimum = min(len(v) for v in counts.values())
        key = rng.choice([k for k, v in counts.items() if len(v) == minimum])
        variant, actual = key.split("@")
        lu, sc, mc = arena(variant, actual, seed)
        st = dict(st, map=mc)
        return st, lu, {"scenario": sc, "learner": actual, "model": self.tank, "selfplay": True,
                        "reward": reward_config(), "kind": "combat", "time_limit_s": st["time_limit_s"],
                        "curriculum_version": VERSION, "stageset": "final-1v6", "map_seed": mc["seed"],
                        "balance_version": battle_curriculum.BALANCE_VERSION, "final_battle_version": 1,
                        "learning_objective": {"id": st["id"], "label": st["label"], "version": REWARD_VERSION}}

    def report_battle(self, sid, success, global_step, variant, learner, stats, episode):
        key = self.key(variant, learner)
        if key not in self.results.get(sid, {}):
            return None
        self.results[sid][key].append(int(success))
        scen = episode.get("scenario", {}) or {}
        cover = scen.get("cover", {}) or {}
        dur = max(0.1, float(episode.get("duration_s", 0) or 0.1))
        alive = str(scen.get("status", "")) not in ("destroyed", "knocked_out")
        self.metrics[sid][key].append({"hit": int(stats.get("hits", 0) > 0), "pen": int(stats.get("pens", 0) > 0),
                                       "resolved": int(episode.get("winner", -1) in (0, 1)), "survived": int(alive),
                                       "overwatch": round(float(cover.get("overwatch_s", 0)) / dur, 4),
                                       "multi_seen": round(float(cover.get("multi_seen_s", 0)) / dur, 4)})
        self.episodes_in_stage += 1
        return None

    def set_stage(self, sid, global_step):
        if sid not in STAGE_IDS:
            raise ValueError("최종 학습에는 단계가 하나뿐입니다")
        return None

    def state(self):
        return {"curriculum_version": VERSION, "reward_version": REWARD_VERSION, "map_version": MAP_VERSION,
                "balance_version": self.balance_version, "tank": self.tank, "stage": self.stage["id"],
                "stage_idx": self.stage_idx, "common_complete": False,
                "episodes_in_stage": self.episodes_in_stage, "stage_start_step": self.stage_start_step,
                "branched_from": self.branched_from, "initialized_from": self.initialized_from,
                "history": self.history,
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
            raise ValueError("최종 학습 상태/전차가 일치하지 않습니다")
        kw.pop("start_stage", None)
        c = cls(tank, **kw)
        for name in ("episodes_in_stage", "stage_start_step", "branched_from", "initialized_from", "history"):
            setattr(c, name, state.get(name, getattr(c, name)))
        for name in ("results", "metrics"):
            for sid, vals in state.get(name, {}).items():
                for k, values in vals.items():
                    if sid in getattr(c, name) and k in getattr(c, name)[sid]:
                        getattr(c, name)[sid][k].extend(values)
        return c

    def initialize_from(self, source: str, global_step: int):
        """V5 공통 모델에서 이 전차 모델을 처음 만들 때 기록."""
        self.initialized_from = source
        self.stage_start_step = global_step
        ev = {"tank": self.tank, "from": "battle(V5) shared", "to": STAGE_IDS[0], "reason": "final_init",
              "source": source, "global_step": global_step, "episodes": 0, "success_rate": 0.0,
              "curriculum_version": VERSION}
        self.history.append(ev)
        return ev


def dump_maps(path: str) -> None:
    """맵 미리보기용 JSON(training/tools/final_map_preview.gd)."""
    out = {}
    for map_id in MAP_IDS:
        mc, obstacles = build_map(map_id)
        out[map_id] = {"map": mc, "obstacles": obstacles, "label": MAPS[map_id]}
    with open(path, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False)
