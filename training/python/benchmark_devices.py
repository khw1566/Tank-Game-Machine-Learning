"""Compare CPU/CUDA with real Godot environments without saving over a training checkpoint."""
from __future__ import annotations

import argparse
import datetime as dt
import json
from pathlib import Path
import statistics
import time

import torch
from stable_baselines3.common.callbacks import BaseCallback
from stable_baselines3.common.logger import configure

from tankrl.curriculum import Curriculum, STAGE_IDS
from tankrl.godot_env import GodotVecEnv
from tankrl.runtime import gpu_memory, model_runtime, resolve_device
from train import build_model, set_torch_threads


class Timings(BaseCallback):
    def __init__(self, device):
        super().__init__()
        self.device = device
        self.collect_s = []
        self.update_s = []
        self.update_start = None

    def sync(self):
        if self.device.startswith("cuda"):
            torch.cuda.synchronize(self.device)

    def finish_update(self):
        if self.update_start is not None:
            self.sync()
            self.update_s.append(time.perf_counter() - self.update_start)
            self.update_start = None

    def _on_rollout_start(self):
        self.finish_update()
        self.collect_start = time.perf_counter()

    def _on_step(self):
        return True

    def _on_rollout_end(self):
        self.sync()
        self.collect_s.append(time.perf_counter() - self.collect_start)
        self.update_start = time.perf_counter()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", required=True)
    ap.add_argument("--project", default=None)
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--devices", default="cpu,cuda,hybrid")
    ap.add_argument("--stage", default="drive", choices=STAGE_IDS)
    ap.add_argument("--tank", default="tiger1")
    ap.add_argument("--n-envs", type=int, default=8)
    ap.add_argument("--rollouts", type=int, default=2)
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--n-steps", type=int, default=None)
    ap.add_argument("--batch-size", type=int, default=None)
    ap.add_argument("--n-epochs", type=int, default=None)
    ap.add_argument("--out", default="")
    a = ap.parse_args()
    if min(a.n_envs, a.rollouts, a.repeats) < 1:
        ap.error("n-envs, rollouts and repeats must be positive")
    # Validate all devices before launching anything; checkpoint is only read.
    devices = [(d.strip(), resolve_device(d.strip())) for d in a.devices.split(",")]
    out = Path(a.out or f"runs/device_benchmark_{dt.datetime.now():%Y%m%d_%H%M%S}").resolve()
    out.mkdir(parents=True, exist_ok=True)
    results = []
    for repeat in range(a.repeats):
        for requested, device in devices:
            run = out / f"{requested.replace(':', '_')}_{repeat + 1}"
            if run.exists():
                raise ValueError(f"Benchmark directory already exists: {run}")
            config = argparse.Namespace(device=requested, resolved_device=device, n_envs=a.n_envs,
                                        n_steps=a.n_steps, batch_size=a.batch_size, n_epochs=a.n_epochs,
                                        torch_threads=0, lr=3e-4, ent_coef=0.005, sde_freq=20, seed=0)
            set_torch_threads(config)
            cur = Curriculum(a.tank, start_stage=STAGE_IDS.index(a.stage), review_prob=0, seed=0)
            env = GodotVecEnv(a.n_envs, a.godot, a.project, run, a.tank, cur,
                              seed=sum(map(ord, a.tank)), record_every=0)
            try:
                model = build_model(config, env, Path(a.checkpoint))
                model.set_logger(configure(str(run / "sb3"), ["csv"]))
                env.policy_fn = lambda obs: model.predict(obs, deterministic=False)[0]
                env.learner_version = "device-benchmark"
                timing = Timings(device)
                start_steps = model.num_timesteps
                start = time.perf_counter()
                model.learn(model.n_steps * a.n_envs * a.rollouts, callback=timing,
                            reset_num_timesteps=False, progress_bar=False)
                timing.finish_update()
                wall = time.perf_counter() - start
                steps = model.num_timesteps - start_steps
                measured = sum(timing.collect_s) + sum(timing.update_s)
                result = {"repeat": repeat + 1, "runtime": model_runtime(model, requested),
                          "n_envs": a.n_envs, "steps": steps, "wall_s": round(wall, 4),
                          "steady_steps_per_s": round(steps / measured, 2),
                          "collect_s": timing.collect_s, "update_s": timing.update_s,
                          "median_collect_s": statistics.median(timing.collect_s),
                          "median_update_s": statistics.median(timing.update_s),
                          "gpu_memory": gpu_memory(device),
                          "finite_parameters": all(torch.isfinite(p).all().item() for p in model.policy.parameters())}
                results.append(result)
                (out / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
                print(json.dumps(result), flush=True)
            finally:
                env.close()
    print(f"Results: {out / 'results.json'}", flush=True)


if __name__ == "__main__":
    main()
