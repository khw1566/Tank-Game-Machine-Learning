"""탄착군(탄착점 분포) 보고서: 학습 중 모든 에피소드의 사격 기록을 모아 표적 전차 기준 그림으로 보여 준다.

자료: 학습이 매 에피소드 남기는 episodes/env*/<uid>.json 의 "shots"(명중 좌표 entry_local·부위 zone·거리·
관통/도탄, 지근탄 near_miss.local_point) 와 paths_1hz(1초 간격 위치·방향). 게임 쪽 추가 기록은 없다.

  python -m tankrl.shot_groups <run_dir>      → <run_dir>/analysis/shot_groups/report.html

출력(analysis/shot_groups/):
  report.html   그림 보고서(외부 라이브러리 없음, 범위 선택 = 전체/단계별)
  rows.csv      사격 1발 = 1줄 원자료(증분 갱신: 이미 읽은 에피소드는 다시 읽지 않는다)
  index.json    읽은 에피소드 파일 목록
  summary.json  범위별 요약 수치

학습 보고서(report.py)를 만들 때 함께 갱신되고, train.py 는 체크포인트 저장·단계 변경 때 report.py 를
낮은 우선순위의 별도 프로세스로 돌려 자동으로 갱신한다(--auto-report-min).
"""
from __future__ import annotations

import csv
import html
import json
import math
import os
import random
import re
import sys
import time
from collections import Counter, defaultdict, deque
from pathlib import Path

FORMAT_VERSION = 1
OUT_DIR = Path("analysis") / "shot_groups"

FIELDS = ["global_step", "uid", "stage", "variant", "learner_tank", "t", "shooter", "shooter_type", "shooter_role",
          "shooter_team", "target", "target_type", "target_role", "target_team", "friendly", "outcome", "zone", "x", "y", "z",
          "range_m", "range_source", "aspect_deg", "miss_m", "shell"]

TANK_LABEL = {"tiger1": "티거 I", "sherman75": "셔먼 76mm", "t34_76": "T-34-85"}
ROLE_LABEL = {"learner": "학습 전차", "opponent": "상대 모델", "rule": "규칙 AI", "ally": "아군 모델"}
ZONE_LABEL = {"hull_front_upper": "차체 전면 상부", "hull_front_lower": "차체 전면 하부",
              "hull_side_upper": "차체 측면 상부", "hull_side_lower": "차체 측면 하부", "hull_rear": "차체 후면",
              "hull_top": "차체 상판", "hull_bottom": "차체 하부", "turret_front": "포탑 전면", "turret_side": "포탑 측면",
              "turret_rear": "포탑 후면", "turret_top": "포탑 상판", "mantlet": "포방패", "gun_barrel": "포신", "track": "궤도"}
ZONE_ORDER = list(ZONE_LABEL)
OUTCOMES = ["penetration", "non_penetration", "ricochet", "near", "blocked", "miss"]
OUTCOME_LABEL = {"penetration": "관통", "non_penetration": "비관통", "ricochet": "도탄", "near": "지근탄",
                 "blocked": "지형·장애물 차단", "miss": "빗나감"}
COLOR = {"penetration": "#16796c", "non_penetration": "#bd7a17", "ricochet": "#8e5bd0", "near": "#357abd",
         "blocked": "#9aa5b1", "miss": "#cfd6dd", "friendly": "#d9534f"}
HITS = ("penetration", "non_penetration", "ricochet")
RANGE_BANDS = [(0, 100), (100, 200), (200, 300), (300, 450), (450, 10_000)]
ASPECT_BANDS = [(0, 30, "정면 0–30°"), (30, 60, "전측면 30–60°"), (60, 120, "측면 60–120°"), (120, 181, "후면 120–180°")]
# 개략 외형(balance v3 제원, tanks/tank_database.gd): 폭, 길이, 차체 바닥·지붕 높이, 포탑 폭·길이·높이·전후 위치.
# 차체 좌표: x = 좌우, y = 높이, z = 전후(−z 가 정면). 그림의 윤곽선 표시용이며 판정에는 쓰지 않는다.
HULL = {
    "tiger1": dict(w=3.56, l=6.32, y0=0.47, y1=1.87, tw=2.30, tl=2.50, th=0.95, tz=-0.15),
    "sherman75": dict(w=2.62, l=5.84, y0=0.43, y1=1.95, tw=2.10, tl=2.40, th=0.90, tz=-0.40),
    "t34_76": dict(w=3.00, l=5.92, y0=0.40, y1=1.65, tw=2.22, tl=2.60, th=0.94, tz=-0.60),
}
DEFAULT_HULL = dict(w=3.0, l=6.0, y0=0.45, y1=1.85, tw=2.1, tl=2.4, th=0.9, tz=-0.3)
POINTS_PER_PANEL = 700        # 그림 한 칸에 찍는 최근 표본 수(통계는 전체 표본)
STAT_SAMPLE = 4000            # 탄착 중심·50% 반경 계산용 표본 상한(범위·표적별)
TREND_BUCKETS = 10


# ───────────────────────── 원자료 추출 ─────────────────────────

def _f(v, nd=3):
    return "" if v is None or v == "" else f"{float(v):.{nd}f}"


def _range_band(r: float) -> int:
    for i, (a, b) in enumerate(RANGE_BANDS):
        if a <= r < b:
            return i
    return len(RANGE_BANDS) - 1


def _aspect_band(a: float) -> int:
    for i, (lo, hi, _) in enumerate(ASPECT_BANDS):
        if lo <= a < hi:
            return i
    return len(ASPECT_BANDS) - 1


def _outcome(s: dict) -> str:
    if s.get("hit"):
        if s.get("penetrated"):
            return "penetration"
        return "ricochet" if s.get("ricochet") else "non_penetration"
    if s.get("near_miss"):
        return "near"
    blocked = str(s.get("blocked_by", "") or "").lower()
    return "blocked" if blocked not in ("", "none") else "miss"


def episode_rows(d: dict) -> list[dict]:
    """에피소드 JSON 하나 → 사격 행 목록."""
    cfg = d.get("config", {}) or {}
    meta = cfg.get("meta", {}) or {}
    res = d.get("result", {}) or {}
    roles = meta.get("roles", {}) or {}
    tanks = d.get("tanks", []) or []
    names = [t.get("name", "") for t in tanks]
    info = {t.get("name", ""): t for t in tanks}
    learner = next((n for n, r in roles.items() if r == "learner"), None)
    paths = d.get("paths_1hz", []) or []
    stage = str(res.get("stage") or cfg.get("stage") or meta.get("current_stage") or "")
    variant = str(meta.get("variant") or (cfg.get("scenario") or {}).get("variant") or "")
    learner_tank = str(meta.get("learner_tank") or (info.get(learner, {}).get("tank", "") if learner else ""))
    step = int(meta.get("global_step") or 0)
    uid = str(res.get("uid") or cfg.get("uid") or "")

    def pose(name: str, t: float):
        if not paths or name not in names:
            return None
        row = paths[max(0, min(len(paths) - 1, int(round(t))))]
        k = 1 + 4 * names.index(name)
        if len(row) < k + 4:
            return None
        return float(row[k]), float(row[k + 1]), float(row[k + 2]), int(row[k + 3])

    out = []
    for s in d.get("shots", []) or []:
        shooter = str(s.get("shooter", ""))
        sinfo = info.get(shooter, {})
        steam = sinfo.get("team", "")
        outcome = _outcome(s)
        near = s.get("near_miss") or {}
        target = str(s.get("target") or "") if s.get("hit") else str(near.get("target_name") or "")
        tinfo = info.get(target, {})
        tteam = tinfo.get("team", near.get("target_team", "")) if target else ""
        friendly = "" if not target or steam == "" or tteam == "" else int(tteam == steam)
        local = s.get("entry_local") if s.get("hit") else near.get("local_point")
        x = y = z = None
        if isinstance(local, (list, tuple)) and len(local) == 3:
            x, y, z = local
        t = float(s.get("t", 0) or 0)
        rng, src = None, ""
        if s.get("hit") and s.get("distance_m") not in (None, ""):
            rng, src = float(s["distance_m"]), "measured"
        elif near.get("range_m") not in (None, ""):
            rng, src = float(near["range_m"]), "measured"
        else:
            me = pose(shooter, t)
            if me:
                best = None
                for other in names:
                    o = info.get(other, {})
                    if other == shooter or o.get("team") == steam:
                        continue
                    p = pose(other, t)
                    if p and p[3] < 2:
                        dist = math.hypot(p[0] - me[0], p[1] - me[1])
                        best = dist if best is None else min(best, dist)
                if best is not None:
                    rng, src = best, "nearest_enemy_1hz"
        aspect = None
        if target:
            me, tp = pose(shooter, t), pose(target, t)
            if me and tp:
                dx, dz = me[0] - tp[0], me[1] - tp[1]
                yaw = math.radians(tp[2])
                fx, fz = -math.sin(yaw), -math.cos(yaw)   # 차체 정면(−Z) 방향, paths_1hz yaw 는 도 단위
                n = math.hypot(dx, dz)
                if n > 1e-6:
                    aspect = math.degrees(math.acos(max(-1.0, min(1.0, (fx * dx + fz * dz) / n))))
        out.append({
            "global_step": step, "uid": uid, "stage": stage, "variant": variant, "learner_tank": learner_tank,
            "t": _f(t, 2), "shooter": shooter, "shooter_type": sinfo.get("tank", ""),
            "shooter_role": roles.get(shooter, ""), "shooter_team": steam, "target": target,
            "target_type": tinfo.get("tank", ""), "target_role": roles.get(target, "") if target else "",
            "target_team": tteam, "friendly": friendly, "outcome": outcome,
            "zone": s.get("zone", "") if s.get("hit") else "", "x": _f(x), "y": _f(y), "z": _f(z),
            "range_m": _f(rng, 1), "range_source": src, "aspect_deg": _f(aspect, 1),
            "miss_m": _f(near.get("miss_distance_m"), 2) if outcome == "near" else "",
            "shell": str(s.get("shell", ""))})
    return out


_STEP_RE = re.compile(r"_(\d{6,})_")


def _episode_files(directories) -> list[tuple[str, Path]]:
    files = []
    for directory in directories:
        root = Path(directory) / "episodes"
        if not root.is_dir():
            continue
        for env in os.scandir(root):
            if not env.is_dir():
                continue
            for e in os.scandir(env.path):
                if e.name.endswith(".json") and e.is_file():
                    files.append((f"{Path(directory).name}/{env.name}/{e.name}", Path(e.path)))

    def key(item):
        m = _STEP_RE.search(item[1].name)
        return (int(m.group(1)) if m else 0, item[0])

    files.sort(key=key)
    return files


def update_rows(run_dir: Path, directories=None, log=print) -> Path:
    """새 에피소드 파일만 읽어 rows.csv 에 덧붙인다."""
    out = Path(run_dir) / OUT_DIR
    out.mkdir(parents=True, exist_ok=True)
    rows_path, index_path = out / "rows.csv", out / "index.json"
    index = {}
    if index_path.exists() and rows_path.exists():
        try:
            index = json.loads(index_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            index = {}
    if index.get("version") != FORMAT_VERSION or index.get("fields") != FIELDS:
        index = {"version": FORMAT_VERSION, "fields": FIELDS, "files": {}}
        rows_path.unlink(missing_ok=True)
    seen = index["files"]
    todo = [(k, p) for k, p in _episode_files(directories or [run_dir]) if k not in seen]
    new_file = not rows_path.exists()
    n_rows = bad = 0
    with rows_path.open("a", encoding="utf-8", newline="") as f:
        w = csv.DictWriter(f, fieldnames=FIELDS)
        if new_file:
            w.writeheader()
        for i, (key, path) in enumerate(todo):
            try:
                d = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                bad += 1          # 아직 쓰는 중이거나 깨진 파일: 다음 갱신 때 다시 시도
                continue
            rows = episode_rows(d)
            w.writerows(rows)
            seen[key] = len(rows)
            n_rows += len(rows)
            if log and (i + 1) % 5000 == 0:
                log(f"[shot_groups] {i + 1:,}/{len(todo):,} 에피소드 읽음")
    tmp = index_path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(index, ensure_ascii=False), encoding="utf-8")
    os.replace(tmp, index_path)
    if log:
        log(f"[shot_groups] 새 에피소드 {len(todo) - bad:,}개 · 사격 {n_rows:,}발 추가 (전체 에피소드 {len(seen):,}개)")
    return rows_path


# ───────────────────────── 집계 ─────────────────────────

class Agg:
    """한 범위(전체 또는 단계)의 집계. 학습 전차가 쏜 탄(out)과 학습 전차가 맞은 탄(recv)을 따로 센다."""

    def __init__(self, step_lo: int, step_hi: int, seed: int):
        self.rng = random.Random(seed)
        self.lo, self.hi = step_lo, max(step_hi, step_lo + 1)
        self.roles = defaultdict(Counter)                     # role -> outcome(+friendly_hit) counts
        self.outcomes = Counter()                             # 학습 전차 사격 결과
        self.friendly = Counter()                             # 학습 전차 → 아군: hit/near/pen/ko? (outcome)
        self.zone = defaultdict(Counter)                      # target_type -> (zone, outcome)
        self.rband = defaultdict(Counter)                     # range band -> outcome
        self.rband_est = Counter()                            # range band -> 추정 거리 사격 수
        self.aspect = defaultdict(Counter)                    # aspect band -> outcome (명중·지근탄)
        self.shooter = defaultdict(Counter)                   # learner tank type -> outcome / friendly_hit
        self.points = defaultdict(lambda: deque(maxlen=POINTS_PER_PANEL))   # target_type -> recent (x,y,z,outcome,friendly)
        self.stat = defaultdict(list)                         # target_type -> reservoir (x,y,z,outcome)
        self.stat_n = Counter()
        self.recv_points = defaultdict(lambda: deque(maxlen=POINTS_PER_PANEL))  # learner type -> (x,y,z,outcome,friendly)
        self.recv = defaultdict(Counter)                      # learner type -> (zone, outcome)
        self.recv_aspect = defaultdict(Counter)
        self.trend = [Counter() for _ in range(TREND_BUCKETS)]
        self.trend_pts = [[] for _ in range(TREND_BUCKETS)]   # normalized (nx, ny) hostile hits+near
        self.trend_n = Counter()
        self.trend_steps = [[None, None] for _ in range(TREND_BUCKETS)]
        self.episodes = set()

    def _bucket(self, step: int) -> int:
        return max(0, min(TREND_BUCKETS - 1, int((step - self.lo) / (self.hi - self.lo) * TREND_BUCKETS)))

    def _reservoir(self, lst, n_seen, item, cap):
        if len(lst) < cap:
            lst.append(item)
        else:
            j = self.rng.randrange(n_seen)
            if j < cap:
                lst[j] = item

    def add(self, r: dict) -> None:
        role, oc = r["shooter_role"], r["outcome"]
        friendly = r["friendly"] == "1"
        self.episodes.add(r["uid"])
        self.roles[role][oc] += 1
        if friendly and oc in HITS:
            self.roles[role]["friendly_hit"] += 1
        has_xyz = r["x"] != ""
        if role == "learner":
            self.outcomes[oc] += 1
            st = r["shooter_type"]
            self.shooter[st][oc] += 1
            if friendly:
                self.friendly[oc] += 1
                if oc in HITS:
                    self.shooter[st]["friendly_hit"] += 1
            if r["range_m"] != "":
                b = _range_band(float(r["range_m"]))
                if not friendly:
                    self.rband[b][oc] += 1
                    if r["range_source"] != "measured":
                        self.rband_est[b] += 1
            if r["target_type"] and not friendly and oc in HITS:
                self.zone[r["target_type"]][(r["zone"], oc)] += 1
            if r["aspect_deg"] != "" and not friendly and oc in HITS + ("near",):
                self.aspect[_aspect_band(float(r["aspect_deg"]))][oc] += 1
            if has_xyz and r["target_type"]:
                p = (float(r["x"]), float(r["y"]), float(r["z"]), oc, friendly)
                self.points[r["target_type"]].append(p)
                if not friendly:
                    tt = r["target_type"]
                    self.stat_n[tt] += 1
                    self._reservoir(self.stat[tt], self.stat_n[tt], p, STAT_SAMPLE)
            step = int(r["global_step"] or 0)
            b = self._bucket(step)
            lohi = self.trend_steps[b]
            lohi[0] = step if lohi[0] is None else min(lohi[0], step)
            lohi[1] = step if lohi[1] is None else max(lohi[1], step)
            self.trend[b][oc] += 1
            if friendly and oc in HITS:
                self.trend[b]["friendly_hit"] += 1
            if has_xyz and not friendly and r["target_type"]:
                h = HULL.get(r["target_type"], DEFAULT_HULL)
                nx = float(r["x"]) / (h["w"] / 2)
                ny = (float(r["y"]) - (h["y0"] + h["y1"]) / 2) / ((h["y1"] - h["y0"]) / 2)
                self.trend_n[b] += 1
                self._reservoir(self.trend_pts[b], self.trend_n[b], (nx, ny, oc), 1500)
        # 학습 전차가 맞은(스친) 탄 = 피격 분포. 사격 주체는 상대·규칙 AI·아군(오사) 모두.
        if r["target_role"] == "learner" and oc in HITS + ("near",):
            lt = r["target_type"]
            if has_xyz:
                self.recv_points[lt].append((float(r["x"]), float(r["y"]), float(r["z"]), oc, friendly))
            if oc in HITS:
                self.recv[lt][(r["zone"], oc)] += 1
            if r["aspect_deg"] != "":
                self.recv_aspect[_aspect_band(float(r["aspect_deg"]))][oc] += 1


def _iter_rows(rows_path: Path):
    with rows_path.open(encoding="utf-8", newline="") as f:
        yield from csv.DictReader(f)


def aggregate(rows_path: Path) -> tuple[dict, list[str], dict]:
    """rows.csv → {범위: Agg}. 범위 = "all" 과 단계 id(처음 나온 순서)."""
    lo = hi = None
    stage_steps = {}
    for r in _iter_rows(rows_path):
        s = int(r["global_step"] or 0)
        lo = s if lo is None else min(lo, s)
        hi = s if hi is None else max(hi, s)
        st = r["stage"]
        a = stage_steps.setdefault(st, [s, s])
        a[0], a[1] = min(a[0], s), max(a[1], s)
    if lo is None:
        return {}, [], {}
    stages = sorted(stage_steps, key=lambda k: stage_steps[k][0])
    scopes = {"all": Agg(lo, hi, 1)}
    for i, st in enumerate(stages):
        scopes[st] = Agg(stage_steps[st][0], stage_steps[st][1], 2 + i)
    for r in _iter_rows(rows_path):
        scopes["all"].add(r)
        scopes[r["stage"]].add(r)
    return scopes, stages, stage_steps


# ───────────────────────── 그림 ─────────────────────────

def _esc(v) -> str:
    return html.escape(str(v))


def _pct(a, b) -> str:
    return f"{100 * a / b:.1f}%" if b else "–"


def dispersion(points) -> dict:
    """정면 투영(x, y)의 평균 탄착점(MPI)과 MPI 기준 50%·90% 반경."""
    pts = [(p[0], p[1]) for p in points]
    if not pts:
        return {}
    mx = sum(p[0] for p in pts) / len(pts)
    my = sum(p[1] for p in pts) / len(pts)
    rad = sorted(math.hypot(p[0] - mx, p[1] - my) for p in pts)
    q = lambda f: rad[min(len(rad) - 1, int(f * (len(rad) - 1) + 0.5))]
    return {"n": len(pts), "mx": mx, "my": my, "r50": q(0.5), "r90": q(0.9)}


VIEWS = {
    # name: (가로축 값, 세로축 값, 제목, 가로 설명, 세로 설명)
    "front": (lambda p: -p[0], lambda p: p[1], "정면에서 본 탄착", "← 표적 우측 · 좌측 →", "높이"),
    "side": (lambda p: p[2], lambda p: p[1], "측면에서 본 탄착", "← 정면 · 후면 →", "높이"),
    "top": (lambda p: -p[0], lambda p: -p[2], "위에서 본 탄착", "← 표적 우측 · 좌측 →", "정면 ↑"),
}


def _outline(view: str, h: dict, sx, sy) -> str:
    """개략 외형: 차체·포탑 상자와 포신."""
    w2, l2, y0, y1 = h["w"] / 2, h["l"] / 2, h["y0"], h["y1"]
    tw2, tl2, th, tz = h["tw"] / 2, h["tl"] / 2, h["th"], h["tz"]
    gy = y1 + th * 0.45
    rects, lines = [], []
    if view == "front":
        rects = [(-w2, y0, w2, y1), (-tw2, y1, tw2, y1 + th)]
        circ = (0.0, gy)
    elif view == "side":
        rects = [(-l2, y0, l2, y1), (tz - tl2, y1, tz + tl2, y1 + th)]
        lines = [((tz - tl2, gy), (tz - tl2 - 2.6, gy))]
        circ = None
    else:
        rects = [(-w2, -l2, w2, l2), (-tw2, -(tz + tl2), tw2, -(tz - tl2))]
        lines = [((0, -(tz - tl2)), (0, -(tz - tl2) + 2.6))]
        circ = None
    out = []
    for i, (a, b, c, d) in enumerate(rects):
        x0, x1 = sorted((sx(a), sx(c)))
        y_0, y_1 = sorted((sy(b), sy(d)))
        out.append(f'<rect x="{x0:.1f}" y="{y_0:.1f}" width="{x1 - x0:.1f}" height="{y_1 - y_0:.1f}" '
                   f'fill="{"#c5d2dc" if i == 0 else "#a9bac8"}" fill-opacity=".45" stroke="#6b8194" stroke-width="1.2"/>')
    for (a, b), (c, d) in lines:
        out.append(f'<line x1="{sx(a):.1f}" y1="{sy(b):.1f}" x2="{sx(c):.1f}" y2="{sy(d):.1f}" stroke="#6b8194" stroke-width="3"/>')
    if circ:
        out.append(f'<circle cx="{sx(circ[0]):.1f}" cy="{sy(circ[1]):.1f}" r="3.5" fill="#6b8194"/>')
    return "".join(out)


def scatter_svg(points, ttype: str, view: str, stats_points=None, title: str | None = None, recv=False) -> str:
    h = HULL.get(ttype, DEFAULT_HULL)
    fx, fy, vtitle, xlab, ylab = VIEWS[view]
    half = max(h["l"], h["w"]) / 2 + 4.0
    if view == "top":
        xr, yr = (-half, half), (-half, half)
    else:
        top = h["y1"] + h["th"] + 3.0
        xr = (-half, half)
        yr = (-1.5, top) if view == "front" else (-1.5, top)
        if view == "front":
            xr = (-(h["w"] / 2 + 4.0), h["w"] / 2 + 4.0)
    W, H, L, R, T, B = 300, 0, 34, 10, 26, 30
    pw = W - L - R
    ph = pw * (yr[1] - yr[0]) / (xr[1] - xr[0])
    H = int(T + ph + B)
    sx = lambda v: L + (v - xr[0]) / (xr[1] - xr[0]) * pw
    sy = lambda v: T + ph - (v - yr[0]) / (yr[1] - yr[0]) * ph
    out = [f'<svg viewBox="0 0 {W} {H}" class="sg" role="img" aria-label="{_esc(title or vtitle)}">',
           f'<text x="{L}" y="16" class="sgt">{_esc(title or vtitle)}</text>',
           f'<rect x="{L}" y="{T}" width="{pw:.1f}" height="{ph:.1f}" fill="#fbfcfd" stroke="#e1e7ee"/>']
    if view != "top":
        out.append(f'<line x1="{L}" x2="{L + pw:.1f}" y1="{sy(0):.1f}" y2="{sy(0):.1f}" stroke="#b9c4cf" stroke-dasharray="3 3"/>')
    out.append(_outline(view, h, sx, sy))
    outside = 0
    for p in points:
        X, Y = fx(p), fy(p)
        if not (xr[0] <= X <= xr[1] and yr[0] <= Y <= yr[1]):
            outside += 1
            continue
        oc, fr = p[3], p[4]
        if fr:
            out.append(f'<path d="M{sx(X) - 3:.1f},{sy(Y) - 3:.1f}l6,6m0,-6l-6,6" stroke="{COLOR["friendly"]}" stroke-width="1.6"/>')
        else:
            r = 2.0 if oc == "near" else 2.4
            out.append(f'<circle cx="{sx(X):.1f}" cy="{sy(Y):.1f}" r="{r}" fill="{COLOR[oc]}" fill-opacity="{.45 if oc == "near" else .7}"/>')
    st = dispersion([p for p in (stats_points or []) if p[3] in HITS + ("near",)]) if view == "front" else {}
    if st:
        cx, cy = sx(-st["mx"]), sy(st["my"])
        for key, dash in (("r50", ""), ("r90", ' stroke-dasharray="4 3"')):
            rr = st[key] / (xr[1] - xr[0]) * pw
            out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{rr:.1f}" fill="none" stroke="#17324d" stroke-width="1.2"{dash}/>')
        out.append(f'<path d="M{cx - 6:.1f},{cy:.1f}h12M{cx:.1f},{cy - 6:.1f}v12" stroke="#17324d" stroke-width="1.8"/>')
    out.append(f'<text x="{L + pw / 2:.1f}" y="{H - 8}" class="sga" text-anchor="middle">{_esc(xlab)} · 칸 1m</text>')
    out.append(f'<text x="{W - R}" y="16" class="sga" text-anchor="end">{len(points) - outside}점'
               + (f" · 범위 밖 {outside}" if outside else "") + "</text>")
    # 1m 눈금
    for v in range(math.ceil(xr[0]), math.floor(xr[1]) + 1):
        out.append(f'<line x1="{sx(v):.1f}" x2="{sx(v):.1f}" y1="{T + ph:.1f}" y2="{T + ph + (4 if v % 2 else 7):.1f}" stroke="#8a99a8"/>')
    for v in range(math.ceil(yr[0]), math.floor(yr[1]) + 1):
        out.append(f'<line x1="{L - (4 if v % 2 else 7)}" x2="{L}" y1="{sy(v):.1f}" y2="{sy(v):.1f}" stroke="#8a99a8"/>')
    out.append(f'<text x="8" y="{T + ph / 2:.1f}" class="sga" transform="rotate(-90 8 {T + ph / 2:.1f})" text-anchor="middle">{_esc(ylab)}</text>')
    out.append("</svg>")
    return "".join(out)


def bars_svg(rows, title: str, keys=OUTCOMES, width=900) -> str:
    """rows: [(라벨, Counter)] → 결과별로 나눈 가로 막대(막대 길이 = 발 수)."""
    rows = [(lab, c) for lab, c in rows if sum(c[k] for k in keys)]
    if not rows:
        return f"<p class=muted>{_esc(title)}: 자료 없음</p>"
    L, R, T, rowh = 150, 70, 26, 22
    H = T + rowh * len(rows) + 10
    peak = max(sum(c[k] for k in keys) for _, c in rows)
    out = [f'<svg viewBox="0 0 {width} {H}" class="chart" role="img" aria-label="{_esc(title)}">',
           f'<text x="8" y="17" class="sgt">{_esc(title)}</text>']
    for i, (lab, c) in enumerate(rows):
        y = T + i * rowh
        out.append(f'<text x="{L - 6}" y="{y + 15}" class="sga" text-anchor="end">{_esc(lab)}</text>')
        x = L
        total = sum(c[k] for k in keys)
        for k in keys:
            if not c[k]:
                continue
            w = (width - L - R) * c[k] / peak
            out.append(f'<rect x="{x:.1f}" y="{y + 3}" width="{max(w, .8):.1f}" height="{rowh - 6}" fill="{COLOR[k]}">'
                       f'<title>{_esc(lab)} · {OUTCOME_LABEL[k]} {c[k]:,}발 ({_pct(c[k], total)})</title></rect>')
            x += w
        out.append(f'<text x="{x + 5:.1f}" y="{y + 15}" class="sga">{total:,}</text>')
    out.append("</svg>")
    return "".join(out)


def line_svg(series, title: str, xs_label: str, width=900, height=230, pct=True) -> str:
    """series: [(라벨, 색, [(x, y)])]."""
    pts = [p for _, _, s in series for p in s]
    if len(pts) < 2:
        return f"<p class=muted>{_esc(title)}: 자료가 부족합니다(구간 2개 이상 필요)</p>"
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    y0, y1 = 0.0, max(p[1] for p in pts) * 1.1 or 1.0
    if x1 == x0:
        x1 = x0 + 1
    L, R, T, B = 60, 20, 26, 30
    sx = lambda v: L + (v - x0) / (x1 - x0) * (width - L - R)
    sy = lambda v: T + (height - T - B) - (v - y0) / (y1 - y0) * (height - T - B)
    out = [f'<svg viewBox="0 0 {width} {height}" class="chart" role="img" aria-label="{_esc(title)}">',
           f'<text x="8" y="17" class="sgt">{_esc(title)}</text>']
    for i in range(5):
        v = y0 + (y1 - y0) * i / 4
        out.append(f'<line x1="{L}" x2="{width - R}" y1="{sy(v):.1f}" y2="{sy(v):.1f}" stroke="#eceff3"/>'
                   f'<text x="{L - 6}" y="{sy(v) + 4:.1f}" class="sga" text-anchor="end">{(f"{100 * v:.0f}%" if pct else f"{v:.2f}")}</text>')
    for i in range(5):
        v = x0 + (x1 - x0) * i / 4
        out.append(f'<text x="{sx(v):.1f}" y="{height - 10}" class="sga" text-anchor="middle">{v / 1e6:.2f}M</text>')
    for lab, col, s in series:
        if len(s) < 1:
            continue
        d = " ".join(f"{'M' if j == 0 else 'L'}{sx(x):.1f},{sy(y):.1f}" for j, (x, y) in enumerate(s))
        out.append(f'<path d="{d}" fill="none" stroke="{col}" stroke-width="2"/>')
        out.extend(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="2.6" fill="{col}"><title>{_esc(lab)} {x:,.0f}: '
                   f'{(f"{100 * y:.1f}%" if pct else f"{y:.2f}")}</title></circle>' for x, y in s)
    out.append(f'<text x="{width - R}" y="{height - 10}" class="sga" text-anchor="end">{_esc(xs_label)}</text></svg>')
    legend = "".join(f'<span><i style="background:{c}"></i>{_esc(l)}</span>' for l, c, s in series if s)
    return "".join(out) + f'<div class="sg-legend">{legend}</div>'


def norm_scatter_svg(points, title: str) -> str:
    """표준 차체(폭·높이 ±1)로 맞춘 정면 탄착: 차종을 섞어 학습 초기와 최근을 비교."""
    W, L, T, pw = 300, 30, 24, 250
    ext = 3.0
    sx = lambda v: L + (v + ext) / (2 * ext) * pw
    sy = lambda v: T + pw - (v + ext) / (2 * ext) * pw
    out = [f'<svg viewBox="0 0 {W} {T + pw + 26}" class="sg" role="img" aria-label="{_esc(title)}">',
           f'<text x="{L}" y="16" class="sgt">{_esc(title)}</text>',
           f'<rect x="{L}" y="{T}" width="{pw}" height="{pw}" fill="#fbfcfd" stroke="#e1e7ee"/>',
           f'<rect x="{sx(-1):.1f}" y="{sy(1):.1f}" width="{sx(1) - sx(-1):.1f}" height="{sy(-1) - sy(1):.1f}" '
           f'fill="#c5d2dc" fill-opacity=".45" stroke="#6b8194"/>',
           f'<rect x="{sx(-.62):.1f}" y="{sy(2.3):.1f}" width="{sx(.62) - sx(-.62):.1f}" height="{sy(1) - sy(2.3):.1f}" '
           f'fill="#a9bac8" fill-opacity=".45" stroke="#6b8194"/>']
    shown = 0
    for nx, ny, oc in points[-POINTS_PER_PANEL:]:
        if abs(nx) <= ext and abs(ny) <= ext:
            shown += 1
            out.append(f'<circle cx="{sx(-nx):.1f}" cy="{sy(ny):.1f}" r="2.1" fill="{COLOR[oc]}" fill-opacity=".6"/>')
    st = dispersion([(nx, ny) for nx, ny, _ in points])
    if st:
        cx, cy = sx(-st["mx"]), sy(st["my"])
        out.append(f'<circle cx="{cx:.1f}" cy="{cy:.1f}" r="{st["r50"] / (2 * ext) * pw:.1f}" fill="none" stroke="#17324d" stroke-width="1.2"/>'
                   f'<path d="M{cx - 6:.1f},{cy:.1f}h12M{cx:.1f},{cy - 6:.1f}v12" stroke="#17324d" stroke-width="1.8"/>')
    out.append(f'<text x="{L + pw / 2}" y="{T + pw + 18}" class="sga" text-anchor="middle">차체 폭·높이 = ±1 · {shown}점'
               + (f" · 50% 반경 {st['r50']:.2f}" if st else "") + "</text></svg>")
    return "".join(out)


LEGEND = ('<div class="sg-legend">' + "".join(
    f'<span><i style="background:{COLOR[k]}"></i>{OUTCOME_LABEL[k]}</span>' for k in ("penetration", "non_penetration", "ricochet", "near"))
    + f'<span><b style="color:{COLOR["friendly"]}">✕</b> 아군 오사</span><span>✛ 평균 탄착점 · 실선 원 50% · 점선 원 90%</span></div>')


def _kpi(c: Counter) -> str:
    shots = sum(c[k] for k in OUTCOMES)
    hits = sum(c[k] for k in HITS)
    return (f"사격 {shots:,}발 · 명중 {hits:,} ({_pct(hits, shots)}) · 관통 {c['penetration']:,} ({_pct(c['penetration'], shots)}, "
            f"명중 중 {_pct(c['penetration'], hits)}) · 도탄 {c['ricochet']:,} · 지근탄 {c['near']:,} ({_pct(c['near'], shots)}) · "
            f"차단 {c['blocked']:,} ({_pct(c['blocked'], shots)})")


def scope_html(a: Agg, label: str) -> str:
    out = [f"<p class=kpi><b>{_esc(label)}</b> · 에피소드 {len(a.episodes):,}개</p>"]
    # 역할별 요약
    out.append("<h3>사격 주체별 요약</h3><table><tr><th>사격 주체</th><th>사격</th><th>명중률</th><th>관통/발</th>"
               "<th>관통/명중</th><th>도탄</th><th>지근탄</th><th>차단</th><th>아군 명중</th></tr>")
    for role in sorted(a.roles, key=lambda k: (k != "learner", k)):
        c = a.roles[role]
        shots = sum(c[k] for k in OUTCOMES)
        hits = sum(c[k] for k in HITS)
        out.append(f"<tr><td>{_esc(ROLE_LABEL.get(role, role or '미기록'))}</td><td>{shots:,}</td><td>{_pct(hits, shots)}</td>"
                   f"<td>{_pct(c['penetration'], shots)}</td><td>{_pct(c['penetration'], hits)}</td><td>{c['ricochet']:,}</td>"
                   f"<td>{c['near']:,}</td><td>{_pct(c['blocked'], shots)}</td><td>{c['friendly_hit']:,}</td></tr>")
    out.append("</table>")
    out.append(f"<p class=muted>학습 전차: {_kpi(a.outcomes)}</p>")

    # 1. 표적 기준 탄착군
    out.append("<h3>1. 표적 전차 기준 탄착군 — 학습 전차가 쏜 탄</h3>"
               "<p class=muted>점 하나 = 명중 1발(입사 위치) 또는 지근탄 1발(표적에 가장 가까이 지나간 점). 표적의 위치·방향을 원점으로 맞췄으며 "
               f"칸마다 최근 {POINTS_PER_PANEL}발까지 그립니다. 평균 탄착점과 원은 아군을 뺀 전체 표본(최대 {STAT_SAMPLE:,}발 무작위)으로 계산합니다.</p>" + LEGEND)
    for tt in sorted(a.points, key=lambda k: -len(a.points[k])):
        pts = list(a.points[tt])
        st = dispersion([p for p in a.stat.get(tt, []) if p[3] in HITS + ("near",)])
        hits = sum(1 for p in a.stat.get(tt, []) if p[3] in HITS)
        desc = ""
        if st:
            hh = HULL.get(tt, DEFAULT_HULL)
            center_y = (hh["y0"] + hh["y1"]) / 2
            desc = (f"평균 탄착점: 좌우 {st['mx']:+.2f}m · 높이 {st['my']:.2f}m (차체 중앙 높이 {center_y:.2f}m 대비 "
                    f"{st['my'] - center_y:+.2f}m) · 50% 반경 {st['r50']:.2f}m · 90% 반경 {st['r90']:.2f}m · 표본 {st['n']:,}발(명중 {hits:,})")
        out.append(f"<h4>표적: {_esc(TANK_LABEL.get(tt, tt))}</h4><p class=muted>{desc}</p><div class=sg-row>"
                   + "".join(scatter_svg(pts, tt, v, a.stat.get(tt, [])) for v in ("front", "side", "top")) + "</div>")
    if not a.points:
        out.append("<p class=muted>좌표가 있는 명중·지근탄 기록이 없습니다.</p>")

    # 2. 부위별
    keys = HITS
    out.append("<h3>2. 부위별 명중</h3>")
    for tt in sorted(a.zone, key=lambda k: -sum(a.zone[k].values())):
        rows = []
        for z in ZONE_ORDER + sorted({z for z, _ in a.zone[tt]} - set(ZONE_ORDER)):
            c = Counter({oc: a.zone[tt][(z, oc)] for oc in keys})
            rows.append((ZONE_LABEL.get(z, z or "부위 미기록"), c))
        out.append(bars_svg(rows, f"표적 {TANK_LABEL.get(tt, tt)} · 부위별 명중(관통·비관통·도탄)", keys))

    # 3. 거리별
    out.append("<h3>3. 거리별 사격 결과</h3><table><tr><th>거리</th><th>사격</th><th>명중률</th><th>관통/발</th>"
               "<th>지근탄</th><th>차단</th><th>거리 추정 비율</th></tr>")
    brows = []
    for i, (lo, hi) in enumerate(RANGE_BANDS):
        c = a.rband.get(i, Counter())
        shots = sum(c[k] for k in OUTCOMES)
        if not shots:
            continue
        lab = f"{lo}–{hi} m" if hi < 10_000 else f"{lo} m 이상"
        hits = sum(c[k] for k in HITS)
        out.append(f"<tr><td>{lab}</td><td>{shots:,}</td><td>{_pct(hits, shots)}</td><td>{_pct(c['penetration'], shots)}</td>"
                   f"<td>{_pct(c['near'], shots)}</td><td>{_pct(c['blocked'], shots)}</td><td>{_pct(a.rband_est[i], shots)}</td></tr>")
        brows.append((lab, c))
    out.append("</table>" + bars_svg(brows, "거리별 사격 결과(아군 제외)"))
    out.append("<p class=muted>명중·지근탄은 기록된 거리, 그 밖의 탄은 1초 간격 위치 기록으로 잰 가장 가까운 살아 있는 적까지의 거리입니다(추정).</p>")

    # 4. 입사 방향
    out.append("<h3>4. 표적 기준 사격 방향(정면·측면·후면)</h3>")
    out.append(bars_svg([(lab, a.aspect.get(i, Counter())) for i, (_, _, lab) in enumerate(ASPECT_BANDS)],
                        "학습 전차의 명중·지근탄이 표적의 어느 방향에서 왔는가", HITS + ("near",)))
    out.append("<p class=muted>사격 순간(1초 간격 기록) 표적 차체 정면과 사격 전차 방향 사이의 각도. 측면·후면 비율이 늘면 우회·측면 공격을 배운 것으로 볼 수 있습니다.</p>")

    # 5. 사격 전차별 + 아군 오사
    out.append("<h3>5. 학습 전차 차종별 사격과 아군 오사</h3><table><tr><th>차종</th><th>사격</th><th>명중률</th>"
               "<th>관통/발</th><th>도탄/명중</th><th>아군 명중</th><th>아군 명중/명중</th></tr>")
    for st_, c in sorted(a.shooter.items(), key=lambda kv: -sum(kv[1][k] for k in OUTCOMES)):
        shots = sum(c[k] for k in OUTCOMES)
        hits = sum(c[k] for k in HITS)
        out.append(f"<tr><td>{_esc(TANK_LABEL.get(st_, st_))}</td><td>{shots:,}</td><td>{_pct(hits, shots)}</td>"
                   f"<td>{_pct(c['penetration'], shots)}</td><td>{_pct(c['ricochet'], hits)}</td><td>{c['friendly_hit']:,}</td>"
                   f"<td>{_pct(c['friendly_hit'], hits)}</td></tr>")
    out.append("</table>")
    fr_hits = sum(a.friendly[k] for k in HITS)
    out.append(f"<p class=muted>아군 오사(학습 전차 → 같은 편 전차): 명중 {fr_hits:,}발(관통 {a.friendly['penetration']:,}) · "
               f"아군 근처 지근탄 {a.friendly['near']:,}발. 탄착군 그림에서는 빨간 ✕ 로 표시합니다.</p>")

    # 6. 학습 진행
    out.append("<h3>6. 학습 진행에 따른 변화</h3>")
    xs = []
    for b in range(TREND_BUCKETS):
        c = a.trend[b]
        shots = sum(c[k] for k in OUTCOMES)
        lohi = a.trend_steps[b]
        if shots >= 20 and lohi[0] is not None:
            xs.append(((lohi[0] + lohi[1]) / 2, c, shots, b))
    out.append(line_svg([
        ("명중률", "#2a6fdb", [(x, sum(c[k] for k in HITS) / n) for x, c, n, _ in xs]),
        ("관통/발", COLOR["penetration"], [(x, c["penetration"] / n) for x, c, n, _ in xs]),
        ("지근탄/발", COLOR["near"], [(x, c["near"] / n) for x, c, n, _ in xs]),
        ("차단/발", "#7c8a99", [(x, c["blocked"] / n) for x, c, n, _ in xs]),
        ("아군 명중/발", COLOR["friendly"], [(x, c["friendly_hit"] / n) for x, c, n, _ in xs]),
    ], "학습 스텝 구간별 사격 결과 비율(구간당 20발 이상)", "학습 스텝"))
    r50 = [(x, dispersion([(p[0], p[1]) for p in a.trend_pts[b]]).get("r50")) for x, _, _, b in xs if a.trend_pts[b]]
    my = [(x, dispersion([(p[0], p[1]) for p in a.trend_pts[b]]).get("my")) for x, _, _, b in xs if a.trend_pts[b]]
    out.append(line_svg([("50% 반경(표준 차체 단위)", "#17324d", [p for p in r50 if p[1] is not None]),
                         ("평균 탄착점 높이 − 차체 중앙(표준 단위, 0 이상만)", "#e08a1e", [(x, max(0.0, y)) for x, y in my if y is not None])],
                        "탄착군 크기와 평균 탄착점 높이(차체 높이의 절반 = 1)", "학습 스텝", pct=False))
    filled = [b for _, _, _, b in xs if a.trend_pts[b]]
    if len(filled) >= 2:
        first, last = filled[0], filled[-1]
        fs, ls = a.trend_steps[first], a.trend_steps[last]
        out.append("<div class=sg-row>" + norm_scatter_svg(a.trend_pts[first], f"초기 구간 {fs[0] / 1e6:.2f}–{fs[1] / 1e6:.2f}M")
                   + norm_scatter_svg(a.trend_pts[last], f"최근 구간 {ls[0] / 1e6:.2f}–{ls[1] / 1e6:.2f}M") + "</div>"
                   "<p class=muted>차종을 섞기 위해 차체 폭의 절반과 높이의 절반을 1로 맞춘 정면 투영입니다(포탑 상자는 개략). "
                   "원이 작아지고 중심이 차체 안으로 들어오면 조준이 좋아진 것입니다.</p>")

    # 7. 피격 분포
    out.append("<h3>7. 학습 전차가 맞은 위치(피격 탄착군)</h3>")
    if a.recv_points:
        for lt in sorted(a.recv_points, key=lambda k: -len(a.recv_points[k])):
            pts = list(a.recv_points[lt])
            out.append(f"<h4>학습 전차: {_esc(TANK_LABEL.get(lt, lt))}</h4><div class=sg-row>"
                       + "".join(scatter_svg(pts, lt, v, pts) for v in ("front", "side", "top")) + "</div>")
            rows = []
            for z in ZONE_ORDER:
                c = Counter({oc: a.recv[lt][(z, oc)] for oc in HITS})
                rows.append((ZONE_LABEL.get(z, z), c))
            out.append(bars_svg(rows, f"{TANK_LABEL.get(lt, lt)} 피격 부위", HITS))
        out.append(bars_svg([(lab, a.recv_aspect.get(i, Counter())) for i, (_, _, lab) in enumerate(ASPECT_BANDS)],
                            "학습 전차가 맞은(스친) 탄의 방향", HITS + ("near",)))
        out.append("<p class=muted>정면 피격 비율이 높고 포방패·전면 장갑에서 도탄이 많다면 정면을 적에게 향하는 법을 배운 것이고, "
                   "측면·후면 피격이 많으면 측면을 노출하고 있다는 뜻입니다.</p>")
    else:
        out.append("<p class=muted>학습 전차가 맞은 기록이 없습니다.</p>")
    return "".join(out)


CSS = """body{font-family:system-ui,'Malgun Gothic',sans-serif;margin:24px auto;max-width:980px;padding:0 16px;color:#222;background:#fff}
h1{font-size:22px}h2{margin-top:30px;border-bottom:1px solid #ddd;padding-bottom:4px}h3{margin-top:26px;font-size:16px}h4{margin:14px 0 2px;font-size:14px}
table{border-collapse:collapse;font-size:13px;margin:8px 0}td,th{border:1px solid #ddd;padding:4px 8px;text-align:left}th{background:#f4f4f4}
.muted{color:#666;font-size:13px}.kpi{font-size:14px}.chart{width:100%;height:auto;margin:6px 0;background:#fcfcfc;border:1px solid #eee}
.sg-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:10px;margin:6px 0}.sg{width:100%;height:auto;background:#fff;border:1px solid #eee}
.sgt{font-size:12px;font-weight:600;fill:#17324d}.sga{font-size:10px;fill:#576b80}
.sg-legend{display:flex;flex-wrap:wrap;gap:4px 14px;font-size:12px;margin:4px 0 8px}.sg-legend span{display:inline-flex;align-items:center;gap:5px}.sg-legend i{width:10px;height:10px;border-radius:50%;display:inline-block}
.scope-bar{position:sticky;top:0;background:#fff;padding:8px 0;border-bottom:1px solid #eee;z-index:2;display:flex;gap:8px;flex-wrap:wrap;align-items:center}
.scope-bar button{border:1px solid #c9d3dd;background:#f7f9fb;border-radius:4px;padding:4px 10px;cursor:pointer;font:inherit;font-size:13px}
.scope-bar button[aria-pressed=true]{background:#17324d;color:#fff;border-color:#17324d}
@media print{.scope-bar{display:none}.scope[hidden]{display:none}}"""

JS = """(()=>{const bar=document.querySelector('.scope-bar');if(!bar)return;const show=id=>{document.querySelectorAll('.scope').forEach(s=>s.hidden=s.dataset.scope!==id);
bar.querySelectorAll('button[data-scope]').forEach(b=>b.setAttribute('aria-pressed',b.dataset.scope===id));history.replaceState(null,'','#scope='+encodeURIComponent(id))};
bar.addEventListener('click',e=>{const b=e.target.closest('button[data-scope]');if(b)show(b.dataset.scope)});
const m=location.hash.match(/scope=([^&]+)/);const want=m?decodeURIComponent(m[1]):'all';show(document.querySelector(`.scope[data-scope="${CSS.escape(want)}"]`)?want:'all')})();"""


def stage_label(run_dir: Path, sid: str) -> str:
    try:
        manifest = json.loads((Path(run_dir) / "run.json").read_text(encoding="utf-8"))
        for st in manifest.get("stages", []) or []:
            if isinstance(st, dict) and st.get("id") == sid:
                return f"{sid} · {st.get('label') or st.get('name') or ''}".rstrip(" ·")
    except (OSError, ValueError):
        pass
    return sid or "단계 미기록"


def summary(a: Agg) -> dict:
    c = a.outcomes
    shots = sum(c[k] for k in OUTCOMES)
    hits = sum(c[k] for k in HITS)
    per_target = {}
    for tt, pts in a.stat.items():
        st = dispersion([p for p in pts if p[3] in HITS + ("near",)])
        if st:
            per_target[tt] = {k: round(v, 3) if isinstance(v, float) else v for k, v in st.items()}
    return {"episodes": len(a.episodes), "learner_shots": shots, "learner_hits": hits,
            "learner_outcomes": dict(c), "friendly": dict(a.friendly), "dispersion_front_m": per_target,
            "roles": {k: dict(v) for k, v in a.roles.items()}}


def build(run_dir: Path, directories=None, log=print) -> Path | None:
    """rows.csv 를 갱신하고 report.html·summary.json 을 다시 만든다. 사격 기록이 없으면 None."""
    run_dir = Path(run_dir)
    t0 = time.time()
    rows_path = update_rows(run_dir, directories, log=log)
    scopes, stages, stage_steps = aggregate(rows_path)
    if not scopes:
        return None
    out_dir = run_dir / OUT_DIR
    labels = {"all": "전체"}
    labels.update({s: stage_label(run_dir, s) for s in stages})
    blocks, buttons = [], []
    for key, a in scopes.items():
        buttons.append(f'<button type=button data-scope="{_esc(key)}" aria-pressed=false>{_esc(labels[key])}</button>')
        blocks.append(f'<section class=scope data-scope="{_esc(key)}"{" hidden" if key != "all" else ""}>'
                      f"<h2>{_esc(labels[key])}</h2>{scope_html(a, labels[key])}</section>")
    head = (f"<!doctype html><html lang=ko><head><meta charset=utf-8><meta name=viewport content=\"width=device-width,initial-scale=1\">"
            f"<title>탄착군 보고서 {_esc(run_dir.name)}</title><style>{CSS}</style></head><body>"
            f"<h1>탄착군 보고서 — {_esc(run_dir.name)}</h1>"
            f"<p class=muted>만든 시각 {time.strftime('%Y-%m-%d %H:%M')} · 학습 에피소드 기록(episodes/*.json) 전체에서 모은 사격 기록 · "
            f"<a href=\"rows.csv\" download>원자료 rows.csv</a> · <a href=\"summary.json\">요약 JSON</a> · "
            f"<a href=\"../../training_report.html\">학습 보고서</a></p>"
            f"<div class=\"scope-bar\"><span class=muted>범위</span>{''.join(buttons)}"
            f"<span style=\"flex:1\"></span><button type=button onclick=\"window.print()\">인쇄 / PDF</button></div>")
    tail = (f"<h2>읽는 법과 한계</h2><ul class=muted><li>모든 학습 에피소드를 씁니다(전체 리플레이를 남긴 경기만이 아님). "
            f"좌표는 게임 판정이 기록한 표적 차체 기준 값이며, 윤곽선은 제원으로 그린 개략 외형입니다.</li>"
            f"<li>빗나감·차단 탄은 탄착 좌표가 없으므로 점으로 그리지 않고 표와 비율에만 들어갑니다. 지근탄은 표적 중심 12m 안을 지난 탄입니다.</li>"
            f"<li>사격 방향·추정 거리는 1초 간격 위치 기록으로 계산하므로 빠르게 움직일 때 수 도 정도 오차가 있습니다.</li>"
            f"<li>표본이 적은 범위(수십 발 이하)의 분포는 일반화하기 어렵습니다.</li></ul>"
            f"<script>{JS}</script></body></html>")
    page = head + "".join(blocks) + tail
    tmp = out_dir / "report.html.tmp"
    tmp.write_text(page, encoding="utf-8")
    os.replace(tmp, out_dir / "report.html")
    summ = {"run": run_dir.name, "built": time.strftime("%Y-%m-%dT%H:%M:%S"), "stages": stages,
            "stage_steps": stage_steps, "scopes": {k: summary(a) for k, a in scopes.items()}}
    tmp = out_dir / "summary.json.tmp"
    tmp.write_text(json.dumps(summ, ensure_ascii=False, indent=1), encoding="utf-8")
    os.replace(tmp, out_dir / "summary.json")
    if log:
        log(f"[shot_groups] {out_dir / 'report.html'} ({time.time() - t0:.1f}s)")
    return out_dir / "report.html"


def training_report_section(run_dir: Path) -> str:
    """학습 보고서(training_report.html)에 넣는 요약: 최근 단계의 정면 탄착군 + 링크."""
    run_dir = Path(run_dir)
    path = run_dir / OUT_DIR / "summary.json"
    if not path.exists():
        return ""
    try:
        summ = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return ""
    rows = []
    for key in ["all"] + list(summ.get("stages", [])):
        s = summ["scopes"].get(key)
        if not s:
            continue
        c = Counter(s.get("learner_outcomes", {}))
        shots = sum(c[k] for k in OUTCOMES)
        hits = sum(c[k] for k in HITS)
        disp = s.get("dispersion_front_m", {})
        disp_txt = " · ".join(f"{TANK_LABEL.get(t, t)} {d['r50']:.2f}m" for t, d in disp.items())
        fr = sum(s.get("friendly", {}).get(k, 0) for k in HITS)
        rows.append(f"<tr><td><a href=\"analysis/shot_groups/report.html#scope={html.escape(key)}\">{_esc('전체' if key == 'all' else stage_label(run_dir, key))}</a></td>"
                    f"<td>{shots:,}</td><td>{_pct(hits, shots)}</td><td>{_pct(c['penetration'], shots)}</td>"
                    f"<td>{_pct(c['ricochet'], hits)}</td><td>{_pct(c['near'], shots)}</td><td>{fr:,}</td><td>{_esc(disp_txt) or '–'}</td></tr>")
    return ("<h2>탄착군(사격 분포)</h2><p class=muted>학습 전차가 쏜 탄의 표적 기준 분포. 그림(정면·측면·위, 부위·거리·방향별, 학습 진행, 피격 분포)은 "
            "<a href=\"analysis/shot_groups/report.html\">탄착군 보고서</a>에 있습니다. 50% 반경 = 정면에서 본 평균 탄착점 기준 명중·지근탄 절반이 들어오는 원.</p>"
            "<table><tr><th>범위</th><th>사격</th><th>명중률</th><th>관통/발</th><th>도탄/명중</th><th>지근탄/발</th><th>아군 명중</th><th>50% 반경(표적별)</th></tr>"
            + "".join(rows) + "</table>")


def main(argv=None) -> int:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run_dir")
    ap.add_argument("--rebuild", action="store_true", help="rows.csv 를 지우고 모든 에피소드를 다시 읽는다")
    a = ap.parse_args(argv)
    run_dir = Path(a.run_dir).resolve()
    if a.rebuild:
        (run_dir / OUT_DIR / "index.json").unlink(missing_ok=True)
        (run_dir / OUT_DIR / "rows.csv").unlink(missing_ok=True)
    sources_file = run_dir / "history_sources.json"
    sources = json.loads(sources_file.read_text(encoding="utf-8")).get("sources", []) if sources_file.exists() else []
    out = build(run_dir, [run_dir / s["path"] for s in sources] + [run_dir])
    print(out or "사격 기록이 없습니다")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
