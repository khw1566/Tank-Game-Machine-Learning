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
from tankrl import battle_curriculum
from tankrl.battle_curriculum import BattleCurriculum
from tankrl import final_curriculum
from tankrl.final_curriculum import FinalCurriculum
from tankrl import v6_curriculum
from tankrl.v6_curriculum import V6Curriculum
from tankrl.control import write_json_atomic
from tankrl.godot_env import GodotVecEnv
from tankrl.health import HealthConfig, HealthMonitor
from tankrl.opponents import OpponentPool
from tankrl.runtime import model_runtime, resolve_device
from tankrl.terrain import COURSE_IDS, COURSES
from tankrl.storage import (RunLock, archive_runtime, atomic_copy, checkpoint_paths, default_runs_dir,
                            save_checkpoint, session_log_dir)


def parse():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--godot", required=True, help="Godot 4.3 실행 파일 또는 내보낸 TankGame.exe")
    ap.add_argument("--project", default=None, help="Godot 편집기 실행 파일을 쓸 때 프로젝트 폴더(내보낸 exe 면 생략)")
    ap.add_argument("--tank", default="tiger1", choices=["tiger1", "sherman75", "t34_76", "shared"],
                    help="shared = v4 공통 모델(세 전차를 한 모델로, 3부 T3 까지)")
    ap.add_argument("--auto-branch", action="store_true",
                    help="v4 공통 모델이 T3 를 마치면 전차별 모델로 복사해 T4~T6 을 --rotate-steps 씩 번갈아 학습")
    ap.add_argument("--branch-from", default="", help="v4: 이 실행 폴더의 shared 모델에서 전차별 모델을 시작(같은 실행이면 비움)")
    ap.add_argument("--max-std", type=float, default=1.0,
                    help="행동 잡음(gSDE 표준편차) 상한. 0 = 제한 없음. 성공이 없는 단계에서 잡음만 커져 행동이 ±1에 붙는 것을 막는다")
    ap.add_argument("--target-kl", type=float, default=0.05, help="PPO 갱신 중 approx KL 이 이 값을 넘으면 그 갱신의 남은 반복을 멈춘다(0 = 끔)")
    ap.add_argument("--use-sde", action="store_true",
                    help="새 정책을 gSDE 로 만든다(예전 방식). 기본은 행동별 표준편차. 이어서 학습하는 모델은 저장된 방식을 따른다")
    ap.add_argument("--log-std-init", type=float, default=-0.7, help="새 정책의 행동 표준편차 초기값(log, -0.7 ≈ 0.5)")
    ap.add_argument("--no-health", action="store_true",
                    help="건강 점검·정상 체크포인트 표시·자동 복구를 끈다(기본은 켜짐)")
    ap.add_argument("--rollback-limit", type=int, default=3, help="한 단계에서 자동 복구를 이만큼 하면 일시정지")
    ap.add_argument("--init-model", default="", help="체크포인트가 없을 때 이 모델 가중치로 시작(관측·행동 규격이 같아야 함)")
    ap.add_argument("--branch-tanks", default="tiger1,sherman75,t34_76", help="자동 분기할 전차 목록")
    ap.add_argument("--rotate", default="", help="여러 종류를 번갈아 학습: tiger1,sherman75,t34_76")
    ap.add_argument("--rotate-steps", type=int, default=300_000, help="교대마다 한 종류의 학습 스텝")
    ap.add_argument("--cycles", type=int, default=1, help="--rotate 반복 횟수")
    ap.add_argument("--timesteps", type=int, default=1_000_000, help="--rotate 가 없을 때 총 스텝(결정 수)")
    ap.add_argument("--n-envs", type=int, default=4, help="동시에 띄울 Godot 수(CPU 코어 수 정도)")
    ap.add_argument("--auto-envs", action="store_true",
                    help="V6: 동시 환경 수를 단계(적 수)에 맞게 자동으로 정하고, 승급하면 그 자리에서 다시 띄운다(--n-envs 무시)")
    ap.add_argument("--run", default="", help="실행 이름(runs/<run>). 비우면 날짜시각")
    ap.add_argument("--runs-dir", default=str(default_runs_dir()))
    ap.add_argument("--pool-dir", default="", help="자기대전 상대 정책 풀(기본 runs/pool)")
    ap.add_argument("--curriculum", default="v1", choices=["v1", "v4", "battle", "final", "v6"],
                    help="v1 = 기존 10단계, v4 = 결과 기반 보상·변형 혼합(기동·사격·전술·최종), 상황 관측 사용")
    ap.add_argument("--entropy-boost", type=float, default=0.003, help="v4: 단계 진입 직후 탐색 계수")
    ap.add_argument("--entropy-steps", type=int, default=300_000, help="v4: 탐색 계수를 기본값으로 줄이는 스텝 수")
    ap.add_argument("--start-stage", default="", choices=[""] + STAGE_IDS + curriculum_v4.STAGE_IDS + battle_curriculum.STAGE_IDS + final_curriculum.STAGE_IDS + v6_curriculum.STAGE_IDS,
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
    ap.add_argument("--ent-coef", type=float, default=0.001,
                    help="행동을 −1~1 로 자르는 구조에서는 잡음을 키워도 손해가 없어 큰 값이 잡음만 키운다")
    ap.add_argument("--gamma", type=float, default=0.995, help="할인율(결정 10Hz, 0.995 ≈ 반감기 14초). 이어받는 모델에도 적용")
    ap.add_argument("--gae-lambda", type=float, default=0.97, help="GAE λ. 이어받는 모델에도 적용")
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
                                "situation_obs_version": env.procs[0].hello.get("situation_obs_version", 0),
                                "driving_reward_version": env.procs[0].hello.get("driving_reward_version", 0),
                                "threat_obs_version": env.procs[0].hello.get("threat_obs_version", 0),
                                "projectile_version": env.procs[0].hello.get("projectile_version", 0),
                                "assessment_version": getattr(env.curriculum, "assessment_version", 1),
                                "balance_version": getattr(env.curriculum, "balance_version", 1),
                                "reward_version": getattr(env.curriculum, "reward_version", 1),
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
    overrides.update(gamma=args.gamma, gae_lambda=args.gae_lambda, ent_coef=args.ent_coef)
    if checkpoint is not None:
        if getattr(getattr(env, "curriculum", None), "version", 0) == v6_curriculum.VERSION:
            from tankrl.input_migration import migrate_for_env
            migrated = migrate_for_env(checkpoint, env, env.run_dir / "input_migrations")
            if migrated != Path(checkpoint).resolve():
                print(f"[model] 관측 입력 확장(적 슬롯 6): 기존 가중치·optimizer·누적 스텝 보존 → {migrated}", flush=True)
            checkpoint = migrated
        elif getattr(getattr(env, "curriculum", None), "obs", "") in ("situation_v3", "battle"):
            from tankrl.input_migration import expand_fire_inputs
            migrated = expand_fire_inputs(checkpoint, env.observation_space, env.run_dir / "input_migrations",
                                           allow_battle=env.curriculum.obs == "battle")
            if migrated != Path(checkpoint).resolve():
                print(f"[model] 사격 관측 입력 확장: 기존 가중치·optimizer·누적 스텝 보존 → {migrated}", flush=True)
            checkpoint = migrated
        return algorithm.load(str(checkpoint), env=env, device=device,
                              rollout_buffer_class=buffer_class, **overrides)
    n_steps = args.n_steps or 1024
    return algorithm("MlpPolicy", env, n_steps=n_steps,
               # 큰 롤아웃(환경 100개 이상)은 큰 미니배치가 GPU 에서 빠르고 기울기 잡음도 적다
               batch_size=args.batch_size or min(8192 if n_steps * env.num_envs >= 65536 else 2048, n_steps * env.num_envs),
               learning_rate=args.lr, gamma=args.gamma, gae_lambda=args.gae_lambda,
               ent_coef=args.ent_coef, clip_range=0.2, n_epochs=args.n_epochs or 8,
               # 새 정책 기본 = 행동별 표준편차(상한이 실제 행동 잡음에 그대로 적용된다).
               # gSDE 는 잡음 = 특징값 × 행렬이라 행렬을 제한해도 실제 잡음이 커질 수 있었다(V4RUN 1~3 에서 확인).
               policy_kwargs={"net_arch": [256, 256], "log_std_init": args.log_std_init},
               # gSDE noise must persist long enough for the tank gearbox to respond.
               use_sde=args.use_sde, sde_sample_freq=args.sde_freq if args.use_sde else -1, seed=args.seed,
               device=device, rollout_buffer_class=buffer_class, verbose=0)


def branch_source(args, run_dir: Path, tank: str):
    """전차별 모델의 시작점: 아직 체크포인트가 없는 전차 폴더 + 공통(shared) 체크포인트가 있으면 (모델, 커리큘럼, 설명)."""
    if tank == curriculum_v4.SHARED or (not args.branch_from and not args.auto_branch):
        return None
    src_run = Path(args.branch_from).resolve() if args.branch_from else run_dir
    sdir = src_run / curriculum_v4.SHARED
    model, cpath = checkpoint_paths(sdir)
    if model is None:
        return None
    saved = json.loads(cpath.read_text(encoding="utf-8"))
    cls = BattleCurriculum if saved.get("curriculum_version") == battle_curriculum.VERSION else CurriculumV4
    if args.curriculum == "battle" and cls is not BattleCurriculum:
        raise ValueError("전투 자기 대전의 분화 원본에는 완료된 전투 공통 모델이 필요합니다")
    shared = cls.load(cpath, curriculum_v4.SHARED, review_prob=args.review_prob, seed=args.seed,
                               entropy_boost=args.entropy_boost, entropy_steps=args.entropy_steps)
    info = json.loads((sdir / "checkpoint.json").read_text(encoding="utf-8")) if (sdir / "checkpoint.json").exists() else {}
    source = f"{src_run.name}/{curriculum_v4.SHARED}/step_{int(info.get('num_timesteps', 0)):09d}"
    return model, shared, source, info


def final_source(args):
    """최종 1대6: 전차별 모델의 시작 가중치 = V5 전투 공통 모델(--branch-from 실행의 shared) 또는 --init-model."""
    if args.init_model:
        path = Path(args.init_model).resolve()
        if not path.exists():
            raise ValueError(f"시작 모델이 없습니다: {path}")
        return path, f"{path.parent.name}/{path.name}", {}
    if not args.branch_from and args.curriculum == "v6" and (Path(args.runs_dir) / "V5run 1" / curriculum_v4.SHARED).exists():
        # V6 는 V5 공통 모델에서 시작한다: 지정이 없으면 기본 실행 "V5run 1" 을 쓴다
        args.branch_from = "V5run 1"
        print('[train] 시작 모델 실행이 비어 있어 기본값 "V5run 1" 을 사용합니다', flush=True)
    if not args.branch_from:
        raise ValueError("최종 학습의 첫 실행에는 --branch-from <V5 실행 폴더>(예: runs/\"V5run 1\") 또는 --init-model 이 필요합니다")
    src_run = Path(args.branch_from)
    if not src_run.is_absolute() and not src_run.exists():
        src_run = Path(args.runs_dir) / src_run
    src_run = src_run.resolve()
    sdir = src_run / curriculum_v4.SHARED
    model, _cpath = checkpoint_paths(sdir)
    if model is None:
        raise ValueError(f"시작할 공통 모델이 없습니다: {sdir}")
    info = json.loads((sdir / "checkpoint.json").read_text(encoding="utf-8")) if (sdir / "checkpoint.json").exists() else {}
    return model, f"{src_run.name}/{curriculum_v4.SHARED}/step_{int(info.get('num_timesteps', 0)):09d}", info


def clamp_exploration(model, args) -> None:
    """행동 잡음 상한과 KL 조기 중단(이어서 학습한 모델에도 적용). 상한에 걸리면 표준편차 로그에 그대로 보인다."""
    import math
    import torch
    model.target_kl = args.target_kl or None
    if args.max_std <= 0:
        return
    # HybridPPO: 갱신용(CUDA) 정책과 수집용(CPU) 복사본 모두. 수집 시작 콜백 시점의 model.policy 는 복사본이다.
    policies = {id(p): p for p in (model.policy, getattr(model, "_update_policy", None)) if p is not None}
    for policy in policies.values():
        log_std = getattr(policy, "log_std", None)
        if log_std is None:
            continue
        cap = args.max_std
        if getattr(policy, "use_sde", False):
            # gSDE: 행동 잡음 표준편차 = sqrt(Σ_j latent_j² · σ_ij²), latent 는 tanh(|·|≤1) 이고 256개.
            # 원소 상한을 max_std / sqrt(latent 수) 로 두어야 실제 잡음이 max_std 를 넘지 않는다(V4RUN-3 에서 확인).
            cap = args.max_std / math.sqrt(log_std.shape[0])
        with torch.no_grad():
            log_std.clamp_(min=math.log(min(0.05, cap * 0.5)), max=math.log(cap))
    if getattr(model.policy, "use_sde", False):
        model.policy.reset_noise(model.n_envs)


def train_one(args, run_dir: Path, pool_dir: Path, tank: str, steps: int, ctl: TrainController) -> bool:
    """반환: v4 공통 모델이 이번에 T3 를 마쳐 전차별 분기 준비가 됐으면 True."""
    from stable_baselines3.common.callbacks import BaseCallback
    from stable_baselines3.common.logger import configure

    tdir = run_dir / tank
    tdir.mkdir(parents=True, exist_ok=True)
    cpath = tdir / "curriculum.json"
    checkpoint, cpath = checkpoint_paths(tdir)
    resume = checkpoint is not None
    v6 = args.curriculum == "v6"
    final = args.curriculum in ("final", "v6")
    fmod, fcls = (v6_curriculum, V6Curriculum) if v6 else (final_curriculum, FinalCurriculum)
    if final and tank not in final_curriculum.TANKS:
        raise ValueError("최종 학습은 전차별 모델입니다: --rotate tiger1,sherman75,t34_76 로 실행하세요")
    final_src = final_source(args) if final and not resume else None
    branched = None if (resume or final) else branch_source(args, run_dir, tank)
    battle = final or args.curriculum == "battle" or (branched is not None and isinstance(branched[1], BattleCurriculum))
    v4 = args.curriculum == "v4" or tank == curriculum_v4.SHARED or branched is not None
    if final and cpath.exists() and resume:
        if json.loads(cpath.read_text(encoding="utf-8")).get("curriculum_version") != fmod.VERSION:
            raise ValueError("이 실행의 기존 모델은 최종 학습이 아닙니다. 새 --run 이름을 사용하세요")
    elif cpath.exists() and (resume or args.resume or args.rotate):
        # 저장된 진행 상태가 v4 면 대시보드의 "이어서"도 v4 로 이어 간다
        saved_version = json.loads(cpath.read_text(encoding="utf-8")).get("curriculum_version")
        if battle and saved_version != battle_curriculum.VERSION:
            raise ValueError("기존 실행은 다른 커리큘럼입니다. 전투 자기 대전에는 새 --run 이름을 사용하세요")
        battle = saved_version == battle_curriculum.VERSION
        v4 = v4 or saved_version == curriculum_v4.VERSION
    cls, ids = ((fcls, fmod.STAGE_IDS) if final else
                (BattleCurriculum, battle_curriculum.STAGE_IDS) if battle else
                (CurriculumV4, curriculum_v4.STAGE_IDS) if v4 else (Curriculum, STAGE_IDS))
    kw = dict(entropy_boost=args.entropy_boost, entropy_steps=args.entropy_steps) if v4 or battle else {}
    start = ids.index(args.start_stage) if args.start_stage else 0
    if final:
        review = args.review_prob if v6 else 0.0
        if resume:
            cur = fcls.load(cpath, tank, review_prob=review, seed=args.seed, **kw)
        elif v6:
            cur = fcls(tank, start_stage=start, review_prob=review, seed=args.seed, **kw)
        else:
            cur = fcls(tank, review_prob=0.0, seed=args.seed, **kw)
    elif branched is not None:
        cur = branched[1].branch(tank, 0, branched[2])
        print(f"[train] {tank}: 공통 모델 {branched[2]} 에서 분기, 단계 {cur.stage['id']}", flush=True)
    elif cpath.exists() and (resume or args.resume or args.rotate):
        cur = cls.load(cpath, tank, review_prob=args.review_prob, seed=args.seed, **kw)
    else:
        cur = cls(tank, start_stage=start, review_prob=args.review_prob, seed=args.seed, **kw)
    cur.review_prob = ctl.review_prob
    cur.terrain_fixed = args.terrain_course
    if args.terrain_course and cur.stage["id"] != "drive_terrain":
        cur.set_stage("drive_terrain", 0)
    ctl.curriculum = cur
    if getattr(cur, "training_complete", False):
        return tank == curriculum_v4.SHARED
    ctl.info.update({"tank": tank, "target_timesteps": None})
    ctl.write_status(None, force=True, phase="starting")
    inference_device = "cpu" if args.device in ("auto", "hybrid") else args.resolved_device
    pool = OpponentPool(pool_dir, exclude=None if battle else tank, device=inference_device)
    if final:
        # 아직 스냅숏이 없는 종류의 상대·아군은 V5 공통 모델(opponents/shared)이 조종한다
        src = final_src or (final_source(args) if (args.branch_from or args.init_model) else None)
        if src is not None:
            initial = pool_dir / "shared" / f"step_{int(src[2].get('num_timesteps', 0)):09d}.zip"
            if not initial.exists():
                atomic_copy(src[0], initial)
        elif not list((pool_dir / "shared").glob("step_*.zip")) and not list((pool_dir / tank).glob("step_*.zip")):
            raise ValueError("상대 풀이 비어 있습니다. --branch-from 으로 V5 공통 모델 실행을 지정하세요")
    if battle and branched is not None:
        initial = pool_dir / "shared" / f"step_{int(branched[3].get('num_timesteps', 0)):09d}.zip"
        if not initial.exists():
            atomic_copy(branched[0], initial)
    # 재개할 때마다 다른 배치 순서(같은 시드면 처음 수천 판이 매번 똑같이 반복됐다). 시드는 run.json 에 기록된다.
    resume_steps = int(json.loads((tdir / "checkpoint.json").read_text(encoding="utf-8")).get("num_timesteps", 0)) \
        if (tdir / "checkpoint.json").exists() else 0
    env_seed = args.seed * 1000 + sum(map(ord, tank)) + resume_steps
    cur.rng.seed(args.seed + resume_steps)
    ctl.info["env_seed"] = env_seed
    n_envs = env_count(args, cur)
    if n_envs != args.n_envs:
        print(f"[train] {tank}: 단계 {cur.stage['id']} → 동시 환경 {n_envs}개 (자동)", flush=True)
    ctl.env_restart = None
    env = GodotVecEnv(n_envs, args.godot, args.project, run_dir, tank, cur, opponents=pool,
                      seed=env_seed, record_every=ctl.record_every,
                      quiet=not args.verbose_godot, run_name=run_dir.name)
    ctl.env = env
    if v6:
        from tankrl.input_migration import migrate_pool
        moved = migrate_pool(pool_dir, env, run_dir / "input_migrations")
        if moved:
            print(f"[pool] 상대 스냅숏 관측 입력 확장: {', '.join(moved)}", flush=True)
    latest = tdir / "latest.zip"
    if resume and not (args.resume or args.rotate):
        print(f"[train] 기존 {tank} 체크포인트 보호: 자동으로 이어서 학습합니다", flush=True)
    try:
        init = Path(args.init_model).resolve() if args.init_model and not resume and not branched and not final else None
        model = build_model(args, env, checkpoint if resume else (final_src[0] if final_src else
                                                                  branched[0] if branched else init))
        if final_src is not None:
            ev = cur.initialize_from(final_src[1], model.num_timesteps)
            write_json_atomic(tdir / "branch.json", {"source": final_src[1], "source_checkpoint": final_src[2],
                                                     "source_model": str(final_src[0]), "tank": tank,
                                                     "start_stage": cur.stage["id"], "curriculum": args.curriculum})
            env.log_stage_change(ev)
        if battle and not resume:
            cur.stage_start_step = model.num_timesteps
        if branched is not None:
            cur.stage_start_step = model.num_timesteps
            cur.history[-1]["global_step"] = model.num_timesteps
            write_json_atomic(tdir / "branch.json", {"source": branched[2], "source_checkpoint": branched[3],
                                                     "source_model": str(branched[0]), "tank": tank,
                                                     "start_stage": cur.stage["id"]})
        if cur.history and cur.history[-1].get("reason") == "assessment_upgrade":
            cur.stage_start_step = model.num_timesteps
            cur.history[-1]["global_step"] = model.num_timesteps
            print(f"[curriculum] 평가 v{cur.assessment_version}: 기존 모델을 유지하고 {cur.stage['id']}부터 진행합니다", flush=True)
        runtime = model_runtime(model, args.device)
        runtime["input_migration"] = getattr(model, "input_migration", None)
        runtime['start_timesteps'] = model.num_timesteps
        runtime['resumed_from'] = str(checkpoint) if checkpoint else (str(branched[0]) if branched else None)
        runtime['branched_from'] = branched[2] if branched else (final_src[1] if final_src else None)
        runtime['initialized_from'] = str(init) if init else None
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
    health = None if args.no_health else HealthMonitor(
        tdir, HealthConfig(std_cap=args.max_std, max_rollbacks=args.rollback_limit))

    def stage_success() -> float | None:
        """현재 단계 성공률: 기록이 있는 변형 × 전차의 최근 40판 평균(없으면 None)."""
        sid = cur.stage["id"]
        if hasattr(cur, "variant_rates"):
            rates = [v for k, v in cur.variant_rates(sid, 40).items() if cur.results[sid][k]]
            return round(sum(rates) / len(rates), 4) if rates else None
        return cur.success_rate(sid, 100) if cur.results[sid] else None

    def health_check(step: int, logged: dict) -> None:
        if health is None or "train/approx_kl" not in logged:
            return
        stage = cur.stage["id"]
        result = health.check(step, stage, logged, stage_success(), model)
        if result["verdict"] != "collapse":
            return
        ev = {"tank": tank, "from": stage, "to": stage, "episodes": cur.episodes_in_stage,
              "success_rate": result.get("success") or 0.0, "global_step": step, "causes": result["reasons"],
              "best_success": result.get("best_success")}
        if health.over_limit(stage):
            ev["reason"] = "rollback_limit"
            env.log_stage_change(ev)
            ctl.paused = True
            ctl.note(f"자동 복구 {health.config.max_rollbacks}회 초과: 일시정지 ({', '.join(result['reasons'])})")
            return
        target = health.rollback(model, stage)
        if target is None:
            ev["reason"] = "collapse_no_backup"
            env.log_stage_change(ev)
            ctl.note(f"망가짐 감지({', '.join(result['reasons'])}) — 되돌릴 정상 체크포인트 없음")
            return
        ev.update(reason="rollback", restored_step=target["step"], restored_path=target["path"],
                  rollback_count=target["count"])
        env.log_stage_change(ev)
        ctl.note(f"자동 복구: {', '.join(result['reasons'])} → step {target['step']:,} ({target['count']}/{target['limit']})")
    if cur.history and cur.history[-1].get("reason") == "assessment_upgrade":
        env.log_stage_change(cur.history[-1])

    class Cb(BaseCallback):
        def __init__(self):
            super().__init__()
            self.next_save = (model.num_timesteps // args.save_every + 1) * args.save_every

        def _on_rollout_start(self) -> None:
            if hasattr(cur, "entropy_coef"):
                model.ent_coef = cur.entropy_coef(args.ent_coef, self.num_timesteps)
            clamp_exploration(model, args)
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
            if getattr(cur, "training_complete", False):
                print("[train] 모든 세부 항목 통과: 현재 커리큘럼 학습을 마칩니다", flush=True)
                return False
            if args.auto_envs and env_count(args, cur) != env.num_envs:
                # 승급으로 적 수가 바뀌었다: 저장하고 이 전차의 남은 스텝을 새 환경 수로 이어서 한다
                ctl.env_restart = {"tank": tank, "remaining": max(0, target - self.num_timesteps),
                                   "from": env.num_envs, "to": env_count(args, cur), "stage": cur.stage["id"]}
                print(f"[train] {tank}: 단계 {cur.stage['id']} → 동시 환경 {env.num_envs} → {ctl.env_restart['to']}개로 다시 띄웁니다", flush=True)
                return False
            return ctl.tick(self.num_timesteps)

        def _on_rollout_end(self) -> None:
            # 직전 PPO 갱신의 지표(train/*)는 다음 로그 출력 전까지 logger 에 남아 있다
            health_check(self.num_timesteps, dict(self.logger.name_to_value))
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
            if battle:
                # 콜백 저장 직후 PPO 갱신/재개/복구로 같은 스텝에 다른 가중치가 생길 수 있다.
                # 기존 상대 파일을 덮어쓰면 경기 도중 상대가 바뀌므로 매번 새 경로를 만든다.
                name = f"step_{model.num_timesteps:09d}_{__import__('time').time_ns():020d}.zip"
            atomic_copy(latest, tdir / name)
            atomic_copy(latest, pdir / name)
            if health is not None:
                health.mark_saved(model.num_timesteps, cur.stage["id"], tdir / name, stage_success())
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
        if battle:
            # reset()에서 상대를 고르기 전에 초기/재개 정책의 고정 복사본이 반드시 있어야 한다.
            save(snapshot=True)
        model.learn(total_timesteps=steps, callback=Cb(), reset_num_timesteps=False, progress_bar=False)
    finally:
        try:
            # Final saving no longer needs live simulators. Release their memory
            # before ZIP validation, hashing and serialization under memory pressure.
            env.close()
        finally:
            ctl.env = None
            try:
                __import__('gc').collect()
                save(snapshot=True)
            finally:
                ctl.model = ctl.curriculum = None
    return bool(getattr(cur, "common_complete", False)) and tank == curriculum_v4.SHARED


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
    manifest = run_dir / "run.json"
    if manifest.exists() and json.loads(manifest.read_text(encoding="utf-8")).get("curriculum_version") == battle_curriculum.VERSION:
        if args.curriculum == "final":
            raise ValueError(f"{run} 은 V5 전투 실행입니다. 최종 학습은 새 실행 이름(예: FINAL-1)에 --branch-from \"{run}\" 으로 시작하세요")
        args.curriculum = "battle"
    elif manifest.exists() and json.loads(manifest.read_text(encoding="utf-8")).get("curriculum_version") == final_curriculum.VERSION:
        args.curriculum = "final"
    elif manifest.exists() and json.loads(manifest.read_text(encoding="utf-8")).get("curriculum_version") == v6_curriculum.VERSION:
        args.curriculum = "v6"
    pool_dir = Path(args.pool_dir).resolve() if args.pool_dir else (
        run_dir / "opponents" if args.curriculum in ("battle", "final", "v6") else (Path(args.runs_dir) / "pool").resolve())
    with RunLock(run_dir):
        run_training(args, run_dir, pool_dir)


def env_count(args, cur) -> int:
    """--auto-envs 이고 단계가 환경 비율을 갖고 있으면 단계별 자동 값, 아니면 --n-envs."""
    if getattr(args, "auto_envs", False) and "envs_per_core" in cur.stage:
        return v6_curriculum.auto_envs(cur.stage)
    return args.n_envs


def train_turn(args, run_dir: Path, pool_dir: Path, tank: str, steps: int, ctl) -> bool:
    """train_one + 자동 환경 수: 학습 중 승급해 환경 수가 바뀌면 남은 스텝을 새 환경 수로 이어서 학습한다."""
    result = train_one(args, run_dir, pool_dir, tank, steps, ctl)
    while getattr(ctl, "env_restart", None) and not ctl.stop_requested:
        info, ctl.env_restart = ctl.env_restart, None
        if info["remaining"] <= 0:
            break
        result = train_one(args, run_dir, pool_dir, tank, info["remaining"], ctl)
    return result


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
                    train_turn(args, run_dir, pool_dir, t, args.rotate_steps, ctl)
        else:
            done_common = train_turn(args, run_dir, pool_dir, args.tank, args.timesteps, ctl)
            if done_common and args.auto_branch and not ctl.stop_requested:
                tanks = [t.strip() for t in args.branch_tanks.split(",") if t.strip()]
                for c in range(args.cycles):
                    for t in tanks:
                        if ctl.stop_requested:
                            break
                        print(f"[train] 전차별 분기 {c + 1}/{args.cycles}: {t} {args.rotate_steps} 스텝", flush=True)
                        ctl.info["rotate"] = {"tanks": tanks, "cycle": c + 1, "cycles": args.cycles, "branch": True}
                        train_turn(args, run_dir, pool_dir, t, args.rotate_steps, ctl)
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
