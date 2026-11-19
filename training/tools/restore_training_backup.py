"""Verify an archived training snapshot and restore into a new local directory."""
import argparse
import hashlib
import json
from pathlib import Path
import zipfile

parser = argparse.ArgumentParser()
parser.add_argument('snapshot', type=Path)
parser.add_argument('destination', type=Path)
args = parser.parse_args()
manifest = json.loads((args.snapshot / 'manifest.json').read_text(encoding='utf-8'))
destination = args.destination.resolve()
if destination.exists():
    raise SystemExit('Destination must not exist; existing data will not be overwritten.')
for item in manifest['archives']:
    with (args.snapshot / item['path']).open('rb') as stream:
        if hashlib.file_digest(stream, 'sha256').hexdigest() != item['sha256']:
            raise SystemExit(f"Archive checksum mismatch: {item['path']}")
for item in manifest['archives']:
    with zipfile.ZipFile(args.snapshot / item['path']) as archive:
        for row in (r for r in manifest['files'] if r['archive'] == item['path']):
            target = (destination / row['path']).resolve()
            if not target.is_relative_to(destination):
                raise SystemExit('Unsafe archive path')
            data = archive.read(row['path'])
            if len(data) != row['bytes'] or hashlib.sha256(data).hexdigest() != row['sha256']:
                raise SystemExit(f"File checksum mismatch: {row['path']}")
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(data)
print(f"Restored {manifest['file_count']} verified files to {destination}")
