"""On-policy PPO: CPU rollout inference, CUDA optimization, synchronized per rollout."""
from __future__ import annotations

import torch
from stable_baselines3 import PPO


class HybridPPO(PPO):
    def _maybe_recommend_cpu(self, mlp_class_name="ActorCriticPolicy") -> None:
        # CPU inference already handles the MLP workload warned about by vanilla PPO.
        pass

    def _setup_model(self) -> None:
        super()._setup_model()
        self._update_device = self.device
        self._update_policy = self.policy
        if self.device.type == "cuda":
            # gSDE distributions contain non-leaf tensors and cannot be deep-copied.
            # Preserve CPU RNG state while constructing the inference-only policy.
            with torch.random.fork_rng(devices=[]):
                self._rollout_policy = type(self.policy)(**self.policy._get_constructor_parameters()).to("cpu")
        else:
            self._rollout_policy = self.policy

    @property
    def training_device(self):
        return self._update_device

    @property
    def inference_device(self):
        return "cpu"

    def collect_rollouts(self, env, callback, rollout_buffer, n_rollout_steps):
        # Copy only the current policy, once per rollout. Actions/values/log-probs/GAE
        # are all computed by that frozen CPU policy; PPO updates begin after collection.
        self._rollout_policy.load_state_dict(self._update_policy.state_dict())
        self.policy, self.device = self._rollout_policy, torch.device("cpu")
        try:
            return super().collect_rollouts(env, callback, rollout_buffer, n_rollout_steps)
        finally:
            self.policy, self.device = self._update_policy, self._update_device

    def train(self) -> None:
        if getattr(self, "_skip_next_train", False):
            # 자동 복구 직후: 이 롤아웃은 복구 전(망가진) 정책으로 모은 것이라 버린다
            self._skip_next_train = False
            self.logger.record("train/skipped_after_rollback", 1)
            return
        return super().train()

    def _excluded_save_params(self):
        return super()._excluded_save_params() + ["_update_policy", "_rollout_policy", "_update_device", "_skip_next_train"]

    def save(self, path, exclude=None, include=None) -> None:
        # Checkpoint callbacks can fire during CPU collection. Always save the actual
        # learner policy AND its trained optimizer state, not the inference copy.
        previous_policy, previous_device = self.policy, self.device
        self.policy, self.device = self._update_policy, self._update_device
        try:
            return super().save(path, exclude=exclude, include=include)
        finally:
            self.policy, self.device = previous_policy, previous_device
