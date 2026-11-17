"""학습 모니터링·제어 대시보드(브라우저 GUI). 추가 패키지 없이 Python 표준 라이브러리만 쓴다(GPU 불필요).

  python dashboard.py                    → http://127.0.0.1:8765 이 자동으로 열린다
  python dashboard.py --port 8800 --runs-dir runs --no-browser

할 수 있는 것
  - 학습 시작(전차·교대·환경 수·단계·배속 제한 …), 일시정지/재개, 저장 후 중지, 지금 체크포인트
  - 환경 수 바꾸기(저장 → 같은 실행을 --resume 으로 다시 시작), 기록 간격·복습 확률·배속 제한은 실행 중 바로 반영
  - 커리큘럼 단계 수동 변경(승급 기록에 manual 로 남음)
  - 실시간: 단계·성공률(승급 기준 대비), 초당 결정·에피소드, 실시간 대비 배속, 학습 곡선(성공률·보상·명중·속도·PPO 통계)
  - 전차별 정책(단계, 체크포인트, 상대 풀), 최근 에피소드 → 리플레이 보기(게임 리플레이 뷰어)·재현 후 보기·경기 보고서

대시보드를 닫아도 학습은 계속된다(상태는 runs/<run>/status.json, 명령은 runs/<run>/control.jsonl). 다시 열면 이어서 보인다.
"""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import io
import json
import os
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from tankrl.curriculum import STAGE_IDS as V1_STAGE_IDS, STAGES as V1_STAGES  # noqa: E402
from tankrl import curriculum_v4  # noqa: E402
from tankrl.objectives import v4_color  # noqa: E402

# 기존 10단계 뒤에 커리큘럼 v4 단계를 이어 붙인다(번호가 겹치지 않게).
STAGES = V1_STAGES + curriculum_v4.STAGES
STAGE_IDS = V1_STAGE_IDS + curriculum_v4.STAGE_IDS
from tankrl.runtime import select_device  # noqa: E402
from tankrl.terrain import COURSES
from tankrl.storage import default_runs_dir
from tankrl.objectives import ObjectiveIndex, objective_color
from tankrl.control import write_json_atomic

TANKS = ["tiger1", "sherman75", "t34_76"]
MODELS = TANKS + [curriculum_v4.SHARED]   # 저장 모델 폴더: 전차별 + v4 공통 모델
# 브라우저로 보내는 에피소드 열(짧게): progress.csv 의 열 이름
EP_COLS = ["wall_time", "global_step", "env", "tank", "stage_idx", "current_stage", "success", "return",
           "decisions", "hits", "pens", "kills", "shots", "spawn_distance_m", "rec", "objective"]
RECENT_COLS = ["wall_time", "global_step", "env", "uid", "tank", "stage", "success", "reason", "winner", "return",
               "decisions", "duration_s", "spawn_distance_m", "hits", "pens", "kills", "shots", "learner_policy",
               "opponents", "episode_file", "replay_dir"]
SB3_KEYS = ["time/total_timesteps", "rollout/ep_rew_mean", "rollout/ep_len_mean", "train/entropy_loss",
            "train/value_loss", "train/policy_gradient_loss", "train/approx_kl", "train/clip_fraction",
            "train/explained_variance", "train/std", "time/fps", "curriculum/stage_idx", "curriculum/success_rate"]


REQUIRED = ["numpy", "gymnasium", "stable_baselines3", "torch"]
DEPS_CHECK = ("import importlib.util, sys, json; mods = %r; "
              "miss = [m for m in mods if importlib.util.find_spec(m) is None]; "
              "print('MISSING=' + ','.join(miss)); print('PY=' + sys.version.split()[0]); "
              "\nif not miss:\n from tankrl.runtime import hardware_info\n"
              " print('RUNTIME=' + json.dumps(hardware_info()))") % REQUIRED


def venv_python() -> Path | None:
    for p in [HERE / ".venv" / "Scripts" / "python.exe", HERE / ".venv" / "bin" / "python"]:
        if p.exists():
            return p
    return None


def default_godot() -> str:
    for p in [HERE.parents[1] / "build" / "TankGame.exe", HERE.parents[1] / "build" / "TankGame.x86_64"]:
        if p.exists():
            return str(p)
    return ""


def num(v: str):
    try:
        f = float(v)
    except (TypeError, ValueError):
        return v
    return int(f) if f.is_integer() and abs(f) < 2**53 else round(f, 4)


class CsvTail:
    """덧붙여지는 CSV 를 새로 쓰인 부분만 읽는다(학습 중 progress.csv 가 계속 자람)."""

    def __init__(self, path: Path):
        self.path = path
        self.offset = 0
        self.header: list[str] | None = None
        self.rows: list[dict] = []

    def update(self) -> int:
        try:
            size = self.path.stat().st_size
        except FileNotFoundError:
            return 0
        if size < self.offset:            # 새로 만들어짐
            self.offset, self.header, self.rows = 0, None, []
        if size == self.offset:
            return 0
        with open(self.path, "rb") as f:
            first = next(csv.reader([f.readline().decode('utf-8-sig', 'replace')]), [])
            if self.header is not None and first != self.header:
                self.offset, self.header, self.rows = 0, None, []
            f.seek(self.offset)
            data = f.read()
        end = data.rfind(b"\n") + 1
        if end == 0:
            return 0
        self.offset += end
        text = data[:end].decode("utf-8-sig", "replace")
        lines = list(csv.reader(io.StringIO(text)))
        if self.header is None and lines:
            self.header = lines.pop(0)
        n0 = len(self.rows)
        for r in lines:
            if len(r) == len(self.header):
                self.rows.append(dict(zip(self.header, r)))
        return len(self.rows) - n0


class CsvSegments:
    """Keep every PPO session; resuming must never truncate an older progress.csv."""
    def __init__(self, directories):
        self.directories = directories
        self.tails = {}
        self.rows = []

    def update(self):
        for directory in self.directories:
            for path in directory.glob('**/progress.csv'):
                self.tails.setdefault(path, CsvTail(path)).update()
        self.rows = sorted([row for tail in self.tails.values() for row in tail.rows],
                           key=lambda row: float(row.get('time/total_timesteps') or 0))


class RunWatch:
    def __init__(self, run_dir: Path):
        self.run_dir = run_dir
        self.progress = CsvTail(run_dir / "progress.csv")
        self.terrain = CsvTail(run_dir / "terrain_progress.csv")
        sources = read_json(run_dir / 'history_sources.json').get('sources', [])
        self.imports = [run_dir / source['path'] for source in sources]
        self.imported_progress = [CsvTail(directory / 'progress.csv') for directory in self.imports]
        self.imported_terrain = [CsvTail(directory / 'terrain_progress.csv') for directory in self.imports]
        self.sb3 = {t: CsvSegments([run_dir / 'sb3' / t] + [directory / 'sb3' / t for directory in self.imports]) for t in MODELS}
        self.lock = threading.Lock()
        self.first_read = True
        self.objectives = ObjectiveIndex()

    def ep_compact(self, r: dict) -> list:
        out = []
        for c in EP_COLS:
            if c == "tank":
                out.append(TANKS.index(r["tank"]) if r.get("tank") in TANKS else -1)
            elif c == "current_stage":
                out.append(STAGE_IDS.index(r[c]) if r.get(c) in STAGE_IDS else -1)
            elif c == "rec":
                out.append(1 if r.get("replay_dir") else 0)
            elif c == 'objective':
                out.append(r.get(c, ''))
            else:
                out.append(num(r.get(c, "")))
        return out

    def state(self, ep_since: int, sb3_since: dict) -> dict:
        with self.lock:
            if self.first_read:
                ep_since, sb3_since = 0, {}
                self.first_read = False
            self.progress.update()
            self.terrain.update()
            for tail in self.imported_progress + self.imported_terrain:
                tail.update()
            for t in self.sb3.values():
                t.update()
            by_uid = {}
            terrain = {(r['uid'], r.get('global_step')): r for tail in self.imported_terrain + [self.terrain] for r in tail.rows}
            for tail in self.imported_progress + [self.progress]:
                for row in tail.rows:
                    row = self.objectives.annotate(row, tail.path.parent, terrain.get((row.get('uid'), row.get('global_step'))))
                    by_uid[(row.get('uid') or str(row), row.get('final_hash', ''))] = row
            rows = sorted(by_uid.values(), key=lambda r: float(r.get('wall_time') or 0))
            ep_since = min(max(0, ep_since), len(rows))
            out = {"run": self.run_dir.name, "ep_cols": EP_COLS, "ep_total": len(rows),
                   "episodes": [self.ep_compact(r) for r in rows[ep_since:]], "ep_since": ep_since,
                   "objectives": self.objectives.catalog,
                   "recent": [{c: num(r.get(c, "")) if c not in ("uid", "episode_file", "replay_dir",
                                                                 "learner_policy", "opponents", "stage",
                                                                 "reason", "tank") else r.get(c, "")
                               for c in RECENT_COLS} | {"i": len(rows) - k, "objective": r['objective']}
                              for k, r in enumerate(reversed(rows[-60:]), start=1)],
                   "sb3": {}}
            for tank, tail in self.sb3.items():
                s = int(sb3_since.get(tank, 0))
                if tail.rows:
                    s = min(max(0, s), len(tail.rows))
                    out["sb3"][tank] = {"total": len(tail.rows), "since": s,
                                        "rows": [[num(r.get(k, "")) if r.get(k, "") != "" else None
                                                  for k in SB3_KEYS] for r in tail.rows[s:]]}
            out["sb3_keys"] = SB3_KEYS
        out['history_sources'] = [directory.name for directory in self.imports]
        out["terrain_recent"] = ([r for tail in self.imported_terrain for r in tail.rows] + self.terrain.rows)[-20:]
        out["status"] = read_json(self.run_dir / "status.json")
        out["evaluation"] = read_json(self.run_dir / 'evaluation.json').get('groups', {})
        out['individuals'] = read_json(self.run_dir / 'individuals.json')
        out['individual_progress'] = read_jsonl(self.run_dir / 'individual_progress.jsonl')
        out['individual_colors'] = {name: objective_color('agent/' + name) for name in out['individuals']}
        out['individual_curve_colors'] = {r['agent'] + '/v' + str(r.get('reward_version', 2)):
            objective_color('agent/' + r['agent'] + '/v' + str(r.get('reward_version', 2))) for r in out['individual_progress']}
        out["curriculum_log"] = read_jsonl(self.run_dir / "curriculum_log.jsonl")[-200:]
        out["v4"] = self.v4_summary(rows)
        out["tanks"] = self.tank_info()
        out["run_json"] = self.run_summary()
        log = self.run_dir / "train_log.txt"
        out["log_tail"] = tail_text(log, 6000) if log.exists() else ""
        return out

    def v4_summary(self, rows: list[dict]) -> dict | None:
        """커리큘럼 v4 지도·품질 표. 모델(공통/전차별) × 스텝 구간 × 단계:변형 × 전차의 성공률.
        학습 에피소드 + 복습 에피소드(이전 단계를 가끔 다시 푸는 판)로 계산하므로, 단계가 바뀐 뒤
        이전 단계 실력이 떨어지는지(망각)도 같은 표에서 보인다."""
        marker = '/objective:v4/'
        v4 = [r for r in rows if marker in r.get('objective', '')]
        if not v4:
            return None
        top = max(float(r.get('global_step') or 0) for r in v4)
        bucket = max(50_000, int(round(top / 30 / 50_000)) * 50_000)
        grid, recent = {}, {}
        for r in v4:
            ident = r['objective'].split(marker, 1)[1]
            tank = r.get('tank', '')
            policy = r.get('learner_policy', '')
            parts = policy.split('/')
            model = parts[1] if len(parts) > 2 else tank
            b = int(float(r.get('global_step') or 0) // bucket)
            ok = 1 if str(r.get('success')) in ('1', '1.0', 'True') else 0
            cell = grid.setdefault(model, {}).setdefault(str(b), {}).setdefault(ident + '@' + tank, [0, 0, 0.0])
            cell[0] += 1
            cell[1] += ok
            cell[2] += float(r.get('return') or 0)
            q = recent.setdefault(ident + '@' + tank, [])
            q.append(ok)
            if len(q) > 40:
                del q[0]
        stages = [{"id": s["id"], "part": s["part"], "scope": s["scope"], "label": s["label"], "variants": s["variants"],
                   "learn": s.get("learn", ""), "goal": s.get("goal", ""), "lesson": s.get("lesson", ""),
                   "variant_notes": s.get("variants_desc", {}),
                   "threshold": s["promote"]["threshold"], "window": s["promote"]["window"],
                   "color": v4_color(s["id"]),
                   "variant_colors": {v: v4_color(s["id"] + ':' + v) for v in s["variants"]}} for s in curriculum_v4.STAGES]
        models = {}
        for m in MODELS:
            c = read_json(self.run_dir / m / 'curriculum.json')
            if c.get('curriculum_version') == curriculum_v4.VERSION:
                models[m] = {"stage": c.get("stage"), "stage_idx": c.get("stage_idx"), "tanks": c.get("tanks", [m]),
                             "common_complete": c.get("common_complete", False), "branched_from": c.get("branched_from", ""),
                             "episodes_in_stage": c.get("episodes_in_stage", 0), "shaping_scale": c.get("shaping_scale")}
        branch = {m: read_json(self.run_dir / m / 'branch.json') for m in TANKS if (self.run_dir / m / 'branch.json').exists()}
        return {"bucket": bucket, "grid": grid, "recent": {k: [sum(v), len(v)] for k, v in recent.items()},
                "stages": stages, "models": models, "branch": branch, "tanks": curriculum_v4.SHARED_TANKS}

    def tank_info(self) -> dict:
        res = {}
        pool = self.run_dir.parent / "pool"
        sessions = read_json(self.run_dir / "run.json").get("sessions", [])
        if sessions and sessions[-1].get("args", {}).get("pool_dir"):
            pool = abs_path(sessions[-1]["args"]["pool_dir"])
        for t in MODELS:
            d = self.run_dir / t
            if not d.exists():
                continue
            snaps = sorted(d.glob("step_*.zip"))
            latest = d / "latest.zip"
            res[t] = {"curriculum": read_json(d / "curriculum.json"),
                      "checkpoint": read_json(d / "checkpoint.json"),
                      "saved_steps": read_json(d / "checkpoint.json").get("num_timesteps", int(snaps[-1].stem.removeprefix("step_")) if snaps else 0),
                      "snapshots": len(snaps), "last_snapshot": snaps[-1].name if snaps else "",
                      "latest_mtime": latest.stat().st_mtime if latest.exists() else None,
                      "pool": read_json(pool / t / "latest.json"),
                      "pool_snapshots": len(list((pool / t).glob("step_*.zip"))) if (pool / t).exists() else 0}
        return res

    def run_summary(self) -> dict:
        rj = read_json(self.run_dir / "run.json")
        if not rj:
            return {}
        s = (rj.get("sessions") or [{}])[-1]
        return {"sessions": len(rj.get("sessions", [])), "args": s.get("args", {}), "git_commit": s.get("git_commit"),
                "godot": s.get("godot"), "torch": s.get("torch"), "sb3": s.get("stable_baselines3"),
                "runtime": s.get("runtime", {}),
                "started": s.get("started"), "obs_size": len(rj.get("obs_labels", [])),
                "act_size": len(rj.get("action_labels", []))}


def abs_path(p: str) -> Path:
    """상대 경로는 training/python 기준(README 예시 "..\\..\\build\\TankGame.exe" 그대로 쓸 수 있게)."""
    q = Path(p.strip().strip('"'))
    return (q if q.is_absolute() else HERE / q).resolve()


def read_json(p: Path) -> dict:
    for _ in range(3):
        try:
            return json.loads(p.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return {}
        except (json.JSONDecodeError, PermissionError, OSError):
            time.sleep(0.02)
    return {}


def read_jsonl(p: Path) -> list:
    if not p.exists():
        return []
    out = []
    for line in p.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            out.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return out


def tail_text(p: Path, n: int) -> str:
    with open(p, "rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - n))
        return f.read().decode("utf-8", "replace")


class Dashboard:
    def __init__(self, runs_dir: Path):
        self.runs_dir = runs_dir.resolve()
        self.runs_dir.mkdir(parents=True, exist_ok=True)
        self.watches: dict[str, RunWatch] = {}
        self.procs: dict[str, subprocess.Popen] = {}      # 이 대시보드가 띄운 train.py
        self._records_cache: dict[str, tuple] = {}  # progress.csv 경로 -> (수정 시각, 보고서 목록)
        self.jobs: list[dict] = []                         # 재현·보고서 등 백그라운드 작업
        self.lock = threading.Lock()
        self.settings_path = self.runs_dir / "dashboard_settings.json"
        self.settings = {"godot": default_godot(), "project": "", "python": "", "device": "auto"} | read_json(self.settings_path)
        if self.settings.get('godot') and not abs_path(self.settings['godot']).is_file():
            self.settings.update(godot=default_godot(), project='')
        if self.settings.get('python') and not abs_path(self.settings['python']).is_file():
            self.settings['python'] = ''
        write_json_atomic(self.settings_path, self.settings)
        self._gpu_status = {"gpus": []}
        self._gpu_next_check = 0.0
        self._gpu_lock = threading.Lock()
        self.deps: dict = {"state": "unknown"}
        self.install_job: dict | None = None
        threading.Thread(target=self.check_deps, daemon=True).start()

    # ------------------------------------------------------------ 공통

    def run_dir(self, run: str) -> Path:
        d = (self.runs_dir / run).resolve()
        if d.parent != self.runs_dir or not run or run == "pool":
            raise ValueError(f"잘못된 실행 이름: {run}")
        return d

    def watch(self, run: str) -> RunWatch:
        with self.lock:
            if run not in self.watches:
                self.watches[run] = RunWatch(self.run_dir(run))
            return self.watches[run]

    def save_settings(self, **kw) -> None:
        self.settings.update({k: v for k, v in kw.items() if v is not None})
        self.settings_path.write_text(json.dumps(self.settings, ensure_ascii=False, indent=1), encoding="utf-8")

    def alive(self, run: str, status: dict) -> bool:
        p = self.procs.get(run)
        if p is not None:
            return p.poll() is None
        if not status or status.get("phase") == "stopped":
            return False
        age = time.time() - float(status.get("updated", 0))
        # PPO 갱신·저장 중에는 상태가 잠시 안 바뀐다
        return age < (180 if status.get("phase") in ("updating", "saving", "starting") else 20)

    def runs(self) -> list[dict]:
        out = []
        for d in sorted(self.runs_dir.iterdir(), key=lambda p: p.stat().st_mtime, reverse=True):
            if not d.is_dir() or d.name == "pool" or not ((d / "run.json").exists() or (d / "status.json").exists()
                                                          or (d / "train_log.txt").exists()):
                continue
            st = read_json(d / "status.json")
            out.append({"run": d.name, "alive": self.alive(d.name, st), "phase": st.get("phase", ""),
                        "tank": st.get("tank", ""), "steps": st.get("num_timesteps", 0),
                        "stage": (st.get("curriculum") or {}).get("stage", ""),
                        "mtime": d.stat().st_mtime})
        return out

    def records(self) -> dict:
        """모든 실행의 보고서를 한곳에: 실행별 학습·평가 보고서 + 전체 기록(리플레이)이 남은 경기의 보고서."""
        out, runs = [], []
        for d in sorted(self.runs_dir.iterdir()):
            if not d.is_dir() or d.name == "pool":
                continue
            progress = d / "progress.csv"
            v4 = read_json(d / "run.json").get("curriculum_version") == curriculum_v4.VERSION
            files = [f for f in ("training_report.html", "evaluation_report.html") if (d / f).exists()]
            if not progress.exists() and not files:
                continue
            runs.append({"run": d.name, "v4": v4, "reports": files,
                         "mtime": max((d / f).stat().st_mtime for f in files) if files else None})
            if not progress.exists():
                continue
            key = str(progress)
            mt = progress.stat().st_mtime
            if self._records_cache.get(key, (None,))[0] != mt:
                rows = []
                with progress.open(newline="", encoding="utf-8-sig") as src:
                    for r in csv.DictReader(src):
                        rd = r.get("replay_dir") or ""
                        rep_html = Path(rd) / "report.html" if rd else None
                        if not rep_html or not rep_html.exists():
                            continue
                        try:
                            rel = rep_html.resolve().relative_to(self.runs_dir).as_posix()
                        except ValueError:
                            continue
                        uid = r.get("uid", "")
                        variant = ""
                        if v4 and r.get("stage") and ("_" + r["stage"] + "_") in uid:
                            # uid = <실행>_<모델>_<번호>_<단계>_<변형>[_<전차>] (공통 모델은 전차가 붙는다)
                            rest = uid.split("_" + r["stage"] + "_", 1)[1]
                            tank_suffix = "_" + r.get("tank", "")
                            variant = rest[:-len(tank_suffix)] if r.get("tank") and rest.endswith(tank_suffix) else rest
                        rows.append({"run": d.name, "t": num(r.get("wall_time", "")), "step": num(r.get("global_step", "")),
                                     "tank": r.get("tank", ""), "stage": r.get("stage", ""), "variant": variant,
                                     "success": r.get("success") in ("1", "1.0", "True"), "reason": r.get("reason", ""),
                                     "return": num(r.get("return", "")), "dur": num(r.get("duration_s", "")),
                                     "policy": r.get("learner_policy", ""), "report": rel, "v4": v4})
                self._records_cache[key] = (mt, rows)
            out.extend(self._records_cache[key][1])
        out.sort(key=lambda r: r["t"] or 0, reverse=True)
        return {"runs": runs, "records": out}

    def info(self) -> dict:
        return {"stages": [{"id": s["id"], "kind": s["kind"], "promote": s.get("promote"),
                            "time_limit_s": s["time_limit_s"], "v4": s["id"] in curriculum_v4.STAGE_IDS,
                            "label": s.get("label", ""), "learn": s.get("learn", ""), "goal": s.get("goal", ""),
                            "lesson": s.get("lesson", ""),
                            "variant_notes": s.get("variants_desc", {})} for s in STAGES],
                "tanks": TANKS, "cpu_count": os.cpu_count() or 1, "settings": self.settings,
                "runs_dir": str(self.runs_dir), "platform": sys.platform, "deps": self.deps_info(),
                "terrain_courses": COURSES}

    # ------------------------------------------------------------ 학습용 Python·패키지

    def train_python(self) -> str:
        """학습에 쓸 Python: 설정에 적은 것 → training/python/.venv → 대시보드를 실행한 Python."""
        p = self.settings.get("python", "")
        if p and Path(p).exists():
            return str(Path(p))
        v = venv_python()
        return str(v) if v else sys.executable

    def check_deps(self) -> dict:
        py = self.train_python()
        self.deps = {"state": "checking", "python": py}
        try:
            r = subprocess.run([py, "-c", DEPS_CHECK], capture_output=True, text=True, timeout=120,
                               encoding="utf-8", errors="replace", cwd=str(HERE),
                               creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            out = dict(ln.split("=", 1) for ln in r.stdout.splitlines() if "=" in ln)
            missing = [m for m in out.get("MISSING", "").split(",") if m]
            if r.returncode != 0 or "MISSING" not in out:
                self.deps = {"state": "error", "python": py, "detail": (r.stdout + r.stderr)[-800:]}
            else:
                self.deps = {"state": "ok" if not missing else "missing", "python": py, "missing": missing,
                             "version": out.get("PY", ""), "runtime": json.loads(out.get("RUNTIME", "{}"))}
        except Exception as e:
            self.deps = {"state": "error", "python": py, "detail": str(e)}
        self.deps["venv"] = str(venv_python() or "")
        self.deps["checked"] = time.time()
        return self.deps

    def deps_info(self) -> dict:
        d = dict(self.deps)
        j = self.install_job
        if j:
            d["install"] = {k: j.get(k) for k in ("state", "result", "t", "t_end")}
            log = self.runs_dir / "pip_install.log"
            d["install"]["log"] = tail_text(log, 3000) if log.exists() else ""
        return d

    def gpu_status(self) -> dict:
        """System-wide counters, cached for five seconds; not per-process utilization."""
        if time.monotonic() < self._gpu_next_check or not self._gpu_lock.acquire(blocking=False):
            return self._gpu_status
        try:
            self._gpu_next_check = time.monotonic() + 5
            r = subprocess.run(["nvidia-smi", "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,power.draw",
                                "--format=csv,noheader,nounits"], capture_output=True, text=True,
                               timeout=3, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            if r.returncode:
                raise RuntimeError(r.stderr.strip())
            gpus = []
            for row in csv.reader(io.StringIO(r.stdout)):
                if len(row) == 6:
                    values = [v.strip() for v in row]
                    gpus.append(dict(zip(("index", "name", "utilization", "used_mib", "total_mib", "power_w"), values)))
            self._gpu_status = {"gpus": gpus, "updated": time.time()}
        except (OSError, subprocess.SubprocessError, RuntimeError) as e:
            self._gpu_status = {"gpus": [], "error": str(e)}
        finally:
            self._gpu_lock.release()
        return self._gpu_status

    def install_deps(self) -> dict:
        if self.install_job and self.install_job["state"] == "running":
            return {"job": self.install_job["id"]}
        py = self.train_python()
        log_path = self.runs_dir / "pip_install.log"

        def job():
            # PYTHONUTF8: 한국어 Windows(cp949)에서 옛 pip 이 파일을 못 읽는 문제 방지. pip 부터 최신으로.
            env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUTF8="1")
            kw = {"creationflags": getattr(subprocess, "CREATE_NO_WINDOW", 0)} if sys.platform == "win32" else {}
            steps = [[py, "-m", "pip", "install", "--upgrade", "pip"],
                     [py, "-m", "pip", "install", "--disable-pip-version-check", "-r", str(HERE / "requirements.txt")]]
            with open(log_path, "w", encoding="utf-8") as log:
                for cmd in steps:
                    log.write("> " + subprocess.list2cmdline(cmd) + "\n")
                    log.flush()
                    r = subprocess.run(cmd, cwd=str(HERE), stdout=log, stderr=subprocess.STDOUT,
                                       stdin=subprocess.DEVNULL, env=env, **kw)
                    if r.returncode != 0 and cmd is steps[-1]:
                        break
            d = self.check_deps()
            if r.returncode != 0 or d["state"] != "ok":
                raise RuntimeError(f"설치 실패(종료 코드 {r.returncode}) — 아래 설치 로그를 확인하세요")
            return "설치 완료"

        res = self.background(f"필수 패키지 설치 ({Path(py).name})", job)
        self.install_job = self.jobs[-1]
        return res

    # ------------------------------------------------------------ 학습 프로세스

    def build_cmd(self, a: dict) -> list[str]:
        cmd = [self.train_python(), "-u", str(HERE / "train.py"), "--godot", a["godot"], "--run", a["run"],
               "--runs-dir", str(self.runs_dir), "--n-envs", str(int(a.get("n_envs", 4)))]
        if a.get("project"):
            cmd += ["--project", a["project"]]
        if a.get("rotate"):
            cmd += ["--rotate", a["rotate"], "--rotate-steps", str(int(a.get("rotate_steps", 300000))),
                    "--cycles", str(int(a.get("cycles", 1)))]
        else:
            cmd += ["--tank", a.get("tank", "tiger1"), "--timesteps", str(int(a.get("timesteps", 1000000)))]
        if a.get("start_stage"):
            cmd += ["--start-stage", a["start_stage"]]
        if a.get("resume"):
            cmd += ["--resume"]
        if a.get("terrain_course"):
            cmd += ["--terrain-course", a["terrain_course"]]
        for key, flag in [("record_every", "--record-every"), ("save_every", "--save-every"),
                          ("review_prob", "--review-prob"), ("speed_cap", "--speed-cap"), ("seed", "--seed"),
                           ("torch_threads", "--torch-threads"), ("n_steps", "--n-steps"),
                           ("batch_size", "--batch-size"), ("n_epochs", "--n-epochs"),
                           ("lr", "--lr"), ("ent_coef", "--ent-coef"), ("sde_freq", "--sde-freq"),
                           ("pool_dir", "--pool-dir")]:
            if a.get(key) not in (None, ""):
                cmd += [flag, str(a[key])]
        cmd += ["--device", a.get("device") or self.settings.get("device", "auto")]
        if a.get("extra"):
            cmd += shlex.split(a["extra"], posix=sys.platform != "win32")
        return cmd

    def start(self, a: dict) -> dict:
        run = a.get("run") or time.strftime("%Y%m%d_%H%M%S")
        a["run"] = run
        d = self.run_dir(run)
        if read_json(d / 'status.json').get('mode') == 'evaluation':
            raise ValueError('평가 결과 폴더에서는 학습을 시작할 수 없습니다. 원래 학습 실행을 선택하세요.')
        if a.get('start_stage') == 'final_battle' or read_json(d / 'status.json').get('mode') == 'independent':
            return self.train_individuals(run, int(a.get('timesteps', 10000)))
        st = read_json(d / "status.json")
        if self.alive(run, st):
            raise ValueError(f"{run} 은 이미 학습 중")
        if not a.get("godot"):
            raise ValueError("게임 실행 파일(--godot) 경로를 넣어 주세요")
        a["godot"] = str(abs_path(a["godot"]))
        if a.get("project"):
            a["project"] = str(abs_path(a["project"]))
        if not Path(a["godot"]).exists():
            raise ValueError(f"실행 파일이 없습니다: {a['godot']}")
        if a.get("python") is not None and a.get("python", "").strip() != self.settings.get("python", ""):
            py = a["python"].strip()
            if py and not abs_path(py).exists():
                raise ValueError(f"Python 실행 파일이 없습니다: {py}")
            self.save_settings(python=str(abs_path(py)) if py else "")
            self.check_deps()
        if self.deps.get("state") in ("unknown", "checking") or self.deps.get("python") != self.train_python():
            self.check_deps()
        if self.deps.get("state") != "ok":
            miss = ", ".join(self.deps.get("missing", [])) or self.deps.get("detail", "")[-200:]
            raise ValueError(f"학습용 Python 에 필요한 패키지가 없습니다({miss}). 화면 위의 '필수 패키지 설치'를 먼저 눌러 주세요")
        cmd = self.build_cmd(a)
        # Respect --device passed via legacy extra arguments too (argparse uses the last value).
        requested = "auto"
        for i, value in enumerate(cmd):
            if value == "--device" and i + 1 < len(cmd):
                requested = cmd[i + 1]
            elif value.startswith("--device="):
                requested = value.split("=", 1)[1]
        select_device(requested, self.deps.get("runtime", {"cuda_available": False}))
        self.save_settings(godot=a["godot"], project=a.get("project", ""), device=requested)
        d.mkdir(parents=True, exist_ok=True)
        log = open(d / "train_log.txt", "a", encoding="utf-8")
        log.write(f"\n===== {time.strftime('%Y-%m-%d %H:%M:%S')} 시작: {subprocess.list2cmdline(cmd)}\n")
        log.flush()
        kw = {}
        if sys.platform == "win32":
            # 대시보드를 닫아도(콘솔 Ctrl+C) 학습은 계속되게 별도 프로세스 그룹으로
            kw["creationflags"] = subprocess.CREATE_NEW_PROCESS_GROUP | getattr(subprocess, "CREATE_NO_WINDOW", 0)
        env = dict(os.environ, PYTHONIOENCODING="utf-8", PYTHONUNBUFFERED="1", PYTHONUTF8="1")
        self.procs[run] = subprocess.Popen(cmd, cwd=str(HERE), stdout=log, stderr=subprocess.STDOUT,
                                           stdin=subprocess.DEVNULL, env=env, **kw)
        log.close()
        return {"run": run, "cmd": cmd}

    def control(self, run: str, msg: dict) -> dict:
        d = self.run_dir(run)
        with open(d / "control.jsonl", "a", encoding="utf-8") as f:
            f.write(json.dumps(msg | {"t": round(time.time(), 2)}, ensure_ascii=False) + "\n")
        return {"ok": True}

    def restart_args(self, run: str, overrides: dict) -> dict:
        """Preserve device and PPO settings across environment-count changes."""
        d = self.run_dir(run)
        rj = read_json(d / "run.json")
        if not rj.get("sessions"):
            raise ValueError("run.json 이 없어 이전 설정을 알 수 없습니다")
        args = dict(rj["sessions"][-1]["args"])
        a = {"run": run, "godot": args.get("godot"), "project": args.get("project") or "",
             "n_envs": args.get("n_envs"), "record_every": args.get("record_every"),
             "save_every": args.get("save_every"), "review_prob": args.get("review_prob"),
             "speed_cap": args.get("speed_cap", 0), "seed": args.get("seed"),
             "torch_threads": args.get("torch_threads", 0), "resume": True,
             "device": args.get("device", "auto")}
        for key in ("n_steps", "batch_size", "n_epochs", "lr", "ent_coef", "sde_freq", "pool_dir", "terrain_course"):
            if args.get(key) is not None:
                a[key] = args[key]
        st = read_json(d / "status.json")
        if args.get("rotate"):
            a |= {"rotate": args["rotate"], "rotate_steps": args.get("rotate_steps"), "cycles": args.get("cycles")}
        else:
            # 남은 스텝만큼 이어서
            left = int((st.get("target_timesteps") or 0) - (st.get("num_timesteps") or 0))
            a |= {"tank": args.get("tank", "tiger1"), "timesteps": max(left, 10000) if st.get("target_timesteps")
                  else args.get("timesteps")}
        # 실행 중에 바꾼 값(기록 간격·복습·배속)도 이어 간다
        for k in ("record_every", "review_prob", "speed_cap"):
            if k in st:
                a[k] = st[k]
        a |= {k: v for k, v in overrides.items() if v not in (None, "")}
        return a

    def restart(self, run: str, overrides: dict) -> dict:
        """저장 후 중지 → 같은 설정 + overrides 로 --resume 다시 시작."""
        d = self.run_dir(run)
        a = self.restart_args(run, overrides)

        def job():
            if self.alive(run, read_json(d / "status.json")):
                self.control(run, {"cmd": "stop"})
                t0 = time.time()
                while time.time() - t0 < 600:
                    p = self.procs.get(run)
                    if p is not None:
                        if p.poll() is not None:
                            break
                    elif read_json(d / "status.json").get("phase") == "stopped":
                        time.sleep(2)   # 프로세스 정리 시간
                        break
                    time.sleep(0.5)
            self.procs.pop(run, None)
            self.start(a)

        return self.background(f"{run}: 다시 시작({', '.join(f'{k}={v}' for k, v in overrides.items())})", job)

    # ------------------------------------------------------------ 리플레이·보고서

    def train_individuals(self, source_run: str, timesteps: int = 10000) -> dict:
        source = self.run_dir(source_run)
        status = read_json(source / 'status.json')
        if not 1 <= timesteps <= 10000000 or status.get('mode') == 'evaluation':
            raise ValueError('학습 모델이 있는 실행과 올바른 추가 스텝 수를 선택하세요.')
        if status.get('mode') == 'independent':
            if self.alive(source_run, status):
                raise ValueError('이미 독립 학습 중입니다.')
            run = source_run
            origin = read_json(source / 'independent_run.json')['source_run']
        else:
            run = 'independent_' + dt.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
            origin = source_run
        directory = self.run_dir(run)
        directory.mkdir(exist_ok=True)
        game = self.game_cmd()
        cmd = [self.train_python(), '-u', str(HERE / 'train_individuals.py'), '--godot', game[0],
               '--runs-dir', str(self.runs_dir), '--run', run, '--source-run', origin, '--timesteps', str(timesteps),
               # 전장 4개 병렬(개체별 추론 묶음). 설정 independent_n_envs 로 바꿀 수 있다(1 = 예전 순차 수집)
               '--n-envs', str(int(self.settings.get('independent_n_envs', 4)))]
        if self.settings.get('project'):
            cmd += ['--project', self.settings['project']]
        with (directory / 'train_log.txt').open('a', encoding='utf-8') as log:
            flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0
            process = subprocess.Popen(cmd, cwd=str(HERE), stdout=log, stderr=subprocess.STDOUT, creationflags=flags)
        self.procs[run] = process

        def wait():
            if process.wait() != 0:
                raise RuntimeError(tail_text(directory / 'train_log.txt', 1400))
            return run + ': 7개체 저장 완료'
        return self.background(source_run + ': 7개체 독립 학습', wait) | {'run': run}

    def evaluate(self, source_run: str, episodes: int = 1, modes: str = 'mixed') -> dict:
        from tankrl.evaluation import MODES
        source = self.run_dir(source_run)
        if read_json(source / 'status.json').get('mode') == 'evaluation':
            raise ValueError('학습 모델이 있는 원래 실행을 선택하세요.')
        if not 1 <= episodes <= 100 or any(mode not in MODES for mode in modes.split(',')):
            raise ValueError('잘못된 평가 설정')
        run = 'evaluation_' + dt.datetime.now().strftime('%Y%m%d_%H%M%S_%f')
        directory = self.run_dir(run)
        directory.mkdir()
        game = self.game_cmd()
        cmd = [self.train_python(), '-u', str(HERE / 'evaluate.py'), '--godot', game[0],
               '--runs-dir', str(self.runs_dir), '--source-run', source_run,
               '--out', str(directory), '--episodes', str(episodes), '--modes', modes]
        if self.settings.get('project'):
            cmd += ['--project', self.settings['project']]
        with (directory / 'train_log.txt').open('a', encoding='utf-8') as log:
            flags = subprocess.CREATE_NEW_PROCESS_GROUP | subprocess.CREATE_NO_WINDOW if sys.platform == 'win32' else 0
            process = subprocess.Popen(cmd, cwd=str(HERE), stdout=log, stderr=subprocess.STDOUT, creationflags=flags)
        self.procs[run] = process

        def wait():
            if process.wait() != 0:
                raise RuntimeError(tail_text(directory / 'train_log.txt', 1400))
            return run + '/evaluation_report.html'
        return self.background(source_run + ': 10단계 최종전 평가', wait) | {'run': run}

    def game_cmd(self) -> list[str]:
        g = self.settings.get("godot", "")
        if not g or not Path(g).exists():
            raise ValueError("게임 실행 파일 경로가 설정되지 않았습니다(학습 시작 칸)")
        cmd = [g]
        if self.settings.get("project"):
            cmd += ["--path", self.settings["project"]]
        return cmd

    def safe_path(self, p: str) -> Path:
        q = Path(p).resolve()
        if self.runs_dir not in q.parents:
            raise ValueError("runs 폴더 밖의 경로")
        return q

    def open_viewer(self, events: Path) -> None:
        cmd = self.game_cmd() + ["res://recording/replay_viewer.tscn", "--", f"--replay={events}"]
        subprocess.Popen(cmd, cwd=str(HERE), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def open_replay(self, replay_dir: str) -> dict:
        d = self.safe_path(replay_dir)
        ev = d / "events.jsonl"
        if not ev.exists():
            raise ValueError(f"리플레이 파일이 없습니다: {ev}")
        self.open_viewer(ev)
        return {"ok": True}

    def reproduce(self, run: str, episode_file: str, view: bool) -> dict:
        ep = self.safe_path(episode_file)
        out = self.run_dir(run) / "reproduced"

        def job():
            cmd = [self.train_python(), str(HERE / "reproduce.py"), str(ep), "--out-dir", str(out)]
            g = self.game_cmd()
            cmd += ["--godot", g[0]] + (["--project", g[2]] if len(g) > 2 else [])
            r = subprocess.run(cmd, cwd=str(HERE), capture_output=True, text=True, encoding="utf-8",
                               errors="replace")
            res = sorted((out / "replays").glob("ep*/reproduce.json"), key=lambda p: p.stat().st_mtime)
            if not res:
                raise RuntimeError("재현 실패: " + (r.stdout + r.stderr)[-500:])
            if view:
                self.open_viewer(res[-1].parent / "events.jsonl")
            verdict = next((ln for ln in r.stdout.splitlines() if ln.startswith(("OK", "MISMATCH"))), "")
            return f"{verdict} → {res[-1].parent.name}"

        return self.background(f"재현 {ep.stem}", job)

    def report(self, run: str) -> dict:
        d = self.run_dir(run)

        def job():
            r = subprocess.run([self.train_python(), str(HERE / "report.py"), str(d)], cwd=str(HERE),
                               capture_output=True, text=True, encoding="utf-8", errors="replace")
            if r.returncode != 0:
                raise RuntimeError((r.stdout + r.stderr)[-500:])
            return "training_report.html"

        return self.background(f"{run}: 학습 보고서", job)

    def background(self, title: str, fn) -> dict:
        job = {"id": len(self.jobs) + 1, "title": title, "state": "running", "t": time.time(), "result": ""}
        self.jobs.append(job)

        def run():
            try:
                job["result"] = fn() or ""
                job["state"] = "done"
            except Exception as e:
                job["state"] = "error"
                job["result"] = str(e)
            job["t_end"] = time.time()

        threading.Thread(target=run, daemon=True).start()
        return {"job": job["id"]}


def make_handler(dash: Dashboard):
    page_path = HERE / "tankrl" / "dashboard.html"

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def send_body(self, code: int, body: bytes, ctype: str) -> None:
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def send_json(self, data, code: int = 200) -> None:
            self.send_body(code, json.dumps(data, ensure_ascii=False).encode("utf-8"), "application/json; charset=utf-8")

        def do_GET(self):
            u = urllib.parse.urlparse(self.path)
            q = {k: v[0] for k, v in urllib.parse.parse_qs(u.query).items()}
            try:
                if u.path == "/":
                    return self.send_body(200, page_path.read_bytes(), "text/html; charset=utf-8")
                if u.path == "/api/info":
                    return self.send_json(dash.info())
                if u.path == "/api/deps":
                    if q.get("refresh"):
                        dash.check_deps()
                    return self.send_json(dash.deps_info())
                if u.path == "/api/records":
                    return self.send_json(dash.records())
                if u.path == "/api/runs":
                    return self.send_json({"runs": dash.runs(), "jobs": dash.jobs[-10:]})
                if u.path == "/api/state":
                    w = dash.watch(q["run"])
                    st = w.state(int(q.get("ep_since", 0)), json.loads(q.get("sb3_since", "{}")))
                    st["alive"] = dash.alive(q["run"], st["status"])
                    st["owned"] = q["run"] in dash.procs
                    st["jobs"] = dash.jobs[-10:]
                    st["gpu_status"] = dash.gpu_status()
                    return self.send_json(st)
                if u.path.startswith("/files/"):
                    p = dash.safe_path(str(dash.runs_dir / urllib.parse.unquote(u.path[len("/files/"):])))
                    if not p.is_file():
                        return self.send_json({"error": "없는 파일"}, 404)
                    ctype = {".html": "text/html; charset=utf-8", ".json": "application/json",
                             ".csv": "text/csv; charset=utf-8", ".jsonl": "text/plain; charset=utf-8",
                             ".txt": "text/plain; charset=utf-8", ".png": "image/png"}.get(p.suffix, "application/octet-stream")
                    return self.send_body(200, p.read_bytes(), ctype)
                self.send_json({"error": "not found"}, 404)
            except Exception as e:
                self.send_json({"error": str(e)}, 400)

        def do_POST(self):
            u = urllib.parse.urlparse(self.path)
            n = int(self.headers.get("Content-Length", 0))
            try:
                a = json.loads(self.rfile.read(n) or b"{}")
                if u.path == "/api/start":
                    return self.send_json(dash.start(a))
                if u.path == "/api/control":
                    return self.send_json(dash.control(a.pop("run"), a))
                if u.path == "/api/restart":
                    return self.send_json(dash.restart(a.pop("run"), a))
                if u.path == "/api/open_replay":
                    return self.send_json(dash.open_replay(a["replay_dir"]))
                if u.path == "/api/reproduce":
                    return self.send_json(dash.reproduce(a["run"], a["episode_file"], bool(a.get("view", True))))
                if u.path == "/api/report":
                    return self.send_json(dash.report(a["run"]))
                if u.path == '/api/evaluate':
                    return self.send_json(dash.evaluate(a['run'], int(a.get('episodes', 1)), a.get('modes', 'mixed')))
                if u.path == '/api/train_individuals':
                    return self.send_json(dash.train_individuals(a['run'], int(a.get('timesteps', 10000))))
                if u.path == "/api/install":
                    return self.send_json(dash.install_deps())
                if u.path == "/api/settings":
                    dash.save_settings(godot=a.get("godot"), project=a.get("project"), python=a.get("python"))
                    return self.send_json(dash.settings)
                self.send_json({"error": "not found"}, 404)
            except Exception as e:
                self.send_json({"error": str(e)}, 400)

    return H


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8', errors='replace')
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1", help="다른 PC 에서 보려면 0.0.0.0 (같은 네트워크 안에서만)")
    ap.add_argument("--runs-dir", default=str(default_runs_dir()))
    ap.add_argument("--no-browser", action="store_true")
    a = ap.parse_args()
    dash = Dashboard(Path(a.runs_dir) if Path(a.runs_dir).is_absolute() else HERE / a.runs_dir)
    srv = ThreadingHTTPServer((a.host, a.port), make_handler(dash))
    url = f"http://127.0.0.1:{a.port}/"
    print(f"[dashboard] {url}  (runs: {dash.runs_dir}) — 닫으려면 Ctrl+C. 학습은 계속 돈다.", flush=True)
    if not a.no_browser:
        threading.Timer(0.6, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
