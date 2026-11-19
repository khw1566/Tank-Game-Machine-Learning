@echo off
setlocal
cd /d "%~dp0"
set "BATTLE_PY=%~dp0.venv\Scripts\python.exe"
if not exist "%BATTLE_PY%" set "BATTLE_PY=python"
set "PYTHONUTF8=1"
"%BATTLE_PY%" -u train.py --godot "..\..\build\TankGame_battle.exe" --curriculum battle --tank shared --auto-branch --run BATTLE-2 --n-envs 8 --device auto --torch-threads 2 --n-steps 256 --batch-size 512 --n-epochs 4 --timesteps 10000000 --rotate-steps 3000000 --cycles 3 --save-every 50000 --record-every 100 %*
endlocal
