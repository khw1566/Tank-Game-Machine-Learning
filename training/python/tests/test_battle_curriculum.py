import json
import random
import tempfile
import unittest
from pathlib import Path

from tankrl.battle_curriculum import BattleCurriculum, STAGES, STAGE_IDS, TANKS, arena
from tankrl.opponents import OpponentPool


class BattleCurriculumTests(unittest.TestCase):
    def test_balance_upgrade_reassesses_without_claiming_old_mastery(self):
        c = BattleCurriculum("shared")
        self.fill_stage(c, STAGE_IDS[0], 3_000_000)
        old = c.state()
        old.pop("balance_version")
        old.pop("reward_version")
        old["common_complete"] = True
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "curriculum.json"
            path.write_text(json.dumps(old), encoding="utf-8")
            migrated = BattleCurriculum.load(path, "shared")
        self.assertEqual(migrated.stage["id"], "battle_flat")
        self.assertFalse(migrated.common_complete)
        self.assertFalse(any(v for pairs in migrated.results.values() for v in pairs.values()))
        self.assertEqual(migrated.history[-1]["reason"], "assessment_upgrade")

    def test_progressive_rewards_are_bounded_and_win_dominates(self):
        c = BattleCurriculum("shared")
        _, _, extra = c.build_episode("shared", random.Random(2), 2)
        reward = extra["reward"]
        auxiliary = reward["near_pen_budget"] + reward["near_miss_budget"] + reward["closing_budget"] + sum(reward["close_bonuses"])
        self.assertGreater(reward["win"], 10 * auxiliary)
        self.assertLess(reward["timeout_penalty"] + auxiliary + 36 * reward["combat"]["hit"], 0)
        self.assertTrue(reward["progressive_combat_v2"])
        self.assertEqual(extra["balance_version"], 2)

    def test_dashboard_passes_shared_battle_mode(self):
        from dashboard import Dashboard
        dashboard = object.__new__(Dashboard)
        dashboard.runs_dir = Path("runs")
        dashboard.settings = {}
        dashboard.train_python = lambda: "python"
        cmd = dashboard.build_cmd({"godot": "TankGame_battle.exe", "run": "unit",
                                   "tank": "shared", "curriculum": "battle"})
        self.assertEqual(cmd.count("--curriculum"), 1)
        self.assertEqual(cmd[cmd.index("--curriculum") + 1], "battle")
        self.assertIn("--auto-branch", cmd)

    def test_seeded_arenas_and_real_team_lineups(self):
        for stage in STAGES:
            for variant in stage["variants"]:
                for tank in TANKS:
                    result = arena(stage["id"], variant, tank, 19)
                    self.assertEqual(result, arena(stage["id"], variant, tank, 19))
                    lu, sc, mc = result
                    self.assertEqual(len(sc["enemies"]) + 1, len(lu))
                    self.assertEqual(lu[0]["role"], "learner")
                    self.assertTrue(all(d["ctrl"] == "external" for d in lu))
                    positions = [sc["learner"]["p"]] + [p["p"] for p in sc["enemies"]]
                    self.assertEqual(len(positions), len({tuple(p) for p in positions}))
                    self.assertEqual(sc["goal"], "battle")
                    if stage["id"] == "battle_flat":
                        self.assertEqual(mc["amplitude"], 0)
                        self.assertFalse(sc["obstacles"])
                        self.assertEqual(lu[1]["type"], tank)
                    if variant == "team":
                        self.assertEqual(len(lu), 7)
                        self.assertEqual(sum(d["team"] == 0 for d in lu), 1)
                        self.assertEqual(sum(d["team"] == 1 for d in lu), 6)

    def test_frozen_opponents_never_use_mutable_latest(self):
        with tempfile.TemporaryDirectory() as directory:
            pool = OpponentPool(directory)
            shared = Path(directory) / "shared"
            shared.mkdir()
            (shared / "latest.zip").touch()
            with self.assertRaises(RuntimeError):
                pool.pick_frozen("tiger1", random.Random(1))
            (shared / "step_000000001.zip").touch()
            self.assertEqual(pool.pick_frozen("tiger1", random.Random(1)), "shared/step_000000001.zip")

    def fill_stage(self, c, sid, step, *, hit=1, pen=1, resolved=True):
        event = None
        for variant in STAGES[STAGE_IDS.index(sid)]["variants"]:
            for tank in c.tanks:
                for i in range(40):
                    # 50% 승률도 실제 교전이 성립하면 승급할 수 있다.
                    event = c.report_battle(sid, i % 2 == 0, step, variant, tank,
                                           {"hits": hit, "pens": pen}, {"winner": 0 if resolved else -1}) or event
        return event

    def test_progress_requires_combat_not_just_steps_or_wins(self):
        c = BattleCurriculum("shared", review_prob=0)
        self.assertIsNone(self.fill_stage(c, STAGE_IDS[0], 3_000_000, hit=0, pen=0, resolved=False))
        self.assertEqual(c.stage_idx, 0)
        event = self.fill_stage(c, STAGE_IDS[0], 3_000_000)
        self.assertEqual(event["to"], STAGE_IDS[1])
        self.assertIsNone(self.fill_stage(c, STAGE_IDS[1], 3_100_000))
        self.assertFalse(c.training_complete)
        event = self.fill_stage(c, STAGE_IDS[1], 6_100_000)
        self.assertEqual(event["to"], "branch_tanks")
        self.assertTrue(c.training_complete)
        for tank in TANKS:
            child = c.branch(tank, 6_100_000, "shared/step_006100000")
            self.assertEqual(child.stage_idx, 2)
            self.assertFalse(child.training_complete)
            self.assertEqual(len(child.metrics[STAGE_IDS[0]]["close@" + tank]), 80)

    def test_restore_preserves_progress_and_no_cross_curriculum_load(self):
        c = BattleCurriculum("shared")
        self.fill_stage(c, STAGE_IDS[0], 3_000_000)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "curriculum.json"
            c.save(path)
            restored = BattleCurriculum.load(path, "shared")
            self.assertEqual(c.state(), restored.state())
            with self.assertRaises(ValueError):
                BattleCurriculum.load(path, "tiger1")
            bad = json.loads(path.read_text(encoding="utf-8"))
            bad["curriculum_version"] = 4
            path.write_text(json.dumps(bad), encoding="utf-8")
            with self.assertRaises(ValueError):
                BattleCurriculum.load(path, "shared")


if __name__ == "__main__":
    unittest.main()
