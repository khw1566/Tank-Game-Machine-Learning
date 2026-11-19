"""HTML 보고서 → PDF(인쇄용). 추가 패키지 없이 PC 에 깔린 Edge/Chrome 의 headless 인쇄를 쓴다.

  python -m tankrl.pdf_export runs/<run>/training_report.html            → 같은 폴더의 training_report.pdf
  python -m tankrl.pdf_export <경기>/report.html out.pdf --landscape

- 보고서 원본은 건드리지 않는다. 임시 사본에 인쇄용 CSS(A4 여백, 색 유지, 차트·표가 페이지 경계에서
  잘리지 않게, 스크롤 상자 펼치기, 화면 전용 버튼 숨기기)와 <base> 를 넣어 인쇄한다.
- SVG 차트는 벡터 그대로 PDF 에 들어간다. 보고서 안의 필터 스크립트도 실행된 뒤 인쇄된다
  (URL 의 #stage=…&variant=… 로 고른 단계·변형만 인쇄할 수 있다).
- 브라우저 경로를 바꾸려면 환경 변수 TANK_PDF_BROWSER.
"""
from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PRINT_CSS = """
@page { size: A4 %(orient)s; margin: 12mm 11mm 14mm 11mm; }
@media print {
  html, body { background: #fff !important; }
  body { margin: 0 auto !important; max-width: none !important; padding: 0 !important; font-size: 12px; }
  * { -webkit-print-color-adjust: exact !important; print-color-adjust: exact !important; }
  .no-print, .toolbar, .filters, .actions, button, select, input { display: none !important; }
  .scroll, .tablewrap, .table-wrap { max-height: none !important; overflow: visible !important; }
  svg, figure, .chartbox, .objective-legend, .legend, .tiles, tr, img, canvas { break-inside: avoid; page-break-inside: avoid; }
  h1, h2, h3 { break-after: avoid; page-break-after: avoid; }
  h2 { break-before: auto; }
  section.stage-block { break-inside: avoid-page; }
  table { width: auto; max-width: 100%%; }
  thead { display: table-header-group; }
  a { color: inherit; text-decoration: none; }
  svg { max-width: 100%% !important; height: auto !important; }
}
"""

CANDIDATES = [
    r"%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe",
    r"%ProgramFiles%\Microsoft\Edge\Application\msedge.exe",
    r"%ProgramFiles%\Google\Chrome\Application\chrome.exe",
    r"%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe",
    r"%LocalAppData%\Google\Chrome\Application\chrome.exe",
    "/usr/bin/chromium", "/usr/bin/chromium-browser", "/usr/bin/google-chrome",
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
]


def find_browser() -> str | None:
    env = os.environ.get("TANK_PDF_BROWSER")
    if env and Path(env).exists():
        return env
    for c in CANDIDATES:
        p = Path(os.path.expandvars(c))
        if p.exists():
            return str(p)
    for name in ("msedge", "chrome", "chromium", "chromium-browser", "google-chrome"):
        w = shutil.which(name)
        if w:
            return w
    return None


def printable_html(text: str, base_dir: Path, landscape: bool = False) -> str:
    """원본 HTML 에 <base> 와 인쇄용 CSS 를 끼워 넣는다(원본 파일은 그대로)."""
    inject = (f'<base href="{base_dir.resolve().as_uri()}/">'
              f'<style id="tank-print-css">{PRINT_CSS % {"orient": "landscape" if landscape else "portrait"}}</style>')
    m = re.search(r"<head[^>]*>", text, re.I)
    if m:
        return text[:m.end()] + inject + text[m.end():]
    m = re.search(r"<meta charset[^>]*>", text, re.I)
    if m:
        return text[:m.end()] + inject + text[m.end():]
    return "<meta charset=utf-8>" + inject + text


def html_to_pdf(html_text: str, out_pdf: Path, base_dir: Path, *, landscape: bool = False, fragment: str = "",
                timeout: float = 120) -> Path:
    browser = find_browser()
    if not browser:
        raise RuntimeError("PDF 를 만들 브라우저(Edge/Chrome)를 찾지 못했습니다. 보고서를 열고 Ctrl+P → 'PDF로 저장'을 쓰거나 "
                           "TANK_PDF_BROWSER 환경 변수로 브라우저 경로를 지정하세요.")
    out_pdf = Path(out_pdf).resolve()
    out_pdf.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="tank_pdf_", ignore_cleanup_errors=True) as tmp:
        src = Path(tmp) / "page.html"
        src.write_text(printable_html(html_text, base_dir, landscape), encoding="utf-8")
        part = out_pdf.with_suffix(".pdf.part")
        part.unlink(missing_ok=True)
        cmd = [browser, "--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
               "--disable-extensions", "--no-pdf-header-footer", "--hide-scrollbars",
               f"--user-data-dir={Path(tmp) / 'profile'}",   # 사용 중인 브라우저 창과 프로필이 겹치지 않게
               "--virtual-time-budget=8000", "--run-all-compositor-stages-before-draw",
               f"--print-to-pdf={part}", src.as_uri() + (("#" + fragment.lstrip("#")) if fragment else "")]
        flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=timeout,
                           creationflags=flags)
        # 브라우저가 파일을 다 쓰고 닫을 때까지 잠깐 기다린다
        for _ in range(50):
            if part.exists() and part.stat().st_size > 0:
                break
            time.sleep(0.1)
        if not part.exists() or part.stat().st_size == 0:
            raise RuntimeError("PDF 생성 실패: " + (r.stdout + r.stderr)[-400:])
        os.replace(part, out_pdf)
    return out_pdf


def file_to_pdf(src: Path, out_pdf: Path | None = None, **kw) -> Path:
    src = Path(src).resolve()
    out = Path(out_pdf) if out_pdf else src.with_suffix(".pdf")
    return html_to_pdf(src.read_text(encoding="utf-8", errors="replace"), out, src.parent, **kw)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("html")
    ap.add_argument("out", nargs="?")
    ap.add_argument("--landscape", action="store_true")
    ap.add_argument("--fragment", default="", help="예: stage=m3_under_fire&variant=ambush")
    a = ap.parse_args(argv)
    print(file_to_pdf(Path(a.html), Path(a.out) if a.out else None, landscape=a.landscape, fragment=a.fragment))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
