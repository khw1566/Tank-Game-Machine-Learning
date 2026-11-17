import json
from pathlib import Path
import random
import tempfile
import unittest

from tankrl.curriculum import Curriculum, STAGES, STAGE_IDS, make_config, lineup
from tankrl.terrain import COURSES, COURSE_IDS, WINDOW, lesson
from tankrl.control import write_json_atomic


class TerrainCurriculumTests(unittest.TestCase):
    def test_basic_driving_review_uses_same_stopping_rule(self):
        self.assertEqual(STAGES[0]['terrain_course']['hold_s'], .6)
        self.assertEqual(STAGES[0]['terrain_course']['stop_speed'], 1)
        self.assertEqual(STAGES[0]['terrain_course']['id'], 'approach')

    def test_status_write_does_not_reuse_shared_tmp_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'status.json'
            legacy = path.with_suffix('.json.tmp')
            legacy.write_text('occupied')
            with legacy.open('r'):
                write_json_atomic(path, dict(phase='stopped'))
            self.assertEqual(json.loads(path.read_text()), dict(phase='stopped'))
            self.assertEqual(legacy.read_text(), 'occupied')
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ['status.json', 'status.json.tmp'])

    def test_legacy_checkpoint_starts_first_lesson_and_keeps_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "curriculum.json"
            path.write_text(json.dumps(dict(stage_idx=1, episodes_in_stage=1089, history=[dict(reason="threshold")])))
            cur = Curriculum.load(path, "tiger1", review_prob=0)
            self.assertEqual(cur.episodes_in_stage, 0)
            self.assertEqual(cur.previous_assessments[0]['episodes_in_stage'], 1089)
            self.assertEqual(cur.pick_stage()["terrain_course"]["id"], "approach")
            self.assertEqual(cur.stage["id"], "drive_terrain")

    def test_each_lesson_requires_own_window_and_no_forced_promotion(self):
        cur = Curriculum("tiger1", start_stage=1, review_prob=0)
        cur.episodes_in_stage = 100000
        for _ in range(100):
            self.assertIsNone(cur.report("drive_terrain", False, 1, "approach"))
        self.assertEqual(cur.terrain_idx, 0)
        for index, course in enumerate(COURSES):
            for step in range(WINDOW - 1):
                self.assertIsNone(cur.report("drive_terrain", True, step, course["id"]))
            event = cur.report("drive_terrain", True, 50, course["id"])
            if index < len(COURSES) - 1:
                self.assertIsNone(event)
                self.assertEqual(cur.terrain_idx, index + 1)
            else:
                self.assertEqual(event["to"], "gunnery_static")

    def test_unversioned_results_cannot_pass_new_lessons(self):
        cur = Curriculum("tiger1", start_stage=1)
        for _ in range(7000):
            cur.report("drive_terrain", True, 1)
        self.assertEqual(cur.stage_idx, 1)
        self.assertEqual(cur.terrain_idx, 0)

    def test_results_and_subcourse_survive_resume(self):
        cur = Curriculum("tiger1", start_stage=1, review_prob=0)
        for _ in range(WINDOW):
            cur.report("drive_terrain", True, 1, "approach")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            cur.save(path)
            loaded = Curriculum.load(path, "tiger1", review_prob=0)
            self.assertEqual(loaded.state(), cur.state())
            self.assertEqual(loaded.terrain_idx, 1)

    def test_config_varies_each_episode_and_keeps_seed_and_dimensions(self):
        for index, course in enumerate(COURSES):
            stage = lesson(STAGES[1], index)
            lu = lineup(stage, "tiger1", random.Random(3), set())
            config = make_config(stage, "tiger1", lu, 123, 7, "test", False, {})
            self.assertEqual(config["map"]["seed"], 123)
            self.assertEqual(config["terrain_course"]["id"], course["id"])
            self.assertEqual(config["map"]["size_m"], 240)
            self.assertFalse(config["map"]["features"])
            self.assertEqual(len(config["tanks"]), 1)
        self.assertEqual(STAGE_IDS[1], "drive_terrain")

    def test_fixed_course_never_promotes_and_disables_stage_review(self):
        cur = Curriculum("tiger1", start_stage=1, review_prob=1)
        cur.terrain_fixed = "gates"
        for _ in range(100):
            self.assertEqual(cur.pick_stage()["terrain_course"]["id"], "gates")
            self.assertIsNone(cur.report("drive_terrain", True, 1, "gates"))
        self.assertEqual(cur.stage_idx, 1)

    def test_version_change_archives_assessment_without_changing_combat_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'state.json'
            old = dict(stage_idx=2, stage='gunnery_static', episodes_in_stage=1089,
                       results={'gunnery_static': [1, 0]}, terrain=dict(version=2, index=4))
            path.write_text(json.dumps(old))
            loaded = Curriculum.load(path, 'tiger1')
            self.assertEqual(loaded.stage_idx, 2)
            self.assertEqual(loaded.episodes_in_stage, 1089)
            self.assertEqual(loaded.previous_assessments[0]['terrain'], old['terrain'])
            loaded.save(path)
            self.assertEqual(Curriculum.load(path, 'tiger1').state(), loaded.state())

    def test_basic_drive_failures_never_force_promotion(self):
        cur = Curriculum('sherman75')
        cur.episodes_in_stage = 100000
        for _ in range(100):
            self.assertIsNone(cur.report('drive', False, 1, 'approach'))
        self.assertEqual(cur.stage_idx, 0)


if __name__ == "__main__":
    unittest.main()
