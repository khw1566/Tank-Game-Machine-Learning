"""Frozen V6-1 evaluation: same seeds/maps/lineups and opponent checkpoint every time.

No optimizer updates and no writes to the source run. Outputs episode records and JSON.
Use the same --opponent, --seed, --seeds-per-map and game EXE for checkpoint comparisons.
"""
import argparse
from collections import Counter
import json
from pathlib import Path

import numpy as np
import torch
from stable_baselines3 import PPO

from tankrl import curriculum_v4, v6_curriculum as v6
from tankrl.godot_env import GodotProcess
from tankrl.storage import sha256


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--opponent", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=20261120)
    ap.add_argument("--seeds-per-map", type=int, default=1)
    args = ap.parse_args()
    torch.set_num_threads(1)
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    model = PPO.load(args.model, device="cpu")
    opponent = PPO.load(args.opponent, device="cpu")
    manifest = dict(model=str(Path(args.model).resolve()), model_sha256=sha256(Path(args.model)),
                    opponent=str(Path(args.opponent).resolve()), opponent_sha256=sha256(Path(args.opponent)),
                    game_sha256=sha256(Path(args.godot)), seed=args.seed,
                    seeds_per_map=args.seeds_per_map, deterministic=True, num_timesteps=model.num_timesteps)
    games = []
    proc = GodotProcess(args.godot, None, 0, str(out), extra=["--obs=battle"])
    try:
        if proc.hello.get("v6_tactics_version", 0) < 1:
            raise RuntimeError("The evaluation needs the V6 tactics EXE")
        for mi, variant in enumerate(v6.MAP_IDS):
            for j in range(args.seeds_per_map):
                seed = args.seed + 100 * mi + j
                for scripted in (True, False):
                    stage = v6.STAGES[0]
                    lu, sc, mc, _ = v6.arena(stage, variant, "tiger1", seed)
                    lu[1].update(ctrl="scripted" if scripted else "external", role="rule" if scripted else "opponent")
                    sc["enemies"][0]["ai"] = dict(v6.RULE_FLANK, flank_offset=200.0)
                    uid = f"fixed_{variant}_{seed}_{'rule' if scripted else 'model'}"
                    extra = dict(reward=v6.reward_config(stage), kind="combat", time_limit_s=stage["time_limit_s"],
                                 scenario=sc, learning_objective=dict(id="v6_fixed", label="V6 fixed evaluation", version=2))
                    cfg = curriculum_v4.make_config(dict(stage, map=mc), extra, "tiger1", lu, seed, uid, False,
                                                     dict(evaluation=True, variant=variant))
                    cfg["map"]["seed"] = mc["seed"]
                    cfg.update(curriculum_version=v6.VERSION, balance_version=v6.BALANCE_VERSION)
                    proc.send(dict(type="reset", config=cfg))
                    h, obs = proc.recv_obs()
                    while not h["done"]:
                        actions = [model.predict(obs[0], deterministic=True)[0]]
                        if not scripted:
                            actions.append(opponent.predict(obs[1], deterministic=True)[0])
                        proc.send(dict(type="step"), np.asarray(actions, dtype="<f4").tobytes())
                        h, obs = proc.recv_obs()
                    ep = h["episode"]
                    path = Path(ep["episode_file"])
                    record = json.loads(path.read_text(encoding="utf-8"))
                    me = record["tanks"][0]["name"]
                    shots = Counter("hit" if s["hit"] else s.get("blocked_by", "none")
                                    for s in record["shots"] if s["shooter"] == me)
                    game = dict(uid=uid, variant=variant, opponent="rule" if scripted else "model", seed=seed,
                                success=bool(ep["success"]), reason=ep["reason"], duration_s=ep["duration_s"],
                                path_m=ep.get("scenario", {}).get("path_m", 0), shots=dict(shots),
                                final_hash=ep["final_hash"], episode_file=str(path))
                    games.append(game)
                    (out / "evaluation.json").write_text(json.dumps(dict(manifest=manifest, games=games), indent=2), encoding="utf-8")
                    print(uid, game["success"], game["reason"], flush=True)
    finally:
        proc.close()
    shots = Counter()
    for g in games:
        shots.update(g["shots"])
    total = sum(shots.values())
    summary = dict(games=len(games), wins=sum(g["success"] for g in games),
                   timeouts=sum(g["reason"] == "time_limit" for g in games), shots=dict(shots),
                   blocked_fraction=(total - shots["hit"] - shots["none"]) / max(1, total))
    (out / "evaluation.json").write_text(json.dumps(dict(manifest=manifest, summary=summary, games=games), indent=2), encoding="utf-8")
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
