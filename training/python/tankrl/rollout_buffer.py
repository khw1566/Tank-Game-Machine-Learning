"""Upload each PPO rollout once, reuse it on CUDA across all optimization epochs."""
from __future__ import annotations

import numpy as np
import torch
from stable_baselines3.common.buffers import RolloutBuffer
from stable_baselines3.common.type_aliases import RolloutBufferSamples


class CudaRolloutBuffer(RolloutBuffer):
    def reset(self) -> None:
        self._device_samples = None
        super().reset()

    def _get_samples(self, batch_inds: np.ndarray, env=None) -> RolloutBufferSamples:
        if self.device.type != "cuda":
            return super()._get_samples(batch_inds, env)
        # RolloutBuffer.get() has already flattened time/environment in SB3's order.
        # Keep observations/GAE on CPU during collection; only cache the training data.
        if self._device_samples is None:
            arrays = (self.observations, self.actions.astype(np.float32, copy=False),
                      self.values.flatten(), self.log_probs.flatten(),
                      self.advantages.flatten(), self.returns.flatten())
            self._device_samples = tuple(self.to_torch(a) for a in arrays)
        indices = torch.as_tensor(batch_inds, dtype=torch.long, device=self.device)
        return RolloutBufferSamples(*(a.index_select(0, indices) for a in self._device_samples))
