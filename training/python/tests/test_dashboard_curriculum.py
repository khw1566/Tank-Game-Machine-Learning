import json
import tempfile
import unittest
from pathlib import Path

from dashboard import Dashboard


class DashboardCurriculumTests(unittest.TestCase):
    def dashboard(self, root):
        dash = object.__new__(Dashboard)
        dash.runs_dir = Path(root)
        dash.settings = {}
        dash.train_python = lambda: "python"
        return dash

    def test_final_restart_recovers_source_for_uninitialized_tanks(self):
        with tempfile.TemporaryDirectory() as root:
            dash = self.dashboard(root)
            run = Path(root) / "FINAL-1"
            run.mkdir()
            first = dict(curriculum="final", branch_from="V5run 1", rotate="tiger1,sherman75,t34_76",
                         godot="TankGame_final.exe", n_envs=6, device="cpu", rotate_steps=2000000, cycles=10)
            latest = first | dict(branch_from="", curriculum="v1")
            (run / "run.json").write_text(json.dumps(dict(curriculum_version=6, sessions=[
                dict(args=first), dict(args=latest)])))
            args = dash.restart_args("FINAL-1", dict(n_envs=8))
            cmd = dash.build_cmd(args)
            self.assertEqual(args["curriculum"], "final")
            self.assertEqual(args["branch_from"], "V5run 1")
            self.assertEqual(cmd.count("--curriculum"), 1)
            self.assertEqual(cmd[cmd.index("--curriculum") + 1], "final")
            self.assertEqual(cmd[cmd.index("--branch-from") + 1], "V5run 1")

    def test_invalid_cross_curriculum_stage_is_rejected_before_queueing(self):
        with tempfile.TemporaryDirectory() as root:
            dash = self.dashboard(root)
            run = Path(root) / "V5run 1"
            run.mkdir()
            (run / "run.json").write_text(json.dumps(dict(curriculum_version=5)))
            with self.assertRaisesRegex(ValueError, "최종"):
                dash.control(run.name, dict(cmd="set_stage", stage="final_1v6"))
            self.assertFalse((run / "control.jsonl").exists())
            dash.control(run.name, dict(cmd="set_stage", stage="battle_terrain"))
            self.assertEqual(json.loads((run / "control.jsonl").read_text(encoding="utf-8"))["stage"], "battle_terrain")
