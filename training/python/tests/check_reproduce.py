"""재현 점검: 무작위 정책으로 몇 판(사격·1대1·팀전) 돌려 에피소드 파일을 남긴 뒤, 각각 재현해 끝 상태 해시가 같은지 확인.
python -m tests.check_reproduce --godot <godot> [--project <폴더>]"""
import argparse
import glob
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

from tankrl import curriculum
from tankrl.curriculum import STAGE_IDS, Curriculum
from tankrl.godot_env import GodotVecEnv

ap = argparse.ArgumentParser()
ap.add_argument("--godot", required=True)
ap.add_argument("--project", default=None)
ap.add_argument("--keep", action="store_true")
a = ap.parse_args()
tmp = Path(tempfile.mkdtemp(prefix="tank_repro_"))
fails = 0
for stage, tank in [("gunnery_moving", "tiger1"), ("duel_scripted", "sherman75"), ("team_scripted", "sherman75")]:
    st = curriculum.STAGES[STAGE_IDS.index(stage)]
    st["time_limit_s"] = 20
    cur = Curriculum(tank, start_stage=STAGE_IDS.index(stage), review_prob=0.0)
    env = GodotVecEnv(1, a.godot, a.project, tmp / stage, tank, cur, record_every=0, seed=7)
    rng = np.random.default_rng(0)
    env.policy_fn = lambda o: rng.uniform(-1, 1, (len(o), 11))
    env.reset()
    done = 0
    while done < 1:
        act = rng.uniform(-1, 1, (1, 11)).astype(np.float32)
        act[:, 0:2] = np.abs(act[:, 0:2])
        _, _, d, _ = env.step(act)
        done += int(d[0])
    env.close()
    files = sorted(glob.glob(str(tmp / stage / "episodes" / "env0" / "*.json")))
    f = files[0]
    cmd = [a.godot, "--headless", "--fixed-fps", "30"] + (["--path", a.project] if a.project else []) + \
          ["--", f"--reproduce={f}", f"--out-dir={tmp / stage / 'repro'}", "--log-obs=0"]
    r = subprocess.run(cmd, capture_output=True, text=True)
    ok = r.returncode == 0 and "OK" in r.stdout
    print(("PASS " if ok else "FAIL ") + stage, [l for l in r.stdout.splitlines() if "final_hash" in l])
    fails += 0 if ok else 1
if not a.keep:
    shutil.rmtree(tmp, ignore_errors=True)
print("재현 점검:", "모두 통과" if fails == 0 else f"{fails}개 실패")
sys.exit(1 if fails else 0)
