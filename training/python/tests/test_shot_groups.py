import json
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tankrl import shot_groups
from tankrl.auto_report import AutoReport


def episode(step, stage="v6_1v1"):
    """학습 전차(셔먼, 팀 1)와 아군 T-34 가 티거(팀 0)와 싸운 짧은 에피소드."""
    return {
        "config": {"meta": {"global_step": step, "learner_tank": "sherman75", "variant": "valley",
                            "roles": {"sherman75_0": "learner", "t34_76_1": "rule", "tiger1_2": "opponent"}}},
        "result": {"stage": stage, "uid": f"run_{step}"},
        "tanks": [{"name": "sherman75_0", "tank": "sherman75", "team": 1},
                  {"name": "t34_76_1", "tank": "t34_76", "team": 1},
                  {"name": "tiger1_2", "tank": "tiger1", "team": 0}],
        # t, (x, z, yaw도, status) × 3: 티거는 원점에서 정면(−Z)을 보고, 셔먼은 그 앞 200m, T-34 는 셔먼 옆 150m
        "paths_1hz": [[t, 0, -200, 0, 0, 150, -200, 0, 0, 0, 0, 0, 0] for t in range(10)],
        "shots": [
            {"shooter": "sherman75_0", "t": 1.0, "hit": True, "target": "tiger1_2", "zone": "mantlet",
             "entry_local": [0.1, 2.5, -1.6], "distance_m": 200.0, "penetrated": False, "ricochet": True},
            {"shooter": "sherman75_0", "t": 2.0, "hit": True, "target": "tiger1_2", "zone": "hull_front_upper",
             "entry_local": [-0.3, 1.5, -3.1], "distance_m": 201.0, "penetrated": True},
            {"shooter": "sherman75_0", "t": 3.0, "hit": False, "target": "",
             "near_miss": {"target_name": "tiger1_2", "target_team": 0, "local_point": [2.0, 3.0, -1.0],
                           "range_m": 199.0, "miss_distance_m": 2.5}},
            {"shooter": "sherman75_0", "t": 4.0, "hit": False, "target": "", "blocked_by": "Terrain"},
            {"shooter": "sherman75_0", "t": 5.0, "hit": True, "target": "t34_76_1", "zone": "hull_side_upper",
             "entry_local": [1.4, 1.2, 0.0], "distance_m": 250.0, "penetrated": True},
            {"shooter": "tiger1_2", "t": 6.0, "hit": True, "target": "sherman75_0", "zone": "hull_front_upper",
             "entry_local": [0.0, 1.4, -2.9], "distance_m": 200.0, "penetrated": True},
        ],
    }


class ShotGroupTests(unittest.TestCase):
    def test_rows_classify_outcome_friendly_range_and_aspect(self):
        rows = shot_groups.episode_rows(episode(1000))
        self.assertEqual([r["outcome"] for r in rows],
                         ["ricochet", "penetration", "near", "blocked", "penetration", "penetration"])
        self.assertEqual(rows[2]["target"], "tiger1_2")
        self.assertEqual(rows[4]["friendly"], 1)
        self.assertEqual(rows[0]["friendly"], 0)
        self.assertEqual(rows[3]["range_source"], "nearest_enemy_1hz")
        self.assertAlmostEqual(float(rows[3]["range_m"]), 200.0, places=1)
        self.assertAlmostEqual(float(rows[0]["aspect_deg"]), 0.0, places=1)      # 티거 정면에서 쏨
        self.assertAlmostEqual(float(rows[4]["aspect_deg"]), 90.0, places=1)     # 셔먼이 T-34 옆에서
        self.assertEqual(rows[5]["target_role"], "learner")

    def test_build_is_incremental_and_writes_report(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp) / "run"
            env = run / "episodes" / "env0"
            env.mkdir(parents=True)
            for i, step in enumerate((1000, 5000, 9000)):
                stage = "v6_1v1" if i < 2 else "v6_1v2"
                (env / f"run_sherman75_{step:07d}_{stage}.json").write_text(json.dumps(episode(step, stage)), encoding="utf-8")
            (env / "run_sherman75_0009999_partial.json").write_text("{", encoding="utf-8")   # 쓰는 중인 파일
            out = shot_groups.build(run, log=None)
            self.assertTrue(out.exists())
            page = out.read_text(encoding="utf-8")
            self.assertIn("표적: 티거 I", page)
            self.assertIn('data-scope="v6_1v2"', page)
            summ = json.loads((run / "analysis/shot_groups/summary.json").read_text(encoding="utf-8"))
            self.assertEqual(summ["scopes"]["all"]["learner_shots"], 15)
            self.assertEqual(summ["scopes"]["all"]["friendly"]["penetration"], 3)
            self.assertEqual(summ["scopes"]["v6_1v1"]["episodes"], 2)
            rows = (run / "analysis/shot_groups/rows.csv").read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(rows), 1 + 18)
            shot_groups.build(run, log=None)
            self.assertEqual(len((run / "analysis/shot_groups/rows.csv").read_text(encoding="utf-8").splitlines()), 19)
            self.assertIn("탄착군(사격 분포)", shot_groups.training_report_section(run))

    def test_auto_report_throttles_and_queues(self):
        with tempfile.TemporaryDirectory() as tmp:
            auto = AutoReport(Path(tmp), 600)
            started = []
            auto.running = lambda: False
            import tankrl.auto_report as mod
            real = mod.subprocess.Popen
            mod.subprocess.Popen = lambda *a, **k: started.append(a) or object()
            try:
                self.assertTrue(auto.request("checkpoint"))
                self.assertFalse(auto.request("checkpoint"))          # 10분 안: 건너뜀
                self.assertTrue(auto.request("stage", force=True))   # 단계 변경: 항상
                auto.running = lambda: True
                self.assertFalse(auto.request("checkpoint"))
                self.assertTrue(auto.pending)
                auto.running = lambda: False
                self.assertTrue(auto.request("checkpoint"))          # 대기분은 간격 무시
            finally:
                mod.subprocess.Popen = real
            self.assertEqual(len(started), 3)
            self.assertFalse(AutoReport(Path(tmp), 0).request("checkpoint", force=True))


if __name__ == "__main__":
    unittest.main()
