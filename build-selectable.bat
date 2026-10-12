@echo off
rem Terminal entry point for Windows users who would rather double-click than
rem open an MSYS2 shell. Everything it does is forward the arguments to
rem build-selectable.ps1, which asks the questions and runs the build in MSYS2.
rem Every build-selectable.ps1 option works here too, for example
rem   build-selectable.bat -Preset image -Codecs spng,openjpeg -Platform win-x64
rem   build-selectable.bat -DryRun -Yes -Preset aggressive -Features heif_enc=on
rem (-Preset takes full/lean/aggressive/image, or the old 0/1/2 numbers, and
rem  -Features takes comma separated name=on|off pairs; lean is asked by default.)
setlocal
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-selectable.ps1" %*
set "RC=%ERRORLEVEL%"
if "%RC%"=="9009" echo(Start this from PowerShell instead: .\build-selectable.ps1
exit /b %RC%