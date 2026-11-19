"""TANKGAME_GODOT 와 TANKGAME_PROJECT 를 지정하면 실제 시뮬레이터를 검증한다."""
import copy
import os
import random
import tempfile
import unittest
from pathlib import Path

import numpy as np

from tankrl.battle_curriculum import BattleCurriculum, STAGES, TANKS
from tankrl.curriculum_v4 import make_config
from tankrl.godot_env import GodotProcess


@unittest.skipUnless(os.environ.get("TANKGAME_GODOT"), "Godot runtime required")
class BattleEnvTests(unittest.TestCase):
    def test_arenas_targeting_masks_and_multi_agent_rewards(self):
        with tempfile.TemporaryDirectory() as directory:
            p = GodotProcess(os.environ["TANKGAME_GODOT"], os.environ.get("TANKGAME_PROJECT"), 0,
                             directory, quiet=False, extra=["--obs=battle"])
            try:
                labels = p.hello["obs_labels"]
                aiming = [i for i, label in enumerate(labels) if label.startswith("aim")]
                visible = [i for i, label in enumerate(labels) if label.startswith("aim") and label.endswith(".visible")]
                self.assertEqual(len(aiming), 168)
                base_config = None
                for index, stage in enumerate(STAGES):
                    for tank in TANKS:
                        for variant in stage["variants"]:
                            c = BattleCurriculum(tank, start_stage=index, review_prob=0)
                            # 단일 변형을 고르는 시드 검색(단계 정의를 바꾸지 않는다).
                            for seed in range(100):
                                st, lu, extra = c.build_episode(tank, random.Random(seed), seed + 1)
                                if extra["scenario"]["variant"] == variant:
                                    break
                            cfg = make_config(st, extra, tank, lu, seed + 1, "test", False, {})
                            cfg.update(curriculum_version=5, learner_team=lu[0]["team"], time_limit_s=0.5)
                            p.send({"type": "reset", "config": cfg})
                            h, obs = p.recv_obs()
                            self.assertEqual(obs.shape, (len(lu), len(labels)))
                            self.assertTrue(np.isfinite(obs).all())
                            if index == 0 and tank == "sherman75" and variant == "close":
                                self.assertGreater(obs[0, visible].sum(), 0, "Visible tank has no aim points")
                                base_config = copy.deepcopy(cfg)
                            for _ in range(8):
                                actions = np.zeros((len(lu), p.act_size), dtype="<f4")
                                p.send({"type": "step"}, actions.tobytes())
                                h, obs = p.recv_obs()
                                if h["done"]:
                                    break
                            self.assertTrue(h["done"])
                            self.assertEqual(h["episode"]["reason"], "time_limit")
                            self.assertTrue(all(a["reward"] < 0 for a in h["agents"]))
                self.assertIsNotNone(base_config)
                cfg = base_config
                cfg["pace"]["identify_px"] = 100000
                p.send({"type": "reset", "config": cfg})
                _, obs = p.recv_obs()
                self.assertEqual(float(np.abs(obs[:, aiming]).sum()), 0, "Unidentified target leaked shape")
                cfg["pace"]["identify_px"] = 18
                sc = cfg["scenario"]
                a, b = sc["learner"]["p"], sc["enemies"][0]["p"]
                sc["obstacles"] = [{"type": "stone", "p": [(a[0]+b[0])/2, (a[1]+b[1])/2],
                                    "size": [35, 25, 35], "yaw": 0}]
                p.send({"type": "reset", "config": cfg})
                _, obs = p.recv_obs()
                self.assertEqual(float(np.abs(obs[:, aiming]).sum()), 0, "Occluded target leaked shape")
            finally:
                p.close()


if __name__ == "__main__":
    unittest.main()
