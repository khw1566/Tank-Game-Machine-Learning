"""실제 전투 시범(사람 조작) 파일 형식과 V6 전차별 모델 행동 복제.

시범 1판 = npz 1개:
    obs      float32 [N, D]   학습 전차와 같은 관측(V6 = 750개, 라벨은 meta.obs_labels)
    actions  float32 [N, 11]  정책 공간 행동(-1~1, int8 양자화 값). Godot 이 이 값을 policy_to_action 으로 적용했다
    meta     JSON 문자열       차종·단계·맵·시드·결과·관측/행동 라벨·게임 버전

행동 복제는 PPO 정책의 행동 분포(V6ControlDistribution = 실제로 적용되는 int8 명령의 확률)에 대한
음의 로그우도를 줄인다. 표준편차(log_std)와 가치 함수는 건드리지 않아 PPO 탐색이 그대로 이어진다.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np

DEMO_FORMAT = "tankgame-combat-demo-v1"
ALLIES = ("sherman75", "t34_76")


def demos_root() -> Path:
    from .storage import data_root
    return data_root() / "combat_demos"


def save_demo(path: Path, obs: np.ndarray, actions: np.ndarray, meta: dict) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp.npz")
    np.savez_compressed(tmp, obs=obs.astype(np.float32), actions=actions.astype(np.float32),
                        meta=np.array(json.dumps(dict(meta, format=DEMO_FORMAT), ensure_ascii=False)))
    tmp.replace(path)
    return path


def read_demo(path: Path) -> tuple[np.ndarray, np.ndarray, dict]:
    with np.load(path, allow_pickle=False) as data:
        meta = json.loads(str(data["meta"]))
        obs, actions = data["obs"], data["actions"]
    if meta.get("format") != DEMO_FORMAT:
        raise ValueError(f"실제 전투 시범 형식이 아닙니다: {path}")
    if obs.ndim != 2 or actions.shape != (len(obs), 11) or not np.isfinite(obs).all() or not np.isfinite(actions).all():
        raise ValueError(f"손상된 시범: {path}")
    if len(meta.get("obs_labels", [])) != obs.shape[1]:
        raise ValueError(f"관측 라벨 수가 다릅니다: {path}")
    return obs, actions, meta


def list_demos(tank: str, root: Path | None = None) -> list[Path]:
    d = (root or demos_root()) / tank
    return sorted(d.glob("*.npz")) if d.exists() else []


def _align(obs: np.ndarray, labels: list[str], target: list[str]) -> np.ndarray:
    """시범 관측 열을 모델 입력 라벨 순서로 맞춘다(없는 열은 0)."""
    if labels == target:
        return obs
    index = {name: i for i, name in enumerate(labels)}
    out = np.zeros((len(obs), len(target)), dtype=np.float32)
    for j, name in enumerate(target):
        if name in index:
            out[:, j] = obs[:, index[name]]
    return out


def clone(model, paths: list[Path], obs_labels: list[str], *, epochs: int = 20, lr: float = 3e-4,
          batch: int = 256, seed: int = 0, patience: int = 4) -> dict:
    """model.policy 의 행동 평균을 사람 시범 쪽으로 옮긴다. 판 단위로 20%(최소 1판)를 검증에 쓴다."""
    import torch

    if not paths:
        raise ValueError("시범 파일이 없습니다")
    rng = np.random.default_rng(seed)
    episodes, sources = [], []
    for p in paths:
        obs, act, meta = read_demo(p)
        if len(obs) == 0:
            continue
        episodes.append((_align(obs, meta["obs_labels"], obs_labels), act))
        sources.append({"file": p.name, "steps": int(len(obs)), "stage": meta.get("stage"), "map": meta.get("map"),
                        "result": meta.get("result", {}).get("reason")})
    if not episodes:
        raise ValueError("기록된 조작이 있는 시범이 없습니다")
    order = rng.permutation(len(episodes))
    n_val = max(1, len(order) // 5) if len(order) > 1 else 0
    val_ids, train_ids = order[:n_val], order[n_val:]
    policy = model.policy
    dev = policy.device

    def stack(ids):
        if len(ids) == 0:
            return None
        return (torch.as_tensor(np.concatenate([episodes[i][0] for i in ids]), device=dev),
                torch.as_tensor(np.concatenate([episodes[i][1] for i in ids]), device=dev))

    train, val = stack(train_ids), stack(val_ids)
    params = [p for name, p in policy.named_parameters()
              if name != "log_std" and not name.startswith(("value_net", "mlp_extractor.value_net", "vf_features_extractor"))]
    optimizer = torch.optim.Adam(params, lr=lr)

    def nll(obs, act):
        dist = policy.get_distribution(obs)
        return -dist.log_prob(act).mean()

    def agree(data):
        """사람 조작과 정책 최빈 행동의 일치(발사·제동·시점은 같은 구간인지, 궤도·포는 평균 절대 오차)."""
        if data is None:
            return None
        with torch.no_grad():
            mode = policy.get_distribution(data[0]).mode().clamp(-1, 1)
            y = data[1]
            fire = ((mode[:, 5] > 0) == (y[:, 5] > 0)).float().mean().item()
            brake = ((mode[:, 2] > 0) == (y[:, 2] > 0)).float().mean().item()
            bins = lambda v: (v > -1 / 3).long() + (v > 1 / 3).long()
            view = (bins(mode[:, 6]) == bins(y[:, 6])).float().mean().item()
            tracks = (mode[:, :2] - y[:, :2]).abs().mean().item()
            gun = (mode[:, 3:5] - y[:, 3:5]).abs().mean().item()
            return {"nll": float(nll(*data).item()), "fire_match": fire, "brake_match": brake,
                    "view_match": view, "track_mae": tracks, "gun_mae": gun}

    before = {"train": agree(train), "held_out": agree(val)}
    best, best_state, stale, history = float("inf"), None, 0, []
    policy.set_training_mode(True)
    for epoch in range(epochs):
        perm = torch.as_tensor(rng.permutation(len(train[0])), device=dev)
        for ids in perm.split(batch):
            optimizer.zero_grad(set_to_none=True)
            loss = nll(train[0][ids], train[1][ids])
            loss.backward()
            torch.nn.utils.clip_grad_norm_(params, 1.0)
            optimizer.step()
        with torch.no_grad():
            score = float(nll(*(val or train)).item())
        history.append({"epoch": epoch + 1, "held_out_nll" if val else "train_nll": score})
        if score < best - 1e-4:
            best, stale = score, 0
            best_state = {k: v.detach().clone() for k, v in policy.state_dict().items()}
        else:
            stale += 1
            if stale >= patience:
                break
    if best_state is not None:
        policy.load_state_dict(best_state)
    policy.set_training_mode(False)
    after = {"train": agree(train), "held_out": agree(val)}
    return {"format": DEMO_FORMAT, "episodes": len(episodes), "train_samples": int(len(train[0])),
            "held_out_samples": int(len(val[0])) if val else 0, "held_out_files": [sources[i]["file"] for i in val_ids],
            "epochs_run": len(history), "lr": lr, "seed": seed, "before": before, "after": after,
            "history": history, "sources": sources}
