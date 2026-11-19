"""Archive live legacy training data without moving or modifying the source."""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import io
import json
import os
from pathlib import Path
import zipfile
from concurrent.futures import ThreadPoolExecutor


def stable_read(path):
    for _ in range(10):
        before = path.stat()
        data = path.read_bytes()
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) == (after.st_size, after.st_mtime_ns):
            return data, after
    raise RuntimeError(f'File keeps changing: {path}')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    source, destination = args.source.absolute(), args.destination.absolute()
    destination.mkdir(parents=True, exist_ok=False)
    archive_dir = destination / 'archives'
    archive_dir.mkdir()
    started = dt.datetime.now().astimezone().isoformat()
    files, skipped, pinned, checkpoints = [], [], {}, []
    for parent, dirs, names in os.walk(source, followlinks=False):
        for directory in dirs:
            if (Path(parent) / directory).is_junction():
                raise RuntimeError(f'Unexpected external junction: {parent}/{directory}')
        for name in sorted(names):
            path = Path(parent) / name
            relative = path.relative_to(source).as_posix()
            if name.endswith('.lock') or name.endswith('.tmp'):
                skipped.append(relative)
                continue
            files.append((relative, path))
    # Pin complete immutable generations before copying live logs. Publish each
    # snapshot's pointer, latest model and curriculum from the same generation.
    for relative, path in files:
        if path.name != 'checkpoint.json':
            continue
        pointer, stat = stable_read(path)
        info = json.loads(pointer)
        generation = (path.parent / info['generation']).resolve()
        if not generation.is_relative_to(path.parent.resolve()):
            raise RuntimeError(f'Invalid generation: {path}')
        model, model_stat = stable_read(generation / 'model.zip')
        assert hashlib.sha256(model).hexdigest() == info['sha256'], path
        with zipfile.ZipFile(io.BytesIO(model)) as archive:
            assert archive.testzip() is None, path
        curriculum, curriculum_stat = stable_read(generation / 'curriculum.json')
        pinned[relative] = (pointer, stat)
        pinned[(generation / 'model.zip').relative_to(source).as_posix()] = (model, model_stat)
        pinned[(generation / 'curriculum.json').relative_to(source).as_posix()] = (curriculum, curriculum_stat)
        pinned[(path.parent / 'latest.zip').relative_to(source).as_posix()] = (model, model_stat)
        pinned[(path.parent / 'curriculum.json').relative_to(source).as_posix()] = (curriculum, curriculum_stat)
        checkpoints.append(dict(path=relative, **info))
    existing = {relative for relative, _ in files}
    for relative in pinned.keys() - existing:
        files.append((relative, source / relative))
    files.sort()
    rows, archives = [], []
    archive = None
    batch_bytes = 0
    def read_one(item):
        relative, path = item
        data, stat = pinned[relative] if relative in pinned else stable_read(path)
        return relative, data, stat
    pool = ThreadPoolExecutor(max_workers=12)
    try:
        for index, (relative, data, stat) in enumerate(pool.map(read_one, files, buffersize=24), 1):
            if archive is None or batch_bytes + len(data) > 256 * 1024 * 1024:
                if archive:
                    archive.close()
                archive_name = f'archives/part_{len(archives) + 1:03d}.zip'
                archives.append(archive_name)
                archive = zipfile.ZipFile(destination / archive_name, 'w', zipfile.ZIP_DEFLATED, compresslevel=4)
                batch_bytes = 0
            archive.writestr(relative, data)
            batch_bytes += len(data)
            rows.append(dict(path=relative, archive=archive_name, bytes=len(data),
                             sha256=hashlib.sha256(data).hexdigest(), source_mtime_ns=stat.st_mtime_ns,
                             pinned_checkpoint=relative in pinned))
            if index % 1000 == 0:
                print(f'Archived {index}/{len(files)} files', flush=True)
    finally:
        pool.shutdown(wait=True)
        if archive:
            archive.close()
    print('Verifying every archived file and its SHA-256', flush=True)
    verified = 0
    archive_rows = []
    for name in archives:
        with zipfile.ZipFile(destination / name) as archive:
            selected = [row for row in rows if row['archive'] == name]
            assert len(archive.infolist()) == len(selected)
            for row in selected:
                data = archive.read(row['path'])
                assert len(data) == row['bytes']
                assert hashlib.sha256(data).hexdigest() == row['sha256'], row['path']
                verified += 1
        with (destination / name).open('rb') as stream:
            digest = hashlib.file_digest(stream, 'sha256').hexdigest()
        archive_rows.append(dict(path=name, bytes=(destination / name).stat().st_size, sha256=digest))
    manifest = dict(source=str(source), started=started, finished=dt.datetime.now().astimezone().isoformat(),
                    consistency='Live file snapshot; complete checkpoint generations pinned at start. Logs captured per file.',
                    file_count=len(rows), total_source_bytes=sum(row['bytes'] for row in rows),
                    total_archive_bytes=sum(row['bytes'] for row in archive_rows), verified_files=verified,
                    skipped_transient_files=skipped, checkpoints=checkpoints, archives=archive_rows, files=rows)
    (destination / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps({k: manifest[k] for k in ('file_count', 'total_source_bytes', 'total_archive_bytes', 'verified_files')}, ensure_ascii=False), flush=True)


if __name__ == '__main__':
    main()
