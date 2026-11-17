"""최종전(티거 1 대 연합군 6) 시뮬레이션 처리량 측정.

학습 루프와 같은 방식(Godot 1개, 7대 모두 외부 조종, 에피소드마다 새 프로세스)으로 경기를 돌리고
구간별 시간을 잰다. 정책 가중치를 바꾸거나 학습 결과를 쓰지 않는다.

  random : 시드 고정 무작위 행동. Godot 시뮬레이션 + 통신만 잰다.
  policy : --source-run 의 7개 정책으로 학습과 같은 확률적 추론(개체마다 1회 forward).

결과는 --out JSON 에 저장한다(Godot 쪽 구간별 시간 result.perf 포함, 지원하는 빌드일 때).

  python benchmark_battle.py --godot ../../build/TankGame.exe --episodes 3 --out bench.json
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import statistics
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

from tankrl.evaluation import battle_config
from tankrl.godot_env import GodotProcess
from tankrl.individuals import AGENTS


def run(args) -> dict:
    models = None
    if args.mode == 'policy':
        import torch
        from stable_baselines3.common.utils import obs_as_tensor
        from tankrl.individuals import load_individuals
        torch.set_num_threads(2)
        tmp = Path(tempfile.mkdtemp(prefix='tank_bench_'))
        models, _ = load_individuals(args.runs_dir / args.source_run, tmp, 256, args.seed)
        for model in models.values():
            model.policy.set_training_mode(False)
    rng = np.random.default_rng(args.seed)
    log_dir = Path(tempfile.mkdtemp(prefix='tank_bench_log_'))
    episodes = []
    process = None
    started = time.perf_counter()
    for index in range(args.episodes):
        t0 = time.perf_counter()
        if process is None or args.fresh_process:
            if process is not None:
                process.close()
            process = GodotProcess(args.godot, args.project, 0, str(log_dir))
        t_start = time.perf_counter() - t0
        seed = args.seed + index
        cfg, _ = battle_config(list(AGENTS), 'mixed', seed, f'bench_{seed}', False, args.time_limit)
        cfg['save_episode'] = not args.no_episode_file
        if args.overrides:
            cfg.update(json.loads(args.overrides))
        t1 = time.perf_counter()
        process.send({'type': 'reset', 'config': cfg})
        header, obs = process.recv_obs()
        t_reset = time.perf_counter() - t1
        infer = wait = 0.0
        decisions = agent_steps = 0
        alive = np.array([a['alive'] for a in header['agents']], dtype=bool)
        while True:
            ti = time.perf_counter()
            if models is None:
                actions = rng.uniform(-1, 1, (len(alive), 11)).astype(np.float32)
                # 무작위 사격 빈도를 줄인다(전투가 너무 빨리 끝나면 기동 비용을 못 잰다)
                actions[:, 5] = np.where(rng.random(len(alive)) < args.fire_prob, 1.0, -1.0)
            else:
                actions = np.zeros((len(alive), 11), dtype=np.float32)
                for k, model in enumerate(models.values()):
                    if not alive[k]:
                        continue
                    with torch.no_grad():
                        a, _, _ = model.policy(obs_as_tensor(obs[k:k + 1], model.device))
                    actions[k] = a.cpu().numpy()[0]
            tw = time.perf_counter()
            infer += tw - ti
            process.send({'type': 'step'}, np.clip(actions, -1, 1).astype('<f4').tobytes())
            header, obs = process.recv_obs()
            wait += time.perf_counter() - tw
            decisions += 1
            agent_steps += int(alive.sum())
            alive = np.array([a['alive'] for a in header['agents']], dtype=bool)
            if header['done']:
                break
        result = header['episode']
        total = time.perf_counter() - t0
        ep = dict(seed=seed, reason=result.get('reason'), winner=result.get('winner'),
                  duration_s=result.get('duration_s'), decisions=decisions, agent_steps=agent_steps,
                  wall_s=round(total, 3), process_start_s=round(t_start, 3), reset_s=round(t_reset, 3),
                  infer_s=round(infer, 3), godot_wait_s=round(wait, 3),
                  decisions_per_s=round(decisions / total, 1), agent_steps_per_s=round(agent_steps / total, 1),
                  sim_speed_x=round(float(result.get('duration_s', 0)) / total, 2),
                  final_hash=result.get('final_hash'), perf=result.get('perf'), episode_file=result.get('episode_file', ''),
                  kills=sum(t.get('kills', 0) for t in result.get('tanks', [])),
                  shots=sum(t.get('shots', 0) for t in result.get('tanks', [])))
        episodes.append(ep)
        print(json.dumps({k: ep[k] for k in ('seed', 'reason', 'duration_s', 'decisions', 'wall_s', 'decisions_per_s',
                                              'sim_speed_x', 'final_hash')}, ensure_ascii=False), flush=True)
    if process is not None:
        process.close()
    wall = time.perf_counter() - started
    dec = sum(e['decisions'] for e in episodes)
    summary = dict(
        mode=args.mode, godot=str(args.godot), episodes=len(episodes), wall_s=round(wall, 2),
        decisions=dec, agent_steps=sum(e['agent_steps'] for e in episodes),
        decisions_per_s=round(dec / wall, 1),
        agent_steps_per_s=round(sum(e['agent_steps'] for e in episodes) / wall, 1),
        game_seconds=round(sum(float(e['duration_s']) for e in episodes), 1),
        sim_speed_x=round(sum(float(e['duration_s']) for e in episodes) / wall, 2),
        median_episode_decisions_per_s=statistics.median(e['decisions_per_s'] for e in episodes),
        share=dict(process_start=round(sum(e['process_start_s'] for e in episodes) / wall, 3),
                   reset=round(sum(e['reset_s'] for e in episodes) / wall, 3),
                   infer=round(sum(e['infer_s'] for e in episodes) / wall, 3),
                   godot_wait=round(sum(e['godot_wait_s'] for e in episodes) / wall, 3)),
        machine=dict(cpu=platform.processor(), cores=os.cpu_count(), python=sys.version.split()[0]),
        args={k: str(v) if isinstance(v, Path) else v for k, v in vars(args).items()},
        per_episode=episodes)
    return summary


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, 'reconfigure'):
            stream.reconfigure(encoding='utf-8')
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--godot', required=True)
    p.add_argument('--project')
    p.add_argument('--mode', choices=['random', 'policy'], default='random')
    p.add_argument('--runs-dir', type=Path, default=None)
    p.add_argument('--source-run', default='')
    p.add_argument('--episodes', type=int, default=3)
    p.add_argument('--seed', type=int, default=1)
    p.add_argument('--time-limit', type=int, default=180)
    p.add_argument('--fire-prob', type=float, default=0.05)
    p.add_argument('--fresh-process', type=int, default=1, help='1 = 학습처럼 에피소드마다 새 Godot')
    p.add_argument('--no-episode-file', action='store_true')
    p.add_argument('--overrides', default='', help='reset 설정에 덮어쓸 JSON')
    p.add_argument('--out', type=Path)
    args = p.parse_args()
    if args.mode == 'policy' and (args.runs_dir is None or not args.source_run):
        p.error('policy 모드는 --runs-dir 와 --source-run 이 필요합니다')
    summary = run(args)
    text = json.dumps(summary, ensure_ascii=False, indent=2)
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(text, encoding='utf-8')
    print(json.dumps({k: summary[k] for k in ('mode', 'episodes', 'wall_s', 'decisions_per_s', 'agent_steps_per_s',
                                               'sim_speed_x', 'share')}, ensure_ascii=False))


if __name__ == '__main__':
    main()
