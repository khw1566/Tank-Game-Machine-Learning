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
    parser.add_argument('--n-envs', type=int, default=1,
                        help='동시에 돌릴 전장(Godot 프로세스) 수. 개체별 모델은 그대로 7개이고 추론만 묶는다')
    parser.add_argument('--prefetch', type=int, default=1,
                        help='1 = 다음 경기용 Godot 를 미리 띄워 재시작 대기를 없앤다')
    args = parser.parse_args()
    if not 1 <= args.n_envs <= 16:
        parser.error('--n-envs must be 1..16')
    if args.n_steps < 2 or args.timesteps < 1 or args.save_every < 1 or not 1 <= args.time_limit <= 180:
        parser.error('Invalid training length, rollout size or time limit')
    train(args)


if __name__ == '__main__':
    main()
