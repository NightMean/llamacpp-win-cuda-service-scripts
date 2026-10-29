@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0llama-scripts\rollback-llamacpp.ps1" %*
echo.
pause
