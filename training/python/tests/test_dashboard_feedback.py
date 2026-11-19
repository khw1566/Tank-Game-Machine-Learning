"""대시보드 피드백: 명령 확인 응답(acks), 준비 중에 보낸 명령, 커리큘럼 버전 분류."""
import json
import os
import tempfile
import time
import unittest
from pathlib import Path

from dashboard import Dashboard
from tankrl import curriculum_history
from tankrl.control import LAUNCH_ENV, TrainController


def status(run: Path) -> dict:
    return json.loads((run / "status.json").read_text(encoding="utf-8"))


def wait_for(fn, timeout=3.0):
    t0 = time.time()
    while time.time() - t0 < timeout:
        v = fn()
        if v:
            return v
        time.sleep(0.05)
    raise AssertionError("시간 초과")


class ControlAckTests(unittest.TestCase):
    def dashboard(self, root):
        dash = object.__new__(Dashboard)
        dash.runs_dir = Path(root)
        dash.settings = {}
        import threading
        dash.lock = threading.Lock()
        dash._cmd_seq = 0
        return dash

    def test_commands_are_acknowledged_while_training_thread_is_busy(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root) / "R"
            run.mkdir()
            (run / "run.json").write_text(json.dumps({"curriculum_version": 6}))
            ctl = TrainController(run, record_every=100)
            try:
                ctl.write_status(0, force=True, phase="updating")   # 학습 스레드는 PPO 갱신 중이라 tick 을 안 부른다
                dash = self.dashboard(root)
                pause = dash.control("R", {"cmd": "pause"})
                rec = dash.control("R", {"cmd": "set", "record_every": 25})
                ck = dash.control("R", {"cmd": "checkpoint"})
                acks = wait_for(lambda: {a["id"]: a for a in status(run).get("acks", [])} if len(status(run).get("acks", [])) == 3 else None)
                self.assertEqual(acks[pause["id"]]["state"], "applied")
                self.assertEqual(acks[rec["id"]]["state"], "applied")
                self.assertEqual(status(run)["record_every"], 25)
                self.assertTrue(status(run)["paused"])
                self.assertEqual(status(run)["phase"], "updating")
                self.assertEqual(acks[ck["id"]]["state"], "received")     # 체크포인트는 학습 스레드에서
                done = []
                ctl.handlers["checkpoint"] = lambda msg: done.append(msg)
                ctl.poll()
                self.assertEqual(len(done), 1)
                wait_for(lambda: {a["id"]: a for a in status(run)["acks"]}[ck["id"]]["state"] == "applied")
            finally:
                ctl.close()

    def test_commands_sent_during_launch_are_kept_but_old_ones_ignored(self):
        with tempfile.TemporaryDirectory() as root:
            run = Path(root) / "R"
            run.mkdir()
            (run / "control.jsonl").write_text(json.dumps({"cmd": "stop", "t": time.time() - 100}) + "\n")
            launch = time.time()
            with open(run / "control.jsonl", "a") as f:
                f.write(json.dumps({"cmd": "pause", "id": "a", "t": launch + 0.5}) + "\n")
            os.environ[LAUNCH_ENV] = f"{launch:.3f}"
            try:
                ctl = TrainController(run)
            finally:
                del os.environ[LAUNCH_ENV]
            try:
                wait_for(lambda: ctl.paused)
                self.assertFalse(ctl.stop_requested)
            finally:
                ctl.close()


class HistoryTests(unittest.TestCase):
    def test_versions_and_classification(self):
        keys = [v["key"] for v in curriculum_history.versions()]
        self.assertEqual(keys, ["v1", "v4.0", "v4.1", "v4.1-cover", "v5", "v6"])
        with tempfile.TemporaryDirectory() as root:
            def make(name, version, cur=None):
                d = Path(root) / name
                (d / "shared").mkdir(parents=True)
                (d / "run.json").write_text(json.dumps({"curriculum_version": version}))
                if cur is not None:
                    (d / "shared" / "curriculum.json").write_text(json.dumps(cur))
                return curriculum_history.classify_run(d)
            self.assertEqual(make("a", 1), "v1")
            self.assertEqual(make("b", 4, {"curriculum_version": 4}), "v4.0")
            self.assertEqual(make("c", 4, {"stageset": "4.1", "assessment_version": 3}), "v4.1")
            self.assertEqual(make("d", 4, {"stageset": "4.1", "assessment_version": 4}), "v4.1-cover")
            self.assertEqual(make("e", 5), "v5")
            self.assertEqual(make("f", 6), "v6")


if __name__ == "__main__":
    unittest.main()
