"""Copy every existing training artifact into a frozen archive OUTSIDE the active training paths.

Sources are only read, never modified or deleted. The archive gets a per-file SHA-256 manifest,
the source commit, Python package versions and game executable hashes, and is then verified by
re-reading every archived file against the hash taken from its source.

    python training/snapshots/archive_all.py --dest C:/Users/<you>/Desktop/TankGameML_archive/<name>
    python training/snapshots/archive_all.py --verify C:/Users/<you>/Desktop/TankGameML_archive/<name>
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

REPO = Path(__file__).resolve().parents[2]
SKIP_NAMES = {'.training.lock', '__pycache__'}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(4 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def sources() -> dict[str, Path]:
    found = {
        'repo_runs': REPO / 'training' / 'python' / 'runs',
        'repo_snapshots': REPO / 'training' / 'snapshots',
        'build': REPO / 'build',
        'reports_output': REPO / 'output',
    }
    local = Path(os.environ.get('LOCALAPPDATA', Path.home())) / 'TankGameML'
    if os.environ.get('TANKGAME_DATA_DIR'):
        found['data_dir'] = Path(os.environ['TANKGAME_DATA_DIR'])
    elif local.exists():
        found['localappdata_tankgameml'] = local
    godot = Path(os.environ.get('APPDATA', Path.home())) / 'Godot' / 'app_userdata' / 'Tank Game Machine Learning' / 'logs'
    if godot.exists():
        found['godot_user_logs'] = godot
    return {k: v for k, v in found.items() if v.exists()}


def walk(root: Path):
    for path in sorted(root.rglob('*')):
        if path.is_file() and not any(part in SKIP_NAMES for part in path.parts):
            yield path


def run(cmd: list[str]) -> str:
    try:
        return subprocess.run(cmd, cwd=REPO, capture_output=True, text=True, check=False).stdout.strip()
    except OSError as error:
        return f'unavailable: {error}'


def create(dest: Path) -> dict:
    dest = dest.resolve()
    if dest.exists():
        raise SystemExit('Destination must not exist; archives are never overwritten: ' + str(dest))
    if dest.is_relative_to(REPO):
        raise SystemExit('Archive must live outside the repository / active training paths')
    (dest / 'data').mkdir(parents=True)
    files = []
    for label, root in sources().items():
        for path in walk(root):
            rel = Path(label) / path.relative_to(root)
            target = dest / 'data' / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            before = sha256(path)
            shutil.copy2(path, target)
            files.append(dict(path=rel.as_posix(), source=str(path), bytes=path.stat().st_size, sha256=before))
    env = dest / 'environment'
    env.mkdir()
    py = REPO / 'training' / 'python' / '.venv' / 'Scripts' / 'python.exe'
    (env / 'pip-freeze.txt').write_text(run([str(py if py.exists() else sys.executable), '-m', 'pip', 'freeze']), encoding='utf-8')
    (env / 'git.txt').write_text('\n'.join([
        'HEAD ' + run(['git', 'rev-parse', 'HEAD']),
        'branch ' + run(['git', 'rev-parse', '--abbrev-ref', 'HEAD']),
        'status:\n' + run(['git', 'status', '--short']),
    ]), encoding='utf-8')
    executables = {f['path']: f['sha256'] for f in files if f['path'].lower().endswith('.exe')}
    manifest = dict(format='tankgame-full-archive', version=1,
                    created=dt.datetime.now().astimezone().isoformat(),
                    source_repo=str(REPO), source_commit=run(['git', 'rev-parse', 'HEAD']),
                    sources={k: str(v) for k, v in sources().items()},
                    executables=executables, file_count=len(files),
                    total_bytes=sum(f['bytes'] for f in files), files=files)
    (dest / 'manifest.json').write_text(json.dumps(manifest, indent=1, ensure_ascii=False), encoding='utf-8')
    return manifest


def verify(dest: Path, compare_sources: bool = True) -> dict:
    dest = dest.resolve()
    manifest = json.loads((dest / 'manifest.json').read_text(encoding='utf-8'))
    errors, changed_sources = [], []
    expected = set()
    for entry in manifest['files']:
        expected.add(entry['path'])
        target = dest / 'data' / entry['path']
        if not target.is_file() or target.stat().st_size != entry['bytes'] or sha256(target) != entry['sha256']:
            errors.append(entry['path'])
        if compare_sources:
            src = Path(entry['source'])
            if not src.is_file() or src.stat().st_size != entry['bytes']:
                changed_sources.append(entry['path'])
    actual = {p.relative_to(dest / 'data').as_posix() for p in (dest / 'data').rglob('*') if p.is_file()}
    errors += sorted(actual ^ expected)
    if len(expected) != manifest['file_count'] or sum(f['bytes'] for f in manifest['files']) != manifest['total_bytes']:
        errors.append('manifest totals')
    result = dict(verified_files=len(expected) - len(errors), file_count=manifest['file_count'],
                  total_bytes=manifest['total_bytes'], errors=errors[:20],
                  sources_changed_since_archive=changed_sources[:20], ok=not errors)
    (dest / 'verification.json').write_text(json.dumps(dict(result, verified_at=dt.datetime.now().astimezone().isoformat()),
                                                       indent=1, ensure_ascii=False), encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--dest', type=Path)
    group.add_argument('--verify', type=Path)
    args = parser.parse_args()
    if args.dest:
        manifest = create(args.dest)
        print(json.dumps(dict(created=str(args.dest), file_count=manifest['file_count'], total_bytes=manifest['total_bytes'])))
        result = verify(args.dest)
    else:
        result = verify(args.verify)
    print(json.dumps(result, indent=1, ensure_ascii=False))
    sys.exit(0 if result['ok'] else 1)


if __name__ == '__main__':
    main()
