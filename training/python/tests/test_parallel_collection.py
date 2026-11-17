"""여러 전장 수집(Segments)이 단일 전장 순차 수집과 같은 이득·가치를 만드는지."""
import unittest

import numpy as np
import torch
from stable_baselines3 import PPO
from stable_baselines3.common.utils import obs_as_tensor

from tankrl.independent_training import Segments
from tankrl.individuals import PolicySpaces


def make_model(n_steps=8):
    model = PPO('MlpPolicy', PolicySpaces(), n_steps=n_steps, batch_size=n_steps, n_epochs=1, seed=3, device='cpu')
    model.policy.set_training_mode(False)
    return model


def transitions(model, rng, n, terminal_at=()):
    out = []
    for t in range(n):
        obs = rng.standard_normal((1, 389)).astype(np.float32)
        with torch.no_grad():
            action, value, logp = model.policy(obs_as_tensor(obs, 'cpu'))
        out.append([obs, action.numpy(), float(rng.normal()), t == 0 or (t - 1) in terminal_at, value, logp,
                    t in terminal_at])
    return out


class SegmentTests(unittest.TestCase):
    def test_single_env_matches_sequential_gae(self):
        rng = np.random.default_rng(0)
        model = make_model()
        items = transitions(model, rng, 8, terminal_at=(3,))
        live = rng.standard_normal((1, 389)).astype(np.float32)
        # 기존 방식: 버퍼에 바로 넣고 마지막 다음 상태 가치로 GAE
        buf = model.rollout_buffer
        for it in items:
            buf.add(it[0], it[1], np.array([it[2]]), np.array([it[3]]), it[4], it[5])
        with torch.no_grad():
            last = model.policy.predict_values(obs_as_tensor(live, 'cpu'))
        buf.compute_returns_and_advantage(last_values=last, dones=np.array([False]))
        expected = buf.advantages.copy(), buf.returns.copy()
        buf.reset()
        # 새 방식: 구간을 모았다가 flush (train 은 막고 버퍼만 비교)
        seg = Segments(1)
        seg.lists[0] = [list(it) for it in items]
        import tankrl.independent_training as it_mod
        original = it_mod._train
        captured = {}
        it_mod._train = lambda m: captured.update(adv=m.rollout_buffer.advantages.copy(), ret=m.rollout_buffer.returns.copy())
        try:
            self.assertTrue(seg.flush(model, [live], [True]))
        finally:
            it_mod._train = original
        np.testing.assert_allclose(captured['adv'], expected[0], rtol=1e-5, atol=1e-5)
        np.testing.assert_allclose(captured['ret'], expected[1], rtol=1e-5, atol=1e-5)
        self.assertEqual(len(seg), 0)

    def test_two_envs_fill_exactly_and_carry_rest(self):
        rng = np.random.default_rng(1)
        model = make_model()
        seg = Segments(2)
        seg.lists[0] = transitions(model, rng, 5)
        seg.lists[1] = transitions(model, rng, 5)
        lives = [rng.standard_normal((1, 389)).astype(np.float32) for _ in range(2)]
        import tankrl.independent_training as it_mod
        original = it_mod._train
        starts = {}
        it_mod._train = lambda m: starts.update(s=m.rollout_buffer.episode_starts.copy().ravel())
        try:
            self.assertTrue(seg.flush(model, lives, [True, True]))
        finally:
            it_mod._train = original
        # 전장 0 의 5개 + 전장 1 의 앞 3개 = 8. 전장 경계는 새 구간 시작으로 표시
        self.assertEqual(starts['s'][0], 1.0)
        self.assertEqual(starts['s'][5], 1.0)
        self.assertEqual(len(seg.lists[0]), 0)
        self.assertEqual(len(seg.lists[1]), 2)
        self.assertTrue(seg.lists[1][0][3])


if __name__ == '__main__':
    unittest.main()
