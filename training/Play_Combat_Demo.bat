@echo off
rem Real-combat human demonstrations for behavior cloning (V6 battle, real shells).
rem Usage: Play_Combat_Demo.bat [--tank sherman75^|t34_76] [--stage v6_1v1^|v6_1v2^|v6_1v3^|v6_1v6] [--run "V6 run name"]
setlocal
cd /d "%~dp0python"
set "DEMO_PY=%~dp0python\.venv\Scripts\python.exe"
if not exist "%DEMO_PY%" set "DEMO_PY=py -3.14"
set "PYTHONUTF8=1"
set "DEMO_GAME=%~dp0..\build\TankGame_v6.exe"
if exist "%~dp0..\build\combat-demo\TankGame_v6.exe" set "DEMO_GAME=%~dp0..\build\combat-demo\TankGame_v6.exe"
%DEMO_PY% -u play_combat_demo.py --godot "%DEMO_GAME%" %*
if errorlevel 1 pause
endlocal
