"""Exercise all terrain lessons with a waypoint controller and verify deterministic replay."""
import argparse
import json
from pathlib import Path
import subprocess
import sys
import time

import numpy as np

from tankrl.curriculum import Curriculum
from tankrl.godot_env import GodotVecEnv
from tankrl.terrain import COURSE_IDS


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--godot', required=True)
    parser.add_argument('--project')
    parser.add_argument('--out', default='runs/terrain_checks')
    args = parser.parse_args()
    out = Path(args.out).resolve()
    results = []
    for course in COURSE_IDS:
        cur = Curriculum('tiger1', start_stage=1, review_prob=0)
        cur.terrain_fixed = course
        run = out / course
        env = GodotVecEnv(1, args.godot, args.project, run, 'tiger1', cur, seed=41, record_every=0)
        started = time.perf_counter()
        try:
            obs = env.reset()
            assert obs.shape == (1, 389) and env.action_space.shape == (11,)
            for _ in range(1300):
                bearing = float(np.arctan2(obs[0, -7], obs[0, -6]))
                distance = float(obs[0, -5] * 1000)
                speed = float(obs[0, 0] * (38 / 3.6))
                action = np.zeros((1, 11), dtype=np.float32)
                action[0, 5] = -1  # No firing.
                if distance < 4:
                    action[0, 2] = 1
                else:
                    turn = float(np.clip(bearing * 1.8, -.8, .8))
                    throttle = .65 if distance > 14 else .22
                    if abs(bearing) > .6:
                        throttle = 0
                    action[0, 0] = np.clip(throttle - turn, -1, 1)
                    action[0, 1] = np.clip(throttle + turn, -1, 1)
                    if distance < 10 and speed > 2:
                        action[0, 2] = .7
                obs, rewards, done, info = env.step(action)
                assert np.isfinite(obs).all() and np.isfinite(rewards).all()
                if done[0]:
                    break
            else:
                raise AssertionError('Trial never terminated')
        finally:
            env.close()
        episode = sorted((run / 'episodes' / 'env0').glob('*.json'))[0]
        data = json.loads(episode.read_text(encoding='utf-8'))
        assert data['result']['terrain']['course'] == course
        assert data['result']['terrain']['reward_components']['progress'] <= 4.00001
        layout = data['config']['terrain_layout']
        assert len(layout['route']) >= 1
        command = [sys.executable, 'reproduce.py', str(episode), '--godot', args.godot,
                   '--out-dir', str(run / 'reproduction'), '--log-obs', '0']
        if args.project:
            command += ['--project', args.project]
        replay = subprocess.run(command, capture_output=True, encoding='utf-8', errors='replace', timeout=120)
        assert replay.returncode == 0, replay.stdout + replay.stderr
        result = dict(course=course, success=data['result']['success'], reason=data['result']['reason'],
                      decisions=data['result']['decisions'], terrain=data['result']['terrain'],
                      replay='OK', seconds=round(time.perf_counter() - started, 2))
        results.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)
    (out / 'results.json').write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding='utf-8')
    if not all(r['success'] for r in results):
        raise AssertionError('Waypoint controller failed a lesson; inspect results.json')


if __name__ == '__main__':
    main()
