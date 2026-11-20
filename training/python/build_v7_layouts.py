"""Bake the existing V6 curriculum's Godot geometry for offline V7 play."""
from pathlib import Path
import hashlib
import json
import random

from tankrl import v6_curriculum as v6


OUTPUT = Path(__file__).resolve().parents[1] / "v7_training_layouts.json"
SAMPLES_PER_MAP = 16


def reference_layout(stage, tank, map_id, seed):
    """Project the existing training configuration onto spatial fields."""
    lookup = next(stage_info for stage_info in v6.STAGES if stage_info["id"] == stage)
    tanks, scenario, terrain, _ = v6.arena(lookup, map_id, tank, seed)
    poses = [scenario["learner"], *scenario["enemies"]]
    return ({"map": {k: v for k, v in terrain.items() if k != "seeds"},
             "obstacles": scenario["obstacles"]},
            [{"type": t["type"], "team": t["team"], "p": p["p"], "yaw": p["yaw"]}
             for t, p in zip(tanks, poses, strict=True)])


def build_catalog():
    maps, layouts = {}, {}
    # Older V6 branches can regenerate the team layouts while retaining the newer
    # 1v1 maps and spawns already stored in the catalog.
    recorded = (json.loads(OUTPUT.read_text(encoding="utf-8"))
                if OUTPUT.is_file() and not hasattr(v6, "v6_duel_maps") else None)
    rng = random.Random(736061)
    for stage in v6.STAGE_IDS:
        layouts[stage] = {}
        for tank in v6.TANKS:
            layouts[stage][tank] = entries = []
            for sample in range(SAMPLES_PER_MAP):
                seed = rng.randrange(1, 2**31 - 1)
                if recorded is not None and stage == "v6_1v1":
                    width = len(v6.MAP_IDS)
                    rows = recorded["layouts"][stage][tank][sample * width:(sample + 1) * width]
                    if [row["map_id"] for row in rows] != list(v6.MAP_IDS) or any(row["source_seed"] != seed for row in rows):
                        raise ValueError("The recorded 1v1 layouts do not match the catalog seeds")
                    entries.extend(rows)
                    maps.update({row["map_key"]: recorded["maps"][row["map_key"]] for row in rows})
                    continue
                for map_id in v6.MAP_IDS:
                    geometry, poses = reference_layout(stage, tank, map_id, seed)
                    map_key = f"{stage}/{map_id}"
                    maps.setdefault(map_key, geometry)
                    row = {"map_id": map_id, "map_key": map_key, "source_stage": stage, "source_seed": seed,
                           "tanks": poses}
                    encoded = json.dumps([row, geometry], sort_keys=True, separators=(",", ":")).encode()
                    entries.append(row | {"layout_id": hashlib.sha256(encoded).hexdigest()})
    return {"format": "tankgame-v6-geometry-v1", "map_ids": list(v6.MAP_IDS), "maps": maps, "layouts": layouts}


if __name__ == "__main__":
    OUTPUT.write_text(json.dumps(build_catalog(), ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
