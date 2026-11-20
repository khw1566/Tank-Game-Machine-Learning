"""Device selection, CUDA rollout equivalence and CPU checkpoint migration checks.

Run: .venv/Scripts/python.exe -m unittest discover -s tests -p test_gpu_runtime.py -v
"""
from argparse import Namespace
import json
import random
from pathlib import Path
import tempfile
import unittest

import gymnasium as gym
import numpy as np
import torch
from stable_baselines3.common.buffers import RolloutBuffer
from stable_baselines3.common.callbacks import BaseCallback
from stable_baselines3.common.vec_env import DummyVecEnv

from dashboard import Dashboard
from tankrl.rollout_buffer import CudaRolloutBuffer
from tankrl.runtime import hardware_info, model_runtime, resolve_device, select_device
from tankrl.opponents import OpponentPool
from train import build_model, v6_sampling_seed


class VectorEnv(gym.Env):
    observation_space = gym.spaces.Box(-1, 1, (389,), np.float32)
    action_space = gym.spaces.Box(-1, 1, (11,), np.float32)

    def reset(self, seed=None, options=None):
        super().reset(seed=seed)
        self.steps = 0
        return np.zeros(389, dtype=np.float32), {}

    def step(self, action):
        self.steps += 1
        return np.full(389, self.steps / 100, dtype=np.float32), -float(np.square(action).mean()), False, self.steps == 16, {}


def args(device):
    return Namespace(device=device, resolved_device=device, n_steps=8, batch_size=8,
                     n_epochs=2, lr=3e-4, gamma=0.99, gae_lambda=0.95, ent_coef=0.005, sde_freq=4, seed=0, log_std_init=-0.5, use_sde=True)


class DeviceTests(unittest.TestCase):
    def test_v6_sampling_changes_on_rotation_and_resume(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = v6_sampling_seed(root, 0, "tiger1", 1000)
            self.assertEqual(first, v6_sampling_seed(root, 0, "tiger1", 1000))
            other_tank = v6_sampling_seed(root, 0, "sherman75", 1000)
            next_step = v6_sampling_seed(root, 0, "tiger1", 2000)
            (root / "run.json").write_text(json.dumps({"sessions": [{}]}), encoding="utf-8")
            same_step_resume = v6_sampling_seed(root, 0, "tiger1", 1000)
            self.assertEqual(len({first, other_tank, next_step, same_step_resume}), 4)

    def test_loading_v6_frozen_opponent_preserves_learner_random_streams(self):
        env = DummyVecEnv([VectorEnv])
        with tempfile.TemporaryDirectory() as directory:
            pool = OpponentPool(directory)
            pool.input_env = env
            model = build_model(args("cpu"), env)
            model.save(Path(directory) / "opponent.zip")
            model.set_random_seed(7)
            expected = (random.random(), np.random.random(), torch.rand(5))
            model.set_random_seed(7)
            pool._load("opponent.zip")
            self.assertEqual(expected[0], random.random())
            self.assertEqual(expected[1], np.random.random())
            self.assertTrue(torch.equal(expected[2], torch.rand(5)))
        env.close()

    def test_cpu_install_explicit_cuda_rejected_auto_allowed(self):
        info = {"cuda_available": False, "cuda_version": None}
        self.assertEqual(select_device("auto", info), "cpu")
        self.assertEqual(select_device("cpu", info), "cpu")
        with self.assertRaisesRegex(RuntimeError, "CPU 전용"):
            select_device("cuda", info)

    def test_gpu_index_and_invalid_device(self):
        info = {"cuda_available": True, "gpus": [{"index": 0}]}
        self.assertEqual(select_device("auto", info), "cuda:0")
        with self.assertRaises(ValueError):
            select_device("cuda:1", info)
        for device in ("cuda:-1", "cuda:abc", "gpu", "cpu:1"):
            with self.assertRaises(ValueError):
                select_device(device, info)

    def test_restart_preserves_gpu_and_explicit_ppo_settings(self):
        with tempfile.TemporaryDirectory() as td:
            dash = Dashboard.__new__(Dashboard)
            dash.runs_dir = Path(td)
            dash.settings = {"device": "auto"}
            dash.train_python = lambda: "python.exe"
            run_dir = Path(td) / "sample"
            run_dir.mkdir()
            settings = {"godot": "TankGame.exe", "device": "cuda:0", "n_envs": 8,
                        "n_steps": 1024, "batch_size": 2048, "n_epochs": 8,
                        "torch_threads": 1, "lr": 0.0001, "sde_freq": 20}
            (run_dir / "run.json").write_text(json.dumps({"sessions": [{"args": settings}]}))
            (run_dir / "status.json").write_text(json.dumps({"target_timesteps": 3000000,
                                                              "num_timesteps": 135952}))
            restart = dash.restart_args("sample", {"n_envs": 6})
            command = dash.build_cmd(restart)
            self.assertEqual(restart["device"], "cuda:0")
            self.assertEqual(restart["timesteps"], 2864048)
            for flag, value in (("--device", "cuda:0"), ("--batch-size", "2048"),
                                ("--n-steps", "1024"), ("--n-epochs", "8"), ("--n-envs", "6")):
                self.assertEqual(command[command.index(flag) + 1], value)

    def test_cpu_resume_applies_explicit_rollout_override(self):
        self._resume_check("cpu")

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA GPU required")
    def test_cuda_resume_train_save_then_load_on_cpu(self):
        self.assertTrue(resolve_device("cuda").startswith("cuda"))
        self.assertTrue(hardware_info()["gpus"])
        self._resume_check("cuda:0")

    @unittest.skipUnless(torch.cuda.is_available(), "CUDA GPU required")
    def test_hybrid_cpu_collection_gpu_update_and_mid_rollout_checkpoint(self):
        torch.set_num_threads(1)
        env = DummyVecEnv([VectorEnv, VectorEnv])
        config = args("hybrid")
        config.resolved_device = "cuda:0"
        try:
            with tempfile.TemporaryDirectory() as td:
                model = build_model(config, env)
                path = Path(td) / "during_collection.zip"

                class Check(BaseCallback):
                    def _on_rollout_start(cb):
                        for name, parameter in cb.model.policy.state_dict().items():
                            torch.testing.assert_close(parameter,
                                                       cb.model._update_policy.state_dict()[name].cpu(),
                                                       rtol=0, atol=0)

                    def _on_step(cb):
                        self.assertEqual(cb.model.policy.device.type, "cpu")
                        self.assertEqual(cb.model.training_device.type, "cuda")
                        if cb.num_timesteps == 18:  # optimizer already updated on the first rollout
                            cb.model.save(path)
                        return True

                model.learn(32, callback=Check())
                self.assertEqual(model.policy.device.type, "cuda")
                self.assertGreater(model._n_updates, 0)
                restored = build_model(config, env, path)
                self.assertEqual(restored.num_timesteps, 18)
                self.assertTrue(restored.policy.optimizer.state)
                for state in restored.policy.optimizer.state.values():
                    self.assertEqual(state["exp_avg"].device.type, "cuda")
                rt = model_runtime(model, "hybrid")
                self.assertEqual(rt["inference_device"], "cpu")
                self.assertEqual(rt["update_device"], "cuda:0")
                self.assertIsNot(model._rollout_policy, model.policy)
                config.device = "auto"
                automatic = build_model(config, env, path)
                self.assertEqual(model_runtime(automatic, "auto")["mode"], "hybrid")
        finally:
            env.close()

    def _resume_check(self, device):
        torch.set_num_threads(1)
        env = DummyVecEnv([VectorEnv, VectorEnv])
        try:
            with tempfile.TemporaryDirectory() as td:
                original = build_model(args("cpu"), env)
                original.learn(16)
                expected, _ = original.predict(np.zeros((2, 389), np.float32), deterministic=True)
                path = Path(td) / "cpu.zip"
                original.save(path)
                config = args(device)
                config.n_steps, config.batch_size = 16, 16
                resumed = build_model(config, env, path)
                self.assertEqual(resumed.num_timesteps, 16)
                self.assertEqual(resumed.rollout_buffer.buffer_size, 16)
                self.assertEqual(resumed.batch_size, 16)
                self.assertEqual(model_runtime(resumed, device)["device"], device)
                actual, _ = resumed.predict(np.zeros((2, 389), np.float32), deterministic=True)
                np.testing.assert_allclose(expected, actual, rtol=1e-4, atol=1e-5)
                before = next(resumed.policy.parameters()).detach().clone()
                resumed.learn(32, reset_num_timesteps=False)
                self.assertEqual(resumed.num_timesteps, 48)
                self.assertFalse(torch.equal(before, next(resumed.policy.parameters())))
                for parameter in resumed.policy.parameters():
                    self.assertTrue(torch.isfinite(parameter).all())
                resumed.save(Path(td) / "updated.zip")
                loaded_cpu = build_model(args("cpu"), env, Path(td) / "updated.zip")
                self.assertEqual(str(next(loaded_cpu.policy.parameters()).device), "cpu")
                self.assertEqual(loaded_cpu.num_timesteps, 48)
        finally:
            env.close()


class BufferTests(unittest.TestCase):
    @unittest.skipUnless(torch.cuda.is_available(), "CUDA GPU required")
    def test_cached_samples_match_sb3_across_epochs_and_reset(self):
        cpu = RolloutBuffer(4, VectorEnv.observation_space, VectorEnv.action_space, n_envs=2, device="cpu")
        cuda = CudaRolloutBuffer(4, VectorEnv.observation_space, VectorEnv.action_space, n_envs=2, device="cuda:0")
        rng = np.random.default_rng(123)
        for field in ("observations", "actions", "values", "log_probs", "advantages", "returns"):
            values = rng.normal(size=getattr(cpu, field).shape).astype(np.float32)
            setattr(cpu, field, values.copy())
            setattr(cuda, field, values.copy())
        cpu.full = cuda.full = True
        for epoch in range(2):
            np.random.seed(10 + epoch)
            expected = list(cpu.get(3))
            np.random.seed(10 + epoch)
            actual = list(cuda.get(3))
            for left, right in zip(expected, actual):
                for a, b in zip(left, right):
                    self.assertEqual(b.device.type, "cuda")
                    np.testing.assert_array_equal(a.numpy(), b.cpu().numpy())
        self.assertIsNotNone(cuda._device_samples)
        cuda.reset()
        self.assertIsNone(cuda._device_samples)
        self.assertFalse(cuda.generator_ready)


if __name__ == "__main__":
    unittest.main()
