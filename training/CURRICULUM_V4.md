# 커리큘럼 v4 — 결과 기반 보상과 상황 혼합

기존 커리큘럼은 "우회 지점 도착" 같은 행동 자체를 보상해서 습관(항상 우회)이 굳었다.
v4 는 결과(목표 달성·생존·피해 교환)만 보상하고, 같은 과제 안에서 시드마다 이기는 선택이 다른 변형을 섞는다.
계획 전체: 탱크 AI 커리큘럼 v4 계획 문서(프로젝트 스레드). 기존 v1 실행·체크포인트는 그대로 동작한다.

## 실행

1~2부와 3부 T1~T3 은 세 전차를 **한 모델(shared)** 로 학습하고, T3 를 마치면 공통 모델을 전차별로 복사해 T4~T6 을 따로 학습한다.

```powershell
# 공통 학습 → T3 완료 시 자동 분기, 전차별 300만 스텝씩 3바퀴 번갈아
python train.py --godot ../../build/TankGame.exe --curriculum v4 --tank shared --auto-branch --rotate-steps 3000000 --cycles 3 --run cv4_20261117_shared --n-envs 8
# 수동 분기: 다른 실행의 공통 모델에서 전차별 학습 시작
python train.py --godot ../../build/TankGame.exe --curriculum v4 --tank t34_76 --branch-from runs/cv4_20261117_shared --run cv4_t34
python -m tests.check_curriculum_v4 --godot ../../build/TankGame.exe   # 모든 단계·변형 스모크 + 재현 해시
```

`--curriculum v4` 는 Godot 을 `--obs=situation` 으로 띄워 관측 뒤에 `SituationObs` 30개를 붙인다
(기존 v1 정책과 입력 크기가 달라 새 정책으로 시작한다).

## 구성

단계 구성 4.1 — 9단계, 단계마다 원인 → 결과 하나, 승급 기준 80%(변형 × 전차 모두), 최대 판수 강제 승급 없음.
(4.0 의 15단계는 첫 학습에서 최대 판수로 강제 승급되며 성공률 25~30% 인 채로 넘어가 폐기했다.)

| 단계 | 부 | 원인 → 결과 | 변형 |
|---|---|---|---|
| m1_drive | 기동 | 조작 → 도착(멈춰야 도착) | near / far / behind |
| m2_route | 기동 | 장애물 → 경로(막히면 우회, 열리면 직진) | clear / wall / gates |
| m3_under_fire | 기동 | 노출 → 피격(시선 끊기·계속 움직이기) | screened / open_cover / crossing / ambush |
| g1_aim | 사격 | 조준 → 명중(거리 어림·리드) | static / hidden / moving |
| g2_posture | 사격 | 자세 → 받는 피해(헐다운·앵글링) | hull_down / angled / close |
| t1_numbers | 전술(공통) | 교전 상대 수 → 승패 | isolated_near / group_near |
| t2_cover_fight | 전술(공통) | 엄폐 사용 → 생존 | peek_fast / peek_slow / capture_inside / capture_overwatch |
| s1_role | 전술(전차별) | 전차 특성 → 역할 | defend / defend_flank / flank |
| s2_outnumbered | 전술(전차별) | 열세 → 후퇴 | pursuers / holders |

맞을 때마다(관통 여부와 무관) −0.5 (`hit_taken`). 게임 속도 설정(`tankrl/pace.py`)을 처음부터 적용한다.

공통 모델의 승급은 변형 × 전차 조합이 모두 기준을 넘어야 한다(한 전차만 잘해서는 통과하지 못함).
4부 최종단계(규칙 AI 다수전 → 자기대전)는 다음 단계에서 추가한다.

## 대시보드

- **커리큘럼 v4 지도**: 부별로 단계 카드, 카드 안에 변형 × 전차 칸(최근 40판 성공률, 기준 통과 시 진한 초록), 학습 중인 모델 배지.
- **모델 품질 표**: 행 = 모델(공통/전차별) × 스텝 구간, 열 = 단계·변형. 복습 판까지 집계하므로 단계 변경 뒤 이전 단계 성공률이
  떨어지는지(망각) 같은 열에서 보인다. ▶ 단계 변경, ⑂ 전차별 분기 표시.
- **곡선 묶기**: 변형 / 단계 / 부 / 변형 × 전차(전차는 선 모양으로 구분). 단계 변경선과 분기선(보라)에 이름표.
- **색상**: 부마다 색 계열(기동 파랑, 사격 주황, 공통 전술 초록, 전차별 전술 보라), 단계마다 색조, 변형마다 명암.

## 규칙

- **보상**: 시간(-0.01/s), 목표 달성 +8, 생존 +6, 승리 +8, 격파당함 -8, 시간 초과 -3, 사격 결과(명중·관통·격파)와
  피격 피해(`victim_scale` 1.0). 엄폐물 도착·차체 각도에는 직접 보상이 없다.
- **보조 보상**: 목표까지 새로 줄인 거리 × 0.03 × `shaping_scale`. 현재 단계에서는 실력에 따라 줄인다
  (1 − 가장 약한 변형 성공률/승급 기준). 실력보다 먼저 사라지지 않게 하되 `shaping_decay_episodes`×4 판이 지나면 0 으로 끝낸다.
  복습 단계에서는 0.
- **승급**: 변형마다 최근 40판 성공률이 모두 기준 이상(최소 에피소드 충족). 상한(`max_episodes`)에 닿으면 강제 승급하고
  `reason = max_episodes` 로 남긴다.
- **탐색 재개**: 단계 진입 시 `ent_coef` 를 `--entropy-boost`(0.02)로 올리고 `--entropy-steps`(30만) 동안 기본값까지 줄인다.
- **적 AI**: `hold`(제자리), `aim_noise_mrad`(발마다 다시 뽑는 조준 오차, 시드 고정), `fire_delay_s`(반응 시간),
  `max_fire_range`. 리드를 주지 않으므로 움직이는 표적에 약하다.
- **관측(SituationObs)**: 기억 중인 적의 어림 위치에서 본 노출(차체 / 포탑만), 최근 본 적 방향, 피격·근접 탄착,
  목표 방향·거리, 8방위 엄폐물(차체 높이 / 포탑 높이). 실제 적 위치 같은 정답 정보는 쓰지 않는다.

## 기록

- 에피소드 파일(설정·시드·행동)은 그대로이며 `config.scenario` 에 배치 전체가 들어 있어 재현된다.
- `result.scenario`: 변형, 목표 달성, 노출 시간(실제 적 시선 기준, 차체/포탑만 구분), 피격·관통 수, 이동 거리,
  보상 성분, 스폰 이동 기록.
- 실행 폴더 `scenario_progress.csv`: 위 값을 에피소드마다 한 줄. `curriculum_log.jsonl` 승급 기록에는 변형별 성공률.
