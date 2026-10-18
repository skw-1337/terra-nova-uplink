@echo off
rem Terra Nova Uplink, online coop guest (prototype): joins a Steam friend's coop game. Needs your own copy of the game
rem (Uplink draws the maps from it), Godot 4.7 and Steam running. Accept the host's invite in Steam, or start this file
rem and use "Join game" on the host in your friends list. W/S/A/D, mouse and left button in this window drive your teammate,
rem or a gamepad (left stick move, right stick look, right trigger fire). F8: next teammate. Host and guest need the
rem same Uplink coop files (the version is checked when you join).
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
start "" "%EXE%" --path "%HERE%." --resolution 1280x720 -- --live --coop-guest --live-port 47831 --play --play-port 47834 %*
