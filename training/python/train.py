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
  status.json              1초마다 현재 상태(대시보드가 읽음), control.jsonl = 대시보드 명령(일시정지·중지·단계 변경 …)

모니터링·제어 GUI:  python dashboard.py  (브라우저에서 시작·일시정지·환경 수·단계 변경·학습 곡선·리플레이)
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

from tankrl.control import TrainController
from tankrl.curriculum import STAGE_IDS, STAGES, Curriculum
from tankrl import curriculum_v4
from tankrl.curriculum_v4 import CurriculumV4
from tankrl.godot_env import GodotVecEnv
from tankrl.opponents import OpponentPool
from tankrl.runtime import model_runtime, resolve_device
from tankrl.terrain import COURSE_IDS, COURSES
from tankrl.storage import (RunLock, archive_runtime, atomic_copy, checkpoint_paths, default_runs_dir,
                            save_checkpoint, session_log_dir)


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
    ap.add_argument("--runs-dir", default=str(default_runs_dir()))
    ap.add_argument("--pool-dir", default="", help="자기대전 상대 정책 풀(기본 runs/pool)")
    ap.add_argument("--curriculum", default="v1", choices=["v1", "v4"],
                    help="v1 = 기존 10단계, v4 = 결과 기반 보상·변형 혼합(기동·사격·전술·최종), 상황 관측 사용")
    ap.add_argument("--entropy-boost", type=float, default=0.02, help="v4: 단계 진입 직후 탐색 계수")
    ap.add_argument("--entropy-steps", type=int, default=300_000, help="v4: 탐색 계수를 기본값으로 줄이는 스텝 수")
    ap.add_argument("--start-stage", default="", choices=[""] + STAGE_IDS + curriculum_v4.STAGE_IDS,
                    help="이 단계부터 시작")
    ap.add_argument("--resume", action="store_true", help="runs/<run>/<tank>/latest.zip 과 커리큘럼 상태에서 이어서")
    ap.add_argument("--terrain-course", default="", choices=[""] + COURSE_IDS,
                    help="지형주행 단일 코스 고정 연습(생략하면 자동 승급)")
    ap.add_argument("--save-every", type=int, default=100_000)
    ap.add_argument("--record-every", type=int, default=200, help="N 에피소드마다 전체 리플레이·보고서 기록(0 = 끔)")
    ap.add_argument("--review-prob", type=float, default=0.1, help="이전 단계 복습 확률")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--device", default="auto", help="auto = 혼합 CUDA 우선, hybrid, cpu, cuda 또는 cuda:0")
    ap.add_argument("--n-steps", type=int, default=None,
                    help="PPO 환경당 수집 스텝(새 정책 1024, 재개 시 생략하면 기존 값)")
    ap.add_argument("--batch-size", type=int, default=None,
                    help="PPO 갱신 배치(새 정책 최대 2048, 재개 시 생략하면 기존 값)")
    ap.add_argument("--n-epochs", type=int, default=None, help="PPO 갱신 반복(새 정책 8)")
    ap.add_argument("--lr", type=float, default=3e-4)
    ap.add_argument("--ent-coef", type=float, default=0.005)
    ap.add_argument("--sde-freq", type=int, default=20, help="gSDE 탐색 잡음을 몇 결정마다 다시 뽑을지(20 = 2초)")
    ap.add_argument("--speed-cap", type=float, default=0.0,
                    help="실시간 대비 최대 배속(모든 환경 합, 0 = 무제한). PC 를 같이 쓸 때 낮춘다")
    ap.add_argument("--torch-threads", type=int, default=0,
                    help="PyTorch 스레드 수(0 = 자동: 코어 수 - 환경 수, 최소 1). Godot 과 CPU 를 덜 다투게")
    ap.add_argument("--verbose-godot", action="store_true")
    return ap.parse_args()


def git_commit(project: str | None) -> str:
    try:
        root = Path(project or Path(__file__).resolve().parents[2])
        return subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def write_manifest(run_dir: Path, args, env: GodotVecEnv, runtime: dict) -> None:
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
                 "godot": env.procs[0].hello.get("engine", ""), "godot_cmd": env.procs[0].cmd,
                 "runtime": runtime})
    runs[-1]['preserved_runtime'] = archive_runtime(Path(shutil.which(args.godot) or args.godot).resolve(), args.project)
    path.write_text(json.dumps({"format": "tankgame-train-run", "version": 1, "sessions": runs,
                                "stages": getattr(env.curriculum, "stages", STAGES),
                                "curriculum_version": getattr(env.curriculum, "version", 1),
                                "obs_labels": env.obs_labels,
                                "action_labels": env.action_labels,
                                "protocol": env.procs[0].hello.get("protocol"),
                                "repeat_ticks": env.procs[0].hello.get("repeat"),
                                "terrain_course_version": env.procs[0].hello.get("terrain_course_version", 0),
                                "terrain_courses": COURSES,
                                "physics_hz": env.procs[0].hello.get("physics_hz")},
                               ensure_ascii=False, indent=1), encoding="utf-8")


def build_model(args, env, checkpoint: Path | None = None):
    """Apply explicit rollout settings on resume too; never change unspecified saved settings."""
    from stable_baselines3 import PPO
    from stable_baselines3.common.buffers import RolloutBuffer
    from tankrl.rollout_buffer import CudaRolloutBuffer
    from tankrl.hybrid_ppo import HybridPPO

    device = args.resolved_device
    algorithm = HybridPPO if device.startswith("cuda") and args.device in ("auto", "hybrid") else PPO
    buffer_class = CudaRolloutBuffer if device.startswith("cuda") else RolloutBuffer
    overrides = {k: getattr(args, k) for k in ("n_steps", "batch_size", "n_epochs")
                 if getattr(args, k) is not None}
    if checkpoint is not None:
        return algorithm.load(str(checkpoint), env=env, device=device,
                              rollout_buffer_class=buffer_class, **overrides)
    n_steps = args.n_steps or 1024
    return algorithm("MlpPolicy", env, n_steps=n_steps,
               batch_size=args.batch_size or min(2048, n_steps * env.num_envs),
               learning_rate=args.lr, gamma=0.99, gae_lambda=0.95,
               ent_coef=args.ent_coef, clip_range=0.2, n_epochs=args.n_epochs or 8,
               policy_kwargs={"net_arch": [256, 256], "log_std_init": -0.5},
               # gSDE noise must persist long enough for the tank gearbox to respond.
               use_sde=True, sde_sample_freq=args.sde_freq, seed=args.seed,
               device=device, rollout_buffer_class=buffer_class, verbose=0)


def train_one(args, run_dir: Path, pool_dir: Path, tank: str, steps: int, ctl: TrainController) -> None:
    from stable_baselines3.common.callbacks import BaseCallback
    from stable_baselines3.common.logger import configure

    tdir = run_dir / tank
    tdir.mkdir(parents=True, exist_ok=True)
    cpath = tdir / "curriculum.json"
    checkpoint, cpath = checkpoint_paths(tdir)
    resume = checkpoint is not None
    v4 = args.curriculum == "v4"
    if cpath.exists() and (resume or args.resume or args.rotate):
        # 저장된 진행 상태가 v4 면 대시보드의 "이어서"도 v4 로 이어 간다
        v4 = v4 or json.loads(cpath.read_text(encoding="utf-8")).get("curriculum_version") == curriculum_v4.VERSION
    cls, ids = (CurriculumV4, curriculum_v4.STAGE_IDS) if v4 else (Curriculum, STAGE_IDS)
    kw = dict(entropy_boost=args.entropy_boost, entropy_steps=args.entropy_steps) if v4 else {}
    start = ids.index(args.start_stage) if args.start_stage else 0
    if cpath.exists() and (resume or args.resume or args.rotate):
        cur = cls.load(cpath, tank, review_prob=args.review_prob, seed=args.seed, **kw)
    else:
        cur = cls(tank, start_stage=start, review_prob=args.review_prob, seed=args.seed, **kw)
    cur.review_prob = ctl.review_prob
    cur.terrain_fixed = args.terrain_course
    if args.terrain_course and cur.stage["id"] != "drive_terrain":
        cur.set_stage("drive_terrain", 0)
    ctl.curriculum = cur
    ctl.info.update({"tank": tank, "target_timesteps": None})
    ctl.write_status(None, force=True, phase="starting")
    inference_device = "cpu" if args.device in ("auto", "hybrid") else args.resolved_device
    pool = OpponentPool(pool_dir, exclude=tank, device=inference_device)
    env = GodotVecEnv(args.n_envs, args.godot, args.project, run_dir, tank, cur, opponents=pool,
                      seed=args.seed * 1000 + sum(map(ord, tank)), record_every=ctl.record_every,
                      quiet=not args.verbose_godot, run_name=run_dir.name)
    ctl.env = env
    latest = tdir / "latest.zip"
    if resume and not (args.resume or args.rotate):
        print(f"[train] 기존 {tank} 체크포인트 보호: 자동으로 이어서 학습합니다", flush=True)
    try:
        model = build_model(args, env, checkpoint if resume else None)
        runtime = model_runtime(model, args.device)
        runtime['start_timesteps'] = model.num_timesteps
        runtime['resumed_from'] = str(checkpoint) if checkpoint else None
        ctl.info["runtime"] = runtime
        write_manifest(run_dir, args, env, runtime)
    except BaseException:
        env.close()
        ctl.env = None
        raise
    print(f"[train] {tank}: {'이어서 학습' if resume else '새 정책'}, "
          f"{model.num_timesteps} 스텝, 단계 {cur.stage['id']}", flush=True)
    print(f"[device] {runtime['device']} / {runtime['gpu_name'] or 'CPU'} / "
          f"torch {runtime['torch']} / batch {model.batch_size} / "
          f"rollout {runtime['rollout_size']} / {runtime['rollout_buffer']} / "
          f"추론 {runtime['inference_device']} / 갱신 {runtime['update_device']}", flush=True)
    fmt = ["csv", "stdout"]
    try:
        import tensorboard  # noqa: F401
        fmt.append("tensorboard")
    except ImportError:
        pass
    model.set_logger(configure(str(session_log_dir(run_dir, tank)), fmt))
    target = model.num_timesteps + steps
    ctl.model = model
    ctl.info["target_timesteps"] = target

    def version() -> str:
        return f"{run_dir.name}/{tank}/step_{model.num_timesteps:09d}"

    env.learner_version = version()
    env.policy_fn = lambda o: model.predict(o, deterministic=False)[0]

    class Cb(BaseCallback):
        def __init__(self):
            super().__init__()
            self.next_save = (model.num_timesteps // args.save_every + 1) * args.save_every

        def _on_rollout_start(self) -> None:
            if hasattr(cur, "entropy_coef"):
                model.ent_coef = cur.entropy_coef(args.ent_coef, self.num_timesteps)
            ctl.write_status(self.num_timesteps, force=True, phase="collecting")

        def _on_step(self) -> bool:
            env.learner_version = version()
            env.global_step = self.num_timesteps
            for info in self.locals.get("infos", []):
                if "success" in info:
                    self.logger.record_mean(f"success/{info['stage']}", float(info["success"]))
            if self.num_timesteps >= self.next_save:
                self.next_save += args.save_every
                save(snapshot=True)
            return ctl.tick(self.num_timesteps)

        def _on_rollout_end(self) -> None:
            self.logger.record("curriculum/stage_idx", cur.stage_idx)
            self.logger.record("curriculum/success_rate", cur.success_rate(cur.stage["id"], 100))
            if hasattr(cur, "shaping_scale"):
                self.logger.record("curriculum/shaping_scale", cur.shaping_scale(cur.stage["id"]))
                self.logger.record("train/ent_coef_scheduled", float(model.ent_coef))
            # 이제 PPO 갱신(몇 초). 그동안 Godot 은 기다리며 CPU 를 거의 안 쓴다
            ctl.write_status(self.num_timesteps, force=True, phase="updating")

    def save(snapshot: bool) -> None:
        ctl.write_status(model.num_timesteps, force=True, phase="saving")
        save_checkpoint(model, tdir, cur.state())
        pdir = pool_dir / tank
        pdir.mkdir(parents=True, exist_ok=True)
        atomic_copy(latest, pdir / "latest.zip")
        (pdir / "latest.json").write_text(json.dumps({"version": version(), "stage": cur.stage["id"]}),
                                          encoding="utf-8")
        if snapshot:
            name = f"step_{model.num_timesteps:09d}.zip"
            atomic_copy(latest, tdir / name)
            atomic_copy(latest, pdir / name)
        ctl.last_save = {"t": round(__import__("time").time(), 1), "version": version(), "snapshot": snapshot,
                         "stage": cur.stage["id"]}
        print(f"[train] {tank}: 저장 {version()} (단계 {cur.stage['id']})", flush=True)

    def on_checkpoint(_msg):
        save(snapshot=True)
        ctl.note(f"체크포인트 저장 {version()}")

    def on_set_stage(msg):
        ev = cur.set_stage(str(msg["stage"]), model.num_timesteps)
        if ev:
            env.log_stage_change(ev)
            ctl.note(f"단계 변경 {ev['from']} → {ev['to']}")

    ctl.handlers.update({"checkpoint": on_checkpoint, "set_stage": on_set_stage})
    try:
        model.learn(total_timesteps=steps, callback=Cb(), reset_num_timesteps=False, progress_bar=False)
    finally:
        try:
            save(snapshot=True)
        finally:
            env.close()
            ctl.env = ctl.model = ctl.curriculum = None


def main():
    args = parse()
    args.device = args.device.strip().lower()
    for name in ("n_envs", "save_every", "timesteps", "rotate_steps", "n_steps", "batch_size", "n_epochs"):
        value = getattr(args, name)
        if value is not None and value <= 0:
            raise ValueError(f"{name}는 1 이상이어야 합니다")
    if args.batch_size == 1:
        raise ValueError("PPO batch_size는 2 이상이어야 합니다")
    # Check the actual CUDA runtime before starting any simulator processes.
    args.resolved_device = resolve_device(args.device)
    set_torch_threads(args)
    run = args.run or dt.datetime.now().strftime("%Y%m%d_%H%M%S")
    run_dir = (Path(args.runs_dir) / run).resolve()
    run_dir.mkdir(parents=True, exist_ok=True)
    pool_dir = Path(args.pool_dir).resolve() if args.pool_dir else (Path(args.runs_dir) / "pool").resolve()
    with RunLock(run_dir):
        run_training(args, run_dir, pool_dir)


def run_training(args, run_dir: Path, pool_dir: Path) -> None:
    ctl = TrainController(run_dir, record_every=args.record_every, review_prob=args.review_prob,
                          speed_cap=args.speed_cap)
    try:
        if args.rotate:
            tanks = [t.strip() for t in args.rotate.split(",") if t.strip()]
            for c in range(args.cycles):
                for t in tanks:
                    if ctl.stop_requested:
                        break
                    print(f"[train] 교대 {c + 1}/{args.cycles}: {t} {args.rotate_steps} 스텝")
                    ctl.info["rotate"] = {"tanks": tanks, "cycle": c + 1, "cycles": args.cycles}
                    train_one(args, run_dir, pool_dir, t, args.rotate_steps, ctl)
        else:
            train_one(args, run_dir, pool_dir, args.tank, args.timesteps, ctl)
    finally:
        ctl.write_status(None, force=True, phase="stopped")
    print(f"[train] 끝. 보고서: python report.py {run_dir}")


def set_torch_threads(args) -> None:
    import os
    import torch
    if args.torch_threads < 0:
        raise ValueError("torch_threads는 0 이상이어야 합니다")
    n = args.torch_threads or (1 if args.resolved_device.startswith("cuda")
                             else max(1, (os.cpu_count() or 2) - args.n_envs))
    torch.set_num_threads(n)


if __name__ == "__main__":
    np.set_printoptions(precision=3, suppress=True)
    main()
