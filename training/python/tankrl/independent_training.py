"""IPPO joint collection with seven completely separate PPO updates.

여러 전장(--n-envs)을 동시에 돌릴 수 있다. 전장마다 Godot 프로세스 1개가 병렬로 돌고,
개체(모델)마다 살아 있는 전장의 관측을 모아 한 번에 추론한다. 모델·optimizer·버퍼는 여전히 7개로 분리된다.

경험은 (전장, 개체)마다 연속 구간으로 모았다가 모델 버퍼가 찰 때 전장 순서대로 이어 붙인다.
구간이 에피소드 중간에서 잘리면 다음 상태 가치를 보상에 더해(gamma·V) 잘린 곳을 끝으로 처리한다
(SB3 의 시간 초과 처리와 같은 방식). 전장 1개일 때는 기존 순차 수집과 같은 이득·가치를 만든다.
가짜 경험으로 버퍼를 채우지 않는다: 전사한 개체는 그 전장이 끝날 때까지 경험을 내지 않는다.
"""
from concurrent.futures import ThreadPoolExecutor
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
from .pace import require_pace_support
from .storage import RunLock, archive_runtime, save_checkpoint, session_log_dir


def update_policies(models, observations, dones):
    """기존 단일 전장 경로(모델 버퍼를 직접 채운 경우)용. 버퍼가 찬 모델만 갱신한다."""
    for index, model in enumerate(models.values()):
        if not model.rollout_buffer.full:
            continue  # Interrupted partial rollouts are discarded, never padded with fake data.
        with torch.no_grad():
            last = model.policy.predict_values(obs_as_tensor(observations[index:index+1], model.device))
        model.rollout_buffer.compute_returns_and_advantage(last_values=last, dones=np.array([dones[index]]))
        _train(model)


def _train(model):
    model._update_current_progress_remaining(model.num_timesteps, model._total_timesteps)
    model.train()
    model.logger.dump(model.num_timesteps)
    model.rollout_buffer.reset()
    model.policy.set_training_mode(False)


class Segments:
    """한 모델의 전장별 연속 경험. 각 항목 = [obs, action, reward, episode_start, value, log_prob, terminal]."""

    def __init__(self, n_envs):
        self.lists = [[] for _ in range(n_envs)]

    def __len__(self):
        return sum(len(items) for items in self.lists)

    def flush(self, model, live_obs, ongoing):
        """버퍼 크기만큼 전장 순서대로 옮겨 담고 갱신한다. live_obs[e] = 전장 e 의 지금 관측(이 개체),
        ongoing[e] = 그 전장에서 이 개체의 에피소드가 아직 진행 중인가. 남는 경험(전장 수-1 이하)은 다음 버퍼로."""
        buffer = model.rollout_buffer
        room = buffer.buffer_size - buffer.pos
        for e, items in enumerate(self.lists):
            if room <= 0 or not items:
                continue
            take = min(room, len(items))
            chunk, rest = items[:take], items[take:]
            last = chunk[-1]
            if not last[6]:
                # 에피소드 중간에서 잘림: 다음 상태 가치로 이어 붙인다
                if rest:
                    bootstrap = float(rest[0][4].item())
                elif ongoing[e]:
                    with torch.no_grad():
                        bootstrap = float(model.policy.predict_values(obs_as_tensor(live_obs[e], model.device)).item())
                else:
                    bootstrap = 0.0
                last = list(last)
                last[2] = last[2] + model.gamma * bootstrap
                chunk[-1] = last
            for k, item in enumerate(chunk):
                start = True if k == 0 else item[3]
                buffer.add(item[0], item[1], np.array([item[2]]), np.array([start]), item[4], item[5])
            if rest:
                rest[0] = list(rest[0])
                rest[0][3] = True
            self.lists[e] = rest
            room -= take
        if buffer.full:
            buffer.compute_returns_and_advantage(last_values=torch.zeros(1), dones=np.array([True]))
            _train(model)
            return True
        return False


class Battlefield:
    """전장 1개: Godot 프로세스, 현재 설정·관측·생존·수익. 다음 프로세스를 미리 띄워 둔다."""

    def __init__(self, index, pool, args, run):
        self.index = index
        self.pool = pool
        self.args = args
        self.run = run
        self.process = None
        self._next = None
        self.cfg = None
        self.obs = None
        self.alive = np.ones(7, dtype=bool)
        self.starts = np.ones(7, dtype=bool)
        self.returns = np.zeros(7)

    def _spawn(self):
        return GodotProcess(self.args.godot, self.args.project, self.index, str(self.run))

    def prefetch(self):
        if self.pool is not None and self._next is None:
            self._next = self.pool.submit(self._spawn)

    def take_process(self):
        if self._next is not None:
            process, self._next = self._next.result(), None
        else:
            process = self._spawn()
        self.process = process
        self.prefetch()
        return process

    def retire(self):
        old, self.process = self.process, None
        if old is None:
            return
        if self.pool is not None:
            self.pool.submit(old.close)
        else:
            old.close()

    def close(self):
        if self.process is not None:
            self.process.close()
            self.process = None
        if self._next is not None:
            try:
                self._next.result().close()
            except Exception:
                pass
            self._next = None


def train(args):
    n_envs = max(1, int(getattr(args, 'n_envs', 1)))
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
        ctl.info.update(mode='independent', tank='tiger1', n_envs=n_envs, target_timesteps=args.timesteps)
        ctl._kept['curriculum'] = dict(stage_idx=9, stage='final_battle')
        manifest = dict(format='independent-ppo', version=1, source_run=args.source_run,
            agents=dict(AGENTS), scenario_version=2, reward_version=3, collection_version=2, n_envs=n_envs,
            args={k:str(v) if isinstance(v, Path) else v for k,v in vars(args).items()},
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
        step = 0
        episode = episode_counter(run, run.name, 'tiger1')
        new_episodes = 0
        names = list(models)
        segments = {name: Segments(n_envs) for name in names}
        collected = {name: 0 for name in names}   # gSDE 잡음 재표본 주기(모델별 수집 횟수)
        pool = ThreadPoolExecutor(max_workers=max(2, n_envs)) if getattr(args, 'prefetch', 1) else None
        fields = list(PROGRESS_FIELDS)

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

        def reset(field):
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
            cfg['meta']['battlefield'] = field.index
            cfg['meta']['n_envs'] = n_envs
            cfg['meta']['policies'] = {name: f'{run.name}/agents/{name}/step_{m.num_timesteps:09d}' for name,m in models.items()}
            process = field.take_process()
            process.send({'type':'reset', 'config':cfg})
            header, observations = process.recv_obs()
            if [agent['name'] for agent in header['agents']] != list(AGENTS):
                raise ValueError('Independent policy identities do not match battlefield order')
            field.cfg = cfg
            field.obs = observations.copy()
            field.alive[:] = True
            field.starts[:] = True
            field.returns[:] = 0

        def ongoing(name_index):
            return [bool(f.alive[name_index]) for f in fields_]

        header_new = not (run / 'progress.csv').exists()
        fields_ = [Battlefield(e, pool, args, run) for e in range(n_envs)]
        try:
            for field in fields_:
                field.prefetch()
            for field in fields_:
                reset(field)
                hello = field.process.hello
                if hello.get('compact_battle_version', 0) < 1 or hello.get('fast_combat_reward_version', 0) < 1:
                    raise ValueError('독립 개체용 소형 전장을 지원하는 최신 게임 빌드가 필요합니다.')
                require_pace_support(hello, field.cfg)
            with (run/'progress.csv').open('a', newline='', encoding='utf-8') as output:
                writer = csv.DictWriter(output, fieldnames=fields)
                if header_new:
                    writer.writeheader()
                with (run/'individual_progress.jsonl').open('a', encoding='utf-8') as individual_log:
                    next_save = args.save_every
                    while step < args.timesteps:
                        # 1) 개체별 묶음 추론
                        actions = np.zeros((n_envs, 7, 11), dtype=np.float32)
                        outputs = {}
                        for index, (name, model) in enumerate(models.items()):
                            envs = [e for e, f in enumerate(fields_) if f.alive[index]]
                            if not envs:
                                continue
                            if model.use_sde and (collected[name] == 0 or model.sde_sample_freq > 0 and collected[name] % model.sde_sample_freq == 0):
                                model.policy.reset_noise(1)
                            collected[name] += 1
                            batch = np.stack([fields_[e].obs[index] for e in envs])
                            with torch.no_grad():
                                action, value, probability = model.policy(obs_as_tensor(batch, model.device))
                            action = action.cpu().numpy()
                            for k, e in enumerate(envs):
                                actions[e, index] = action[k]
                                outputs[(e, index)] = (value[k:k+1], probability[k:k+1])
                        if not np.isfinite(actions).all():
                            raise ValueError('Non-finite independent action')
                        # 2) 모든 전장에 행동을 먼저 보내고(병렬 진행) 결과를 받는다
                        for e, field in enumerate(fields_):
                            field.process.send({'type':'step'}, np.clip(actions[e],-1,1).astype('<f4').tobytes())
                        finished = []
                        for e, field in enumerate(fields_):
                            header, next_obs = field.process.recv_obs()
                            next_obs = next_obs.copy()
                            done = bool(header['done'])
                            next_alive = np.array([a['alive'] for a in header['agents']], dtype=bool)
                            dones = np.logical_or(~next_alive, done)
                            if not np.isfinite(next_obs).all():
                                raise ValueError('Non-finite independent observation')
                            rewards = np.array([a['reward'] for a in header['agents']], dtype=np.float32)
                            field.returns += rewards
                            for index, (name, model) in enumerate(models.items()):
                                if not field.alive[index]:
                                    continue
                                reward = float(rewards[index])
                                if done and next_alive[index] and header['episode']['reason'] == 'time_limit':
                                    with torch.no_grad():
                                        reward += model.gamma * float(model.policy.predict_values(obs_as_tensor(next_obs[index:index+1], model.device)).item())
                                value, probability = outputs[(e, index)]
                                segments[name].lists[e].append([field.obs[index:index+1].copy(), actions[e, index:index+1].copy(),
                                    reward, bool(field.starts[index]), value, probability, bool(dones[index])])
                                model.num_timesteps += 1
                                ctl.info['individuals'][name].update(steps=model.num_timesteps,
                                    independent_steps=model.num_timesteps-states[name]['inherited_timesteps'])
                            field.obs = next_obs
                            field.starts = dones
                            field.alive = next_alive
                            if done:
                                finished.append((field, header['episode']))
                        step += n_envs
                        # 3) 버퍼가 찬 모델만 갱신(전장 순서대로 이어 붙임)
                        for index, (name, model) in enumerate(models.items()):
                            if len(segments[name]) + model.rollout_buffer.pos >= model.rollout_buffer.buffer_size:
                                ctl.write_status(step, force=True, phase='updating')
                                live = [f.obs[index:index+1] for f in fields_]
                                if segments[name].flush(model, live, ongoing(index)):
                                    collected[name] = 0
                        # 4) 끝난 전장 기록 → 새 프로세스로 다음 경기
                        for field, result in finished:
                            for index,tank in enumerate(result['tanks']):
                                individual_log.write(json.dumps(dict(agent=tank['name'], uid=field.cfg['uid'], env=field.index,
                                    step=models[tank['name']].num_timesteps, reward=float(field.returns[index]),
                                    reward_version=3,
                                    winner=result['winner'], **{k:v for k,v in tank.items() if k!='name'}))+'\n')
                            individual_log.flush()
                            tiger=result['tanks'][0]
                            cfg = field.cfg
                            row=dict(wall_time=time.time(),global_step=step,env=field.index,uid=cfg['uid'],tank='tiger1',
                                stage='final_battle',stage_idx=9,current_stage='final_battle',success=int(result['winner']==0),
                                reason=result['reason'],winner=result['winner'],decisions=result['decisions'],
                                duration_s=result['duration_s'],spawn_distance_m=result['spawn_distance_m'],
                                map_seed=cfg['seed'],seed=cfg['seed'],hits=tiger['hits'],pens=tiger['pens'],kills=tiger['kills'],
                                shots=tiger['shots'],learner_policy=cfg['meta']['policies']['tiger1_0'],opponents='independent_ppo',
                                episode_file=result['episode_file'],replay_dir=result.get('replay_dir',''),final_hash=result['final_hash'])
                            row['return']=float(field.returns[0]);writer.writerow(row);output.flush()
                            perf = result.get('perf') or {}
                            print(f'Independent battle {episode} (env {field.index}): winner={result["winner"]}, '
                                  f'{result["duration_s"]}s, sim {perf.get("sim_ms", 0) / 1000:.1f}s',flush=True)
                            field.retire()
                            reset(field)
                        if step >= next_save:
                            save()
                            next_save += args.save_every
                        if not ctl.tick(step):
                            break
        finally:
            save()
            for field in fields_:
                field.close()
            if pool is not None:
                pool.shutdown(wait=True)
            for model in models.values():
                model.get_env().close()
            ctl.write_status(step, force=True, phase='stopped')
            write_json_atomic(run/'independent_validation.json',dict(
                initial_steps=initial_steps,final_steps={name:m.num_timesteps for name,m in models.items()},
                updates_added={name:m._n_updates-initial_updates[name] for name,m in models.items()},
                separate_policies=len({id(m.policy) for m in models.values()}),
                separate_optimizers=len({id(m.policy.optimizer) for m in models.values()}),
                separate_buffers=len({id(m.rollout_buffer) for m in models.values()}),
                n_envs=n_envs))
