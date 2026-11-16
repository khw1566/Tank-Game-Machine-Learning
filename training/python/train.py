"""PPO 커리큘럼 학습(전차 종류별 정책).

예) 티거 하나만 처음부터:
  python train.py --godot "C:/.../TankGame.exe" --tank tiger1 --timesteps 2000000
예) 세 종류를 번갈아(자기대전 단계에서 서로의 최신 정책이 상대가 된다):
  python train.py --godot godot.exe --project .. /.. --rotate tiger1,sherman75,t34_76 --rotate-steps 300000 --cycles 10

출력(runs/<run>/):
  run.json                 실행 설정·버전·단계 정의·관측/행동 이름(보고서·재현용)
  progress.csv             에피소드마다 한 줄(단계, 성공, 보상, 명중, 스폰 거리, 재현 파일 경로 …)
  curriculum_log.jsonl     단계 승급 기록
  <tank>/latest.zip, <tank>/step_*.zip, <tank>/curriculum.json   정책 체크포인트·진행 상태
  episodes/env*/<uid>.json 모든 에피소드 재현 파일(설정·시드·행동·보상·사격·동선)
  env*/replays/ep*/        record_every 마다 전체 리플레이(events.jsonl)·보고서(report.html)
  sb3/                     학습 통계(progress.csv, 텐서보드가 설치돼 있으면 이벤트 파일)
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import platform
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

from tankrl.curriculum import STAGE_IDS, STAGES, Curriculum
from tankrl.godot_env import GodotVecEnv
from tankrl.opponents import OpponentPool


def parse():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot", required=True, help="Godot 4.3 실행 파일 또는 내보낸 TankGame.exe")
    ap.add_argument("--project", default=None, help="Godot 편집기 실행 파일을 쓸 때 프로젝트 폴더(내보낸 exe 면 생략)")
    ap.add_argument("--tank", default="tiger1", choices=["tiger1", "sherman75", "t34_76"])
    ap.add_argument("--rotate", default="", help="여러 종류를 번갈아 학습: tiger1,sherman75,t34_76")
    ap.add_argument("--rotate-steps", type=int, default=300_000, help="교대마다 한 종류의 학습 스텝")
    ap.add_argument("--cycles", type=int, default=1, help="--rotate 반복 횟수")
    ap.add_argument("--timesteps", type=int, default=1_000_000, help="--rotate 가 없을 때 총 스텝(결정 수)")
    ap.add_argument("--n-envs", type=int, default=4, help="동시에 띄울 Godot 수(CPU 코어 수 정도)")
    ap.add_argument("--run", default="", help="실행 이름(runs/<run>). 비우면 날짜시각")
    ap.add_argument("--runs-dir", default="runs")
    ap.add_argument("--pool-dir", default="", help="자기대전 상대 정책 풀(기본 runs/pool)")
    ap.add_argument("--start-stage", default="", choices=[""] + STAGE_IDS, help="이 단계부터 시작")
    ap.add_argument("--resume", action="store_true", help="runs/<run>/<tank>/latest.zip 과 커리큘럼 상태에서 이어서")
    ap.add_argument("--save-every", type=int, default=100_000)
    ap.add_argument("--record-every", type=int, default=200, help="N 에피소드마다 전체 리플레이·보고서 기록(0 = 끔)")
    ap.add_argument("--review-prob", type=float, default=0.1, help="이전 단계 복습 확률")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--device", default="cpu")
    ap.add_argument("--n-steps", type=int, default=1024, help="PPO: 환경당 수집 스텝")
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--ent-coef", type=float, default=0.005)
    ap.add_argument("--sde-freq", type=int, default=20, help="gSDE 탐색 잡음을 몇 결정마다 다시 뽑을지(20 = 2초)")
    ap.add_argument("--verbose-godot", action="store_true")
    return ap.parse_args()


def git_commit(project: str | None) -> str:
    try:
        root = Path(project or Path(__file__).resolve().parents[2])
        return subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def write_manifest(run_dir: Path, args, env: GodotVecEnv) -> None:
    import stable_baselines3
    import torch
    path = run_dir / "run.json"
    runs = []
    if path.exists():
        runs = json.loads(path.read_text(encoding="utf-8")).get("sessions", [])
    runs.append({"started": dt.datetime.now().isoformat(timespec="seconds"), "argv": sys.argv,
                 "args": vars(args), "git_commit": git_commit(args.project),
                 "python": sys.version.split()[0], "platform": platform.platform(),
                 "torch": torch.__version__, "stable_baselines3": stable_baselines3.__version__,
                 "godot": env.procs[0].hello.get("engine", ""), "godot_cmd": env.procs[0].cmd})
    path.write_text(json.dumps({"format": "tankgame-train-run", "version": 1, "sessions": runs,
                                "stages": STAGES, "obs_labels": env.obs_labels,
                                "action_labels": env.action_labels,
                                "protocol": env.procs[0].hello.get("protocol"),
                                "repeat_ticks": env.procs[0].hello.get("repeat"),
                                "physics_hz": env.procs[0].hello.get("physics_hz")},
                               ensure_ascii=False, indent=1), encoding="utf-8")


def train_one(args, run_dir: Path, pool_dir: Path, tank: str, steps: int) -> None:
    from stable_baselines3 import PPO
    from stable_baselines3.common.callbacks import BaseCallback
    from stable_baselines3.common.logger import configure

    tdir = run_dir / tank
    tdir.mkdir(parents=True, exist_ok=True)
    cpath = tdir / "curriculum.json"
    start = STAGE_IDS.index(args.start_stage) if args.start_stage else 0
    if cpath.exists() and (args.resume or args.rotate):
        cur = Curriculum.load(cpath, tank, review_prob=args.review_prob, seed=args.seed)
    else:
        cur = Curriculum(tank, start_stage=start, review_prob=args.review_prob, seed=args.seed)
    pool = OpponentPool(pool_dir, exclude=tank, device=args.device)
    env = GodotVecEnv(args.n_envs, args.godot, args.project, run_dir, tank, cur, opponents=pool,
                      seed=args.seed * 1000 + sum(map(ord, tank)), record_every=args.record_every,
                      quiet=not args.verbose_godot, run_name=run_dir.name)
    write_manifest(run_dir, args, env)
    latest = tdir / "latest.zip"
    if latest.exists() and (args.resume or args.rotate):
        model = PPO.load(str(latest), env=env, device=args.device)
        print(f"[train] {tank}: 이어서 학습 ({latest}, {model.num_timesteps} 스텝, 단계 {cur.stage['id']})")
    else:
        model = PPO("MlpPolicy", env, n_steps=args.n_steps, batch_size=min(2048, args.n_steps * args.n_envs),
                    learning_rate=args.lr, gamma=0.99, gae_lambda=0.95, ent_coef=args.ent_coef, clip_range=0.2,
                    n_epochs=8, policy_kwargs={"net_arch": [256, 256], "log_std_init": -0.5},
                    # gSDE: 탐색 잡음을 몇 결정 동안 유지(매 0.1초 무작위로 궤도 방향이 바뀌면 변속기 때문에 전차가 아예 못 움직인다)
                    use_sde=True, sde_sample_freq=args.sde_freq, seed=args.seed, device=args.device,
                    verbose=0)
        print(f"[train] {tank}: 새 정책, 단계 {cur.stage['id']}")
    fmt = ["csv", "stdout"]
    try:
        import tensorboard  # noqa: F401
        fmt.append("tensorboard")
    except ImportError:
        pass
    model.set_logger(configure(str(run_dir / "sb3" / tank), fmt))

    def version() -> str:
        return f"{run_dir.name}/{tank}/step_{model.num_timesteps:09d}"

    env.learner_version = version()
    env.policy_fn = lambda o: model.predict(o, deterministic=False)[0]

    class Cb(BaseCallback):
        def __init__(self):
            super().__init__()
            self.next_save = (model.num_timesteps // args.save_every + 1) * args.save_every

        def _on_step(self) -> bool:
            env.learner_version = version()
            env.global_step = self.num_timesteps
            for info in self.locals.get("infos", []):
                if "success" in info:
                    self.logger.record_mean(f"success/{info['stage']}", float(info["success"]))
            if self.num_timesteps >= self.next_save:
                self.next_save += args.save_every
                save(snapshot=True)
            return True

        def _on_rollout_end(self) -> None:
            self.logger.record("curriculum/stage_idx", cur.stage_idx)
            self.logger.record("curriculum/success_rate", cur.success_rate(cur.stage["id"], 100))

    def save(snapshot: bool) -> None:
        model.save(str(latest))
        cur.save(cpath)
        pdir = pool_dir / tank
        pdir.mkdir(parents=True, exist_ok=True)
        shutil.copy2(latest, pdir / "latest.zip")
        (pdir / "latest.json").write_text(json.dumps({"version": version(), "stage": cur.stage["id"]}),
                                          encoding="utf-8")
        if snapshot:
            name = f"step_{model.num_timesteps:09d}.zip"
            shutil.copy2(latest, tdir / name)
            shutil.copy2(latest, pdir / name)
        print(f"[train] {tank}: 저장 {version()} (단계 {cur.stage['id']})", flush=True)

    try:
        model.learn(total_timesteps=steps, callback=Cb(), reset_num_timesteps=False, progress_bar=False)
    finally:
        save(snapshot=True)
        env.close()


def main():
    args = parse()
    run = args.run or dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = (Path(args.runs_dir) / run).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    pool_dir = Path(args.pool_dir).resolve() if args.pool_dir else (Path(args.runs_dir) / "pool").resolve()
    if args.rotate:
        tanks = [t.strip() for t in args.rotate.split(",") if t.strip()]
        for c in range(args.cycles):
            for t in tanks:
                print(f"[train] 교대 {c + 1}/{args.cycles}: {t} {args.rotate_steps} 스텝")
                train_one(args, run_dir, pool_dir, t, args.rotate_steps)
    else:
        train_one(args, run_dir, pool_dir, args.tank, args.timesteps)
    print(f"[train] 끝. 보고서: python report.py {run_dir}")


if __name__ == "__main__":
    np.set_printoptions(precision=3, suppress=True)
    main()
