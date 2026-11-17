"""커리큘럼 v4: 결과 기반 보상 + 변형 혼합 + 변형별 승급 + 감쇠하는 보조 보상 + 단계 진입 시 탐색 재개.

기존 커리큘럼(curriculum.py)과 같은 인터페이스(stage, pick_stage, report, set_stage, state, save, load)를 갖고,
에피소드 설정은 build_episode() 가 직접 만든다. 계획 문서: training/CURRICULUM_V4.md

1부 기동    m1_move_basic → m2_move_obstacles → m3_move_under_fire → m4_ambush → m5_crossing
2부 사격    g1_gunnery → g2_gunnery_moving → g4_return_fire → g6_close_front
3부 전술    공통: t1_pick_fights → t2_peek → t3_capture  /  전차별: t4_defend → t5_flank → t6_retreat
(4부 최종단계는 다음 단계에서 추가한다)

공통 학습(tank = "shared"): 티거·셔먼·T-34 를 한 모델로 학습한다(관측에 내 전차 종류가 있다). 에피소드마다 전차 종류를
고르고, 승급은 변형 × 전차 조합이 모두 기준을 넘어야 한다. scope="common" 단계(t3 까지)를 마치면 common_complete 가
되고, train.py 가 공통 모델을 전차별 실행으로 복사해(branch) scope="tank" 단계(t4~)를 전차마다 따로 학습한다.
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


SHARED = "shared"
SHARED_TANKS = ["tiger1", "sherman75", "t34_76"]


def stage(sid, part, label, builder, variants, kind, time_limit, size, threshold, enemy_ctrl="scripted",
          min_eps=300, max_eps=8000, view_lock=-1, decay=1500, scope="common"):
    return {"id": sid, "part": part, "scope": scope, "label": label, "builder": builder, "variants": variants, "kind": kind,
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
    stage("t1_pick_fights", "전술", "유리한 교전 고르기(고립된 적부터)", "pick_fights", ["isolated_near", "group_near"],
          "combat", 180, 2000, .45, min_eps=400, max_eps=12000),
    stage("t2_peek", "전술", "사격 후 재배치", "peek", ["same_spot", "slow_enemy"], "combat", 120, 1800, .45, min_eps=400),
    stage("t3_capture", "전술", "거점 확보", "capture", ["inside", "overwatch"], "combat", 150, 1600, .45, min_eps=400,
          max_eps=12000),
    stage("t4_defend", "전술", "거점 방어(전차별)", "defend", ["frontal", "flanking"], "combat", 120, 2400, .45,
          min_eps=400, max_eps=12000, scope="tank"),
    stage("t5_flank", "전술", "측면 기동/측면 대응(전차별)", "flank", ["open", "screened"], "combat", 150, 1800, .45,
          min_eps=400, max_eps=12000, scope="tank"),
    stage("t6_retreat", "전술", "열세 시 후퇴·반격(전차별)", "retreat", ["pursuers", "holders"], "combat", 90, 2000, .45,
          min_eps=400, max_eps=12000, scope="tank"),
]
STAGE_IDS = [s["id"] for s in STAGES]

# 대시보드 툴팁: 무엇을 배우는지(learn), 무엇을 하면 성공인지(goal), 변형별로 어떤 선택이 유리한지(variants)
DESCRIPTIONS = {
    "m1_move_basic": dict(
        learn="전차를 원하는 지점까지 몰고 가서 멈추는 기본 조작(무한궤도 좌우, 브레이크, 변속).",
        goal="반경 6m 목표 지점에 들어가 0.6초 정지. 60초 제한.",
        variants_desc={"near": "30~60m 앞", "far": "80~150m 앞", "behind": "뒤쪽 목표: 제자리 선회 후 출발"}),
    "m2_move_obstacles": dict(
        learn="장애물이 있는 지형에서 경로를 고르는 법. 직진이 맞는 곳과 돌아가야 하는 곳을 구분한다.",
        goal="90~140m 앞 목표 지점 도착·정지. 90초 제한.",
        variants_desc={"clear": "장애물이 길 옆에만 있음(직진이 정답)", "wall": "길을 막은 벽: 한쪽 끝으로 우회",
                  "gates": "엇갈린 통로 두 개를 차례로 통과"}),
    "m3_move_under_fire": dict(
        learn="멀리 있는 부정확한 적 2~4대가 쏘는 가운데 옆으로 이동. 엄폐를 쓸지, 빠르게 돌파할지 판단한다.",
        goal="격파되지 않고 목표 지점 도착. 받은 피해만큼 감점. 120초 제한.",
        variants_desc={"screened": "경로를 벽이 가려 줌: 그대로 가면 안전", "open_cover": "개활지에 바위 몇 개: 엄폐 경유 또는 빠른 돌파",
                  "long_detour": "엄폐는 멀고 적은 매우 부정확: 돌아가면 손해"}),
    "m4_ambush": dict(
        learn="기습 사격을 받았을 때 시선을 끊을 곳으로 빠지는 법(앞으로, 옆으로, 뒤로).",
        goal="40초 동안 전투 가능 상태 유지. 받은 피해만큼 감점.",
        variants_desc={"near_cover": "가까운 바위 뒤", "far_cover": "옆쪽 먼 바위", "reverse": "뒤쪽 벽 뒤로 후진"}),
    "m5_crossing": dict(
        learn="엄폐 없는 개활지를 적 사선을 가로질러 통과. 적은 이동 표적에 리드를 주지 않으므로 멈추지 않는 것이 유리하다.",
        goal="150~220m 횡단 후 목표 지점 도착. 90초 제한.",
        variants_desc={"steady": "적 조준이 비교적 정확", "sloppy": "적 조준이 거침", "woods": "경로 근처 숲을 은폐로 이용 가능"}),
    "g1_gunnery": dict(
        learn="포수 조준경으로 거리를 어림하고 조준해 맞히는 법. 반격 없음.",
        goal="45초 안에 명중 2회.",
        variants_desc={"static": "150~700m 정지 표적", "hidden": "숲 가장자리에 반쯤 숨은 표적"}),
    "g2_gunnery_moving": dict(
        learn="움직이는 표적에 앞을 겨누어(리드) 맞히는 법.",
        goal="60초 안에 명중 2회.",
        variants_desc={"moving": "무작위로 움직이는 표적"}),
    "g4_return_fire": dict(
        learn="되쏘는 적과의 1대1. 차체를 둔덕 뒤에 숨기는 헐다운, 엄폐가 없을 때는 차체 각도(앵글링)로 피해를 줄인다.",
        goal="적 격파. 준 피해와 받은 피해가 보상에 반영. 90초 제한.",
        variants_desc={"berm": "바로 앞에 차체 높이 둔덕(헐다운 가능)", "open": "엄폐 없음(앵글링·선제 사격)"}),
    "g6_close_front": dict(
        learn="근거리 정면 대결. 차체를 비스듬히 두어 도탄을 유도하는 티타임과 먼저 쏘기.",
        goal="적 격파. 60초 제한.",
        variants_desc={"close": "120~260m", "medium": "260~400m"}),
    "t1_pick_fights": dict(
        learn="적이 적은 쪽부터 싸우기. 고립된 1대를 먼저 잡고 묶여 있는 2대는 나중에 상대한다.",
        goal="적 3대 모두 격파. 180초 제한.",
        variants_desc={"isolated_near": "고립된 적이 가까움", "group_near": "묶음이 가까움: 벽을 돌아 고립된 적부터"}),
    "t2_peek": dict(
        learn="엄폐 뒤에서 내다보고 쏜 뒤 숨기, 같은 자리로 다시 나가지 않고 위치를 바꾸기.",
        goal="적 격파. 120초 제한.",
        variants_desc={"same_spot": "적 반응이 빨라 같은 자리 재노출이 위험", "slow_enemy": "적 반응이 느려 빠르게 쏘고 숨기가 통함"}),
    "t3_capture": dict(
        learn="목표 구역에 들어가 버티기. 구역 안 적을 먼저 치울지, 엄폐로 감시 시선을 끊을지 판단한다.",
        goal="반경 35m 구역 안에 누적 25초. 150초 제한.",
        variants_desc={"inside": "적이 구역 안 엄폐에 있음", "overwatch": "적이 멀리서 구역을 감시"}),
    "t4_defend": dict(
        learn="거점 방어(전차별). 티거는 둔덕 뒤에서 장거리로 하나씩, 셔먼과 T-34는 티거의 접근을 버틴다.",
        goal="티거: 접근하는 3~4대 모두 격파. 셔먼·T-34: 티거 상대로 120초 생존.",
        variants_desc={"frontal": "정면 접근", "flanking": "일부가 측면으로 돌아옴"}),
    "t5_flank": dict(
        learn="측면(전차별). 셔먼과 T-34는 정면이 단단한 티거의 옆을 잡고, 티거는 좌우 협공에 차체 정면을 돌려 대응한다.",
        goal="적 격파. 150초 제한.",
        variants_desc={"open": "측면 경로에 바위 엄폐", "screened": "숲 뒤로 돌아가는 경로(연합군)"}),
    "t6_retreat": dict(
        learn="열세일 때 물러나 시야를 끊고, 쫓아오는 적을 엄폐 뒤에서 하나씩 상대한다.",
        goal="90초 생존(격파는 추가 보상). 티거 1:5, 셔먼·T-34 1:3.",
        variants_desc={"pursuers": "적이 추격해 옴", "holders": "적이 제자리에서 사격"}),
}
for _st in STAGES:
    _st.update(DESCRIPTIONS.get(_st["id"], {}))

LAST_COMMON = max(i for i, s in enumerate(STAGES) if s["scope"] == "common")
FIRST_TANK = LAST_COMMON + 1


class CurriculumV4:
    version = VERSION
    obs = OBS
    stages = STAGES
    stage_ids = STAGE_IDS
    dashboard_offset = len(_v1.STAGE_IDS)   # 대시보드는 v1 10단계 뒤에 v4 단계를 이어 표시한다

    def __init__(self, tank: str, start_stage: int = 0, review_prob: float = 0.1, seed: int = 0,
                 entropy_boost: float = 0.02, entropy_steps: int = 300_000):
        self.tank = tank
        self.tanks = list(SHARED_TANKS) if tank == SHARED else [tank]
        self.common_complete = False
        self.branched_from = ""
        self.stage_idx = start_stage
        self.review_prob = review_prob
        self.rng = random.Random(seed)
        self.episodes_in_stage = 0
        self.stage_start_step = 0
        self.entropy_boost = entropy_boost
        self.entropy_steps = entropy_steps
        self.history: list[dict] = []
        self.results = {s["id"]: {self.key(v, t): collections.deque(maxlen=200) for v in s["variants"] for t in self.tanks}
                        for s in STAGES}
        self.terrain_fixed = ""      # 기존 인터페이스 호환(사용 안 함)

    @staticmethod
    def key(variant: str, tank: str) -> str:
        return f"{variant}@{tank}"

    @property
    def last_stage(self) -> int:
        return LAST_COMMON if self.tank == SHARED else len(STAGES) - 1

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
        # 공통 모델은 전차 수만큼 판이 나뉘므로 상한도 그만큼 늘린다
        cap = max(0.0, 1.0 - self.episodes_in_stage / max(1, 4 * len(self.tanks) * self.stage["shaping_decay_episodes"]))
        return round(min(skill, cap), 4)

    def entropy_coef(self, base: float, step: int) -> float:
        """단계 진입 직후 탐색 계수를 올렸다가 entropy_steps 동안 선형으로 기본값까지 줄인다."""
        frac = max(0.0, 1.0 - (step - self.stage_start_step) / max(1, self.entropy_steps))
        return base + (max(base, self.entropy_boost) - base) * frac

    def build_episode(self, learner: str, rng: random.Random, seed: int) -> tuple[dict, list[dict], dict]:
        st = self.pick_stage()
        if learner == SHARED or learner not in scenarios.TEAM_OF:
            learner = rng.choice(self.tanks)
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
                 "curriculum_version": VERSION, "learner": learner, "model": self.tank}
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

    def report(self, stage_id: str, success: bool, global_step: int, course: str = "", variant: str = "",
               learner: str = "") -> dict | None:
        if stage_id not in self.results:
            return None
        k = self.key(variant, learner or self.tanks[0])
        if k in self.results[stage_id]:
            self.results[stage_id][k].append(int(success))
        if stage_id != self.stage["id"]:
            return None
        self.episodes_in_stage += 1
        p = self.stage["promote"]
        if self.stage_idx >= self.last_stage:
            if self.tank == SHARED and not self.common_complete:
                return self._complete_common(global_step, p)
            return None
        window = p["window"]
        enough = self.episodes_in_stage >= p["min_episodes"] and all(len(d) >= window for d in self.results[stage_id].values())
        rates = self.variant_rates(stage_id, window)
        rate = min(rates.values())
        forced = p.get("max_episodes") is not None and self.episodes_in_stage >= p["max_episodes"]
        if (enough and rate >= p["threshold"]) or forced:
            return self._advance(self.stage_idx + 1, global_step, "threshold" if enough and rate >= p["threshold"] else "max_episodes", rates)
        return None

    def _complete_common(self, global_step: int, p: dict) -> dict | None:
        """공통 단계 끝(t3): 기준을 넘거나 상한에 닿으면 전차별 분기 준비 완료."""
        sid = self.stage["id"]
        window = p["window"]
        enough = self.episodes_in_stage >= p["min_episodes"] and all(len(d) >= window for d in self.results[sid].values())
        rates = self.variant_rates(sid, window)
        passed = enough and min(rates.values()) >= p["threshold"]
        if not passed and self.episodes_in_stage < p["max_episodes"]:
            return None
        self.common_complete = True
        ev = {"tank": self.tank, "from": sid, "to": "branch_tanks", "episodes": self.episodes_in_stage,
              "success_rate": round(min(rates.values()), 4), "variant_rates": {k: round(v, 4) for k, v in rates.items()},
              "reason": "threshold" if passed else "max_episodes", "global_step": global_step,
              "curriculum_version": VERSION}
        self.history.append(ev)
        return ev

    def branch(self, tank: str, global_step: int, source: str) -> "CurriculumV4":
        """공통 진행 기록을 이어받은 전차별 커리큘럼(첫 전차별 단계부터)."""
        c = CurriculumV4(tank, start_stage=FIRST_TANK, review_prob=self.review_prob, entropy_boost=self.entropy_boost,
                         entropy_steps=self.entropy_steps)
        c.stage_start_step = global_step
        c.branched_from = source
        c.history = [dict(h) for h in self.history] + [{"tank": tank, "from": self.stage["id"], "to": STAGES[FIRST_TANK]["id"],
                                                         "reason": "branch", "source": source, "global_step": global_step,
                                                         "episodes": self.episodes_in_stage, "success_rate": 0.0,
                                                         "curriculum_version": VERSION}]
        for sid, vs in self.results.items():
            for k, d in vs.items():
                if k in c.results[sid]:
                    c.results[sid][k].extend(d)
        return c

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
        if idx > self.last_stage:
            raise ValueError("공통 모델은 전차별 단계로 갈 수 없습니다. 전차별 분기 후 진행하세요.")
        if idx == self.stage_idx:
            return None
        return self._advance(idx, global_step, "manual", self.variant_rates(self.stage["id"], 40))

    def state(self) -> dict:
        return {"curriculum_version": VERSION, "tank": self.tank, "tanks": self.tanks, "common_complete": self.common_complete,
                "branched_from": self.branched_from, "stage_idx": self.stage_idx, "stage": self.stage["id"],
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
        c.common_complete = bool(st.get("common_complete", False))
        c.branched_from = st.get("branched_from", "")
        for sid, vs in st.get("results", {}).items():
            for v, values in vs.items():
                k = v if "@" in v else c.key(v, c.tanks[0])   # 초기 v4 저장본(변형만 기록)
                if sid in c.results and k in c.results[sid]:
                    c.results[sid][k].extend(values)
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
