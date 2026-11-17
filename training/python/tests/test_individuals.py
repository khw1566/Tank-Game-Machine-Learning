from pathlib import Path
import tempfile
import unittest

import numpy as np
import torch
from stable_baselines3.common.logger import configure
from stable_baselines3.common.utils import obs_as_tensor

from tankrl.evaluation import policy_hash
from tankrl.independent_training import update_policies
from tankrl.individuals import AGENTS, load_individuals


class IndependentPolicyTests(unittest.TestCase):
    def test_updating_one_vehicle_cannot_update_its_peers(self):
        torch.set_num_threads(1)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            models, states = load_individuals(root/'empty_source', root/'individuals', n_steps=8, seed=13)
            self.assertEqual(len(models), 7)
            self.assertEqual(len({id(m.policy.optimizer) for m in models.values()}), 7)
            self.assertEqual(len({id(m.rollout_buffer) for m in models.values()}), 7)
            initial = {name: policy_hash(model) for name,model in models.items()}
            name = next(iter(models))
            model = models[name]
            model.set_logger(configure(str(root/'log'), []))
            model._setup_learn(8, reset_num_timesteps=False)
            obs = np.ones((1,389), dtype=np.float32) * .1
            for i in range(8):
                with torch.no_grad():
                    action, value, probability = model.policy(obs_as_tensor(obs, model.device))
                model.rollout_buffer.add(obs, action.numpy(), np.array([1.]), np.array([i==0]), value, probability)
                model.num_timesteps += 1
            update_policies(models, np.repeat(obs, 7, axis=0), np.zeros(7, dtype=bool))
            self.assertNotEqual(initial[name], policy_hash(model))
            for peer, other in models.items():
                if peer != name:
                    self.assertEqual(initial[peer], policy_hash(other))
                    self.assertEqual(other.num_timesteps, 0)
            # Resume picks each vehicle's own checkpoint and does not seed it from another vehicle.
            resumed, _ = load_individuals(root/'empty_source', root/'individuals', n_steps=8, seed=99)
            for peer in AGENTS:
                self.assertEqual(policy_hash(resumed[peer]), initial[peer])
            for m in list(models.values()) + list(resumed.values()):
                m.get_env().close()


if __name__ == '__main__':
    unittest.main()
