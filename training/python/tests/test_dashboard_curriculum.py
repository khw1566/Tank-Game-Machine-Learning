import json
import io
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from dashboard import Dashboard, EP_COLS, RunWatch, default_v6_godot
from tankrl import curriculum_v4, v6_curriculum, v7_curriculum
from tankrl.runtime import v6_game_path


class DashboardCurriculumTests(unittest.TestCase):
    def test_arcade_scratch_command_and_prepared_resume(self):
        with tempfile.TemporaryDirectory() as root:
            dash = self.dashboard(root)
            args = dict(curriculum="v7", run="V7-1", n_envs=4, tank="sherman75", timesteps=500,
                        behavior_clone=True, demos_dir="example demos", godot="legacy.exe",
                        init_model="old.zip", branch_from="older")
            cmd = dash.build_cmd(args)
            self.assertEqual(Path(cmd[2]).name, "train_v7.py")
            self.assertEqual(cmd[cmd.index("--tank") + 1], "sherman75")
            self.assertEqual(cmd[cmd.index("--demos-dir") + 1], "example demos")
            self.assertIn("--behavior-clone", cmd)
            for flag in ("--godot", "--init-model", "--branch-from", "--resume"):
                self.assertNotIn(flag, cmd)
            run = Path(root) / args["run"]
            run.mkdir()
            (run / "run.json").write_text(json.dumps({"curriculum_version": v7_curriculum.VERSION,
                                                      "stageset": v7_curriculum.STAGESET, "sessions": []}))
            resumed = dash.build_cmd(dash.restart_args(run.name, {"n_envs": 3}))
            for flag in ("--rotate", "--resume", "--behavior-clone"):
                self.assertIn(flag, resumed)
            self.assertEqual(resumed[resumed.index("--n-envs") + 1], "3")
            with self.assertRaisesRegex(ValueError, "같은 이름"):
                dash.start(args)
            with self.assertRaisesRegex(ValueError, "V7"):
                dash.control(run.name, {"cmd": "set_stage", "stage": v7_curriculum.STAGE_IDS[-1]})
            dash.control(run.name, {"cmd": "checkpoint"})

    def test_arcade_stage_map_and_reward_ledger_use_active_model_and_stage(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root)
            (run / "run.json").write_text(json.dumps({"curriculum_version": v7_curriculum.VERSION,
                                                      "stageset": v7_curriculum.STAGESET}))
            first = v7_curriculum.STAGE_IDS[0]
            st = {"tank": "sherman75", "curriculum": {"stage": first}}
            (run / "status.json").write_text(json.dumps(st))
            state = RunWatch(run).state(0, {})
            self.assertEqual(state["stage_ids"], v7_curriculum.STAGE_IDS)
            self.assertIsNone(state["v6"])
            self.assertEqual(state["v7"]["models"]["sherman75"]["stage"], first)
            row = {"tank": "sherman75", "stage": first, "reward_components": '{"side_seen": 0.5}'}
            summary = RunWatch.v7_summary(st, {}, [row, row | {"reward_components": "{}"}, row | {"tank": "tiger1"}])
            self.assertEqual(summary["reward_episodes"], 2)
            self.assertEqual(summary["reward_means"]["side_seen"], 0.25)

    def test_start_preflights_selected_allied_demos_before_launch(self):
        with tempfile.TemporaryDirectory() as root:
            dash = self.dashboard(root)
            dash.procs = {}
            dash.deps = {"state": "ok", "python": "python"}
            demo = Path(root) / "demos"
            (demo / "sherman75").mkdir(parents=True)
            (demo / "sherman75" / "finished.json").touch()
            args = dict(curriculum="v7", run="arcade", demos_dir=str(demo), behavior_clone=True)
            with patch("dashboard.subprocess.Popen") as launch:
                with self.assertRaisesRegex(ValueError, "t34_76"):
                    dash.start(args | {"rotate": "tiger1,sherman75,t34_76"})
                launch.assert_not_called()
                result = dash.start(args | {"tank": "sherman75"})
                self.assertIn("--behavior-clone", result["cmd"])
                launch.assert_called_once()

    def test_collector_starts_once_and_reuses_known_service(self):
        with tempfile.TemporaryDirectory() as root:
            dash = self.dashboard(root)
            dash.play_lock = threading.Lock()
            dash.play_proc = None
            with patch.object(dash, "collector_ready", side_effect=[False, True, True]), \
                    patch("dashboard.subprocess.Popen") as launch, \
                    patch("dashboard.urllib.request.urlopen", side_effect=lambda *a, **kw: io.BytesIO(b'{"running":true}')):
                first = dash.open_collector()
                self.assertEqual(dash.open_collector(), first)
                self.assertTrue(first["running"])
                self.assertEqual(Path(launch.call_args.args[0][2]).name, "play_v7.py")
                launch.assert_called_once()
    def test_duel_opponents_are_recovered_from_original_progress_rows(self):
        with tempfile.TemporaryDirectory() as root:
            watch = RunWatch(Path(root))
            index = EP_COLS.index('duel_opponent')
            base = {'tank': 'tiger1', 'stage': 'v6_1v1'}
            self.assertEqual(watch.ep_compact(base | {'opponents': ''})[index], 'scripted')
            self.assertEqual(watch.ep_compact(base | {'opponents': 'shared/step_1.zip'})[index], 'model')
            self.assertEqual(watch.ep_compact(base)[index], '')
            self.assertEqual(watch.ep_compact(base | {'stage': 'v6_1v2', 'opponents': ''})[index], '')

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

    def test_exited_process_does_not_hide_live_replacement(self):
        with tempfile.TemporaryDirectory() as root:
            dash = self.dashboard(root)
            dash.procs = {"V6-1": SimpleNamespace(pid=100, poll=lambda: 0)}
            status = dict(pid=101, phase="collecting", updated=time.time())
            self.assertTrue(dash.alive("V6-1", status))
            self.assertFalse(dash.alive("V6-1", status | {"pid": 100}))
            self.assertFalse(dash.alive("V6-1", status | {"updated": time.time() - 30}))

    def test_v6_path_replaces_stale_build_choices_only(self):
        canonical = Path(default_v6_godot())
        self.assertEqual(canonical.name, "TankGame_v6.exe")
        for name in ("TankGame_v6_cover.exe", "TankGame_v6_tactics_v2.exe"):
            self.assertEqual(Path(v6_game_path(str(canonical.with_name(name)))), canonical)
        with tempfile.TemporaryDirectory() as root:
            archive = str(Path(root) / "TankGame_v6_cover.exe")
            self.assertEqual(v6_game_path(archive), archive)

    def test_v6_map_uses_stage_catalog_and_live_stats(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root)
            (run / "run.json").write_text(json.dumps({"curriculum_version": v6_curriculum.VERSION}))
            st = {"tank": "tiger1", "curriculum": {"stage": "v6_1v1", "battle": {"metrics": {
                "valley@tiger1": {"episodes": 50, "win": 0.36}}}}}
            (run / "status.json").write_text(json.dumps(st))
            state = RunWatch(run).state(0, {})
            self.assertIsNone(state["v4"])
            self.assertEqual([s["id"] for s in state["v6"]["stages"]], v6_curriculum.STAGE_IDS)
            self.assertEqual(state["v6"]["recent"]["v6_1v1:valley@tiger1"], [18, 50])
            self.assertEqual(state["v6"]["models"]["tiger1"]["stage"], "v6_1v1")
            (run / "run.json").write_text(json.dumps({"curriculum_version": curriculum_v4.VERSION}))
            state = RunWatch(run).state(0, {})
            self.assertIsNone(state["v6"])
            self.assertEqual([s["id"] for s in state["v4"]["stages"]], curriculum_v4.STAGE_IDS)
