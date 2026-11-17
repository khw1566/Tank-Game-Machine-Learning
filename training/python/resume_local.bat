@echo off
setlocal
chcp 65001 >nul
set PYTHONUTF8=1
cd /d "%~dp0"
if not exist ".venv\Scripts\python.exe" (
  echo Missing training Python: .venv\Scripts\python.exe
  pause
  exit /b 1
)
set "trainingData=%LOCALAPPDATA%\TankGameML\training"
if defined TANKGAME_DATA_DIR set "trainingData=%TANKGAME_DATA_DIR%"
if not exist "%trainingData%\runs\su1117_02\tiger1\latest.zip" (
  echo Missing restored checkpoint: %trainingData%\runs\su1117_02\tiger1\latest.zip
  pause
  exit /b 1
)
".venv\Scripts\python.exe" -u train.py --godot "..\..\build\TankGame.exe" --run su1117_02 --tank tiger1 --resume --device cpu --n-envs 2 --torch-threads 2 --timesteps 1000000 %*
set "trainExit=%errorlevel%"
pause
exit /b %trainExit%
