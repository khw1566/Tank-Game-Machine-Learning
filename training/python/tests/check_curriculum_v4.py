"""커리큘럼 v4 스모크: 모든 단계·변형을 한 판씩(무작위 행동, 짧은 제한 시간) 돌리고 재현해 끝 상태 해시를 비교한다.
python -m tests.check_curriculum_v4 --godot <TankGame.exe> [--tank tiger1] [--keep]"""
import argparse
import copy
import glob
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np

from tankrl import curriculum_v4
from tankrl.curriculum_v4 import CurriculumV4
from tankrl.godot_env import GodotVecEnv

ap = argparse.ArgumentParser()
ap.add_argument("--godot", required=True)
ap.add_argument("--project", default=None)
ap.add_argument("--tank", default="tiger1")
ap.add_argument("--time-limit", type=float, default=25)
ap.add_argument("--keep", action="store_true")
ap.add_argument("--from-stage", default="", help="이 단계부터만 점검")
a = ap.parse_args()
tmp = Path(tempfile.mkdtemp(prefix="tank_v4_"))
original = copy.deepcopy(curriculum_v4.STAGES)
fails = 0
rows = []
for idx, st0 in enumerate(original):
    if a.from_stage and idx < curriculum_v4.STAGE_IDS.index(a.from_stage):
        continue
    for variant in st0["variants"]:
        st = curriculum_v4.STAGES[idx]
        st["variants"] = [variant]
        st["time_limit_s"] = a.time_limit
        for sp in st.get("variant_specs", {}).values():
            sp["time_limit_s"] = a.time_limit
        cur = CurriculumV4(a.tank, start_stage=idx, review_prob=0.0)
        name = f"{st['id']}_{variant}"
        env = GodotVecEnv(1, a.godot, a.project, tmp / name, a.tank, cur, record_every=0, seed=11)
        assert any(label.startswith("sit.") for label in env.obs_labels), "상황 관측이 없음"
        rng = np.random.default_rng(idx)
        env.reset()
        info = {}
        for _ in range(4000):
            act = rng.uniform(-1, 1, (1, 11)).astype(np.float32)
            act[:, 0:2] = np.abs(act[:, 0:2])
            _, _, d, infos = env.step(act)
            if d[0]:
                info = infos[0]
                break
        env.close()
        files = sorted(glob.glob(str(tmp / name / "episodes" / "env0" / "*.json")))
        ep = json.loads(Path(files[0]).read_text(encoding="utf-8"))
        res = ep["result"]
        sc = res.get("scenario", {})
        cmd = [a.godot, "--headless", "--fixed-fps", "30"] + (["--path", a.project] if a.project else []) + \
              ["--", f"--reproduce={files[0]}", f"--out-dir={tmp / name / 'repro'}", "--log-obs=0"]
        subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
        rep = sorted((tmp / name / "repro" / "replays").glob("ep*/reproduce.json"))
        ok = bool(rep) and json.loads(rep[-1].read_text(encoding="utf-8"))["ok"] and sc.get("variant") == variant
        fails += 0 if ok else 1
        rows.append(name)
        print(("PASS " if ok else "FAIL ") + f"{name:34s} {res.get('reason', ''):20s} "
              f"{res.get('duration_s', 0):6}s exposed {sc.get('exposed_s')} hits_taken {sc.get('hits_taken')} "
              f"relocated {len(sc.get('relocated', []))} parts {sc.get('reward_components')}", flush=True)
        curriculum_v4.STAGES[idx] = copy.deepcopy(original[idx])
if not a.keep:
    shutil.rmtree(tmp, ignore_errors=True)
else:
    print("결과 폴더:", tmp)
print(f"v4 스모크: {len(rows) - fails}/{len(rows)} 통과")
sys.exit(1 if fails else 0)
