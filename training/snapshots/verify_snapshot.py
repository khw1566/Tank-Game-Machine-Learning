"""Verify a training snapshot after Git LFS download (standard library only)."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def verify(root: Path) -> dict:
    root = root.resolve()
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    expected = set()
    errors = []
    for entry in manifest["files"]:
        name = entry["path"]
        path = (root / name).resolve()
        if not path.is_relative_to(root):
            raise ValueError(f"Path outside snapshot: {name}")
        if name in expected:
            raise ValueError(f"Duplicate manifest entry: {name}")
        expected.add(name)
        if not path.is_file() or path.stat().st_size != entry["bytes"]:
            errors.append(name)
            continue
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        if digest.hexdigest() != entry["sha256"]:
            errors.append(name)
    actual = {p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()
              and p != root / "manifest.json"}
    if actual != expected:
        errors.extend(sorted(actual.symmetric_difference(expected)))
    if len(expected) != manifest["file_count"]:
        raise ValueError("Manifest file count does not match its entries")
    if sum(e["bytes"] for e in manifest["files"]) != manifest["total_bytes"]:
        raise ValueError("Manifest byte count does not match its entries")
    if errors:
        raise ValueError("Missing or changed files (run git lfs pull if needed): " + ", ".join(errors[:10]))
    return {"verified_files": len(expected), "bytes": manifest["total_bytes"],
            "num_timesteps": manifest["training_state"]["num_timesteps"],
            "latest_checkpoint_sha256": manifest["latest_checkpoint_sha256"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", type=Path)
    args = parser.parse_args()
    print(json.dumps(verify(args.snapshot), indent=2))


if __name__ == "__main__":
    main()
