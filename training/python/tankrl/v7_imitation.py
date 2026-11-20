"""Initialize the native Godot actor from human decisions captured by its scene."""
import json
from pathlib import Path

import numpy as np
import torch

from .storage import sha256
from .v7_godot import ACTION_LABELS, ALLIES, DEMO_FORMAT, OBS_LABELS, PHYSICS_HZ, PROTOCOL, REPEAT, TEAM_STAGES
from .v7_godot import expected_layout


def read_demonstration(path, tank):
    path = Path(path)
    if path.suffix.lower() != ".json":
        raise ValueError(f"Godot 창에서 저장한 JSON 시범 파일이 필요합니다: {path}")
    with path.open(encoding="utf-8") as source:
        record = json.load(source)
    if (not isinstance(record, dict) or tank not in ALLIES or record.get("format") != DEMO_FORMAT
            or record.get("source") != "godot-human" or record.get("protocol") != PROTOCOL
            or record.get("physics_hz") != PHYSICS_HZ or record.get("repeat") != REPEAT
            or record.get("tank") != tank
            or record.get("stage") not in TEAM_STAGES or record.get("allied_team") is not True
            or record.get("completed") is not True or record.get("obs_labels") != OBS_LABELS
            or record.get("action_labels") != ACTION_LABELS):
        raise ValueError(f"Godot 시범의 출처·차종·완료 상태 또는 입력 규격이 다릅니다: {path}")
    if type(record.get("seed")) is not int or record.get("layout") != expected_layout(tank, record["stage"], record["seed"]):
        raise ValueError(f"현재 커리큘럼의 맵·전차 배치와 일치하지 않는 시범입니다: {path}")
    obs = np.asarray(record.get("obs"), dtype=np.float32)
    actions = np.asarray(record.get("actions"), dtype=np.float32)
    if (obs.ndim != 2 or obs.shape[1] != len(OBS_LABELS) or len(obs) == 0
            or actions.shape != (len(obs), len(ACTION_LABELS))
            or not np.isfinite(obs).all() or not np.isfinite(actions).all()
            or np.abs(obs).max() > 1 or np.abs(actions).max() > 1):
        raise ValueError(f"손상된 Godot 관측·행동 쌍: {path}")
    return obs, actions


def clone_actor(model, paths, tank, seed, epochs=12):
    if model.num_timesteps or model._n_updates or model.policy.optimizer.state:
        raise ValueError("행동 복제는 PPO 첫 업데이트 전에만 적용할 수 있습니다")
    if not paths:
        raise ValueError("수집된 시범이 없습니다")
    rng = np.random.default_rng(seed)
    episodes, sources = [], []
    hashes = set()
    for path in sorted(map(Path, paths)):
        digest = sha256(path)
        if digest not in hashes:
            episodes.append(read_demonstration(path, tank))
            sources.append({"file": path.name, "sha256": digest, "steps": len(episodes[-1][0])})
            hashes.add(digest)
    order = rng.permutation(len(episodes))
    holdout_count = max(1, len(order) // 5) if len(order) > 1 else 0

    def batch(indices):
        return tuple(torch.as_tensor(np.concatenate([episodes[i][j] for i in indices]),
                                     device=model.device) for j in (0, 1))

    x, y = batch(order[holdout_count:])
    validation = batch(order[:holdout_count]) if holdout_count else None
    actor = model.policy
    optimizer = torch.optim.Adam(actor.parameters(), lr=0.001)

    def error(features, target):
        mean = actor.get_distribution(features).mode()
        return torch.nn.functional.mse_loss(mean, target)

    def measure(data):
        with torch.no_grad():
            return float(error(*data).item()) if data is not None else None

    before, validation_before = measure((x, y)), measure(validation)
    for _ in range(epochs):
        for ids in np.array_split(rng.permutation(len(x)), (len(x) + 127) // 128):
            optimizer.zero_grad(set_to_none=True)
            loss = error(x[ids], y[ids])
            loss.backward()
            torch.nn.utils.clip_grad_norm_(actor.parameters(), 1.0)
            optimizer.step()
    optimizer.zero_grad(set_to_none=True)
    return {"tank": tank, "source_format": DEMO_FORMAT, "seed": seed, "epochs": epochs, "episodes": len(episodes),
            "samples": len(x), "held_out_samples": len(validation[0]) if validation is not None else 0,
            "train_mse_before": before, "train_mse_after": measure((x, y)),
            "held_out_mse_before": validation_before, "held_out_mse_after": measure(validation),
            "sources": sources, "held_out_files": [sources[i]["file"] for i in order[:holdout_count]]}
