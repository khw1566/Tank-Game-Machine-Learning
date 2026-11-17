"""IPPO joint collection with seven completely separate PPO updates."""
import csv
import json
import time
from pathlib import Path

import numpy as np
import torch
from stable_baselines3.common.logger import configure
from stable_baselines3.common.utils import obs_as_tensor

from .control import TrainController, write_json_atomic
from .evaluation import battle_config
from .godot_env import GodotProcess, PROGRESS_FIELDS, episode_counter
from .individuals import AGENTS, load_individuals
from .storage import RunLock, archive_runtime, save_checkpoint, session_log_dir


def update_policies(models, observations, dones):
    for index, model in enumerate(models.values()):
        if not model.rollout_buffer.full:
            continue  # Interrupted partial rollouts are discarded, never padded with fake data.
        with torch.no_grad():
            last = model.policy.predict_values(obs_as_tensor(observations[index:index+1], model.device))
        model.rollout_buffer.compute_returns_and_advantage(last_values=last, dones=np.array([dones[index]]))
        model._update_current_progress_remaining(model.num_timesteps, model._total_timesteps)
        model.train()
        model.logger.dump(model.num_timesteps)
        model.rollout_buffer.reset()
        model.policy.set_training_mode(False)


def train(args):
    torch.set_num_threads(2)
    base = args.runs_dir.resolve()
    run = (base / args.run).resolve()
    source = (base / args.source_run).resolve()
    if run.parent != base or source.parent != base or run == source:
        raise ValueError('Choose a separate run for independent training')
    run.mkdir(parents=True, exist_ok=True)
    if (run / 'evaluation_manifest.json').exists() or (run / 'run.json').exists():
        raise ValueError('Do not mix legacy/evaluation output with independent training')
    with RunLock(run):
        ctl = TrainController(run, record_every=args.record_every, review_prob=0)
        models, states = load_individuals(source, run, args.n_steps, args.seed)
        initial_steps = {name: model.num_timesteps for name, model in models.items()}
        initial_updates = {name: model._n_updates for name, model in models.items()}
        ctl.info.update(mode='independent', tank='tiger1', n_envs=1, target_timesteps=args.timesteps)
        ctl._kept['curriculum'] = dict(stage_idx=9, stage='final_battle')
        manifest = dict(format='independent-ppo', version=1, source_run=args.source_run,
            agents=dict(AGENTS), scenario_version=2, reward_version=3, args={k:str(v) if isinstance(v, Path) else v for k,v in vars(args).items()},
            runtime=archive_runtime(Path(args.godot).resolve(), args.project))
        manifest_path = run / 'independent_run.json'
        previous = json.loads(manifest_path.read_text(encoding='utf-8')) if manifest_path.exists() else {}
        sessions = previous.get('sessions', [])
        if previous and not sessions:
            sessions = [{k:v for k,v in previous.items() if k != 'sessions'}]
        manifest['sessions'] = sessions + [dict(manifest)]
        write_json_atomic(manifest_path, manifest)
        ctl.info['individuals'] = {name: dict(tank=AGENTS[name], steps=model.num_timesteps,
            independent_steps=states[name].get('independent_steps',0)) for name,model in models.items()}
        ctl.write_status(0, force=True, phase='starting')
        if args.initialize_only:
            ctl.write_status(0, force=True, phase='stopped')
            print('Initialized seven independent policies; no learning performed.', flush=True)
            return
        for name, model in models.items():
            model.set_logger(configure(str(session_log_dir(run, name)), ['csv']))
            model._setup_learn(args.timesteps, reset_num_timesteps=False)
            model.policy.set_training_mode(False)
        process = None
        step = 0
        episode = episode_counter(run, run.name, 'tiger1')
        starts = np.ones(7, dtype=bool)
        alive = np.ones(7, dtype=bool)
        new_episodes = 0

        def save(_message=None):
            ctl.write_status(step, force=True, phase='saving')
            for name, model in models.items():
                states[name]['independent_steps'] = model.num_timesteps - states[name]['inherited_timesteps']
                states[name]['ppo_updates'] = model._n_updates
                states[name]['reward_version'] = 3
                states[name]['independent_updates'] = model._n_updates - states[name]['inherited_updates']
                save_checkpoint(model, run / 'agents' / name, states[name])
            write_json_atomic(run / 'individuals.json', states)

        ctl.handlers['checkpoint'] = save

        def reset():
            nonlocal episode, new_episodes
            episode += 1
            new_episodes += 1
            seed = args.seed + 61 + episode
            uid = f'{run.name}_tiger1_{episode:07d}_final_battle'
            cfg, _ = battle_config(models, 'mixed', seed, uid,
                                  ctl.record_every > 0 and new_episodes % ctl.record_every == 0,
                                  args.time_limit)
            cfg['meta']['evaluation'] = False
            cfg['meta']['algorithm'] = 'independent_ppo'
            cfg['meta']['policies'] = {name: f'{run.name}/agents/{name}/step_{m.num_timesteps:09d}' for name,m in models.items()}
            process.send({'type':'reset', 'config':cfg})
            header, observations = process.recv_obs()
            if [agent['name'] for agent in header['agents']] != list(AGENTS):
                raise ValueError('Independent policy identities do not match battlefield order')
            return cfg, observations.copy()

        header_new = not (run / 'progress.csv').exists()
        returns = np.zeros(7)
        try:
            process = GodotProcess(args.godot, args.project, 0, str(run))
            if process.hello.get('compact_battle_version', 0) < 1 or process.hello.get('fast_combat_reward_version', 0) < 1:
                raise ValueError('독립 개체용 소형 전장을 지원하는 최신 게임 빌드가 필요합니다.')
            cfg, obs = reset()
            with (run/'progress.csv').open('a', newline='', encoding='utf-8') as output:
                writer = csv.DictWriter(output, fieldnames=PROGRESS_FIELDS)
                if header_new:
                    writer.writeheader()
                with (run/'individual_progress.jsonl').open('a', encoding='utf-8') as individual_log:
                    for step in range(1, args.timesteps + 1):
                        tensors, raw = [], []
                        for index, model in enumerate(models.values()):
                            if not alive[index]:
                                tensors.append(None)
                                raw.append(np.zeros(11))
                                continue
                            position = model.rollout_buffer.pos
                            if model.use_sde and (position == 0 or model.sde_sample_freq > 0 and position % model.sde_sample_freq == 0):
                                model.policy.reset_noise(1)
                            with torch.no_grad():
                                action, value, probability = model.policy(obs_as_tensor(obs[index:index+1], model.device))
                            tensors.append((value, probability))
                            raw.append(action.cpu().numpy()[0])
                        actions = np.asarray(raw, dtype=np.float32)
                        if not np.isfinite(actions).all():
                            raise ValueError('Non-finite independent action')
                        process.send({'type':'step'}, np.clip(actions,-1,1).astype('<f4').tobytes())
                        header, next_obs = process.recv_obs()
                        next_obs = next_obs.copy()
                        done = bool(header['done'])
                        next_alive = np.array([a['alive'] for a in header['agents']], dtype=bool)
                        dones = np.logical_or(~next_alive, done)
                        if not np.isfinite(next_obs).all():
                            raise ValueError('Non-finite independent observation')
                        rewards = np.array([a['reward'] for a in header['agents']], dtype=np.float32)
                        returns += rewards
                        for index, (name, model) in enumerate(models.items()):
                            if not alive[index]:
                                continue
                            reward = float(rewards[index])
                            if done and next_alive[index] and header['episode']['reason'] == 'time_limit':
                                with torch.no_grad():
                                    reward += model.gamma * float(model.policy.predict_values(obs_as_tensor(next_obs[index:index+1], model.device)).item())
                            model.rollout_buffer.add(obs[index:index+1], actions[index:index+1], np.array([reward]),
                                np.array([starts[index]]), *tensors[index])
                            model.num_timesteps += 1
                            ctl.info['individuals'][name].update(steps=model.num_timesteps,
                                independent_steps=model.num_timesteps-states[name]['inherited_timesteps'])
                        obs = next_obs
                        starts = dones
                        alive = next_alive
                        if any(model.rollout_buffer.full for model in models.values()):
                            ctl.write_status(step, force=True, phase='updating')
                            update_policies(models, obs, dones)
                        if done:
                            result = header['episode']
                            for index,tank in enumerate(result['tanks']):
                                individual_log.write(json.dumps(dict(agent=tank['name'], uid=cfg['uid'],
                                    step=models[tank['name']].num_timesteps, reward=float(returns[index]),
                                    reward_version=3,
                                    winner=result['winner'], **{k:v for k,v in tank.items() if k!='name'}))+'\n')
                            individual_log.flush()
                            tiger=result['tanks'][0]
                            row=dict(wall_time=time.time(),global_step=step,env=0,uid=cfg['uid'],tank='tiger1',
                                stage='final_battle',stage_idx=9,current_stage='final_battle',success=int(result['winner']==0),
                                reason=result['reason'],winner=result['winner'],decisions=result['decisions'],
                                duration_s=result['duration_s'],spawn_distance_m=result['spawn_distance_m'],
                                map_seed=cfg['seed'],seed=cfg['seed'],hits=tiger['hits'],pens=tiger['pens'],kills=tiger['kills'],
                                shots=tiger['shots'],learner_policy=cfg['meta']['policies']['tiger1_0'],opponents='independent_ppo',
                                episode_file=result['episode_file'],replay_dir=result.get('replay_dir',''),final_hash=result['final_hash'])
                            row['return']=float(returns[0]);writer.writerow(row);output.flush()
                            returns[:]=0
                            print(f'Independent battle {episode}: winner={result["winner"]}, {result["duration_s"]}s',flush=True)
                            process.close()
                            process=GodotProcess(args.godot,args.project,0,str(run))
                            cfg,obs=reset()
                            starts[:]=True
                            alive[:]=True
                        if step % args.save_every == 0:
                            save()
                        if not ctl.tick(step):
                            break
        finally:
            save()
            if process is not None:
                process.close()
            for model in models.values():
                model.get_env().close()
            ctl.write_status(step, force=True, phase='stopped')
            write_json_atomic(run/'independent_validation.json',dict(
                initial_steps=initial_steps,final_steps={name:m.num_timesteps for name,m in models.items()},
                updates_added={name:m._n_updates-initial_updates[name] for name,m in models.items()},
                separate_policies=len({id(m.policy) for m in models.values()}),
                separate_optimizers=len({id(m.policy.optimizer) for m in models.values()}),
                separate_buffers=len({id(m.rollout_buffer) for m in models.values()})))
