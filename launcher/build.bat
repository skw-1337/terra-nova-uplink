@echo off
rem Builds "Terra Nova Uplink.exe" with the C# compiler that comes with Windows (.NET Framework 4.5 or later), and
rem "Terra Nova Coop.exe" from the same code (TerraNovaCoop.cs: a copy, read by the Coop launchers to update themselves)
rem The pages' pictures (bg_*.jpg) and the Graphics page's previews (previews\*.jpg) are built into both.
cd /d "%~dp0"
copy /y TerraNovaUplink.cs TerraNovaCoop.cs >nul
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
setlocal enabledelayedexpansion
set "PV="
for %%f in (previews\*.jpg) do set "PV=!PV! /resource:previews\%%~nxf,previews.%%~nxf"
"%CSC%" /nologo /optimize /target:winexe /platform:anycpu /win32manifest:app.manifest /win32icon:icon.ico /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Management.dll /resource:bg_play.jpg /resource:bg_coop.jpg /resource:bg_maps.jpg %PV% /out:"Terra Nova Uplink.exe" TerraNovaUplink.cs
if errorlevel 1 (echo BUILD FAILED) else (echo Built "Terra Nova Uplink.exe")
"%CSC%" /nologo /optimize /target:winexe /platform:anycpu /win32manifest:coop.manifest /win32icon:icon.ico /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.IO.Compression.dll /r:System.IO.Compression.FileSystem.dll /r:System.Management.dll /resource:bg_play.jpg /resource:bg_coop.jpg /resource:bg_maps.jpg %PV% /out:"Terra Nova Coop.exe" TerraNovaCoop.cs
if errorlevel 1 (echo BUILD FAILED) else (echo Built "Terra Nova Coop.exe")
if not "%1"=="nopause" pause
