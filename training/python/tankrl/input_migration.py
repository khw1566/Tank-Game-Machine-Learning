"""Append fire-cue inputs without changing the learned function or discarding Adam history."""
from __future__ import annotations

import os
from pathlib import Path
import tempfile

import torch
from stable_baselines3.common.save_util import load_from_zip_file, save_to_zip_file

from .storage import sha256

LEGACY_SITUATION_SIZE = 419
THREAT_INPUT_SIZE = 437
BATTLE_INPUT_SIZE = THREAT_INPUT_SIZE + 4 * 7 * 6
FIRST_LAYERS = ("mlp_extractor.policy_net.0.weight", "mlp_extractor.value_net.0.weight")


def expand_fire_inputs(source: Path, observation_space, output_dir: Path, *, allow_battle: bool = False) -> Path:
    """Create an immutable derivative. The source model and all old input columns stay intact."""
    source = Path(source).resolve()
    data, params, variables = load_from_zip_file(source, device="cpu")
    old_shape = tuple(data["observation_space"].shape)
    new_shape = tuple(observation_space.shape)
    if old_shape == new_shape:
        return source
    supported = old_shape == (LEGACY_SITUATION_SIZE,) and new_shape == (THREAT_INPUT_SIZE,)
    if allow_battle:
        supported = supported or (old_shape in ((LEGACY_SITUATION_SIZE,), (THREAT_INPUT_SIZE,))
                                   and new_shape == (BATTLE_INPUT_SIZE,))
    if not supported:
        raise ValueError(f"Unsupported policy input migration: {old_shape} -> {new_shape}")
    digest = sha256(source)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / f"{digest[:24]}_fire_inputs_{new_shape[0]}.zip"
    if destination.exists():
        return destination
    shapes = set()
    for name in FIRST_LAYERS:
        weight = params["policy"][name]
        if weight.ndim != 2 or weight.shape[1] != old_shape[0]:
            raise ValueError(f"Unexpected first layer: {name}: {tuple(weight.shape)}")
        shapes.add(tuple(weight.shape))
        expanded = weight.new_zeros((weight.shape[0], new_shape[0]))
        expanded[:, :old_shape[0]] = weight
        params["policy"][name] = expanded
    for optimizer in (v for k, v in params.items() if k.endswith(".optimizer")):
        for state in optimizer["state"].values():
            for name, value in list(state.items()):
                if isinstance(value, torch.Tensor) and tuple(value.shape) in shapes:
                    expanded = value.new_zeros((value.shape[0], new_shape[0]))
                    expanded[:, :old_shape[0]] = value
                    state[name] = expanded
    data["observation_space"] = observation_space
    data["_last_obs"] = None
    data["_last_original_obs"] = None
    data["input_migration"] = {"version": 1, "source": str(source), "source_sha256": digest,
                               "old_size": old_shape[0], "new_size": new_shape[0],
                               "new_columns": "zero", "optimizer": "preserved_with_zero_padded_moments"}
    fd, name = tempfile.mkstemp(prefix="fire_inputs_", suffix=".zip", dir=output_dir)
    os.close(fd)
    temporary = Path(name)
    try:
        save_to_zip_file(temporary, data=data, params=params, pytorch_variables=variables)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination
