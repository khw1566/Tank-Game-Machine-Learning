import json
import unittest

from tankrl.v7_curriculum import STAGES, STAGE_IDS, TANKS, V7Curriculum, WINDOW


class ArcadeCurriculumTest(unittest.TestCase):
    def test_new_avatars_use_first_stage_and_independent_histories(self):
        curricula = [V7Curriculum(tank) for tank in TANKS]
        self.assertEqual(STAGE_IDS, ["v7_target", "v7_side", "v7_1v1", "v7_1v2", "v7_1v3", "v7_1v6"])
        self.assertEqual([s["opponents"] for s in STAGES], [0, 0, 1, 2, 3, 6])
        self.assertEqual([s["rings"] for s in STAGES], [3, 3, 3, 4, 5, 6])
        for c in curricula:
            self.assertEqual((c.stage["id"], c.episodes_in_stage), ("v7_target", 0))
        self.assertFalse(curricula[0].record("v7_target", True))
        self.assertTrue(all(c.total_episodes == 0 for c in curricula[1:]))

    def test_rolling_threshold_excludes_outdated_results(self):
        c = V7Curriculum("tiger1")
        for _ in range(3 * WINDOW):
            self.assertFalse(c.record("v7_target", False))
        # The threshold of .75 requires 48 of the last 64 completed episodes.
        for _ in range(47):
            self.assertFalse(c.record("v7_target", True))
        self.assertTrue(c.record("v7_target", True))
        self.assertEqual(c.history[-1]["success_rate"], 0.75)
        self.assertEqual(c.stage["id"], "v7_side")
        # A parallel environment was still finishing a target-stage episode.
        self.assertFalse(c.record("v7_target", False))
        self.assertEqual(c.episodes_in_stage, 0)
        self.assertEqual(c.total_episodes, 3 * WINDOW + 49)
        self.assertEqual(c.success_rate("v7_side", WINDOW), 0.0)

    def test_resume_restores_pending_window_and_can_advance_to_final_stage(self):
        c = V7Curriculum("t34_76")
        for _ in range(WINDOW - 1):
            self.assertFalse(c.record("v7_target", True))
        state = json.loads(json.dumps(c.state()))
        resumed = V7Curriculum.from_state(state)
        self.assertEqual(resumed.state(), state)
        self.assertTrue(resumed.record("v7_target", True))
        self.assertEqual(c.episodes_in_stage, WINDOW - 1)
        for stage in STAGES[1:-1]:
            for _ in range(WINDOW - 1):
                self.assertFalse(resumed.record(stage["id"], True))
            self.assertTrue(resumed.record(stage["id"], True))
        for _ in range(WINDOW + 1):
            self.assertFalse(resumed.record("v7_1v6", True))
        self.assertEqual(resumed.stage["id"], "v7_1v6")
        self.assertEqual(resumed.episodes_in_stage, WINDOW + 1)
        self.assertEqual(len(resumed.history), len(STAGES) - 1)
        self.assertEqual(V7Curriculum.from_state(resumed.state()).state(), resumed.state())

    def test_foreign_state_future_episode_and_corrupt_history_are_rejected(self):
        c = V7Curriculum("sherman75")
        with self.assertRaises(ValueError):
            c.record("v7_side", True)
        self.assertEqual(c.total_episodes, 0)
        with self.assertRaises(ValueError):
            V7Curriculum.from_state({"curriculum_version": 7})
        state = c.state()
        state["stage_stats"]["v7_target"]["recent"] = [True]
        with self.assertRaises(ValueError):
            V7Curriculum.from_state(state)


if __name__ == "__main__":
    unittest.main()
