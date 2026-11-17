"""Verify an archive snapshot and restore it into a NEW data directory."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import zipfile

from verify_snapshot import verify


def restore(snapshot: Path, destination: Path | None = None):
    verify(snapshot)
    entries = json.loads((snapshot / 'content_manifest.json').read_text(encoding='utf-8'))['files']
    groups = {}
    for entry in entries:
        groups.setdefault(entry['archive'], {})[entry['path']] = entry
    if destination is not None:
        destination = destination.resolve()
        if destination.exists():
            raise ValueError('Destination must not exist; existing training data is never overwritten')
        destination.mkdir(parents=True)
    count = 0
    for archive, expected in groups.items():
        archive_path = (snapshot / archive).resolve()
        if not archive_path.is_relative_to(snapshot.resolve()):
            raise ValueError('Archive outside snapshot: ' + archive)
        with zipfile.ZipFile(archive_path) as source:
            if set(source.namelist()) != set(expected):
                raise ValueError('Archive contents mismatch: ' + archive)
            for name, entry in expected.items():
                path = PurePosixPath(name)
                if path.is_absolute() or '..' in path.parts or ':' in name or '\\' in name:
                    raise ValueError('Unsafe archive path: ' + name)
                target = destination.joinpath(*path.parts) if destination is not None else None
                if target:
                    target.parent.mkdir(parents=True, exist_ok=True)
                digest = hashlib.sha256()
                size = 0
                with source.open(name) as incoming:
                    output = target.open('xb') if target else None
                    try:
                        for data in iter(lambda: incoming.read(1024 * 1024), b''):
                            digest.update(data)
                            size += len(data)
                            if output:
                                output.write(data)
                    finally:
                        if output:
                            output.close()
                if size != entry['bytes'] or digest.hexdigest() != entry['sha256']:
                    raise ValueError('Content checksum mismatch: ' + name)
                count += 1
    return dict(verified_archive_files=count, destination=str(destination) if destination else None)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('--dest', type=Path)
    args = parser.parse_args()
    print(json.dumps(restore(args.snapshot.resolve(), args.dest), indent=2))
