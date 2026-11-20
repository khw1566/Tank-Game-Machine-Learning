# V6-1 모델 백업 · 2026-11-20

실행 중인 V6-1에서 차종마다 가장 최근에 저장을 마친 체크포인트를 복사했다. 세 모델 모두 V6-1의 1대1 단계와 보상 v2를 사용한다.

| 전차 | 해당 모델의 누적 스텝 |
| --- | ---: |
| 티거 I | 13,977,994 |
| 셔먼 75 | 9,200,014 |
| T-34-76 | 7,826,364 |

`runs/V6-1`에는 정책과 Adam 상태가 들어 있는 ZIP, 커리큘럼, 저장 세대 포인터가 있다. 자기대전은 각 차종의 이 저장본과 V5 공통 상대 모델을 사용해 재개할 수 있다. `runtime`에는 당시 사용한 Windows 실행 파일이 있다. 원본의 전체 상대 스냅숏 풀과 경기 기록은 로컬 실행에 남아 있다.

저장소 루트에서 Git LFS 파일을 받으면 모델과 EXE의 크기 및 SHA-256을 확인할 수 있다.

```powershell
git lfs install
git lfs pull --include='training/snapshots/20261120_v6_1_checkpoints/**'
$snapshot = (Resolve-Path 'training/snapshots/20261120_v6_1_checkpoints').Path
python training/snapshots/verify_snapshot.py $snapshot
```

복사본을 사용해 재개한다. 아래 예시는 스냅숏과 다른 새 경로를 만들고 티거부터 교대 학습한다. Python 학습 의존성은 `training/python/requirements.txt`에 있다.

```powershell
$restoredRuns = Join-Path $env:LOCALAPPDATA 'TankGameML/training/runs_restored_v6_20261120'
if (Test-Path -LiteralPath $restoredRuns) { throw '다른 복원 폴더를 지정하세요.' }
New-Item -ItemType Directory -Path $restoredRuns | Out-Null
Copy-Item -LiteralPath (Join-Path $snapshot 'runs/V6-1') -Destination $restoredRuns -Recurse
python training/python/train.py --godot (Join-Path $snapshot 'runtime/TankGame_v6_tactics_v2.exe') --runs-dir $restoredRuns --run V6-1 --curriculum v6 --resume --rotate tiger1,sherman75,t34_76 --rotate-steps 2000000 --cycles 10 --auto-envs --n-envs 10 --torch-threads 2 --device auto --gamma 0.999 --gae-lambda 0.995 --lr 0.0001 --record-every 100 --save-every 100000
```
