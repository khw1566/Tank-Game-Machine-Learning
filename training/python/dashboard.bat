@echo off
rem Training dashboard launcher (double-click).
rem Python choice: training\python\.venv  ->  "py -3" launcher (newest installed)  ->  python on PATH.
rem The dashboard then uses the SAME Python for train.py, pip install, reproduce and report.
chcp 65001 >nul
set PYTHONUTF8=1
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
  ".venv\Scripts\python.exe" dashboard.py %*
  goto end
)
where py >nul 2>nul
if %errorlevel%==0 (
  py -3 dashboard.py %*
  goto end
)
python dashboard.py %*
:end
pause
