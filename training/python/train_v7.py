"""Train V7 in native Godot and optionally initialize from its human-play recordings."""
from __future__ import annotations

import argparse
import csv
import datetime as dt
import json
import tempfile
import time
import uuid
from collections import Counter
from pathlib import Path

import gymnasium as gym
import numpy as np
import stable_baselines3 as sb3
import torch
from stable_baselines3 import PPO
from stable_baselines3.common.callbacks import BaseCallback
from stable_baselines3.common.logger import configure
from stable_baselines3.common.vec_env import DummyVecEnv

from tankrl.control import TrainController, write_json_atomic
from tankrl.storage import (RunLock, checkpoint_paths, data_root, default_runs_dir,
                            save_checkpoint, session_log_dir)
from tankrl.runtime import v7_game_path
from tankrl.v7_godot import ACTION_LABELS, CATALOG_SHA256, OBS_LABELS, PROTOCOL, NativeGodotEnv
from tankrl.v7_curriculum import STAGES, STAGE_IDS, STAGESET, TANKS, VERSION, V7Curriculum
from tankrl.v7_imitation import ALLIES, clone_actor, read_demonstration

FIELDS = ["wall_time", "global_step", "env", "uid", "tank", "stage", "stage_idx", "current_stage",
          "success", "reason", "return", "decisions", "seed", "variant", "layout_id", "source_seed", "learner_policy",
          "objective_id", "objective_version", "objective_label", "reward_components", "side_seen_count"]


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def parse(argv=None):
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--run", default="V7-Godot-3")
    p.add_argument("--godot", default=str(v7_game_path()), help="게임 실행 파일 또는 Godot 편집기")
    p.add_argument("--project", type=Path, help="편집기로 실행할 때 project.godot가 있는 폴더")
    p.add_argument("--runs-dir", type=Path, default=default_runs_dir())
    group = p.add_mutually_exclusive_group()
    group.add_argument("--tank", choices=TANKS, default="tiger1")
    group.add_argument("--rotate", help="학습할 차종을 쉼표로 구분")
    p.add_argument("--rotate-steps", type=int, default=65536)
    p.add_argument("--cycles", type=int, default=10)
    p.add_argument("--timesteps", type=int, default=65536)
    p.add_argument("--n-envs", type=int, default=8)
    p.add_argument("--seed", type=int, default=7)
    p.add_argument("--save-every", type=int, default=16384)
    p.add_argument("--device", choices=["auto", "cpu"], default="auto")
    p.add_argument("--prepare-only", action="store_true", help="세 모델을 무작위 초기화하고 0스텝에서 저장")
    p.add_argument("--resume", action="store_true")
    p.add_argument("--behavior-clone", action="store_true", help="선택한 연합군 모델에 직접 수집한 시범을 먼저 적용")
    p.add_argument("--demos-dir", type=Path, default=data_root() / "v7_godot_control_demos")
    args = p.parse_args(argv)
    if (not args.run.strip() or args.run in (".", "..") or Path(args.run).name != args.run
            or "/" in args.run or "\\" in args.run):
        p.error("실행 이름에는 폴더 경로를 사용할 수 없습니다")
    if min(args.n_envs, args.rotate_steps, args.cycles, args.timesteps, args.save_every) < 1:
        p.error("환경 수와 학습·저장 간격은 양수여야 합니다")
    if not 0 <= args.seed <= 2**32 - len(TANKS):
        p.error("시드는 0 이상 32비트 범위여야 합니다")
    tanks = args.rotate.split(",") if args.rotate else [args.tank]
    if any(t not in TANKS for t in tanks) or len(set(tanks)) != len(tanks):
        p.error("차종 목록을 확인하세요")
    return args


def now():
    return dt.datetime.now().astimezone().isoformat(timespec="seconds")


def load_manifest(run, args):
    path = run / "run.json"
    if path.exists():
        m = read_json(path)
        if (m.get("environment") != PROTOCOL or m.get("stageset") != STAGESET or m.get("curriculum_version") != VERSION
                or m.get("layout_catalog_sha256") != CATALOG_SHA256
                or m.get("obs_labels") != list(OBS_LABELS) or m.get("action_labels") != list(ACTION_LABELS)):
            raise ValueError("Godot V7 전용 실행을 선택하세요. 기존 시범과 모델은 원래 실행에 보관됩니다")
        if not args.resume:
            raise FileExistsError("이미 준비된 실행입니다. 같은 V7을 이어가려면 --resume을 지정하세요")
        return m
    if args.resume:
        raise FileNotFoundError("재개할 V7 실행이 없습니다")
    if any(p.name not in (".training.lock", "train_log.txt") for p in run.iterdir()):
        raise FileExistsError(f"기존 파일이 있는 실행 폴더입니다: {run}")
    m = {"format": "tankgame-train-run", "version": 1, "stageset": STAGESET, "curriculum_version": VERSION,
         "environment": PROTOCOL, "layout_catalog_sha256": CATALOG_SHA256,
         "stages": STAGES, "created": now(), "seed": args.seed, "obs_labels": list(OBS_LABELS),
         "action_labels": list(ACTION_LABELS), "initialization": "random", "initial_models": {},
         "preparation": "initializing", "sessions": []}
    write_json_atomic(path, m)
    return m


def prepare(run, manifest):
    if manifest["preparation"] != "initializing":
        return
    for index, tank in enumerate(TANKS):
        dest = run / tank
        seed = manifest["seed"] + index
        if not dest.exists():
            env = NativeGodotEnv(tank, STAGE_IDS[0])
            try:
                model = PPO("MlpPolicy", env, device="cpu", seed=seed, n_steps=128, batch_size=128,
                            n_epochs=6, learning_rate=0.0003, verbose=0)
                with tempfile.TemporaryDirectory(dir=run) as temp:
                    draft = Path(temp) / tank
                    save_checkpoint(model, draft, V7Curriculum(tank).state())
                    draft.rename(dest)
            finally:
                env.close()
        model_path, _ = checkpoint_paths(dest)
        meta = read_json(dest / "checkpoint.json")
        if model_path is None or meta["num_timesteps"] != 0:
            raise ValueError(f"0스텝 초기화가 중단됐습니다: {dest}")
        manifest["initial_models"][tank] = {**meta, "seed": seed, "origin": "random",
                                            "updates": 0, "optimizer_entries": 0}
    manifest["preparation"] = "ready"
    write_json_atomic(run / "run.json", manifest)


class EpisodeLogger(gym.Wrapper):
    def __init__(self, cur, args):
        self.cur = cur
        self.stage_id = cur.stage["id"]
        super().__init__(NativeGodotEnv(cur.tank, self.stage_id, args.godot, args.project))

    def reset(self, *, seed=None, options=None):
        if seed is not None or not hasattr(self, "seeds"):
            self.seeds = np.random.default_rng(seed)
        self.stage_id = self.env.stage_id = self.cur.stage["id"]
        self.episode_seed = int(self.seeds.integers(0, 2**32))
        self.components = Counter()
        self.score = 0.
        self.steps = 0
        return self.env.reset(seed=self.episode_seed, options=options)

    def step(self, action):
        obs, reward, terminated, truncated, info = self.env.step(action)
        self.score += float(reward)
        self.steps += 1
        self.components.update(info["reward_components"])
        if terminated or truncated:
            success = bool(info["is_success"])
            promoted = self.cur.record(self.stage_id, success)
            stage = STAGES[STAGE_IDS.index(self.stage_id)]
            info["arcade_episode"] = {
                "stage": self.stage_id, "stage_idx": STAGE_IDS.index(self.stage_id),
                "success": int(success), "reason": info["reason"], "return": round(self.score, 5),
                "decisions": self.steps, "seed": self.episode_seed, "variant": info["layout"]["map_id"],
                "layout_id": info["layout"]["layout_id"], "source_seed": info["layout"]["source_seed"],
                "objective_id": self.stage_id, "objective_version": 7, "objective_label": stage["label"],
                "side_seen_count": info.get("side_seen_count", 0),
                "reward_components": json.dumps(dict(self.components), separators=(",", ":"))}
            if promoted:
                info["arcade_promotion"] = dict(self.cur.history[-1])
        return obs, reward, terminated, truncated, info


def apply_demonstrations(run, args, requested):
    """Bind imitation and its provenance to the same immutable checkpoint."""
    paths_by_tank = {}
    for tank in requested:
        if tank not in ALLIES:
            continue
        model_path, state_path = checkpoint_paths(run / tank)
        state = read_json(state_path)
        if state.get("behavior_clone"):
            continue
        if read_json(run / tank / "checkpoint.json")["num_timesteps"]:
            raise ValueError(f"{tank}: PPO가 이미 시작되어 초기 행동 복제를 적용할 수 없습니다")
        paths = sorted((args.demos_dir / tank).glob("*.json"))
        if not paths:
            raise ValueError(f"{tank}: 저장된 시범이 없습니다. 이 차종의 경기를 수집하거나 시범이 있는 차종만 선택하세요")
        for path in paths:
            read_demonstration(path, tank)
        paths_by_tank[tank] = (model_path, state, paths)
    for tank, (path, state, paths) in paths_by_tank.items():
        model = PPO.load(path, device="cpu")
        state["behavior_clone"] = clone_actor(model, paths, tank, int(model.seed))
        save_checkpoint(model, run / tank, state)
        print(f"[V7] {tank} 행동 복제 {len(paths)}경기, PPO 시작 스텝 0", flush=True)


def train_turn(run, args, manifest, ctl, tank, target):
    path, state_path = checkpoint_paths(run / tank)
    saved = read_json(state_path)
    cur = V7Curriculum.from_state(saved)
    if cur.tank != tank:
        raise ValueError(f"체크포인트 차종 불일치: {tank}")
    env = DummyVecEnv([lambda: EpisodeLogger(cur, args) for _ in range(args.n_envs)])
    logger = None
    try:
        for wrapped in env.envs:
            wrapped.unwrapped.connect()
        model = PPO.load(path, env=env, device="cpu")
        start = model.num_timesteps
        session = len(manifest["sessions"])
        seed = int(np.random.SeedSequence([manifest["seed"], TANKS.index(tank), start, session]).generate_state(1)[0])
        model.set_random_seed(seed)
        env.episode_count = cur.total_episodes
        env.learner_version = f"{run.name}/{tank}/step_{start:09d}"
        hello = env.envs[0].unwrapped.hello
        runtime = {"environment": PROTOCOL, "godot": args.godot, "project": str(args.project) if args.project else None,
                   "engine": hello["engine"], "physics_hz": hello["physics_hz"], "repeat": hello["repeat"],
                   "requested_device": args.device, "device": "cpu", "start_timesteps": start,
                   "n_envs": args.n_envs, "sampling_seed": seed, "initialized_from": None, "branched_from": None,
                   "resumed_from": str(path.relative_to(run)) if start else None,
                   "initialization": "random", "behavior_clone": saved.get("behavior_clone")}
        recorded = {k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()}
        manifest["sessions"].append({"started": now(), "args": dict(recorded, curriculum="v7"),
                                      "runtime": runtime, "tank": tank, "torch": str(torch.__version__),
                                      "stable_baselines3": sb3.__version__})
        write_json_atomic(run / "run.json", manifest)
        ctl.env, ctl.model, ctl.curriculum = env, model, cur
        ctl.info.update(tank=tank, runtime=runtime, target_timesteps=target)
        ctl._rate.clear()
        ctl.write_status(start, force=True, phase="collecting")
        logger = configure(str(session_log_dir(run, tank)), ["csv"])
        model.set_logger(logger)
        next_save = (start // args.save_every + 1) * args.save_every

        def save():
            state = cur.state()
            if "behavior_clone" in saved:
                state["behavior_clone"] = saved["behavior_clone"]
            ctl.write_status(model.num_timesteps, force=True, phase="saving")
            save_checkpoint(model, run / tank, state)
            ctl.last_save = {"t": time.time(), "version": f"{run.name}/{tank}/step_{model.num_timesteps:09d}",
                             "stage": cur.stage["id"], "snapshot": True}

        ctl.handlers["checkpoint"] = lambda msg: save()
        csv_path = run / "progress.csv"
        with csv_path.open("a", encoding="utf-8", newline="") as stream:
            writer = csv.DictWriter(stream, fieldnames=FIELDS)
            if stream.tell() == 0:
                writer.writeheader()

            class LogCallback(BaseCallback):
                def _on_step(self):
                    nonlocal next_save
                    env.learner_version = f"{run.name}/{tank}/step_{self.num_timesteps:09d}"
                    env.episode_count = cur.total_episodes
                    for idx, info in enumerate(self.locals["infos"]):
                        if "arcade_episode" in info:
                            writer.writerow(dict(info["arcade_episode"], wall_time=time.time(), uid=uuid.uuid4().hex,
                                                 tank=tank, env=idx, global_step=self.num_timesteps,
                                                 learner_policy=env.learner_version, current_stage=cur.stage["id"]))
                            stream.flush()
                        if "arcade_promotion" in info:
                            with (run / "curriculum_log.jsonl").open("a", encoding="utf-8") as log:
                                event = dict(info["arcade_promotion"], tank=tank, step=self.num_timesteps, time=now())
                                log.write(json.dumps(event, ensure_ascii=False) + "\n")
                    if self.num_timesteps >= next_save:
                        save()
                        next_save = (self.num_timesteps // args.save_every + 1) * args.save_every
                    return ctl.tick(self.num_timesteps)

                def _on_rollout_end(self):
                    self.logger.record("curriculum/stage_idx", cur.stage_idx)
                    self.logger.record("curriculum/success_rate", cur.success_rate(cur.stage["id"]))
                    ctl.write_status(self.num_timesteps, force=True, phase="updating")

            try:
                model.learn(total_timesteps=target - start, reset_num_timesteps=False, callback=LogCallback())
            finally:
                save()
    finally:
        if logger is not None:
            logger.close()
        env.close()
        ctl.env = ctl.model = ctl.curriculum = None
        ctl.handlers.pop("checkpoint", None)


def main(argv=None):
    args = parse(argv)
    torch.set_num_threads(1)
    run = args.runs_dir.resolve() / args.run
    run.mkdir(parents=True, exist_ok=True)
    tanks = args.rotate.split(",") if args.rotate else [args.tank]
    with RunLock(run):
        manifest = load_manifest(run, args)
        prepare(run, manifest)
        if args.prepare_only:
            if manifest["sessions"]:
                raise ValueError("학습 이력이 있는 실행입니다. 초기 모델은 run.json의 initial_models에서 확인하세요")
            if manifest["stages"] != STAGES:
                manifest["stages"] = STAGES
                write_json_atomic(run / "run.json", manifest)
            print(f"[V7] 초기 모델 3개 준비 완료: {run}")
            return
        if args.behavior_clone:
            apply_demonstrations(run, args, tanks)
        config = {"tanks": tanks, "cycles": args.cycles if args.rotate else 1,
                  "steps": args.rotate_steps if args.rotate else args.timesteps}
        schedule = manifest.get("schedule", {})
        if schedule.get("config") != config or schedule.get("completed"):
            schedule = {"config": config, "base": {t: read_json(run / t / "checkpoint.json")["num_timesteps"]
                                                    for t in tanks}, "completed": False}
            manifest["schedule"] = schedule
            write_json_atomic(run / "run.json", manifest)
        ctl = TrainController(run, record_every=0, review_prob=0)
        try:
            for cycle in range(1, config["cycles"] + 1):
                for tank in tanks:
                    target = schedule["base"][tank] + cycle * config["steps"]
                    if read_json(run / tank / "checkpoint.json")["num_timesteps"] < target:
                        if args.rotate:
                            ctl.info["rotate"] = {"cycle": cycle, "cycles": config["cycles"], "tanks": tanks}
                        train_turn(run, args, manifest, ctl, tank, target)
                    if ctl.stop_requested:
                        return
            schedule["completed"] = True
            write_json_atomic(run / "run.json", manifest)
        finally:
            ctl.write_status(None, force=True, phase="stopped")


if __name__ == "__main__":
    main()
