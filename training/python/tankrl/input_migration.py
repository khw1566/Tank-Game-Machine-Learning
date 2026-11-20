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
V6_INPUT_SIZE = 750
V6_OCCLUSION_LABELS = [f"cover{slot}.{part}_occluded" for slot in range(6) for part in ("hull", "turret")]
V6_COVER_INPUT_SIZE = V6_INPUT_SIZE + len(V6_OCCLUSION_LABELS)
FIRST_LAYERS = ("mlp_extractor.policy_net.0.weight", "mlp_extractor.value_net.0.weight")


def expand_fire_inputs(source: Path, observation_space, output_dir: Path, *, allow_battle: bool = False,
                       allow_v6_cover: bool = False) -> Path:
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
    if allow_v6_cover:
        supported = supported or (old_shape == (V6_INPUT_SIZE,) and new_shape == (V6_COVER_INPUT_SIZE,))
    if not supported:
        raise ValueError(f"Unsupported policy input migration: {old_shape} -> {new_shape}")
    digest = sha256(source)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    kind = "target_occlusion" if allow_v6_cover else "fire_inputs"
    destination = output_dir / f"{digest[:24]}_{kind}_{new_shape[0]}.zip"
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
    data["input_migration"] = {"version": 3 if allow_v6_cover else 1, "kind": kind, "source": str(source), "source_sha256": digest,
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


# ---------------------------------------------------------------- V6: 적 슬롯 4 → 6, 적/아군 표시, 사격선 관측
SITUATION_COUNT_LABELS = ("sit.known_enemies", "sit.exposed_hull", "sit.exposed_turret_only")


def legacy_labels(new_labels: list[str], old_slots: int = 4) -> list[str]:
    """새 관측 라벨에서 old_slots 이후의 적 슬롯(enemyN.*, aimN.*)을 빼면 이전 관측의 순서가 된다."""
    def extra(label: str) -> bool:
        for prefix in ("enemy", "aim"):
            if label.startswith(prefix):
                head = label[len(prefix):].split(".", 1)[0]
                if head.isdigit() and int(head) >= old_slots:
                    return True
        return False
    def added(label: str) -> bool:
        # V6 에서 새로 생긴 입력: 접촉 슬롯의 적/아군 표시(enemyN.team, allyN.team), 사격선 관측(fireline.*)
        if label.startswith("fireline."):
            return True
        head, _, field = label.partition(".")
        return field == "team" and (head.startswith("enemy") or head.startswith("ally"))
    return [label for label in new_labels if not extra(label) and not added(label)]


def expand_enemy_slots(source: Path, observation_space, new_labels: list[str], output_dir: Path, *,
                       old_slots: int = 4, old_max_enemies: float = 4.0, new_max_enemies: float = 6.0) -> Path:
    """V5 모델(적 슬롯 4)을 V6 관측(적 슬롯 6)에 맞게 옮긴다. 기존 입력 열은 라벨이 같은 새 위치로 그대로 옮기고
    새 슬롯 열은 0 이므로 새 슬롯이 비어 있으면 출력이 원래와 같다. 상황 관측의 적 수 3개는 정규화 분모가
    4 → 6 으로 바뀌었으므로 가중치를 6/4 배 해서 같은 함수를 유지한다. 원본 파일은 바꾸지 않는다."""
    source = Path(source).resolve()
    data, params, variables = load_from_zip_file(source, device="cpu")
    old_n = int(data["observation_space"].shape[0])
    new_n = int(observation_space.shape[0])
    if old_n == new_n:
        return source
    old_labels = legacy_labels(new_labels, old_slots)
    if len(old_labels) != old_n or len(new_labels) != new_n:
        raise ValueError(f"관측 라벨로 입력을 맞출 수 없습니다: 원본 {old_n}, 추정 원본 {len(old_labels)}, 새 {new_n}/{len(new_labels)}")
    index = {label: k for k, label in enumerate(new_labels)}
    columns = torch.tensor([index[label] for label in old_labels], dtype=torch.long)
    scale = torch.ones(old_n)
    for label in SITUATION_COUNT_LABELS:
        if label in old_labels:
            scale[old_labels.index(label)] = new_max_enemies / old_max_enemies
    digest = sha256(source)
    output_dir = Path(output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    destination = output_dir / f"{digest[:24]}_enemy_slots_{new_n}.zip"
    if destination.exists():
        return destination
    shapes = set()
    for name in FIRST_LAYERS:
        weight = params["policy"][name]
        if weight.ndim != 2 or weight.shape[1] != old_n:
            raise ValueError(f"Unexpected first layer: {name}: {tuple(weight.shape)}")
        shapes.add(tuple(weight.shape))
        expanded = weight.new_zeros((weight.shape[0], new_n))
        expanded[:, columns] = weight * scale.to(weight.dtype)
        params["policy"][name] = expanded
    for optimizer in (v for k, v in params.items() if k.endswith(".optimizer")):
        for state in optimizer["state"].values():
            for name, value in list(state.items()):
                if isinstance(value, torch.Tensor) and tuple(value.shape) in shapes:
                    expanded = value.new_zeros((value.shape[0], new_n))
                    expanded[:, columns] = value
                    state[name] = expanded
    data["observation_space"] = observation_space
    data["_last_obs"] = None
    data["_last_original_obs"] = None
    data["input_migration"] = {"version": 2, "kind": "enemy_slots", "source": str(source), "source_sha256": digest,
                               "old_size": old_n, "new_size": new_n, "old_slots": old_slots,
                               "new_columns": "zero", "rescaled": list(SITUATION_COUNT_LABELS),
                               "optimizer": "preserved_with_zero_padded_moments"}
    fd, name = tempfile.mkstemp(prefix="enemy_slots_", suffix=".zip", dir=output_dir)
    os.close(fd)
    temporary = Path(name)
    try:
        save_to_zip_file(temporary, data=data, params=params, pytorch_variables=variables)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
    return destination


def saved_input_size(path: Path) -> int:
    data, _, _ = load_from_zip_file(Path(path), device="cpu", load_data=True)
    return int(data["observation_space"].shape[0])


def migrate_for_env(checkpoint: Path, env, output_dir: Path) -> Path:
    """체크포인트 입력을 419/437 → 605 → 750 → 762 순서로 확장한다."""
    import gymnasium as gym
    import numpy as np
    checkpoint = Path(checkpoint).resolve()
    size = saved_input_size(checkpoint)
    target = int(env.observation_space.shape[0])
    if size == target:
        return checkpoint
    if size in (LEGACY_SITUATION_SIZE, THREAT_INPUT_SIZE):
        space = gym.spaces.Box(-np.inf, np.inf, shape=(BATTLE_INPUT_SIZE,), dtype=np.float32)
        checkpoint = expand_fire_inputs(checkpoint, space, output_dir, allow_battle=True)
        size = BATTLE_INPUT_SIZE
    if size == target:
        return checkpoint
    labels = list(getattr(env, "obs_labels", []) or [])
    if target == V6_COVER_INPUT_SIZE:
        if labels[-len(V6_OCCLUSION_LABELS):] != V6_OCCLUSION_LABELS:
            raise ValueError("Unexpected V6 target occlusion labels")
        if size != V6_INPUT_SIZE:
            base_space = gym.spaces.Box(-np.inf, np.inf, shape=(V6_INPUT_SIZE,), dtype=np.float32)
            checkpoint = expand_enemy_slots(checkpoint, base_space, labels[:-len(V6_OCCLUSION_LABELS)], output_dir)
        return expand_fire_inputs(checkpoint, env.observation_space, output_dir, allow_v6_cover=True)
    return expand_enemy_slots(checkpoint, env.observation_space, labels, output_dir)
