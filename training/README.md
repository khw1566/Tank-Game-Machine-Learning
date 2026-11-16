# 강화학습 (커리큘럼 + 자기대전)

헤드리스 Godot 여러 개를 Python(Stable-Baselines3 PPO)에 소켓으로 붙여 학습한다.
전차 종류마다 정책(모델)이 따로 있고, 쉬운 과제부터 단계적으로 올라가 마지막에 원래 목표(티거 1 vs 셔먼 3 + T-34 2 자기대전)에 도달한다.

```
Python train.py ─┬─ GodotVecEnv ─ TCP ─ Godot #0 (training_env.tscn, --headless --fixed-fps 30)
   PPO(전차별)    ├─ 커리큘럼(승급)  ─ TCP ─ Godot #1
   상대 풀        └─ progress.csv    ─ TCP ─ Godot #2 …
```

## 왜 단계적으로(커리큘럼)

처음부터 900m 떨어진 6대 전투로 시작하면 보상이 너무 드물어(찾고·다가가고·맞히는 것까지 우연히 해야 함) 거의 배우지 못한다.
그래서 주행 → 사격 → 1대1 → 팀전 순으로, 스폰 거리도 짧게 시작해 늘린다. 성공률이 기준을 넘으면 자동 승급하고,
10% 확률로 이전 단계를 복습해 앞에서 배운 것을 잊지 않게 한다.

| # | 단계 | 내용 | 스폰/표적 거리 | 시점 | 성공 | 승급 기준 |
|---|---|---|---|---|---|---|
| 1 | drive | 빈 맵, 웨이포인트까지 주행 | 60~200m | 3인칭 고정 | 12m 안 도착 | 최근 100판 80% |
| 2 | drive_terrain | 숲·바위·생울타리 맵 주행 | 100~300m | 3인칭 고정 | 15m 안 도착 | 70% |
| 3 | gunnery_static | 정지 표적(적 전차, 방향 무작위) | 150~400m | 포수 조준경 고정 | 2발 명중 또는 격파 | 70% |
| 4 | gunnery_moving | 움직이는 표적 | 200~600m | 포수 조준경 고정 | 2발 명중 또는 격파 | 60% |
| 5 | gunnery_search | 지형 맵, 시점 자유: 둘러보고 찾아서 쏘기 | 200~700m | 자유 | 2발 명중 또는 격파 | 50% |
| 6 | duel_scripted | 1대1 vs 규칙 AI | 300~700m | 자유 | 승리 | 50% |
| 7 | duel_selfplay | 1대1 vs 상대 종류의 학습 정책(없으면 규칙 AI) | 300~800m | 자유 | 승리 | 50% |
| 8 | team_scripted | 티거 1 vs 셔먼 2 + T-34 1 | 500~800m | 자유 | 팀 승리 | 50% |
| 9 | team_selfplay | **원래 목표**: 티거 1 vs 셔먼 3 + T-34 2, 전원 학습 정책 | 600~900m | 자유 | 팀 승리 | (마지막) |

각 단계는 최대 에피소드 수(6000~8000)를 넘으면 기준 미달이어도 넘어간다(승급 기록에 "최대 에피소드 도달"로 남음).
정의는 [python/tankrl/curriculum.py](python/tankrl/curriculum.py) 의 `STAGES` 한 곳에 있다.

- **같은 종류 아군**은 학습 중인 현재 정책을 그대로 복사해 쓰고(파라미터 공유), **다른 종류**는 풀(`runs/pool/<tank>/`)에 저장된 그 종류의 정책을 상대로 쓴다(70% 최신, 30% 예전 스냅숏).
- `--rotate tiger1,sherman75,t34_76` 로 종류를 번갈아 학습하면 자기대전 단계에서 서로의 최신 정책과 싸운다.

## 관측·행동

- 관측 = `TankPerception`(사람이 그 시점에서 보고 듣는 것, [controls/OBSERVATION.md](../controls/OBSERVATION.md)) + 임무 8개:
  웨이포인트 유무·방위(sin, cos)·거리(주행 단계만), 남은 시간, 단계 종류(주행/사격/전투). 전투에서 임무 방위 = 적 출발 지역(맵 공개 정보),
  사격 훈련에서 = 표적이 있는 구역(사수에게 지시된 방향; 거리는 주지 않음).
- 행동 = 11개, 정책 출력은 모두 −1~1 이고 Godot 에서 변환: brake = max(0, x), fire = x > 0, view_mode = 3구간(3인칭/포수/전차장), free_look = x > 0.
  10Hz(3틱마다) 결정, 사이에는 직전 행동 유지.
- 보상 = 게임 점수와 같은 `RewardModel`(명중·관통·격파·피격 감점…) + 단계별 보조 보상(`training/training_reward.gd`):
  주행 = 가까워진 거리, 도착 / 사격 = 포 방향 정렬 퍼텐셜 + 성공 보너스 / 전투 = 첫 탐지, 승패. 보조 보상은 실제 거리 같은 정답 정보를 쓰지만 관측에는 안 들어간다.

## 설치 (Windows, 한 번만)

1. Python 3.10~3.14 설치(python.org, "Add to PATH" 체크)
2. 이 폴더에서:
   ```
   cd "C:\Users\work\Desktop\Tank Game Machine Learning\training\python"
   python -m venv .venv
   .venv\Scripts\activate
   pip install -r requirements.txt
   ```
   GPU 는 필요 없다(정책이 작은 MLP 라 CPU 가 더 빠를 때가 많음). 속도는 Godot 시뮬레이션이 좌우한다.

## 학습 실행

내보낸 게임 실행 파일(`build\TankGame.exe`)을 그대로 쓸 수 있다(편집기 없이). 코드를 바꿨으면 exe 를 다시 내보내거나, 편집기 실행 파일 + `--project` 를 쓴다.

```
:: 티거만, 처음부터
python train.py --godot "..\..\build\TankGame.exe" --tank tiger1 --timesteps 3000000 --n-envs 6 --run tiger_a

:: 세 종류 교대(자기대전), 이어서 하기는 같은 --run 으로 --resume
python train.py --godot "..\..\build\TankGame.exe" --rotate tiger1,sherman75,t34_76 --rotate-steps 500000 --cycles 10 --run selfplay_a
python train.py --godot "..\..\build\TankGame.exe" --tank tiger1 --run tiger_a --resume --timesteps 2000000

:: 편집기로(코드 수정 직후)
python train.py --godot "C:\Godot\Godot_v4.3-stable_win64_console.exe" --project "..\.." --tank sherman75
```

옵션: `--n-envs`(동시 Godot 수, CPU 코어 수 정도), `--speed-cap 20`(실시간 대비 최대 배속, 0 = 무제한), `--torch-threads`, `--start-stage gunnery_static`(중간 단계부터), `--record-every 200`(N판마다 전체 리플레이·경기 보고서), `--save-every 100000`, `--review-prob 0.1`.

속도(클라우드 4코어 측정): 주행 단계 Godot 1개당 약 200~270 결정/초(실시간의 20~27배), 1대1 약 120~150. 4개 병렬 PPO 학습 전체 ≈ 600 결정/초.

## 모니터링·제어 대시보드(GUI)

추가 설치 없이(Python 표준 라이브러리만, GPU 불필요) 브라우저에서 학습을 시작·감시·조절한다.

```
cd "C:\Users\work\Desktop\Tank Game Machine Learning\training\python"
.venv\Scripts\activate
python dashboard.py                → 브라우저에 http://127.0.0.1:8765 이 열린다
```

또는 `training\python\dashboard.bat` 더블클릭(`.venv` 가 있으면 그 Python 으로 실행).
학습용 Python 에 필요한 패키지(numpy, gymnasium, stable-baselines3, torch)가 없으면 화면 맨 위에 알림이 뜨고 **"필수 패키지 설치"** 버튼으로 `pip install -r requirements.txt` 를 실행한다(처음 한 번, 수 분).
학습용 Python 은 새 학습 창에서 지정할 수 있고, 비우면 `training\python\.venv` → 대시보드를 실행한 Python 순서로 고른다. Python 3.10~3.14 모두 Windows 용 torch(CPU) 휠이 있다.

- **시작**: 오른쪽 위 "새 학습 / 이어서" → 게임 실행 파일(기본 `..\..\build\TankGame.exe`), 전차 하나 또는 교대, 환경 수, 시작 단계, 배속 제한 …
  보고 있는 실행이 멈춰 있으면 그 설정으로 "이어서"가 채워진다.
- **제어**: 일시정지/재개, 저장 후 중지, 지금 체크포인트, 커리큘럼 단계 수동 변경(승급 기록에 "수동 변경"),
  기록 간격·복습 확률·배속 제한은 실행 중 바로 반영. **환경 수**는 실행 중에 못 바꾸므로 "적용"하면 저장 → 같은 실행을 `--resume` 으로 다시 시작(남은 스텝, 바꾼 설정 유지).
- **감시(2초마다)**: 단계·성공률(승급 기준 대비)·초당 결정·에피소드, 실시간 대비 배속, 남은 시간, 9단계 띠,
  학습 곡선(단계별 성공률·보상·에피소드 길이, 명중·관통률, 학습 속도, PPO 엔트로피·가치 손실·KL — 가로축 스텝/에피소드/시간, 점선 = 단계 변경),
  전차별 정책(단계·스냅숏·상대 풀), 단계 변경 기록, 학습 로그.
- **최근 에피소드 → 보기**: 🎬 리플레이(기록된 판, 게임 리플레이 뷰어로 열림)·경기 보고서, 아무 판이나 "재현 후 보기"(`reproduce.py` 로 똑같이 다시 돌려 `runs/<run>/reproduced/` 에 저장 후 뷰어로 열기, 해시 OK/MISMATCH 표시).
  "학습 보고서 만들기" = `report.py`.
- 대시보드를 닫아도 학습은 계속된다. 다시 열면 그대로 이어서 보인다. 명령줄로 시작한 `train.py` 도 같은 `runs` 폴더면 감시·제어된다.

가속 요령
- 환경 수 ≈ 논리 코어 수 − 1~2(Godot 1개 = 코어 1개). 대시보드의 "초당 결정 수"를 보며 늘려 보고, 더 안 오르면 그 앞이 적정.
- 전체 리플레이 기록은 느리니 간격을 크게(또는 0). 재현 파일은 항상 남으므로 어떤 판이든 나중에 다시 볼 수 있다.
- 게임 시간 배속은 이미 최대(헤드리스·잠금 단계, 렌더링 없음)라 더 올릴 수 없다. 반대로 PC 를 같이 쓰려면 "배속 제한"으로 낮춘다.
- Godot 은 Python 을 오래 기다리면(PPO 갱신·일시정지) 잠들어 CPU 를 양보한다 → PPO 갱신이 빨라지고, 일시정지 중 CPU 사용 ≈ 0.
  `--torch-threads`(기본 = 코어 수 − 환경 수)로 PyTorch 스레드가 Godot 과 코어를 다투지 않게 한다.

제어는 파일로 주고받는다: `runs/<run>/control.jsonl`(명령 한 줄씩), `runs/<run>/status.json`(1초마다 상태). 형식은 [python/tankrl/control.py](python/tankrl/control.py) 맨 위.

## 기록(보고서용) — `runs/<run>/`

| 파일 | 내용 |
|---|---|
| `run.json` | 실행 인자, git 커밋, Python/torch/SB3/Godot 버전, 단계 정의 전체, 관측·행동 이름 |
| `status.json`, `control.jsonl`, `train_log.txt` | 현재 상태(1초마다), 대시보드 명령, 대시보드로 시작한 학습의 출력 |
| `progress.csv` | **에피소드마다 한 줄**: 단계, 성공, 종료 사유, 승자, 보상 합, 길이, 스폰 거리, 맵 시드, 에피소드 시드, 발사·명중·관통·격파, 학습 정책 버전, 상대 정책 버전, 재현 파일 경로, 리플레이 경로, 끝 상태 해시 |
| `curriculum_log.jsonl` | 승급 기록(언제, 몇 판 만에, 성공률, 그때 정책 버전) |
| `episodes/env*/<uid>.json` | **모든 에피소드 재현 파일**: reset 설정 전체(시드·맵·전차·단계·보상 가중치·정책 버전), 결정마다 외부 행동(int8)·보상(float32), 사격 기록(명중 부위·관통·거리), 1초 간격 동선, 결과 |
| `env*/replays/ep*/` | `--record-every` 마다 전체 리플레이 `events.jsonl`(그래픽 무관 상태 기록, 판단 기록에 관측 벡터·정책 버전·누적 보상) + `report.html` |
| `<tank>/step_*.zip`, `latest.zip`, `curriculum.json` | 정책 체크포인트와 커리큘럼 상태 |
| `sb3/<tank>/progress.csv` | PPO 학습 통계(손실, 엔트로피, 단계별 성공률). tensorboard 가 설치돼 있으면 이벤트 파일도 |

학습 보고서(단계별 학습 곡선·승급 표·단계 통계·기록된 경기 링크):

```
python report.py runs\tiger_a        → runs\tiger_a\training_report.html
```

## 지난 판 재현

에피소드는 (설정 + 시드 + 결정마다의 외부 행동)으로 완전히 결정된다: 맵·출발 위치·전차 난수·움직이는 표적은 모두 에피소드 시드에서 나오고,
규칙 AI 는 난수를 쓰지 않으며, 정책 행동은 1/127 단위로 양자화한 값을 그대로 적용·저장한다. 그래서 학습 중 어떤 판이든 나중에 똑같이 다시 돌릴 수 있다.

```
python reproduce.py runs\tiger_a\episodes\env2\tiger_a_tiger1_0001234_gunnery_static.json --godot "..\..\build\TankGame.exe"
```

- 결과 리플레이는 게임의 기록 폴더(`user://logs/replays`)에 들어가 **게임에서 F3 리플레이 뷰어로 바로** 여러 시점(1~6)으로 볼 수 있다(`--out-dir` 로 다른 곳 지정 가능).
- 재현 기록에는 결정마다(0.1초) 관측 벡터 전체·행동·누적 보상이 들어간다(`--log-obs 0` 으로 끔).
- 끝 상태 해시가 원래와 같으면 `OK`. 다르면 `MISMATCH`(종료 코드 3) — 게임 코드나 엔진 버전이 바뀐 뒤에는 달라질 수 있으니, 보고서용으로는 `run.json` 의 git 커밋과 같은 판에서 재현한다.

## 프로토콜 (Godot ↔ Python)

메시지 = `[u32 JSON 길이][JSON][u32 바이너리 길이][바이너리]`(리틀엔디언). Python 이 포트를 열고 Godot 이 접속한다.

| 방향 | type | 내용 |
|---|---|---|
| G→P | hello | obs_size, act_size, 관측·행동 이름, 엔진 버전 |
| P→G | reset | `config`(training_env.gd `reset_episode` 주석의 키) → G 는 obs 로 답 |
| P→G | step | 바이너리 = 외부 조종 전차 수 × 11 float32 → G 는 3틱 진행 후 obs |
| G→P | obs | agents[{name, tank, team, alive, reward}], done, (끝나면) episode{reason, success, winner, 전차별 통계, episode_file, replay_dir, final_hash}; 바이너리 = 전차 수 × obs_size float32 |
| P→G | close | 종료 |

## 점검

```
python -m tests.smoke_env --godot <godot> --project ..\.. --stage gunnery_static --steps 600   (무작위 행동, 속도 측정)
python -m tests.check_reproduce --godot <godot> --project ..\..                                  (짧은 판 기록 → 재현 → 해시 비교)
```

게임에서도 스폰 거리를 줄일 수 있다: `TankGame.exe -- --spawn-distance=500`(기본 900m).
