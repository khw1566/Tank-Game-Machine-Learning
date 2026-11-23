import csv
import json
from pathlib import Path
import tempfile
import unittest

from dashboard import RunWatch, EP_COLS
from report import build, svg_chart
from tankrl.objectives import ObjectiveIndex, objective_color, COURSE_COLORS


class ObjectiveTests(unittest.TestCase):
    def test_versions_and_unknown_history_are_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            index = ObjectiveIndex()
            keys = []
            for version in (2, 3):
                p = root / 'episodes/env0' / f'v{version}.json'
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(json.dumps({'config': {'terrain_course': {'version': version, 'id': 'approach'}}}))
                keys.append(index.annotate(dict(uid=p.stem, stage='drive_terrain', env=0), root)['objective'])
            keys.append(index.annotate(dict(uid='legacy', stage='drive_terrain'), root)['objective'])
            self.assertEqual(len(set(keys)), 3)
            self.assertEqual(len({index.catalog[k]['color'] for k in keys}), 3)
            self.assertEqual(len(set(COURSE_COLORS.values())), 13)
            self.assertNotEqual(objective_color('drive/terrain:v3/approach'),
                                objective_color('drive_terrain/terrain:v3/approach'))

    def test_new_objective_metadata_needs_no_chart_code_change(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p = root / 'episodes/env0/custom.json'
            p.parent.mkdir(parents=True)
            p.write_text(json.dumps({'config': {'learning_objective': {'id': 'aim_track', 'label': 'Track aiming', 'version': 4}}}))
            index = ObjectiveIndex()
            key = index.annotate(dict(uid='custom', stage='gunnery_static'), root)['objective']
            self.assertEqual(index.catalog[key]['label'], 'Track aiming [v4]')
            self.assertEqual(index.catalog[key]['color'], objective_color(key))

    def test_dashboard_and_report_share_groups_and_colors(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fields = ['wall_time','global_step','env','uid','tank','stage','stage_idx','current_stage','success','return','duration_s','decisions','shots','hits','pens','kills','reason','spawn_distance_m']
            with (root/'progress.csv').open('w', newline='') as f:
                writer = csv.DictWriter(f, fieldnames=fields)
                writer.writeheader()
                for i, course in enumerate(['approach', 'slope']):
                    uid = f'e{i}'
                    p = root/'episodes/env0'/f'{uid}.json'
                    p.parent.mkdir(parents=True, exist_ok=True)
                    p.write_text(json.dumps({'config': {'terrain_course': {'id': course, 'version': 3}}}))
                    writer.writerow(dict(zip(fields,[i,i,0,uid,'tiger1','drive_terrain',1,'drive_terrain',i,0,1,10,0,0,0,0,'done',20])))
            state = RunWatch(root).state(0, {})
            self.assertEqual(len(state['objectives']), 2)
            self.assertNotEqual(state['episodes'][0][EP_COLS.index('objective')], state['episodes'][1][EP_COLS.index('objective')])
            page = build(root).read_text(encoding='utf-8')
            for info in state['objectives'].values():
                self.assertIn(info['label'], page)
                self.assertIn(info['color'], page)
            self.assertIn('</svg><div class=objective-legend>', page)

    def test_final_map_variant_reaches_dashboard(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            p = root / 'episodes/env0/final.json'
            p.parent.mkdir(parents=True)
            p.write_text(json.dumps({'config': {'scenario': {'variant': 'urban'}}}))
            row = ObjectiveIndex().annotate(dict(uid='final', stage='final_selfplay', env=0), root)
            self.assertEqual(row['variant'], 'urban')
            self.assertEqual(RunWatch(root).ep_compact(row)[EP_COLS.index('variant')], 'urban')

    def test_saved_v6_objectives_preserve_graph_groups_without_episode_files(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'episode_objectives.csv').write_text(
                'uid,final_hash,objective_id,objective_label,objective_version,variant\n'
                'duel,abc,v6_1v1,Duel,4,village\n', encoding='utf-8')
            index = ObjectiveIndex()
            episode = dict(uid='duel', final_hash='abc', stage='v6_1v1')
            result = index.annotate(episode, root)
            self.assertEqual(result['objective'], 'v6_1v1/objective:v4/v6_1v1')
            self.assertEqual(result['variant'], 'village')
            self.assertEqual(index.catalog[result['objective']]['label'], 'Duel [v4]')
            self.assertEqual(index.annotate(episode | {'final_hash': 'new'}, root)['variant'], '')

    def test_single_episode_is_visible(self):
        page = svg_chart([('One', '#2563eb', [(10, 1)])], 'Title', 'Value')
        self.assertIn('<circle', page)


if __name__ == '__main__':
    unittest.main()
