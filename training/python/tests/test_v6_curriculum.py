import random
import unittest

from tankrl import v6_curriculum as v6
from tankrl.input_migration import legacy_labels


class V6CurriculumTest(unittest.TestCase):
    def test_ladder_lineups(self):
        for stage in v6.STAGES:
            for tank in v6.TANKS:
                for seed in range(20):
                    lu, sc, mc, n_rule = v6.arena(stage, "village", tank, seed)
                    self.assertEqual(lu[0]["type"], tank)
                    self.assertEqual(lu[0]["ctrl"], "external")
                    self.assertEqual(sum(1 for d in lu if d["type"] == "tiger1"), 1)
                    self.assertEqual(len(lu), stage["allies"] + 1)
                    lo, hi = stage["rule"]
                    self.assertLessEqual(n_rule, hi)
                    rules = [d for d in lu if d["ctrl"] == "scripted"]
                    self.assertEqual(len(rules), n_rule)
                    self.assertTrue(all(d["type"] != "tiger1" for d in rules))
                    self.assertEqual(len(sc["enemies"]), stage["allies"])
                    scripted_places = [p for d, p in zip(lu, [sc["learner"]] + sc["enemies"]) if d["ctrl"] == "scripted"]
                    self.assertTrue(all("ai" in p for p in scripted_places))

    def test_reward_shaping_decays_and_exchange_is_constant(self):
        rewards = [v6.reward_config(s) for s in v6.STAGES]
        self.assertTrue(all(r["exchange"] == rewards[0]["exchange"] for r in rewards))
        self.assertEqual(rewards[-1]["combat"]["hit"], 0.0)
        self.assertGreater(rewards[0]["combat"]["hit"], rewards[1]["combat"]["hit"])
        self.assertTrue(all(r["win"] == 0 and r["timeout_penalty"] == 0 for r in rewards))
        self.assertTrue(all(r["combat"]["knockout"] == 0 and r["combat"]["penetration"] == 0 for r in rewards))

    def test_promotion_needs_every_map(self):
        cur = v6.V6Curriculum("tiger1")
        good = {"winner": 0, "scenario": {"path_m": 50}, "exchange": {"team_lost": [0.2, 1.0]}}
        stats = {"hits": 1}
        promo = None
        for _ in range(60):
            for m in v6.MAP_IDS[:-1]:
                promo = promo or cur.report_battle("v6_1v1", True, 1, m, "tiger1", stats, good)
        self.assertIsNone(promo)
        for _ in range(60):
            promo = promo or cur.report_battle("v6_1v1", True, 1, v6.MAP_IDS[-1], "tiger1", stats, good)
        self.assertIsNotNone(promo)
        self.assertEqual(cur.stage["id"], "v6_1v2")

    def test_stationary_policy_is_not_promoted(self):
        cur = v6.V6Curriculum("tiger1")
        still = {"winner": 0, "scenario": {"path_m": 2}, "exchange": {"team_lost": [0.0, 1.0]}}
        for _ in range(80):
            for m in v6.MAP_IDS:
                self.assertIsNone(cur.report_battle("v6_1v1", True, 1, m, "tiger1", {}, still))
        self.assertEqual(cur.stage["id"], "v6_1v1")

    def test_state_roundtrip(self):
        import json, tempfile, os
        cur = v6.V6Curriculum("sherman75", start_stage=2)
        cur.report_battle("v6_1v3", False, 5, "valley", "sherman75", {}, {"winner": 0, "scenario": {}})
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "c.json")
            cur.save(p)
            back = v6.V6Curriculum.load(p, "sherman75")
        self.assertEqual(back.stage["id"], "v6_1v3")
        self.assertEqual(len(back.metrics["v6_1v3"]["valley@sherman75"]), 1)
        self.assertIsNotNone(json.dumps(back.state()))

    def test_episode_review_uses_lower_stage(self):
        cur = v6.V6Curriculum("tiger1", start_stage=3, review_prob=1.0)
        st, lu, extra = cur.build_episode("tiger1", random.Random(1), 7)
        self.assertNotEqual(st["id"], "v6_1v6")
        self.assertEqual(extra["v6_version"], 1)


class LegacyLabelTest(unittest.TestCase):
    def test_removes_only_extra_enemy_slots(self):
        labels = ["self.x", "enemy0.present", "enemy5.present", "ally0.present", "aim3.hull.vis", "aim4.hull.vis",
                  "sit.known_enemies", "enemy0.team", "ally1.team", "fireline.ally_in_line", "fire.cue_present"]
        self.assertEqual(legacy_labels(labels, 4), ["self.x", "enemy0.present", "ally0.present", "aim3.hull.vis",
                                                   "sit.known_enemies", "fire.cue_present"])


if __name__ == "__main__":
    unittest.main()
