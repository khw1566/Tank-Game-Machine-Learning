import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'snapshots'))
from restore_archives import restore


class ArchiveRestoreTests(unittest.TestCase):
    def fixture(self, root, name='runs/example/data.txt', expected=None):
        payload = b'training record'
        with zipfile.ZipFile(root/'data.zip','w') as archive:
            archive.writestr(name, payload)
        contents = dict(files=[dict(archive='data.zip', path=name, bytes=len(payload),
                                   sha256=expected or hashlib.sha256(payload).hexdigest())])
        (root/'content_manifest.json').write_text(json.dumps(contents))
        files = [dict(path=p.name, bytes=p.stat().st_size, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
                 for p in root.iterdir() if p.is_file()]
        (root/'manifest.json').write_text(json.dumps(dict(files=files,file_count=len(files),
            total_bytes=sum(f['bytes'] for f in files),training_state=dict(num_timesteps=123),latest_checkpoint_sha256='example')))

    def test_verified_restore_and_existing_destination_protection(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'snapshot';root.mkdir()
            self.fixture(root)
            target=Path(tmp)/'restored'
            self.assertEqual(restore(root,target)['verified_archive_files'],1)
            self.assertEqual((target/'runs/example/data.txt').read_bytes(),b'training record')
            with self.assertRaises(ValueError): restore(root,target)

    def test_inner_checksum_mismatch_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            self.fixture(root,expected='0'*64)
            with self.assertRaisesRegex(ValueError,'checksum'): restore(root)

    def test_parent_path_cannot_escape_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)/'snapshot';root.mkdir()
            self.fixture(root,name='../escaped.txt')
            with self.assertRaisesRegex(ValueError,'Unsafe'): restore(root,Path(tmp)/'restored')
            self.assertFalse((Path(tmp)/'escaped.txt').exists())
