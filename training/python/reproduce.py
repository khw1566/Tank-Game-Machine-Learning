"""지난 학습 에피소드를 똑같이 다시 돌린다(재현 파일 = 설정·시드·행동).

  python reproduce.py <episode.json> --godot <godot 또는 TankGame.exe> [--project <폴더>] [--out-dir <폴더>] [--log-obs 1]

결과: <out-dir>/replays/ep####_*/ 에 events.jsonl(전체 리플레이, 결정마다 관측 벡터 포함)·report.html·reproduce.json.
--out-dir 을 생략하면 게임의 user://logs 에 저장되어 게임에서 F3 리플레이 뷰어로 바로 열 수 있다.
끝 상태 해시가 원래와 같으면 "OK", 다르면 "MISMATCH"(종료 코드 3) — 엔진·코드 버전이 다르면 달라질 수 있다.
"""
import argparse
import json
import subprocess
import sys
from pathlib import Path

ap = argparse.ArgumentParser()
ap.add_argument("episode")
ap.add_argument("--godot", required=True)
ap.add_argument("--project", default=None)
ap.add_argument("--out-dir", default="")
ap.add_argument("--log-obs", type=int, default=1, help="관측 벡터를 결정 기록 몇 번마다 남길지(1 = 매번, 0 = 끔)")
a = ap.parse_args()
ep = Path(a.episode).resolve()
d = json.loads(ep.read_text(encoding="utf-8"))
print(f"{d['config'].get('uid')}: 단계 {d['config'].get('stage')}, 시드 {d['config'].get('seed')}, "
      f"정책 {d['config'].get('meta', {}).get('policies')}, 원래 엔진 {d.get('engine')}")


def godot_user_logs() -> Path:
    """게임의 user://logs (F3 리플레이 뷰어가 여는 곳)"""
    import os
    name = "Tank Game Machine Learning"
    if sys.platform.startswith("win"):
        base = Path(os.environ.get("APPDATA", Path.home() / "AppData/Roaming")) / "Godot/app_userdata" / name
    elif sys.platform == "darwin":
        base = Path.home() / "Library/Application Support/Godot/app_userdata" / name
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local/share")) / "godot/app_userdata" / name
    return base / "logs"


out = Path(a.out_dir).resolve() if a.out_dir else godot_user_logs()
cmd = [a.godot, "--headless", "--fixed-fps", "30"]
if a.project:
    cmd += ["--path", a.project]
cmd += ["--", f"--reproduce={ep}", f"--log-obs={a.log_obs}", f"--out-dir={out}"]
r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
# 결과는 표준출력 대신 reproduce.json 에서 읽는다(Windows GUI exe 는 표준출력이 안 나올 수 있음)
runs = sorted((out / "replays").glob("ep*/reproduce.json"), key=lambda p: p.stat().st_mtime)
if runs:
    res = json.loads(runs[-1].read_text(encoding="utf-8"))
    print(("OK — 원래 에피소드와 같음" if res["ok"] else "MISMATCH — 원래와 다름"),
          f"(끝 상태 해시 {res['final_hash']} / 원래 {res['expected_hash']})")
    print("리플레이·보고서:", runs[-1].parent)
else:
    print("재현 결과를 찾지 못함. Godot 출력:")
    print(r.stdout[-2000:], r.stderr[-2000:])
sys.exit(r.returncode)
