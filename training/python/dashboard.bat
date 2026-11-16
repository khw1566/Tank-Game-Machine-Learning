@echo off
rem 학습 대시보드 실행(더블클릭). training\python\.venv 가 있으면 그 Python 을 쓴다.
chcp 65001 >nul
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" dashboard.py %*
) else (
  python dashboard.py %*
)
pause
