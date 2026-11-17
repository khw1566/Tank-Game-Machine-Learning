import tempfile
from pathlib import Path
import unittest

from dashboard import CsvTail, CsvSegments


class CsvStreamTests(unittest.TestCase):
    def test_sb3_header_expansion_reloads_all_previous_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'progress.csv'
            p.write_text('time/total_timesteps\n1024\n')
            tail = CsvTail(p)
            tail.update()
            p.write_text('time/total_timesteps,train/value_loss\n1024,\n2048,0.5\n')
            tail.update()
            self.assertEqual(len(tail.rows), 2)
            self.assertEqual(tail.rows[-1]['train/value_loss'], '0.5')
            tail.update()
            self.assertEqual(len(tail.rows), 2)

    def test_bom_and_partial_appends_do_not_duplicate_rows(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'progress.csv'
            p.write_text('step,value\n1,2\n', encoding='utf-8-sig')
            tail=CsvTail(p)
            tail.update()
            with p.open('a') as f: f.write('2,')
            tail.update()
            self.assertEqual(len(tail.rows), 1)
            with p.open('a') as f: f.write('3\n')
            tail.update()
            self.assertEqual(tail.rows, [{'step':'1','value':'2'}, {'step':'2','value':'3'}])
