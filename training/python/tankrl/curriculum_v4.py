"""커리큘럼 v4: 결과 기반 보상 + 변형 혼합 + 변형별 승급 + 감쇠하는 보조 보상 + 단계 진입 시 탐색 재개.

기존 커리큘럼(curriculum.py)과 같은 인터페이스(stage, pick_stage, report, set_stage, state, save, load)를 갖고,
에피소드 설정은 build_episode() 가 직접 만든다. 계획 문서: training/CURRICULUM_V4.md

단계 구성 4.1(9단계, 단계마다 원인 → 결과 하나, 승급 기준 80%, 최대 판수 강제 승급 없음)
1부 기동    m1_drive → m2_route → m3_under_fire
2부 사격    g1_aim → g2_posture
3부 전술    공통: t1_numbers → t2_cover_fight  /  전차별: s1_role → s2_outnumbered
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
from .pace import GAME_PACE

VERSION = 4
OBS = "situation"            # Godot --obs=situation (SituationObs) 이 필요하다

# hit_taken: 맞을 때마다(관통 여부와 무관). 노출 → 피격 관계를 티거처럼 관통당하지 않는 전차도 분명히 겪게 한다
BASE_REWARD = {"time_per_s": -0.01, "progress": 0.03, "objective": 8.0, "survive": 6.0, "win": 8.0,
               "loss": -8.0, "timeout_penalty": -3.0, "hit_taken": -0.5,
               "combat": {"hit": 0.5, "penetration": 2.0, "knockout": 8.0, "miss": -0.05,
                          "victim_scale": 1.0, "live_target_only": True}}


def _map(size: float) -> dict:
    return {"features": False, "profile": "flat", "amplitude": 0.0, "size_m": size, "cell_m": 8.0,
            "ridge_count": 0, "seeds": [1]}


SHARED = "shared"
SHARED_TANKS = ["tiger1", "sherman75", "t34_76"]


STAGESET = "4.1"   # 4.0 = 15단계(강제 승급 있음), 4.1 = 9단계·기준 80%·강제 승급 없음
THRESHOLD = 0.8


def V(name, builder, bvariant, kind="combat", time_limit=90, ctrl="scripted"):
    """변형 하나 = 상황 생성기 + 그 생성기의 변형. 같은 단계 안에서 이기는 선택이 서로 다른 변형을 섞는다."""
    return {"name": name, "builder": builder, "variant": bvariant, "kind": kind, "time_limit_s": time_limit, "ctrl": ctrl}


def stage(sid, part, label, variants, size, lesson, learn, goal, scope="common", view_lock=-1, min_eps=300,
          decay=1500, threshold=THRESHOLD):
    return {"id": sid, "part": part, "scope": scope, "label": label, "lesson": lesson, "learn": learn, "goal": goal,
            "variants": [v["name"] for v in variants], "variant_specs": {v["name"]: v for v in variants},
            "variants_desc": {v["name"]: v.get("desc", "") for v in variants},
            "kind": variants[0]["kind"], "time_limit_s": max(v["time_limit_s"] for v in variants),
            "map": _map(size), "view_lock": view_lock, "lineup": "scenario", "reward": BASE_REWARD,
            # 승급은 기준 달성으로만(최대 판수 강제 승급 없음). 막히면 대시보드에 그대로 드러난다.
            "promote": {"window": 40, "threshold": threshold, "min_episodes": min_eps, "max_episodes": None},
            "shaping_decay_episodes": decay}


def D(v, desc):
    v["desc"] = desc
    return v


STAGES = [
    # ---------------------------------------------------------------- 1부 기동
    stage("m1_drive", "기동", "주행·정지", [
        D(V("near", "move_basic", "near", "drive", 60), "30~60m 앞 목표"),
        D(V("far", "move_basic", "far", "drive", 60), "80~150m 앞 목표"),
        D(V("behind", "move_basic", "behind", "drive", 60), "뒤쪽 목표: 제자리 선회 후 출발"),
    ], 600, lesson="조작 → 도착: 속도를 줄여 목표에서 멈춰야 도착으로 인정된다",
        learn="무한궤도·브레이크·변속으로 원하는 지점까지 가서 멈추기.", goal="반경 6m 목표 안에서 0.6초 정지(60초 제한).",
        min_eps=200, decay=800),
    stage("m2_route", "기동", "경로 선택", [
        D(V("clear", "move_obstacles", "clear", "drive", 90), "장애물이 길 옆에만: 직진이 정답"),
        D(V("wall", "move_obstacles", "wall", "drive", 90), "길을 막은 벽: 끝으로 돌아가야 함"),
        D(V("gates", "move_obstacles", "gates", "drive", 90), "엇갈린 통로 두 개"),
    ], 600, lesson="장애물 → 경로: 막혀 있으면 돌아가고, 열려 있으면 곧장 간다",
        learn="장애물을 보고 직진과 우회를 구분하기.", goal="90~140m 앞 목표 도착·정지(90초 제한)."),
    stage("m3_under_fire", "기동", "노출과 피격", [
        D(V("screened", "move_under_fire", "screened", "combat", 120), "벽이 경로를 가려 줌: 그대로 가면 안 맞는다"),
        D(V("open_cover", "move_under_fire", "open_cover", "combat", 120), "개활지 + 바위: 바위 뒤를 거치면 덜 맞는다"),
        D(V("crossing", "crossing", "steady", "combat", 90), "엄폐 없음: 멈추지 않고 움직이면 덜 맞는다"),
        D(V("ambush", "ambush", "reverse", "combat", 40), "기습: 뒤쪽 벽 뒤로 빠져 시선을 끊으면 산다(40초 생존)"),
    ], 2400, lesson="노출 → 피격: 적 시선 안에 서 있으면 맞고, 시선을 끊거나 움직이면 덜 맞는다",
        learn="적이 쏘는 가운데 이동·생존. 맞으면(관통되지 않아도) 감점.",
        goal="격파되지 않고 목표 도착 또는 40초 생존. 3발(횡단 4발) 넘게 맞으면 목표를 이뤄도 실패."),
    # ---------------------------------------------------------------- 2부 사격
    stage("g1_aim", "사격", "조준 사격", [
        D(V("static", "gunnery", "static", "gunnery", 45, "static"), "150~700m 정지 표적"),
        D(V("hidden", "gunnery", "hidden", "gunnery", 45, "static"), "숲 가장자리에 반쯤 숨은 표적"),
        D(V("moving", "gunnery", "moving", "gunnery", 60, "mover"), "움직이는 표적: 앞을 겨누어야 맞는다"),
    ], 1800, lesson="조준 → 명중: 거리를 어림하고(이동 표적은 앞을 겨누어) 쏴야 맞는다",
        learn="포수 조준경으로 거리 어림·조준·리드. 반격 없음.", goal="제한 시간 안에 명중 2회.", view_lock=1),
    stage("g2_posture", "사격", "교전 자세", [
        D(V("hull_down", "return_fire", "berm", "combat", 90), "앞에 차체 높이 둔덕: 차체를 숨기고 포탑만 내밀면 덜 맞는다"),
        D(V("angled", "return_fire", "open", "combat", 90), "엄폐 없음(400m 안팎): 차체를 비스듬히 두면 도탄된다"),
        D(V("close", "close_front", "close", "combat", 60), "120~260m 정면: 먼저 쏘고 각도로 버틴다"),
    ], 1800, lesson="자세 → 받는 피해: 헐다운이면 차체가 안 맞고, 비스듬하면 도탄된다",
        learn="되쏘는 적과 1대1. 헐다운·앵글링(티타임)·선제 사격.", goal="적 격파. 준 피해와 받은 피해(피격 포함)가 보상에 반영."),
    # ---------------------------------------------------------------- 3부 전술(공통)
    stage("t1_numbers", "전술", "수적 우위 만들기", [
        D(V("isolated_near", "pick_fights", "isolated_near", "combat", 180), "고립된 적이 가까움: 그쪽부터"),
        D(V("group_near", "pick_fights", "group_near", "combat", 180), "묶음이 가까움: 벽을 돌아 고립된 적부터"),
    ], 2000, lesson="교전 상대 수 → 승패: 한 번에 한 대씩 상대하면 이긴다",
        learn="적 3대 중 고립된 1대를 먼저 잡고, 묶인 2대와 동시에 싸우지 않기.", goal="적 3대 격파(180초 제한).",
        min_eps=400),
    stage("t2_cover_fight", "전술", "엄폐를 쓰는 교전", [
        D(V("peek_fast", "peek", "same_spot", "combat", 120), "적 반응 빠름: 같은 자리로 다시 나가면 맞는다(자리 바꾸기)"),
        D(V("peek_slow", "peek", "slow_enemy", "combat", 120), "적 반응 느림: 빨리 쏘고 숨기"),
        D(V("capture_inside", "capture", "inside", "combat", 150), "구역 안 적: 먼저 치우고 점유"),
        D(V("capture_overwatch", "capture", "overwatch", "combat", 150), "멀리서 감시: 구역 안 엄폐로 시선 끊고 버티기"),
    ], 1800, lesson="엄폐 사용 → 생존: 쏠 때만 노출하고, 노출 위치를 바꾸면 덜 맞는다",
        learn="엄폐 뒤에서 내다보고 쏘기, 위치 바꾸기, 엄폐를 끼고 구역 점유.", goal="적 격파 또는 구역 25초 점유(구역 점유는 5발 넘게 맞으면 실패).",
        min_eps=400),
    # ---------------------------------------------------------------- 3부 전술(전차별)
    stage("s1_role", "전술", "전차 역할(전차별)", [
        D(V("defend", "defend", "frontal", "combat", 150), "티거: 접근하는 3~4대 격파 / 연합군: 티거 상대로 120초 생존"),
        D(V("defend_flank", "defend", "flanking", "combat", 150), "일부가 측면으로 돌아오는 방어"),
        D(V("flank", "flank", "open", "combat", 150), "티거: 좌우 협공 대응 / 연합군: 티거 측면 공략"),
    ], 2400, lesson="전차 특성 → 역할: 티거는 버티며 정면으로, 셔먼·T-34는 측면으로",
        learn="전차마다 다른 방어·측면 과제.", goal="변형별 목표(격파 또는 생존).", scope="tank", min_eps=400),
    stage("s2_outnumbered", "전술", "열세 대응(전차별)", [
        D(V("pursuers", "retreat", "pursuers", "combat", 90), "적이 추격: 엄폐 뒤에서 하나씩 상대"),
        D(V("holders", "retreat", "holders", "combat", 90), "적이 제자리: 시야를 끊고 버티기"),
    ], 2000, lesson="열세 → 후퇴: 시선을 끊으면 살고, 추격해 온 적은 하나씩 잡는다",
        learn="수적으로 불리할 때 물러나 시선을 끊고 버티기.", goal="90초 생존, 6발 넘게 맞으면 실패(티거 1:5, 셔먼·T-34 1:3).",
        scope="tank", min_eps=400),
]
STAGE_IDS = [s["id"] for s in STAGES]

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
        spec = st["variant_specs"][variant]
        sc = scenarios.build(spec["builder"], spec["variant"], learner, seed)
        sc["variant"] = variant
        sc["source"] = {"builder": spec["builder"], "variant": spec["variant"]}
        team = scenarios.TEAM_OF[learner]
        lu = [{"type": learner, "team": team, "ctrl": "external", "role": "learner"}]
        for _ in sc["enemies"]:
            t = rng.choice(scenarios.ENEMIES_OF[learner])
            lu.append({"type": t, "team": 1 - team, "ctrl": spec["ctrl"], "role": spec["ctrl"]})
        reward = json.loads(json.dumps(st["reward"]))
        reward["shaping_scale"] = self.shaping_scale(st["id"])
        extra = {"scenario": sc, "reward": reward, "kind": spec["kind"],
                 "time_limit_s": sc.get("survive_s", spec["time_limit_s"]), "stageset": STAGESET,
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
        if not passed and (p.get("max_episodes") is None or self.episodes_in_stage < p["max_episodes"]):
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
        return {"curriculum_version": VERSION, "stageset": STAGESET, "tank": self.tank, "tanks": self.tanks, "common_complete": self.common_complete,
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
        if st.get("stageset", "4.0") != STAGESET:
            raise ValueError(f"단계 구성이 다릅니다({st.get('stageset', '4.0')} → {STAGESET}). 새 실행 이름으로 시작하세요: {path}")
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
            "curriculum_version": VERSION, "stageset": extra.get("stageset", STAGESET), "pace": dict(GAME_PACE)}
