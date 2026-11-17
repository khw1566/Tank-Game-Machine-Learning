"""Stable per-vehicle identities. Models, optimizers and buffers are never shared."""
import json
import zipfile
from pathlib import Path

import gymnasium as gym
import numpy as np

from .control import write_json_atomic
from .storage import checkpoint_paths, save_checkpoint, sha256

AGENTS = {'tiger1_0': 'tiger1', **{f'sherman75_{i}': 'sherman75' for i in range(1, 4)},
          **{f't34_76_{i}': 't34_76' for i in range(4, 7)}}


class PolicySpaces(gym.Env):
    observation_space = gym.spaces.Box(-np.inf, np.inf, (389,), dtype=np.float32)
    action_space = gym.spaces.Box(-1, 1, (11,), dtype=np.float32)

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        return np.zeros(389, dtype=np.float32), {}

    def step(self, action):
        raise RuntimeError('Joint actions must be stepped through the shared battlefield')


def load_individuals(source: Path, destination: Path, n_steps=256, seed=0):
    from stable_baselines3 import PPO
    models, states = {}, {}
    for index, (agent, tank) in enumerate(AGENTS.items()):
        target = destination / 'agents' / agent
        target.mkdir(parents=True, exist_ok=True)
        checkpoint, state_path = checkpoint_paths(target)
        resumed = checkpoint is not None
        if checkpoint is None:
            origin = source / 'agents' / agent
            if not origin.exists():
                origin = source / tank
            checkpoint, state_path = checkpoint_paths(origin)
        kwargs = dict(env=PolicySpaces(), device='cpu', n_steps=n_steps,
                      batch_size=min(128, n_steps), n_epochs=4, seed=seed + index)
        if checkpoint is not None:
            model = PPO.load(str(checkpoint), **kwargs)
        else:
            model = PPO('MlpPolicy', use_sde=True, sde_sample_freq=20, **kwargs)
        if model.observation_space.shape != (389,) or model.action_space.shape != (11,):
            raise ValueError(f'{agent}: incompatible model dimensions')
        prior = json.loads(state_path.read_text(encoding='utf-8')) if state_path.exists() else {}
        state = prior.copy() if resumed or prior.get('agent_id') == agent else dict(agent_id=agent, tank=tank, stage='final_battle', stage_idx=9,
            origin=str(checkpoint) if checkpoint else 'new_random_policy',
            origin_sha256=sha256(checkpoint) if checkpoint else None,
            inherited_timesteps=model.num_timesteps, independent_steps=0, scenario_version=2)
        if not resumed and prior.get('agent_id') == agent:
            state['resumed_from'] = str(checkpoint)
        if 'inherited_updates' not in state:
            origin = Path(state['origin'])
            state['inherited_updates'] = 0
            if origin.is_file():
                with zipfile.ZipFile(origin) as archive:
                    state['inherited_updates'] = int(json.loads(archive.read('data'))['_n_updates'])
        state['independent_updates'] = model._n_updates - state['inherited_updates']
        if not resumed:
            save_checkpoint(model, target, state)
        models[agent], states[agent] = model, state
    assert len({id(model.policy) for model in models.values()}) == 7
    assert len({id(model.policy.optimizer) for model in models.values()}) == 7
    assert len({id(model.rollout_buffer) for model in models.values()}) == 7
    write_json_atomic(destination / 'individuals.json', states)
    return models, states
