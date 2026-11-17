# 학습 데이터 스냅샷

최신 보존본: **[20261117_164221_learning_progress](20261117_164221_learning_progress)**

- `terrain_v2_20261117`의 Tiger I **2,965,902스텝** 체크포인트를 기준으로 저장했다.
- 전체 실행의 모델·저장 세대·정책 풀·학습 통계·평가·리플레이와 7개체 독립 모델, 실행 파일 9개 버전을 포함한다.
- 가변 파일을 별도로 고정한 뒤 압축 중 학습을 재개했다. 이후 진행분은 실행 중인 원본에 계속 저장된다.
- 실행별 ZIP은 Git LFS로 보관한다. 파일별 크기와 SHA-256은 `content_manifest.json`, 압축 파일의 검증값은 `manifest.json`에 있다.

저장소 루트에서 다운로드하고 검증한다. 복원 대상 폴더는 존재하지 않아야 한다.

```powershell
git lfs install
git lfs pull
python training/snapshots/restore_archives.py training/snapshots/20261117_164221_learning_progress
python training/snapshots/restore_archives.py training/snapshots/20261117_164221_learning_progress --dest C:/TankGameML-restored-20261117
training/python/dashboard.bat --runs-dir C:/TankGameML-restored-20261117/runs
```

다른 PC에서는 게임 실행 파일과 Python 경로를 현재 환경에 맞게 지정한다.
`runtimes/<SHA-256>/TankGame.exe`에 보관된 버전으로 당시 환경을 선택할 수 있다.
기록 속 절대 경로와 프로세스 ID는 당시 이력이며 자동으로 현재 경로로 바뀌지 않는다.

## 이전 환경 보존본

**[20261117_083446_before_environment_change](20261117_083446_before_environment_change)**

- 캡처: 2026-11-17 08:34:46 KST. 학습이 저장 후 중지된 상태에서 복사했다.
- 실행: `20261117_063521`, Tiger I, **2,097,312스텝**, `drive_terrain` 단계.
- 소스 커밋: `9e3868b1ee6b7b15445cad5e8b55b09097595573`.
- 데이터 파일 4,301개, 약 401.77MiB. 별도 `manifest.json`에 파일별 크기와 SHA-256을 기록했다.
- 모델 체크포인트와 게임 실행 파일은 Git LFS로 저장한다. 원본 `training/python/runs`는 계속 Git에서 제외한다.

## 포함된 자료

| 폴더 | 내용 |
|---|---|
| `runs/20261117_063521` | 전체 학습 실행 설정·통계·커리큘럼·행동/보상/동선 재현 파일·리플레이·단계별 모델·최종 모델 |
| `runs/pool` | 자기대전 상대 정책 풀과 정책 버전 메타데이터 |
| `runs/gpu_*`, `runs/terrain_diagnostics_*` | GPU 검증·비교 결과와 지형주행 진단 기록 |
| `runs`의 기타 파일 | 이전 시작 로그, 대시보드 설정, 패키지 설치 로그 |
| `godot_user_logs` | 게임 사용자 폴더에 저장됐던 경기 기록·리플레이·보고서·게임 로그 |
| `runtime/TankGame.exe` | 당시 학습에 사용한 Godot 4.3 게임 실행 파일(가속 개선 반영) |
| `environment/pip-freeze.txt` | 당시 Python 가상환경 패키지 버전 목록 |

가상환경 자체, 다운로드 도구, 빌드 중간 산출물은 포함하지 않는다.
이 자료는 현재 존재하는 모델과 기록의 보존본이며, 모든 학습 스텝의 화면 이미지 데이터셋은 아니다.

## 다운로드와 무결성 확인

Git LFS를 설치한 후 저장소 루트에서 실행한다.

```powershell
git lfs install
git lfs pull
python training/snapshots/verify_snapshot.py training/snapshots/20261117_083446_before_environment_change
```

성공 시 `verified_files: 4301`, `num_timesteps: 2097312`가 표시된다.
최종 체크포인트 SHA-256:

```text
adc5f919b1c91c7af6a2b7d12b707f90f215075d6013c15375fe7a2e7170b772
```

## 학습 재개

보존본에서 직접 학습하지 말고 실행 데이터 복사본을 만든다. 아래 명령은 `runs_restored`가
이미 있으면 덮어쓰지 않고 실패한다. 다른 복원 폴더 이름을 사용해 기존 학습 자료를 보존한다.

```powershell
python -c "import shutil; shutil.copytree('training/snapshots/20261117_083446_before_environment_change/runs', 'training/python/runs_restored')"
training/python/dashboard.bat --runs-dir runs_restored
```

필요하면 먼저 `training/python/setup_gpu.bat`로 CUDA 가상환경을 준비한다.
대시보드에서 `20261117_063521`을 선택하고 **새 학습 / 이어서**로 재개한다.
다른 PC에서는 저장된 게임·Python 경로를 현재 경로로 지정한다.

당시 물리를 유지하려면 이 스냅샷의 `runtime/TankGame.exe`를 게임 실행 파일로 선택한다.
변경한 환경에서 학습하려면 새 게임 실행 파일을 선택한다. 기존 모델 입력·행동 규격이 달라지면
체크포인트를 그대로 재사용할 수 있는지 별도로 확인해야 한다.

기록에 들어 있는 절대 경로와 과거 프로세스 ID는 당시의 이력이다.
게임의 F3 목록에서 별도 경기 기록을 열려면 `godot_user_logs/replays`를 게임 사용자 로그 폴더로 복사한다.
