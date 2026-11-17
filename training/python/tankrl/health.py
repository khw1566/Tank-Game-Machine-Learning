"""학습 건강 점검 · 정상 체크포인트 보관 · 자동 복구.

PPO 갱신마다 정책 상태를 점검한다. 정상인 동안 저장되는 스냅숏은 "정상 체크포인트"로 표시하고, 단계마다
가장 성공률이 높았던 모델은 good/ 폴더에 따로 복사해 둔다(일반 스냅숏 정리와 무관하게 남는다).
망가지는 징후가 이어지면 갱신용 정책과 optimizer 를 마지막 정상 체크포인트로 되돌린다.
같은 단계에서 복구가 반복되면 학습을 일시정지하고 사람이 보게 한다.

기록: <tank>/health.jsonl(갱신마다 점검값·판정), <tank>/good_checkpoints.json(정상 목록·단계별 최고),
      실행 폴더 curriculum_log.jsonl 에 reason = "rollback" / "rollback_limit" 로 남겨 대시보드 곡선에 표시한다.

판정(모두 연속 횟수로 판단해 한 번의 튐에는 반응하지 않는다)
  nonfinite         정책 가중치·손실에 NaN/inf                                → 즉시
  kl                approx KL > kl_limit 가 kl_patience 회 연속                → 정책이 한 번에 너무 크게 바뀜
  value             explained_variance < ev_floor 가 ev_patience 회 연속        → 가치 예측 붕괴
  std               행동 잡음 평균이 상한의 std_ratio 이상으로 std_patience 회 연속 → 잡음이 상한에 붙음
  success           현재 단계 성공률이 그 단계 최고보다 drop 이상 낮은 상태가 success_patience 회 연속
"""
from __future__ import annotations

import json
import math
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path

from .storage import atomic_copy


@dataclass
class HealthConfig:
    kl_limit: float = 0.3
    kl_patience: int = 3
    ev_floor: float = 0.0
    ev_patience: int = 6
    std_cap: float = 1.0
    std_ratio: float = 0.98
    std_patience: int = 40
    drop: float = 0.35
    min_best: float = 0.4
    success_patience: int = 12
    good_after: int = 3          # 연속 정상 점검 횟수가 이만큼이면 저장본을 정상으로 표시
    max_rollbacks: int = 3       # 한 단계에서 이만큼 복구하면 일시정지
    keep_good: int = 30          # 정상 목록에 남길 개수(파일은 지우지 않는다)


@dataclass
class HealthMonitor:
    tdir: Path
    config: HealthConfig = field(default_factory=HealthConfig)
    streak: dict = field(default_factory=lambda: {"kl": 0, "value": 0, "std": 0, "success": 0, "healthy": 0})
    best: dict = field(default_factory=dict)          # 단계 -> 최고 성공률
    rollbacks: dict = field(default_factory=dict)     # 단계 -> 복구 횟수
    good: list = field(default_factory=list)
    best_models: dict = field(default_factory=dict)   # 단계 -> {step, path, success}
    last: dict = field(default_factory=dict)

    def __post_init__(self):
        self.tdir = Path(self.tdir)
        state = self._read(self.tdir / "good_checkpoints.json")
        self.good = state.get("good", [])
        self.best_models = state.get("best", {})
        self.rollbacks = state.get("rollbacks", {})
        self.best = {k: v.get("success", 0.0) for k, v in self.best_models.items()}

    @staticmethod
    def _read(path: Path) -> dict:
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}

    # ------------------------------------------------------------ 점검
    @staticmethod
    def policy_metrics(model) -> dict:
        import torch
        policy = getattr(model, "_update_policy", None) or model.policy
        finite = all(bool(torch.isfinite(p).all()) for p in policy.parameters())
        out = {"finite": finite}
        log_std = getattr(policy, "log_std", None)
        if log_std is not None:
            std = log_std.detach().exp()
            out.update(std_mean=float(std.mean()), std_max=float(std.max()))
        return out

    def check(self, step: int, stage: str, logged: dict, success: float | None, model) -> dict:
        c = self.config
        m = self.policy_metrics(model)
        def num(key):   # SB3 logger 값은 numpy float32 일 수 있다(JSON 기록용으로 float 로 바꾼다)
            v = logged.get(key)
            return None if v is None else float(v)
        kl, ev, loss = num("train/approx_kl"), num("train/explained_variance"), num("train/loss")
        reasons = []
        if not m["finite"] or (loss is not None and not math.isfinite(loss)):
            reasons.append("nonfinite")
        self.streak["kl"] = self.streak["kl"] + 1 if kl is not None and kl > c.kl_limit else 0
        self.streak["value"] = self.streak["value"] + 1 if ev is not None and ev < c.ev_floor else 0
        at_cap = c.std_cap > 0 and m.get("std_mean", 0) >= c.std_cap * c.std_ratio
        self.streak["std"] = self.streak["std"] + 1 if at_cap else 0
        if success is not None:
            self.best[stage] = max(self.best.get(stage, 0.0), success)
        top = self.best.get(stage, 0.0)
        falling = success is not None and top >= c.min_best and success < top - c.drop
        self.streak["success"] = self.streak["success"] + 1 if falling else 0
        if self.streak["kl"] >= c.kl_patience:
            reasons.append("kl")
        if self.streak["value"] >= c.ev_patience:
            reasons.append("value")
        if self.streak["std"] >= c.std_patience:
            reasons.append("std")
        if self.streak["success"] >= c.success_patience:
            reasons.append("success")
        warning = [k for k in ("kl", "value", "std", "success") if self.streak[k] > 0]
        self.streak["healthy"] = 0 if (reasons or warning) else self.streak["healthy"] + 1
        verdict = "collapse" if reasons else ("warning" if warning else "ok")
        self.last = {"t": round(time.time(), 1), "step": step, "stage": stage, "verdict": verdict, "reasons": reasons,
                     "warning": warning, "approx_kl": kl, "explained_variance": ev, "success": success,
                     "best_success": top, "streak": dict(self.streak), **m}
        with (self.tdir / "health.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps(self.last, ensure_ascii=False) + "\n")
        return self.last

    @property
    def healthy(self) -> bool:
        return self.streak["healthy"] >= self.config.good_after

    # ------------------------------------------------------------ 정상 체크포인트
    def mark_saved(self, step: int, stage: str, snapshot: Path, success: float | None) -> None:
        """방금 저장한 스냅숏을, 최근 점검이 계속 정상이었으면 정상 체크포인트로 표시."""
        if not self.healthy or not snapshot.exists():
            return
        entry = {"step": step, "stage": stage, "path": str(snapshot), "success": success,
                 "std_mean": self.last.get("std_mean"), "approx_kl": self.last.get("approx_kl"),
                 "t": round(time.time(), 1)}
        self.good.append(entry)
        self.good = self.good[-self.config.keep_good:]
        best = self.best_models.get(stage)
        if success is not None and (best is None or success > best.get("success", -1)):
            target = self.tdir / "good" / f"best_{stage}.zip"
            target.parent.mkdir(parents=True, exist_ok=True)
            atomic_copy(snapshot, target)
            self.best_models[stage] = dict(entry, path=str(target), source=str(snapshot))
        self._save()

    def _save(self) -> None:
        data = {"good": self.good, "best": self.best_models, "rollbacks": self.rollbacks, "config": asdict(self.config)}
        tmp = self.tdir / "good_checkpoints.json.tmp"
        tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
        tmp.replace(self.tdir / "good_checkpoints.json")

    def rollback_target(self, stage: str) -> dict | None:
        same = [g for g in self.good if g["stage"] == stage and Path(g["path"]).exists()]
        if same:
            return same[-1]
        any_good = [g for g in self.good if Path(g["path"]).exists()]
        return any_good[-1] if any_good else None

    # ------------------------------------------------------------ 복구
    def rollback(self, model, stage: str) -> dict | None:
        """갱신용 정책·optimizer 를 마지막 정상 체크포인트로 되돌린다. 수집용 복사본은 다음 수집 때 동기화된다."""
        target = self.rollback_target(stage)
        if target is None:
            return None
        from stable_baselines3.common.save_util import load_from_zip_file
        policy = getattr(model, "_update_policy", None) or model.policy
        device = next(policy.parameters()).device
        _, params, _ = load_from_zip_file(target["path"], device=device)
        policy.load_state_dict(params["policy"])
        if "policy.optimizer" in params:
            policy.optimizer.load_state_dict(params["policy.optimizer"])
        rollout = getattr(model, "_rollout_policy", None)
        if rollout is not None and rollout is not policy:
            rollout.load_state_dict(policy.state_dict())
        self.rollbacks[stage] = self.rollbacks.get(stage, 0) + 1
        for k in ("kl", "value", "std", "success", "healthy"):
            self.streak[k] = 0
        self._save()
        return dict(target, count=self.rollbacks[stage], limit=self.config.max_rollbacks)

    def over_limit(self, stage: str) -> bool:
        return self.rollbacks.get(stage, 0) >= self.config.max_rollbacks
