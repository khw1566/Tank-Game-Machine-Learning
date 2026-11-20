"""V6 1v1 openings with cover between the spawns and two paths out."""
from __future__ import annotations

import math

from .final_curriculum import build_map

VERSION = 2
DISTANCE = (120, 160)
FLANK_X = 54.0
FLANK_Z = 43.0


def _in_opening(x, z, half_x=0.0, half_z=0.0):
    return abs(x) <= 70 + half_x and abs(z) <= 105 + half_z


def _crowds_opening(obstacle):
    """Keep the spawn lanes clear while retaining the rest of each map."""
    x, z = obstacle["p"]
    if "b" in obstacle:
        bx, bz = obstacle["b"]
        return _in_opening((x + bx) / 2, (z + bz) / 2, abs(x - bx) / 2 + 2, abs(z - bz) / 2 + 2)
    if "size" in obstacle:
        w, _, d = obstacle["size"]
        yaw = obstacle.get("yaw", 0)
        c, s = abs(math.cos(yaw)), abs(math.sin(yaw))
        return _in_opening(x, z, (w * c + d * s) / 2 + 3, (w * s + d * c) / 2 + 3)
    radius = obstacle.get("r", 0) + 6
    return _in_opening(x, z, radius, radius)


def build_duel_map(map_id):
    config, original = build_map(map_id)
    obstacles = [o for o in original if not _crowds_opening(o)]
    config["mounds"] = [m for m in config["mounds"] if not _in_opening(m[0], m[1], 20, 20)]
    config["custom_ridges"] = [r for r in config["custom_ridges"] if not _in_opening(*r["c"])]
    if map_id == "rolling_woods":
        config["mounds"].append([0, 0, 10, 13])
    elif map_id == "ridgeline":
        # The two shallow saddles interrupt the crest on either side of the centre.
        config["custom_ridges"].append({"c": [0, 0], "yaw": 0, "len": 12, "h": 14,
                                         "sigma": 13, "gaps": [[-33, 0.85], [33, 0.85]]})
    elif map_id == "village":
        obstacles.append({"type": "house", "p": [0, 0], "size": [34, 8, 18], "yaw": 0})
    elif map_id == "valley":
        config["mounds"].extend([[0, -9, 6.5, 13], [0, 9, 6.5, 13]])
    elif map_id == "boulder_field":
        config["mounds"].append([-48, 39, 2.5, 22])
        obstacles.append({"type": "stone", "p": [0, 0], "size": [33, 7, 18], "yaw": 0.16})
    return config, obstacles


def duel_spawns(rng):
    """Swap ends, vary the distance and offset, and provide two usable exits per end."""
    direction = rng.choice((-1, 1))
    distance = rng.uniform(*DISTANCE)
    tiger_depth = distance / 2 + rng.uniform(-3, 3)
    allied_depth = distance - tiger_depth
    tiger = [round(rng.uniform(-7, 7), 2), round(-direction * tiger_depth, 2)]
    allied = [round(rng.uniform(-7, 7), 2), round(direction * allied_depth, 2)]
    theta = 0.0 if direction == 1 else math.pi
    return tiger, [allied], theta, math.dist(tiger, allied)
