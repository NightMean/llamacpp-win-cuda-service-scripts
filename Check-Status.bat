@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0llama-scripts\check-llama-status.ps1" %*
echo.
pause
