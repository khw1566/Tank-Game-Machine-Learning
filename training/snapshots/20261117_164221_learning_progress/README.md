# 학습 데이터 보존본 — 2026-11-17

`terrain_v2_20261117`의 Tiger I **2,965,902스텝** 체크포인트를 기준으로 저장했다.
체크포인트 생성 시각은 `2026-11-17T16:42:21.684964+09:00`이다. 전체 데이터 파일은 **22,457개**다.

전체 실행의 모델·저장 세대·정책 풀·행동·보상·동선·평가·리플레이·보고서와
7개체 독립 모델, 실행 파일 9개 버전을 포함한다. 학습을 일시정지하고 체크포인트를 저장한 후
가변 파일을 별도로 고정했다. 압축 중 학습을 재개했으며 이후 진행분은 원본에 계속 저장된다.
메모리에만 있던 미완료 에피소드와 롤아웃, 잠금·임시 파일, Python 캐시는 제외했다.

소스 코드는 이 보존본을 포함한 Git 커밋에 있다. `training_state.json`에는 변경 전 기준 커밋과
실제 실행 파일의 SHA-256을 기록했다. 기존 실행 메타데이터의 버전 이력도 유지했다.

## 다운로드·검증·복원

저장소 루트에서 실행한다. 복원 대상 폴더는 존재하지 않아야 한다.

```powershell
git lfs pull
python training/snapshots/restore_archives.py training/snapshots/20261117_164221_learning_progress
python training/snapshots/restore_archives.py training/snapshots/20261117_164221_learning_progress --dest C:/TankGameML-restored-20261117
training/python/dashboard.bat --runs-dir C:/TankGameML-restored-20261117/runs
```

복원 후 게임 실행 파일과 Python 경로를 현재 PC에 맞게 지정한다.
실행 파일은 `runtimes/<SHA-256>/TankGame.exe`에 있다. 원본 절대 경로와 프로세스 ID는 당시 이력이다.
재개는 저장된 모델·커리큘럼에서 시작하며, 메모리에만 있던 롤아웃을 정확히 이어가는 방식은 아니다.

`content_manifest.json`은 데이터 파일별 압축 위치·크기·SHA-256을 기록한다.
`manifest.json`은 외부 압축 파일과 메타데이터를 검증한다. 가상환경 자체는 포함하지 않는다.
