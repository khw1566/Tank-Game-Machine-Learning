import tempfile
import unittest
from pathlib import Path

import gymnasium as gym
import torch
from stable_baselines3 import PPO

from tankrl.health import HealthConfig, HealthMonitor


def ok_log(kl=0.02, ev=0.9):
    import numpy as np   # SB3 logger values arrive as numpy floats
    return {"train/approx_kl": np.float32(kl), "train/explained_variance": np.float32(ev), "train/loss": np.float32(0.1)}


class HealthTest(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp())
        self.model = PPO("MlpPolicy", gym.make("Pendulum-v1"), use_sde=True, n_steps=64, batch_size=64, device="cpu")

    def test_good_checkpoints_and_rollback(self):
        h = HealthMonitor(self.dir, HealthConfig(std_cap=0))
        snap = self.dir / "step_000001000.zip"
        self.model.save(snap)
        h.mark_saved(1000, "m1", snap, 0.5)
        self.assertEqual(h.good, [], "not marked before enough healthy checks")
        for i in range(3):
            self.assertEqual(h.check(i, "m1", ok_log(), 0.5, self.model)["verdict"], "ok")
        h.mark_saved(1000, "m1", snap, 0.5)
        self.assertEqual(len(h.good), 1)
        self.assertTrue((self.dir / "good" / "best_m1.zip").exists())
        before = {k: v.clone() for k, v in self.model.policy.state_dict().items()}
        with torch.no_grad():                       # simulate a broken policy
            for p in self.model.policy.parameters():
                p.add_(5.0)
        verdicts = [h.check(10 + i, "m1", ok_log(kl=0.9), 0.5, self.model)["verdict"] for i in range(3)]
        self.assertEqual(verdicts, ["warning", "warning", "collapse"])
        target = h.rollback(self.model, "m1")
        self.assertEqual(target["step"], 1000)
        for k, v in self.model.policy.state_dict().items():
            self.assertTrue(torch.equal(v, before[k]), k)
        # state survives a restart
        h2 = HealthMonitor(self.dir)
        self.assertEqual(h2.rollbacks["m1"], 1)
        self.assertEqual(len(h2.good), 1)

    def test_success_drop_and_nonfinite(self):
        h = HealthMonitor(self.dir, HealthConfig(std_cap=0, success_patience=2))
        h.check(0, "m2", ok_log(), 0.9, self.model)
        self.assertEqual(h.check(1, "m2", ok_log(), 0.4, self.model)["verdict"], "warning")
        self.assertIn("success", h.check(2, "m2", ok_log(), 0.4, self.model)["reasons"])
        bad = h.check(3, "m2", {"train/approx_kl": 0.01, "train/loss": float("nan")}, 0.9, self.model)
        self.assertIn("nonfinite", bad["reasons"])
        self.assertIsNone(HealthMonitor(Path(tempfile.mkdtemp())).rollback(self.model, "m2"), "no backup -> no rollback")


if __name__ == "__main__":
    unittest.main()
