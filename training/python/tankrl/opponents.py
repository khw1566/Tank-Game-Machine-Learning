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

    def _load(self, version: str):
        from stable_baselines3 import PPO
        path = self.dir / version
        mt = path.stat().st_mtime
        if version not in self._models or self._mtime.get(version) != mt:
            self._models[version] = PPO.load(str(path), device=self.device)
            self._mtime[version] = mt
        self._models.move_to_end(version)
        while len(self._models) > 64:
            oldest, _ = self._models.popitem(last=False)
            self._mtime.pop(oldest, None)
        return self._models[version]

    def act(self, version: str, obs: np.ndarray) -> np.ndarray:
        a, _ = self._load(version).predict(obs, deterministic=False)
        return a
