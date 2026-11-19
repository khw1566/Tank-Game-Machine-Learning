"""커리큘럼 버전 이력(대시보드 표시용). 학습 동작에는 쓰이지 않는다.

커리큘럼은 정석(v1) → 결과 기반·회피/엄폐(v4) → 전투 자기 대전(v5) → 최종 1대6(v6) 순으로 바뀌었다.
대시보드는 이 목록으로 버전별 단계·바뀐 점·바꾼 이유를 보여 주고, 실행 폴더가 어느 버전인지 분류한다.
새 커리큘럼을 추가하면 VERSIONS 끝에 한 항목을 붙이고 classify_run() 에 구분 규칙을 넣는다.
"""
from __future__ import annotations

import json
from pathlib import Path

from . import battle_curriculum, curriculum as v1, curriculum_v4, final_curriculum

V1_LABELS = {
    "drive": "주행", "drive_terrain": "지형 주행", "gunnery_static": "정지 표적 사격", "gunnery_moving": "이동 표적 사격",
    "gunnery_search": "수색·사격", "duel_scripted": "1대1 vs 규칙 AI", "duel_selfplay": "1대1 자기대전",
    "team_scripted": "팀전 vs 규칙 AI", "team_selfplay": "팀 자기대전", "final_battle": "최종전 1 대 6",
}
V1_PARTS = {"drive": "기동", "drive_terrain": "기동", "gunnery_static": "사격", "gunnery_moving": "사격",
            "gunnery_search": "사격", "duel_scripted": "교전", "duel_selfplay": "교전", "team_scripted": "팀전",
            "team_selfplay": "팀전", "final_battle": "최종"}

# v4.0(15단계)은 코드에서 사라졌다(4.1 로 압축). 기록 표시용으로 이름만 남긴다.
V4_0_STAGES = [
    ("m1_move_basic", "기동", "기본 주행·정지"), ("m2_move_obstacles", "기동", "장애물 지대 통과"),
    ("m3_move_under_fire", "기동", "포화 속 이동"), ("m4_ambush", "기동", "기습 대응·생존"),
    ("m5_crossing", "기동", "개활지 횡단"), ("g1_gunnery", "사격", "정지 표적·은폐 표적"),
    ("g2_gunnery_moving", "사격", "이동 표적"), ("g4_return_fire", "사격", "반격하는 적과 대결"),
    ("g6_close_front", "사격", "근거리 정면(앵글링)"), ("t1_pick_fights", "전술", "유리한 교전 고르기"),
    ("t2_peek", "전술", "사격 후 재배치"), ("t3_capture", "전술", "거점 확보"),
    ("t4_defend", "전술", "거점 방어(전차별)"), ("t5_flank", "전술", "측면 기동(전차별)"),
    ("t6_retreat", "전술", "열세 시 후퇴·반격(전차별)"),
]


def _stage(sid, part, label, scope="common", goal=""):
    return {"id": sid, "part": part, "label": label, "scope": scope, "goal": goal}


def _live(stages) -> list[dict]:
    return [_stage(s["id"], s.get("part", ""), s.get("label", s["id"]), s.get("scope", "common"), s.get("goal", ""))
            for s in stages]


def versions() -> list[dict]:
    """오래된 것 → 최신 순. key 는 실행 분류(classify_run)와 같은 값."""
    v4_live = _live(curriculum_v4.STAGES)
    v4_1 = [s for s in v4_live if s["id"] != "m3a_find_cover"]
    return [
        {"key": "v1", "family": "v1", "name": "v1 정석", "tag": "정석", "date": "2026-11-16", "color": "#6b7b2a",
         "focus": "주행 → 지형 → 사격 → 1대1 → 팀전 → 최종전, 쉬운 과제부터 차례로",
         "model": "전차 종류별 모델(티거·셔먼·T-34)", "obs": "기본 관측 389개",
         "stages": [_stage(s["id"], V1_PARTS[s["id"]], V1_LABELS[s["id"]]) for s in v1.STAGES],
         "changes": ["10단계 커리큘럼, 성공률이 기준을 넘으면 자동 승급", "10% 확률로 이전 단계 복습",
                     "지형 주행은 13개 적응 코스(지형주행 v3)", "10단계 최종전은 7개체 독립 모델(IPPO, 360m 소형 전장)"],
         "why_next": "'우회 지점 도착'처럼 행동 자체를 보상해서 습관(항상 우회)이 굳었다 → 결과만 보상하는 v4 로",
         "docs": ["README.md", "TERRAIN_V3.md", "FINAL_BATTLE.md", "COMBAT_REWARDS.md"],
         "start_mode": "single", "curriculum_arg": "v1", "status": "보관"},
        {"key": "v4.0", "family": "v4", "name": "v4.0 결과 기반", "tag": "회피·생존", "date": "2026-11-17", "color": "#8e5bd0",
         "focus": "결과(도착·생존·피해 교환)만 보상, 같은 과제 안에 이기는 선택이 다른 변형을 섞음",
         "model": "세 전차 공통 모델 → 전술 후반부터 전차별 분기", "obs": "상황 관측 419개",
         "stages": [_stage(i, p, l, "tank" if "전차별" in l else "common") for i, p, l in V4_0_STAGES],
         "changes": ["기동 5 · 사격 4 · 전술 6 = 15단계", "포화 속 이동·기습 대응·개활지 횡단 등 회피·생존 과제 비중이 큼",
                     "변형 × 전차 조합이 모두 기준을 넘어야 승급, 최대 판수 도달 시 강제 승급"],
         "why_next": "단계가 너무 많고 강제 승급으로 못 익힌 채 넘어감 → 9단계·기준 80%·강제 승급 없음(4.1)",
         "docs": ["CURRICULUM_V4.md"], "start_mode": None, "status": "종료(새로 시작 불가)"},
        {"key": "v4.1", "family": "v4", "name": "v4.1 압축 9단계", "tag": "회피·생존", "date": "2026-11-17", "color": "#8e5bd0",
         "focus": "단계마다 원인 → 결과 하나, 승급 기준 80%, 강제 승급 없음",
         "model": "세 전차 공통 모델 → 전차별 분기(s1·s2)", "obs": "상황 관측 419개",
         "stages": v4_1,
         "changes": ["15단계 → 9단계로 압축", "최대 판수 강제 승급 제거", "보조 보상 감쇠를 판수가 아닌 실력에 연동"],
         "why_next": "V4RUN-2 가 '노출과 피격'에서 1억 스텝까지 성공 0%, 행동 잡음이 커져 제자리 원 그리기 → 잡음 상한 + '엄폐 찾기' 중간 단계(V4RUN-3)",
         "docs": ["CURRICULUM_V4.md"], "start_mode": "shared", "curriculum_arg": "v4", "status": "보관"},
        {"key": "v4.1-cover", "family": "v4", "name": "v4.1 + 회피·엄폐", "tag": "회피 위주", "date": "2026-11-18", "color": "#8e5bd0",
         "focus": "적 사격 인지 → 회피 이동 → 실제 엄폐로 사선 차단",
         "model": "세 전차 공통 모델 → 전차별 분기", "obs": "situation_v3 437개(발사음·섬광·비행 탄 단서 +18)",
         "stages": v4_live,
         "changes": ["'엄폐 찾기'(m3a) 단계 추가: 적이 쏘지 않는 상태에서 벽 뒤로", "'노출과 피격'을 날아오는 탄을 실제로 피할 수 있게 변경",
                     "발사음·섬광·근접 탄·비행 탄 관측 18개 추가(평가 버전 4)", "주행 꼼수 수정, 탐색 잡음 상한"],
         "why_next": "기동·사격 단독 과제를 차례로 통과한 뒤에야 실전에 들어가는 구조 대신, 첫 판부터 실탄으로 싸우는 별도 커리큘럼(v5)으로",
         "docs": ["UNDER_FIRE_V1.md", "CURRICULUM_V4.md"], "start_mode": "shared", "curriculum_arg": "v4", "status": "보관"},
        {"key": "v5", "family": "v5", "name": "v5 전투 자기 대전", "tag": "전투 위주", "date": "2026-11-18", "color": "#d9534f",
         "focus": "단독 과제 없이 첫 판부터 실탄 1대1 자기 대전, 평지 → 지형 → 전차별",
         "model": "공통 모델 → battle_roles 에서 전차별 분화", "obs": "battle 605개(부위 관측 168개 추가)",
         "stages": _live(battle_curriculum.STAGES),
         "changes": ["승급은 승률이 아니라 명중·관통·교전 완료 지표", "상대 = 고정 스냅숏(최신 70%·과거 30%)",
                     "balance v2: 셔먼 76mm·T-34-85·티거 포방패 200mm", "보상 v3 + 공격·조준 보상(지근탄·조준점·조준 후 발포)"],
         "why_next": "V5run 1 에서 사격은 충분히 익혔지만 1대1이라 엄폐 없이 정지한 채 장거리에서 먼저 맞히는 양상으로 굳음 → 여러 적을 동시에(v6)",
         "docs": ["BATTLE_SELFPLAY.md", "BATTLE_BALANCE_V2.md", "ATTACK_SHAPING.md"],
         "start_mode": "battle", "curriculum_arg": "battle", "status": "보관 · 최종 학습의 시작 모델"},
        {"key": "v6", "family": "v6", "name": "v6 최종 1대6", "tag": "엄폐 전투", "date": "2026-11-19", "color": "#2a6fdb",
         "focus": "티거 1 vs 셔먼 3 + T-34 3, 굴곡·장애물 맵 5종, 랜덤 스폰으로 엄폐를 융통성 있게",
         "model": "전차 종류별 3개(V5 공통 모델에서 시작)", "obs": "battle 605개",
         "stages": _live(final_curriculum.STAGES),
         "changes": ["맵 5종: 구릉과 숲·중앙 능선·마을·계곡·바위 지대(600m)", "진입 방향·거리·흩어짐·차체 방향을 매 판 무작위",
                     "엄폐 보상(노출 감점, 가린 채 관측) + 생존 승리 보너스, 접근 보조는 절반", "제한 시간 240초"],
         "why_next": "", "docs": ["FINAL_1V6.md", "ATTACK_SHAPING.md"],
         "start_mode": "final", "curriculum_arg": "final", "status": "현재"},
    ]


# 실행 key → run.json 의 curriculum_version
VERSION_NUMBER = {"v1": 1, "v4.0": 4, "v4.1": 4, "v4.1-cover": 4, "v5": 5, "v6": 6}
# 학습 시작 인자(--curriculum) → 지금 코드가 만드는 버전 key
ARG_KEY = {"v1": "v1", "v4": "v4.1-cover", "battle": "v5", "final": "v6"}


def _read(p: Path) -> dict:
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def classify_run(run_dir: Path) -> str:
    """실행 폴더 → 버전 key. 모르면 빈 문자열."""
    rj = _read(run_dir / "run.json")
    version = rj.get("curriculum_version")
    if version is None:
        st = _read(run_dir / "status.json")
        if st.get("cv"):
            return st["cv"]            # 대시보드가 시작하며 적어 둔 값(run.json 이 생기기 전)
        mode = st.get("mode")
        if mode == "evaluation":
            return "eval"
        if mode == "independent" or (run_dir / "independent_run.json").exists():
            return "v1"
        if not rj:
            return ""
        version = 1
    if version == final_curriculum.VERSION:
        return "v6"
    if version == battle_curriculum.VERSION:
        return "v5"
    if version == curriculum_v4.VERSION:
        cur = {}
        for name in [curriculum_v4.SHARED] + curriculum_v4.SHARED_TANKS:
            cur = _read(run_dir / name / "curriculum.json")
            if cur:
                break
        if not cur:
            return "v4.1-cover"           # 아직 저장 전: 지금 코드 = 최신 v4
        if cur.get("stageset", "4.0") == "4.0":
            return "v4.0"
        return "v4.1-cover" if int(cur.get("assessment_version", 1)) >= 4 else "v4.1"
    return "v1"
