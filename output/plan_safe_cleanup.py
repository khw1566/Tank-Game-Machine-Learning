import hashlib
import json
import os
from pathlib import Path
import zipfile
import zlib

ROOT = Path(__file__).resolve().parents[1]
SYNC = ROOT / '_sync'
entries = []

def sha(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()

def add(path, reason, retained):
    assert path.is_relative_to(SYNC) and path.is_file()
    entries.append(dict(path=str(path), bytes=path.stat().st_size,
                        reason=reason, retained=str(retained)))

for version, locations in {
    '20261118_105224': ['packages', 'portable relocation check/20261118_105224'],
    '20261118_114645': ['packages', 'portable v2 validation'],
}.items():
    name = 'TankGameML_Battle_Windows_' + version
    archive = SYNC / 'packages' / (name + '.zip')
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        members = {i.filename: i for i in z.infolist()}
        for location in locations:
            print('Checking runtime:', location, version, flush=True)
            runtime = SYNC / location / name / 'python'
            for path in runtime.rglob('*'):
                if not path.is_file() or path.is_symlink():
                    continue
                # Focus on large redundant runtime binaries. Keep small files
                # and caches to avoid unnecessary work during active training.
                if path.stat().st_size < 1024 * 1024:
                    continue
                # Keep CSV files even when they are library test fixtures.
                if path.suffix.lower() == '.csv':
                    continue
                relative = path.relative_to(runtime).as_posix()
                keys = ['python/' + relative, name + '/python/' + relative]
                member = next((members[k] for k in keys if k in members), None)
                if member is not None and member.file_size == path.stat().st_size:
                    crc = 0
                    with path.open('rb') as stream:
                        while chunk := stream.read(1024 * 1024):
                            crc = zlib.crc32(chunk, crc)
                    if crc == member.CRC:
                        add(path, 'runtime_file_preserved_in_verified_zip', archive)
            print('Verified files so far:', len(entries), flush=True)

# Keep all original snapshots and archived game engines. Remove only identical
# staging copies, proven by size and SHA-256, never unique files or partial ZIPs.
canonical = list((ROOT / 'training' / 'snapshots').rglob('*.zip'))
canonical += list((ROOT / 'build').glob('*.exe'))
canonical += list((Path(os.environ['LOCALAPPDATA']) / 'TankGameML/training/runtimes').rglob('*.exe'))
by_size = {}
for path in canonical:
    by_size.setdefault(path.stat().st_size, []).append(path)
digest_cache = {}
staging = list(SYNC.glob('*.exe'))
for folder in ['partial_snapshot_first_attempt', 'partial_snapshot_second_attempt']:
    staging += list((SYNC / folder).rglob('*.zip'))
for path in staging:
    for keep in by_size.get(path.stat().st_size, []):
        digest_cache.setdefault(str(keep), sha(keep))
        if sha(path) == digest_cache[str(keep)]:
            add(path, 'identical_staging_copy', keep)
            break

assert len({e['path'] for e in entries}) == len(entries)
result = dict(entries=entries, files=len(entries), bytes=sum(e['bytes'] for e in entries))
out = ROOT / 'output' / 'safe-cleanup-plan-20261119.json'
out.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
from collections import Counter
summary = Counter()
for e in entries:
    summary[e['reason']] += e['bytes']
print(json.dumps(dict(manifest=str(out), files=result['files'], bytes=result['bytes'], categories=summary)))
