"""Frozen-policy final battle evaluation. Never calls learn() or updates a training run."""
import argparse
import sys
from pathlib import Path

from tankrl.evaluation import MODES, run_evaluation
from tankrl.storage import default_runs_dir


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True)
    parser.add_argument('--project')
    parser.add_argument('--runs-dir', type=Path, default=default_runs_dir())
    parser.add_argument('--source-run', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--episodes', type=int, default=1, help='Games per mode')
    parser.add_argument('--seed', type=int, default=10001, help='First held-out map/episode seed')
    parser.add_argument('--modes', default='mixed', help=','.join(MODES))
    parser.add_argument('--time-limit', type=int, default=180)
    parser.add_argument('--record-every', type=int, default=3)
    args = parser.parse_args()
    modes = args.modes.split(',')
    if args.episodes < 1 or not 1 <= args.time_limit <= 180 or any(m not in MODES for m in modes):
        parser.error('Invalid episodes, time limit or modes')
    run_evaluation(args, modes)


if __name__ == '__main__':
    main()
