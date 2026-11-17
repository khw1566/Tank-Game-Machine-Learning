import csv
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from dashboard import RunWatch
from tankrl.storage import RunLock, checkpoint_paths, save_checkpoint, session_log_dir
from tankrl.godot_env import episode_counter


class FakeModel:
    num_timesteps = 123
    fail = False

    def save(self, path):
        if self.fail:
            Path(path).write_bytes(b'incomplete')
            raise OSError('simulated interrupted save')
        with zipfile.ZipFile(path, 'w') as archive:
            archive.writestr('data', json.dumps(dict(num_timesteps=self.num_timesteps)))


class StorageTests(unittest.TestCase):
    def test_unfinished_episode_names_are_not_reused_on_resume(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            folder = run / 'episodes' / 'env1'
            folder.mkdir(parents=True)
            (folder / 'example_sherman75_0000012_drive.json').write_text('{}')
            (run / 'progress.csv').write_text('uid,tank\nexample_sherman75_0000009_drive,sherman75\n')
            self.assertEqual(episode_counter(run, 'example', 'sherman75'), 12)
            self.assertEqual(episode_counter(run, 'example', 'tiger1'), 0)

    def test_generations_preserve_models_and_matching_curriculum(self):
        with tempfile.TemporaryDirectory() as tmp:
            tank = Path(tmp)
            model = FakeModel()
            save_checkpoint(model, tank, dict(stage_idx=1))
            original, curriculum = checkpoint_paths(tank)
            before = original.read_bytes()
            model.num_timesteps = 456
            save_checkpoint(model, tank, dict(stage_idx=2))
            current, state = checkpoint_paths(tank)
            self.assertEqual(original.read_bytes(), before)
            self.assertNotEqual(current, original)
            self.assertEqual(json.loads(state.read_text())['stage_idx'], 2)
            self.assertEqual(json.loads(curriculum.read_text())['stage_idx'], 1)
            (tank / 'latest.zip').write_bytes(b'corrupt canonical mirror')
            self.assertEqual(checkpoint_paths(tank)[0], current)

    def test_interrupted_save_keeps_previous_valid_model(self):
        with tempfile.TemporaryDirectory() as tmp:
            tank = Path(tmp)
            model = FakeModel()
            save_checkpoint(model, tank, dict(stage_idx=1))
            original = (tank / 'latest.zip').read_bytes()
            model.fail = True
            with self.assertRaises(OSError):
                save_checkpoint(model, tank, dict(stage_idx=2))
            self.assertEqual((tank / 'latest.zip').read_bytes(), original)
            self.assertEqual(json.loads(checkpoint_paths(tank)[1].read_text())['stage_idx'], 1)

    def test_run_cannot_have_two_writers(self):
        with tempfile.TemporaryDirectory() as tmp:
            with RunLock(Path(tmp)):
                with self.assertRaises(RuntimeError):
                    with RunLock(Path(tmp)):
                        pass
            with RunLock(Path(tmp)):
                pass

    def test_session_logs_and_imported_history_are_retained(self):
        with tempfile.TemporaryDirectory() as tmp:
            run = Path(tmp)
            first = session_log_dir(run, 'tiger1')
            second = session_log_dir(run, 'tiger1')
            for directory, steps in ((first, 100), (second, 200)):
                (directory / 'progress.csv').write_text('time/total_timesteps,train/loss\n%d,1\n' % steps)
            imported = run / 'imports' / 'old'
            imported.mkdir(parents=True)
            (run / 'history_sources.json').write_text(json.dumps(dict(sources=[dict(path='imports/old')])))
            header = 'uid,tank,wall_time,global_step,stage_idx,stage,success\n'
            (run / 'progress.csv').write_text(header + 's,sherman75,2,20,0,drive,1\n')
            (imported / 'progress.csv').write_text(header + 't,tiger1,1,100,1,drive_terrain,1\n')
            watch = RunWatch(run)
            result = watch.state(0, {})
            self.assertEqual(result['ep_total'], 2)
            self.assertEqual(len(result['sb3']['tiger1']['rows']), 2)
            self.assertTrue((first / 'progress.csv').exists())


if __name__ == '__main__':
    unittest.main()
