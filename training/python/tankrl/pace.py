"""게임 속도(학습용 공통 배율). reset 설정의 "pace" 로 Godot 에 넘기고 에피소드 파일에 그대로 남는다.

- 모든 전차에 같은 배율을 곱하므로 전차 사이의 상대적 특성은 유지된다
  (T-34 가장 빠름·후진 나쁨, 셔먼 중간·빠른 포탑, 티거 느린 기동·가장 느린 포탑).
- 설정이 없는 옛 에피소드는 배율 1(원래 규칙)로 재현된다.

  mobility      기어별 속도·후진·가속 × k (엔진 출력도 × k 라서 같은 기어를 쓰고 야지 속도도 × k).
                기동간 조준 흔들림·차체 출렁임 계수는 ÷ k 로 맞춰 기동간 사격 난이도는 그대로.
  turret        포탑 선회·포 고저 속도 × k
  detect_range  탐지 거리 × k (가려진 전차를 더 멀리서 찾는다)
  min_fraction  탐지에 필요한 최소 노출 비율(원래 0.12)
  identify_px   전차 종류·방향 식별에 필요한 화면 크기(원래 18px, 3인칭 시야에서 약 130m → 12px 은 약 200m)
  memory_s      화면 밖으로 나간 적을 기억하는 시간(원래 12초)
"""

GAME_PACE = {
    "version": 1,
    "mobility": 1.35,
    "turret": 1.5,
    "detect_range": 1.5,
    "min_fraction": 0.08,
    "identify_px": 12.0,
    "memory_s": 20.0,
}

# 비교·재현용: 원래 규칙과 같은 값
ORIGINAL_PACE = {"version": 1, "mobility": 1.0, "turret": 1.0, "detect_range": 1.0,
                 "min_fraction": 0.12, "identify_px": 18.0, "memory_s": 12.0}


def require_pace_support(hello: dict, cfg: dict) -> None:
    if "pace" in cfg and int(hello.get("pace_version", 0)) < int(cfg["pace"].get("version", 1)):
        raise RuntimeError("게임 속도(pace) 설정을 지원하지 않는 게임입니다. 최신 소스로 게임을 다시 빌드하세요.")
