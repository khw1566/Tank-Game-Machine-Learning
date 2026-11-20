# 실제 전투 시범과 행동 복제

연합군의 기동 전술(우회·측면·헐다운)을 사람이 직접 보여 주고, 그 조작을 V6 전차별 모델에 행동 복제한 뒤 PPO 로 이어 학습한다.

V7 시범 수집(링 태그 연습)과 다른 점:

| | V7 시범 수집 | 실제 전투 시범 |
|---|---|---|
| 게임 | 포탄 없는 링 태그 연습 | V6 전투 그대로(실제 포탄·관통·피해, 티거 상대) |
| 시작 시점 | 3인칭 | **포수 조준경** |
| 조준 | 카메라 중앙 조준점 | 같은 카메라 중앙 조준점(V7 에서 그대로 가져옴) |
| 관측 / 행동 | 78개 / 9개 | **V6 학습과 같은 관측(762개) / 행동 11개** |
| 쓰는 곳 | V7 링 모델 | **V6 전차별 모델**(train.py --curriculum v6 실행) |

## 1. 시범 수집

```powershell
.\training\Play_Combat_Demo.bat --tank sherman75 --stage v6_1v2 --run "V6run 1"
```

- `--tank` 셔먼 `sherman75` 또는 T-34 `t34_76` (티거 `tiger1` 도 가능)
- `--stage` `v6_1v1` / `v6_1v2` / `v6_1v3` / `v6_1v6` — 맵·배치·제한 시간·규칙 AI 아군은 V6 학습과 같다
- `--run` 티거(와 모델이 조종하는 다른 차종)를 그 실행의 상대 풀 최신 모델이 조종한다. 비우면 규칙 AI
- `--map village` 처럼 맵을 고정할 수 있다. `--time-limit 120` 으로 제한 시간을 바꿀 수 있다

판이 시작되면 **첫 조작을 할 때까지 시간이 멈춰 있다.** 판이 끝나면 결과가 화면에 나오고 다음 판이 준비된다.
창을 닫으면 끝난다(진행 중인 판은 저장하지 않는다).

| 조작 | |
|---|---|
| W/S | 전진/후진 |
| Q/A · E/D | 왼쪽·오른쪽 궤도 |
| Space | 제동 |
| 마우스 | 조준점(화면 가운데 흰 원). 포탑·포가 따라간다 |
| 좌클릭 / F | 발사 |
| Shift | 포수 조준경 ↔ 3인칭 |
| B | 전차장 시점(포 고정) |
| 우클릭 / C (3인칭) | 둘러보기(포 고정) |
| 휠 | 조준경 배율 / 전차장 확대 |
| 1 / 2 / 3 | 탄종 |
| Esc / P | 일시정지(창 밖을 클릭해도 멈춘다) |

화면의 **노란 십자 + 눈금** 은 포가 실제로 향한 곳과 거리 눈금(×100m, 현재 탄종 탄도)이다. 포탑이 조준점을 따라오면 흰 원과 겹친다.
멀리 있는 표적은 그 거리 눈금에 표적을 놓고 쏜다(자동 탄도 계산 없음).

저장 위치: `%LOCALAPPDATA%\TankGameML\training\combat_demos\<차종>\<단계>_<맵>_....npz`
(0.1초마다 관측·행동 한 쌍, 결과·맵·시드·라벨·게임 버전 포함)

## 2. 행동 복제 적용

```powershell
cd training\python
# 효과만 보기
py -3.14 train_combat_bc.py --run "V6run 1" --tank sherman75 --dry-run
# 적용(학습이 멈춰 있을 때)
py -3.14 train_combat_bc.py --run "V6run 1" --tank sherman75
```

- 시범 판의 20%(최소 1판)는 검증용으로 빼고, 검증 오차가 더 줄지 않으면 멈춘다.
- PPO 정책의 실제 int8 명령 확률(V6ControlDistribution)에 대한 음의 로그우도를 줄인다.
  행동 잡음(log_std)과 가치 함수는 그대로 두므로 PPO 탐색 폭이 줄지 않는다.
- 결과는 새 체크포인트 세대로 저장한다. 누적 스텝·커리큘럼·PPO optimizer 상태는 그대로이고,
  보고서는 `<실행>\<차종>\behavior_clone\<시각>.json`, 요약은 `curriculum.json` 의 `behavior_clone`.
- 적용한 뒤 대시보드에서 그 실행을 **이어서** 학습하면 시범을 따라 한 정책에서 PPO 가 시작한다.
- 출력 예: 발사 일치 · 제동 일치 · 시점 일치(같은 구간인지), 궤도·포 평균 절대 오차, 적용 전/후 비교.

## 3. 시험

```powershell
cd training\python
py -3.14 -m pytest tests\test_combat_demo.py
```

클라우드에서는 `--autopilot`(숨은 옵션)으로 창 모드 경기를 자동 조작해 저장·발사·시점을 확인했다.

## 구현

- `training/human_pilot.gd` — 창·카메라(V7 중앙 조준), 포수 시점 시작, 사람 입력 → 정책 공간 행동 11개
- `training/human_pilot_reticle.gd` — 조준점·포 축·거리 눈금
- `training/training_env.gd` — `ctrl: "human"` 전차. 결정 시점마다 관측과 int8 양자화 행동을 obs 메시지 뒤에 붙여 보낸다
  (`human_demo_version` 1). 헤드리스 학습에는 영향이 없다
- `training/python/play_combat_demo.py` — V6 배치 생성, 상대 모델 추론, 시범 저장
- `training/python/tankrl/combat_demo.py` — 시범 형식, 행동 복제
- `training/python/train_combat_bc.py` — 실행의 차종 모델에 적용
