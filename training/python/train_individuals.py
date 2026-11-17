"""Independent PPO for seven vehicles in one compact battlefield."""
import argparse
from pathlib import Path
import sys

from tankrl.independent_training import train
from tankrl.storage import default_runs_dir


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--godot', required=True)
    parser.add_argument('--project')
    parser.add_argument('--runs-dir', type=Path, default=default_runs_dir())
    parser.add_argument('--run', required=True)
    parser.add_argument('--source-run', required=True)
    parser.add_argument('--timesteps', type=int, default=10000, help='Additional decisions per vehicle')
    parser.add_argument('--n-steps', type=int, default=256)
    parser.add_argument('--save-every', type=int, default=4096)
    parser.add_argument('--record-every', type=int, default=10)
    parser.add_argument('--seed', type=int, default=0)
    parser.add_argument('--time-limit', type=int, default=180)
    parser.add_argument('--initialize-only', action='store_true')
    args = parser.parse_args()
    if args.n_steps < 2 or args.timesteps < 1 or args.save_every < 1 or not 1 <= args.time_limit <= 180:
        parser.error('Invalid training length, rollout size or time limit')
    train(args)


if __name__ == '__main__':
    main()
