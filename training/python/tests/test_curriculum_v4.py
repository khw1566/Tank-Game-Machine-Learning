import json
import math
import random

from tankrl import curriculum_v4, scenarios
from tankrl.curriculum_v4 import CurriculumV4


def test_scenarios_are_deterministic_and_complete():
    for st in curriculum_v4.STAGES:
        assert st["promote"]["threshold"] == 0.8 and st["promote"]["max_episodes"] is None
        assert st["lesson"] and st["learn"] and st["goal"]
        for v in st["variants"]:
            spec = st["variant_specs"][v]
            for tank in ("tiger1", "sherman75", "t34_76"):
                a = scenarios.build(spec["builder"], spec["variant"], tank, 42)
                b = scenarios.build(spec["builder"], spec["variant"], tank, 42)
                assert json.dumps(a, sort_keys=True) == json.dumps(b, sort_keys=True)
                assert a["variant"] == spec["variant"] and "learner" in a
                assert a["goal"] in ("reach", "survive", "destroy", "zone", "hits", "take_cover")
                if a["goal"] == "reach":
                    assert "objective" in a
                if spec["kind"] != "drive":
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
    assert ev and ev["to"] == curriculum_v4.STAGE_IDS[1] and set(ev["variant_rates"]) == {f"{v}@tiger1" for v in st["variants"]}
    assert c.stage_start_step > 0


def test_shaping_decays_and_entropy_restarts(tmp_path):
    c = CurriculumV4("tiger1", start_stage=1, entropy_boost=0.03, entropy_steps=100)
    sid = c.stage["id"]
    assert c.shaping_scale(sid) == 1.0
    c.episodes_in_stage = c.stage["shaping_decay_episodes"] * 2
    assert c.shaping_scale(sid) == 1.0                   # unsolved driving retains shaping
    c.episodes_in_stage = 0
    for v in c.stage["variants"]:
        for _ in range(c.pair_minimum(c.stage)):
            c.results[sid][c.key(v, "tiger1")].append(1)
    assert c.shaping_scale(sid) == 0.0                      # competence removes shaping
    assert c.shaping_scale(curriculum_v4.STAGE_IDS[0]) == 0.0  # review = outcome only
    assert abs(c.entropy_coef(0.005, 0) - 0.03) < 1e-9
    assert abs(c.entropy_coef(0.005, 100) - 0.005) < 1e-9
    c.save(tmp_path / "c.json")
    d = CurriculumV4.load(tmp_path / "c.json", "tiger1")
    assert d.stage_idx == 1 and d.episodes_in_stage == c.episodes_in_stage


def test_build_episode_config():
    c = CurriculumV4("t34_76", start_stage=curriculum_v4.STAGE_IDS.index("g2_posture"), review_prob=0)
    st, lu, extra = c.build_episode("t34_76", random.Random(3), 99)
    cfg = curriculum_v4.make_config(st, extra, "t34_76", lu, 99, "u", False, {})
    assert cfg["tanks"][0] == {"type": "t34_76", "team": 1, "ctrl": "external"}
    assert all(t["team"] == 0 and t["type"] == "tiger1" for t in cfg["tanks"][1:])
    assert len(cfg["tanks"]) == 1 + len(cfg["scenario"]["enemies"])
    assert cfg["learning_objective"]["id"].startswith("g2_posture:")


def test_shared_requires_every_tank_and_branches():
    c = CurriculumV4(curriculum_v4.SHARED, start_stage=curriculum_v4.LAST_COMMON, review_prob=0)
    st = c.stage
    rng = random.Random(0)
    seen = set()
    for i in range(60):
        s2, lu, extra = c.build_episode(curriculum_v4.SHARED, rng, i + 1)
        seen.add(extra["learner"])
        assert lu[0]["type"] == extra["learner"]
    assert seen == set(curriculum_v4.SHARED_TANKS)
    p = st["promote"]
    ev = None
    for i in range(p["min_episodes"] + p["window"]):
        for t in curriculum_v4.SHARED_TANKS:
            for v in st["variants"]:
                ev = c.report(st["id"], t != "sherman75", i, variant=v, learner=t) or ev
    assert ev is None and not c.common_complete           # one tank failing blocks the branch
    for i in range(p["window"]):
        for v in st["variants"]:
            ev = c.report(st["id"], True, 99_000 + i, variant=v, learner="sherman75") or ev
    assert ev and ev["to"] == "branch_tanks" and c.common_complete
    b = c.branch("t34_76", 123, "run/shared/step_000000123")
    assert b.stage["id"] == curriculum_v4.STAGE_IDS[curriculum_v4.FIRST_TANK] and b.stage["scope"] == "tank"
    assert list(b.results[st["id"]]["capture_inside@t34_76"])[-1] == 1 and b.history[-1]["reason"] == "branch"
    try:
        c.set_stage("s1_role", 0)
        raise AssertionError("shared model must not enter tank stages")
    except ValueError:
        pass


def test_mastered_pairs_are_skipped_and_stay_passed(tmp_path):
    c = CurriculumV4("shared", start_stage=1, review_prob=0)
    sid = c.stage["id"]
    for key in c.results[sid]:
        if key != "wall@t34_76":
            c.results[sid][key].extend([1] * c.pair_minimum(c.stage))
    rng = random.Random(1)
    for seed in range(50):
        _, _, extra = c.build_episode("shared", rng, seed)
        assert extra["scenario"]["variant"] == "wall" and extra["learner"] == "t34_76"
        assert extra["scenario"]["driving"]["min_forward_fraction"] == 0.85
    # In-flight episodes finishing after the pass cannot reopen that pair.
    c.report(sid, False, 1, variant="clear", learner="tiger1")
    assert c.variant_rates(sid, 40)["clear@tiger1"] == 1.0
    c.save(tmp_path / "passed.json")
    d = CurriculumV4.load(tmp_path / "passed.json", "shared", review_prob=0)
    assert d.pending_pairs(d.stage) == [("wall", "t34_76")]
    d.episodes_in_stage = 1_000_000
    assert d.shaping_scale(sid) > 0.0


def test_legacy_assessment_keeps_weights_compatible_and_preserves_results(tmp_path):
    c = CurriculumV4("shared", start_stage=2)
    state = c.state()
    state.pop("assessment_version")
    state["results"]["m1_drive"]["behind@tiger1"] = [1] * 40
    path = tmp_path / "legacy.json"
    path.write_text(json.dumps(state), encoding="utf-8")
    d = CurriculumV4.load(path, "shared")
    assert d.stage["id"] == "m1_drive" and not any(d.results["m1_drive"].values())
    assert d.previous_assessments[-1]["results"]["m1_drive"]["behind@tiger1"] == [1] * 40
    d.save(path)
    assert CurriculumV4.load(path, "shared").previous_assessments == d.previous_assessments


def test_under_fire_requires_distant_off_axis_cover_and_preserves_driving(tmp_path):
    for tank in curriculum_v4.SHARED_TANKS:
        for variant in curriculum_v4.STAGES[2]["variants"]:
            for seed in range(20):
                sc = scenarios.build("evade_to_cover", variant, tank, seed)
                assert sc["goal"] == "take_cover" and "objective" not in sc
                assert sc["projectile_version"] == 1 and sc["evade"]["hold_s"] == 4
                cover = sc["obstacles"][0]
                spawn = sc["learner"]["p"]
                assert math.dist(spawn, cover["p"]) > 50
                yaw = sc["learner"]["yaw"]
                to_cover = [cover["p"][i] - spawn[i] for i in range(2)]
                lateral = abs(to_cover[0] * math.cos(yaw) - to_cover[1] * math.sin(yaw))
                assert lateral > 30  # Never straight in front.
    c = CurriculumV4("shared", start_stage=0)
    state = c.state()
    state["assessment_version"] = 2
    state["results"]["m1_drive"]["near@tiger1"] = [1] * 40
    state["mastered"]["m1_drive"] = ["near@tiger1"]
    state["results"]["m3_under_fire"]["screened@tiger1"] = [1] * 40
    path = tmp_path / "v2.json"
    path.write_text(json.dumps(state), encoding="utf-8")
    d = CurriculumV4.load(path, "shared")
    assert d.stage_idx == 0 and "near@tiger1" in d.mastered["m1_drive"]
    assert list(d.results["m1_drive"]["near@tiger1"]) == [1] * 40
    assert not any(d.results["m3_under_fire"].values())


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
        test_shared_requires_every_tank_and_branches()
        test_mastered_pairs_are_skipped_and_stay_passed(Path(tempfile.mkdtemp()))
        test_legacy_assessment_keeps_weights_compatible_and_preserves_results(Path(tempfile.mkdtemp()))
        test_under_fire_requires_distant_off_axis_cover_and_preserves_driving(Path(tempfile.mkdtemp()))


if __name__ == "__main__":
    unittest.main()
