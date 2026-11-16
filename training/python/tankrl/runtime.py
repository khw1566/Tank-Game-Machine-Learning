"""Training device checks. Torch is imported lazily so the dashboard stays lightweight."""
from __future__ import annotations

import json
import platform
import sys


def hardware_info() -> dict:
    import torch

    info = {"python": sys.executable, "python_version": platform.python_version(),
            "torch": torch.__version__, "cuda_version": torch.version.cuda,
            "cuda_available": torch.cuda.is_available(), "gpus": []}
    if info["cuda_available"]:
        try:
            for i in range(torch.cuda.device_count()):
                p = torch.cuda.get_device_properties(i)
                info["gpus"].append({"index": i, "name": p.name,
                                     "memory_mib": round(p.total_memory / 2**20),
                                     "capability": [p.major, p.minor]})
        except Exception as e:
            info.update(cuda_available=False, cuda_error=str(e), gpus=[])
    return info


def select_device(requested: str, info: dict) -> str:
    """Select from probe results without importing torch in the dashboard process."""
    requested = requested.strip().lower()
    if requested == "cpu":
        return "cpu"
    if requested not in ("auto", "hybrid", "cuda") and not (
            requested.startswith("cuda:") and requested[5:].isdigit()):
        raise ValueError("학습 장치는 auto, hybrid, cpu, cuda 또는 cuda:0 형태로 지정하세요")
    if not info["cuda_available"]:
        if requested == "auto":
            return "cpu"
        why = info.get("cuda_error") or ("CPU 전용 PyTorch" if not info.get("cuda_version")
                                         else "CUDA 드라이버/장치를 초기화할 수 없음")
        raise RuntimeError(f"CUDA 학습 불가: {why}. training/python/setup_gpu.bat 실행 후 "
                           "대시보드의 학습용 Python을 .venv로 설정하세요. CPU는 --device cpu.")
    index = int(requested.split(":")[1]) if ":" in requested else 0
    if index >= len(info["gpus"]):
        raise ValueError(f"CUDA 장치 {index}가 없습니다(사용 가능한 장치 {len(info['gpus'])}개)")
    return f"cuda:{index}"


def resolve_device(requested: str, info: dict | None = None) -> str:
    """Explicit CUDA never silently falls back to CPU (unlike SB3's device resolver)."""
    import torch

    device = select_device(requested, hardware_info() if info is None else info)
    if device == "cpu":
        return device
    # A real kernel catches incompatible drivers/binaries before spawning Godot processes.
    try:
        if torch.ones(1, device=device).sum().item() != 1:
            raise RuntimeError("CUDA 연산 검증 실패")
    except Exception as e:
        raise RuntimeError(f"{device} 연산을 실행하지 못했습니다: {e}") from e
    return device


def model_runtime(model, requested: str) -> dict:
    import torch

    device = next(model.policy.parameters()).device
    return {"requested_device": requested, "device": str(device),
            "gpu_name": torch.cuda.get_device_name(device) if device.type == "cuda" else None,
            "torch": torch.__version__, "cuda_version": torch.version.cuda,
            "torch_threads": torch.get_num_threads(), "n_steps": model.n_steps,
            "batch_size": model.batch_size, "n_epochs": model.n_epochs,
            "rollout_size": model.n_steps * model.n_envs,
            "rollout_buffer": type(model.rollout_buffer).__name__,
            "mode": "hybrid" if hasattr(model, "training_device") else device.type,
            "inference_device": getattr(model, "inference_device", str(device)),
            "update_device": str(device)}


def gpu_memory(device: str) -> dict:
    import torch

    if not device.startswith("cuda"):
        return {}
    return {"allocated_mib": round(torch.cuda.memory_allocated(device) / 2**20, 1),
            "reserved_mib": round(torch.cuda.memory_reserved(device) / 2**20, 1)}


if __name__ == "__main__":
    print(json.dumps(hardware_info(), ensure_ascii=False))
