@echo off
rem Terra Nova Uplink, online coop host (prototype, TN+ Coop build): you play in this window, a Steam friend
rem drives a teammate from his PC (Coop online - join.bat). F9 in your window: Steam invite. English game.
rem Start the game first with Terra Nova Plus (Display HD 848x480), then run this file.
rem Needs 64-bit Python 3 with numpy and psutil (pip install numpy psutil).
setlocal
set "HERE=%~dp0"
set "EXE="
if defined GODOT if exist "%GODOT%" set "EXE=%GODOT%"
if not defined EXE for %%f in ("%HERE%Godot_v4*_win64.exe" "%HERE%..\Godot_v4*_win64.exe" "C:\Tools\Godot\Godot_v4*_win64.exe") do if not defined EXE if exist "%%~f" set "EXE=%%~f"
if not defined EXE for %%g in (godot.exe godot4.exe) do if not defined EXE for %%p in (%%g) do if not "%%~$PATH:p"=="" set "EXE=%%~$PATH:p"
if not defined EXE (
    echo Godot 4.7 not found.
    echo Download the standard Windows version from https://godotengine.org/download/windows/
    echo and unzip it next to this folder, or set the GODOT variable to the Godot exe.
    pause
    exit /b 1
)
set "GODOT=%EXE%"
where python >nul 2>nul
if errorlevel 1 (
    echo Python 3 not found. Get it from https://www.python.org/downloads/ then run: pip install numpy psutil
    pause
    exit /b 1
)
python -u "%HERE%live\live_bridge.py" --launch --hud --play --guest-remote --fov 91.5 --res 1696x960
rem the window closes with Uplink; it stays open only if the bridge stopped on an error
if errorlevel 1 pause
