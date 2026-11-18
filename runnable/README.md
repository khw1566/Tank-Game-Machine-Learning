# 바로 실행 가능한 묶음 (curriculum-v4-runnable)

`curriculum-v4` 코드 + 게임 실행 파일 + 학습된 모델. 다른 PC에서 받아 바로 이어서 학습하거나 모델을 확인할 때 쓴다.
`main`·`curriculum-v4` 브랜치에는 실행 파일·모델을 넣지 않는다(이 브랜치에만 있다).

기준 시각 2026-11-18 09:22 KST.

| 파일 | 내용 |
|---|---|
| `TankGame.exe` | 게임 실행 파일(Godot 4.3). 엄폐 과제 조기 종료 감점·후진 비용 수정본 |
| `runs/V4RUN-4/` | 공통 모델(세 전차) **730만 스텝, 2단계 경로 선택**. 학습 실행 폴더 그대로라 이어서 학습할 수 있다 |
| `runs/V4RUN-4/shared/good/` | 단계별 최고 모델(주행·정지, 경로 선택) |
| `reference/V4RUN-2_step_047900104/` | 이전 계열(gSDE) 4,790만 스텝, 경로 선택 통과 직후 모델. 비교·참고용(행동 잡음 문제가 있어 이어서 학습은 권하지 않음) |

## 받기

실행 파일과 모델은 Git LFS 로 저장되어 있다.

```powershell
git lfs install
git fetch origin curriculum-v4-runnable
git checkout curriculum-v4-runnable
git lfs pull
```

## 이어서 학습

`runs/V4RUN-4` 를 학습 폴더로 복사한 뒤 대시보드에서 `V4RUN-4` 를 골라 "새 학습 / 이어서" → "시작".

```powershell
python -c "import shutil; shutil.copytree('runnable/runs/V4RUN-4', 'training/python/runs/V4RUN-4')"
copy runnable\TankGame.exe build\TankGame.exe
training\python\dashboard.bat
```

명령줄로는:

```powershell
cd training/python
.venv\Scripts\python.exe train.py --godot ..\..\build\TankGame.exe --run V4RUN-4 --tank shared --curriculum v4 --auto-branch --rotate-steps 3000000 --cycles 3 --timesteps 80000000 --n-envs 120 --device hybrid --resume
```

다른 PC 에서는 `--n-envs` 를 CPU 코어 수에 맞게 줄인다. 이미 같은 이름의 실행 폴더가 있으면 덮어쓰지 말고 다른 이름으로 복사한다.

## 체크섬(SHA-256)

```text
2a34673565dfb6c0ec3ccec7bf5ff579b032ba2e8f41af50070d2789e5362bf0  TankGame.exe
d57af95173a5bdad03f095aa0508dc24bada5005648c9188d04dee9479b0a463  runs/V4RUN-4/shared/latest.zip (= checkpoints/step_007300032_*/model.zip)
e36195b74c524e2393ae9691639c8573535e64568c3b6a7c9a8fa66c801341f4  runs/V4RUN-4/shared/good/best_m1_drive.zip
bf14ca40ef048d66923bbaf0490faee00bf5a2881900877baeef783ac685cee3  runs/V4RUN-4/shared/good/best_m2_route.zip
94d916988f06b8b4976e5a81dbc37029f144f3eafba260bc1aaa01db54b3ccb4  reference/V4RUN-2_step_047900104/model.zip
```

`runs/V4RUN-4/shared/checkpoint.json` 의 sha256 은 학습 코드가 불러올 때 다시 확인한다.
`good_checkpoints.json`·`run.json` 안의 절대 경로는 원래 PC 의 기록이다.
