"""자기대전 상대 풀: 전차 종류별로 저장된 정책 스냅숏(pool/<tank>/*.zip)을 불러 추론한다.

- 대부분 최신(latest.zip), latest_prob 외에는 예전 스냅숏을 고른다(한 상대에만 맞춘 전술로 굳지 않게).
- 버전 문자열 = 파일 이름(예: "sherman75/step_000400000.zip") → 에피소드 기록·재현 파일에 남는다.
"""
from __future__ import annotations

import random
from collections import OrderedDict
from pathlib import Path

import numpy as np


class OpponentPool:
    def __init__(self, pool_dir: str | Path, exclude: str | None = None, latest_prob: float = 0.7,
                 device: str = "cpu"):
        self.dir = Path(pool_dir)
        self.exclude = exclude          # 지금 학습 중인 종류(그 종류는 copy 로 현재 정책을 쓴다)
        self.latest_prob = latest_prob
        self.device = device
        self.input_env = None
        self._models: OrderedDict[str, object] = OrderedDict()
        self._mtime: dict[str, float] = {}

    def _files(self, tank: str) -> list[Path]:
        d = self.dir / tank
        return sorted(d.glob("step_*.zip")) if d.exists() else []

    def available(self) -> list[str]:
        out = []
        for d in self.dir.glob("*") if self.dir.exists() else []:
            if d.is_dir() and d.name != self.exclude and ((d / "latest.zip").exists() or self._files(d.name)):
                out.append(d.name)
        return out

    def pick(self, tank: str, rng: random.Random) -> str:
        snaps = self._files(tank)
        if (self.dir / tank / "latest.zip").exists() and (not snaps or rng.random() < self.latest_prob):
            return f"{tank}/latest.zip"
        return f"{tank}/{rng.choice(snaps).name}" if snaps else f"{tank}/latest.zip"

    def describe(self, version: str) -> str:
        """기록용 이름: latest.zip 은 저장 당시 실제 버전(latest.json)으로 바꾼다."""
        if version.endswith("latest.zip"):
            meta = self.dir / version.replace("latest.zip", "latest.json")
            try:
                import json
                return json.loads(meta.read_text(encoding="utf-8"))["version"]
            except Exception:
                return version
        return version

    def pick_frozen(self, tank: str, rng: random.Random, fallback: str = "shared") -> str:
        """경기 중 교체되지 않는 스냅숏만 선택. 분화 전에는 공통 정책을 사용한다."""
        for key in dict.fromkeys((tank, fallback)):
            snapshots = self._files(key)
            if snapshots:
                chosen = snapshots[-1] if rng.random() < self.latest_prob else rng.choice(snapshots)
                return f"{key}/{chosen.name}"
        raise RuntimeError(f"자기 대전 상대 스냅숏이 없습니다: {tank} (fallback={fallback})")

    def _load_policy(self, path: Path):
        from stable_baselines3 import PPO
        if self.input_env is None:
            return PPO.load(str(path), device=self.device)

        # Building a frozen policy consumes Torch random numbers and SB3 normally restores
        # its saved seed process-wide. Neither should change the learner's exploration.
        import torch
        device = torch.device(self.device)
        devices = [device] if device.type == "cuda" else []
        with torch.random.fork_rng(devices=devices):
            return PPO.load(str(path), device=self.device, seed=None)

    def _load(self, version: str):
        if version in self._models and not version.endswith("latest.zip"):
            # step_*.zip 스냅숏은 저장 후 바뀌지 않는다: 매 결정마다 파일 시각을 확인하지 않는다
            self._models.move_to_end(version)
            return self._models[version]
        path = self.dir / version
        mt = path.stat().st_mtime
        if version not in self._models or self._mtime.get(version) != mt:
            model = self._load_policy(path)
            if self.input_env is not None:
                from .input_migration import V6_COVER_INPUT_SIZE, V6_INPUT_SIZE, migrate_for_env

                width = model.observation_space.shape[0]
                target = self.input_env.observation_space.shape[0]
                if width != target and (width, target) != (V6_INPUT_SIZE, V6_COVER_INPUT_SIZE):
                    migrated = migrate_for_env(path, self.input_env, self.input_env.run_dir / "input_migrations")
                    model = self._load_policy(migrated)
            self._models[version] = model
            self._mtime[version] = mt
        self._models.move_to_end(version)
        while len(self._models) > 64:
            oldest, _ = self._models.popitem(last=False)
            self._mtime.pop(oldest, None)
        return self._models[version]

    @staticmethod
    def compatible_observation(obs: np.ndarray, model) -> np.ndarray:
        from .input_migration import V6_COVER_INPUT_SIZE, V6_INPUT_SIZE

        if (obs.shape[-1], model.observation_space.shape[0]) == (V6_COVER_INPUT_SIZE, V6_INPUT_SIZE):
            return obs[..., :V6_INPUT_SIZE]
        return obs

    def act(self, version: str, obs: np.ndarray) -> np.ndarray:
        model = self._load(version)
        a, _ = model.predict(self.compatible_observation(obs, model) if self.input_env is not None else obs,
                             deterministic=False)
        return a

    def act_batch(self, version: str, obs: np.ndarray) -> np.ndarray:
        """같은 버전 정책을 쓰는 여러 전차(여러 환경)의 관측 [n, D] → 행동 [n, A], forward 1회."""
        model = self._load(version)
        a, _ = model.predict(self.compatible_observation(obs, model) if self.input_env is not None else obs,
                             deterministic=False)
        return np.asarray(a, dtype=np.float32).reshape(len(obs), -1)
