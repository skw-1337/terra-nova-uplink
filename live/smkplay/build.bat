@echo off
rem Builds smkdec.exe (the co-op guest's Smacker video decoder, smkdec.cs) with the C# compiler that comes with Windows
rem (.NET Framework 4). Not needed by hand: the guest's Uplink builds it the same way the first time it needs it.
cd /d "%~dp0"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
"%CSC%" /nologo /optimize /target:exe /platform:anycpu /out:smkdec.exe smkdec.cs
if errorlevel 1 (echo BUILD FAILED) else (echo Built smkdec.exe)
if not "%1"=="nopause" pause
