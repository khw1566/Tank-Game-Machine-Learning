"""실제 전투 시범 수집: V6 전투 환경에서 연합 전차 한 대를 사람이 직접 조종하고, PPO 와 같은 관측·행동을 기록한다.

    py -3.14 training/python/play_combat_demo.py --tank sherman75 --stage v6_1v2 --run "V6run 1"

- 맵·배치·보상·관통은 V6 학습과 같은 생성기(v6_curriculum.arena)를 쓴다. 사람이 조종하는 전차가 학습 전차 자리에 선다.
- 티거와 다른 차종(외부 조종 전차)은 --run 의 상대 풀(<run>/opponents/<차종>/step_*.zip) 최신 모델이 조종한다.
  모델이 없으면 규칙 AI 가 맡는다. 규칙 AI 아군(우회조·견제조)은 V6 와 같다.
- 0.1초마다 (관측 750, 행동 11) 한 쌍. 판이 끝나면 <데이터>/combat_demos/<차종>/*.npz 로 저장하고 다음 판을 준비한다.
  창을 닫으면 진행 중인 판은 저장하지 않는다(완료된 판만 행동 복제에 쓴다).
"""
from __future__ import annotations

import argparse
import datetime as dt
import random
import secrets
import socket
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))

from tankrl import curriculum_v4, protocol, v6_curriculum  # noqa: E402
from tankrl.combat_demo import ALLIES, demos_root, save_demo  # noqa: E402
from tankrl.curriculum import tank_names  # noqa: E402
from tankrl.runtime import V6_GAME  # noqa: E402
from tankrl.storage import default_runs_dir  # noqa: E402


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tank", default="sherman75", choices=list(ALLIES) + ["tiger1"])
    ap.add_argument("--stage", default="v6_1v2", choices=v6_curriculum.STAGE_IDS)
    ap.add_argument("--map", default="", help="맵 이름(비우면 V6 처럼 무작위)")
    ap.add_argument("--run", default="", help="상대 모델을 가져올 V6 실행 이름(비우면 모두 규칙 AI)")
    ap.add_argument("--runs-dir", default=str(default_runs_dir()))
    ap.add_argument("--godot", default=str(V6_GAME), help="게임 실행 파일(또는 Godot 편집기 + --project)")
    ap.add_argument("--project", default=None)
    ap.add_argument("--out", default="", help="저장 폴더(기본: <데이터>/combat_demos)")
    ap.add_argument("--episodes", type=int, default=0, help="이만큼 저장하면 종료(0 = 창을 닫을 때까지)")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--resolution", default="1600x900")
    ap.add_argument("--time-limit", type=float, default=0.0, help="판 제한 시간(초) 덮어쓰기(0 = V6 단계 기본값)")
    ap.add_argument("--autopilot", action="store_true", help=argparse.SUPPRESS)
    return ap.parse_args(argv)


class Opponents:
    """외부 조종 전차(티거 등)의 고정 모델. 차종별 최신 스냅숏 하나를 쓴다."""

    def __init__(self, run_dir: Path | None):
        self.pool = None
        if run_dir is not None and (run_dir / "opponents").exists():
            from tankrl.opponents import OpponentPool
            self.pool = OpponentPool(run_dir / "opponents", latest_prob=1.0)
        self.versions: dict[str, str] = {}

    def version(self, tank: str, rng: random.Random) -> str:
        if self.pool is None:
            return ""
        if tank not in self.versions:
            try:
                self.versions[tank] = self.pool.pick_frozen(tank, rng)
            except RuntimeError:
                self.versions[tank] = ""
        return self.versions[tank]

    def act(self, version: str, obs: np.ndarray) -> np.ndarray:
        model = self.pool._load(version)
        action, _ = model.predict(self.pool.compatible_observation(obs, model), deterministic=False)
        return np.asarray(action, dtype=np.float32).reshape(len(obs), -1)


def build_episode(args, rng: random.Random, opponents: Opponents, hello: dict):
    cur = v6_curriculum.V6Curriculum(args.tank, start_stage=v6_curriculum.STAGE_IDS.index(args.stage), review_prob=0.0)
    for _ in range(500):
        seed = rng.randrange(1, 2**31 - 1)
        st, lu, extra = cur.build_episode(args.tank, rng, seed)
        if not args.map or extra["scenario"]["variant"] == args.map:
            break
    else:
        raise SystemExit(f"맵 이름이 V6 맵에 없습니다: {args.map}")
    lu = [dict(d) for d in lu]
    lu[0]["ctrl"] = "human"
    lu[0]["role"] = "human"
    policies = {}
    names = tank_names(lu)
    for d, name in zip(lu, names):
        if d["ctrl"] != "external":
            continue
        v = opponents.version(d["type"], rng)
        if v:
            d["model"] = v
            policies[name] = v
        else:
            d["ctrl"] = "scripted"      # 모델이 없으면 규칙 AI(팀 기본 전술)
            d["role"] = "rule"
    uid = f"demo_{args.tank}_{dt.datetime.now():%Y%m%d_%H%M%S}_{secrets.token_hex(3)}"
    meta = {"run": "combat-demo", "learner_tank": args.tank, "model": "human", "policies": policies,
            "roles": {n: d["role"] for d, n in zip(lu, names)}, "variant": extra["scenario"]["variant"]}
    cfg = curriculum_v4.make_config(st, extra, args.tank, lu, seed, uid, False, meta, None)
    cfg["curriculum_version"] = v6_curriculum.VERSION
    cfg["learner_team"] = lu[0]["team"]
    cfg["map"]["seed"] = int(extra["map_seed"])
    cfg["balance_version"] = extra["balance_version"]
    if args.time_limit > 0:
        cfg["time_limit_s"] = args.time_limit
    ext = [d for d in lu if d["ctrl"] == "external"]
    return cfg, lu, ext, names


def launch(args):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.bind(("127.0.0.1", 0))
    srv.listen(1)
    srv.settimeout(120)
    port = srv.getsockname()[1]
    cmd = [args.godot, "--resolution", args.resolution]
    if args.project:
        cmd += ["--path", args.project]
    cmd += ["--", "--train", f"--port={port}", "--env-id=0", f"--log-dir={Path(args.out) / '_godot'}",
            f"--obs={v6_curriculum.V6Curriculum.obs}"] + (["--human-autopilot"] if args.autopilot else [])
    proc = subprocess.Popen(cmd)
    try:
        sock, _ = srv.accept()
    finally:
        srv.close()
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    hello, _ = protocol.recv(sock)
    if int(hello.get("human_demo_version", 0)) < 1:
        proc.kill()
        raise SystemExit("이 게임 실행 파일은 실제 전투 시범(ctrl human)을 지원하지 않습니다. 게임을 다시 빌드하세요.")
    return proc, sock, hello


def main(argv=None):
    args = parse_args(argv)
    args.out = str(Path(args.out) if args.out else demos_root())
    rng = random.Random(args.seed if args.seed is not None else secrets.randbits(31))
    run_dir = (Path(args.runs_dir) / args.run).resolve() if args.run else None
    if run_dir is not None and not run_dir.exists():
        raise SystemExit(f"실행 폴더가 없습니다: {run_dir}")
    opponents = Opponents(run_dir)
    proc, sock, hello = launch(args)
    D, A = int(hello["obs_size"]), int(hello["act_size"])
    saved = 0
    print(f"[demo] {args.tank} · {args.stage} · 저장 폴더 {Path(args.out) / args.tank}", flush=True)
    try:
        while args.episodes <= 0 or saved < args.episodes:
            cfg, lu, ext, names = build_episode(args, rng, opponents, hello)
            protocol.send(sock, {"type": "reset", "config": cfg})
            obs_rows, act_rows = [], []
            started = time.time()
            while True:
                h, payload = protocol.recv(sock)
                if h.get("type") == "error":
                    raise RuntimeError(h.get("message"))
                n_ext = len(h["agents"])
                human = h.get("human", {})
                m = int(human.get("n", 0))
                flat = np.frombuffer(payload, dtype="<f4")
                ext_obs = flat[:n_ext * D].reshape(n_ext, D)
                if m:
                    obs_rows.append(flat[n_ext * D:(n_ext + m) * D].reshape(m, D).copy())
                    act_rows.append(np.asarray(human["actions"], dtype=np.float32).reshape(m, A))
                if h.get("done"):
                    ep = h.get("episode", {})
                    break
                acts = np.zeros((n_ext, A), dtype=np.float32)
                for k, d in enumerate(ext):
                    acts[k] = opponents.act(d["model"], ext_obs[k:k + 1])[0]
                protocol.send(sock, {"type": "step"}, np.clip(acts, -1, 1).astype("<f4").tobytes())
            if not obs_rows:
                continue
            obs, actions = np.concatenate(obs_rows), np.concatenate(act_rows)
            me = next((t for t in ep.get("tanks", []) if t.get("name") == names[0]), {})
            result = {"reason": ep.get("reason"), "winner": ep.get("winner"), "duration_s": ep.get("duration_s"),
                      "won": ep.get("winner") == lu[0]["team"], "status": me.get("status"), "shots": me.get("shots"),
                      "hits": me.get("hits"), "pens": me.get("pens"), "kills": me.get("kills"),
                      "exchange": ep.get("exchange")}
            meta = {"tank": args.tank, "stage": cfg["stage"], "map": cfg["scenario"]["variant"], "seed": cfg["seed"],
                    "uid": cfg["uid"], "lineup": [{k: d[k] for k in ("type", "team", "ctrl", "role")} | ({"model": d["model"]} if "model" in d else {}) for d in lu],
                    "obs_labels": hello["obs_labels"], "action_labels": hello["action_labels"],
                    "repeat": hello["repeat"], "physics_hz": hello["physics_hz"], "engine": hello.get("engine"),
                    "game_versions": {k: v for k, v in hello.items() if k.endswith("_version")},
                    "result": result, "wall_s": round(time.time() - started, 1),
                    "recorded": dt.datetime.now().astimezone().isoformat(timespec="seconds")}
            path = Path(args.out) / args.tank / f"{cfg['stage']}_{cfg['scenario']['variant']}_{cfg['uid']}.npz"
            save_demo(path, obs, actions, meta)
            saved += 1
            print(f"[demo] 저장 {path.name}: 조작 {len(obs)}개 · {result['reason']} · {'승리' if result['won'] else '승리 아님'}", flush=True)
    except (ConnectionError, OSError) as e:
        print(f"[demo] 게임 창이 닫혔습니다({e.__class__.__name__}). 저장한 판 {saved}개", flush=True)
    finally:
        try:
            protocol.send(sock, {"type": "close"})
        except OSError:
            pass
        sock.close()
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()


if __name__ == "__main__":
    main()
