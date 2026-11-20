import json
from http.client import HTTPConnection
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from play_v7 import PlayServer, SERVICE


class NativePlayLauncherTests(unittest.TestCase):
    def test_graphical_process_gets_exact_lineup_and_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            exe = root / "Godot Game.exe"
            exe.touch()
            with PlayServer(0, root / "demo folder", exe) as server, patch("play_v7.subprocess.Popen") as launch:
                with self.assertRaises(ValueError):
                    server.launch({"tank": "tiger1", "stage": "v7_1v6"})
                launch.return_value.poll.return_value = None
                picked = {"tank": "t34_76", "stage": "v7_1v6"}
                state = server.launch(picked)
                self.assertTrue(state["running"])
                self.assertEqual(state, server.launch(picked))
                launch.assert_called_once()
                args = launch.call_args.args[0]
                self.assertEqual(args[:3], [str(exe), "--", "--v7-native"])
                self.assertIn("--tank=t34_76", args)
                self.assertIn("--stage=v7_1v6", args)
                self.assertIn(f"--demos-dir={root / 'demo folder'}", args)
                self.assertNotIn("--headless", args)

    def test_native_lobby_launch_and_corpus_are_local(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            exe = root / "game.exe"
            exe.touch()
            (root / "sherman75").mkdir()
            (root / "sherman75" / "complete.json").touch()
            (root / "sherman75" / "incomplete.tmp").touch()
            (root / "sherman75" / "old.npz").touch()
            with PlayServer(0, root, exe) as server, patch("play_v7.subprocess.Popen") as launch:
                launch.return_value.poll.return_value = None
                launch.return_value.pid = 1234
                worker = threading.Thread(target=server.serve_forever, daemon=True)
                worker.start()
                client = HTTPConnection("127.0.0.1", server.server_port, timeout=3)
                try:
                    client.request("GET", "/api/corpus")
                    state = json.load(client.getresponse())
                    self.assertEqual(state["service"], SERVICE)
                    self.assertEqual(state["counts"], {"t34_76": 0, "sherman75": 1})
                    client.request("POST", "/api/launch", "{}", {"Origin": "http://elsewhere",
                                                                  "Content-Type": "application/json"})
                    response = client.getresponse()
                    self.assertEqual(response.status, 403)
                    response.read()
                    launch.assert_not_called()
                    client.request("POST", "/api/launch", "{}", {"Content-Type": "application/json"})
                    self.assertTrue(json.load(client.getresponse())["running"])
                    self.assertFalse(any(s.startswith("--tank=") for s in launch.call_args.args[0]))
                finally:
                    client.close()
                    server.shutdown()
                    worker.join()
