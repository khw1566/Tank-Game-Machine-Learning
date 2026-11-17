# 커리큘럼 v4 — 결과 기반 보상과 상황 혼합

기존 커리큘럼은 "우회 지점 도착" 같은 행동 자체를 보상해서 습관(항상 우회)이 굳었다.
v4 는 결과(목표 달성·생존·피해 교환)만 보상하고, 같은 과제 안에서 시드마다 이기는 선택이 다른 변형을 섞는다.
계획 전체: 탱크 AI 커리큘럼 v4 계획 문서(프로젝트 스레드). 기존 v1 실행·체크포인트는 그대로 동작한다.

## 실행

```powershell
python train.py --godot ../../build/TankGame.exe --curriculum v4 --tank tiger1 --run cv4_20261117 --n-envs 6
python -m tests.check_curriculum_v4 --godot ../../build/TankGame.exe   # 모든 단계·변형 스모크 + 재현 해시
```

`--curriculum v4` 는 Godot 을 `--obs=situation` 으로 띄워 관측 뒤에 `SituationObs` 30개를 붙인다
(기존 v1 정책과 입력 크기가 달라 새 정책으로 시작한다).

## 구성

| 단계 | 부 | 변형(이기는 선택이 다름) | 목표 |
|---|---|---|---|
| m1_move_basic | 기동 | near / far / behind | 도착·정지 |
| m2_move_obstacles | 기동 | clear / wall / gates | 도착·정지 |
| m3_move_under_fire | 기동 | screened / open_cover / long_detour | 포화 속 도착 |
| m4_ambush | 기동 | near_cover / far_cover / reverse | 40초 생존 |
| m5_crossing | 기동 | steady / sloppy / woods | 횡단 도착 |
| g1_gunnery | 사격 | static / hidden | 명중 2회 |
| g2_gunnery_moving | 사격 | moving | 명중 2회 |
| g4_return_fire | 사격 | berm(헐다운) / open(앵글링) | 격파 |
| g6_close_front | 사격 | close / medium | 격파 |

3부 전술적 응용(T1~T6)과 4부 최종단계(규칙 AI 다수전 → 자기대전)는 다음 단계에서 추가한다.

## 규칙

- **보상**: 시간(-0.01/s), 목표 달성 +8, 생존 +6, 승리 +8, 격파당함 -8, 시간 초과 -3, 사격 결과(명중·관통·격파)와
  피격 피해(`victim_scale` 1.0). 엄폐물 도착·차체 각도에는 직접 보상이 없다.
- **보조 보상**: 목표까지 새로 줄인 거리 × 0.03 × `shaping_scale`. 현재 단계에서 진입 후 에피소드 수에 따라 1→0,
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
