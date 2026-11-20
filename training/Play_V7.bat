@echo off
setlocal
set "v7_game=%~dp0..\build\TankGame_v6.exe"
if exist "%~dp0..\build\v7-controls\TankGame_v6.exe" set "v7_game=%~dp0..\build\v7-controls\TankGame_v6.exe"
if not exist "%v7_game%" (
    echo Game executable missing: "%v7_game%"
    pause
    exit /b 1
)
start "" "%v7_game%" -- --v7-native
