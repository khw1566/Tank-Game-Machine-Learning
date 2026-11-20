"""Generate actual V6 1v1 episodes and check them using Godot collision and LOS."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile

from tankrl import curriculum_v4, v6_curriculum as v6, v6_duel_maps


def config(variant, learner, seed, legacy):
    stage = v6.STAGES[0]
    lineup, sc, mc, _ = v6.arena(stage, variant, learner, seed, legacy_open_start=legacy)
    extra = dict(reward=v6.reward_config(stage), kind="combat", time_limit_s=stage["time_limit_s"], scenario=sc,
                 learning_objective=dict(id=stage["id"], label=stage["label"], version=1))
    cfg = curriculum_v4.make_config(dict(stage, map=mc), extra, learner, lineup, seed,
                                    f"test_{variant}_{seed}", False, {})
    cfg["map"]["seed"] = mc["seed"]
    cfg.update(curriculum_version=v6.VERSION, balance_version=v6.BALANCE_VERSION, save_episode=False)
    return cfg


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", required=True, type=Path)
    parser.add_argument("--seeds-per-map", type=int, default=24)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[3]
    cases = [config(variant, v6.TANKS[i % len(v6.TANKS)], 20261120 + i, legacy)
             for variant in v6.MAP_IDS for legacy in (True, False) for i in range(args.seeds_per_map)]
    with tempfile.TemporaryDirectory(prefix="v6-duel-maps-") as folder:
        fixture = Path(folder) / "cases.json"
        fixture.write_text(json.dumps(dict(cases=cases, flank_x=v6_duel_maps.FLANK_X, flank_z=v6_duel_maps.FLANK_Z)),
                           encoding="utf-8")
        subprocess.run([str(args.godot.resolve()), "--headless", "--path", str(root),
                        "-s", "res://training/tests/run_v6_duel_maps_tests.gd", "--", str(fixture)], check=True)


if __name__ == "__main__":
    main()
