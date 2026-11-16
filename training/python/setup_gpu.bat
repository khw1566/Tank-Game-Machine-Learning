@echo off
chcp 65001 >nul
set PYTHONUTF8=1
cd /d "%~dp0"
py -3.14 setup_gpu.py
if errorlevel 1 echo GPU setup failed. Check the error above.
pause
