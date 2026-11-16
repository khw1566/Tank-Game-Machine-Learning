"""무작위 행동으로 Godot 학습 환경을 짧게 돌려 연결·리셋·기록을 확인한다.
python -m tests.smoke_env --godot <godot> --project <프로젝트 폴더> [--stage gunnery_static] [--steps 600]"""
import argparse
import time

import numpy as np

from tankrl.curriculum import STAGE_IDS, Curriculum
from tankrl.godot_env import GodotVecEnv

ap = argparse.ArgumentParser()
ap.add_argument("--godot", required=True)
ap.add_argument("--project", default=None)
ap.add_argument("--stage", default="drive")
ap.add_argument("--tank", default="tiger1")
ap.add_argument("--steps", type=int, default=600)
ap.add_argument("--n-envs", type=int, default=2)
ap.add_argument("--run-dir", default="runs/smoke")
ap.add_argument("--record-every", type=int, default=0)
a = ap.parse_args()
cur = Curriculum(a.tank, start_stage=STAGE_IDS.index(a.stage), review_prob=0.0)
env = GodotVecEnv(a.n_envs, a.godot, a.project, a.run_dir, a.tank, cur, record_every=a.record_every, quiet=False)
env.learner_version = "random"
env.policy_fn = lambda o: np.random.uniform(-1, 1, (len(o), env.action_space.shape[0]))
obs = env.reset()
print("obs", obs.shape, "finite", np.isfinite(obs).all())
t0 = time.time()
eps = 0
for s in range(a.steps):
    act = np.random.uniform(-1, 1, (a.n_envs, env.action_space.shape[0])).astype(np.float32)
    act[:, 0:2] = np.abs(act[:, 0:2])  # 대체로 앞으로
    obs, r, d, info = env.step(act)
    for i in np.where(d)[0]:
        eps += 1
        print("episode", info[i]["stage"], "success", info[i]["success"], "return %.3f" % info[i]["episode"]["r"],
              "len", info[i]["episode"]["l"])
dt = time.time() - t0
print(f"{a.steps * a.n_envs} decisions in {dt:.1f}s = {a.steps * a.n_envs / dt:.0f} decisions/s "
      f"({a.steps * a.n_envs * 0.1 / dt:.1f}x realtime per all envs), episodes {eps}")
env.close()
