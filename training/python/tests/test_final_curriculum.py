import random
import tempfile
import unittest
from pathlib import Path

from tankrl import final_curriculum as fc


class FinalCurriculumTest(unittest.TestCase):
    def test_five_fixed_maps(self):
        self.assertEqual(len(fc.MAP_IDS), 5)
        for map_id in fc.MAP_IDS:
            a, b = fc.build_map(map_id), fc.build_map(map_id)
            self.assertEqual(a, b, "같은 맵은 항상 같은 배치")
            mc, obstacles = a
            self.assertTrue(mc["mounds"] or mc["custom_ridges"] or mc["amplitude"] > 0, "굴곡이 있어야 한다")
            self.assertGreater(len(obstacles), 20)

    def test_lineup_and_random_spawn(self):
        for tank in fc.TANKS:
            c = fc.FinalCurriculum(tank)
            seen = set()
            for seed in range(30):
                _, lu, extra = c.build_episode(tank, random.Random(seed), 1000 + seed)
                types = [d["type"] for d in lu]
                self.assertEqual(types[0], tank)
                self.assertEqual(sorted(types), sorted(["tiger1"] + fc.ALLIED_LINEUP))
                self.assertEqual(lu[0]["role"], "learner")
                sc = extra["scenario"]
                self.assertEqual(len(sc["enemies"]), 6)
                self.assertEqual(extra["map_seed"], fc.build_map(sc["variant"])[0]["seed"])
                seen.add(tuple(sc["learner"]["p"]))
                for p in [sc["learner"]["p"]] + [e["p"] for e in sc["enemies"]]:
                    self.assertLessEqual(max(abs(p[0]), abs(p[1])), fc.PLAY)
            self.assertGreater(len(seen), 25, "스폰 위치가 매 판 달라야 한다")

    def test_reward_has_cover_terms(self):
        r = fc.reward_config()
        self.assertLess(r["cover"]["seen_hull_per_s"], 0)
        self.assertGreater(r["cover"]["overwatch_per_s"], 0)
        self.assertLess(abs(r["cover"]["exposure_budget"]) + r["cover"]["overwatch_budget"], r["win"] / 4)

    def test_attack_rewards_favor_hits_and_bound_auxiliary_rewards(self):
        r = fc.reward_config()
        self.assertEqual(r["attack_shaping_version"], 1)
        self.assertLess(r["near_miss_bonus"], r["combat"]["hit"])
        self.assertEqual(r["combat"]["friendly_fire"], -3.0)
        self.assertEqual(r["combat"]["friendly_knockout"], -60.0)
        auxiliary = sum(r[k] for k in ("near_miss_budget", "near_pen_budget", "aim_alignment_budget",
                                        "aim_overlap_budget", "aimed_fire_budget", "closing_budget"))
        auxiliary += sum(r["close_bonuses"]) + r["cover"]["overwatch_budget"]
        self.assertLess(auxiliary, r["win"] / 4)
        self.assertLess(r["close_after_stall_s"], 30)

    def test_state_roundtrip(self):
        c = fc.FinalCurriculum("t34_76")
        c.initialize_from("V5run 1/shared/step_001609086", 1609086)
        c.report_battle("final_1v6", True, 10, "valley", "t34_76", {"hits": 1, "pens": 1},
                        {"winner": 1, "duration_s": 100, "scenario": {"status": "operational",
                                                                      "cover": {"overwatch_s": 20, "multi_seen_s": 5}}})
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "c.json"
            c.save(path)
            back = fc.FinalCurriculum.load(path, "t34_76")
        m = back.combat_metrics()["valley@t34_76"]
        self.assertEqual(m["episodes"], 1)
        self.assertAlmostEqual(m["overwatch"], 0.2)
        self.assertEqual(back.initialized_from, "V5run 1/shared/step_001609086")
        with self.assertRaises(ValueError):
            fc.FinalCurriculum("shared")


if __name__ == "__main__":
    unittest.main()
