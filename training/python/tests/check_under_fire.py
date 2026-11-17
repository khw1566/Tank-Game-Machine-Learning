"""Generate seeded cover layouts; verify firing cues, physical flight and replay through the real protocol."""
import argparse
import json
from pathlib import Path
import random
import subprocess
import sys

import numpy as np

from tankrl import curriculum_v4, scenarios
from tankrl.godot_env import GodotProcess


def configuration(tank, variant, seed, stage_id="m3_under_fire"):
    cur = curriculum_v4.CurriculumV4(tank, start_stage=curriculum_v4.STAGE_IDS.index(stage_id), review_prob=0)
    st, _, extra = cur.build_episode(tank, random.Random(seed), seed)
    spec = st["variant_specs"][variant]
    sc = scenarios.build(spec["builder"], spec["variant"], tank, seed)
    sc["variant"] = variant
    sc["observation_version"] = 3
    extra["scenario"] = sc
    extra["learning_objective"]["id"] = f"{stage_id}:{variant}"
    extra["learning_objective"]["label"] = f"{st['label']} · {variant}"
    team = scenarios.TEAM_OF[tank]
    lineup = [{"type": tank, "team": team, "ctrl": "external"}]
    lineup += [{"type": scenarios.ENEMIES_OF[tank][0], "team": 1 - team, "ctrl": "scripted"} for _ in sc["enemies"]]
    return curriculum_v4.make_config(st, extra, tank, lineup, seed, f"evade_{tank}_{variant}_{seed}", False, {})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot")
    parser.add_argument("--project")
    parser.add_argument("--out", required=True)
    parser.add_argument("--fixtures-only", action="store_true")
    parser.add_argument("--stage", default="m3_under_fire", help="m3_under_fire 또는 m3a_find_cover")
    args = parser.parse_args()
    out = Path(args.out).resolve()
    out.mkdir(parents=True, exist_ok=True)
    stage = curriculum_v4.STAGES[curriculum_v4.STAGE_IDS.index(args.stage)]
    fixtures = [configuration(tank, variant, seed, args.stage) for tank in curriculum_v4.SHARED_TANKS
                for variant in stage["variants"] for seed in (17, 42, 93)]
    (out / "fixtures.json").write_text(json.dumps(fixtures, ensure_ascii=False, indent=2), encoding="utf-8")
    if args.fixtures_only:
        print(out / "fixtures.json")
        return
    assert args.godot
    proc = GodotProcess(args.godot, args.project, 0, str(out), extra=["--obs=situation_v3"], quiet=False)
    rows = []
    try:
        assert proc.obs_size == 437 and proc.hello["projectile_version"] >= 1
        labels = proc.hello["obs_labels"]
        shot_index = labels.index("fire.heard_recent")
        tracer_index = labels.index("fire.tracer_present")
        for original in fixtures[1::3]:  # 12 real episodes: every variant and every tank.
            cfg = dict(original, time_limit_s=12)
            proc.send({"type": "reset", "config": cfg})
            header, obs = proc.recv_obs()
            heard, tracer = False, False
            for _ in range(140):
                action = np.zeros((1, 11), np.float32)
                action[0, 2] = 1
                action[0, 5:8] = -1
                proc.send({"type": "step"}, action.tobytes())
                header, obs = proc.recv_obs()
                assert np.isfinite(obs).all()
                heard |= bool(obs[0, shot_index] > 0)
                tracer |= bool(obs[0, tracer_index] > 0)
                if header["done"]:
                    break
            assert header["done"], cfg["uid"]
            result = header["episode"]
            summary = result["scenario"]
            assert heard and summary["enemy_shots"] > 0 and summary["fire_cue_received"], (cfg["uid"], summary)
            assert not result["success"], "Standing exposed must never pass an evasion lesson"
            command = [sys.executable, "reproduce.py", result["episode_file"], "--godot", args.godot,
                       "--out-dir", str(out / cfg["uid"]), "--log-obs", "1"]
            if args.project:
                command += ["--project", args.project]
            replay = subprocess.run(command, capture_output=True, encoding="utf-8", errors="replace", timeout=90)
            if replay.returncode:
                raise AssertionError(replay.stdout + replay.stderr)
            manifest = sorted((out / cfg["uid"] / "replays").glob("ep*/reproduce.json"))[-1]
            assert json.loads(manifest.read_text(encoding="utf-8"))["ok"]
            frames = []
            with (manifest.parent / "events.jsonl").open(encoding="utf-8") as file:
                for line in file:
                    event = json.loads(line)
                    if event.get("type") == "header":
                        assert len(event["observation_labels"]) == 437 and event["score_source"] == "training"
                    elif event.get("type") == "frame" and event.get("projectiles"):
                        frames.append(event)
            assert frames, "Flight positions must also be available in replay frames"
            row = dict(tank=cfg["tanks"][0]["type"], variant=cfg["scenario"]["variant"],
                       heard=heard, visible_tracer=tracer, enemy_shots=summary["enemy_shots"],
                       projectiles=summary["projectiles"], reason=result["reason"], replay="OK")
            rows.append(row)
            print(json.dumps(row), flush=True)
    finally:
        proc.close()
    (out / "results.json").write_text(json.dumps(rows, indent=2), encoding="utf-8")
    print(f"Under-fire protocol/replay: {len(rows)}/12 passed", flush=True)


if __name__ == "__main__":
    main()
