# Tank Game Machine Learning

2차 세계대전 전차전(티거 I vs 셔먼·T-34 다수)을 단순한 Godot 4 게임으로 만들고,
자기대전(self-play) 학습으로 당시 전술(티거의 비스듬한 대면, 연합군의 우회·측면 공격 등)이 나타나는지 확인하는 프로젝트.

- 엔진: Godot 4.3 이상 (GL Compatibility 렌더러, 에셋 없이 프리미티브 도형만 사용)
- 물리: 30 Hz. 헤드리스 실행 시 메시를 만들지 않아 학습용으로 가볍다.

## 폴더 구성

| 폴더 | 내용 |
|---|---|
| `tanks/` | 전차별 고유 모델(형상·경사장갑, 기동, 사격 특성), 공통 모듈(궤도·포탑·포방패·주퇴기/주포·장갑), 피해 모델, 전차 노드 → [tanks/README.md](tanks/README.md) |
| `controls/` | 공용 조작 입력(`TankControlInput`, 액션 벡터 6개), 키보드 조작, 통합 스모크 테스트 |
| `map/` | 전술 지형 생성기(`HillMap`, 시드로 재현), 시야·탐지 판정(`LineOfSight`), 거리 격자(`RangeGrid`) → 아래 "맵과 시야" |
| `tanks/lab/` | 장갑 시험장(시각화 + 관통 시험) |
| `recording/` | 경기 기록·점수(보상)·보고서·리플레이 뷰어·관찰 오버레이·규칙 AI → [recording/README.md](recording/README.md) |
| `build/` | Windows 실행 파일 출력 위치 |
| `main.tscn` / `main.gd` | 메인 씬: 티거 1 vs 셔먼 3 + T-34 2, 경기 기록·보고서 자동 생성 |

## 조작 (모든 전차 공통)

| 키 | 동작 | 액션 벡터 |
|---|---|---|
| Q / A | 왼쪽 궤도 전진 / 후진 | [0] left_track −1~1 |
| E / D | 오른쪽 궤도 전진 / 후진 | [1] right_track −1~1 |
| W / S | 양쪽 궤도 함께 | (0, 1 에 합산) |
| Space | 브레이크 | [2] brake 0~1 |
| ← / → | 포탑 선회 | [3] turret_traverse −1~1 (+ = 우) |
| ↑ / ↓ | 포 고저 | [4] gun_elevation −1~1 |
| F / Enter | 발사 | [5] fire (>0.5) |
| 1 / 2 / 3 | 탄종 선택(철갑 / 고속철갑·고체철갑 / 고폭) | (`tank.select_ammo(i)`) |
| Shift | 포수 조준경 시점 켜기/끄기: 포구에서 포 방향을 보고, 거리별 조준 눈금(현재 탄종 탄도)·조준 오차 원 표시. 휠/+− 로 저·고배율(약 3배/6배) | - |
| C (누르는 동안) | 3인칭 자유 시선: 포탑·포는 그대로 두고 마우스/방향키로 카메라만 돌림. 떼면 포 뒤로 복귀 | 포탑·포 입력 0 |
| B | 전차장 시점 켜기/끄기: 해치 높이에서 마우스/방향키로 둘러봄, 포는 고정. 휠/+− 로 확대(최대 약 9배) | 포탑·포 입력 0 |
| Tab | 조종 전차 전환 | - |
| G | 거리 표시 순환: 격자+거리 링 → 끔 → 격자 → 링만 | - |
| V | 시선 표시(초록 탐지 / 노랑 일부 보임 / 빨강 가려짐) | - |
| F1 | 장갑 시험장 열기 | - |
| F2 / M | 관찰 오버레이(미니맵 동선·탄착·점수 그래프) 켜기·끄기 / 지도 크게 | - |
| H / P | 3D 탄착 표시 / 이동 경로 선 켜기·끄기 | - |
| F3 | 리플레이 뷰어(지난 경기 다시 보기) | - |
| F4 | 경기 종료 + 보고서 생성 | - |
| F5 | 새 경기 | - |
| F6 | 기록 폴더 열기 | - |
| F7 | AI 전환: 꺼짐 → 다른 전차 AI → 전원 AI(관전) | - |

AI 는 `tank.control = TankControlInput.from_array([...])` 로 같은 입력을 넣는다.

시점(`controls/view_camera.gd`, `controls/view_reticle.gd`)은 화면 전용이라 헤드리스 학습에는 영향이 없다.
C·B 로 시선이 포와 분리된 동안은 방향키가 카메라를 돌리고 포탑·포 입력이 0 으로 기록된다(포가 움직이지 않음).
자유 시선·전차장 시점에서는 왼쪽 아래 방위판(차체 사각형, 노란 선 = 포, 하늘색 = 시야)과 ◇포 표시로 포가 어디를 겨누는지 보여 준다.

같은 입력이라도 전차마다 결과가 다르다: 실제 기어표의 변속기로 서서히 가속하고(T-34 2→3단 3초 동력 단절, 전후진 전환 3초),
차체가 지형 굴곡·돌·통나무를 따라 피치/롤로 기울고 출렁이기 때문에 포 각도를 다시 맞춰야 하며,
포 내림각(T-34 −5°, 티거 −8°, 셔먼 −10°)이 헐다운 가능 여부를 정한다.
움직이며 쏘면 조준 오차가 커지는데 셔먼은 안정장치 덕에 그 폭이 작다. 자세한 내용은 [tanks/README.md](tanks/README.md).

## 실행 파일

`build/TankGame.exe` 를 더블클릭하면 바로 실행된다(Godot 설치 불필요, 데이터 내장).
다시 빌드하려면 Godot 에디터에서 프로젝트 → 내보내기 → "Windows Desktop", 또는
`godot --headless --path . --export-release "Windows Desktop" build/TankGame.exe`
(Godot 4.3 Windows 내보내기 템플릿 필요).

## 장갑 시험장 (F1, 또는 `tanks/lab/armor_lab.tscn`)

- 표적 전차의 장갑 구역을 색으로 표시: **두께 / 현재 시점 기준 유효장갑 / 선택 탄종·거리의 관통확률**
- 탄종 9종(전차별 3종)과 거리(50~2500m), 표적 차체·포탑 회전, 시점 프리셋(정면·티타임 35°·측면·후면)
- 좌클릭 = 그 지점에 사격(카메라 방향이 사격 방향). 결과: 구역, 입사각, 유효장갑, 관통력 굴림값, 피해 내역, 승무원·모듈 상태
- "현재 시점 200발": 실루엣 전체에 무작위로 쏴서 구역별 관통률·한 발 전투불능률과 탄착 분포 표시
- 내부 보기: 승무원(파랑/노랑 부상/검정 전사)과 모듈(주황/빨강 손상/회색 파괴) 배치
- 아래 그래프: 그 포의 탄종별 거리-관통력 곡선 + 마우스가 가리키는 구역의 유효장갑선

## 실행

```
godot --path .                                                     # 게임 실행(키보드 조작)
godot --headless --path . -s res://tanks/tests/run_tank_tests.gd   # 장갑·피해·모듈 검증
godot --headless --path . -s res://tanks/tests/run_trait_tests.gd  # 전차별 특성(기동·헐다운·안정장치·조준·탄도)
godot --headless --path . -s res://controls/tests/run_sim_smoke.gd # 주행·선회·사격 통합 테스트
godot --headless --path . -s res://controls/tests/run_view_tests.gd # 포수·전차장·자유 시선 시점, 포 고정
godot --headless --path . -s res://map/tests/run_map_tests.gd      # 맵 재현성·차단물별 시야 판정·시선 통계
godot --headless --fixed-fps 30 --path . -s res://recording/tests/run_record_tests.gd  # 기록·리플레이·보고서 검증
godot --headless --fixed-fps 30 --path . -- --episodes=10           # AI 끼리 10판 연속(빠르게) 기록
```

경기 기록·보고서: `user://logs/replays/ep####_<시각>/` (events.jsonl, report.html, CSV),
에피소드 요약: `user://logs/episodes.csv`
(Windows: `%APPDATA%\Godot\app_userdata\Tank Game Machine Learning\logs\`, 게임에서 F6)

## 맵과 시야

`HillMap` (map/hill_map.gd) 은 `map_seed` 하나로 같은 지형을 다시 만든다. 경기 기록에는 지형 격자와 모든 배치가 통째로 저장되어(`to_record`/`load_record`) 생성기가 바뀌어도 지난 경기를 재구성할 수 있다. 1200m 정사각형, 스폰은 Z ±450.

| 요소 | 포탄 | 시야 | 전술적 의미 |
|---|---|---|---|
| 능선 3개 (진격축을 가로지름, 안부 통로 1~2곳) | 차단 | 차단 | 반사면에 차체를 숨기는 hull-down, 능선 넘을 때 노출 |
| 숲 8곳 (절반은 양 측면) | 줄기만 | 25m 통과 시 10% | 은폐·매복, 측면 우회로 차폐 |
| 수목선 (능선 마루) | 줄기만 | 감쇠 | 마루 위 은폐 사격 진지 |
| 생울타리 (흙둑 1.2m + 덤불 3.5m, 틈 있음) | 흙둑 | 거의 차단 | 보카주식 근접 매복 |
| 돌담 1.4m | 차단 | 차체만 가림 | 포탑만 내미는 hull-down |
| 마을(교차로) + 외딴 농가 | 차단 | 차단 | 시가지 엄폐 |
| 바위 무더기, 외딴 나무 | 차단 / 수관 감쇠 | | 소규모 엄폐 |

**시야 판정** (`LineOfSight`, AI 와 HUD 가 같은 함수 사용):
관측자 전차장 눈높이 → 표적의 표본점 6곳(포탑 위·중앙, 차체 앞·뒤·좌·우)으로 시선을 긋고,
지형·건물·바위·흙둑·돌담·나무줄기·다른 전차(레이어 1·2)는 물리 레이캐스트로 완전 차단,
숲·덤불·수관(레이어 4)은 통과 거리로 투과율 `exp(-밀도×거리)` 를 구한다.
`visible_fraction` = 표본점 투과율 평균. 탐지 = `visible_fraction ≥ 0.12` 이고
`거리 ≤ 1400m × 표적 크기 × 이동(최대 1.5배) × 관측자(T-34 전차장 포수 겸임 0.8) × visible_fraction`.

```gdscript
var seen := LineOfSight.spotted_enemies(map, my_tank, tanks)  # [{target, detected, visible_fraction, distance, blocked_by, ...}]
var r := LineOfSight.ray(map, from, to)                        # 임의 두 점 사이 {transmittance, blocked_by}
map.cover_at(pos)                                              # 그 지점을 덮는 잎 볼륨 종류(숲 속인가 등)
```

시드 1 맵 통계(임의 두 지점 200~900m, 눈높이 2.7m → 1.5m): 시선 트임 평지 100% → 지형만 25% → 전체 약 10% (+부분 가림 7%).
시선 1회 약 36µs (전차 6대 전원 상호 판정 ≈ 6.5ms).

거리 표시(`RangeGrid`, 화면 전용): 100m 격자(500m 마다 노란 굵은 선) + 중심선 좌표 라벨, 조종 전차 주위 100m~1km 거리 링(포탑 방향에 거리 라벨), 지면 50m 체커 무늬.

## 충돌 레이어

1 = 지형·바위·나무줄기·건물·흙둑·돌담(포탄·시야 차단), 2 = 전차, 4 = 숲·덤불·수관(시야만 차단, 포탄 통과)

## 다음 단계(예정)

- AI 관측 벡터에 `LineOfSight.spotted_enemies` 결과 연결
- 자기대전 학습 환경(에피소드 리셋, 보상, 고속 스텝)
- 학습 AI 연결: `MatchRecorder.log_decision()` 로 관측·행동·판단 기록, `RewardModel` 로 보상 계산(이미 준비됨)
