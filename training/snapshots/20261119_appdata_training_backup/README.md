# 2026-11-19 학습 데이터 백업

원본 위치: `%LOCALAPPDATA%/TankGameML/training`.

`archives/part_*.zip` 전체가 하나의 백업이다. 각 ZIP은 독립적인 표준 ZIP이며, 파일 경로는 원본 `training` 폴더 기준이다. 모델·옵티마이저·체크포인트·상대 정책 풀·성공률 및 보상 CSV·에피소드 JSON/JSONL·보고서·재현용 실행 파일과 로그를 포함한다. 잠금 파일과 저장 중 임시 파일은 제외한다.

`manifest.json`에 모든 파일의 상대 경로, 크기, SHA-256, 소속 ZIP과 체크포인트 세대가 기록된다. 큰 ZIP은 Git LFS로 보관한다. Git LFS 포인터만 다운로드한 상태에서는 복원할 수 없다.

학습 프로세스가 종료된 뒤 생성한 백업이다. 보존된 `status.json`에는 마지막 수집 상태가 남아 있을 수 있으므로 현재 실행 여부는 운영체제 프로세스로 확인한다. `FINAL-V5run1/tiger1`의 마지막 확인된 저장 모델은 2,300,001스텝이다. 마지막 상태 기록의 약 236만 스텝을 저장된 모델 스텝으로 해석하지 않는다.

## 프로젝트 내부로 복원

저장소 루트에서 실행한다. 복원 대상 폴더는 아직 존재하지 않아야 한다.

```powershell
git lfs pull --include="training/snapshots/20261119_appdata_training_backup/archives/*.zip"
python training/tools/restore_training_backup.py training/snapshots/20261119_appdata_training_backup training/data
```

복원 도구는 ZIP과 각 파일의 SHA-256을 확인하며, 기존 폴더를 덮어쓰지 않는다. 복원 결과는 `training/data/runs`, `training/data/runtimes` 등이다. 복원 자체는 학습을 시작하지 않는다.

기존 학습 프로그램에는 AppData 기본 경로와 절대 경로가 남아 있다. 학습을 다시 시작하기 전에 저장 경로·실행 파일 경로를 이 프로젝트 내부의 복원 위치로 맞추고 재개 동작을 검증해야 한다. 백업 작업은 원본 AppData 파일과 기존 junction을 이동하거나 삭제하지 않았다. 새 저장 위치의 원칙은 루트 `AGENTS.md`를 따른다.
