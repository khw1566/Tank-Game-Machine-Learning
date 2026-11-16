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
from tankrl.curriculum import STAGE_IDS, STAGES  # noqa: E402

TANKS = ["tiger1", "sherman75", "t34_76"]
# 브라우저로 보내는 에피소드 열(짧게): progress.csv 의 열 이름
EP_COLS = ["wall_time", "global_step", "env", "tank", "stage_idx", "current_stage", "success", "return",
           "decisions", "hits", "pens", "kills", "shots", "spawn_distance_m", "rec"]
RECENT_COLS = ["wall_time", "global_step", "env", "uid", "tank", "stage", "success", "reason", "winner", "return",
               "decisions", "duration_s", "spawn_distance_m", "hits", "pens", "kills", "shots", "learner_policy",
               "opponents", "episode_file", "replay_dir"]
SB3_KEYS = ["time/total_timesteps", "rollout/ep_rew_mean", "rollout/ep_len_mean", "train/entropy_loss",
            "train/value_loss", "train/policy_gradient_loss", "train/approx_kl", "train/clip_fraction",
            "train/explained_variance", "train/std", "time/fps", "curriculum/stage_idx", "curriculum/success_rate"]


REQUIRED = ["numpy", "gymnasium", "stable_baselines3", "torch"]
DEPS_CHECK = ("import importlib.util, sys; mods = %r; "
              "miss = [m for m in mods if importlib.util.find_spec(m) is None]; "
              "print('MISSING=' + ','.join(miss)); print('PY=' + sys.version.split()[0])") % REQUIRED


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
            f.seek(self.offset)
            data = f.read()
        end = data.rfind(b"\n") + 1
        if end == 0:
            return 0
        self.offset += end
        text = data[:end].decode("utf-8", "replace")
        lines = list(csv.reader(io.StringIO(text)))
        if self.header is None and lines:
            self.header = lines.pop(0)
        n0 = len(self.rows)
        for r in lines:
            if len(r) == len(self.header):
                self.rows.append(dict(zip(self.header, r)))
        return len(self.rows) - n0


class RunWatch:
    def __init__(self, run_dir: Path):
        self.run_dir = run_dir
        self.progress = CsvTail(run_dir / "progress.csv")
        self.sb3 = {t: CsvTail(run_dir / "sb3" / t / "progress.csv") for t in TANKS}
        self.lock = threading.Lock()

    def ep_compact(self, r: dict) -> list:
        out = []
        for c in EP_COLS:
            if c == "tank":
                out.append(TANKS.index(r["tank"]) if r.get("tank") in TANKS else -1)
            elif c == "current_stage":
                out.append(STAGE_IDS.index(r[c]) if r.get(c) in STAGE_IDS else -1)
            elif c == "rec":
                out.append(1 if r.get("replay_dir") else 0)
            else:
                out.append(num(r.get(c, "")))
        return out

    def state(self, ep_since: int, sb3_since: dict) -> dict:
        with self.lock:
            self.progress.update()
            for t in self.sb3.values():
                t.update()
            rows = self.progress.rows
            ep_since = min(max(0, ep_since), len(rows))
            out = {"run": self.run_dir.name, "ep_cols": EP_COLS, "ep_total": len(rows),
                   "episodes": [self.ep_compact(r) for r in rows[ep_since:]], "ep_since": ep_since,
                   "recent": [{c: num(r.get(c, "")) if c not in ("uid", "episode_file", "replay_dir",
                                                                 "learner_policy", "opponents", "stage",
                                                                 "reason", "tank") else r.get(c, "")
                               for c in RECENT_COLS} | {"i": len(rows) - k}
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
        out["status"] = read_json(self.run_dir / "status.json")
        out["curriculum_log"] = read_jsonl(self.run_dir / "curriculum_log.jsonl")[-200:]
        out["tanks"] = self.tank_info()
        out["run_json"] = self.run_summary()
        log = self.run_dir / "train_log.txt"
        out["log_tail"] = tail_text(log, 6000) if log.exists() else ""
        return out

    def tank_info(self) -> dict:
        res = {}
        pool = self.run_dir.parent / "pool"
        for t in TANKS:
            d = self.run_dir / t
            if not d.exists():
                continue
            snaps = sorted(d.glob("step_*.zip"))
            latest = d / "latest.zip"
            res[t] = {"curriculum": read_json(d / "curriculum.json"),
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
        self.jobs: list[dict] = []                         # 재현·보고서 등 백그라운드 작업
        self.lock = threading.Lock()
        self.settings_path = self.runs_dir / "dashboard_settings.json"
        self.settings = {"godot": default_godot(), "project": "", "python": ""} | read_json(self.settings_path)
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

    def info(self) -> dict:
        return {"stages": [{"id": s["id"], "kind": s["kind"], "promote": s.get("promote"),
                            "time_limit_s": s["time_limit_s"]} for s in STAGES],
                "tanks": TANKS, "cpu_count": os.cpu_count() or 1, "settings": self.settings,
                "runs_dir": str(self.runs_dir), "platform": sys.platform, "deps": self.deps_info()}

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
                               encoding="utf-8", errors="replace")
            out = dict(ln.split("=", 1) for ln in r.stdout.splitlines() if "=" in ln)
            missing = [m for m in out.get("MISSING", "").split(",") if m]
            if r.returncode != 0 or "MISSING" not in out:
                self.deps = {"state": "error", "python": py, "detail": (r.stdout + r.stderr)[-800:]}
            else:
                self.deps = {"state": "ok" if not missing else "missing", "python": py, "missing": missing,
                             "version": out.get("PY", "")}
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
        for key, flag in [("record_every", "--record-every"), ("save_every", "--save-every"),
                          ("review_prob", "--review-prob"), ("speed_cap", "--speed-cap"), ("seed", "--seed"),
                          ("torch_threads", "--torch-threads")]:
            if a.get(key) not in (None, ""):
                cmd += [flag, str(a[key])]
        if a.get("extra"):
            cmd += shlex.split(a["extra"], posix=sys.platform != "win32")
        return cmd

    def start(self, a: dict) -> dict:
        run = a.get("run") or time.strftime("%Y%m%d_%H%M%S")
        a["run"] = run
        d = self.run_dir(run)
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
        if self.deps.get("state") in ("unknown", "checking"):
            self.check_deps()
        if self.deps.get("state") != "ok":
            miss = ", ".join(self.deps.get("missing", [])) or self.deps.get("detail", "")[-200:]
            raise ValueError(f"학습용 Python 에 필요한 패키지가 없습니다({miss}). 화면 위의 '필수 패키지 설치'를 먼저 눌러 주세요")
        self.save_settings(godot=a["godot"], project=a.get("project", ""))
        d.mkdir(parents=True, exist_ok=True)
        cmd = self.build_cmd(a)
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

    def restart(self, run: str, overrides: dict) -> dict:
        """저장 후 중지 → 같은 설정 + overrides(예: n_envs) 로 --resume 다시 시작. 환경 수는 실행 중에 못 바꾸므로."""
        d = self.run_dir(run)
        rj = read_json(d / "run.json")
        if not rj.get("sessions"):
            raise ValueError("run.json 이 없어 이전 설정을 알 수 없습니다")
        args = dict(rj["sessions"][-1]["args"])
        a = {"run": run, "godot": args.get("godot"), "project": args.get("project") or "",
             "n_envs": args.get("n_envs"), "record_every": args.get("record_every"),
             "save_every": args.get("save_every"), "review_prob": args.get("review_prob"),
             "speed_cap": args.get("speed_cap", 0), "seed": args.get("seed"),
             "torch_threads": args.get("torch_threads", 0), "resume": True}
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
                if u.path == "/api/runs":
                    return self.send_json({"runs": dash.runs(), "jobs": dash.jobs[-10:]})
                if u.path == "/api/state":
                    w = dash.watch(q["run"])
                    st = w.state(int(q.get("ep_since", 0)), json.loads(q.get("sb3_since", "{}")))
                    st["alive"] = dash.alive(q["run"], st["status"])
                    st["owned"] = q["run"] in dash.procs
                    st["jobs"] = dash.jobs[-10:]
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
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--host", default="127.0.0.1", help="다른 PC 에서 보려면 0.0.0.0 (같은 네트워크 안에서만)")
    ap.add_argument("--runs-dir", default="runs")
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
