"""Build an offline Windows bundle with a consistent battle checkpoint and portable Python."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
import zipfile

from tankrl.storage import default_runs_dir, sha256

ROOT = Path(__file__).resolve().parents[2]


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding="utf-8")


def copy_file(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def copy_tree(source, destination, skip=()):
    for path in source.rglob("*"):
        relative = path.relative_to(source)
        if path.is_file() and not any(p in skip for p in relative.parts) and path.suffix not in (".pyc", ".pyo"):
            copy_file(path, destination / relative)


def command(directory, messages):
    with (directory / "control.jsonl").open("a", encoding="utf-8") as f:
        f.write("".join(json.dumps(m) + "\n" for m in messages))


def snapshot(source, destination):
    status = read(source / "status.json") if (source / "status.json").exists() else {}
    live = time.time() - status.get("updated", 0) < 30 and status.get("phase") != "stopped"
    original_paused = bool(status.get("paused"))
    paused_here = False
    try:
        if live:
            previous = read(source / "shared" / "checkpoint.json")["generation"]
            last_save = status.get("last_save", {}).get("t", 0)
            paused_here = not original_paused
            command(source, [{"cmd": "pause"}, {"cmd": "checkpoint"}])
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                current = read(source / "status.json")
                pointer = read(source / "shared" / "checkpoint.json")
                if (current.get("paused") and pointer["generation"] != previous
                        and current.get("last_save", {}).get("t", 0) > last_save):
                    status = current
                    break
                time.sleep(0.25)
            else:
                raise RuntimeError("Trainer did not acknowledge pause/checkpoint within 60 seconds")
        pointer = read(source / "shared" / "checkpoint.json")
        generation = source / "shared" / pointer["generation"]
        if sha256(generation / "model.zip") != pointer["sha256"]:
            raise RuntimeError("Source checkpoint hash mismatch")
        # Copy immutable generation plus aliases from that exact generation, never a racing latest.zip.
        for filename in ("model.zip", "curriculum.json", "metadata.json"):
            copy_file(generation / filename, destination / "shared" / pointer["generation"] / filename)
        copy_file(generation / "model.zip", destination / "shared" / "latest.zip")
        copy_file(generation / "curriculum.json", destination / "shared" / "curriculum.json")
        write(destination / "shared" / "checkpoint.json", pointer)
        for tank in ("shared", "tiger1", "sherman75", "t34_76"):
            directory = source / tank
            if tank != "shared" and directory.exists():
                copy_tree(directory, destination / tank, skip=("__pycache__",))
            elif directory.exists():
                for model in directory.glob("step_*.zip"):
                    copy_file(model, destination / tank / model.name)
                for name in ("good",):
                    if (directory / name).exists():
                        copy_tree(directory / name, destination / tank / name)
                for name in ("health.jsonl", "good_checkpoints.json", "branch.json"):
                    if (directory / name).exists():
                        copy_file(directory / name, destination / tank / name)
            health = destination / tank / "good_checkpoints.json"
            if health.exists():
                data = read(health)
                for row in data.get("good", []) + list(data.get("best", {}).values()):
                    for key in ("path", "source"):
                        if key in row:
                            relative = Path(row[key]).relative_to(source)
                            row[key] = "$RUN/" + relative.as_posix()
                            if not (destination / relative).is_file():
                                raise RuntimeError("Missing health checkpoint: " + str(relative))
                write(health, data)
        copy_tree(source / "opponents", destination / "opponents", skip=("__pycache__",))
        for name in ("progress.csv", "scenario_progress.csv", "curriculum_log.jsonl", "run.json"):
            if (source / name).exists():
                copy_file(source / name, destination / name)
        if (source / "sb3").exists():
            copy_tree(source / "sb3", destination / "sb3")
        # A PID/lock/old control queue must never masquerade as a running process on another PC.
        portable_status = dict(status, pid=0, phase="stopped", paused=False, stop_requested=False,
                               updated=0, num_timesteps=pointer["num_timesteps"],
                               target_timesteps=None, steps_per_s=0, episodes_per_s=0)
        write(destination / "status.json", portable_status)
        print(f"Checkpoint captured: {pointer['num_timesteps']:,} / {pointer['sha256']}", flush=True)
        return pointer
    finally:
        if paused_here:
            command(source, [{"cmd": "resume"}])
            print("Original trainer resume requested.", flush=True)


def build(args):
    stamp = dt.datetime.now(dt.timezone(dt.timedelta(hours=9))).strftime("%Y%m%d_%H%M%S")
    name = f"TankGameML_Battle_Windows_{stamp}"
    directory = Path(args.output).resolve() / name
    directory.mkdir(parents=True, exist_ok=False)
    source = Path(args.run_dir).resolve()
    run_name = source.name
    pointer = snapshot(source, directory / "data" / "runs" / run_name)
    print("Copying current game and source...", flush=True)
    copy_file(ROOT / "build" / "TankGame_battle.exe", directory / "build" / "TankGame_battle.exe")
    for name_ in ("README.md", "project.godot", "main.gd", "main.tscn", "export_presets.cfg"):
        copy_file(ROOT / name_, directory / name_)
    for name_ in ("controls", "map", "recording", "tanks", "training"):
        for source_file in (ROOT / name_).rglob("*"):
            rel = source_file.relative_to(ROOT)
            if any(p in (".venv", "__pycache__", "snapshots", "runs", "runs_before_persistent_20261117_115744") for p in rel.parts):
                continue
            if source_file.is_file() and source_file.suffix in (".py", ".gd", ".tscn", ".json", ".html", ".md", ".bat", ".txt"):
                copy_file(source_file, directory / rel)
    print("Copying relocatable Python and offline CPU dependencies...", flush=True)
    base = Path(sys.base_prefix)
    for filename in ("python.exe", "pythonw.exe", "python3.dll", "python314.dll", "vcruntime140.dll", "vcruntime140_1.dll", "LICENSE.txt"):
        copy_file(base / filename, directory / "python" / filename)
    for folder in ("Lib", "DLLs", "libs", "include"):
        copy_tree(base / folder, directory / "python" / folder, skip=("site-packages", "__pycache__"))
    packages = Path(sys.prefix) / "Lib" / "site-packages"
    copy_tree(packages, directory / "python" / "Lib" / "site-packages", skip=("__pycache__",))
    freeze = subprocess.check_output([sys.executable, "-m", "pip", "freeze"], text=True)
    (directory / "requirements-lock.txt").write_text("\n".join(x for x in freeze.splitlines()
                                                            if not x.lower().startswith("torch==")) + "\n", encoding="utf-8")
    (directory / "environment-source.txt").write_text(freeze + f"\nPython: {sys.version}\n", encoding="utf-8")
    write(directory / "package_config.json", {"run": run_name, "n_envs": 0, "device": "auto", "timesteps": 10_000_000,
                                              "rotate_steps": 3_000_000, "cycles": 3})
    for filename, mode in (("01_CHECK_PC.bat", "check"), ("02_SETUP_NVIDIA_GPU.bat", "gpu"),
                           ("03_RESUME_TRAINING.bat", "resume"), ("04_OPEN_DASHBOARD.bat", "dashboard"),
                           ("05_SAVE_AND_STOP.bat", "stop")):
        text = ('@echo off\r\nsetlocal\r\nchcp 65001 >nul\r\ncd /d "%~dp0"\r\n'
                'set "PYTHONHOME="\r\nset "PYTHONPATH="\r\nset "PYTHONUTF8=1"\r\n'
                f'"%~dp0python\\python.exe" -I "%~dp0training\\portable\\runner.py" {mode} %*\r\n'
                'if errorlevel 1 echo Operation failed. Check the error above.\r\npause\r\nendlocal\r\n')
        (directory / filename).write_bytes(text.encode("utf-8"))
    readme = f"""# 다른 PC에서 이어서 학습하기

대상: Windows 10/11 x64. Python 3.14, CPU 학습 패키지, 실행 파일과 소스를 포함한다.
Git, Git LFS, Godot 편집기, 별도 Python 설치 없이 CPU 학습을 재개할 수 있다.
학습 저장본: {run_name}, {pointer['num_timesteps']:,} 스텝. 모델 SHA-256: `{pointer['sha256']}`.

1. ZIP을 로컬 폴더에 **전부 압축 해제**한다. 예: `C:/TankBattle`. ZIP 안에서 바로 실행하지 않는다.
2. `01_CHECK_PC.bat`을 실행한다. READY와 전차 관측 605개 확인이 나와야 한다.
3. NVIDIA GPU를 사용할 때만 `02_SETUP_NVIDIA_GPU.bat`을 실행한다. 인터넷과 NVIDIA 드라이버가 필요하다.
   공식 PyTorch CUDA 13.2 인덱스의 고정 버전을 별도 gpu_env에 설치하고 실제 CUDA 초기화까지 검사한다.
   실패해도 포함된 CPU 환경은 유지된다. GPU가 없으면 이 단계를 건너뛴다.
4. `03_RESUME_TRAINING.bat`을 실행한다. 현재 가중치·optimizer·단계·자기 대전 상대를 이어받는다.
5. `04_OPEN_DASHBOARD.bat`을 실행한다. 브라우저에서 http://localhost:8765/ 가 열린다.
6. 끝낼 때 `05_SAVE_AND_STOP.bat` 또는 대시보드의 중지를 누른다. 학습 창에 저장 후 종료가 표시될 때까지 기다린다.

CPU 환경은 오프라인 실행 가능하다. NVIDIA 설정만 네트워크를 사용한다.
GPU 설정은 성공적으로 검증된 경우에만 자동 선택한다. 드라이버/기기 호환성은 빌린 PC에서 확인해야 한다.
GPU 사용 시 시뮬레이션과 상대 추론은 CPU, PPO 갱신은 GPU에서 수행한다.

`package_config.json`에서 n_envs, device, timesteps 등을 바꿀 수 있다.
n_envs=0은 새 PC 논리 코어의 절반, 최소 2개·최대 16개를 선택한다.
명령줄 예: `03_RESUME_TRAINING.bat --n-envs 24 --device hybrid`.
CPU가 병목일 수 있으므로 환경 수는 대시보드 초당 결정 수를 보고 조정한다.

## 파일과 학습 기록

- `data/runs/{run_name}/`: 이어갈 모델, 단계 상태, 상대 풀, 학습 곡선·정상 복구 체크포인트.
- `build/TankGame_battle.exe`: 전투 자기 대전·부위별 조준 관측을 지원하는 게임.
- `python/`: 재배치 가능한 Python 및 검증된 CPU 패키지. Python 라이선스는 python/LICENSE.txt, 패키지 라이선스는 각 dist-info 폴더에 있다.
- `gpu_env/`: NVIDIA 설정 성공 시 생성되는 GPU 전용 환경. CPU 환경과 분리된다.
- `training/BATTLE_SELFPLAY.md`: 세 단계와 관측·보상 설계 설명.
- `PACKAGE_MANIFEST.json`: 파일별 SHA-256, 원본 Git 커밋 및 수정 상태, 저장본 정보.

옛 실험·미완료 LFS 다운로드·개발용 캐시는 포함하지 않는다. 기존 리플레이는 원래 PC에 남기고,
단계 기록과 학습 곡선 및 상대 스냅숏을 옮긴다. 원래 PC의 학습은 패키징 후에도 계속된다.
이 ZIP은 위 스텝의 고정 저장본이므로 이후 원래 PC에서 학습한 내용은 포함되지 않는다.
다른 PC와 원래 PC에서 진행한 가중치를 자동 합치지는 않는다. 어느 쪽 결과를 이어갈지 선택한다.
훈련을 끝낸 뒤 **패키지 폴더 전체**를 복사하면 새 모델과 상대 풀을 함께 다시 옮길 수 있다.
원본 경로가 달라져도 실행 스크립트가 복구 체크포인트와 대시보드 경로를 현재 폴더에 맞춘다.

최초 사용 전에 전체 무결성을 검사하려면 `01_CHECK_PC.bat --full`을 실행한다.
학습/설정 변경 후 데이터 파일 해시가 달라지는 것은 정상이다. 일반 PC 검사는 최신 모델 해시와 게임을 검사한다.

공식 GPU 패키지 인덱스: https://download.pytorch.org/whl/cu132/torch/
"""
    (directory / "START_HERE_KO.md").write_text(readme, encoding="utf-8")
    return seal(directory, pointer, run_name, args.output)


def seal(directory, pointer, run_name, output):
    stamp = dt.datetime.now(dt.timezone(dt.timedelta(hours=9))).strftime("%Y%m%d_%H%M%S")
    curriculum = read(directory / "data" / "runs" / run_name / "shared" / pointer["generation"] / "curriculum.json")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    changes = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True).splitlines()
    print("Hashing package contents...", flush=True)
    paths = [p for p in sorted(directory.rglob("*")) if p.is_file() and p.name != "PACKAGE_MANIFEST.json"]
    def describe(path):
        return {"path": path.relative_to(directory).as_posix(), "size": path.stat().st_size, "sha256": sha256(path)}
    with ThreadPoolExecutor(max_workers=8) as workers:
        files = list(workers.map(describe, paths))
    write(directory / "PACKAGE_MANIFEST.json", {"format": "tankgame-battle-portable", "version": 1,
          "created_kst": stamp, "platform": "Windows x64", "run": run_name, "checkpoint": pointer,
          "balance_version": curriculum.get("balance_version", 1), "reward_version": curriculum.get("reward_version", 1),
          "git_commit": commit, "working_tree_changes": changes, "files": files})
    archive = directory.with_suffix(".zip")
    print(f"Compressing {len(files):,} files into {archive.name}...", flush=True)
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as z:
        for path in sorted(directory.rglob("*")):
            if path.is_file():
                z.write(path, (Path(directory.name) / path.relative_to(directory)).as_posix())
    checksum = sha256(archive)
    archive.with_suffix(".zip.sha256").write_text(f"{checksum}  {archive.name}\n", encoding="ascii")
    result = {"directory": str(directory), "archive": str(archive), "sha256": checksum,
              "size_bytes": archive.stat().st_size, "steps": pointer["num_timesteps"], "files": len(files) + 1}
    write(Path(output).resolve() / "latest_package.json", result)
    print(json.dumps(result, ensure_ascii=False, indent=2), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-dir", default=str(default_runs_dir() / "BATTLE-2"))
    parser.add_argument("--output", default=str(ROOT / "_sync" / "packages"))
    parser.add_argument("--repack", type=Path, help="Rehash/recompress an existing staged package without touching live training")
    args = parser.parse_args()
    if args.repack:
        directory = args.repack.resolve()
        if (directory / "PACKAGE_MANIFEST.json").exists():
            manifest = read(directory / "PACKAGE_MANIFEST.json")
            pointer, run_name = manifest["checkpoint"], manifest["run"]
        else:
            run_name = read(directory / "package_config.json")["run"]
            pointer = read(directory / "data" / "runs" / run_name / "shared" / "checkpoint.json")
        seal(directory, pointer, run_name, args.output)
    else:
        build(args)


if __name__ == "__main__":
    main()
