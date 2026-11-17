"""기록된 에피소드 동선(1초 간격 위치·차체 방향)으로 학습 전차의 후진 비율을 실행·스텝 구간·단계별로 집계한다.

python -m tests.reverse_audit runs/cv4_20261117_shared runs/V4RUN-3 [--bucket 2000000]
후진 비율 = 차체 뒤쪽으로 움직인 거리 / 전체 이동 거리(1초에 0.5m 미만 움직임은 제외).
"""
import argparse
import collections
import glob
import json
import math
from pathlib import Path


def reverse_share(ep: dict) -> tuple[float, float] | None:
    rows = ep.get("paths_1hz") or []
    if len(rows) < 3:
        return None
    fwd = rev = 0.0
    for a, b in zip(rows, rows[1:]):
        dx, dz = b[1] - a[1], b[2] - a[2]
        dist = math.hypot(dx, dz)
        if dist < 0.5:
            continue
        yaw = math.radians((a[3] + b[3]) * 0.5)
        along = dx * -math.sin(yaw) + dz * -math.cos(yaw)
        if along >= 0:
            fwd += dist
        else:
            rev += dist
    total = fwd + rev
    return (rev / total, total) if total > 5 else None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--bucket", type=int, default=2_000_000)
    ap.add_argument("--limit", type=int, default=4000, help="실행마다 읽을 최대 에피소드 수(고르게 추출)")
    a = ap.parse_args()
    for run in a.runs:
        files = sorted(glob.glob(str(Path(run) / "episodes" / "env*" / "*.json")))
        step = max(1, len(files) // a.limit)
        agg = collections.defaultdict(lambda: [0, 0.0, 0.0])
        for f in files[::step]:
            try:
                ep = json.loads(Path(f).read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            cfg = ep.get("config", {})
            gs = int(cfg.get("meta", {}).get("global_step", 0))
            r = reverse_share(ep)
            if r is None:
                continue
            key = (gs // a.bucket * a.bucket, cfg.get("stage", ""))
            agg[key][0] += 1
            agg[key][1] += r[0]
            agg[key][2] += 1 if r[0] > 0.3 else 0
        print(f"== {run}  (에피소드 {len(files)}개 중 {len(files[::step])}개 표본)")
        for (b, stage), (n, s, heavy) in sorted(agg.items()):
            print(f"  {b / 1e6:6.1f}M {stage:20s} n={n:4d} 평균 후진 비율 {s / n:5.1%}  후진 30%↑ 판 {heavy / n:5.1%}")


if __name__ == "__main__":
    main()
