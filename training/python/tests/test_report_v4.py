"""v4 학습 보고서(단계·변형 필터)와 PDF 인쇄용 HTML 변환 — 브라우저 없이 확인할 수 있는 부분."""
import csv
import json
import tempfile
import unittest
from pathlib import Path

import report
from tankrl.pdf_export import printable_html

COLS = ["global_step", "uid", "tank", "stage", "variant", "success", "reason", "return", "duration_s",
        "hits_taken", "exposed_s", "hits", "shots", "learner_policy"]


class ReportV4Test(unittest.TestCase):
    def make_run(self, d: Path):
        stages = [{"id": "m1_drive", "part": "기동", "label": "주행·정지", "variants": ["near", "far"],
                   "variants_desc": {"near": "가까운 목표", "far": "먼 목표"}, "promote": {"window": 40, "threshold": 0.8}},
                  {"id": "m3_under_fire", "part": "기동", "label": "노출과 피격", "variants": ["screened", "ambush"],
                   "variants_desc": {}, "promote": {"window": 40, "threshold": 0.8}}]
        (d / "run.json").write_text(json.dumps({"curriculum_version": 4, "stages": stages}), encoding="utf-8")
        with (d / "scenario_progress.csv").open("w", newline="", encoding="utf-8") as f:
            w = csv.DictWriter(f, COLS)
            w.writeheader()
            step = 0
            for sid, vs in (("m1_drive", ["near", "far"]), ("m3_under_fire", ["screened", "ambush"])):
                for k in range(120):
                    for v in vs:
                        for t in ("tiger1", "sherman75"):
                            step += 100
                            w.writerow({"global_step": step, "uid": f"r_shared_{k}_{sid}_{v}_{t}", "tank": t, "stage": sid,
                                        "variant": v, "success": int(k % 3 != 0), "reason": "objective_reached",
                                        "return": 1.5, "duration_s": 20, "hits_taken": 1 if sid.startswith("m3") else 0,
                                        "exposed_s": 3, "hits": 0, "shots": 0, "learner_policy": f"r/shared/step_{step}"})
        (d / "curriculum_log.jsonl").write_text(json.dumps({"tank": "shared", "from": "m1_drive", "to": "m3_under_fire",
                                                            "episodes": 480, "success_rate": 0.8, "reason": "threshold",
                                                            "variant_rates": {"near@tiger1": 0.8}, "global_step": 48000,
                                                            "curriculum_version": 4}) + "\n", encoding="utf-8")

    def test_v4_report_has_stage_variant_blocks_and_filter(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.make_run(d)
            out = report.build(d)
            text = out.read_text(encoding="utf-8")
            self.assertIn('class=stage-block data-stage="m1_drive"', text)
            self.assertIn('class=stage-block data-stage="m3_under_fire"', text)
            self.assertIn('data-variant="ambush"', text)
            self.assertIn('data-tank="sherman75"', text)
            self.assertIn("받은 명중(피격) 수", text)            # m3 에만 피격 곡선
            self.assertIn('id=report-meta', text)
            meta = json.loads(text.split("id=report-meta>", 1)[1].split("</script>", 1)[0])
            self.assertEqual([s["id"] for s in meta["stages"]], ["m1_drive", "m3_under_fire"])
            self.assertEqual(meta["stages"][1]["variants"], ["screened", "ambush"])

    def test_final_run_with_scenario_csv_uses_final_report(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            self.make_run(d)
            (d / "run.json").write_text(json.dumps({"curriculum_version": 6}), encoding="utf-8")
            with patch("report.build_v4", side_effect=AssertionError("wrong report")):
                self.assertTrue(report.build(d).is_file())

    def test_chart_end_labels_stay_inside_plot(self):
        from tankrl.report_v4 import chart
        page = chart([{"pts": [(0, 0), (100, 1)], "color": "red", "label": "test"}], "test", "value", vlines=[(100, "last stage")])
        self.assertIn('class=vt text-anchor=end>last stage', page)
        self.assertIn('class=ax text-anchor=start>0', page)

    def test_printable_html_injects_print_css_and_base(self):
        html = "<!doctype html><html><head><meta charset=utf-8><title>x</title></head><body>hi</body></html>"
        out = printable_html(html, Path(tempfile.gettempdir()))
        self.assertIn("@page", out)
        self.assertIn("<base href=\"file:", out)
        self.assertLess(out.index("tank-print-css"), out.index("<title>"))


if __name__ == "__main__":
    unittest.main()
