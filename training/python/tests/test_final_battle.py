from collections import Counter
from pathlib import Path
import random
import tempfile
from types import SimpleNamespace
import unittest

from tankrl.curriculum import Curriculum, STAGES, STAGE_IDS, lineup
from tankrl.evaluation import aggregate, battle_config, run_evaluation
from tankrl.individuals import AGENTS


class FinalBattleTests(unittest.TestCase):
    def test_seventh_tank_does_not_change_old_stage_ids(self):
        self.assertEqual(STAGE_IDS[:9], ['drive','drive_terrain','gunnery_static','gunnery_moving',
            'gunnery_search','duel_scripted','duel_selfplay','team_scripted','team_selfplay'])
        self.assertEqual(STAGE_IDS[9], 'final_battle')
        for learner in ('tiger1', 'sherman75', 't34_76'):
            tanks = lineup(STAGES[9], learner, random.Random(3), {'tiger1','sherman75','t34_76'})
            self.assertEqual(Counter(t['type'] for t in tanks), {'tiger1': 1, 'sherman75': 3, 't34_76': 3})
            self.assertEqual(sum(t['role']=='learner' for t in tanks), 1)

    def test_partial_policy_battle_marks_scripted_t34(self):
        cfg, bindings = battle_config(set(list(AGENTS)[:4]), 'mixed', 10001, 'mixed')
        self.assertEqual([t['ctrl'] for t in cfg['tanks']], ['external']*4 + ['scripted']*3)
        self.assertEqual(list(bindings.values()).count('scripted'), 3)
        self.assertEqual(cfg['spawn']['distance'], [200, 200])
        self.assertEqual(cfg['time_limit_s'], 180)
        self.assertEqual(cfg['map']['size_m'], 360)
        all_cfg, all_bindings = battle_config(set(AGENTS), 'mixed', 10001, 'all')
        self.assertTrue(all(t['ctrl'] == 'external' for t in all_cfg['tanks']))
        self.assertEqual(len(set(all_bindings.values())), 7)

    def test_baseline_uses_same_geometry_but_zero_external_agents(self):
        mixed, _ = battle_config(set(list(AGENTS)[:4]), 'mixed', 10001, 'm')
        baseline, bindings = battle_config(set(list(AGENTS)[:4]), 'scripted', 10001, 'b')
        for key in ('seed', 'map', 'spawn'):
            self.assertEqual(mixed[key], baseline[key])
        self.assertTrue(all(t['ctrl']=='scripted' for t in baseline['tanks']))
        self.assertTrue(all(b=='scripted' for b in bindings.values()))

    def test_ninth_stage_checkpoint_resumes_and_promotes_only_after_success(self):
        cur = Curriculum('tiger1', start_stage=8, review_prob=0)
        cur.episodes_in_stage = 10000
        self.assertIsNone(cur.report('team_selfplay', False, 1))
        self.assertEqual(cur.stage_idx, 8)
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'state.json'
            cur.save(p)
            cur = Curriculum.load(p, 'tiger1', review_prob=0)
            self.assertEqual(cur.stage_idx, 8)
        for _ in range(200):
            event = cur.report('team_selfplay', True, 1)
            if event:
                break
        self.assertEqual(cur.stage_idx, 9)
        self.assertEqual(event['to'], 'final_battle')
        for _ in range(500):
            self.assertIsNone(cur.report('final_battle', True, 1))

    def test_timeouts_are_draws_and_no_shots_is_not_perfect_accuracy(self):
        tank = dict(team=0, shots=0, hits=0, pens=0, kills=0)
        values = aggregate([dict(mode='mixed', winner=-1, duration_s=600, tanks=[tank])])['mixed']
        self.assertEqual(values['tiger_wins'], 0)
        self.assertEqual(values['draws'], 1)
        self.assertIsNone(values['tiger']['accuracy'])

    def test_evaluation_refuses_to_overwrite_training_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root/'training'
            source.mkdir()
            original = source/'progress.csv'
            original.write_text('keep this training history')
            args = SimpleNamespace(out=source, runs_dir=root, source_run='training')
            with self.assertRaises(ValueError):
                run_evaluation(args, ['mixed'])
            self.assertEqual(original.read_text(), 'keep this training history')


if __name__ == '__main__':
    unittest.main()
