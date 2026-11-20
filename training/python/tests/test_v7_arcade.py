import unittest

import gymnasium as gym
import numpy as np
from gymnasium.utils.env_checker import check_env

from tankrl.v7_arcade import ACTION_LABELS, OBS_LABELS, ROUNDS, ArcadeEnv


def drive_from_observation(obs):
    pos = dict(zip(OBS_LABELS, obs))
    return np.asarray([
        (pos["gate_x"] - pos["avatar_x"]) / ArcadeEnv.MOVE_RATE,
        (pos["gate_y"] - pos["avatar_y"]) / ArcadeEnv.MOVE_RATE,
        (pos["ring_x"] - pos["cursor_x"]) / ArcadeEnv.CURSOR_RATE,
        (pos["ring_y"] - pos["cursor_y"]) / ArcadeEnv.CURSOR_RATE,
        1, float(0 < pos["pulse_due_in"] < 0.1),
    ], dtype=np.float32).clip(-1, 1)


class ArcadeTests(unittest.TestCase):
    def test_gym_contract_shared_schema_and_seed(self):
        for stage in ROUNDS:
            env = ArcadeEnv("tiger1", stage)
            check_env(env, skip_render_check=True)
            a, _ = env.reset(seed=321)
            b, _ = env.reset(seed=321)
            np.testing.assert_array_equal(a, b)
            self.assertEqual(len(OBS_LABELS), env.observation_space.shape[0])
            self.assertEqual(len(ACTION_LABELS), env.action_space.shape[0])
            other, _ = env.reset(seed=123)
            self.assertFalse(np.array_equal(a, other))

    def test_all_stages_reachable_for_both_sides_with_observed_controls(self):
        for stage in ROUNDS:
            for tank, allied in [("tiger1", False), ("sherman75", True), ("t34_76", True)]:
                env = ArcadeEnv(tank, stage, allied_team=allied)
                for seed in range(12):
                    obs, _ = env.reset(seed=seed)
                    for _ in range(env.limit):
                        obs, rew, end, cutoff, info = env.step(drive_from_observation(obs))
                        self.assertTrue(env.observation_space.contains(obs))
                        self.assertAlmostEqual(sum(info["reward_components"].values()), rew)
                        if end or cutoff:
                            break
                    with self.subTest(stage=stage, tank=tank, seed=seed):
                        self.assertTrue(info["is_success"])
                        self.assertEqual(info["score"], info["goal"])
                        self.assertEqual(info["team_score"], info["team_goal"])
                        self.assertEqual(info["reason"], "rings_complete")

    def test_time_limit_and_competitor_termination_are_distinct(self):
        for stage, expected in [("v7_target", "time_limit"), ("v7_1v6", "rival_finished")]:
            env = ArcadeEnv("tiger1", stage)
            env.reset(seed=191)
            while True:
                _, _, end, cutoff, info = env.step(np.zeros(6))
                if end or cutoff:
                    break
            self.assertEqual(cutoff, expected == "time_limit")
            self.assertEqual(info["reason"], expected)
            self.assertFalse(info["is_success"])
            with self.assertRaises(gym.error.ResetNeeded):
                env.step(np.zeros(6))

    def test_gate_and_approach_cannot_be_farmed(self):
        env = ArcadeEnv("tiger1", "v7_side")
        obs, _ = env.reset(seed=101)
        sums = {}
        for turn in range(55):
            action = drive_from_observation(obs)
            action[4:] = 0
            if 10 <= turn % 20 < 15:
                action[:4] *= -1
            obs, _, _, _, info = env.step(action)
            for key, value in info["reward_components"].items():
                sums[key] = sums.get(key, 0) + value
        self.assertEqual(sums["side_checkpoint"], 4.0)
        self.assertLessEqual(sums["side_progress"], 0.7 + 1e-10)
        self.assertLessEqual(sums["cursor_progress"], 0.35 + 1e-10)
        self.assertEqual(info["score"], 0)

    def test_pulse_catches_are_distinct_and_share_budget(self):
        for tank in ("tiger1", "sherman75"):
            env = ArcadeEnv(tank, "v7_side")
            obs, _ = env.reset(seed=13)
            sums = {"shield_block": 0.0, "shield_reflect": 0.0}
            block_turn = env.pulse_turn
            for turn in range(75):
                action = np.zeros(6)
                if turn + 1 <= block_turn or obs[OBS_LABELS.index("pulse_due_in")] < 0.1:
                    action[5] = 1
                obs, _, _, _, info = env.step(action)
                parts = info["reward_components"]
                self.assertFalse("shield_reflect" in parts and "shield_block" in parts)
                for k in sums:
                    sums[k] += parts.get(k, 0)
            if tank == "tiger1":
                self.assertAlmostEqual(sums["shield_block"], 0.15)
                self.assertAlmostEqual(sum(sums.values()), ArcadeEnv.SHIELD_BUDGET)
                self.assertGreater(info["shield_reflects"], 1)
            else:
                self.assertEqual(sum(sums.values()), 0)
                self.assertEqual(info["shield_blocks"] + info["shield_reflects"], 0)

    def test_sighting_requires_visible_side_and_pays_once_per_distinct_id(self):
        env = ArcadeEnv("tiger1", "v7_1v6")
        env.reset(seed=25)
        for tile in env.tiles:
            tile.x, tile.y = env.avatar
            tile.face_phase = 0
        env.tiles[5].x = 1.0
        for _ in range(4):
            obs, _, _, _, info = env.step(np.zeros(6))
            self.assertEqual(info["reward_components"]["side_seen"], 0)
            self.assertFalse(obs[OBS_LABELS.index("tile_1_side_face")])
        obs, _, _, _, info = env.step(np.zeros(6))
        self.assertTrue(obs[OBS_LABELS.index("tile_1_side_face")])
        self.assertFalse(obs[OBS_LABELS.index("tile_6_visible")])
        self.assertEqual(info["reward_components"]["side_seen"], 2.5)
        self.assertEqual(info["side_seen_new_ids"], list(range(5)))
        self.assertEqual((info["score"], info["side_checkpoints"]), (0, 0))
        for tile in env.tiles[:5]:
            tile.x = 1.0
        env.tiles[5].x = env.avatar[0]
        _, _, _, _, info = env.step(np.zeros(6))
        self.assertEqual(info["side_seen_new_ids"], [5])
        self.assertEqual(info["reward_components"]["side_seen"], 0.5)
        for tile in env.tiles:
            tile.x = env.avatar[0]
        _, _, _, _, info = env.step(np.zeros(6))
        self.assertEqual(info["side_seen_count"], 6)
        self.assertEqual(info["reward_components"]["side_seen"], 0)
        _, info = env.reset(seed=25)
        self.assertEqual(info["side_seen_count"], 0)

    def test_allied_team_counts_colors_and_no_enemy_credit_for_friends(self):
        for stage, expected in [("v7_1v2", 1), ("v7_1v3", 2), ("v7_1v6", 5)]:
            env = ArcadeEnv("sherman75", stage, "rgb_array", allied_team=True)
            obs, info = env.reset(seed=44)
            self.assertEqual((info["allies"], info["rivals"]), (expected, 1))
            self.assertTrue(obs[OBS_LABELS.index("tile_2_ally")])
            self.assertFalse(obs[OBS_LABELS.index("tile_1_ally")])
            for tile in env.tiles:
                tile.face_phase = 4
            env.tiles[0].x, env.tiles[0].y = env.avatar
            _, _, _, _, info = env.step(np.zeros(6))
            self.assertEqual(info["side_seen_new_ids"], [0])
            frame = env.render()
            self.assertEqual(frame.shape, (128, 128, 3))
            self.assertEqual(frame.dtype, np.uint8)
            self.assertTrue(np.any(np.all(frame == (125, 211, 93), axis=2)))
            while True:
                _, _, end, cutoff, info = env.step(np.zeros(6))
                if end or cutoff:
                    break
            self.assertEqual(info["team_score"], expected)
            self.assertFalse(info["is_success"])


if __name__ == "__main__":
    unittest.main()
