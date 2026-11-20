"""Frozen V6-1 evaluation: same seeds/maps/lineups and opponent checkpoint every time.

No optimizer updates and no writes to the source run. Outputs episode records and JSON.
Use the same --opponent, --seed, --seeds-per-map and game EXE for checkpoint comparisons.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from types import SimpleNamespace

from gymnasium import spaces
import numpy as np
import torch
from stable_baselines3 import PPO

from tankrl import curriculum_v4, v6_curriculum as v6
from tankrl.godot_env import GodotProcess
from tankrl.input_migration import V6_COVER_INPUT_SIZE, migrate_for_env
from tankrl.opponents import OpponentPool
from tankrl.storage import sha256


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--godot", required=True)
    ap.add_argument("--model", required=True)
    ap.add_argument("--tank", choices=v6.TANKS, default="tiger1")
    ap.add_argument("--opponent", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=20261120)
    ap.add_argument("--seeds-per-map", type=int, default=1)
    ap.add_argument("--sample-actions", action="store_true", help="Sample policies as in training with a repeatable per-game RNG seed")
    ap.add_argument("--legacy-open-start", action="store_true", help="Reuse the old randomized V6-1 spawns for historical comparisons")
    args = ap.parse_args()
    torch.set_num_threads(1)
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=False)
    model = PPO.load(args.model, device="cpu")
    opponent = PPO.load(args.opponent, device="cpu")
    manifest = dict(model=str(Path(args.model).resolve()), model_sha256=sha256(Path(args.model)),
                    opponent=str(Path(args.opponent).resolve()), opponent_sha256=sha256(Path(args.opponent)),
                    game_sha256=sha256(Path(args.godot)), seed=args.seed,
                    seeds_per_map=args.seeds_per_map, deterministic=not args.sample_actions, num_timesteps=model.num_timesteps,
                    tank=args.tank, map_version=1 if args.legacy_open_start else 2)
    games = []
    uses_cover = any(m.observation_space.shape == (V6_COVER_INPUT_SIZE,) for m in (model, opponent))
    obs_mode = "battle_v6_cover" if uses_cover else "battle"
    proc = GodotProcess(args.godot, None, 0, str(out), extra=[f"--obs={obs_mode}"])
    try:
        env_spec = SimpleNamespace(observation_space=spaces.Box(-np.inf, np.inf, shape=(proc.obs_size,), dtype=np.float32),
                                   obs_labels=proc.hello["obs_labels"])
        with TemporaryDirectory(prefix="v6-eval-inputs-") as cache:
            if model.observation_space.shape != env_spec.observation_space.shape:
                model = PPO.load(migrate_for_env(Path(args.model), env_spec, Path(cache)), device="cpu")
            if opponent.observation_space.shape != env_spec.observation_space.shape:
                opponent = PPO.load(migrate_for_env(Path(args.opponent), env_spec, Path(cache)), device="cpu")
        if proc.hello.get("v6_tactics_version", 0) < 1:
            raise RuntimeError("The evaluation needs the V6 tactics EXE")
        if uses_cover and proc.hello.get("target_occlusion_version", 0) < 1:
            raise RuntimeError("The evaluation needs the V6 target-occlusion EXE")
        for mi, variant in enumerate(v6.MAP_IDS):
            for j in range(args.seeds_per_map):
                seed = args.seed + 100 * mi + j
                for scripted in (True, False):
                    stage = v6.STAGES[0]
                    lu, sc, mc, _ = v6.arena(stage, variant, args.tank, seed, legacy_open_start=args.legacy_open_start)
                    lu[1].update(ctrl="scripted" if scripted else "external", role="rule" if scripted else "opponent")
                    sc["v6"]["rule_ai"] = int(scripted)
                    sc["v6"]["opponent_kind"] = "scripted" if scripted else "frozen"
                    sc["enemies"][0]["ai"] = (dict(v6.RULE_FLANK, flank_offset=200.0) if args.legacy_open_start
                                                   else dict(v6.RULE_FLANK, engage_range=75.0, flank_offset=290.0))
                    uid = f"fixed_{variant}_{seed}_{'rule' if scripted else 'model'}"
                    rewards = v6.reward_config(stage)
                    if uses_cover:
                        sc["target_occlusion_version"] = v6.TARGET_OCCLUSION_VERSION
                    else:
                        rewards.update(near_miss_visible_pass_only=False, v6_reward_version=2)
                    extra = dict(reward=rewards, kind="combat", time_limit_s=stage["time_limit_s"],
                                 scenario=sc, learning_objective=dict(id="v6_fixed", label="V6 fixed evaluation",
                                                                      version=rewards["v6_reward_version"]))
                    cfg = curriculum_v4.make_config(dict(stage, map=mc), extra, args.tank, lu, seed, uid, False,
                                                     dict(evaluation=True, variant=variant))
                    cfg["map"]["seed"] = mc["seed"]
                    cfg.update(curriculum_version=v6.VERSION, balance_version=v6.BALANCE_VERSION)
                    proc.send(dict(type="reset", config=cfg))
                    h, obs = proc.recv_obs()
                    if args.sample_actions:
                        torch.manual_seed(seed * 2 + int(scripted))
                    episode_return = 0.0
                    while not h["done"]:
                        actions = [model.predict(OpponentPool.compatible_observation(obs[0], model), deterministic=not args.sample_actions)[0]]
                        if not scripted:
                            actions.append(opponent.predict(OpponentPool.compatible_observation(obs[1], opponent), deterministic=not args.sample_actions)[0])
                        proc.send(dict(type="step"), np.asarray(actions, dtype="<f4").tobytes())
                        h, obs = proc.recv_obs()
                        episode_return += h["agents"][0]["reward"]
                    ep = h["episode"]
                    path = Path(ep["episode_file"])
                    record = json.loads(path.read_text(encoding="utf-8"))
                    me = record["tanks"][0]["name"]
                    shots = Counter("hit" if s["hit"] else s.get("blocked_by", "none")
                                    for s in record["shots"] if s["shooter"] == me)
                    game = dict(uid=uid, variant=variant, opponent="rule" if scripted else "model", seed=seed,
                                success=bool(ep["success"]), reason=ep["reason"], duration_s=ep["duration_s"],
                                episode_return=episode_return, path_m=ep.get("scenario", {}).get("path_m", 0), shots=dict(shots),
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
    summary["by_opponent"] = {}
    for kind in ("rule", "model"):
        group = [g for g in games if g["opponent"] == kind]
        if group:
            summary["by_opponent"][kind] = dict(games=len(group), wins=sum(g["success"] for g in group),
                timeouts=sum(g["reason"] == "time_limit" for g in group),
                mean_return=sum(g["episode_return"] for g in group) / len(group))
    (out / "evaluation.json").write_text(json.dumps(dict(manifest=manifest, summary=summary, games=games), indent=2), encoding="utf-8")
    print(json.dumps(summary), flush=True)


if __name__ == "__main__":
    main()
