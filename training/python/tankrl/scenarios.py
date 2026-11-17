"""커리큘럼 v4 전투 상황 배치(시드 → config.scenario). Godot 의 training/scenario_layout.gd 가 그대로 놓는다.

설계 원칙
- 배치는 학습 전차 기준 지역 좌표(u = 옆, v = 적 쪽)로 만들고 시드로 정한 각도만큼 돌린다(방향 습관 방지).
- 같은 과제 안의 변형(variant)마다 이기는 선택이 다르다. 변형은 시드로 고르고 결과에 기록한다.
- 보상은 결과(목표 달성·생존·피해 교환)만. 엄폐물·둔덕에 도착하는 것 자체에는 점수가 없다.
- 모든 값은 random.Random(seed) 에서만 나오므로 같은 시드 = 같은 배치(재현).
"""
from __future__ import annotations

import math
import random

VERSION = 1
TEAM_OF = {"tiger1": 0, "sherman75": 1, "t34_76": 1}
ENEMIES_OF = {"tiger1": ["sherman75", "t34_76"], "sherman75": ["tiger1"], "t34_76": ["tiger1"]}
# 적 사거리(m): 티거를 상대하는 연합군 76mm 는 가까워야 위협이 되고, 88mm 는 멀리서도 위협이다.
THREAT_RANGE = {"tiger1": (300, 550), "sherman75": (600, 900), "t34_76": (600, 900)}
DUEL_RANGE = {"tiger1": (250, 450), "sherman75": (450, 750), "t34_76": (450, 750)}


class Frame:
    """지역 좌표(u, v) → 세계 좌표(x, z). Godot Basis(UP, θ) 회전과 같은 방향."""

    def __init__(self, theta: float, origin=(0.0, 0.0)):
        self.theta = theta
        self.c, self.s = math.cos(theta), math.sin(theta)
        self.ox, self.oz = origin

    def p(self, u: float, v: float) -> list[float]:
        return [round(self.ox + u * self.c + v * self.s, 2), round(self.oz - u * self.s + v * self.c, 2)]

    def yaw(self, local_yaw: float = 0.0) -> float:
        return round(self.theta + local_yaw, 4)


def yaw_to(a, b) -> float:
    """a 에서 b 를 바라보는 전차 yaw (training_env.gd 와 같은 규칙)."""
    return round(math.atan2(-(b[0] - a[0]), -(b[1] - a[1])), 4)


def _enemy_ai(rng: random.Random, noise: tuple, delay: tuple, hold=True) -> dict:
    return {"hold": hold, "aim_noise_mrad": round(rng.uniform(*noise), 2),
            "fire_delay_s": round(rng.uniform(*delay), 2), "max_fire_range": 1600.0}


def _finish(sc: dict, f: Frame, learner_uv, enemies_uv, rng, ai, learner_face=None, jitter_deg=25.0):
    lp = f.p(*learner_uv)
    centroid = (sum(e[0] for e in enemies_uv) / len(enemies_uv), sum(e[1] for e in enemies_uv) / len(enemies_uv)) \
        if enemies_uv else (learner_uv[0], learner_uv[1] + 100)
    face = f.p(*(learner_face or centroid))
    sc["learner"] = {"p": lp, "yaw": round(yaw_to(lp, face) + math.radians(rng.uniform(-jitter_deg, jitter_deg)), 4)}
    sc["enemies"] = []
    for e in enemies_uv:
        ep = f.p(*e)
        sc["enemies"].append({"p": ep, "yaw": round(yaw_to(ep, lp) + math.radians(rng.uniform(-15, 15)), 4),
                              "ai": ai(rng) if callable(ai) else dict(ai)})
    return sc


def _base(stage_id: str, variant: str, goal: str, rng: random.Random) -> tuple[dict, Frame]:
    f = Frame(rng.uniform(-math.pi, math.pi), (rng.uniform(-60, 60), rng.uniform(-60, 60)))
    return {"version": VERSION, "id": stage_id, "variant": variant, "goal": goal, "obstacles": []}, f


def _stone(f: Frame, u, v, w, h, d, local_yaw=0.0) -> dict:
    return {"type": "stone", "p": f.p(u, v), "size": [round(w, 2), round(h, 2), round(d, 2)], "yaw": f.yaw(local_yaw)}


def _berm(f: Frame, u, v, w, d, hull_frac, local_yaw=0.0) -> dict:
    return {"type": "berm", "p": f.p(u, v), "w": round(w, 2), "d": round(d, 2), "hull_frac": hull_frac,
            "yaw": f.yaw(local_yaw)}


# ---------------------------------------------------------------- 1부 기동

def move_basic(rng, learner, variant):
    sc, f = _base("m1_move_basic", variant, "reach", rng)
    dist = {"near": (30, 60), "far": (80, 150), "behind": (40, 90)}[variant]
    ang = rng.uniform(-0.6, 0.6) + (math.pi if variant == "behind" else 0.0)
    d = rng.uniform(*dist)
    goal = (d * math.sin(ang), d * math.cos(ang))
    sc["objective"] = {"p": f.p(*goal), "radius": 6.0, "hold_s": 0.6}
    return _finish(sc, f, (0, 0), [], rng, {}, learner_face=(0, 50), jitter_deg=20)


def move_obstacles(rng, learner, variant):
    sc, f = _base("m2_move_obstacles", variant, "reach", rng)
    d = rng.uniform(90, 140)
    sc["objective"] = {"p": f.p(rng.uniform(-15, 15), d), "radius": 7.0, "hold_s": 0.6}
    obs = sc["obstacles"]
    if variant == "clear":       # 직진이 정답: 장애물은 길 옆에만
        for _ in range(4):
            side = rng.choice([-1, 1])
            obs.append(_stone(f, side * rng.uniform(18, 40), rng.uniform(20, d - 10), rng.uniform(4, 8), 3, rng.uniform(4, 8)))
    elif variant == "wall":      # 길을 가로막는 벽, 한쪽 끝으로 우회
        gap_side = rng.choice([-1, 1])
        width = rng.uniform(50, 70)
        obs.append(_stone(f, -gap_side * (width / 2 - 25), d * 0.5, width, 3.5, 3))
    else:                        # gates: 엇갈린 통로 두 개
        g1, g2 = rng.choice([(-1, 1), (1, -1)])
        for v, g in ((d * 0.35, g1), (d * 0.7, g2)):
            obs.append(_stone(f, -g * 22, v, 36, 3.5, 3))
            obs.append(_stone(f, g * 38, v, 20, 3.5, 3))
    return _finish(sc, f, (0, 0), [], rng, {}, learner_face=(0, 50), jitter_deg=30)


def move_under_fire(rng, learner, variant):
    """먼 거리의 부정확한 적 여러 대가 사격하는 가운데 옆으로 이동.
    screened: 진행 경로 앞을 벽이 가려 줌(직진이 최선) / open_cover: 개활지, 경로 근처 바위(엄폐 경유 또는 빠른 돌파)
    long_detour: 엄폐는 멀리 있고 적은 매우 부정확(돌아가면 손해, 직진 돌파가 유리)."""
    sc, f = _base("m3_move_under_fire", variant, "reach", rng)
    lat = rng.choice([-1, 1]) * rng.uniform(120, 180)
    sc["objective"] = {"p": f.p(lat, rng.uniform(-10, 30)), "radius": 8.0, "hold_s": 0.6}
    r0, r1 = THREAT_RANGE[learner]
    enemies = [(rng.uniform(-200, 200), rng.uniform(r0, r1)) for _ in range(rng.randint(2, 4))]
    obs = sc["obstacles"]
    noise = (2.0, 4.0)
    if variant == "screened":
        n = int(abs(lat) // 30) + 1
        for k in range(n):
            obs.append(_stone(f, lat * (k + 0.5) / n, rng.uniform(18, 26), 30, 4.0, 3))
    elif variant == "open_cover":
        for k in range(3):
            obs.append(_stone(f, lat * (k + 1) / 4 + rng.uniform(-10, 10), rng.uniform(8, 16), rng.uniform(7, 10), 3.5, rng.uniform(5, 8)))
    else:
        noise = (6.0, 9.0)
        obs.append(_stone(f, lat * 0.5, -rng.uniform(70, 100), 40, 4.0, 4))
    return _finish(sc, f, (0, 0), enemies, rng, lambda r: _enemy_ai(r, noise, (1.5, 3.0)), learner_face=(lat, 0), jitter_deg=40)


def ambush(rng, learner, variant):
    """적이 사격을 시작한 상황에서 정해진 시간 생존. 엄폐 위치가 변형마다 다르다(가까운 둔덕 / 먼 바위 / 뒤쪽 벽)."""
    sc, f = _base("m4_ambush", variant, "survive", rng)
    r0, r1 = THREAT_RANGE[learner]
    enemies = [(rng.uniform(-120, 120), rng.uniform(r0, r1)) for _ in range(rng.randint(2, 3))]
    obs = sc["obstacles"]
    if variant == "near_cover":
        obs.append(_stone(f, rng.uniform(-25, 25), rng.uniform(15, 25), 14, 4.0, 4))
    elif variant == "far_cover":
        obs.append(_stone(f, rng.choice([-1, 1]) * rng.uniform(50, 75), rng.uniform(-10, 20), 14, 4.5, 8))
    else:  # reverse: 뒤쪽 벽 뒤로 물러나야 시야가 끊긴다
        obs.append(_stone(f, rng.uniform(-10, 10), -rng.uniform(25, 40), 30, 4.5, 4))
    sc["survive_s"] = 40
    return _finish(sc, f, (0, 0), enemies, rng, lambda r: _enemy_ai(r, (1.5, 3.0), (0.8, 1.5)), jitter_deg=60)


def crossing(rng, learner, variant):
    """엄폐 없이 적 사선을 가로지르는 횡단. 적은 이동 표적에 리드를 주지 않으므로 계속 움직이는 쪽이 유리."""
    sc, f = _base("m5_crossing", variant, "reach", rng)
    r0, r1 = THREAT_RANGE[learner]
    d = rng.uniform(150, 220)
    sc["objective"] = {"p": f.p(d, 0), "radius": 8.0, "hold_s": 0.6}
    enemies = [(d * 0.5 + rng.uniform(-80, 80), rng.uniform(r0, r1)) for _ in range(rng.randint(2, 3))]
    noise = {"steady": (1.5, 2.5), "sloppy": (3.5, 5.0), "woods": (2.0, 3.0)}[variant]
    if variant == "woods":
        sc["obstacles"].append({"type": "woods", "p": f.p(d * rng.uniform(0.3, 0.7), rng.uniform(25, 40)),
                                "r": round(rng.uniform(25, 35), 1), "seed": rng.randrange(1, 2**31 - 1)})
    return _finish(sc, f, (0, 0), enemies, rng, lambda r: _enemy_ai(r, noise, (1.0, 2.0)), learner_face=(d, 0), jitter_deg=30)


# ---------------------------------------------------------------- 2부 사격

def gunnery(rng, learner, variant):
    """static / moving / hidden: 반격 없는 표적. 명중 2회."""
    sc, f = _base("g1_gunnery" if variant != "moving" else "g2_gunnery_moving", variant, "hits", rng)
    sc["hits"] = 2
    d = rng.uniform(150, 700)
    ang = rng.uniform(-0.8, 0.8)
    if variant == "hidden":
        sc["obstacles"].append({"type": "woods", "p": f.p(d * math.sin(ang) + 30, d * math.cos(ang) - 20),
                                "r": 20.0, "seed": rng.randrange(1, 2**31 - 1)})
    return _finish(sc, f, (0, 0), [(d * math.sin(ang), d * math.cos(ang))], rng, {"hold": True, "max_fire_range": 0.0},
                   learner_face=(0, 100), jitter_deg=70)


def return_fire(rng, learner, variant):
    """정지한 적 1대가 되쏘는 대결. berm: 바로 앞에 차체 높이 둔덕(헐다운 가능) / open: 엄폐 없음(앵글링·선제 사격)."""
    sc, f = _base("g4_return_fire", variant, "destroy", rng)
    r0, r1 = DUEL_RANGE[learner]
    d = rng.uniform(r0, r1)
    if variant == "berm":
        sc["obstacles"].append(_berm(f, rng.uniform(-3, 3), rng.uniform(9, 14), 14, 3, 0.95))
    return _finish(sc, f, (0, 0), [(rng.uniform(-60, 60), d)], rng, lambda r: _enemy_ai(r, (1.0, 2.0), (1.5, 2.5)),
                   jitter_deg=20)


def close_front(rng, learner, variant):
    """근거리 정면 대결, 엄폐 없음. 차체 각도(앵글링)와 선제 사격이 결과를 가른다."""
    sc, f = _base("g6_close_front", variant, "destroy", rng)
    d = rng.uniform(120, 260) if variant == "close" else rng.uniform(260, 400)
    return _finish(sc, f, (0, 0), [(rng.uniform(-30, 30), d)], rng, lambda r: _enemy_ai(r, (0.8, 1.5), (1.0, 2.0)),
                   jitter_deg=15)


BUILDERS = {"move_basic": move_basic, "move_obstacles": move_obstacles, "move_under_fire": move_under_fire,
            "ambush": ambush, "crossing": crossing, "gunnery": gunnery, "return_fire": return_fire,
            "close_front": close_front}


def build(builder: str, variant: str, learner: str, seed: int) -> dict:
    rng = random.Random(seed)
    sc = BUILDERS[builder](rng, learner, variant)
    sc["seed"] = seed
    return sc
