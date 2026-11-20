"""학습 중 보고서 자동 갱신: 체크포인트 저장·단계 변경 때 report.py(학습 보고서 + 탄착군 보고서)를
낮은 우선순위의 별도 프로세스로 돌린다. 학습 루프는 기다리지 않는다.

- 이미 돌고 있으면 새로 띄우지 않고 "대기" 표시만 남겨, 다음 요청 때 한 번 더 돈다.
- 저장 때는 min_interval_s 보다 자주 돌리지 않는다. 단계 변경(force)은 간격을 무시한다.
- 출력은 <run>/analysis/auto_report.log 에 남는다.
"""
from __future__ import annotations

import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


class AutoReport:
    def __init__(self, run_dir: Path, min_interval_s: float = 600.0):
        self.run_dir = Path(run_dir)
        self.min_interval_s = float(min_interval_s)
        self.proc: subprocess.Popen | None = None
        self.last_start = 0.0
        self.pending = False

    @property
    def enabled(self) -> bool:
        return self.min_interval_s > 0

    def running(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def request(self, reason: str = "save", force: bool = False) -> bool:
        """보고서 갱신을 요청한다. 실제로 프로세스를 띄웠으면 True."""
        if not self.enabled:
            return False
        if self.running():
            self.pending = True
            return False
        if not (force or self.pending) and time.time() - self.last_start < self.min_interval_s:
            return False
        log_dir = self.run_dir / "analysis"
        log_dir.mkdir(parents=True, exist_ok=True)
        flags = 0
        if sys.platform == "win32":
            flags = subprocess.BELOW_NORMAL_PRIORITY_CLASS | subprocess.CREATE_NO_WINDOW
        try:
            with (log_dir / "auto_report.log").open("a", encoding="utf-8") as log:
                log.write(f"\n=== {time.strftime('%Y-%m-%d %H:%M:%S')} {reason} ===\n")
                log.flush()
                self.proc = subprocess.Popen([sys.executable, str(HERE / "report.py"), str(self.run_dir)],
                                             cwd=str(HERE), stdout=log, stderr=subprocess.STDOUT,
                                             stdin=subprocess.DEVNULL, creationflags=flags)
        except OSError as e:
            print(f"[report] 자동 보고서 시작 실패: {e}", flush=True)
            return False
        self.last_start = time.time()
        self.pending = False
        return True
