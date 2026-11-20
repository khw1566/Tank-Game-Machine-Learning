import tempfile
import unittest
from pathlib import Path

import gymnasium as gym
import numpy as np
import torch
from stable_baselines3 import PPO
from stable_baselines3.common.distributions import StateDependentNoiseDistribution

from tankrl.hybrid_ppo import HybridPPO
from tankrl.v6_control_policy import V6ControlDistribution, V6ControlPolicy


class ToyControls(gym.Env):
    observation_space = gym.spaces.Box(-1, 1, shape=(4,), dtype=np.float32)
    action_space = gym.spaces.Box(-1, 1, shape=(11,), dtype=np.float32)

    def reset(self, seed=None, options=None):
        super().reset(seed=seed)
        return np.zeros(4, dtype=np.float32), {}

    def step(self, action):
        return np.zeros(4, dtype=np.float32), float(action[5] > 0), False, False, {}


class V6ControlPolicyTests(unittest.TestCase):
    def test_bins_are_normalized_and_score_the_commands(self):
        code = torch.arange(-127, 128, dtype=torch.float64).repeat(11, 1).T
        mean = torch.zeros_like(code)
        std = torch.zeros(11, dtype=torch.float64)
        dist = V6ControlDistribution(11).proba_distribution(mean, std)
        mass = dist.command_log_probs(code / 127).exp()
        for axis in (0, 1):
            self.assertAlmostEqual(mass[:, axis].sum().item(), 1.0)
        self.assertAlmostEqual(mass[127:, 2].sum().item(), 1.0)
        self.assertAlmostEqual(mass[[0, -1], 5].sum().item(), 1.0)
        self.assertAlmostEqual(mass[[0, 127, -1], 6].sum().item(), 1.0)
        for mode, axes in ((0, (3, 4)), (1, (8, 9, 10))):
            actions = code / 127
            actions[:, 6] = mode
            by_mode = dist.command_log_probs(actions).exp()
            for axis in axes:
                self.assertAlmostEqual(by_mode[:, axis].sum().item(), 1.)
            if mode == 0:
                self.assertAlmostEqual(by_mode[[0, 127, -1], 10].sum().item(), 1.)
        first = torch.zeros((1, 11), dtype=torch.float64)
        second = first.clone()
        first[0, [0, 5, 6, 7]] = 2
        second[0, [0, 5, 6, 7]] = torch.tensor([1.02, 0.1, 0.4, 0.75], dtype=first.dtype)
        second[0, 2] = -0.8
        dist.proba_distribution(first.clone(), std)
        torch.testing.assert_close(dist.log_prob(first), dist.log_prob(second))

    def test_ignored_controls_and_gunner_zoom(self):
        dist = V6ControlDistribution(11).proba_distribution(torch.zeros(1, 11), torch.zeros(11))
        for mode, free, axes in ((1., 1., (3, 4, 7)), (0., 0., (7, 8, 9)),
                                 (-1., -1., (8, 9, 10)), (-1., 1., (3, 4, 10))):
            action = torch.zeros(1, 11)
            action[0, 6:8] = torch.tensor([mode, free])
            other = action.clone()
            other[0, list(axes)] = -1.
            torch.testing.assert_close(dist.log_prob(action), dist.log_prob(other))
            self.assertTrue((dist.command_log_probs(action)[0, list(axes)] == 0).all())
        for z1, z2 in ((-0.9, -0.6), (-0.4, 0.4), (0.6, 0.9)):
            pair = torch.zeros(2, 11)
            pair[:, 10] = torch.tensor([z1, z2])
            torch.testing.assert_close(*dist.log_prob(pair).unbind())

    def test_entropy_gradient_includes_camera_conditional_axes(self):
        torch.manual_seed(2731)
        # Exact conditional entropies at fixed std. Third person depends on
        # free-look, gunner uses ternary zoom, commander uses full analog zoom.
        means = torch.zeros(11, dtype=torch.float64, requires_grad=True)
        means.data[6:8] = torch.tensor([0.3, -0.4])
        sd = torch.full((11,), 0.55, dtype=torch.float64)
        d = V6ControlDistribution(11).proba_distribution(means.expand(16384, -1), sd.log())
        d.entropy().mean().backward()
        sampled_grad = means.grad.detach().clone()
        means.grad = None

        def probs(axis, boundaries):
            edges = torch.as_tensor(boundaries, dtype=means.dtype)
            cdf = torch.special.ndtr((edges - means[axis]) / sd[axis])
            return torch.diff(cdf, prepend=means.new_zeros(1), append=means.new_ones(1))

        def h(p):
            return -(p * p.log()).sum()

        view = probs(6, [-42.5 / 127, 42.5 / 127])
        free = probs(7, [0.5 / 127])
        analog = h(probs(3, (torch.arange(-127, 127) + 0.5) / 127))
        zoom = h(probs(10, [-0.5, 0.5]))
        exact = h(view) + view[0] * (h(free) + 2 * analog) + view[1] * (2 * analog + zoom) + view[2] * 3 * analog
        exact.backward()
        torch.testing.assert_close(sampled_grad[6:8], means.grad[6:8], atol=0.10, rtol=0.05)

    def test_rare_tail_scores_and_entropy_have_finite_gradients(self):
        mean = torch.linspace(-12, 12, 11).repeat(7, 1).requires_grad_()
        log_std = torch.full((11,), -2.0, requires_grad=True)
        dist = V6ControlDistribution(11).proba_distribution(mean, log_std)
        loss = dist.log_prob(-mean.sign()).mean() + dist.entropy().mean()
        loss.backward()
        self.assertTrue(torch.isfinite(loss) and mean.grad.isfinite().all() and log_std.grad.isfinite().all())

    def test_ppo_resume_preserves_parameters_optimizer_and_sampling(self):
        torch.set_num_threads(1)
        env = ToyControls()
        model = PPO('MlpPolicy', env, n_steps=8, batch_size=8, n_epochs=1, seed=42, device='cpu')
        model.learn(16)
        obs = torch.zeros((3, 4))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'model.zip'
            model.save(path)
            for algorithm in (PPO, HybridPPO):
                new = algorithm.load(path, env=env, device='cpu', custom_objects={'policy_class': V6ControlPolicy})
                for name, param in model.policy.state_dict().items():
                    torch.testing.assert_close(new.policy.state_dict()[name], param, rtol=0, atol=0)
                for idx, data in model.policy.optimizer.state_dict()['state'].items():
                    for key, value in data.items():
                        torch.testing.assert_close(new.policy.optimizer.state_dict()['state'][idx][key], value)
                torch.manual_seed(10)
                old_actions = model.policy(obs)[0]
                torch.manual_seed(10)
                actions, _, old_log_probs = new.policy(obs)
                torch.testing.assert_close(actions, old_actions)
                _, evaluated, entropy = new.policy.evaluate_actions(obs, actions)
                torch.testing.assert_close(old_log_probs, evaluated)
                self.assertTrue(entropy.isfinite().all())
                new.learn(8, reset_num_timesteps=False)
                self.assertEqual(new.num_timesteps, 24)
                target = Path(directory) / 'new.zip'
                new.save(target)
                restored = algorithm.load(target, device='cpu')
                self.assertIsInstance(restored.policy.action_dist, V6ControlDistribution)
                torch.testing.assert_close(new.policy(obs, deterministic=True)[0], restored.policy(obs, deterministic=True)[0])
        sde = PPO(V6ControlPolicy, env, n_steps=8, batch_size=8, use_sde=True, device='cpu')
        self.assertIsInstance(sde.policy.action_dist, StateDependentNoiseDistribution)
