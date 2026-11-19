@echo off
rem Final 1v6 training: copy the V5run 1 shared model into tiger/sherman/T-34 models and train them in turn.
rem Running it again resumes the three models saved in FINAL-1 (V5run 1 itself is never modified).
setlocal
cd /d "%~dp0"
set "FINAL_PY=%~dp0.venv\Scripts\python.exe"
if not exist "%FINAL_PY%" set "FINAL_PY=python"
set "PYTHONUTF8=1"
"%FINAL_PY%" -u train.py --godot "..\..\build\TankGame_final.exe" --curriculum final --branch-from "V5run 1" --run FINAL-1 --rotate tiger1,sherman75,t34_76 --rotate-steps 2000000 --cycles 10 --n-envs 8 --device auto --save-every 100000 --record-every 100 %*
endlocal
