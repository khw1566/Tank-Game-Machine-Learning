"""커리큘럼 v4 학습 보고서: 단계 × 세부 변형(× 전차)별 곡선·표 + 화면 필터 + 인쇄(PDF)용 레이아웃.

report.py 가 v4 실행(run.json curriculum_version == 4)에서 호출한다. 자료는 scenario_progress.csv
(단계·변형·피격·노출 등이 이미 열로 있음)만 읽으므로 에피소드 파일을 하나하나 열지 않아 빠르다.
단계 이름·변형 설명은 그 실행의 run.json 에 저장된 단계 정의를 우선 쓴다(코드가 바뀐 뒤에도 당시 정의 그대로).
"""
from __future__ import annotations

import csv
import html
import json
import os
from collections import defaultdict
from pathlib import Path


TANK_LABEL = {"tiger1": "티거 I", "sherman75": "셔먼 75mm", "t34_76": "T-34/76"}
MODEL_LABEL = {"shared": "공통 모델", **TANK_LABEL}
TANK_DASH = {"tiger1": "", "sherman75": "7 3", "t34_76": "2 3"}
PART_TITLE = {"기동": "1부 기동", "사격": "2부 사격", "전술": "3부 전술"}
REASON = {"objective_reached": "목표 도달", "time_limit": "시간 초과", "training_time_limit": "시간 초과",
          "destroyed": "격파됨", "too_many_hits": "피격 초과", "win": "승리", "survived": "생존"}
E = html.escape
# 한 차트 안 곡선끼리 잘 구분되는 색(단계 개요·변형별 곡선). 대시보드의 색 계열과 별개로 보고서 가독성 우선.
CAT = ["#2563eb", "#dc2626", "#15803d", "#c26708", "#9333ea", "#008b8b", "#c02679", "#687b14", "#795548", "#4f46e5"]


def _f(v, d=0.0):
    try:
        return float(v)
    except (TypeError, ValueError):
        return d


def _ok(v) -> int:
    return 1 if str(v) in ("1", "1.0", "True", "true") else 0


def rolling(xs, w):
    out, s, q = [], 0.0, []
    for x in xs:
        q.append(x)
        s += x
        if len(q) > w:
            s -= q.pop(0)
        out.append(s / len(q))
    return out


def thin(pts, n=420):
    if len(pts) <= n:
        return pts
    k = len(pts) / n
    return [pts[int(i * k)] for i in range(n)] + [pts[-1]]


def fmt_step(v):
    return f"{v / 1e6:.1f}M" if abs(v) >= 1e6 else f"{v / 1e3:.0f}k" if abs(v) >= 1e3 else f"{v:,.0f}"


def chart(series, title, ylabel, *, width=900, height=250, ymin=None, ymax=None, vlines=(), hlines=(), yfmt=None,
          note=""):
    """series: dict(label, color, pts, dash='', attrs={}) · vlines: [(x, label)] · hlines: [(y, label)]
    attrs 는 곡선·범례 항목에 data-* 로 붙어 보고서 필터가 고른다."""
    pts = [p for s in series for p in s["pts"]]
    if not pts:
        return f"<p class=muted>{E(title)}: 자료 없음</p>"
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    y0 = min(p[1] for p in pts) if ymin is None else ymin
    y1 = max(p[1] for p in pts) if ymax is None else ymax
    for y, _ in hlines:
        y0, y1 = min(y0, y), max(y1, y)
    x1 = x1 if x1 > x0 else x0 + 1
    y1 = y1 if y1 > y0 else y0 + 1
    L, R, T, B = 76, 36, 30, 30
    W, H = width - L - R, height - T - B
    sx = lambda x: L + (x - x0) / (x1 - x0) * W
    sy = lambda y: T + H - (y - y0) / (y1 - y0) * H
    yf = yfmt or (lambda v: f"{v:.3g}")
    out = [f'<figure class=chartbox><svg viewBox="0 0 {width} {height}" class=chart role=img aria-label="{E(title)}">',
           f'<text x="{L}" y="18" class=ct>{E(title)}</text>']
    if note:
        out.append(f'<text x="{L + W}" y="18" class=cn text-anchor=end>{E(note)}</text>')
    for k in range(5):
        yv = y0 + (y1 - y0) * k / 4
        out.append(f'<line x1="{L}" x2="{L + W}" y1="{sy(yv):.1f}" y2="{sy(yv):.1f}" class=grid />'
                   f'<text x="{L - 6}" y="{sy(yv) + 4:.1f}" class=ax text-anchor=end>{yf(yv)}</text>')
    for k in range(6):
        xv = x0 + (x1 - x0) * k / 5
        anchor = "start" if k == 0 else "end" if k == 5 else "middle"
        out.append(f'<text x="{sx(xv):.1f}" y="{T + H + 18}" class=ax text-anchor={anchor}>{fmt_step(xv)}</text>')
    for xv, lab in vlines:
        if x0 <= xv <= x1:
            right = sx(xv) > width * .6
            label_x = sx(xv) - 4 if right else sx(xv) + 4
            anchor = "end" if right else "start"
            out.append(f'<line x1="{sx(xv):.1f}" x2="{sx(xv):.1f}" y1="{T}" y2="{T + H}" class=vl />'
                       f'<text x="{label_x:.1f}" y="{T + 10}" class=vt text-anchor={anchor}>{E(lab)}</text>')
    for yv, lab in hlines:
        out.append(f'<line x1="{L}" x2="{L + W}" y1="{sy(yv):.1f}" y2="{sy(yv):.1f}" class=hl />'
                   f'<text x="{L + W - 2}" y="{sy(yv) - 3:.1f}" class=vt text-anchor=end>{E(lab)}</text>')
    for s in series:
        if not s["pts"]:
            continue
        attrs = "".join(f' data-{k}="{E(str(v))}"' for k, v in s.get("attrs", {}).items())
        d = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in s["pts"])
        dash = f' stroke-dasharray="{s["dash"]}"' if s.get("dash") else ""
        out.append(f'<polyline points="{d}" fill=none stroke="{s["color"]}" stroke-width=1.7{dash}{attrs}>'
                   f'<title>{E(s["label"])}</title></polyline>')
        if len(s["pts"]) == 1:
            out.append(f'<circle cx="{sx(s["pts"][0][0]):.1f}" cy="{sy(s["pts"][0][1]):.1f}" r="2.5" fill="{s["color"]}"{attrs}/>')
    out.append(f'<text x="12" y="{T + H / 2}" class=ax transform="rotate(-90 12 {T + H / 2})" text-anchor=middle>{E(ylabel)}</text></svg>')
    legend = []
    for s in series:
        if not s["pts"]:
            continue
        attrs = "".join(f' data-{k}="{E(str(v))}"' for k, v in s.get("attrs", {}).items())
        sw = (f'<svg width=18 height=6><line x1=0 x2=18 y1=3 y2=3 stroke="{s["color"]}" stroke-width=2.5'
              + (f' stroke-dasharray="{s["dash"]}"' if s.get("dash") else "") + "/></svg>")
        legend.append(f'<span{attrs}>{sw}{E(s["label"])}</span>')
    out.append('<figcaption class=objective-legend>' + "".join(legend) + "</figcaption></figure>")
    return "".join(out)


def load(directories):
    """scenario_progress.csv(여러 이력 폴더) → 중복 제거·스텝 순 정렬된 행."""
    rows = {}
    for d in directories:
        f = d / "scenario_progress.csv"
        if not f.exists():
            continue
        with f.open(encoding="utf-8-sig", newline="") as src:
            for r in csv.DictReader(src):
                rows[(r.get("uid"), r.get("global_step"))] = r
    out = list(rows.values())
    out.sort(key=lambda r: _f(r.get("global_step")))
    for r in out:
        parts = (r.get("learner_policy") or "").split("/")
        r["_model"] = parts[1] if len(parts) > 2 else r.get("tank", "")
        r["_x"] = _f(r.get("global_step"))
        r["_ok"] = _ok(r.get("success"))
    return out


def stage_defs(run_dir: Path):
    manifest = {}
    try:
        manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        pass
    stages = manifest.get("stages") or []
    if not stages:
        from .curriculum_v4 import STAGES
        stages = STAGES
    return [{"id": s["id"], "part": s.get("part", ""), "scope": s.get("scope", "common"), "label": s.get("label", s["id"]),
             "lesson": s.get("lesson", ""), "learn": s.get("learn", ""), "goal": s.get("goal", ""),
             "variants": list(s.get("variants", [])), "desc": s.get("variants_desc", {}),
             "threshold": (s.get("promote") or {}).get("threshold", 0.8), "window": (s.get("promote") or {}).get("window", 40)}
            for s in stages]


def build_sections(run_dir: Path, directories, promos) -> tuple[str, dict]:
    """(본문 HTML, 필터용 메타) — 자료가 없으면 ("", {})."""
    rows = load(directories)
    if not rows:
        return "", {}
    defs = stage_defs(run_dir)
    known = {s["id"] for s in defs}
    # 정의에 없는(이전 단계 세트의) 단계도 자료가 있으면 끝에 붙인다
    for sid in dict.fromkeys(r.get("stage", "") for r in rows):
        if sid and sid not in known:
            vs = list(dict.fromkeys(r.get("variant", "") for r in rows if r.get("stage") == sid))
            defs.append({"id": sid, "part": "", "scope": "common", "label": sid, "lesson": "", "learn": "", "goal": "",
                         "variants": vs, "desc": {}, "threshold": 0.8, "window": 40})
            known.add(sid)
    by_stage = defaultdict(list)
    for r in rows:
        by_stage[r.get("stage", "")].append(r)
    defs = [s for s in defs if by_stage.get(s["id"])]
    tanks = [t for t in TANK_LABEL if any(r.get("tank") == t for r in rows)]
    tanks += sorted({r.get("tank", "") for r in rows} - set(tanks) - {""})
    v4promos = [p for p in promos if p.get("curriculum_version") == 4 or p.get("to") in known or p.get("from") in known]

    def label(sid):
        s = next((d for d in defs if d["id"] == sid), None)
        return s["label"] if s else sid

    def promo_lines(models=None):
        out = []
        for p in v4promos:
            if models and p.get("tank") not in models:
                continue
            to = p.get("to", "")
            lab = "공통 완료 → 전차별 분기" if to == "branch_tanks" else ("⑂ " + TANK_LABEL.get(p.get("tank"), p.get("tank", ""))
                                                                       if p.get("reason") == "branch" else "▶ " + label(to))
            out.append((float(p.get("global_step", 0)), lab))
        return out

    meta = {"stages": [{"id": s["id"], "label": s["label"], "variants": s["variants"]} for s in defs],
            "tanks": [{"id": t, "label": TANK_LABEL.get(t, t)} for t in tanks]}
    parts = []
    # ---------------------------------------------------------------- 요약
    parts.append("<h2 id=v4>커리큘럼 v4 — 단계 · 세부 변형별</h2>")
    parts.append(f"<p class=muted>시나리오 기록 {len(rows):,}판 · 단계 {len(defs)}개 · 성공률 곡선은 승급 판정과 같은 "
                 f"최근 {defs[0]['window'] if defs else 40}판 이동평균, 점선 가로선 = 승급 기준. 세로 점선 = 단계 변경.</p>")
    t = ["<table class=summary><thead><tr><th>단계</th><th>세부 변형</th><th class=num>판수</th><th class=num>최근 40 성공률"
         "<br><small>(가장 약한 변형×전차)</small></th><th class=num>기준</th><th>상태</th></tr></thead><tbody>"]
    for si, s in enumerate(defs):
        rs = by_stage[s["id"]]
        cells = defaultdict(list)
        for r in rs:
            cells[(r.get("variant", ""), r.get("tank", ""))].append(r["_ok"])
        rates = {k: sum(v[-s["window"]:]) / len(v[-s["window"]:]) for k, v in cells.items()}
        weakest = min(rates.items(), key=lambda kv: kv[1]) if rates else (("", ""), 0)
        passed = rates and all(len(cells[k]) >= s["window"] for k in cells) and weakest[1] >= s["threshold"]
        promoted = any(p.get("from") == s["id"] for p in v4promos)
        state = "승급함" if promoted else ("기준 통과" if passed else "학습 중")
        wk = f"{weakest[1]:.0%} <small class=muted>{E(weakest[0][0])}·{E(TANK_LABEL.get(weakest[0][1], weakest[0][1]))}</small>"
        t.append(f'<tr data-stage="{E(s["id"])}"><td><span class=dot style="background:{CAT[si % len(CAT)]}"></span>'
                 f'{E(PART_TITLE.get(s["part"], s["part"]))} · <b>{E(s["label"])}</b></td><td>{E(" / ".join(s["variants"]))}</td>'
                 f'<td class=num>{len(rs):,}</td><td class=num>{wk}</td><td class=num>{s["threshold"]:.0%}</td>'
                 f'<td class="{"ok" if promoted or passed else ""}">{state}</td></tr>')
    t.append("</tbody></table>")
    parts.append("".join(t))
    over = []
    for k, s in enumerate(defs):
        rs = by_stage[s["id"]]
        over.append({"label": s["label"], "color": CAT[k % len(CAT)], "attrs": {"stage": s["id"]},
                     "pts": thin(list(zip([r["_x"] for r in rs], rolling([r["_ok"] for r in rs], s["window"]))))})
    parts.append(chart(over, "단계별 성공률(모든 변형·전차 합산, 최근 40판 이동평균)", "성공률", ymin=0, ymax=1,
                       vlines=promo_lines(), hlines=[(defs[0]["threshold"], "승급 기준")] if defs else (),
                       yfmt=lambda v: f"{v:.0%}"))
    # ---------------------------------------------------------------- 단계별
    for si, s in enumerate(defs):
        rs = by_stage[s["id"]]
        sid, win = s["id"], s["window"]
        vl = promo_lines()
        vcol = {v: CAT[k % len(CAT)] for k, v in enumerate(s["variants"])}
        variants = [v for v in s["variants"] if any(r.get("variant") == v for r in rs)]
        variants += sorted({r.get("variant", "") for r in rs} - set(variants))
        for v in variants:
            vcol.setdefault(v, CAT[len(vcol) % len(CAT)])
        per_v = {v: [r for r in rs if r.get("variant") == v] for v in variants}
        per_vt = {(v, t): [r for r in per_v[v] if r.get("tank") == t] for v in variants for t in tanks}
        out = [f'<section class=stage-block data-stage="{E(sid)}">',
               f'<h3><span class=dot style="background:{CAT[si % len(CAT)]}"></span>{E(PART_TITLE.get(s["part"], s["part"]))} · '
               f'{E(s["label"])} <small class=muted>{E(sid)} · {len(rs):,}판</small></h3>']
        if s["lesson"] or s["goal"]:
            out.append(f'<p class=lesson>{E(s["lesson"])}' + (f'<br><span class=muted>목표: {E(s["goal"])}</span>' if s["goal"] else "") + "</p>")
        if s["desc"]:
            out.append("<ul class=variants>" + "".join(
                f'<li data-variant="{E(v)}"><span class=dot style="background:{vcol.get(v, "#666")}"></span><b>{E(v)}</b> — {E(s["desc"].get(v, ""))}</li>'
                for v in s["variants"] if v in per_v) + "</ul>")

        def series(metric, w, by_tank=False, pred=None):
            res = []
            for v in variants:
                for t in (tanks if by_tank else [None]):
                    src = per_vt[(v, t)] if by_tank else per_v[v]
                    if pred:
                        src = [r for r in src if pred(r)]
                    if not src:
                        continue
                    res.append({"label": v + (" · " + TANK_LABEL.get(t, t) if t else ""), "color": vcol[v],
                                "dash": TANK_DASH.get(t, "") if t else "", "attrs": {"variant": v, **({"tank": t} if t else {})},
                                "pts": thin(list(zip([r["_x"] for r in src], rolling([metric(r) for r in src], w))))})
            return res

        hl = [(s["threshold"], f"승급 기준 {s['threshold']:.0%}")]
        pct = lambda v: f"{v:.0%}"
        out.append(chart(series(lambda r: r["_ok"], win), f"성공률 — 세부 변형별(전차 합산, 최근 {win}판)", "성공률",
                         ymin=0, ymax=1, vlines=vl, hlines=hl, yfmt=pct))
        if len(tanks) > 1:
            out.append(f'<div class=by-tank>' + chart(series(lambda r: r["_ok"], win, by_tank=True),
                                                      f"성공률 — 세부 변형 × 전차(최근 {win}판)", "성공률", ymin=0, ymax=1,
                                                      vlines=vl, hlines=hl, yfmt=pct,
                                                      note="실선 티거 · 긴 점선 셔먼 · 짧은 점선 T-34") + "</div>")
        out.append(chart(series(lambda r: _f(r.get("return")), 100), "에피소드 보상 — 세부 변형별(이동평균 100)", "보상", vlines=vl))
        if any(_f(r.get("hits_taken")) for r in rs):
            out.append(chart(series(lambda r: _f(r.get("hits_taken")), 100), "받은 명중(피격) 수 — 세부 변형별(이동평균 100)",
                             "피격/판", ymin=0, vlines=vl))
        if any(_f(r.get("exposed_s")) for r in rs):
            out.append(chart(series(lambda r: _f(r.get("exposed_s")), 100), "적 시야 노출 시간 — 세부 변형별(초, 이동평균 100)",
                             "초", ymin=0, vlines=vl))
        if any(_f(r.get("shots")) for r in rs):
            out.append(chart(series(lambda r: _f(r.get("hits")) / _f(r.get("shots")), 100, pred=lambda r: _f(r.get("shots")) > 0),
                             "명중률 — 세부 변형별(쏜 판만, 이동평균 100)", "명중/발사", ymin=0, vlines=vl, yfmt=pct))
        # 표: 변형 × 전차
        tb = ["<table class=stats><thead><tr><th>세부 변형</th><th>전차</th><th class=num>판수</th><th class=num>전체 성공률</th>"
              f"<th class=num>최근 {win}</th><th class=num>평균 보상</th><th class=num>평균 피격</th><th class=num>노출(초)</th>"
              "<th class=num>평균 시간(초)</th><th>종료 사유</th></tr></thead><tbody>"]
        for v in variants:
            for t in tanks:
                src = per_vt[(v, t)]
                if not src:
                    continue
                n = len(src)
                last = [r["_ok"] for r in src][-win:]
                rate = sum(last) / len(last)
                reasons = defaultdict(int)
                for r in src:
                    reasons[r.get("reason", "")] += 1
                top = ", ".join(f"{E(REASON.get(k, k))} {c / n:.0%}" for k, c in sorted(reasons.items(), key=lambda x: -x[1])[:3])
                cls = "ok" if len(last) >= win and rate >= s["threshold"] else "bad" if len(last) >= win else ""
                tb.append(f'<tr data-variant="{E(v)}" data-tank="{E(t)}"><td><span class=dot style="background:{vcol[v]}"></span>{E(v)}</td>'
                          f'<td>{E(TANK_LABEL.get(t, t))}</td><td class=num>{n:,}</td><td class=num>{sum(r["_ok"] for r in src) / n:.0%}</td>'
                          f'<td class="num {cls}">{rate:.0%}</td><td class=num>{sum(_f(r.get("return")) for r in src) / n:.2f}</td>'
                          f'<td class=num>{sum(_f(r.get("hits_taken")) for r in src) / n:.2f}</td>'
                          f'<td class=num>{sum(_f(r.get("exposed_s")) for r in src) / n:.1f}</td>'
                          f'<td class=num>{sum(_f(r.get("duration_s")) for r in src) / n:.1f}</td><td>{top}</td></tr>')
        tb.append("</tbody></table>")
        out.append("".join(tb))
        sp = [p for p in v4promos if p.get("from") == sid]
        for p in sp:
            vr = p.get("variant_rates") or {}
            out.append(f'<p class=muted>승급 {fmt_step(float(p.get("global_step", 0)))} 스텝 · {MODEL_LABEL.get(p.get("tank"), p.get("tank", ""))} · '
                       f'{p.get("episodes", 0):,}판 · 가장 약한 변형 {min(vr.values()):.0%} → {E(label(p.get("to", "")))}</p>' if vr else "")
        out.append("</section>")
        parts.append("".join(out))
    # ---------------------------------------------------------------- 승급 기록
    if v4promos:
        t = ["<h3>단계 변경 기록</h3><table><thead><tr><th>스텝</th><th>모델</th><th>변경</th><th class=num>판수</th>"
             "<th class=num>성공률(최약 변형)</th><th>사유</th><th>변형 × 전차 성공률</th></tr></thead><tbody>"]
        for p in v4promos:
            vr = p.get("variant_rates") or {}
            t.append(f'<tr data-stage="{E(p.get("from", ""))}"><td class=num>{int(p.get("global_step", 0)):,}</td>'
                     f'<td>{E(MODEL_LABEL.get(p.get("tank"), p.get("tank", "")))}</td><td>{E(label(p.get("from", "")))} → '
                     f'{E("전차별 분기" if p.get("to") == "branch_tanks" else label(p.get("to", "")))}</td>'
                     f'<td class=num>{p.get("episodes", 0):,}</td><td class=num>{_f(p.get("success_rate")):.0%}</td>'
                     f'<td>{E({"threshold": "기준 통과", "manual": "수동", "branch": "분기", "max_episodes": "최대 판수"}.get(p.get("reason"), p.get("reason", "")))}</td>'
                     f'<td class=small>{E(", ".join(f"{k} {x:.0%}" for k, x in vr.items()))}</td></tr>')
        t.append("</tbody></table>")
        parts.append("".join(t))
    return "\n".join(parts), meta


def recorded_table(run_dir: Path, directories, limit=60) -> str:
    """전체 기록(리플레이·경기 보고서)이 남은 판 — progress.csv 의 replay_dir."""
    rec = {}
    for d in directories:
        f = d / "progress.csv"
        if not f.exists():
            continue
        with f.open(encoding="utf-8-sig", newline="") as src:
            for r in csv.DictReader(src):
                if r.get("replay_dir"):
                    rec[r.get("uid")] = r
    rows = sorted(rec.values(), key=lambda r: _f(r.get("global_step")))[-limit:]
    if not rows:
        return ""
    out = [f"<h3>전체 기록된 에피소드(리플레이·경기 보고서) — 최근 {len(rows)}개</h3><table class=small><thead><tr><th>스텝</th>"
           "<th>단계 · 변형</th><th>전차</th><th>결과</th><th class=num>보상</th><th>경기 보고서</th></tr></thead><tbody>"]
    for r in reversed(rows):
        stage, uid, tank = r.get("stage", ""), r.get("uid", ""), r.get("tank", "")
        variant = ""
        if stage and f"_{stage}_" in uid:
            rest = uid.split(f"_{stage}_", 1)[1]
            variant = rest[:-len(tank) - 1] if tank and rest.endswith("_" + tank) else rest
        rep = Path(r["replay_dir"]) / "report.html"
        try:
            link = os.path.relpath(rep, run_dir).replace(os.sep, "/")
        except ValueError:
            link = rep.as_uri()
        out.append(f'<tr data-stage="{E(stage)}" data-variant="{E(variant)}" data-tank="{E(tank)}"><td class=num>{int(_f(r.get("global_step"))):,}</td>'
                   f'<td>{E(stage)} · {E(variant)}</td><td>{E(TANK_LABEL.get(tank, tank))}</td>'
                   f'<td class="{"ok" if _ok(r.get("success")) else "bad"}">{"성공" if _ok(r.get("success")) else "실패"} '
                   f'<small class=muted>{E(REASON.get(r.get("reason", ""), r.get("reason", "")))}</small></td>'
                   f'<td class=num>{_f(r.get("return")):.2f}</td><td><a href="{E(link)}">report.html</a></td></tr>')
    out.append("</tbody></table>")
    return "".join(out)


FILTER_JS = r"""
(function(){
  var M = JSON.parse(document.getElementById('report-meta').textContent);
  var fs = document.getElementById('fStage'), fv = document.getElementById('fVar'), ft = document.getElementById('fTank'),
      fbt = document.getElementById('fByTank'), note = document.getElementById('filterNote');
  if (!fs) return;
  fs.innerHTML = '<option value="">전체 단계</option>' + M.stages.map(function(s){ return '<option value="'+s.id+'">'+s.label+' ('+s.id+')</option>'; }).join('');
  ft.innerHTML = '<option value="">전체 전차</option>' + M.tanks.map(function(t){ return '<option value="'+t.id+'">'+t.label+'</option>'; }).join('');
  function fillVar(){
    var s = M.stages.filter(function(x){ return x.id === fs.value; })[0];
    fv.innerHTML = '<option value="">전체 변형</option>' + (s ? s.variants.map(function(v){ return '<option>'+v+'</option>'; }).join('') : '');
    fv.disabled = !s;
  }
  function readHash(){
    var h = {}; location.hash.replace(/^#/, '').split('&').forEach(function(kv){ var p = kv.split('='); if (p[0]) h[p[0]] = decodeURIComponent(p[1] || ''); });
    return h;
  }
  function apply(write){
    var st = fs.value, va = fv.value, tk = ft.value, bt = fbt.checked;
    document.querySelectorAll('[data-stage]').forEach(function(el){ el.classList.toggle('f-hide', !!st && el.dataset.stage !== st); });
    document.querySelectorAll('[data-variant]').forEach(function(el){ el.classList.toggle('f-hide-v', !!va && el.dataset.variant !== va); });
    document.querySelectorAll('[data-tank]').forEach(function(el){ el.classList.toggle('f-hide-t', !!tk && el.dataset.tank !== tk); });
    document.querySelectorAll('.by-tank').forEach(function(el){ el.classList.toggle('f-hide-b', !bt); });
    var lab = st ? (fs.options[fs.selectedIndex].text + (va ? ' · ' + va : '')) : '전체 단계';
    note.textContent = '보기: ' + lab + ' · ' + (tk ? ft.options[ft.selectedIndex].text : '전체 전차') + (bt ? '' : ' · 변형×전차 곡선 숨김');
    if (write) { var h = []; if (st) h.push('stage=' + st); if (va) h.push('variant=' + va); if (tk) h.push('tank=' + tk); if (!bt) h.push('bytank=0');
      history.replaceState(null, '', h.length ? '#' + h.join('&') : location.pathname + location.search); }
  }
  var h = readHash();
  fs.value = h.stage || ''; fillVar(); fv.value = h.variant || ''; ft.value = h.tank || ''; fbt.checked = h.bytank !== '0';
  fs.onchange = function(){ fillVar(); apply(true); };
  fv.onchange = ft.onchange = fbt.onchange = function(){ apply(true); };
  window.addEventListener('hashchange', function(){ var h = readHash(); fs.value = h.stage || ''; fillVar(); fv.value = h.variant || ''; ft.value = h.tank || ''; fbt.checked = h.bytank !== '0'; apply(false); });
  apply(false);
})();
"""

TOOLBAR = """<div class="toolbar no-print"><b>필터</b>
<select id=fStage></select><select id=fVar></select><select id=fTank></select>
<label><input type=checkbox id=fByTank checked> 변형×전차 곡선</label>
<span class=sp></span><button type=button onclick="window.print()">인쇄 / PDF로 저장</button></div>
<p id=filterNote class="muted filter-note"></p>"""

CSS = """
.toolbar{position:sticky;top:0;z-index:5;display:flex;flex-wrap:wrap;gap:8px;align-items:center;background:#f7f9fc;border:1px solid #dde3ea;border-radius:6px;padding:8px 10px;margin:10px 0}
.toolbar select{font:inherit;padding:3px 6px}.toolbar .sp{flex:1}.toolbar button{font:inherit;padding:4px 12px;cursor:pointer}
.f-hide,.f-hide-v,.f-hide-t,.f-hide-b{display:none!important}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;margin-right:5px;vertical-align:baseline}
.stage-block{margin:22px 0 10px;padding-top:4px;border-top:1px solid #e6e9ee}.stage-block h3{margin:8px 0 4px}
.lesson{font-size:13px;margin:4px 0 6px}.variants{font-size:12.5px;margin:4px 0 8px;padding-left:4px;list-style:none;columns:2}
@media screen{table.summary,table.stats,table.small{display:block;overflow-x:auto;max-width:100%}}
.chartbox{margin:6px 0 10px}.cn{font-size:10.5px;fill:#777}.hl{stroke:#2f855a;stroke-dasharray:6 4}
td.num,th.num{text-align:right;font-variant-numeric:tabular-nums}td.ok,.ok{color:#2f855a;font-weight:600}td.bad{color:#c53030}
table.small,td.small{font-size:11.5px}.filter-note{margin:2px 0 8px}
@media print{.variants{columns:2}.filter-note{display:block}}
"""
