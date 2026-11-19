import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import package_battle

spec = importlib.util.spec_from_file_location("portable_runner", Path(__file__).resolve().parents[2] / "portable" / "runner.py")
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PortablePackageTests(unittest.TestCase):
    def test_snapshot_alias_comes_from_matching_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, target = root / "source", root / "target"
            generation = source / "shared" / "checkpoints" / "step_123"
            generation.mkdir(parents=True)
            (generation / "model.zip").write_bytes(b"matching-model")
            package_battle.write(generation / "curriculum.json", {"stage": "battle_flat"})
            package_battle.write(generation / "metadata.json", {"num_timesteps": 123})
            pointer = {"generation": "checkpoints/step_123", "sha256": package_battle.sha256(generation / "model.zip"),
                       "num_timesteps": 123}
            package_battle.write(source / "shared" / "checkpoint.json", pointer)
            (source / "shared" / "latest.zip").write_bytes(b"racing-alias-must-not-be-used")
            package_battle.write(source / "status.json", {"pid": 999, "phase": "stopped"})
            (source / "opponents").mkdir()
            package_battle.snapshot(source, target)
            self.assertEqual((target / "shared" / "latest.zip").read_bytes(), b"matching-model")
            self.assertEqual(package_battle.read(target / "status.json")["pid"], 0)
            self.assertFalse((source / "control.jsonl").exists())

    def test_gpu_venv_home_moves_with_bundle(self):
        with tempfile.TemporaryDirectory(prefix="portable path ") as directory:
            root = Path(directory)
            gpu = root / "gpu_env"
            (gpu / "Scripts").mkdir(parents=True)
            (gpu / "Scripts" / "python.exe").touch()
            runner.write(gpu / "verified.json", {"verified": True})
            (gpu / "pyvenv.cfg").write_text("home = C:/old/python\nexecutable = C:/old/python/python.exe\n", encoding="utf-8")
            with patch.object(runner, "ROOT", root):
                self.assertEqual(runner.selected_python(), gpu / "Scripts" / "python.exe")
            text = (gpu / "pyvenv.cfg").read_text(encoding="utf-8")
            self.assertIn(str(root / "python"), text)
            self.assertNotIn("C:/old", text)

    def test_health_rebase_is_idempotent(self):
        with tempfile.TemporaryDirectory(prefix="portable path ") as directory:
            root = Path(directory)
            run = root / "data" / "runs" / "BATTLE-1"
            (run / "shared").mkdir(parents=True)
            (run / "shared" / "good.zip").touch()
            runner.write(root / "package_config.json", {"run": "BATTLE-1", "device": "auto"})
            health = run / "shared" / "good_checkpoints.json"
            runner.write(health, {"good": [{"path": "$RUN/shared/good.zip"}], "best": {}})
            with patch.object(runner, "ROOT", root), patch.dict(os.environ), patch("tankrl.storage.checkpoint_paths", return_value=(run / "shared" / "good.zip", None)):
                runner.prepare()
                self.assertEqual(runner.read(health)["good"][0]["path"], str(run / "shared" / "good.zip"))
                modified = health.stat().st_mtime_ns
                runner.prepare()
                self.assertEqual(health.stat().st_mtime_ns, modified, "Launching a dashboard must not overwrite live health state")
                runner.write(health, {"good": [{"path": "$RUN/../../outside.zip"}], "best": {}})
                with self.assertRaises(ValueError):
                    runner.prepare()


if __name__ == "__main__":
    unittest.main()
