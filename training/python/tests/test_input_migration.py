import tempfile
import unittest
from pathlib import Path

import gymnasium as gym
import numpy as np
import torch
from stable_baselines3 import PPO

from tankrl.input_migration import expand_fire_inputs, FIRST_LAYERS
from tankrl.storage import sha256


class ToyEnv(gym.Env):
    def __init__(self, width):
        self.observation_space = gym.spaces.Box(-np.inf, np.inf, (width,), np.float32)
        self.action_space = gym.spaces.Box(-1, 1, (11,), np.float32)

    def reset(self, seed=None, options=None):
        super().reset(seed=seed)
        self.steps = 0
        return np.zeros(self.observation_space.shape, np.float32), {}

    def step(self, action):
        self.steps += 1
        return np.full(self.observation_space.shape, self.steps / 10, np.float32), -float(np.square(action).mean()), False, self.steps >= 8, {}


class InputMigrationTests(unittest.TestCase):
    def test_actions_values_optimizer_and_source_are_preserved(self):
        torch.set_num_threads(1)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = PPO("MlpPolicy", ToyEnv(419), n_steps=8, batch_size=8, n_epochs=1,
                      policy_kwargs={"net_arch": [32, 32]}, use_sde=True, device="cpu", seed=2)
            old.learn(8)
            source = root / "old.zip"
            old.save(source)
            digest = sha256(source)
            destination = expand_fire_inputs(source, ToyEnv(437).observation_space, root / "migrations")
            new = PPO.load(destination, env=ToyEnv(437), device="cpu")
            rng = np.random.default_rng(3)
            obs = rng.normal(size=(4, 419)).astype(np.float32)
            expanded = np.concatenate([obs, rng.normal(size=(4, 18)).astype(np.float32)], axis=1)
            np.testing.assert_allclose(old.predict(obs, deterministic=True)[0], new.predict(expanded, deterministic=True)[0], atol=1e-6)
            with torch.no_grad():
                torch.testing.assert_close(old.policy.predict_values(torch.from_numpy(obs)), new.policy.predict_values(torch.from_numpy(expanded)))
            for key, tensor in old.policy.state_dict().items():
                actual = new.policy.state_dict()[key]
                if key in FIRST_LAYERS:
                    torch.testing.assert_close(tensor, actual[:, :419])
                    assert torch.count_nonzero(actual[:, 419:]) == 0
                else:
                    torch.testing.assert_close(tensor, actual)
            old_state = old.policy.optimizer.state_dict()["state"]
            new_state = new.policy.optimizer.state_dict()["state"]
            for parameter, state in old_state.items():
                for name, value in state.items():
                    actual = new_state[parameter][name]
                    if value.ndim == 2 and value.shape[1] == 419:
                        torch.testing.assert_close(value, actual[:, :419])
                        assert torch.count_nonzero(actual[:, 419:]) == 0
                    else:
                        torch.testing.assert_close(value, actual)
            assert new.num_timesteps == old.num_timesteps and sha256(source) == digest
            assert expand_fire_inputs(destination, ToyEnv(437).observation_space, root) == destination
            new.learn(8, reset_num_timesteps=False)  # Actual optimizer update catches mismatched Adam tensors.
            assert new.num_timesteps == 16
            fire_model = root / "fire.zip"
            new.save(fire_model)
            battle_path = expand_fire_inputs(fire_model, ToyEnv(605).observation_space, root / "migrations",
                                             allow_battle=True)
            battle = PPO.load(battle_path, env=ToyEnv(605), device="cpu")
            battle_obs = np.concatenate([expanded, rng.normal(size=(4, 168)).astype(np.float32)], axis=1)
            np.testing.assert_allclose(new.predict(expanded, deterministic=True)[0],
                                       battle.predict(battle_obs, deterministic=True)[0], atol=1e-6)
            battle.learn(8, reset_num_timesteps=False)
            assert battle.num_timesteps == 24


if __name__ == "__main__":
    unittest.main()
