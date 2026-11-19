"""Relocatable Windows training bundle entry point; stdlib-only bootstrap."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
TRAINING = ROOT / "training" / "python"


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8-sig"))


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".portable.tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")
    os.replace(temporary, path)


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def selected_python():
    gpu = ROOT / "gpu_env" / "Scripts" / "python.exe"
    if gpu.exists() and (gpu.parent.parent / "verified.json").exists():
        # Windows venv launchers read an absolute home; refresh it if the bundle moved.
        config = gpu.parent.parent / "pyvenv.cfg"
        lines = config.read_text(encoding="utf-8").splitlines()
        rebased = [f"home = {ROOT / 'python'}" if line.startswith("home =") else
                   f"executable = {ROOT / 'python' / 'python.exe'}" if line.startswith("executable =") else line
                   for line in lines]
        if lines != rebased:
            config.write_text("\n".join(rebased) + "\n", encoding="utf-8")
        return gpu
    return ROOT / "python" / "python.exe"


def environment():
    env = dict(os.environ)
    for name in ("PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV"):
        env.pop(name, None)
    env.update(PYTHONUTF8="1", TANKGAME_DATA_DIR=str(ROOT / "data"))
    return env


def run(command, **kw):
    return subprocess.run([str(x) for x in command], cwd=TRAINING, env=environment(), check=True, **kw)


def hardware():
    code = "from tankrl.runtime import hardware_info; import json; print(json.dumps(hardware_info()))"
    return json.loads(run([selected_python(), "-c", code], capture_output=True, text=True, encoding="utf-8").stdout)


def prepare():
    config = read(ROOT / "package_config.json")
    run_dir = ROOT / "data" / "runs" / config["run"]
    os.environ.update(TANKGAME_DATA_DIR=str(ROOT / "data"), PYTHONUTF8="1")
    sys.path.insert(0, str(TRAINING))
    from tankrl.storage import checkpoint_paths
    checkpoint, _ = checkpoint_paths(run_dir / "shared")
    if checkpoint is None:
        raise RuntimeError("Packaged checkpoint is missing")
    # Rebase only runtime paths, retaining curriculum/optimizer/history and new progress.
    for model_dir in run_dir.iterdir():
        health_file = model_dir / "good_checkpoints.json"
        if not model_dir.is_dir() or not health_file.exists():
            continue
        state = read(health_file)
        changed = False
        for row in state.get("good", []) + list(state.get("best", {}).values()):
            for key in ("path", "source"):
                if key not in row:
                    continue
                value = row[key].replace("\\", "/")
                if value.startswith("$RUN/"):
                    relative = value[5:]
                elif f"/{config['run']}/" in value:
                    relative = value.split(f"/{config['run']}/", 1)[1]
                else:
                    raise ValueError(f"Unrecognized portable health path: {value}")
                resolved = (run_dir / relative).resolve()
                if not resolved.is_relative_to(run_dir.resolve()) or not resolved.is_file():
                    raise ValueError(f"Missing portable health checkpoint: {relative}")
                if row[key] != str(resolved):
                    row[key] = str(resolved)
                    changed = True
        if changed:
            write(health_file, state)
    manifest_path = run_dir / "run.json"
    if manifest_path.exists():
        manifest = read(manifest_path)
        before = json.dumps(manifest, sort_keys=True)
        for session in manifest.get("sessions", []):
            args = session.setdefault("args", {})
            args.update(godot=str(ROOT / "build" / "TankGame_battle.exe"), project=None,
                        runs_dir=str(run_dir.parent), pool_dir=str(run_dir / "opponents"))
            session.setdefault("preserved_runtime", {})["executable"] = str(ROOT / "build" / "TankGame_battle.exe")
        if json.dumps(manifest, sort_keys=True) != before:
            write(manifest_path, manifest)
    write(run_dir.parent / "dashboard_settings.json", {
        "godot": str(ROOT / "build" / "TankGame_battle.exe"), "project": "",
        "python": str(selected_python()), "device": config["device"]})
    return config, run_dir


def check(full=False):
    manifest = read(ROOT / "PACKAGE_MANIFEST.json")
    selected = manifest["files"] if full else [x for x in manifest["files"]
                                              if x["path"] == "build/TankGame_battle.exe"]
    for item in selected:
        if digest(ROOT / item["path"]) != item["sha256"]:
            raise RuntimeError("Checksum mismatch: " + item["path"])
    config, run_dir = prepare()
    info = hardware()
    print(json.dumps(info, ensure_ascii=False, indent=2), flush=True)
    from tankrl.godot_env import GodotProcess
    probe_dir = ROOT / "data" / "checks"
    probe_dir.mkdir(parents=True, exist_ok=True)
    p = GodotProcess(str(ROOT / "build" / "TankGame_battle.exe"), None, 0, str(probe_dir),
                     extra=["--obs=battle"], timeout=30)
    try:
        if p.hello.get("targeting_obs_version") != 1 or p.obs_size != 605:
            raise RuntimeError("Wrong game observation protocol")
        if int(p.hello.get("battle_balance_version", 1)) < int(manifest.get("balance_version", 1)):
            raise RuntimeError("The game executable is older than the packaged balance profile")
    finally:
        p.close()
    pointer = read(run_dir / "shared" / "checkpoint.json")
    print(f"READY: {config['run']} / step {pointer['num_timesteps']:,} / 605 observations", flush=True)
    print("CUDA ready" if info["cuda_available"] else "CPU ready; optional GPU setup requires NVIDIA and internet")


def setup_gpu():
    gpu = ROOT / "gpu_env"
    if not (gpu / "Scripts" / "python.exe").exists():
        run([ROOT / "python" / "python.exe", "-I", "-m", "venv", gpu])
    py = gpu / "Scripts" / "python.exe"
    run([py, "-m", "pip", "install", "--disable-pip-version-check", "-r", TRAINING / "requirements-cuda.txt"])
    run([py, "-m", "pip", "install", "--disable-pip-version-check", "-r", ROOT / "requirements-lock.txt"])
    run([py, "-c", "from tankrl.runtime import resolve_device; print('Verified:', resolve_device('cuda'))"])
    write(gpu / "verified.json", {"verified": True})
    print("GPU environment verified. Resume will select it automatically.")


def resume(args):
    config, run_dir = prepare()
    hw = hardware()
    gpu = hw["cuda_available"] and args.device != "cpu"
    n_envs = args.n_envs or config.get("n_envs") or min(16, max(2, (os.cpu_count() or 4) // 2))
    command = [selected_python(), "-u", TRAINING / "train.py", "--godot", ROOT / "build" / "TankGame_battle.exe",
               "--curriculum", "battle", "--tank", "shared", "--auto-branch", "--resume", "--run", config["run"],
               "--runs-dir", run_dir.parent, "--pool-dir", run_dir / "opponents", "--n-envs", str(n_envs),
               "--device", args.device or config["device"], "--torch-threads", "1" if gpu else "2",
               "--n-steps", "512" if gpu else "256", "--batch-size", "4096" if gpu and n_envs >= 8 else "512",
               "--n-epochs", "4", "--timesteps", str(args.timesteps or config["timesteps"]),
               "--rotate-steps", str(config["rotate_steps"]), "--cycles", str(config["cycles"]),
               "--save-every", "50000", "--record-every", "100"]
    print(f"Resuming {config['run']}: environments={n_envs}, Python={selected_python()}", flush=True)
    run(command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["check", "gpu", "resume", "dashboard", "stop"])
    parser.add_argument("--full", action="store_true", help="Verify every packaged file before first use")
    parser.add_argument("--n-envs", type=int)
    parser.add_argument("--timesteps", type=int)
    parser.add_argument("--device", choices=["auto", "cpu", "hybrid", "cuda"], default=None)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()
    if args.mode == "check":
        check(args.full)
    elif args.mode == "gpu":
        setup_gpu()
    elif args.mode == "resume":
        resume(args)
    elif args.mode == "dashboard":
        _, directory = prepare()
        command = [selected_python(), TRAINING / "dashboard.py", "--runs-dir", directory.parent, "--port", str(args.port)]
        if args.no_browser:
            command.append("--no-browser")
        run(command)
    else:
        _, directory = prepare()
        with (directory / "control.jsonl").open("a", encoding="utf-8") as f:
            f.write(json.dumps({"cmd": "stop"}) + "\n")
        print("Stop requested. The trainer saves its checkpoint before exiting.")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
