@echo off
rem Terra Nova Uplink, map viewer (Godot 4.7): reads the maps straight from your game install.
rem Looks for Godot in: the GODOT variable, next to this folder, in the PATH, in C:\Tools\Godot.
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
start "" "%EXE%" --path "%HERE%."
