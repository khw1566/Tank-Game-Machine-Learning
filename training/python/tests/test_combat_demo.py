"""실제 전투 시범 파일 형식, V6 배치 변환(ctrl human), 행동 복제가 정책을 시범 쪽으로 옮기는지."""
import random
import sys
from pathlib import Path

import gymnasium as gym
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from play_combat_demo import Opponents, build_episode, parse_args  # noqa: E402
from tankrl.combat_demo import clone, list_demos, read_demo, save_demo  # noqa: E402


def test_episode_has_one_human_and_no_unmodelled_externals():
    args = parse_args(["--tank", "sherman75", "--stage", "v6_1v6"])
    cfg, lu, ext, names = build_episode(args, random.Random(3), Opponents(None), {})
    ctrls = [t["ctrl"] for t in cfg["tanks"]]
    assert ctrls[0] == "human" and ctrls.count("human") == 1
    assert cfg["tanks"][0]["type"] == "sherman75" and cfg["learner_team"] == 1
    assert "external" not in ctrls and ext == []          # 모델이 없으면 규칙 AI
    assert names[0] == "sherman75_0"


def test_map_choice_and_time_limit():
    args = parse_args(["--tank", "t34_76", "--stage", "v6_1v2", "--map", "village", "--time-limit", "30"])
    cfg, *_ = build_episode(args, random.Random(1), Opponents(None), {})
    assert cfg["scenario"]["variant"] == "village" and cfg["time_limit_s"] == 30


def _demo(tmp_path, n, seed):
    rng = np.random.default_rng(seed)
    obs = rng.normal(size=(n, 12)).astype(np.float32)
    act = np.zeros((n, 11), np.float32)
    act[:, 0] = act[:, 1] = np.round(np.tanh(obs[:, 0]) * 127) / 127     # 관측 0 → 궤도
    act[:, 2] = -0.5
    act[:, 5] = np.where(obs[:, 1] > 0, 0.5, -0.5)                       # 관측 1 → 발사
    meta = {"tank": "sherman75", "stage": "v6_1v2", "obs_labels": [f"o{i}" for i in range(12)]}
    return save_demo(tmp_path / "sherman75" / f"d{seed}.npz", obs, act, meta)


def test_clone_moves_policy_towards_demonstrations(tmp_path):
    from stable_baselines3 import PPO
    try:
        from tankrl.v6_control_policy import V6ControlPolicy
    except ImportError:
        V6ControlPolicy = "MlpPolicy"

    class Env(gym.Env):
        observation_space = gym.spaces.Box(-np.inf, np.inf, (12,), np.float32)
        action_space = gym.spaces.Box(-1, 1, (11,), np.float32)

        def reset(self, seed=None, options=None):
            return np.zeros(12, np.float32), {}

        def step(self, a):
            return np.zeros(12, np.float32), 0.0, True, False, {}

    for s in range(4):
        _demo(tmp_path, 300, s)
    paths = list_demos("sherman75", tmp_path)
    assert len(paths) == 4 and read_demo(paths[0])[0].shape == (300, 12)
    model = PPO(V6ControlPolicy, Env(), policy_kwargs={"net_arch": [64, 64], "log_std_init": -0.5}, device="cpu", seed=0)
    log_std = model.policy.log_std.detach().clone()
    report = clone(model, paths, [f"o{i}" for i in range(12)], epochs=30, lr=1e-3)
    held = report["after"]["held_out"]
    assert held["nll"] < report["before"]["held_out"]["nll"]
    assert held["fire_match"] > 0.85 and held["track_mae"] < report["before"]["held_out"]["track_mae"]
    assert np.allclose(model.policy.log_std.detach(), log_std)          # 탐색 잡음은 그대로
