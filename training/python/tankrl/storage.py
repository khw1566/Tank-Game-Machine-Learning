"""Version-independent training data, immutable saves and exclusive run ownership."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
import uuid
import zipfile

from .control import write_json_atomic


def data_root() -> Path:
    if os.environ.get('TANKGAME_DATA_DIR'):
        return Path(os.environ['TANKGAME_DATA_DIR']).expanduser().resolve()
    base = Path(os.environ.get('LOCALAPPDATA', Path.home() / '.local' / 'share'))
    return base / 'TankGameML' / 'training'


def default_runs_dir() -> Path:
    persistent = data_root() / 'runs'
    legacy = Path(__file__).resolve().parents[1] / 'runs'
    # An existing checkout must not look empty before its explicit data migration is complete.
    return legacy.resolve() if not persistent.exists() and legacy.exists() else persistent


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_copy(source: Path, destination: Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=destination.name + '.', suffix='.tmp', dir=destination.parent)
    os.close(fd)
    temporary = Path(name)
    try:
        shutil.copyfile(source, temporary)
        for attempt in range(20):
            try:
                os.replace(temporary, destination)
                return
            except PermissionError:
                if attempt == 19:
                    raise
                time.sleep(.05)
    finally:
        temporary.unlink(missing_ok=True)


def checkpoint_paths(tank_dir: Path) -> tuple[Path | None, Path]:
    pointer = tank_dir / 'checkpoint.json'
    if pointer.exists():
        info = json.loads(pointer.read_text(encoding='utf-8'))
        generation = (tank_dir / info['generation']).resolve()
        if not generation.is_relative_to(tank_dir.resolve()):
            raise ValueError('Checkpoint generation outside tank directory')
        model = generation / 'model.zip'
        if sha256(model) != info['sha256']:
            raise ValueError(f'Checkpoint checksum mismatch: {model}')
        return model, generation / 'curriculum.json'
    latest = tank_dir / 'latest.zip'
    if latest.exists():
        with zipfile.ZipFile(latest) as archive:
            if archive.testzip() is not None:
                raise ValueError(f'Corrupt checkpoint: {latest}')
        return latest, tank_dir / 'curriculum.json'
    if (tank_dir / 'curriculum.json').exists() or any(tank_dir.glob('step_*.zip')) or any((tank_dir / 'checkpoints').glob('*/model.zip')):
        raise ValueError(f'Existing checkpoint history requires recovery; refusing a fresh policy: {tank_dir}')
    return None, tank_dir / 'curriculum.json'


def save_checkpoint(model, tank_dir: Path, curriculum: dict) -> Path:
    token = dt.datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '_' + uuid.uuid4().hex[:6]
    generation = tank_dir / 'checkpoints' / f'step_{model.num_timesteps:09d}_{token}'
    generation.mkdir(parents=True, exist_ok=False)
    model_path = generation / 'model.zip'
    model.save(str(model_path))
    with zipfile.ZipFile(model_path) as archive:
        if archive.testzip() is not None:
            raise ValueError('Saved checkpoint failed ZIP integrity validation')
    write_json_atomic(generation / 'curriculum.json', curriculum)
    info = dict(generation=generation.relative_to(tank_dir).as_posix(), sha256=sha256(model_path),
                num_timesteps=model.num_timesteps, created=dt.datetime.now().astimezone().isoformat())
    write_json_atomic(generation / 'metadata.json', info)
    atomic_copy(model_path, tank_dir / 'latest.zip')
    write_json_atomic(tank_dir / 'curriculum.json', curriculum)
    write_json_atomic(tank_dir / 'checkpoint.json', info)
    return tank_dir / 'latest.zip'


def session_log_dir(run_dir: Path, tank: str) -> Path:
    token = dt.datetime.now().strftime('%Y%m%d_%H%M%S_%f') + '_' + uuid.uuid4().hex[:6]
    directory = run_dir / 'sb3' / tank / token
    directory.mkdir(parents=True, exist_ok=False)
    return directory


def archive_runtime(game: Path, project: str | None = None) -> dict:
    if project:  # Editor sessions also need their source checkout; do not mislabel the editor as an exported game.
        return dict(project=str(Path(project).resolve()))
    digest = sha256(game)
    archive = data_root() / 'runtimes' / digest / game.name
    if not archive.exists():
        atomic_copy(game, archive)
    return dict(sha256=digest, executable=str(archive))


class RunLock:
    def __init__(self, run_dir: Path):
        self.path = run_dir / '.training.lock'
        self.file = None

    def __enter__(self):
        self.file = self.path.open('a+b')
        if self.path.stat().st_size == 0:
            self.file.write(b'\0')
            self.file.flush()
        self.file.seek(0)
        try:
            if os.name == 'nt':
                import msvcrt
                msvcrt.locking(self.file.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.file.close()
            raise RuntimeError(f'이미 학습 중인 실행입니다. 저장 후 중지하고 다시 시작하세요: {self.path.parent}') from None
        return self

    def __exit__(self, *_):
        self.file.seek(0)
        if os.name == 'nt':
            import msvcrt
            msvcrt.locking(self.file.fileno(), msvcrt.LK_UNLCK, 1)
        self.file.close()
