"""Verify full trainer and recorder paths using only temporary, synthetic fixtures."""
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

import numpy as np
import torch
from stable_baselines3 import PPO

import train_v7
from tankrl.storage import checkpoint_paths, save_checkpoint, sha256
from tankrl.v7_curriculum import STAGE_IDS, TANKS, V7Curriculum
from tankrl.v7_godot import ACTION_LABELS, DEMO_FORMAT, OBS_LABELS, PHYSICS_HZ, PROTOCOL, REPEAT, NativeGodotEnv
from tankrl.v7_godot import expected_layout
from tankrl.v7_imitation import read_demonstration


PROJECT = Path(__file__).resolve().parents[3]
EDITOR = (os.getenv("GODOT4") or shutil.which("godot4") or shutil.which("godot")
          or str(PROJECT / "build/_tools/godot-4.3/Godot_v4.3-stable_win64_console.exe"))


def json_file(path):
    return json.loads(path.read_text(encoding="utf-8"))


def synthetic_demo(directory, seed):
    # Build a deterministic file-format fixture only in the test's temporary corpus.
    rng = np.random.default_rng(seed)
    obs = rng.uniform(-1, 1, size=(24, len(OBS_LABELS))).astype(np.float32)
    actions = np.tile(np.array([0.5, 0.5, 0, -1, 0, 1, 0, 0.3, -0.2], dtype=np.float32), (len(obs), 1))
    path = directory / "sherman75" / f"fixture_{seed}.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(dict(format=DEMO_FORMAT, source="godot-human", protocol=PROTOCOL,
                                    physics_hz=PHYSICS_HZ, repeat=REPEAT, tank="sherman75",
                                    stage="v7_1v2", seed=seed, completed=True, allied_team=True,
                                    layout=expected_layout("sherman75", "v7_1v2", seed),
                                    obs_labels=OBS_LABELS, action_labels=ACTION_LABELS,
                                    obs=obs.tolist(), actions=actions.tolist())), encoding="utf-8")
    return path, obs, actions


class NativeTrainingTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.demos = self.base / "synthetic-demo-fixtures"
        self.run = self.base / "runs" / "test-v7"
        self.args = ["--runs-dir", str(self.run.parent), "--run", self.run.name,
                     "--demos-dir", str(self.demos), "--tank", "sherman75",
                     "--n-envs", "1", "--timesteps", "128", "--device", "cpu", "--seed", "182",
                     "--godot", EDITOR, "--project", str(PROJECT)]

    def test_refuse_prior_v6_folder_before_preparing_models(self):
        self.run.mkdir(parents=True)
        old = self.run / "run.json"
        old.write_text('{"stageset":"v6"}', encoding="utf-8")
        with self.assertRaises(ValueError):
            train_v7.main([*self.args, "--resume"])
        self.assertEqual(json_file(old), {"stageset": "v6"})
        self.assertFalse(any((self.run / tank).exists() for tank in TANKS))

    def test_native_bc_before_first_rollout_and_resume(self):
        train_v7.main([*self.args, "--prepare-only"])
        original = {}
        first_layers = []
        for tank in TANKS:
            model_path, state_path = checkpoint_paths(self.run / tank)
            model = PPO.load(model_path, device="cpu")
            self.assertEqual((model.num_timesteps, model._n_updates), (0, 0))
            self.assertFalse(model.policy.optimizer.state)
            first_layer = model.policy.mlp_extractor.policy_net[0].weight.detach().clone()
            self.assertFalse(any(torch.equal(first_layer, other) for other in first_layers))
            first_layers.append(first_layer)
            self.assertEqual(json_file(state_path)["stage"], STAGE_IDS[0])
            original[tank] = sha256(model_path)
            if tank == "sherman75":
                random_weights = {k: v.clone() for k, v in model.policy.state_dict().items()}
        self.assertEqual(len(set(original.values())), len(TANKS))
        self.assertEqual(json_file(self.run / "run.json")["initialization"], "random")

        with self.assertRaises(ValueError):
            train_v7.main([*self.args, "--resume", "--behavior-clone"])
        self.assertFalse((self.run / "progress.csv").exists())
        self.assertEqual(json_file(self.run / "run.json")["sessions"], [])
        fixtures = []
        for seed in (77, 199):
            path, observations, controls = synthetic_demo(self.demos, seed)
            fixtures.append(path)
            obs, actions = read_demonstration(path, "sherman75")
            np.testing.assert_array_equal(obs, observations)
            np.testing.assert_array_equal(actions, controls)
            self.assertEqual(obs.shape, (len(actions), len(OBS_LABELS)))
            self.assertEqual(actions.shape[1], len(ACTION_LABELS))
            with self.assertRaises(ValueError):
                read_demonstration(path, "t34_76")

        incomplete = json_file(fixtures[0])
        incomplete["completed"] = False
        incomplete_path = self.base / "incomplete.json"
        incomplete_path.write_text(json.dumps(incomplete), encoding="utf-8")
        with self.assertRaises(ValueError):
            read_demonstration(incomplete_path, "sherman75")
        with self.assertRaises(ValueError):
            read_demonstration(self.base / "previous_browser_episode.npz", "sherman75")

        args = train_v7.parse(self.args)
        with self.assertRaises(ValueError):
            train_v7.apply_demonstrations(self.run, args, ("sherman75", "t34_76"))
        for tank, digest in original.items():
            self.assertEqual(sha256(checkpoint_paths(self.run / tank)[0]), digest)
        train_v7.apply_demonstrations(self.run, args, ("sherman75",))
        cloned_path, state_path = checkpoint_paths(self.run / "sherman75")
        lineage = json_file(state_path)["behavior_clone"]
        self.assertEqual(lineage["tank"], "sherman75")
        self.assertEqual({s["sha256"] for s in lineage["sources"]}, {sha256(p) for p in fixtures})
        self.assertEqual(len(lineage["held_out_files"]), 1)
        self.assertLess(lineage["train_mse_after"], lineage["train_mse_before"])
        cloned = PPO.load(cloned_path, device="cpu")
        self.assertEqual((cloned.num_timesteps, cloned._n_updates), (0, 0))
        self.assertFalse(cloned.policy.optimizer.state)
        cloned_weights = cloned.policy.state_dict()
        self.assertFalse(torch.equal(random_weights["action_net.weight"], cloned_weights["action_net.weight"]))
        for key in cloned_weights:
            if "value_net" in key:
                self.assertTrue(torch.equal(random_weights[key], cloned_weights[key]), key)

        if not Path(EDITOR).is_file():
            self.skipTest("A Godot editor is required for the native PPO integration")
        with patch.object(train_v7, "clone_actor", side_effect=AssertionError("BC repeated")):
            train_v7.main([*self.args, "--resume", "--behavior-clone"])
        path, state_path = checkpoint_paths(self.run / "sherman75")
        state = json_file(state_path)
        trained = PPO.load(path, device="cpu")
        self.assertEqual(trained.num_timesteps, 128)
        self.assertGreater(trained._n_updates, 0)
        self.assertTrue(trained.policy.optimizer.state)
        self.assertEqual(state["behavior_clone"], lineage)
        self.assertEqual(state["stage"], STAGE_IDS[0])
        self.assertEqual(json_file(self.run / "run.json")["sessions"][-1]["runtime"]["environment"], PROTOCOL)

        # Generate a normal promoted curriculum state to exercise resuming a later stage.
        cur = V7Curriculum.from_state(state)
        for _ in range(2 * cur.stage["promote"]["window"]):
            if cur.record(STAGE_IDS[0], True):
                break
        self.assertEqual(cur.stage["id"], STAGE_IDS[1])
        save_checkpoint(trained, self.run / "sherman75", dict(cur.state(), behavior_clone=lineage))
        with patch.object(train_v7, "clone_actor", side_effect=AssertionError("BC repeated on resume")):
            train_v7.main([*self.args, "--resume", "--behavior-clone"])
        final_path, state_path = checkpoint_paths(self.run / "sherman75")
        resumed = PPO.load(final_path, device="cpu")
        self.assertEqual(resumed.num_timesteps, 256)
        self.assertGreater(resumed._n_updates, trained._n_updates)
        final = json_file(state_path)
        self.assertEqual(final["behavior_clone"], lineage)
        self.assertEqual(final["stage"], STAGE_IDS[1])
        for tank in ("t34_76", "tiger1"):
            self.assertEqual(sha256(checkpoint_paths(self.run / tank)[0]), original[tank])

    @unittest.skipUnless(Path(EDITOR).is_file(), "Godot editor missing")
    def test_actual_engine_observations_change_when_tracks_move(self):
        env = NativeGodotEnv("t34_76", "v7_1v3", EDITOR, PROJECT)
        self.addCleanup(env.close)
        first, _ = env.reset(seed=91)
        self.assertEqual(env.hello["protocol"], PROTOCOL)
        action = np.zeros(len(ACTION_LABELS), dtype=np.float32)
        action[:2] = 1
        for _ in range(16):
            latest, reward, terminated, truncated, info = env.step(action)
            self.assertTrue(env.observation_space.contains(latest))
            self.assertFalse(terminated or truncated)
        self.assertIn("reward_components", info)
        self.assertNotEqual(first[OBS_LABELS.index("vehicle.speed")], latest[OBS_LABELS.index("vehicle.speed")])


if __name__ == "__main__":
    unittest.main()
