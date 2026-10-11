@echo off
rem Terminal entry point for Windows users who would rather double-click than
rem open an MSYS2 shell. Everything it does is forward the arguments to
rem build-selectable.ps1, which asks the questions and runs the build in MSYS2.
setlocal
set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-selectable.ps1" %*
set "RC=%ERRORLEVEL%"
if "%RC%"=="9009" echo(Start this from PowerShell instead: .\build-selectable.ps1
exit /b %RC%