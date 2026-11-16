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
| `map/` | 구릉지 + 숲 군락 + 바위 생성기(`HillMap`, 시드로 재현) |
| `tanks/lab/` | 장갑 시험장(시각화 + 관통 시험) |
| `build/` | Windows 실행 파일 출력 위치 |
| `main.tscn` / `main.gd` | 임시 메인 씬: 티거 1 vs 셔먼 3 + T-34 2, 사격 로그 기록 |

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
| Tab | 조종 전차 전환 | - |
| F1 | 장갑 시험장 열기 | - |

AI 는 `tank.control = TankControlInput.from_array([...])` 로 같은 입력을 넣는다.

같은 입력이라도 전차마다 결과가 다르다: T-34 는 후진이 5km/h 이고 전진→후진 전환에 2.5초가 걸리며,
차체가 경사를 따라 기울기 때문에 포 내림각(T-34 −5°, 티거 −8°, 셔먼 −10°)이 헐다운 가능 여부를 정한다.
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
```

사격·전투불능 기록: `user://logs/combat_<시각>.jsonl`
(Windows: `%APPDATA%\Godot\app_userdata\Tank Game Machine Learning\logs\`)

## 충돌 레이어

1 = 지형·바위·나무줄기(포탄 차단), 2 = 전차, 4 = 나무 수관(시야만 차단, 포탄 통과)

## 다음 단계(예정)

- 시야·탐지(수관/지형 차폐, `spotting_multiplier`) → AI 관측 벡터
- 자기대전 학습 환경(에피소드 리셋, 보상, 고속 스텝)
- AI 입력·판단 기록(보고서용)
