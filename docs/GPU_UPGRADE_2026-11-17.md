# GPU 학습 개선 완료 기록

2026-11-17 / Intel i5-12400F, RTX 4070 SUPER 12GB, Windows.

## 적용한 구성

- 프로젝트 전용 `training/python/.venv`: Python 3.14.0, PyTorch **2.15.0+cu132**, CUDA **13.2**, SB3 2.9.2. 실제 CUDA 커널 실행 확인.
- 장치: `hybrid` = CPU 행동 추론·GAE + GPU PPO 갱신. `auto`도 CUDA 사용 가능 시 혼합 모드를 선택한다.
- `cuda` = 추론과 갱신 모두 GPU, `cpu` = CPU. 명시적인 GPU 요청은 사용 불가 시 오류를 표시한다.
- CPU 추론 정책은 매 rollout 시작에 GPU 학습 정책과 동기화한다. 수집이 끝난 후에만 갱신하므로 기존 PPO의 정책 갱신 순서를 유지한다.
- CUDA rollout 버퍼는 한 번 올린 학습 데이터를 여러 epoch에서 재사용한다. 8 epochs 기준 관측 등의 반복 전송을 줄였다.
- 수집 도중 체크포인트 요청이 와도 GPU 학습 정책과 optimizer 상태를 함께 저장한다. CPU 추론 복사본은 체크포인트에서 제외한다.
- 대시보드에 장치 선택, PPO 수집·배치·epoch 설정, 실제 추론/갱신 장치, PyTorch GPU 메모리와 GPU 전체 지표를 추가했다.
- 환경 수 변경 재시작에서 장치와 PPO 설정을 보존한다. 재개 시 지정한 PPO 설정도 실제 모델/버퍼에 적용한다.
- 현재 로컬 대시보드 기본 장치는 **hybrid**로 설정했다. 본 학습은 재개하지 않았다.

## 실행 방법

이 PC에는 GPU 환경 설치가 끝났으므로 `training/python/dashboard.bat`를 실행하면 된다.
**새 학습 / 이어서 → 기존 실행 선택 → 학습 장치: 혼합 (CPU 추론 + GPU 갱신)**으로 시작한다.
장치 변경은 제어 영역의 학습 장치 선택에서도 가능하다(저장 후 재시작).

다른 PC에서 같은 환경을 준비하려면 Python 3.14와 호환되는 NVIDIA 드라이버 설치 후 `setup_gpu.bat`를 실행한다.
공식 CUDA wheel을 프로젝트 가상환경에 설치하며, 전역 Python은 수정하지 않는다.

Godot 물리·관측 계산은 CPU에서 실행한다. GPU 사용률은 PPO 갱신 구간에서 높아지는 형태이며,
이 작은 MLP에서 높은 VRAM 점유율이나 지속적인 GPU 사용률 자체를 목표로 삼지는 않는다.

## 동일 조건의 짧은 실측

기존 체크포인트를 읽어서, Godot 8개 / 환경당 1,024개 수집 / batch 2,048 / 8 epochs로 비교했다.
CPU는 torch 4스레드, 혼합은 1스레드다. 각 모드 3 rollout × 3회 = 73,728개 전이를 처리했다.
모든 결과의 모델 파라미터가 유한한 값임을 확인했다.

| 항목 | CPU | 혼합 CPU+GPU |
|---|---:|---:|
| 반복별 처리량 평균 | 1,508.50 decisions/s | 1,693.23 decisions/s |
| 반복별 처리량 중앙값 | 1,547.05 decisions/s | 1,690.58 decisions/s |
| 모든 반복 합산 처리량 | 1,505.70 decisions/s | 1,693.00 decisions/s |
| PPO 갱신 시간 중앙값 / rollout | 0.6725초 | 0.3130초 |

이 조건에서 평균 처리량은 **약 12.2% 증가**, 갱신 시간 중앙값은 **약 53.5% 감소**했다.
CPU와 혼합 모드의 스레드 구성 차이도 포함한 실행 모드 비교다. GPU 장치 하나만 바꾼 효과로 해석하면 안 된다.
전체 GPU 추론의 초기 비교에서는 1,122.38 decisions/s로 CPU의 1,457.59보다 느려,
작은 추론을 CPU에 남기는 혼합 경로를 구현했다.

이는 drive 단계의 짧은 검증이다. 초기화된 커리큘럼과 기록을 끈 별도 환경이므로
이전 본 학습의 약 512 decisions/s나, 저장된 커리큘럼을 그대로 재개한 CLI 실행과 직접 비교할 수 없다.
장기 학습 처리량·수렴 속도·사격/자기대전 성능 향상은 아직 검증하지 않았다.

원시 결과:

- `training/python/runs/gpu_validation_20261117/results.json`: CPU와 전체 CUDA 경로의 초기 비교.
- `training/python/runs/gpu_hybrid_validation_20261117/results.json`: CPU/혼합 각 3회 비교.
- 재실행 도구: `training/python/benchmark_devices.py`. 원본 체크포인트는 읽기만 하며 결과를 별도 폴더에 남긴다.

## 검증

- GPU 관련 unittest **7개 통과**: CPU 설치에서 명시 CUDA 거부, 장치 번호 확인, 재시작 설정 보존,
  CPU 체크포인트의 CUDA 갱신 및 CPU 재로드, 버퍼 표본 일치·캐시 초기화,
  혼합 모드의 CPU 수집/GPU 갱신·rollout별 가중치 일치·수집 중 optimizer 포함 저장, auto 모드 확인.
- 실제 `train.py` 경로에서 원본 체크포인트 복사본을 혼합 모드로 8,192스텝 재개하고,
  **1,241,880스텝에서 정상 저장·종료**했다. GPU 저장 결과를 CPU로 다시 불러와 추론을 확인했다.
- 실제 저장 manifest에서 `inference_device=cpu`, `update_device=cuda:0`, `CudaRolloutBuffer`를 확인했다.
- 대시보드 HTTP 읽기 API: 가상환경 선택, CUDA 인식, GPU 지표, 기존 실행 중지 상태 확인.
- 대시보드 JavaScript 문법 검사 및 DOM 통합 검사 통과: 장치 선택·배치 설정·재시작 요청·장치 상태 표시.
  실제 브라우저 화면의 시각 검사는 수행하지 않았다.
- `pip check`: 의존성 충돌 없음.
- 기존 본 실행 `20261117_063521`은 **1,233,688스텝 중지 상태**를 유지했다.
  원본 체크포인트 SHA-256은 검증 전후 아래 값으로 동일했다.

```text
66174664dbbfb93d063a2e7672bb4bb799a1ce7b9cb4b89dbd8db91a77d288a8
```

핵심 코드: `tankrl/hybrid_ppo.py`, `tankrl/rollout_buffer.py`, `tankrl/runtime.py`,
`train.py`, `dashboard.py`, `tankrl/dashboard.html`.

공식 설치·API 근거: [PyTorch 설치 안내](https://pytorch.org/get-started/locally/),
[공식 CUDA wheel 저장소](https://download.pytorch.org/whl/cu132/torch/).
