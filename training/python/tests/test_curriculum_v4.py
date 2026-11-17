import json
import math
import random

from tankrl import curriculum_v4, scenarios
from tankrl.curriculum_v4 import CurriculumV4


def test_scenarios_are_deterministic_and_complete():
    for st in curriculum_v4.STAGES:
        for v in st["variants"]:
            for tank in ("tiger1", "sherman75", "t34_76"):
                a = scenarios.build(st["builder"], v, tank, 42)
                b = scenarios.build(st["builder"], v, tank, 42)
                assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)
                assert a["variant"] == v and "learner" in a
                assert a["goal"] in ("reach", "survive", "destroy", "zone", "hits")
                if a["goal"] == "reach":
                    assert "objective" in a
                if st["kind"] != "drive":
                    assert a["enemies"]


def test_frame_matches_godot_rotation():
    f = scenarios.Frame(math.pi / 2)
    # Godot Basis(UP, 90°): local +x -> world -z, local +z -> world +x
    assert f.p(1, 0) == [0.0, -1.0]
    assert f.p(0, 1) == [1.0, 0.0]
    assert abs(scenarios.yaw_to([0, 0], [0, -10])) < 1e-6  # yaw 0 faces -Z


def test_promotion_requires_every_variant():
    c = CurriculumV4("tiger1", start_stage=0)
    st = c.stage
    window, need = st["promote"]["window"], st["promote"]["min_episodes"]
    ev = None
    for i in range(need + window):
        # "behind" never succeeds: a single habit must not pass
        v = st["variants"][i % len(st["variants"])]
        ev = c.report(st["id"], v != "behind", i, variant=v) or ev
    assert ev is None and c.stage_idx == 0
    for i in range(window):
        ev = c.report(st["id"], True, 10_000 + i, variant="behind") or ev
    assert ev and ev["to"] == curriculum_v4.STAGE_IDS[1] and set(ev["variant_rates"]) == set(st["variants"])
    assert c.stage_start_step > 0


def test_shaping_decays_and_entropy_restarts(tmp_path):
    c = CurriculumV4("tiger1", start_stage=1, entropy_boost=0.03, entropy_steps=100)
    sid = c.stage["id"]
    assert c.shaping_scale(sid) == 1.0
    c.episodes_in_stage = c.stage["shaping_decay_episodes"] // 2
    assert abs(c.shaping_scale(sid) - 0.5) < 1e-3
    assert c.shaping_scale(curriculum_v4.STAGE_IDS[0]) == 0.0  # review = outcome only
    assert abs(c.entropy_coef(0.005, 0) - 0.03) < 1e-9
    assert abs(c.entropy_coef(0.005, 100) - 0.005) < 1e-9
    c.save(tmp_path / "c.json")
    d = CurriculumV4.load(tmp_path / "c.json", "tiger1")
    assert d.stage_idx == 1 and d.episodes_in_stage == c.episodes_in_stage


def test_build_episode_config():
    c = CurriculumV4("t34_76", start_stage=curriculum_v4.STAGE_IDS.index("g4_return_fire"), review_prob=0)
    st, lu, extra = c.build_episode("t34_76", random.Random(3), 99)
    cfg = curriculum_v4.make_config(st, extra, "t34_76", lu, 99, "u", False, {})
    assert cfg["tanks"][0] == {"type": "t34_76", "team": 1, "ctrl": "external"}
    assert all(t["team"] == 0 and t["type"] == "tiger1" for t in cfg["tanks"][1:])
    assert len(cfg["tanks"]) == 1 + len(cfg["scenario"]["enemies"])
    assert cfg["learning_objective"]["id"].startswith("g4_return_fire:")


import tempfile
import unittest
from pathlib import Path


class CurriculumV4Test(unittest.TestCase):
    def test_all(self):
        test_scenarios_are_deterministic_and_complete()
        test_frame_matches_godot_rotation()
        test_promotion_requires_every_variant()
        test_shaping_decays_and_entropy_restarts(Path(tempfile.mkdtemp()))
        test_build_episode_config()


if __name__ == "__main__":
    unittest.main()
