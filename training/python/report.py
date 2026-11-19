"""학습 보고서(HTML 한 장, 외부 라이브러리 없음): 단계별 학습 곡선·승급 기록·단계 통계·기록된 리플레이 목록.

  python report.py runs/<run>            → runs/<run>/training_report.html
"""
from __future__ import annotations

import csv
import html
import json
import os
import sys
from collections import defaultdict
from pathlib import Path

from tankrl.curriculum import STAGE_IDS
from tankrl.objectives import ObjectiveIndex, objective_color

COLORS = ["#2a6fdb", "#d9534f", "#3c9d4e", "#e08a1e", "#8e5bd0", "#1aa3a3", "#b5487a", "#6b7b2a", "#555"]
TANK_LABEL = {"tiger1": "티거 I", "sherman75": "셔먼 76mm", "t34_76": "T-34-85"}
STAGE_LABEL = {"drive": "주행", "drive_terrain": "지형 주행", "gunnery_static": "정지 표적 사격",
               "gunnery_moving": "이동 표적 사격", "gunnery_search": "수색·사격", "duel_scripted": "1대1 vs 규칙 AI",
               "duel_selfplay": "1대1 자기대전", "team_scripted": "팀전 vs 규칙 AI", "team_selfplay": "팀 자기대전", "final_battle": "최종전 1 대 6"}


def rolling(xs, w):
    out, s, q = [], 0.0, []
    for x in xs:
        q.append(x)
        s += x
        if len(q) > w:
            s -= q.pop(0)
        out.append(s / len(q))
    return out


def svg_chart(series, title, ylabel, width=900, height=260, ymin=None, ymax=None, vlines=()):
    """series: [(label, color, [(x, y)…])], vlines: [(x, label)]"""
    pts = [p for _, _, s in series for p in s]
    if not pts:
        return f"<p class=muted>{html.escape(title)}: 자료 없음</p>"
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    y0 = min(p[1] for p in pts) if ymin is None else ymin
    y1 = max(p[1] for p in pts) if ymax is None else ymax
    if x1 == x0:
        x1 = x0 + 1
    if y1 == y0:
        y1 = y0 + 1
    L, R, T, B = 60, 10, 28, 30
    W, H = width - L - R, height - T - B
    sx = lambda x: L + (x - x0) / (x1 - x0) * W
    sy = lambda y: T + H - (y - y0) / (y1 - y0) * H
    out = [f'<svg viewBox="0 0 {width} {height}" class=chart role=img aria-label="{html.escape(title)}">',
           f'<text x="{L}" y="17" class=ct>{html.escape(title)}</text>']
    for k in range(5):
        yv = y0 + (y1 - y0) * k / 4
        out.append(f'<line x1="{L}" x2="{L + W}" y1="{sy(yv):.1f}" y2="{sy(yv):.1f}" class=grid />'
                   f'<text x="{L - 6}" y="{sy(yv) + 4:.1f}" class=ax text-anchor=end>{yv:.3g}</text>')
    for k in range(6):
        xv = x0 + (x1 - x0) * k / 5
        out.append(f'<text x="{sx(xv):.1f}" y="{T + H + 18}" class=ax text-anchor=middle>{xv:,.0f}</text>')
    for xv, lab in vlines:
        out.append(f'<line x1="{sx(xv):.1f}" x2="{sx(xv):.1f}" y1="{T}" y2="{T + H}" class=vl />'
                   f'<text x="{sx(xv) + 3:.1f}" y="{T + 10}" class=vt>{html.escape(lab)}</text>')
    for lab, col, s in series:
        if not s:
            continue
        d = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in s)
        out.append(f'<polyline points="{d}" fill=none stroke="{col}" stroke-width=1.8><title>{html.escape(lab)}</title></polyline>')
        if len(s) == 1:
            out.append(f'<circle cx="{sx(s[0][0]):.1f}" cy="{sy(s[0][1]):.1f}" r="2.5" fill="{col}"/>')
    out.append(f'<text x="12" y="{T + H / 2}" class=ax transform="rotate(-90 12 {T + H / 2})" text-anchor=middle>{html.escape(ylabel)}</text>')
    out.append("</svg><div class=objective-legend>" + "".join(
        f'<span><i style="background:{col}"></i>{html.escape(lab)}</span>' for lab, col, points in series if points) + "</div>")
    return "".join(out)


def build(run_dir: Path) -> Path:
    sources_file = run_dir / 'history_sources.json'
    sources = json.loads(sources_file.read_text(encoding='utf-8')).get('sources', []) if sources_file.exists() else []
    directories = [run_dir / source['path'] for source in sources] + [run_dir]
    unique = {}
    objectives = ObjectiveIndex()
    for directory in directories:
        terrain_file = directory / 'terrain_progress.csv'
        terrain = {}
        if terrain_file.exists():
            with terrain_file.open(encoding='utf-8-sig', newline='') as f:
                terrain = {(r['uid'], r.get('global_step')): r for r in csv.DictReader(f)}
        progress = directory / 'progress.csv'
        if progress.exists():
            with progress.open(encoding='utf-8-sig', newline='') as f:
                for row in csv.DictReader(f):
                    row = objectives.annotate(row, directory, terrain.get((row.get('uid'), row.get('global_step'))))
                    unique[(row.get('uid') or str(row), row.get('final_hash', ''))] = row
    rows = sorted(unique.values(), key=lambda row: float(row.get('wall_time') or 0))
    promos = []
    for directory in directories:
        if (directory / 'curriculum_log.jsonl').exists():
            promos.extend(json.loads(line) for line in (directory / 'curriculum_log.jsonl').read_text(encoding='utf-8').splitlines() if line.strip())
    promos = list({json.dumps(event, sort_keys=True): event for event in promos}.values())
    manifest = json.loads((run_dir / "run.json").read_text(encoding="utf-8")) if (run_dir / "run.json").exists() else {}
    by_tank = defaultdict(list)
    for r in rows:
        by_tank[r["tank"]].append(r)
    parts = [f"<h1>학습 보고서 — {html.escape(run_dir.name)}</h1>"]
    sess = manifest.get("sessions", [])
    if sess:
        s0, s1 = sess[0], sess[-1]
        parts.append(f"<p class=muted>시작 {s0.get('started')} · 세션 {len(sess)}회 · git {s1.get('git_commit', '')[:10]} · "
                     f"Godot {html.escape(s1.get('godot', ''))} · torch {s1.get('torch')} · SB3 {s1.get('stable_baselines3')}</p>")
    parts.append("<table><tr><th>전차</th><th>에피소드</th><th>결정 스텝</th><th>현재 단계</th><th>최근 100 성공률</th></tr>")
    for tank, rs in by_tank.items():
        cur = rs[-1]["current_stage"]
        recent = [int(r["success"]) for r in rs if r["stage"] == cur][-100:]
        parts.append(f"<tr><td>{TANK_LABEL.get(tank, tank)}</td><td>{len(rs):,}</td><td>{int(rs[-1]['global_step']):,}</td>"
                     f"<td>{STAGE_LABEL.get(cur, cur)}</td><td>{(sum(recent) / len(recent) if recent else 0):.2f}</td></tr>")
    parts.append("</table>")
    for tank, rs in by_tank.items():
        parts.append(f"<h2>{TANK_LABEL.get(tank, tank)}</h2>")
        tp = [p for p in promos if p.get("tank") == tank]
        vl = [(p["global_step"], "→" + STAGE_LABEL.get(p["to"], p["to"])) for p in tp]
        per = defaultdict(list)
        for r in rs:
            per[r["objective"]].append(r)
        succ, ret, dist, length = [], [], [], []
        for sid in per:
            sr = per.get(sid)
            if not sr:
                continue
            info = objectives.catalog[sid]
            col = info["color"]
            xs = [int(r["global_step"]) for r in sr]
            lab = STAGE_LABEL.get(info["stage"], info["stage"]) + " · " + info["label"]
            succ.append((lab, col, list(zip(xs, rolling([int(r["success"]) for r in sr], 100)))))
            ret.append((lab, col, list(zip(xs, rolling([float(r["return"]) for r in sr], 100)))))
            length.append((lab, col, list(zip(xs, rolling([float(r["duration_s"]) for r in sr], 100)))))
        parts.append(svg_chart(succ, "세부 목표별 성공률(최근 100 에피소드 이동평균)", "성공률", ymin=0, ymax=1, vlines=vl))
        parts.append(svg_chart(ret, "세부 목표별 에피소드 보상(이동평균 100)", "보상", vlines=vl))
        parts.append(svg_chart(length, "세부 목표별 에피소드 길이(초, 이동평균 100)", "초", vlines=vl))
        parts.append("<h3>세부 목표 통계</h3><table><tr><th>세부 목표</th><th>에피소드</th><th>성공률</th><th>마지막 100</th>"
                     "<th>평균 보상</th><th>발사</th><th>명중/발사</th><th>관통</th><th>격파</th><th>평균 스폰 거리</th><th>종료 사유</th></tr>")
        for sid in per:
            sr = per.get(sid)
            if not sr:
                continue
            info = objectives.catalog[sid]
            label = STAGE_LABEL.get(info["stage"], info["stage"]) + " · " + info["label"]
            n = len(sr)
            shots = sum(int(r["shots"]) for r in sr)
            hits = sum(int(r["hits"]) for r in sr)
            reasons = defaultdict(int)
            for r in sr:
                reasons[r["reason"]] += 1
            last = [int(r["success"]) for r in sr][-100:]
            parts.append(f"<tr><td><span style=\"color:{info['color']}\">●</span> {html.escape(label)}</td><td>{n:,}</td>"
                         f"<td>{sum(int(r['success']) for r in sr) / n:.2f}</td><td>{sum(last) / len(last):.2f}</td>"
                         f"<td>{sum(float(r['return']) for r in sr) / n:.3f}</td><td>{shots:,}</td>"
                         f"<td>{(hits / shots if shots else 0):.3f}</td><td>{sum(int(r['pens']) for r in sr):,}</td>"
                         f"<td>{sum(int(r['kills']) for r in sr):,}</td>"
                         f"<td>{sum(float(r['spawn_distance_m']) for r in sr) / n:.0f} m</td>"
                         f"<td>{', '.join(f'{k} {v}' for k, v in sorted(reasons.items(), key=lambda x: -x[1]))}</td></tr>")
        parts.append("</table>")
        if tp:
            parts.append("<h3>승급 기록</h3><table><tr><th>스텝</th><th>단계</th><th>에피소드</th><th>성공률</th><th>사유</th><th>정책</th></tr>")
            for p in tp:
                parts.append(f"<tr><td>{p['global_step']:,}</td><td>{STAGE_LABEL.get(p['from'], p['from'])} → "
                             f"{STAGE_LABEL.get(p['to'], p['to'])}</td><td>{p['episodes']}</td><td>{p['success_rate']:.2f}</td>"
                             f"<td>{'기준 통과' if p['reason'] == 'threshold' else '최대 에피소드 도달'}</td>"
                             f"<td>{html.escape(p.get('learner_policy', ''))}</td></tr>")
            parts.append("</table>")
        rec = [r for r in rs if r.get("replay_dir")]
        if rec:
            parts.append(f"<h3>전체 기록된 에피소드(리플레이·경기 보고서) — 최근 {min(len(rec), 40)}개</h3>"
                         "<table><tr><th>uid</th><th>단계</th><th>성공</th><th>보상</th><th>경기 보고서</th></tr>")
            for r in rec[-40:]:
                rd = Path(r["replay_dir"])
                rep = rd / "report.html"
                try:
                    link = os.path.relpath(rep, run_dir)
                except ValueError:
                    link = str(rep)
                info = objectives.catalog[r['objective']]
                label = STAGE_LABEL.get(info['stage'], info['stage']) + ' · ' + info['label']
                parts.append(f"<tr><td>{html.escape(r['uid'])}</td><td><span style=\"color:{info['color']}\">●</span> {html.escape(label)}</td>"
                             f"<td>{'✔' if r['success'] == '1' else '–'}</td><td>{float(r['return']):.3f}</td>"
                             f"<td><a href=\"{html.escape(link)}\">report.html</a></td></tr>")
            parts.append("</table>")
    individual_file = run_dir / 'individuals.json'
    if individual_file.exists():
        agents = json.loads(individual_file.read_text(encoding='utf-8'))
        log = run_dir / 'individual_progress.jsonl'
        records = [json.loads(line) for line in log.read_text(encoding='utf-8').splitlines() if line.strip()] if log.exists() else []
        curves = []
        parts.append('<h2>7개체 독립 학습</h2><p>개체마다 정책·옵티마이저·경험 버퍼와 체크포인트를 분리한다. 기존 차종 모델은 초기값으로만 복사한다.</p><table><tr><th>개체</th><th>이전 누적 스텝</th><th>개체별 추가 스텝</th><th>PPO 갱신</th><th>완료 경기</th></tr>')
        for name, state in agents.items():
            color = objective_color('agent/' + name)
            own = [r for r in records if r['agent'] == name]
            for version in sorted({r.get('reward_version', 2) for r in own}):
                curves.append((name + f' · 보상 v{version}', objective_color('agent/' + name + '/v' + str(version)), [(r['step'], r['reward']) for r in own if r.get('reward_version', 2) == version]))
            parts.append(f'<tr><td style="color:{color}">{html.escape(name)}</td><td>{state.get("inherited_timesteps", 0)}</td><td>{state.get("independent_steps", 0)}</td><td>{state.get("independent_updates", 0)}</td><td>{len(own)}</td></tr>')
        parts.append('</table>')
        parts.append(svg_chart(curves, '개체별 자기 보상 · 가로축은 각 개체의 누적 스텝', '보상'))
        if any(r.get('reward_components') for r in records):
            parts.append('<h3>전투 보상 구성 합계</h3><table><tr><th>개체</th><th>보상 항목</th><th>합계</th></tr>')
            for name in agents:
                totals = defaultdict(float)
                for row in records:
                    if row['agent'] == name:
                        for reason, value in row.get('reward_components', {}).items():
                            totals[reason] += value
                for reason, value in sorted(totals.items()):
                    parts.append(f'<tr><td>{html.escape(name)}</td><td>{html.escape(reason)}</td><td>{value:.4f}</td></tr>')
            parts.append('</table>')

    parts.append("<h2>재현</h2><p>모든 에피소드는 <code>episodes/env*/&lt;uid&gt;.json</code> 에 설정·시드·행동이 저장되어 있어, "
                 "<code>python reproduce.py &lt;파일&gt;</code> 로 똑같이 다시 돌려 전체 리플레이(F3 뷰어)·경기 보고서·관측 기록을 만들 수 있다. "
                 "끝 상태 해시가 같으면 원래 경기와 동일하다.</p>")
    css = """.objective-legend{display:flex;flex-wrap:wrap;gap:8px 16px;margin:0 0 20px;font-size:12px}.objective-legend span{display:inline-flex;align-items:center;gap:5px}.objective-legend i{width:12px;height:4px;display:inline-block}body{font-family:system-ui,'Malgun Gothic',sans-serif;margin:24px auto;max-width:960px;padding:0 16px;color:#222;background:#fff}
h1{font-size:22px}h2{margin-top:32px;border-bottom:1px solid #ddd;padding-bottom:4px}table{border-collapse:collapse;font-size:13px;margin:8px 0}
td,th{border:1px solid #ddd;padding:4px 8px;text-align:left}th{background:#f4f4f4}.muted{color:#777;font-size:13px}
.chart{width:100%;height:auto;margin:8px 0;background:#fcfcfc;border:1px solid #eee}.ct{font-size:13px;font-weight:600}.ax{font-size:11px;fill:#555}
.grid{stroke:#e6e6e6}.vl{stroke:#999;stroke-dasharray:4 3}.vt{font-size:10px;fill:#666}code{background:#f3f3f3;padding:1px 4px}"""
    out = run_dir / "training_report.html"
    out.write_text(f"<!doctype html><meta charset=utf-8><title>학습 보고서 {html.escape(run_dir.name)}</title><style>{css}</style>"
                   + "\n".join(parts), encoding="utf-8")
    return out


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    print(build(Path(sys.argv[1]).resolve()))
